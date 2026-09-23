//! Static native UI theme coverage checks.

const std = @import("std");

test "native surfaces do not reuse the legacy border alias as an accent" {
    const audited_sources = [_][]const u8{
        @embedFile("../state.zig"),
        @embedFile("../terminal/terminal.zig"),
        @embedFile("../ui/browser.zig"),
        @embedFile("../ui/chat_panel.zig"),
        @embedFile("../ui/command_palette.zig"),
        @embedFile("../ui/debug.zig"),
        @embedFile("../ui/layout.zig"),
        @embedFile("../ui/settings_modal.zig"),
        @embedFile("../ui/sidebar.zig"),
        @embedFile("../ui/terminal_panel.zig"),
        @embedFile("../ui/workspace_panes.zig"),
    };
    for (audited_sources) |source| {
        try std.testing.expect(std.mem.find(u8, source, "theme.COLOR_SECONDARY_GREEN") == null);
    }
}

test "native surfaces take every colour from the active theme" {
    // Colours must derive from theme roles so light and dark palettes both
    // render legibly. `lighten`/`darken` only work on dark palettes; UI code
    // uses the polarity-aware `theme.raise`/`theme.sink` instead.
    const audited_sources = [_][]const u8{
        @embedFile("../state.zig"),
        @embedFile("../terminal/terminal.zig"),
        @embedFile("../ui/browser.zig"),
        @embedFile("../ui/chat_markdown.zig"),
        @embedFile("../ui/chat_panel.zig"),
        @embedFile("../ui/command_palette.zig"),
        @embedFile("../ui/companion.zig"),
        @embedFile("../ui/composer_pickers.zig"),
        @embedFile("../ui/debug.zig"),
        @embedFile("../ui/handoff_sheet.zig"),
        @embedFile("../ui/layout.zig"),
        @embedFile("../ui/settings_modal.zig"),
        @embedFile("../ui/sidebar.zig"),
        @embedFile("../ui/terminal_panel.zig"),
        @embedFile("../ui/workspace_panes.zig"),
        @embedFile("../ui/workspace_strip.zig"),
    };
    const forbidden = [_][]const u8{
        "theme.lighten(",
        "theme.darken(",
        "colors.rgb(",
        "colors.rgba(",
        "paletteColor(.{ 0",
        "paletteColor(.{ 1",
    };
    for (audited_sources) |source| {
        for (forbidden) |pattern| {
            try std.testing.expect(std.mem.find(u8, source, pattern) == null);
        }
    }
}
