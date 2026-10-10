//! High-level glue between the platform layer (Wayland / AppKit / Win32 windows), the GPU
//! renderer (Vulkan / Metal / Direct3D 11) and the font engine.
//!
//! * `Graphics` is shared by every window of a process: one `gpu.Context`, one
//!   `gpu.Renderer` (pipeline, glyph atlases, textures) and one `fonts.Fonts`
//!   (`font.Collection` with Verde's role chains).
//! * `WindowRenderer` (alias `palette.Surface`) belongs to one `platform.Window`. It owns the
//!   window's dma-buf render targets, imports each of them into the compositor once, and runs
//!   the present loop (Wayland; the macOS variant is described at `MetalWindowRenderer`, the
//!   Windows one, a DXGI flip-model swapchain, in `app_win32.zig`):
//!     1. pick a buffer the compositor released (no roundtrip: `wl_buffer.release` only flips
//!        a flag in the platform layer, which is mirrored into `gpu.DmabufTargets` here),
//!     2. render the batch (damage-tracked; an unchanged batch submits nothing),
//!     3. present with damage rects and request a frame callback,
//!     4. throttle until that callback arrives, or until `frame_timeout_ms` passes (hidden or
//!        locked surfaces get no callbacks, so it never blocks on one).
//!
//! Typical loop:
//!
//! ```zig
//! const gfx = try palette.Graphics.init(gpa, app, .{ .fonts = set, .font_options = .{ .io = io } });
//! var wr = try palette.WindowRenderer.init(gfx, window, .{});
//! var dirty = true;
//! while (true) {
//!     var ev: palette.Event = undefined;
//!     if (app.waitEvent(&ev, wr.timeoutNs(dirty))) {
//!         if (wr.handleEvent(ev)) dirty = true;
//!         // ... feed components, set dirty when they change ...
//!     }
//!     if (dirty) {
//!         build(&batch); palette.scaleBatch(&batch, wr.scale());
//!         switch (try wr.render(&batch, clear)) {
//!             .presented, .unchanged, .hidden => dirty = false,
//!             .throttled, .no_buffer => {}, // retry after timeoutNs(true)
//!         }
//!     }
//! }
//! ```
const std = @import("std");
const draw = @import("draw.zig");
const event = @import("event.zig");
const platform = @import("platform/root.zig");
const gpu = @import("gpu/root.zig");
const font = @import("font/root.zig");
const fonts_mod = @import("fonts.zig");
const text_layout = @import("text_layout.zig");

const present = platform.present;
const clock = @import("clock.zig");

pub const GraphicsOptions = struct {
    /// Faces for the shared collection (see `fonts.FaceSet.fromDir`). Ignored if `fonts_in`
    /// is set.
    fonts: fonts_mod.FaceSet = .{},
    font_options: fonts_mod.Options = .{},
    /// Use an existing font set (not owned).
    fonts_in: ?*fonts_mod.Fonts = null,
    renderer: gpu.RendererOptions = .{},
    context: gpu.ContextOptions = .{},
};

