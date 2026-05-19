const std = @import("std");

pub const shells = [_][]const u8{ "bash", "zsh", "fish" };
pub const encodings = [_][]const u8{ "json", "jsonl" };

pub const top_level_commands = [_][]const u8{
    "app",
    "help",
    "version",
    "capabilities",
    "state",
    "live",
    "mcp",
    "completion",
};

pub const state_commands = [_][]const u8{
    "path",
    "projects",
    "panes",
    "threads",
    "transcript",
};

pub const live_commands = [_][]const u8{
    "status",
    "capabilities",
    "projects",
    "panes",
    "active",
    "threads",
    "terminals",
    "processes",
    "inspect",
    "pane",
    "chat",
    "browser",
    "terminal",
    "process",
    "stack",
};

pub const live_capabilities = [_][]const u8{
    "status",
    "capabilities",
    "projects",
    "panes",
    "active",
    "inspect",
    "threads",
    "terminals",
    "processes",
    "pane.focus",
    "pane.split",
    "pane.resize",
    "pane.minimize",
    "pane.maximize",
    "pane.restore",
    "pane.close",
    "chat.status",
    "chat.transcript",
    "chat.draft.set",
    "chat.draft.append",
    "chat.send",
    "chat.followup",
    "chat.stop",
    "chat.approve",
    "browser.open",
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
    "browser.overlay.projectModalOpen",
    "browser.overlay.projectModalClose",
    "browser.overlay.threadModalOpen",
    "browser.overlay.threadModalClose",
    "browser.overlay.imageModalOpen",
    "browser.overlay.imageModalClose",
    "browser.overlay.transcriptModalOpen",
    "browser.overlay.transcriptModalClose",
    "terminal.write",
    "terminal.tail",
    "terminal.screen",
    "process.list",
    "process.inspect",
    "process.start",
    "process.stop",
    "process.restart",
    "process.logs",
    "stack.status",
    "stack.start",
    "stack.stop",
    "stack.restart",
};

pub const pane_commands = [_][]const u8{
    "focus",
    "split",
    "resize",
    "minimize",
    "maximize",
    "restore",
    "close",
};

pub const chat_commands = [_][]const u8{
    "status",
    "transcript",
    "draft",
    "send",
    "followup",
    "stop",
    "approve",
};

pub const chat_draft_commands = [_][]const u8{ "set", "append" };

pub const browser_commands = [_][]const u8{
    "open",
    "close",
    "toggle",
    "back",
    "forward",
    "reload",
    "focus",
    "blur",
    "toolbar-hit",
    "select-all",
    "copy",
    "cut",
    "paste-text",
    "eval",
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
    "project-modal-open",
    "project-modal-close",
    "thread-modal-open",
    "thread-modal-close",
    "image-modal-open",
    "image-modal-close",
    "transcript-modal-open",
    "transcript-modal-close",
};

pub const terminal_commands = [_][]const u8{ "write", "tail", "screen" };
pub const process_commands = [_][]const u8{ "list", "inspect", "start", "stop", "restart", "logs" };
pub const stack_commands = [_][]const u8{ "status", "start", "stop", "restart" };

pub const all_flags = [_][]const u8{
    "--help",
    "-h",
    "--json",
    "--project",
    "--thread",
    "--pane",
    "--focused",
    "--kind",
    "--axis",
    "--first",
    "--second",
    "--ratio",
    "--text",
    "--prompt",
    "--call",
    "--decision",
    "--name",
    "--lines",
    "--script",
    "--json-payload",
};

pub const json_flags = [_][]const u8{"--json"};
pub const project_json_flags = [_][]const u8{ "--project", "--json" };
pub const pane_flags = [_][]const u8{ "--project", "--pane", "--focused", "--json" };
pub const pane_split_flags = [_][]const u8{ "--project", "--pane", "--focused", "--kind", "--axis", "--json" };
pub const pane_resize_flags = [_][]const u8{ "--project", "--pane", "--focused", "--first", "--second", "--axis", "--ratio", "--json" };
pub const chat_draft_flags = [_][]const u8{ "--project", "--pane", "--focused", "--text", "--json" };
pub const chat_send_flags = [_][]const u8{ "--project", "--pane", "--focused", "--prompt", "--text", "--json" };
pub const chat_approve_flags = [_][]const u8{ "--project", "--pane", "--focused", "--call", "--decision", "--json" };
pub const terminal_write_flags = [_][]const u8{ "--project", "--pane", "--focused", "--text", "--json" };
pub const browser_eval_flags = [_][]const u8{ "--script", "--json" };
pub const browser_post_json_flags = [_][]const u8{ "--json-payload", "--json" };
pub const browser_toolbar_hit_flags = [_][]const u8{ "--target", "--json" };
pub const browser_paste_text_flags = [_][]const u8{ "--text", "--json" };
pub const browser_inspector_mode_flags = [_][]const u8{ "--mode", "--json" };
pub const terminal_tail_flags = [_][]const u8{ "--project", "--pane", "--focused", "--lines", "--json" };
pub const process_flags = [_][]const u8{ "--project", "--pane", "--focused", "--name", "--lines", "--json" };

pub const kind_values = [_][]const u8{ "chat", "terminal" };
pub const axis_values = [_][]const u8{ "horizontal", "vertical" };
pub const decision_values = [_][]const u8{ "approve", "deny" };
pub const inspector_mode_values = [_][]const u8{ "point", "draw-box", "draw-freeform" };

pub fn shellSupported(name: []const u8) bool {
    for (shells) |shell| {
        if (std.mem.eql(u8, name, shell)) return true;
    }
    return false;
}
