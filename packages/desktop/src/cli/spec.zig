const std = @import("std");

pub const shells = [_][]const u8{ "bash", "zsh", "fish", "powershell" };
pub const encodings = [_][]const u8{ "json", "jsonl" };

pub const top_level_commands = [_][]const u8{
    "app",
    "help",
    "version",
    "update",
    "capabilities",
    "open",
    "herdr",
    "theme",
    "state",
    "notify",
    "integrations",
    "session",
    "core",
    "live",
    "mcp",
    "completion",
};

pub const theme_commands = [_][]const u8{
    "import",
    "validate",
    "export",
    "reset",
};

pub const state_commands = [_][]const u8{
    "path",
    "workspaces",
    "panes",
    "threads",
    "transcript",
};

pub const herdr_commands = [_][]const u8{
    "open",
    "handoff",
    "unlink",
    "profiles",
    "status",
};

pub const herdr_profile_commands = [_][]const u8{
    "list",
    "add",
    "remove",
    "test",
};

pub const integration_commands = [_][]const u8{
    "list",
    "doctor",
    "install",
    "remove",
    "disable",
};

pub const integration_providers = [_][]const u8{
    "claude",
    "codex",
    "amp",
    "opencode",
    "cursor",
    "grok",
};

pub const session_commands = [_][]const u8{
    "list",
    "inspect",
    "new",
    "attach",
    "write",
    "tail",
    "screen",
    "kill",
    "cleanup",
};

pub const core_commands = [_][]const u8{
    "status",
    "capabilities",
};

pub const live_commands = [_][]const u8{
    "status",
    "capabilities",
    "workspaces",
    "panes",
    "active",
    "threads",
    "terminals",
    "surfaces",
    "processes",
    "inspect",
    "workspace",
    "pane",
    "chat",
    "browser",
    "palette",
    "terminal",
    "process",
    "agent",
    "stack",
};

pub const live_capabilities = [_][]const u8{
    "status",
    "capabilities",
    "workspaces",
    "panes",
    "active",
    "inspect",
    "threads",
    "terminals",
    "herdr.open",
    "herdr.handoff",
    "herdr.unlink",
    "herdr.status",
    "surfaces",
    "surface.list",
    "surface.inspect",
    "surface.focus",
    "surface.clearAttention",
    "notification.create",
    "notification.update",
    "notification.clear",
    "processes",
    "workspace.select",
    "workspace.create",
    "workspace.rename",
    "workspace.close",
    "workspace.reopen",
    "workspace.archive",
    "workspace.processes",
    "workspace.checkCommand",
    "workspace.acquireLease",
    "workspace.releaseLease",
    "pane.focus",
    "pane.split",
    "pane.resize",
    "pane.move",
    "pane.maximize",
    "pane.close",
    "chat.open",
    "chat.status",
    "chat.transcript",
    "chat.draft.get",
    "chat.draft.set",
    "chat.draft.append",
    "chat.send",
    "chat.followup",
    "chat.stop",
    "chat.approve",
    "browser.open",
    "browser.navigate",
    "browser.status",
    "browser.close",
    "browser.toggle",
    "browser.back",
    "browser.forward",
    "browser.reload",
    "browser.focus",
    "browser.blur",
    "browser.toolbarHit",
    "browser.selectAllFocused",
    "browser.copyFocused",
    "browser.cutFocused",
    "browser.pasteTextFocused",
    "browser.eval",
    "browser.screenshot",
    "browser.postJson",
    "browser.inspector.enable",
    "browser.inspector.disable",
    "browser.inspector.toggle",
    "browser.inspector.mode",
    "browser.inspector.menuOpen",
    "browser.inspector.menuClose",
    "browser.overlay.workspaceMenuOpen",
    "browser.overlay.workspaceMenuClose",
    "browser.overlay.sidebarMenuOpen",
    "browser.overlay.sidebarMenuClose",
    "browser.overlay.composerMenuOpen",
    "browser.overlay.composerMenuClose",
    "browser.overlay.workspaceModalOpen",
    "browser.overlay.workspaceModalClose",
    "browser.overlay.threadModalOpen",
    "browser.overlay.threadModalClose",
    "browser.overlay.imageModalOpen",
    "browser.overlay.imageModalClose",
    "browser.overlay.transcriptModalOpen",
    "browser.overlay.transcriptModalClose",
    "palette.list",
    "palette.run",
    "terminal.write",
    "terminal.key",
    "terminal.tail",
    "terminal.screen",
    "process.list",
    "process.inspect",
    "process.start",
    "process.stop",
    "process.restart",
    "process.logs",
    "agent.open",
    "stack.status",
    "stack.start",
    "stack.stop",
    "stack.restart",
};