pub const Graphics = struct {
    gpa: std.mem.Allocator,
    ctx: *gpu.Context,
    renderer: *gpu.Renderer,
    fonts: *fonts_mod.Fonts,
    owns_fonts: bool,
    /// Compositor dma-buf feedback (format/modifier pairs), copied from the app.
    feedback: present.DmabufFeedback = .{},

    /// `app` may be null for offscreen-only use.
    pub fn init(gpa: std.mem.Allocator, app: ?*platform.App, options: GraphicsOptions) !*Graphics {
        const self = try gpa.create(Graphics);
        errdefer gpa.destroy(self);

        const f = options.fonts_in orelse try fonts_mod.Fonts.init(gpa, options.fonts, options.font_options);
        errdefer if (options.fonts_in == null) f.deinit();

        var copts = options.context;
        var feedback: present.DmabufFeedback = .{};
        if (comptime gpu.backend_kind == .vulkan) {
            if (app) |a| {
                feedback = a.dmabufFeedback();
                if (copts.preferred_device == null) copts.preferred_device = feedback.main_device;
            }
        }
        const ctx = try gpu.Context.init(gpa, copts);
        errdefer ctx.deinit();

        var ropts = options.renderer;
        ropts.glyph_source = gpu.GlyphSource.adapt(font.Collection, f.collection);
        // Measurement and drawing must use the same text scale (see fonts.zig).
        ropts.text_scale = f.text_scale;
        const r = try gpu.Renderer.init(gpa, ctx, ropts);

        self.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .renderer = r,
            .fonts = f,
            .owns_fonts = options.fonts_in == null,
            .feedback = feedback,
        };
        return self;
    }

    pub fn deinit(self: *Graphics) void {
        self.renderer.deinit();
        self.ctx.deinit();
        if (self.owns_fonts) self.fonts.deinit();
        self.gpa.destroy(self);
    }

    /// Component metrics measured with the shared font engine (see `fonts.Fonts.metrics`).
    pub fn metrics(self: *Graphics, role: draw.FontRole, font_size: f32, line_height: ?f32) text_layout.FontMetrics {
        return self.fonts.metrics(role, font_size, line_height);
    }

    pub fn uploadTexture(self: *Graphics, id: u32, width: u32, height: u32, format: gpu.TextureFormat, pixels: []const u8) !void {
        return self.renderer.uploadTexture(id, width, height, format, pixels);
    }

    /// Streaming update for frequently changing images (browser frames): no mips, the image
    /// and staging memory are reused, optional dirty rectangles. See `gpu.Renderer.streamTexture`.
    pub fn streamTexture(self: *Graphics, id: u32, width: u32, height: u32, format: gpu.TextureFormat, pixels: []const u8, options: gpu.StreamOptions) !void {
        return self.renderer.streamTexture(id, width, height, format, pixels, options);
    }
};

pub const Outcome = enum {
    /// Rendered and committed; a frame callback was requested.
    presented,
    /// The batch equals what the screen already shows: nothing was submitted or committed.
    unchanged,
    /// Waiting for the previous frame's callback (or its timeout). Retry after `timeoutNs`.
    throttled,
    /// Every buffer is still held by the compositor. Retry after `timeoutNs`.
    no_buffer,
    /// The window is hidden (`Window.hide`); nothing was rendered. `handleEvent` returns
    /// true for the `window_shown` that ends this, and the next render repaints fully.
    hidden,
};

pub const WindowOptions = struct {
    /// 2 (double buffering) or 3.
    buffers: u8 = 2,
    @"opaque": bool = true,
    /// Present without a frame callback once this much time passed since the last present
    /// (hidden surfaces never get callbacks). 0 disables frame-callback pacing.
    frame_timeout_ms: u32 = 100,
    /// Polling interval while every buffer is held by the compositor.
    buffer_retry_ms: u32 = 2,
    force_linear: bool = false,
};

/// Counters of a window's present loop.
pub const WindowStats = struct {
    presented: u64 = 0,
    unchanged: u64 = 0,
    throttled: u64 = 0,
    no_buffer: u64 = 0,
    frame_timeouts: u64 = 0,
    resizes: u64 = 0,
    /// Windows only: frames dropped because the window was occluded (always 0 elsewhere).
    occluded: u64 = 0,
};

/// The present loop for the platform's windows: dma-buf buffers on Wayland, a CAMetalLayer
/// on macOS, a DXGI flip-model swapchain on Windows. Same public API on all three.
pub const WindowRenderer = switch (gpu.backend_kind) {
    .vulkan => DmabufWindowRenderer,
    .metal => MetalWindowRenderer,
    .d3d11 => @import("app_win32.zig").WindowRenderer,
};

