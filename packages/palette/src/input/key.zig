//! Shared keyboard representation for Palette components.

const Self = @This();

const sdl = @import("../sdl.zig");

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
};

/// Converts SDL keyboard events into Palette's platform-neutral key model.
pub fn fromSdl(event: sdl.KeyboardEvent) ?Self {
    const mod_bits = event.mod;
    const primary = (mod_bits & (sdl.Keymod.ctrl | sdl.Keymod.gui)) != 0;
    const shift = (mod_bits & sdl.Keymod.shift) != 0;
    const alt = (mod_bits & sdl.Keymod.alt) != 0;
    const code: Code = switch (event.key) {
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
        else => return null,
    };
    return .{ .code = code, .shift = shift, .primary = primary, .alt = alt };
}
