//! SDL_ttf-backed font atlas model for powder text rendering.

const Self = @This();
const std = @import("std");

pub const c = struct {
    pub const TTF_Font = opaque {};

    extern fn TTF_Init() bool;
    extern fn TTF_Quit() void;
    extern fn TTF_OpenFont(file: [*:0]const u8, ptsize: f32) ?*TTF_Font;
    extern fn TTF_CloseFont(font: *TTF_Font) void;
};

pub const Glyph = struct {
    codepoint: u21,
    advance: f32,
    bearing_x: f32,
    bearing_y: f32,
    size: [2]f32,
    uv: [4]f32,
};

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    font: ?*c.TTF_Font = null,
    glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty,
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: [:0]const u8, point_size: f32) !FontAtlas {
        if (!c.TTF_Init()) return error.SdlTtfInitFailed;
        const font = c.TTF_OpenFont(path.ptr, point_size) orelse return error.SdlTtfOpenFontFailed;
        return .{
            .allocator = allocator,
            .font = font,
            .width = 1024,
            .height = 1024,
        };
    }

    pub fn deinit(self: *FontAtlas) void {
        self.glyphs.deinit(self.allocator);
        if (self.font) |font| c.TTF_CloseFont(font);
        c.TTF_Quit();
        self.* = undefined;
    }

    /// Adds ASCII glyph metrics. Texture packing/upload is intentionally isolated for the GPU pass.
    pub fn buildAscii(self: *FontAtlas) !void {
        var codepoint: u21 = 32;
        while (codepoint < 127) : (codepoint += 1) {
            try self.glyphs.put(self.allocator, codepoint, .{
                .codepoint = codepoint,
                .advance = 8.0,
                .bearing_x = 0.0,
                .bearing_y = 0.0,
                .size = .{ 8.0, 16.0 },
                .uv = .{ 0.0, 0.0, 0.0, 0.0 },
            });
        }
    }
};