pub const DmabufWindowRenderer = struct {
    gfx: *Graphics,
    window: *platform.Window,
    options: WindowOptions,
    targets: gpu.DmabufTargets,
    ids: [3]present.BufferId = @splat(.invalid),
    awaiting_frame: bool = false,
    last_present_ns: u64 = 0,
    pending_size: ?[2]u32 = null,
    blocked_on_buffer: bool = false,
    /// Repaint everything next frame (after the surface was unmapped).
    force_full: bool = false,
    damage_buf: [16]present.DamageRect = undefined,
    stats: Stats = .{},
    last_frame: gpu.FrameStats = .{},

    pub const Stats = WindowStats;

    pub fn init(gfx: *Graphics, window: *platform.Window, options: WindowOptions) !DmabufWindowRenderer {
        const px = window.pixelSize();
        var self: DmabufWindowRenderer = .{
            .gfx = gfx,
            .window = window,
            .options = options,
            .targets = try gpu.DmabufTargets.init(gfx.renderer, px.width, px.height, .{
                .count = options.buffers,
                .@"opaque" = options.@"opaque",
                .feedback = gfx.feedback,
                .force_linear = options.force_linear,
            }),
        };
        errdefer self.targets.deinit();
        try self.importAll();
        return self;
    }

    pub fn deinit(self: *DmabufWindowRenderer) void {
        self.destroyBuffers();
        self.targets.deinit();
    }

    fn importAll(self: *DmabufWindowRenderer) !void {
        for (self.targets.targets[0..self.targets.count], 0..) |*t, i| {
            const id = try self.window.importDmabuf(self.targets.exported(t));
            self.ids[i] = id;
            t.user_data = @intFromEnum(id);
            t.busy = false;
        }
    }

    fn destroyBuffers(self: *DmabufWindowRenderer) void {
        for (&self.ids) |*id| {
            if (id.* != .invalid) self.window.destroyBuffer(id.*);
            id.* = .invalid;
        }
    }

    /// Feeds a platform event. Returns true when the window needs a redraw (resize / scale
    /// change). A `frame` event only lifts the throttle (returns false): render if dirty.
    pub fn handleEvent(self: *DmabufWindowRenderer, ev: event.Event) bool {
        switch (ev) {
            .resized => |r| {
                if (r.window != self.window.id) return false;
                const w: u32 = @intCast(@max(r.pixel_width, 1));
                const h: u32 = @intCast(@max(r.pixel_height, 1));
                if (w != self.targets.width or h != self.targets.height) self.pending_size = .{ w, h };
                return true;
            },
            .frame => |f| {
                if (f.window == self.window.id) self.awaiting_frame = false;
                return false;
            },
            .window_shown => |v| {
                if (v.window != self.window.id) return false;
                // An unmapped surface lost its contents; a suspended one kept them, but the
                // compositor may have dropped our buffers' damage history either way.
                self.force_full = true;
                self.awaiting_frame = false;
                return true;
            },
            else => return false,
        }
    }

    pub fn scale(self: *const DmabufWindowRenderer) f32 {
        return self.window.scale();
    }

    /// How long the host may block in `waitEvent` before calling `render` again. Null when
    /// not dirty (block until an event). 0 when rendering is possible right now.
    pub fn timeoutNs(self: *const DmabufWindowRenderer, dirty: bool) ?u64 {
        if (!dirty) return null;
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            const due = self.last_present_ns + @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms;
            const now = monotonicNs();
            return if (due > now) due - now else 0;
        }
        if (self.blocked_on_buffer) return @as(u64, self.options.buffer_retry_ms) * std.time.ns_per_ms;
        return 0;
    }

    /// True when `render` would do work right now: not throttled by frame pacing and a
    /// buffer is free. Lets hosts skip building a batch that could not be shown yet.
    pub fn ready(self: *DmabufWindowRenderer) bool {
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            if (monotonicNs() - self.last_present_ns < @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms) return false;
        }
        if (self.pending_size != null) return true;
        self.syncReleases();
        self.blocked_on_buffer = self.targets.acquire() == null;
        return !self.blocked_on_buffer;
    }

    /// Mirrors wl_buffer.release into the GPU targets (a flag check per buffer).
    fn syncReleases(self: *DmabufWindowRenderer) void {
        for (self.targets.targets[0..self.targets.count], 0..) |*t, i| {
            if (t.busy and self.window.bufferReleased(self.ids[i])) self.targets.release(t);
        }
    }

    /// Renders `batch` (device pixels; see `scaleBatch`) and presents it.
    pub fn render(self: *DmabufWindowRenderer, batch: *const draw.RenderBatch, clear: draw.Color) !Outcome {
        if (!self.window.isVisible()) return .hidden;
        if (self.pending_size) |sz| {
            self.pending_size = null;
            try self.applyResize(sz[0], sz[1]);
        }
        if (self.awaiting_frame) {
            if (self.options.frame_timeout_ms == 0) {
                self.awaiting_frame = false;
            } else if (monotonicNs() - self.last_present_ns >= @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms) {
                self.awaiting_frame = false;
                self.stats.frame_timeouts += 1;
            } else {
                self.stats.throttled += 1;
                return .throttled;
            }
        }
        self.syncReleases();
        const t = self.targets.acquire() orelse {
            self.blocked_on_buffer = true;
            self.stats.no_buffer += 1;
            return .no_buffer;
        };
        self.blocked_on_buffer = false;
        const res = try self.targets.render(t, batch, .{ .clear = clear, .force_full = self.force_full });
        self.force_full = false;
        self.last_frame = res.stats;
        if (res.stats.skipped) {
            self.stats.unchanged += 1;
            return .unchanged;
        }
        var rects: []const present.DamageRect = &.{};
        if (!res.stats.full_redraw and res.damage.len <= self.damage_buf.len) {
            for (res.damage, 0..) |d, i| self.damage_buf[i] = .{ .x = d.x, .y = d.y, .w = d.w, .h = d.h };
            rects = self.damage_buf[0..res.damage.len];
        }
        const id: present.BufferId = @enumFromInt(@as(u32, @intCast(t.user_data)));
        if (self.options.frame_timeout_ms > 0) self.window.requestFrame();
        try self.window.present(id, rects);
        self.awaiting_frame = self.options.frame_timeout_ms > 0;
        self.last_present_ns = monotonicNs();
        self.stats.presented += 1;
        return .presented;
    }

    fn applyResize(self: *DmabufWindowRenderer, w: u32, h: u32) !void {
        if (w == self.targets.width and h == self.targets.height) return;
        self.destroyBuffers();
        try self.targets.resize(w, h);
        try self.importAll();
        self.stats.resizes += 1;
    }

    /// Bytes of GPU memory held by this window's buffers.
    pub fn bufferBytes(self: *const DmabufWindowRenderer) u64 {
        var n: u64 = 0;
        for (self.targets.targets[0..self.targets.count]) |t| n += t.memory.size;
        return n;
    }
};

