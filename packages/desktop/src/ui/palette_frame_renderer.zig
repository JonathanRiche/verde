//! The desktop's GPU presentation: one `palette.Graphics` (GPU context,
//! renderer, glyph atlases, the shared font collection) plus the main window's
//! `palette.WindowRenderer` (present loop and frame pacing). Vulkan on Linux,
//! Metal on macOS, Direct3D 11 on Windows, chosen at compile time.
//!
//! Texture ids are allocated here for both one-shot images (inline images,
//! avatars) and streamed browser frames, so the two never collide.

const std = @import("std");
const palette = @import("palette");

const app_state = @import("../state.zig");
const browser_texture = @import("../browser/texture.zig");
const stb_image = @import("../media/stb_image.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");

/// Compile-time GPU backend, for logs.
pub const backend_name: []const u8 = @tagName(palette.gpu.backend_kind);

/// GPU memory the renderer reports after a frame, plus the window's
/// presentation buffers (dma-buf targets / swapchain).
pub const GpuMemory = struct {
    device_local_bytes: u64 = 0,
    host_visible_bytes: u64 = 0,
    window_buffer_bytes: u64 = 0,
};

/// Whether `outcome` settles the requested frame. Throttled and no-buffer
/// outcomes leave the frame pending; the caller retries once `boundWaitNs`
/// elapses.
pub fn outcomePresented(outcome: palette.RenderOutcome) bool {
    return switch (outcome) {
        .presented, .unchanged, .hidden => true,
        .throttled, .no_buffer => false,
    };
}

pub const Renderer = struct {
    gfx: *palette.Graphics,
    wr: palette.WindowRenderer,
    next_texture_id: u32 = 1,

    pub const InitOptions = struct {
        app: *palette.platform.App,
        window: *palette.platform.Window,
        io: std.Io,
        faces: palette.fonts.FaceSet,
    };

    /// The result holds the window renderer by value; do not move it after the
    /// first frame (keep it in one stack slot, as main does).
    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !Renderer {
        const gfx = try palette.Graphics.init(allocator, options.app, .{
            .fonts = options.faces,
            .font_options = .{ .text_scale = palette.fonts.default_text_scale, .io = options.io },
        });
        errdefer gfx.deinit();
        // Verde lays out in framebuffer pixels (mouse events are normalized to
        // pixels too), so measurement stays at device scale 1.
        gfx.fonts.setDeviceScale(1.0);
        const wr = try palette.WindowRenderer.init(gfx, options.window, .{});
        text_measure.configure(gfx.fonts);
        return .{ .gfx = gfx, .wr = wr };
    }

    pub fn deinit(self: *Renderer) void {
        text_measure.clear();
        self.wr.deinit();
        self.gfx.deinit();
        self.* = undefined;
    }

    /// Feeds every platform event to the present loop (frame callbacks,
    /// resizes, visibility). True when the window needs a repaint.
    pub fn handleEvent(self: *Renderer, event: palette.Event) bool {
        return self.wr.handleEvent(event);
    }

    /// Caps the event-wait timeout so a throttled frame is retried when the
    /// present loop can take it.
    pub fn boundWaitNs(self: *const Renderer, timeout_ns: u64, frame_pending: bool) u64 {
        const limit = self.wr.timeoutNs(frame_pending) orelse return timeout_ns;
        return @min(timeout_ns, limit);
    }

    pub fn renderBatch(
        self: *Renderer,
        allocator: std.mem.Allocator,
        batch: *const palette.RenderBatch,
        framebuffer_width: f32,
        framebuffer_height: f32,
    ) !palette.RenderOutcome {
        _ = allocator;
        _ = framebuffer_width;
        _ = framebuffer_height;
        const bg = theme.background();
        return try self.wr.render(batch, .{ .r = bg[0], .g = bg[1], .b = bg[2], .a = bg[3] });
    }

    pub fn lastFrameStats(self: *const Renderer) palette.gpu.FrameStats {
        return self.wr.last_frame;
    }

    pub fn windowStats(self: *const Renderer) palette.WindowRenderer.Stats {
        return self.wr.stats;
    }

    pub fn gpuMemory(self: *const Renderer) GpuMemory {
        const memory = self.wr.last_frame.gpu_memory;
        return .{
            .device_local_bytes = memory.device_local_bytes,
            .host_visible_bytes = memory.host_visible_bytes,
            .window_buffer_bytes = self.wr.bufferBytes(),
        };
    }

    pub fn uploadLoadedTextureCallback(context: ?*anyopaque, loaded: stb_image.LoadedImage) ?app_state.CachedImageTexture {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return null));
        return renderer.uploadLoadedTexture(loaded);
    }

    pub fn uploadLoadedTexture(self: *Renderer, loaded: stb_image.LoadedImage) ?app_state.CachedImageTexture {
        const id = self.nextTextureId();
        const width: u32 = @intCast(loaded.width);
        const height: u32 = @intCast(loaded.height);
        self.gfx.uploadTexture(id, width, height, .rgba8, loaded.pixels[0 .. @as(usize, width) * @as(usize, height) * 4]) catch return null;
        return .{
            .texture_id = id,
            .width = loaded.width,
            .height = loaded.height,
            .valid = true,
            .backend = .external,
        };
    }

    /// Browser frames: streamed (reused image and staging memory, no mips).
    pub fn uploadPaneTextureCallback(context: ?*anyopaque, pane_texture: *browser_texture.PaneTexture, width: u32, height: u32, format: browser_texture.PixelFormat, pixels: []const u8) !void {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return error.GpuTextureUnavailable));
        const texture_id = if (pane_texture.texture_id == 0) renderer.nextTextureId() else pane_texture.texture_id;
        const gpu_format: palette.gpu.TextureFormat = switch (format) {
            .rgba => .rgba8,
            .bgra => .bgra8,
        };
        try renderer.gfx.streamTexture(texture_id, width, height, gpu_format, pixels, .{});
        pane_texture.update(texture_id, width, height, true);
    }

    pub fn releasePaneTextureCallback(context: ?*anyopaque, texture_id: c_uint) void {
        const renderer: *Renderer = @ptrCast(@alignCast(context orelse return));
        renderer.gfx.renderer.releaseTexture(texture_id);
    }

    pub fn releaseTextureCallback(context: ?*anyopaque, texture_id: c_uint) void {
        releasePaneTextureCallback(context, texture_id);
    }

    fn nextTextureId(self: *Renderer) u32 {
        const id = self.next_texture_id;
        self.next_texture_id +%= 1;
        if (self.next_texture_id == 0) self.next_texture_id = 1;
        return id;
    }
};