/// Stable chat-tool names exposed by the stdio MCP bridge.
pub const mcp_chat_tools = [_][]const u8{
    "open_chat",
    "present_chat",
    "set_chat_draft",
    "get_chat_draft",
    "send_chat_message",
    "queue_chat_followup",
    "tail_chat_turn",
    "approve_chat_turn",
    "stop_chat_turn",
    "read_chat_thread",
};

pub const pane_commands = [_][]const u8{
    "focus",
    "split",
    "resize",
    "move",
    "maximize",
    "close",
};

pub const workspace_commands = [_][]const u8{
    "select",
    "create",
    "rename",
    "close",
    "reopen",
    "archive",
};

pub const chat_commands = [_][]const u8{
    "open",
    "status",
    "transcript",
    "draft",
    "send",
    "followup",
    "stop",
    "approve",
};

pub const chat_draft_commands = [_][]const u8{ "get", "set", "append" };

pub const browser_commands = [_][]const u8{
    "open",
    "navigate",
    "status",
    "close",
    "toggle",
    "back",
    "forward",
    "reload",
    "restart",
    "reset",
    "pointer-down",
    "pointer-move",
    "pointer-up",
    "focus",
    "blur",
    "toolbar-hit",
    "select-all",
    "copy",
    "cut",
    "paste-text",
    "eval",
    "screenshot",
    "post-json",
    "inspector-enable",
    "inspector-disable",
    "inspector-toggle",
    "inspector-mode",
    "inspector-menu-open",
    "inspector-menu-close",
    "workspace-menu-open",
    "workspace-menu-close",
    "sidebar-menu-open",
    "sidebar-menu-close",
    "composer-menu-open",
    "composer-menu-close",
    "workspace-modal-open",
    "workspace-modal-close",
    "thread-modal-open",
    "thread-modal-close",
    "image-modal-open",
    "image-modal-close",
    "transcript-modal-open",
    "transcript-modal-close",
};

pub const terminal_commands = [_][]const u8{ "write", "key", "submit", "tail", "screen" };
pub const palette_commands = [_][]const u8{ "list", "run" };
pub const process_commands = [_][]const u8{ "list", "inspect", "start", "stop", "restart", "logs" };
pub const agent_commands = [_][]const u8{"open"};
pub const stack_commands = [_][]const u8{ "status", "start", "stop", "restart" };

pub const all_flags = [_][]const u8{
    "--help",
    "-h",
    "--json",
    "--id",
    "--workspace",
    "--herdr-workspace",
    "--project",
    "--thread",
    "--pane",
    "--focused",
    "--no-focus",
    "--kind",
    "--axis",
    "--first",
    "--second",
    "--ratio",
    "--direction",
    "--path",
    "--url",
    "--text",
    "--key",
    "--chord",
    "--target",
    "--title",
    "--body",
    "--status",
    "--progress",
    "--label",
    "--session",
    "--ssh-target",
    "--profile",
    "--remote",
    "--cwd",
    "--remote-cwd",
    "--local-dir",
    "--all",
    "--dry-run",
    "--dock",
    "--clear",
    "--quiet",
    "--prompt",
    "--call",
    "--decision",
    "--name",
    "--provider",
    "--model",
    "--reasoning",
    "--reasoning-variant",
    "--fast",
    "--no-fast",
    "--on",
    "--off",
    "--toggle",
    "--lines",
    "--script",
    "--json-payload",
    "--mode",
    "--command",
    "--x",
    "--y",
    "--button",
    "--ctrl",
    "--shift",
    "--alt",
    "--super",
};

