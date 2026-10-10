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

var snapshot_path_state: enum { unknown, unset, set } = .unknown;
var snapshot_path_value: [:0]const u8 = "";

fn snapshotPath() ?[:0]const u8 {
    if (snapshot_path_state == .unknown) {
        if (std.c.getenv("VERDE_PALETTE_SNAPSHOT")) |value| {
            snapshot_path_value = std.mem.span(value);
            snapshot_path_state = if (snapshot_path_value.len > 0) .set else .unset;
        } else snapshot_path_state = .unset;
    }
    return if (snapshot_path_state == .set) snapshot_path_value else null;
}

/// True while a `VERDE_PALETTE_SNAPSHOT` request is pending, so the loop can
/// force a frame even when nothing else changed.
pub fn snapshotRequested() bool {
    if (comptime @import("builtin").os.tag == .windows) return false;
    const path = snapshotPath() orelse return false;
    var request_buffer: [4096 + 16]u8 = undefined;
    const request = std.fmt.bufPrintZ(&request_buffer, "{s}.request", .{path}) catch return false;
    return std.c.access(request.ptr, 0) == 0;
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

    /// False while the present loop would refuse a frame (awaiting the frame
    /// callback, or no free buffer); callers skip building the batch.
    pub fn ready(self: *Renderer) bool {
        return self.wr.ready();
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
        const bg = theme.background();
        const clear: palette.Color = .{ .r = bg[0], .g = bg[1], .b = bg[2], .a = bg[3] };
        const outcome = try self.wr.render(batch, clear);
        if (snapshotPath()) |path| self.maybeSnapshot(allocator, batch, framebuffer_width, framebuffer_height, clear, path);
        return outcome;
    }

    /// Dev hook for headless checks: with `VERDE_PALETTE_SNAPSHOT=/path.png`,
    /// creating `/path.png.request` makes the next frame render offscreen and
    /// land as a PNG at `/path.png` (the request file is removed). The window
    /// itself is untouched, so this works on hidden or locked outputs.
    fn maybeSnapshot(self: *Renderer, allocator: std.mem.Allocator, batch: *const palette.RenderBatch, framebuffer_width: f32, framebuffer_height: f32, clear: palette.Color, path: [:0]const u8) void {
        if (comptime @import("builtin").os.tag == .windows) return;
        var request_buffer: [4096 + 16]u8 = undefined;
        const request = std.fmt.bufPrintZ(&request_buffer, "{s}.request", .{path}) catch return;
        if (std.c.access(request.ptr, 0) != 0) return;
        _ = std.c.unlink(request.ptr);
        const width: u32 = @intFromFloat(@max(framebuffer_width, 1));
        const height: u32 = @intFromFloat(@max(framebuffer_height, 1));
        var offscreen = palette.gpu.Offscreen.init(self.gfx.renderer, width, height) catch return;
        defer offscreen.deinit();
        _ = offscreen.render(batch, .{ .clear = clear }) catch return;
        const pixels = allocator.alloc(u8, @as(usize, width) * height * 4) catch return;
        defer allocator.free(pixels);
        offscreen.readRgba(pixels) catch return;
        const png = palette.image_codec.encodeRgba(allocator, pixels, width, height, .{}) catch return;
        defer allocator.free(png);
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        var written: usize = 0;
        while (written < png.len) {
            const n = std.c.write(fd, png[written..].ptr, png.len - written);
            if (n <= 0) return;
            written += @intCast(n);
        }
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

    /// Zero-copy browser frames need dma-buf import, which only the Vulkan
    /// backend has.
    pub const dmabuf_supported = palette.gpu.backend_kind == .vulkan;

    /// The renderer hooks `browser_texture` uses for dma-buf frames, or null
    /// when the backend cannot import them (frames are then copied).
    pub fn dmabufImporter(self: *Renderer) ?browser_texture.DmabufImporter {
        if (comptime !dmabuf_supported) return null;
        return .{
            .context = self,
            .formats = dmabufFormatsCallback,
            .import = importDmabufCallback,
            .release_fence = dmabufReleaseFenceCallback,
            .forget = forgetDmabufCallback,
            .readback = readbackTextureCallback,
        };
    }

    fn fromContext(context: ?*anyopaque) *Renderer {
        return @ptrCast(@alignCast(context.?));
    }

    fn dmabufFormatsCallback(context: ?*anyopaque, allocator: std.mem.Allocator, out: *std.ArrayList(browser_texture.DmabufFormat)) anyerror!void {
        if (comptime !dmabuf_supported) return;
        const renderer = fromContext(context);
        var formats: std.ArrayList(palette.platform.present.FormatModifier) = .empty;
        defer formats.deinit(allocator);
        try renderer.gfx.dmabufImportFormats(allocator, &formats);
        try out.ensureUnusedCapacity(allocator, formats.items.len);
        for (formats.items) |format| {
            out.appendAssumeCapacity(.{ .fourcc = @intFromEnum(format.format), .modifier = format.modifier });
        }
    }

    fn importDmabufCallback(context: ?*anyopaque, texture_id: c_uint, frame: browser_texture.DmabufFrame) anyerror!browser_texture.DmabufImportResult {
        if (comptime !dmabuf_supported) return error.GpuTextureUnavailable;
        const renderer = fromContext(context);
        const present = palette.platform.present;
        if (frame.plane_count == 0 or frame.plane_count > present.max_planes) return error.InvalidDmabuf;
        var image: present.DmabufImage = .{
            .width = frame.width,
            .height = frame.height,
            .format = @enumFromInt(frame.fourcc),
            .modifier = frame.modifier,
            .plane_count = frame.plane_count,
            .planes = undefined,
        };
        for (0..frame.plane_count) |index| {
            const plane = frame.planes[index];
            image.planes[index] = .{ .fd = plane.fd, .offset = plane.offset, .stride = plane.stride };
        }
        var rects: [16]palette.gpu.TextureRect = undefined;
        const count = @min(frame.damage.len, rects.len);
        for (frame.damage[0..count], 0..) |rect, index| {
            rects[index] = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
        }
        // More rects than fit: repaint the whole frame.
        const damage: []const palette.gpu.TextureRect = if (frame.damage.len > rects.len) &.{} else rects[0..count];
        const key = palette.gpu.Renderer.dmabufKey(frame.planes[0].fd);
        const id = if (texture_id == 0) renderer.nextTextureId() else texture_id;
        _ = try renderer.gfx.importDmabufTexture(.{
            .id = palette.TextureId.init(id),
            .image = image,
            .key = key,
            .acquire_fence = frame.acquire_fence,
            .damage = damage,
        });
        return .{ .texture_id = id, .key = key };
    }

    fn dmabufReleaseFenceCallback(context: ?*anyopaque, key: u64) c_int {
        if (comptime !dmabuf_supported) return -1;
        return fromContext(context).gfx.dmabufReleaseFence(key);
    }

    fn forgetDmabufCallback(context: ?*anyopaque, key: u64) void {
        if (comptime !dmabuf_supported) return;
        fromContext(context).gfx.releaseDmabuf(key);
    }

    /// Draws `texture_id` 1:1 into an offscreen target and reads it back.
    fn readbackTextureCallback(context: ?*anyopaque, allocator: std.mem.Allocator, texture_id: c_uint, width: u32, height: u32) anyerror!browser_texture.CopiedFrame {
        if (comptime !dmabuf_supported) return error.GpuTextureUnavailable;
        const renderer = fromContext(context);
        if (width == 0 or height == 0) return error.GpuTextureUnavailable;
        var offscreen = try palette.gpu.Offscreen.init(renderer.gfx.renderer, width, height);
        defer offscreen.deinit();
        var batch: palette.RenderBatch = .{};
        defer batch.deinit(allocator);
        const w: f32 = @floatFromInt(width);
        const h: f32 = @floatFromInt(height);
        try batch.image(allocator, .{ .x = 0, .y = 0, .w = w, .h = h }, palette.TextureId.init(texture_id), .{ .w = 1, .h = 1 }, palette.Color.white, null);
        _ = try offscreen.render(&batch, .{ .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 } });
        const pixels = try allocator.alloc(u8, @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        try offscreen.readRgba(pixels);
        // XR24 frames carry undefined alpha; the page is opaque.
        var alpha: usize = 3;
        while (alpha < pixels.len) : (alpha += 4) pixels[alpha] = 255;
        return .{ .width = width, .height = height, .format = .rgba, .pixels = pixels };
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
