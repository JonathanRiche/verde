//! The role faces Verde hands to the palette font engine. Bundled faces are
//! embedded in the binary; only the user's Ghostty mono font and the system
//! math face come from disk. Kept in one place so the icon audit test below
//! checks the exact chain the app draws with.

const std = @import("std");
const palette = @import("palette");

pub const cal_sans = @embedFile("../assets/fonts/CalSans-Regular.ttf");
pub const noto_sans_regular = @embedFile("../assets/fonts/NotoSans-Regular.ttf");
pub const noto_sans_bold = @embedFile("../assets/fonts/NotoSans-Bold.ttf");
pub const noto_sans_italic = @embedFile("../assets/fonts/NotoSans-Italic.ttf");
pub const noto_sans_bold_italic = @embedFile("../assets/fonts/NotoSans-BoldItalic.ttf");
pub const codicon = @embedFile("../assets/fonts/Codicon.ttf");
pub const nerd_symbols = @embedFile("../assets/fonts/SymbolsNerdFontMono-Regular.ttf");
pub const jetbrains_mono_nerd = @embedFile("../assets/fonts/JetBrainsMonoNerdFont-Regular.ttf");
pub const noto_sans_symbols2 = @embedFile("../assets/fonts/NotoSansSymbols2-Regular.ttf");
pub const noto_sans_symbols = @embedFile("../assets/fonts/NotoSansSymbols-Regular.ttf");
pub const noto_emoji = @embedFile("../assets/fonts/NotoEmoji-Regular.ttf");

/// Face set for the desktop UI. `mono_path` (Ghostty's font) replaces the
/// bundled JetBrains Mono Nerd primary; `math_path` adds the system math face.
/// Paths are read while `palette.fonts.Fonts.init` runs.
pub fn bundled(mono_path: ?[]const u8, math_path: ?[]const u8) palette.fonts.FaceSet {
    return .{
        .ui = .{ .memory = cal_sans },
        // ui_bold and prose_bold both resolve to Noto Sans Bold.
        .bold = .{ .memory = noto_sans_bold },
        .prose = .{ .memory = noto_sans_regular },
        .italic = .{ .memory = noto_sans_italic },
        .bold_italic = .{ .memory = noto_sans_bold_italic },
        .mono = if (mono_path) |path| .{ .path = path } else .{ .memory = jetbrains_mono_nerd },
        // Symbols Nerd Font draws the devicon/Material file icons and most
        // codicons. Codicon backs it for codicons newer than the Nerd Font
        // snapshot (U+EC5E file-text, the `.txt`/`.log`/`.csv` icon).
        .icon = .{ .memory = nerd_symbols },
        .icon_fallback = .{ .memory = codicon },
        // JetBrains Mono Nerd is always the first coverage fallback for mono,
        // even when Ghostty names another primary (e.g. CaskaydiaMono): it
        // carries common TUI symbols (Vite ➜, Claude Code's ✻/✽ spinner
        // frames, ●, □) that user-chosen fonts often lack.
        .mono_symbols = .{ .memory = jetbrains_mono_nerd },
        // Noto Sans Symbols 2 covers ~145/192 Dingbats plus Misc Symbols
        // (✻/✽/✶, ➤, ✷) that even JetBrains Mono Nerd lacks.
        .symbols = .{ .memory = noto_sans_symbols2 },
        // The original Noto Sans Symbols adds numbered dingbats (❶❷..❿ /
        // ➀➁..➓ at U+2776..2793) and other blocks Symbols 2 omits.
        .symbols_alt = .{ .memory = noto_sans_symbols },
        .math = if (math_path) |path| .{ .path = path } else .none,
        // Monochrome Noto Emoji for the emoji-styled Dingbats Symbols 2
        // excludes (✨, ✅/❌, ➕/➖, ❤, ℹ, ⚡, ⚠) and 4-byte emoji (🔥/📦).
        .emoji = .{ .memory = noto_emoji },
    };
}

fn isIconCodepoint(cp: u21) bool {
    // BMP Private Use Area (codicons, devicons, Font Awesome, Powerline) and
    // the Supplementary PUA-A plane Nerd Fonts' Material Design icons use.
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD);
}

/// Appends every icon codepoint in `source`, written either literally or as a
/// `\u{...}` escape.
fn collectIconCodepoints(gpa: std.mem.Allocator, source: []const u8, out: *std.AutoArrayHashMapUnmanaged(u21, void)) !void {
    var i: usize = 0;
    while (i < source.len) {
        if (std.mem.startsWith(u8, source[i..], "\\u{")) {
            const start = i + 3;
            if (std.mem.indexOfScalarPos(u8, source, start, '}')) |end| {
                if (std.fmt.parseInt(u21, source[start..end], 16)) |cp| {
                    if (isIconCodepoint(cp)) try out.put(gpa, cp, {});
                } else |_| {}
                i = end + 1;
                continue;
            }
        }
        const len = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
        if (len > 1 and i + len <= source.len) {
            if (std.unicode.utf8Decode(source[i..][0..len])) |cp| {
                if (isIconCodepoint(cp)) try out.put(gpa, cp, {});
            } else |_| {}
        }
        i += len;
    }
}