pub const json_flags = [_][]const u8{"--json"};
pub const workspace_json_flags = [_][]const u8{ "--workspace", "--json" };
pub const project_json_flags = workspace_json_flags;
pub const herdr_open_flags = [_][]const u8{ "--session", "--herdr-workspace", "--profile", "--remote", "--cwd", "--remote-cwd", "--local-dir", "--pane", "--json" };
pub const herdr_handoff_flags = [_][]const u8{ "--workspace", "--project", "--all", "--session", "--profile", "--remote", "--remote-cwd", "--dry-run", "--json" };
pub const herdr_unlink_flags = [_][]const u8{ "--workspace", "--project", "--all", "--json" };
pub const herdr_profile_add_flags = [_][]const u8{ "--name", "--ssh-target", "--session", "--remote-cwd", "--local-dir", "--json" };
pub const herdr_profile_name_flags = [_][]const u8{ "--name", "--json" };
pub const session_id_json_flags = [_][]const u8{ "--id", "--json" };
pub const session_new_flags = [_][]const u8{ "--workspace", "--name", "--json" };
pub const session_attach_flags = [_][]const u8{ "--id", "--workspace", "--pane" };
pub const session_write_flags = [_][]const u8{ "--id", "--text", "--json" };
pub const session_tail_flags = [_][]const u8{ "--id", "--lines", "--json" };
pub const pane_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--json" };
pub const pane_split_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--kind", "--axis", "--json" };
pub const pane_resize_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--first", "--second", "--axis", "--ratio", "--json" };
pub const pane_move_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--direction", "--json" };
pub const pane_maximize_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--on", "--off", "--toggle", "--json" };
pub const workspace_select_flags = [_][]const u8{ "--workspace", "--project", "--json" };
pub const workspace_create_flags = [_][]const u8{ "--path", "--json" };
pub const workspace_rename_flags = [_][]const u8{ "--workspace", "--project", "--label", "--json" };
pub const workspace_close_flags = [_][]const u8{ "--workspace", "--project", "--json" };
pub const workspace_reopen_flags = [_][]const u8{ "--workspace", "--project", "--json" };
pub const workspace_archive_flags = workspace_close_flags;
pub const chat_open_flags = [_][]const u8{
    "--workspace",
    "--project",
    "--provider",
    "--model",
    "--reasoning",
    "--reasoning-variant",
    "--fast",
    "--no-fast",
    "--pane",
    "--axis",
    "--no-focus",
    "--json",
};
pub const chat_draft_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--thread", "--text", "--json" };
pub const chat_send_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--prompt", "--text", "--json" };
pub const chat_approve_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--call", "--decision", "--json" };
pub const terminal_write_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--text", "--json" };
pub const terminal_key_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--key", "--chord", "--ctrl", "--alt", "--shift", "--super", "--json" };
pub const browser_eval_flags = [_][]const u8{ "--script", "--json" };
pub const browser_pointer_flags = [_][]const u8{ "--x", "--y", "--button", "--ctrl", "--shift", "--alt", "--super", "--json" };
pub const browser_open_flags = [_][]const u8{ "--url", "--workspace", "--project", "--json" };
pub const browser_navigate_flags = [_][]const u8{ "--url", "--json" };
pub const browser_post_json_flags = [_][]const u8{ "--json-payload", "--json" };
pub const browser_toolbar_hit_flags = [_][]const u8{ "--target", "--json" };
pub const browser_paste_text_flags = [_][]const u8{ "--text", "--json" };
pub const browser_inspector_mode_flags = [_][]const u8{ "--mode", "--json" };
pub const palette_run_flags = [_][]const u8{ "--command", "--json" };
pub const terminal_tail_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--lines", "--json" };
pub const process_flags = [_][]const u8{ "--workspace", "--pane", "--focused", "--name", "--lines", "--json" };
pub const agent_flags = [_][]const u8{ "--workspace", "--provider", "--json" };

pub const kind_values = [_][]const u8{ "chat", "terminal" };
pub const axis_values = [_][]const u8{ "horizontal", "vertical" };
pub const direction_values = [_][]const u8{ "left", "right", "up", "down" };
pub const decision_values = [_][]const u8{ "approve", "deny" };
pub const provider_values = [_][]const u8{ "opencode", "codex", "claude", "cursor", "pi", "grok" };
pub const reasoning_values = [_][]const u8{ "low", "medium", "high", "xhigh", "max" };
pub const inspector_mode_values = [_][]const u8{ "point", "draw-box", "draw-freeform" };
pub const terminal_key_values = [_][]const u8{
    "enter",
    "escape",
    "tab",
    "up",
    "down",
    "left",
    "right",
    "home",
    "end",
    "pageup",
    "pagedown",
    "backspace",
    "delete",
    "space",
    "f1",
    "f2",
    "f3",
    "f4",
    "f5",
    "f6",
    "f7",
    "f8",
    "f9",
    "f10",
    "f11",
    "f12",
    "a",
    "b",
    "c",
    "d",
    "e",
    "f",
    "g",
    "h",
    "i",
    "j",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "q",
    "r",
    "s",
    "t",
    "u",
    "v",
    "w",
    "x",
    "y",
    "z",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
};

pub fn shellSupported(name: []const u8) bool {
    for (shells) |shell| {
        if (std.mem.eql(u8, name, shell)) return true;
    }
    return false;
}