/// macOS: one CAMetalLayer per window (the platform view's backing layer).
///
/// * The window keeps a persistent private backbuffer: damage-tracked partial redraws only
///   touch the changed rects, then the whole backbuffer is blitted into the layer's next
///   drawable and presented in the same command buffer (`gpu.metal.LayerTarget`).
/// * Pacing: after each present `Window.requestFrame` unpauses the view's display link; its
///   next vsync tick posts a `frame` event, which lifts the throttle (as a Wayland frame
///   callback does). With nothing dirty the link stays paused and the loop blocks in
///   `waitEvent`: 0% CPU when idle. Occluded windows get no ticks; `frame_timeout_ms`
///   bounds the wait, like hidden Wayland surfaces.
/// * Retina: the drawable size is the view's backing size (points x backingScaleFactor);
///   `resized` events carry it and are applied before the next frame.
/// * `buffers`, `force_linear` and `buffer_retry_ms` do not apply (CoreAnimation owns the
///   drawable pool); `.no_buffer` is never returned.
pub const MetalWindowRenderer = struct {
    gfx: *Graphics,
    window: *platform.Window,
    options: WindowOptions,
    layer: gpu.metal.LayerTarget,
    awaiting_frame: bool = false,
    last_present_ns: u64 = 0,
    pending_size: ?[2]u32 = null,
    force_full: bool = false,
    stats: Stats = .{},
    last_frame: gpu.FrameStats = .{},

    pub const Stats = WindowStats;

    pub fn init(gfx: *Graphics, window: *platform.Window, options: WindowOptions) !MetalWindowRenderer {
        const layer = window.nativeHandles().metal_layer orelse return error.NoMetalLayer;
        const px = window.pixelSize();
        return .{
            .gfx = gfx,
            .window = window,
            .options = options,
            .layer = try gpu.metal.LayerTarget.init(gfx.renderer, layer, px.width, px.height, .{ .@"opaque" = options.@"opaque" }),
        };
    }

    pub fn deinit(self: *MetalWindowRenderer) void {
        self.layer.deinit();
    }

    /// Feeds a platform event. Returns true when the window needs a redraw (resize / scale
    /// change / shown). A `frame` event only lifts the throttle (returns false).
    pub fn handleEvent(self: *MetalWindowRenderer, ev: event.Event) bool {
        switch (ev) {
            .resized => |r| {
                if (r.window != self.window.id) return false;
                const w: u32 = @intCast(@max(r.pixel_width, 1));
                const h: u32 = @intCast(@max(r.pixel_height, 1));
                if (w != self.layer.width() or h != self.layer.height()) self.pending_size = .{ w, h };
                return true;
            },
            .frame => |f| {
                if (f.window == self.window.id) self.awaiting_frame = false;
                return false;
            },
            .window_shown => |v| {
                if (v.window != self.window.id) return false;
                self.force_full = true;
                self.awaiting_frame = false;
                return true;
            },
            else => return false,
        }
    }

    pub fn scale(self: *const MetalWindowRenderer) f32 {
        return self.window.scale();
    }

    pub fn timeoutNs(self: *const MetalWindowRenderer, dirty: bool) ?u64 {
        if (!dirty) return null;
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            const due = self.last_present_ns + @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms;
            const now = monotonicNs();
            return if (due > now) due - now else 0;
        }
        return 0;
    }

    pub fn ready(self: *MetalWindowRenderer) bool {
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            if (monotonicNs() - self.last_present_ns < @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms) return false;
        }
        return true;
    }

    /// Renders `batch` (device pixels; see `scaleBatch`) and presents it.
    pub fn render(self: *MetalWindowRenderer, batch: *const draw.RenderBatch, clear: draw.Color) !Outcome {
        if (!self.window.isVisible()) return .hidden;
        if (self.pending_size) |sz| {
            self.pending_size = null;
            if (sz[0] != self.layer.width() or sz[1] != self.layer.height()) {
                try self.layer.resize(sz[0], sz[1]);
                self.stats.resizes += 1;
            }
        }
        if (self.awaiting_frame) {
            if (self.options.frame_timeout_ms == 0) {
                self.awaiting_frame = false;
            } else if (monotonicNs() - self.last_present_ns >= @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms) {
                self.awaiting_frame = false;
                self.stats.frame_timeouts += 1;
            } else {
                self.stats.throttled += 1;
                return .throttled;
            }
        }
        const res = try self.layer.render(batch, .{ .clear = clear, .force_full = self.force_full });
        self.force_full = false;
        self.last_frame = res.stats;
        if (res.stats.skipped) {
            self.stats.unchanged += 1;
            return .unchanged;
        }
        if (self.options.frame_timeout_ms > 0) self.window.requestFrame();
        self.awaiting_frame = self.options.frame_timeout_ms > 0;
        self.last_present_ns = monotonicNs();
        self.stats.presented += 1;
        return .presented;
    }

    /// Bytes of GPU memory held for this window: the backbuffer plus the layer's drawable
    /// pool (CoreAnimation keeps up to 3 drawables of the same size).
    pub fn bufferBytes(self: *const MetalWindowRenderer) u64 {
        const one = @as(u64, self.layer.width()) * self.layer.height() * 4;
        return one * 4;
    }
};

