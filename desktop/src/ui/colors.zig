/// Builds an opaque RGB color.
pub fn rgb(r: u8, g: u8, b: u8) [4]f32 {
    return rgba(r, g, b, 255);
}

/// Builds an RGBA color in ImGui float space.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) [4]f32 {
    return .{
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    };
}

/// Main BG GREEN #20272A
pub const GREEN_600 = rgba(0x20, 0x27, 0x2A, 255);
/// Main Border Dark Blue #3C474C
pub const DARK_BLUE = rgba(0x3C, 0x47, 0x4C, 255);

/// Main BG Secondary
pub const BLACK_SECONDARY = rgba(0x20, 0x27, 0x2A, 255);
/// Chat BG BLACKG #0d1213
pub const CHAT_BLACK = rgba(0x0D, 0x12, 0x13, 255);

/// Color for time lable on chat thread #9CB5C0
pub const TIME_LABEL = rgba(0x9C, 0xB5, 0xC0, 255);
