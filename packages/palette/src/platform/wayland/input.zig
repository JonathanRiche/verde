//! Pure pointer-input logic: click counting, wheel/touchpad scroll conversion, and the
//! per-`wl_pointer.frame` accumulator. No protocol objects here, so it is unit-testable.

const std = @import("std");
const event = @import("../../event.zig");

/// evdev button codes (linux/input-event-codes.h).
pub const BTN_LEFT = 0x110;
pub const BTN_RIGHT = 0x111;
pub const BTN_MIDDLE = 0x112;
pub const BTN_SIDE = 0x113;
pub const BTN_EXTRA = 0x114;
pub const BTN_FORWARD = 0x115;
pub const BTN_BACK = 0x116;

/// Maps an evdev button code to Palette/SDL button numbering.
pub fn mapButton(code: u32) u8 {
    return switch (code) {
        BTN_LEFT => @intFromEnum(event.MouseButton.left),
        BTN_RIGHT => @intFromEnum(event.MouseButton.right),
        BTN_MIDDLE => @intFromEnum(event.MouseButton.middle),
        BTN_SIDE, BTN_BACK => @intFromEnum(event.MouseButton.back),
        BTN_EXTRA, BTN_FORWARD => @intFromEnum(event.MouseButton.forward),
        else => if (code > BTN_LEFT and code - BTN_LEFT < 250) @intCast(code - BTN_LEFT + 1) else 0,
    };
}

pub fn setButton(state: *event.ButtonState, button: u8, down: bool) void {
    switch (button) {
        1 => state.left = down,
        2 => state.middle = down,
        3 => state.right = down,
        4 => state.back = down,
        5 => state.forward = down,
        else => {},
    }
}

/// Multi-click detection by time and distance, like SDL's (time in ms, wrapping).
pub const ClickCounter = struct {
    pub const default_interval_ms: u32 = 500;
    /// Logical pixels the pointer may move between clicks of one sequence.
    pub const default_radius: f32 = 6;

    interval_ms: u32 = default_interval_ms,
    radius: f32 = default_radius,
    last_time: u32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_button: u8 = 0,
    count: u8 = 0,

    /// Registers a press and returns its click count (1 = single, 2 = double, ...).
    pub fn press(c: *ClickCounter, button: u8, time_ms: u32, x: f32, y: f32) u8 {
        const dt = time_ms -% c.last_time;
        const near = @abs(x - c.last_x) <= c.radius and @abs(y - c.last_y) <= c.radius;
        if (c.count > 0 and button == c.last_button and dt <= c.interval_ms and near) {
            c.count +|= 1;
        } else {
            c.count = 1;
        }
        c.last_time = time_ms;
        c.last_x = x;
        c.last_y = y;
        c.last_button = button;
        return c.count;
    }

    /// Click count to report on release (the count of the press that started it).
    pub fn current(c: *const ClickCounter) u8 {
        return @max(c.count, 1);
    }

    pub fn reset(c: *ClickCounter) void {
        c.count = 0;
    }
};

pub const AxisSource = enum(u32) { wheel = 0, finger = 1, continuous = 2, wheel_tilt = 3, unknown = 0xffffffff, _ };

/// Wayland reports wheel motion in surface pixels; libinput/compositors use 15° = 10 units
/// per detent (SDL uses the same constant to convert to lines).
pub const axis_units_per_line: f64 = 10.0;

/// Accumulates axis events within one wl_pointer frame.
pub const Scroll = struct {
    value: [2]f64 = .{ 0, 0 },
    value120: [2]i32 = .{ 0, 0 },
    discrete: [2]i32 = .{ 0, 0 },
    has_value120: bool = false,
    has_discrete: bool = false,
    source: AxisSource = .unknown,
    any: bool = false,

    /// axis: 0 = vertical, 1 = horizontal (wl_pointer.axis enum).
    pub fn addValue(s: *Scroll, axis: u32, v: f64) void {
        if (axis > 1) return;
        s.value[axis] += v;
        s.any = true;
    }

    pub fn addValue120(s: *Scroll, axis: u32, v: i32) void {
        if (axis > 1) return;
        s.value120[axis] += v;
        s.has_value120 = true;
        s.any = true;
    }

    pub fn addDiscrete(s: *Scroll, axis: u32, v: i32) void {
        if (axis > 1) return;
        s.discrete[axis] += v;
        s.has_discrete = true;
        s.any = true;
    }

    pub const Lines = struct { x: f32, y: f32, precise: bool };

    /// Converts to lines with SDL's sign convention: positive y = scroll up (away from user),
    /// positive x = scroll right. Touchpads (finger/continuous) are `precise`.
    pub fn lines(s: *const Scroll) Lines {
        const precise = s.source == .finger or s.source == .continuous;
        var v: [2]f64 = undefined;
        for (0..2) |a| {
            v[a] = if (precise)
                s.value[a] / axis_units_per_line
            else if (s.has_value120)
                @as(f64, @floatFromInt(s.value120[a])) / 120.0
            else if (s.has_discrete)
                @floatFromInt(s.discrete[a])
            else
                s.value[a] / axis_units_per_line;
        }
        return .{ .x = @floatCast(v[1]), .y = @floatCast(-v[0]), .precise = precise };
    }
};