/// Scales a logical-unit batch to device pixels in place (HiDPI). No-op at 1.0.
pub fn scaleBatch(batch: *draw.RenderBatch, s: f32) void {
    if (s == 1.0) return;
    for (batch.commands.items) |*cmd| {
        cmd.rect = scaleRect(cmd.rect, s);
        cmd.p0 = .{ .x = cmd.p0.x * s, .y = cmd.p0.y * s };
        cmd.p1 = .{ .x = cmd.p1.x * s, .y = cmd.p1.y * s };
        cmd.p2 = .{ .x = cmd.p2.x * s, .y = cmd.p2.y * s };
        if (cmd.clip) |c| cmd.clip = scaleRect(c, s);
        cmd.scroll = .{ .x = cmd.scroll.x * s, .y = cmd.scroll.y * s };
        cmd.font_size *= s;
        cmd.glyph_width *= s;
        cmd.line_height *= s;
        cmd.radius *= s;
        cmd.border_width *= s;
    }
    for (batch.text_runs.items) |*run| {
        run.x *= s;
        run.y *= s;
        run.font_size *= s;
        run.line_height *= s;
        if (run.clip) |c| run.clip = scaleRect(c, s);
    }
}

fn scaleRect(r: draw.Rect, s: f32) draw.Rect {
    return .{ .x = r.x * s, .y = r.y * s, .w = r.w * s, .h = r.h * s };
}

fn monotonicNs() u64 {
    return clock.monotonicTimestampNs();
}

test "scaleBatch scales geometry and text" {
    const gpa = std.testing.allocator;
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try batch.rect(gpa, .{ .x = 10, .y = 20, .w = 30, .h = 40 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    scaleBatch(&batch, 2);
    const r = batch.commands.items[0].rect;
    try std.testing.expectEqual(@as(f32, 20), r.x);
    try std.testing.expectEqual(@as(f32, 80), r.h);
}
