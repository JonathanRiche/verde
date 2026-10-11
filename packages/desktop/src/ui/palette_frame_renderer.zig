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

var stats_path_state: enum { unknown, unset, set } = .unknown;
var stats_path_value: [:0]const u8 = "";

fn statsPath() ?[:0]const u8 {
    if (stats_path_state == .unknown) {
        stats_path_state = .unset;
        if (std.c.getenv("VERDE_PALETTE_STATS")) |value| {
            stats_path_value = std.mem.span(value);
            if (stats_path_value.len > 0) stats_path_state = .set;
        }
    }
    return if (stats_path_state == .set) stats_path_value else null;
}

/// Frames the main loop handed to the renderer, by path.
pub const FrameCounters = struct {
    /// Full UI rebuild (renderRoot) frames that settled.
    full: u64 = 0,
    /// Browser-texture-only frames: the previous batch replayed with new
    /// browser contents, no UI layout.
    texture_only: u64 = 0,
};

/// The last laid-out frame, kept while a browser pane is visible so that a
/// frame whose only change is new browser texture contents can be presented
/// by replaying it: no UI layout, text measurement or batch building. The
/// browser image samples the pane texture by id, so the replay picks up the
/// newly bound dma-buf (or streamed) frame, and the renderer's damage
/// tracking repaints and presents only the browser rect (plus anything drawn
/// above it, so overlays stay composited).
///
/// The batch is a deep copy (texts live in `text`), so state changes after
/// the layout cannot leave it pointing at freed strings.
pub const RetainedFrame = struct {
    batch: palette.RenderBatch = .{},
    text: std.heap.ArenaAllocator,
    valid: bool = false,
    framebuffer_width: c_int = 0,
    framebuffer_height: c_int = 0,
    ui_scale: f32 = 0,
    /// Pane texture the batch's browser image samples.
    browser_texture_id: u32 = 0,
    /// The browser image's visible rect, inset by `pointer_inset`; null when
    /// something is drawn above any part of it (menus, tooltips, toasts), so
    /// pointer motion there may change Verde UI.
    pointer_rect: ?palette.Rect = null,
    /// Pointer position the batch was laid out for.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    built_ms: i64 = 0,
    /// `loop_wakeup.layoutSequence()` sampled before the layout.
    layout_sequence: u64 = 0,

    /// Pane borders and focus rings straddle the image edge; ignore them.
    const pointer_inset: f32 = 4.0;
    /// Replays stop after this long, so state that changed without
    /// requesting a frame still reaches the screen promptly.
    pub const max_age_ms: i64 = 1000;

    pub const Layout = struct {
        framebuffer_width: c_int,
        framebuffer_height: c_int,
        ui_scale: f32,
        browser_texture_id: u32,
        mouse_x: f32,
        mouse_y: f32,
        now_ms: i64,
        layout_sequence: u64,
    };

    pub fn init(allocator: std.mem.Allocator) RetainedFrame {
        return .{ .text = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *RetainedFrame, allocator: std.mem.Allocator) void {
        self.batch.deinit(allocator);
        self.text.deinit();
        self.* = undefined;
    }

    pub fn invalidate(self: *RetainedFrame) void {
        self.valid = false;
    }

    /// Copies `source` (the frame just presented). Stays invalid when the
    /// batch does not draw `layout.browser_texture_id`.
    pub fn capture(self: *RetainedFrame, allocator: std.mem.Allocator, source: *const palette.RenderBatch, layout: Layout) void {
        self.valid = false;
        if (layout.browser_texture_id == 0) return;
        const image_index = findImage(source, layout.browser_texture_id) orelse return;
        self.batch.clear();
        _ = self.text.reset(.retain_capacity);
        self.batch.appendStableBatch(allocator, self.text.allocator(), source) catch return;
        self.pointer_rect = pointerRect(source, image_index);
        self.framebuffer_width = layout.framebuffer_width;
        self.framebuffer_height = layout.framebuffer_height;
        self.ui_scale = layout.ui_scale;
        self.browser_texture_id = layout.browser_texture_id;
        self.mouse_x = layout.mouse_x;
        self.mouse_y = layout.mouse_y;
        self.built_ms = layout.now_ms;
        self.layout_sequence = layout.layout_sequence;
        self.valid = true;
    }

    /// Whether the retained batch still shows what a rebuild would draw,
    /// apart from the browser texture contents.
    pub fn canReplay(self: *const RetainedFrame, current: Layout) bool {
        if (!self.valid) return false;
        if (current.framebuffer_width != self.framebuffer_width or current.framebuffer_height != self.framebuffer_height) return false;
        if (@abs(current.ui_scale - self.ui_scale) > 0.001) return false;
        if (current.browser_texture_id == 0 or current.browser_texture_id != self.browser_texture_id) return false;
        if (current.layout_sequence != self.layout_sequence) return false;
        if (current.now_ms < self.built_ms or current.now_ms - self.built_ms >= max_age_ms) return false;
        return true;
    }

    /// True when both the laid-out and the current pointer position are over
    /// the browser page with nothing drawn above it: pointer input there only
    /// reaches the page (WebKit), not Verde's hover state.
    pub fn pointerStaysInBrowser(self: *const RetainedFrame, mouse_x: f32, mouse_y: f32) bool {
        if (!self.valid) return false;
        const r = self.pointer_rect orelse return false;
        return rectContains(r, self.mouse_x, self.mouse_y) and rectContains(r, mouse_x, mouse_y);
    }

    fn findImage(batch: *const palette.RenderBatch, texture_id: u32) ?usize {
        for (batch.commands.items, 0..) |command, index| {
            if (command.kind == .image and command.texture.value == texture_id) return index;
        }
        return null;
    }

    fn pointerRect(batch: *const palette.RenderBatch, image_index: usize) ?palette.Rect {
        const image = batch.commands.items[image_index];
        const visible = visibleRect(image) orelse return null;
        const inset: palette.Rect = .{
            .x = visible.x + pointer_inset,
            .y = visible.y + pointer_inset,
            .w = visible.w - pointer_inset * 2,
            .h = visible.h - pointer_inset * 2,
        };
        if (inset.w <= 0 or inset.h <= 0) return null;
        // Commands are z-sorted: everything after the image draws above it.
        for (batch.commands.items[image_index + 1 ..]) |command| {
            const above = visibleRect(command) orelse continue;
            if (intersects(above, inset)) return null;
        }
        return inset;
    }

    fn visibleRect(command: palette.draw.Command) ?palette.Rect {
        var r = command.rect;
        if (command.kind == .triangle) {
            const min_x = @min(command.p0.x, @min(command.p1.x, command.p2.x));
            const min_y = @min(command.p0.y, @min(command.p1.y, command.p2.y));
            const max_x = @max(command.p0.x, @max(command.p1.x, command.p2.x));
            const max_y = @max(command.p0.y, @max(command.p1.y, command.p2.y));
            r = .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
        }
        if (command.clip) |clip| r = intersection(r, clip) orelse return null;
        if (r.w <= 0 or r.h <= 0) return null;
        return r;
    }

    fn intersection(a: palette.Rect, b: palette.Rect) ?palette.Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    fn intersects(a: palette.Rect, b: palette.Rect) bool {
        return intersection(a, b) != null;
    }

    fn rectContains(r: palette.Rect, x: f32, y: f32) bool {
        return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
    }
};

pub const Renderer = struct {
    gfx: *palette.Graphics,
    wr: palette.WindowRenderer,
    next_texture_id: u32 = 1,
    counters: FrameCounters = .{},
    last_stats_write_ns: u64 = 0,

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

    /// Dev hook for perf trials: with `VERDE_PALETTE_STATS=/path`, appends one
    /// line per second with the present loop counters, frames by path and the
    /// renderer's GPU memory, so a driver can compute frames/s on hidden outputs.
    pub fn maybeWriteDevStats(self: *Renderer, now_ns: u64) void {
        if (comptime @import("builtin").os.tag == .windows) return;
        const path = statsPath() orelse return;
        if (self.last_stats_write_ns != 0 and now_ns -% self.last_stats_write_ns < std.time.ns_per_s) return;
        self.last_stats_write_ns = now_ns;
        const ws = self.wr.stats;
        const memory = self.gpuMemory();
        var line_buffer: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "t_ms={d} presented={d} unchanged={d} throttled={d} no_buffer={d} frame_timeouts={d} full={d} texture_only={d} gpu_device_bytes={d} gpu_host_bytes={d} window_buffer_bytes={d}\n", .{
            now_ns / std.time.ns_per_ms,
            ws.presented,
            ws.unchanged,
            ws.throttled,
            ws.no_buffer,
            ws.frame_timeouts,
            self.counters.full,
            self.counters.texture_only,
            memory.device_local_bytes,
            memory.host_visible_bytes,
            memory.window_buffer_bytes,
        }) catch return;
        const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, line.ptr, line.len);
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

fn testLayout(texture_id: u32, now_ms: i64) RetainedFrame.Layout {
    return .{
        .framebuffer_width = 800,
        .framebuffer_height = 600,
        .ui_scale = 1.25,
        .browser_texture_id = texture_id,
        .mouse_x = 500,
        .mouse_y = 300,
        .now_ms = now_ms,
        .layout_sequence = 7,
    };
}

test "retained frame replays only while the layout inputs are unchanged" {
    const allocator = std.testing.allocator;
    var source: palette.RenderBatch = .{};
    defer source.deinit(allocator);
    const white: palette.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    var label = [_]u8{ 'h', 'i' };
    try source.rect(allocator, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, white);
    try source.text(allocator, .{ .x = 10, .y = 10, .w = 100, .h = 20 }, &label, white, 14, null);
    try source.image(allocator, .{ .x = 400, .y = 100, .w = 300, .h = 400 }, palette.TextureId.init(9), .{ .w = 1, .h = 1 }, white, null);

    var retained = RetainedFrame.init(allocator);
    defer retained.deinit(allocator);
    retained.capture(allocator, &source, testLayout(9, 1000));
    try std.testing.expect(retained.valid);
    // Texts are deep copies: later edits to frame-owned strings do not leak in.
    label[0] = 'X';
    try std.testing.expectEqualStrings("hi", retained.batch.commands.items[1].text);

    try std.testing.expect(retained.canReplay(testLayout(9, 1500)));
    try std.testing.expect(!retained.canReplay(testLayout(9, 1000 + RetainedFrame.max_age_ms)));
    try std.testing.expect(!retained.canReplay(testLayout(10, 1500)));
    var resized = testLayout(9, 1500);
    resized.framebuffer_width = 801;
    try std.testing.expect(!retained.canReplay(resized));
    var rescaled = testLayout(9, 1500);
    rescaled.ui_scale = 1.5;
    try std.testing.expect(!retained.canReplay(rescaled));
    var newer_state = testLayout(9, 1500);
    newer_state.layout_sequence = 8;
    try std.testing.expect(!retained.canReplay(newer_state));

    // Pointer over the page, laid out there too: no Verde UI changes.
    try std.testing.expect(retained.pointerStaysInBrowser(600, 200));
    // Leaving the page (or onto its border) needs a layout.
    try std.testing.expect(!retained.pointerStaysInBrowser(390, 200));
    try std.testing.expect(!retained.pointerStaysInBrowser(402, 200));

    retained.invalidate();
    try std.testing.expect(!retained.canReplay(testLayout(9, 1500)));
}

test "retained frame treats anything drawn above the browser as live UI" {
    const allocator = std.testing.allocator;
    var source: palette.RenderBatch = .{};
    defer source.deinit(allocator);
    const white: palette.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    try source.image(allocator, .{ .x = 400, .y = 100, .w = 300, .h = 400 }, palette.TextureId.init(9), .{ .w = 1, .h = 1 }, white, null);
    // A tooltip clipped away from the page does not count; one over it does.
    try source.rect(allocator, .{ .x = 450, .y = 150, .w = 50, .h = 20 }, white);
    source.commands.items[1].clip = .{ .x = 0, .y = 0, .w = 100, .h = 100 };

    var retained = RetainedFrame.init(allocator);
    defer retained.deinit(allocator);
    retained.capture(allocator, &source, testLayout(9, 1000));
    try std.testing.expect(retained.pointerStaysInBrowser(600, 200));

    try source.rect(allocator, .{ .x = 450, .y = 150, .w = 50, .h = 20 }, white);
    retained.capture(allocator, &source, testLayout(9, 1000));
    try std.testing.expect(retained.valid);
    try std.testing.expect(!retained.pointerStaysInBrowser(600, 200));

    // A frame without the browser image is never retained.
    retained.capture(allocator, &source, testLayout(11, 1000));
    try std.testing.expect(!retained.valid);
}
