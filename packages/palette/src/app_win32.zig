//! `WindowRenderer` for Windows: a DXGI flip-model swapchain on the window's HWND
//! (`gpu.d3d11.Swapchain`), same API and loop as the Wayland and macOS ones in `app.zig`.
//!
//! Present loop:
//!   1. render the batch into the current back buffer (damage-tracked per buffer age; an
//!      unchanged batch submits nothing),
//!   2. Present1 with dirty rects (vsync), request a frame,
//!   3. throttle until the swapchain's frame-latency waitable is signalled — the platform
//!      layer waits on it in `waitEvent` and emits `frame` — or `frame_timeout_ms` passes.
//!
//! Occlusion (DXGI_STATUS_OCCLUDED: minimised, covered by a fullscreen window, locked) drops
//! the frame; later renders test with DXGI_PRESENT_TEST and return `.throttled` (no GPU work)
//! until the window can be seen, then repaint fully.
const std = @import("std");
const draw = @import("draw.zig");
const event = @import("event.zig");
const platform = @import("platform/root.zig");
const gpu = @import("gpu/root.zig");
const clock = @import("clock.zig");
const app = @import("app.zig");

const Swapchain = gpu.d3d11.Swapchain;

pub const WindowRenderer = struct {
    gfx: *app.Graphics,
    window: *platform.Window,
    options: app.WindowOptions,
    swapchain: Swapchain,
    awaiting_frame: bool = false,
    last_present_ns: u64 = 0,
    pending_size: ?[2]u32 = null,
    occluded: bool = false,
    /// Repaint everything next frame (after occlusion / being hidden).
    force_full: bool = false,
    stats: Stats = .{},
    last_frame: gpu.FrameStats = .{},

    pub const Stats = app.WindowStats;

    /// Movable (the swapchain holds no self pointers). The platform window keeps the
    /// swapchain's waitable handle (registered here) until `deinit`.
    pub fn init(gfx: *app.Graphics, window: *platform.Window, options: app.WindowOptions) !WindowRenderer {
        const px = window.pixelSize();
        const sc = try Swapchain.init(gfx.renderer, window.nativeHandles().hwnd, px.width, px.height, .{
            .buffers = options.buffers,
        });
        window.setFrameWaitable(sc.waitable);
        return .{ .gfx = gfx, .window = window, .options = options, .swapchain = sc };
    }

    pub fn deinit(self: *WindowRenderer) void {
        self.window.setFrameWaitable(null);
        self.swapchain.deinit();
    }

    /// Same contract as the Wayland renderer: true when a redraw is needed.
    pub fn handleEvent(self: *WindowRenderer, ev: event.Event) bool {
        switch (ev) {
            .resized => |r| {
                if (r.window != self.window.id) return false;
                const w: u32 = @intCast(@max(r.pixel_width, 1));
                const h: u32 = @intCast(@max(r.pixel_height, 1));
                if (w != self.swapchain.width or h != self.swapchain.height) self.pending_size = .{ w, h };
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
                self.occluded = false;
                return true;
            },
            else => return false,
        }
    }

    pub fn scale(self: *const WindowRenderer) f32 {
        return self.window.scale();
    }

    pub fn timeoutNs(self: *const WindowRenderer, dirty: bool) ?u64 {
        if (!dirty) return null;
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            const due = self.last_present_ns + @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms;
            const now = clock.monotonicTimestampNs();
            return if (due > now) due - now else 0;
        }
        return 0;
    }

    pub fn ready(self: *WindowRenderer) bool {
        if (self.awaiting_frame and self.options.frame_timeout_ms > 0) {
            if (clock.monotonicTimestampNs() - self.last_present_ns < @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms) return false;
        }
        return true;
    }

    /// Renders `batch` (device pixels; see `scaleBatch`) and presents it.
    pub fn render(self: *WindowRenderer, batch: *const draw.RenderBatch, clear: draw.Color) !app.Outcome {
        if (!self.window.isVisible()) return .hidden;
        if (self.pending_size) |sz| {
            self.pending_size = null;
            if (sz[0] != self.swapchain.width or sz[1] != self.swapchain.height) {
                try self.swapchain.resize(sz[0], sz[1]);
                self.stats.resizes += 1;
            }
        }
        const now = clock.monotonicTimestampNs();
        const timeout = @as(u64, self.options.frame_timeout_ms) * std.time.ns_per_ms;
        if (self.awaiting_frame) {
            if (self.options.frame_timeout_ms == 0) {
                self.awaiting_frame = false;
            } else if (now - self.last_present_ns >= timeout) {
                self.awaiting_frame = false;
                self.stats.frame_timeouts += 1;
            } else {
                self.stats.throttled += 1;
                return .throttled;
            }
        }
        if (self.occluded) {
            if (self.swapchain.stillOccluded()) {
                // Poll again after the frame timeout (no waitable signal while occluded).
                self.last_present_ns = now;
                self.awaiting_frame = self.options.frame_timeout_ms > 0;
                self.stats.throttled += 1;
                return .throttled;
            }
            self.occluded = false;
            self.force_full = true;
        }
        const res = try self.swapchain.render(batch, .{ .clear = clear, .force_full = self.force_full });
        self.force_full = false;
        self.last_frame = res.frame.stats;
        switch (res.result) {
            .unchanged => {
                self.stats.unchanged += 1;
                return .unchanged;
            },
            .occluded => {
                self.occluded = true;
                self.stats.occluded += 1;
                self.last_present_ns = now;
                self.awaiting_frame = self.options.frame_timeout_ms > 0;
                return .throttled;
            },
            .presented => {},
        }
        if (self.options.frame_timeout_ms > 0) self.window.requestFrame();
        self.awaiting_frame = self.options.frame_timeout_ms > 0;
        self.last_present_ns = clock.monotonicTimestampNs();
        self.stats.presented += 1;
        return .presented;
    }

    /// Bytes of GPU memory held by this window's back buffers.
    pub fn bufferBytes(self: *const WindowRenderer) u64 {
        return self.swapchain.bufferBytes();
    }
};
