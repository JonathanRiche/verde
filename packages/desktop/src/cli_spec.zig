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
};

pub const json_flags = [_][]const u8{ "--json" };
pub const project_json_flags = [_][]const u8{ "--project", "--json" };
pub const pane_flags = [_][]const u8{ "--project", "--pane", "--focused", "--json" };
pub const pane_split_flags = [_][]const u8{ "--project", "--pane", "--focused", "--kind", "--axis", "--json" };
pub const pane_resize_flags = [_][]const u8{ "--project", "--pane", "--focused", "--first", "--second", "--axis", "--ratio", "--json" };
pub const chat_draft_flags = [_][]const u8{ "--project", "--pane", "--focused", "--text", "--json" };
pub const chat_send_flags = [_][]const u8{ "--project", "--pane", "--focused", "--prompt", "--text", "--json" };
pub const chat_approve_flags = [_][]const u8{ "--project", "--pane", "--focused", "--call", "--decision", "--json" };
pub const terminal_write_flags = [_][]const u8{ "--project", "--pane", "--focused", "--text", "--json" };
pub const terminal_tail_flags = [_][]const u8{ "--project", "--pane", "--focused", "--lines", "--json" };
pub const process_flags = [_][]const u8{ "--project", "--pane", "--focused", "--name", "--lines", "--json" };

pub const kind_values = [_][]const u8{ "chat", "terminal" };
pub const axis_values = [_][]const u8{ "horizontal", "vertical" };
pub const decision_values = [_][]const u8{ "approve", "deny" };

pub fn shellSupported(name: []const u8) bool {
    for (shells) |shell| {
        if (std.mem.eql(u8, name, shell)) return true;
    }
    return false;
}
