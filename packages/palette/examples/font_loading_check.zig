//! Real font loading smoke test for Palette's SDL_ttf atlas.

const std = @import("std");
const palette = @import("palette");

const desktop_fonts = [_][:0]const u8{
    "../desktop/src/assets/fonts/NotoSans-Bold.ttf",
    "../desktop/src/assets/fonts/CalSans-Regular.ttf",
    "../desktop/src/assets/fonts/SymbolsNerdFontMono-Regular.ttf",
};

pub export fn palette_font_loading_check_main() c_int {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    run(gpa.allocator()) catch |err| {
        std.debug.print("palette font loading check failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

pub fn run(allocator: std.mem.Allocator) !void {
    for (desktop_fonts) |path| {
        var atlas = try palette.FontAtlas.init(allocator, path, 16.0);
        defer atlas.deinit();
        try atlas.buildAscii();
        if (atlas.font == null) return error.FontNotLoaded;
        if (atlas.width != 1024) return error.UnexpectedAtlasWidth;
        if (atlas.height != 1024) return error.UnexpectedAtlasHeight;
        if (atlas.glyphs.count() < 95) return error.MissingAsciiGlyphs;
    }
}

test "loads desktop bundled fonts" {
    try run(std.testing.allocator);
}
