//! Static native UI theme coverage checks.

const std = @import("std");

test "native surfaces do not reuse the legacy border alias as an accent" {
    const audited_sources = [_][]const u8{
        @embedFile("state.zig"),
        @embedFile("terminal/terminal.zig"),
        @embedFile("ui/browser.zig"),
        @embedFile("ui/chat_panel.zig"),
        @embedFile("ui/command_palette.zig"),
        @embedFile("ui/debug.zig"),
        @embedFile("ui/layout.zig"),
        @embedFile("ui/settings_modal.zig"),
        @embedFile("ui/sidebar.zig"),
        @embedFile("ui/terminal_panel.zig"),
        @embedFile("ui/workspace_panes.zig"),
    };
    for (audited_sources) |source| {
        try std.testing.expect(std.mem.find(u8, source, "theme.COLOR_SECONDARY_GREEN") == null);
    }
}
