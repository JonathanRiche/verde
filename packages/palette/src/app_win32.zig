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

// -- live test (Windows only; under Wine via tools/wine-zig.sh with the null display driver,
// so the window exists only inside the test process) -------------------------------------

const testing = std.testing;
const win32 = @import("platform/windows/win32.zig");

fn waitFor(a: *platform.App, wr: *WindowRenderer, comptime tag: std.meta.Tag(event.Event), budget_ms: u32) !event.Event {
    const deadline = clock.monotonicTimestampNs() + @as(u64, budget_ms) * std.time.ns_per_ms;
    while (clock.monotonicTimestampNs() < deadline) {
        var ev: event.Event = undefined;
        if (a.waitEvent(&ev, 10 * std.time.ns_per_ms)) {
            _ = wr.handleEvent(ev);
            if (ev == tag) return ev;
        }
    }
    return error.Timeout;
}

test "Windows WindowRenderer: swapchain present, unchanged skip, frame pacing, resize, input via own HWND" {
    if (comptime @import("builtin").os.tag != .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const a = try platform.App.init(gpa, .{ .app_id = "palette-test-swapchain" });
    defer a.deinit();
    const win = try a.createWindow(.{ .title = "palette-test-swapchain", .width = 160, .height = 120 });
    defer win.destroy();
    // Every system cursor loads (odd MAKEINTRESOURCE ids such as IDC_HAND once tripped the
    // pointer alignment check).
    inline for (@typeInfo(platform.CursorShape).@"enum".fields) |f| win.setCursor(@field(platform.CursorShape, f.name));
    const gfx = app.Graphics.init(gpa, a, .{ .fonts = .{ .ui = .{ .path = "../assets/fonts/NotoSans-Regular.ttf" } }, .font_options = .{ .io = testing.io } }) catch |err| switch (err) {
        error.NoSuitableGpu => return error.SkipZigTest,
        else => return err,
    };
    defer gfx.deinit();
    var wr = try WindowRenderer.init(gfx, win, .{});
    defer wr.deinit();
    try testing.expect(wr.swapchain.waitable != null);

    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try batch.rect(gpa, .{ .x = 10, .y = 10, .w = 50, .h = 40 }, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    const bg: draw.Color = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1 };

    try testing.expectEqual(app.Outcome.presented, try wr.render(&batch, bg));
    try testing.expect(wr.last_frame.full_redraw);
    // Throttled until the frame-latency waitable fires a `frame` event.
    try testing.expectEqual(app.Outcome.throttled, try wr.render(&batch, bg));
    _ = try waitFor(a, &wr, .frame, 2000);
    // Second buffer has never shown this batch: rendered once more, then unchanged.
    var unchanged = false;
    for (0..4) |_| {
        const o = try wr.render(&batch, bg);
        if (o == .unchanged) {
            unchanged = true;
            break;
        }
        if (o == .presented) _ = try waitFor(a, &wr, .frame, 2000);
    }
    try testing.expect(unchanged);

    // Partial redraw: move the rect; damage is a small region, not the whole buffer.
    batch.clear();
    try batch.rect(gpa, .{ .x = 20, .y = 10, .w = 50, .h = 40 }, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
    var partial = false;
    for (0..4) |_| {
        const o = try wr.render(&batch, bg);
        if (o == .presented) {
            if (!wr.last_frame.full_redraw) partial = true;
            _ = try waitFor(a, &wr, .frame, 2000);
        }
    }
    try testing.expect(partial);

    // Resize through our own HWND (SetWindowPos): `resized` -> ResizeBuffers on next render.
    const hwnd: win32.HWND = @ptrCast(win.nativeHandles().hwnd);
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 400, 300, win32.SWP_NOMOVE | win32.SWP_NOZORDER | 0x0010); // SWP_NOACTIVATE
    const rz = try waitFor(a, &wr, .resized, 2000);
    try testing.expect(rz.resized.pixel_width > 0);
    wr.awaiting_frame = false;
    try testing.expectEqual(app.Outcome.presented, try wr.render(&batch, bg));
    try testing.expectEqual(@as(u32, @intCast(rz.resized.pixel_width)), wr.swapchain.width);
    try testing.expectEqual(@as(u64, 1), wr.stats.resizes);
    try testing.expect(wr.last_frame.full_redraw);

    // Input posted to our own window (never into the user's session).
    _ = win32.PostMessageW(hwnd, win32.WM_MOUSEMOVE, 0, (@as(isize, 30) << 16) | 40);
    const mv = try waitFor(a, &wr, .mouse_motion, 2000);
    try testing.expect(mv.mouse_motion.x > 0);
    _ = win32.PostMessageW(hwnd, win32.WM_KEYDOWN, 0x41, 1 | (0x1E << 16)); // 'A', scancode 0x1E
    const kd = try waitFor(a, &wr, .key_down, 2000);
    try testing.expectEqual(@as(u32, 30), kd.key_down.scancode);
}