test "every icon codepoint in the desktop UI resolves to a glyph in the icon chain" {
    const gpa = std.testing.allocator;
    // Every desktop source that draws private-use icon glyphs. Adding a file
    // with icons? List it here so a codepoint no bundled face carries fails
    // the build instead of drawing tofu.
    const sources = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "state.zig", .text = @embedFile("../state.zig") },
        .{ .name = "agent_prompt_popover.zig", .text = @embedFile("agent_prompt_popover.zig") },
        .{ .name = "browser.zig", .text = @embedFile("browser.zig") },
        .{ .name = "chat_markdown.zig", .text = @embedFile("chat_markdown.zig") },
        .{ .name = "chat_panel.zig", .text = @embedFile("chat_panel.zig") },
        .{ .name = "command_palette.zig", .text = @embedFile("command_palette.zig") },
        .{ .name = "commit_sheet.zig", .text = @embedFile("commit_sheet.zig") },
        .{ .name = "context_menu.zig", .text = @embedFile("context_menu.zig") },
        .{ .name = "file_icons.zig", .text = @embedFile("file_icons.zig") },
        .{ .name = "file_viewer.zig", .text = @embedFile("file_viewer.zig") },
        .{ .name = "layout.zig", .text = @embedFile("layout.zig") },
        .{ .name = "settings_modal.zig", .text = @embedFile("settings_modal.zig") },
        .{ .name = "sidebar.zig", .text = @embedFile("sidebar.zig") },
        .{ .name = "side_panel.zig", .text = @embedFile("side_panel.zig") },
        .{ .name = "side_panel_changes.zig", .text = @embedFile("side_panel_changes.zig") },
        .{ .name = "side_panel_files.zig", .text = @embedFile("side_panel_files.zig") },
        .{ .name = "workspace_identity.zig", .text = @embedFile("workspace_identity.zig") },
        .{ .name = "workspace_panes.zig", .text = @embedFile("workspace_panes.zig") },
        .{ .name = "workspace_strip.zig", .text = @embedFile("workspace_strip.zig") },
    };

    const fonts = try palette.fonts.Fonts.init(gpa, bundled(null, null), .{ .optional_missing = false });
    defer fonts.deinit();
    const coll = fonts.collection;

    var missing: usize = 0;
    var checked: usize = 0;
    for (sources) |source| {
        var cps: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
        defer cps.deinit(gpa);
        try collectIconCodepoints(gpa, source.text, &cps);
        try std.testing.expect(cps.count() > 0);
        for (cps.keys()) |cp| {
            checked += 1;
            const entry = coll.resolve(.icon, cp) orelse {
                std.debug.print("{s}: U+{X:0>4} has no face in the icon chain\n", .{ source.name, cp });
                missing += 1;
                continue;
            };
            if (entry.glyph == 0) {
                std.debug.print("{s}: U+{X:0>4} is missing from every icon face\n", .{ source.name, cp });
                missing += 1;
            }
        }
    }
    try std.testing.expect(checked >= 100);
    try std.testing.expectEqual(@as(usize, 0), missing);
}

test "the .txt file icon (codicon file-text, newer than Symbols Nerd Font) draws from Codicon" {
    const fonts = try palette.fonts.Fonts.init(std.testing.allocator, bundled(null, null), .{ .optional_missing = false });
    defer fonts.deinit();
    const chain = fonts.collection.roleChain(.icon);
    const nerd = fonts.collection.sfntFace(chain[0]).?;
    try std.testing.expectEqual(@as(u32, 0), nerd.font.glyphIndex(0xEC5E));
    const entry = fonts.collection.resolve(.icon, 0xEC5E).?;
    try std.testing.expect(entry.face != chain[0]);
    try std.testing.expect(entry.glyph != 0);
    try std.testing.expect((try fonts.measure(.icon, 16, "\u{EC5E}")) > 0);
}

test "collectIconCodepoints reads literal glyphs and escapes" {
    const gpa = std.testing.allocator;
    var cps: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
    defer cps.deinit(gpa);
    try collectIconCodepoints(gpa, "a \"\u{EA83}\" \\u{ec5e} \\u{f0615} \\u{2192} \\u{zz}", &cps);
    try std.testing.expectEqualSlices(u21, &.{ 0xEA83, 0xEC5E, 0xF0615 }, cps.keys());
}
