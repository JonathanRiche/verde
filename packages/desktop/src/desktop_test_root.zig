//! Aggregate desktop test root kept out of the production GUI source graph.
//! Provider, daemon store/RPC, and sessionizer tests belong to `daemon-test`
//! (rooted at daemon_main.zig); registering them here compiled and ran the
//! same ~650 tests twice.

pub const test_backend = @import("state/test_backend.zig");

test {
    _ = @import("main.zig");
    _ = @import("utils.zig");
    _ = @import("cli/main.zig");
    _ = @import("browser/screenshot.zig");
    // The GUI side of the Linux helper protocol (shm slots, frame socket).
    if (@import("builtin").os.tag == .linux) _ = @import("browser/platform/linux_wpe.zig");
    _ = @import("ipc/server.zig");
    _ = @import("platform/mod.zig");
    _ = @import("platform/env.zig");
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
    _ = @import("runtime/log.zig");
    _ = @import("terminal/terminal.zig");
    _ = @import("state/browser_controller.zig");
    _ = @import("state/browser_runtime_access.zig");
    _ = @import("state/side_panel_controller.zig");
    _ = @import("state/muse_tui.zig");
    _ = @import("state/runtime_connections_controller.zig");
    _ = @import("state/workspace_layout.zig");
    _ = @import("state/file_viewer_controller.zig");
    _ = @import("state/file_explorer.zig");
    _ = @import("state/folder_browser.zig");
    _ = @import("state/workspace_setup.zig");
    _ = @import("state/custom_agent_form.zig");
    _ = @import("state/provider_controller.zig");
    _ = @import("state/provider_setup.zig");
    _ = @import("state/remote_setup_terminal.zig");
    _ = @import("state/remote_auth_probe.zig");
    _ = @import("ui/onboarding_modal.zig");
    _ = @import("providers/offline_auth.zig");
    _ = @import("ui/text_edit.zig");
    _ = @import("ui/dev_inject.zig");
    _ = @import("ui/palette_frame_renderer.zig");
    _ = @import("state/workspace_tabs.zig");
    _ = @import("state/resource_waiters.zig");
    _ = @import("chat/slash_commands.zig");
    _ = @import("app/update_installer.zig");
    _ = @import("app/updater.zig");
    _ = @import("ui/command_palette.zig");
    _ = @import("ui/font_faces.zig");
    _ = @import("ui/fuzzy_match.zig");
    _ = @import("ui/companion.zig");
    _ = @import("state/companion_controller.zig");
    _ = @import("state/linked_chats_controller.zig");
    _ = @import("state/companion_roster.zig");
    _ = @import("state/companion_persona.zig");
    _ = @import("state/companion_sync.zig");
    _ = @import("state/schedules_sync.zig");
    _ = @import("ui/diff_view_cache.zig");
    _ = @import("ui/diff_render.zig");
    _ = @import("ui/side_panel_changes.zig");
    _ = @import("ui/handoff_sheet.zig");
    _ = @import("state/handoff_controller.zig");
    _ = @import("state/git_changes_controller.zig");
    _ = @import("state/workspace_changes_controller.zig");
    _ = @import("ui/commit_sheet.zig");
    _ = @import("ui/workspace_strip.zig");
    _ = @import("ui/workspace_identity.zig");
    _ = @import("ui/browser.zig");
    _ = @import("ui/chat_panel.zig");
    _ = @import("ui/terminal_panel.zig");
    _ = @import("ui/workspace_panes.zig");
    _ = @import("ui/host.zig");
    _ = @import("loop_wakeup");
}
