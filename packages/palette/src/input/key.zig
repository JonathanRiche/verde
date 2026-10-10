//! Shared keyboard representation for Palette components.

const Self = @This();

const event = @import("../event.zig");

code: Code,
shift: bool = false,
primary: bool = false,
alt: bool = false,

pub const Code = enum {
    left,
    right,
    up,
    down,
    home,
    end,
    backspace,
    delete,
    enter,
    escape,
    page_up,
    page_down,
    a,
    c,
    v,
    x,
    y,
    z,
};

/// Converts a platform key event into Palette's component key model.
pub fn fromEvent(ev: event.KeyEvent) ?Self {
    const code: Code = switch (ev.key) {
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .pageup => .page_up,
        .pagedown => .page_down,
        .backspace => .backspace,
        .delete => .delete,
        .@"return", .kp_enter => .enter,
        .escape => .escape,
        .a => .a,
        .c => .c,
        .v => .v,
        .x => .x,
        .y => .y,
        .z => .z,
        else => return null,
    };
    return .{ .code = code, .shift = ev.mod.shift, .primary = ev.mod.primary(), .alt = ev.mod.alt };
}
