//! Aggregate desktop test root kept out of the production GUI source graph.

pub const test_backend = @import("state/test_backend.zig");

test {
    _ = @import("main.zig");
    _ = @import("cli/main.zig");
    _ = @import("browser/screenshot.zig");
    _ = @import("ipc/server.zig");
    _ = @import("platform/mod.zig");
    _ = @import("platform/workspace_identity.zig");
    _ = @import("runtime/gateway_transport.zig");
    _ = @import("runtime/connection.zig");
    _ = @import("runtime/pair_client.zig");
    _ = @import("runtime/credential_store.zig");
    _ = @import("runtime/connect_client.zig");
    _ = @import("runtime/profile.zig");
    _ = @import("runtime/profile_store.zig");
    _ = @import("runtime/secret_store.zig");
    _ = @import("runtime/ssh_tunnel.zig");
    _ = @import("runtime/ssh_tunnel_supervisor.zig");
    _ = @import("runtime/thread_binding.zig");
    _ = @import("state/browser_controller.zig");
    _ = @import("state/muse_tui.zig");
    _ = @import("state/runtime_connections_controller.zig");
    _ = @import("state/workspace_layout.zig");
    _ = @import("state/workspace_tabs.zig");
    _ = @import("providers/acp.zig");
    _ = @import("providers/claude.zig");
    _ = @import("providers/cursor.zig");
    _ = @import("providers/diagnostics.zig");
    _ = @import("providers/fx.zig");
    _ = @import("providers/grok.zig");
    _ = @import("providers/muse.zig");
    _ = @import("providers/opencode.zig");
    _ = @import("providers/pi.zig");
    _ = @import("providers/mcp.zig");
    _ = @import("chat/slash_commands.zig");
    _ = @import("theme/coverage_test.zig");
    _ = @import("app/update_installer.zig");
    _ = @import("app/updater.zig");
    _ = @import("ui/command_palette.zig");
    _ = @import("ui/companion.zig");
    _ = @import("ui/diff_view_cache.zig");
    _ = @import("ui/handoff_sheet.zig");
    _ = @import("state/handoff_controller.zig");
    _ = @import("ui/workspace_strip.zig");
    _ = @import("compile_tests/windows_conpty.zig");
    _ = @import("daemon/change_journal.zig");
    _ = @import("daemon/process_registry.zig");
    _ = @import("daemon/store.zig");
}