pub const max_frame_buttons = 8;

pub const FrameButton = struct { button: u8, down: bool, time: u32 };

/// Everything that happened between two wl_pointer.frame events.
pub const PointerFrame = struct {
    enter: bool = false,
    leave: bool = false,
    leave_window: u32 = 0,
    motion: bool = false,
    buttons: [max_frame_buttons]FrameButton = undefined,
    button_count: u8 = 0,
    scroll: Scroll = .{},

    pub fn addButton(f: *PointerFrame, b: FrameButton) void {
        if (f.button_count < max_frame_buttons) {
            f.buttons[f.button_count] = b;
            f.button_count += 1;
        }
    }
};

const testing = std.testing;

test "click counting" {
    var c: ClickCounter = .{};
    try testing.expectEqual(@as(u8, 1), c.press(1, 1000, 10, 10));
    try testing.expectEqual(@as(u8, 2), c.press(1, 1200, 12, 11));
    try testing.expectEqual(@as(u8, 3), c.press(1, 1500, 12, 11));
    try testing.expectEqual(@as(u8, 3), c.current());
    // Too slow.
    try testing.expectEqual(@as(u8, 1), c.press(1, 2100, 12, 11));
    // Too far.
    try testing.expectEqual(@as(u8, 1), c.press(1, 2200, 40, 11));
    // Different button restarts.
    try testing.expectEqual(@as(u8, 1), c.press(3, 2300, 40, 11));
    // Timestamp wrap-around still counts as close in time.
    var w: ClickCounter = .{};
    _ = w.press(1, 0xffffff00, 0, 0);
    try testing.expectEqual(@as(u8, 2), w.press(1, 0x40, 0, 0));
}

test "scroll conversion" {
    // Mouse wheel one detent down (high-res): value 10, value120 120 -> one line, content down.
    var s: Scroll = .{ .source = .wheel };
    s.addValue(0, 10);
    s.addValue120(0, 120);
    var l = s.lines();
    try testing.expectEqual(@as(f32, -1), l.y);
    try testing.expectEqual(@as(f32, 0), l.x);
    try testing.expect(!l.precise);
    // Half detent on a high-resolution wheel.
    s = .{ .source = .wheel };
    s.addValue120(0, -60);
    try testing.expectEqual(@as(f32, 0.5), s.lines().y);
    // Legacy discrete (wl_pointer < 8).
    s = .{ .source = .wheel };
    s.addValue(1, 20);
    s.addDiscrete(1, 2);
    try testing.expectEqual(@as(f32, 2), s.lines().x);
    // Touchpad: precise, fractional lines from pixels.
    s = .{ .source = .finger };
    s.addValue(0, -3.5);
    s.addValue(1, 1.0);
    l = s.lines();
    try testing.expect(l.precise);
    try testing.expectApproxEqAbs(@as(f32, 0.35), l.y, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.1), l.x, 1e-6);
}

test "button mapping" {
    try testing.expectEqual(@as(u8, 1), mapButton(BTN_LEFT));
    try testing.expectEqual(@as(u8, 3), mapButton(BTN_RIGHT));
    try testing.expectEqual(@as(u8, 2), mapButton(BTN_MIDDLE));
    try testing.expectEqual(@as(u8, 4), mapButton(BTN_SIDE));
    try testing.expectEqual(@as(u8, 5), mapButton(BTN_EXTRA));
    var st: event.ButtonState = .{};
    setButton(&st, 3, true);
    try testing.expect(st.right and !st.left);
}
