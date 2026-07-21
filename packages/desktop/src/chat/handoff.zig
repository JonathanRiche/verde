//! Provider-neutral chat and terminal handoff package construction.

const std = @import("std");

pub const ContextMode = enum {
    summary,
    recent,
    full,
};

pub const Surface = enum {
    gui_chat,
    tui,
};

pub const Role = enum {
    user,
    assistant,
    system,
};

pub const MessageView = struct {
    role: Role,
    author: []const u8,
    body: []const u8,
};

pub const AttachmentView = struct {
    file_name: []const u8,
    mime: []const u8,
    byte_size: usize,
};

pub const PackageInput = struct {
    workspace_id: []const u8,
    workspace_label: []const u8,
    workspace_path: []const u8,
    pane_id: u32,
    source_surface: Surface,
    source_provider: []const u8,
    verde_session_id: ?[]const u8 = null,
    verde_thread_index: ?usize = null,
    verde_thread_id: ?[]const u8 = null,
    provider_thread_id: ?[]const u8 = null,
    title: []const u8,
    messages: []const MessageView = &.{},
    attachments: []const AttachmentView = &.{},
    terminal_history: []const u8 = "",
    git_context: []const u8 = "",
    process_context: []const u8 = "",
    context_mode: ContextMode = .summary,
};

/// Builds context that can be sent to any provider without treating the source
/// provider's thread ID as a portable target identifier.
pub fn buildAlloc(allocator: std.mem.Allocator, input: PackageInput) ![:0]u8 {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);

    try output.appendSlice(allocator,
        \\# Verde agent handoff
        \\
        \\Continue the work described below. This is provider-neutral context copied from another Verde surface.
        \\
        \\## Source identity
        \\
    );
    try appendField(&output, allocator, "Workspace", input.workspace_label);
    try appendField(&output, allocator, "Workspace ID", input.workspace_id);
    try appendField(&output, allocator, "Workspace path", input.workspace_path);
    try appendFmt(&output, allocator, "- Active Verde pane ID: {d}\n", .{input.pane_id});
    try appendField(&output, allocator, "Source surface", @tagName(input.source_surface));
    try appendField(&output, allocator, "Source provider", input.source_provider);
    if (input.verde_session_id) |session_id| try appendField(&output, allocator, "Verde terminal session ID", session_id);
    if (input.verde_thread_id) |thread_id| try appendField(&output, allocator, "Verde local thread ID", thread_id);
    if (input.verde_thread_index) |thread_index| try appendFmt(&output, allocator, "- Verde thread index: {d}\n", .{thread_index});
    if (input.provider_thread_id) |thread_id| {
        try appendField(&output, allocator, "Source provider thread ID", thread_id);
        try output.appendSlice(allocator, "- Provider-ID scope: source provider only; do not use this ID as the target provider's thread ID.\n");
    }
    try appendField(&output, allocator, "Source title", input.title);

    try output.appendSlice(allocator, "\n## Attachment disclosure\n\n");
    if (input.attachments.len == 0) {
        try output.appendSlice(allocator, "- No GUI chat attachments were present.\n");
    } else {
        try output.appendSlice(allocator, "- Attachment bytes are not shared by this handoff. Source references:\n");
        for (input.attachments) |attachment| {
            try appendFmt(&output, allocator, "  - {s} ({s}, {d} bytes)\n", .{
                if (likelySensitive(attachment.file_name)) "[redacted attachment name]" else attachment.file_name,
                attachment.mime,
                attachment.byte_size,
            });
        }
    }

    try output.appendSlice(allocator,
        \\
        \\## Retrieve more Verde history
        \\
    );
    if (input.provider_thread_id) |thread_id| {
        try appendFmt(&output, allocator, "- Complete persisted thread: `verde state transcript --workspace {s} --thread {s} --json`\n", .{ input.workspace_id, thread_id });
    } else if (input.verde_thread_index) |thread_index| {
        try appendFmt(&output, allocator, "- Complete persisted thread: `verde state transcript --workspace {s} --thread {d} --json`\n", .{ input.workspace_id, thread_index });
    }
    switch (input.source_surface) {
        .gui_chat => try appendFmt(&output, allocator, "- Active pane while Verde is running: `verde live chat transcript --workspace {s} --pane {d} --json`\n", .{ input.workspace_id, input.pane_id }),
        .tui => {
            try appendFmt(&output, allocator, "- Current TUI screen: `verde live terminal screen --workspace {s} --pane {d} --json`\n", .{ input.workspace_id, input.pane_id });
            try appendFmt(&output, allocator, "- Recent TUI output: `verde live terminal tail --workspace {s} --pane {d} --json`\n", .{ input.workspace_id, input.pane_id });
            if (input.verde_session_id) |session_id| {
                try appendFmt(&output, allocator, "- Persisted terminal session details: `verde session inspect --id {s} --json`\n", .{session_id});
                try appendFmt(&output, allocator, "- Persisted terminal output: `verde session tail --id {s} --json`\n", .{session_id});
            }
        },
    }
    try output.appendSlice(allocator, "- Discover current commands first when needed: `verde capabilities --json` and `verde live capabilities --json`.\n");

    try output.appendSlice(allocator,
        \\
        \\## Objective and conversation context
        \\
    );
    if (input.messages.len > 0) {
        try appendMessages(&output, allocator, input.messages, input.context_mode);
    } else if (input.terminal_history.len > 0) {
        try appendRedactedBlock(&output, allocator, input.terminal_history, 48 * 1024);
    } else {
        try output.appendSlice(allocator, "No transcript was available from the source surface.\n");
    }

    if (input.git_context.len > 0) {
        try output.appendSlice(allocator,
            \\
            \\## Workspace and Git state
            \\
        );
        try appendRedactedBlock(&output, allocator, input.git_context, 12 * 1024);
    }
    if (input.process_context.len > 0) {
        try output.appendSlice(allocator,
            \\
            \\## Active processes
            \\
        );
        try appendRedactedBlock(&output, allocator, input.process_context, 4 * 1024);
    }

    try output.appendSlice(allocator,
        \\
        \\## Safety and continuation instructions
        \\
        \\- The source thread and pane remain unchanged.
        \\- Re-check the workspace before changing files because this snapshot may become stale.
        \\- Credentials, authorization headers, and likely secret-bearing lines were excluded by default.
        \\- Review unresolved approvals in the conversation before taking privileged or destructive actions.
        \\- Ask the user when authority is missing; do not infer approval from this handoff.
    );

    return try allocator.dupeZ(u8, output.items);
}

fn appendMessages(output: *std.ArrayList(u8), allocator: std.mem.Allocator, messages: []const MessageView, mode: ContextMode) !void {
    const initial_len = output.items.len;
    const max_embedded_bytes = 28 * 1024;
    switch (mode) {
        .full => {
            for (messages) |message| {
                if (output.items.len - initial_len >= max_embedded_bytes) {
                    try output.appendSlice(allocator, "Transcript embedding limit reached; use the history commands above for the remainder.\n");
                    break;
                }
                try appendMessage(output, allocator, message);
            }
        },
        .recent => {
            const start = messages.len -| 12;
            if (start > 0) try appendFmt(output, allocator, "Earlier messages omitted ({d}); use the history commands above for the complete thread.\n\n", .{start});
            for (messages[start..]) |message| {
                if (output.items.len - initial_len >= max_embedded_bytes) {
                    try output.appendSlice(allocator, "Recent-message embedding limit reached; use the history commands above for the remainder.\n");
                    break;
                }
                try appendMessage(output, allocator, message);
            }
        },
        .summary => {
            var first_user: ?usize = null;
            var last_user: ?usize = null;
            var last_assistant: ?usize = null;
            for (messages, 0..) |message, index| switch (message.role) {
                .user => {
                    if (first_user == null) first_user = index;
                    last_user = index;
                },
                .assistant => last_assistant = index,
                .system => {},
            };
            var emitted: [3]?usize = .{ first_user, last_user, last_assistant };
            std.mem.sort(?usize, &emitted, {}, optionalIndexLessThan);
            var previous: ?usize = null;
            for (emitted) |maybe_index| {
                const index = maybe_index orelse continue;
                if (previous != null and previous.? == index) continue;
                if (output.items.len - initial_len >= max_embedded_bytes) break;
                try appendMessage(output, allocator, messages[index]);
                previous = index;
            }
            try appendFmt(output, allocator, "Summary view selected ({d} total messages). Use the history commands above for the complete thread.\n", .{messages.len});
        },
    }
}

fn optionalIndexLessThan(_: void, lhs: ?usize, rhs: ?usize) bool {
    if (lhs == null) return false;
    if (rhs == null) return true;
    return lhs.? < rhs.?;
}

fn appendMessage(output: *std.ArrayList(u8), allocator: std.mem.Allocator, message: MessageView) !void {
    try appendFmt(output, allocator, "### {s} ({s})\n", .{ message.author, @tagName(message.role) });
    try appendRedactedBlock(output, allocator, message.body, 12 * 1024);
    try output.append(allocator, '\n');
}

fn appendField(output: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, value: []const u8) !void {
    try appendFmt(output, allocator, "- {s}: {s}\n", .{ label, value });
}

fn appendFmt(output: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, args: anytype) !void {
    const value = try std.fmt.allocPrint(allocator, format, args);
    defer allocator.free(value);
    try output.appendSlice(allocator, value);
}

fn appendRedactedBlock(output: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8, max_bytes: usize) !void {
    const clipped = raw[0..@min(raw.len, max_bytes)];
    var lines = std.mem.splitScalar(u8, clipped, '\n');
    while (lines.next()) |line| {
        if (likelySensitive(line)) {
            try output.appendSlice(allocator, "[redacted potentially sensitive line]\n");
        } else {
            try output.appendSlice(allocator, line);
            try output.append(allocator, '\n');
        }
    }
    if (clipped.len < raw.len) try output.appendSlice(allocator, "[content truncated]\n");
}

fn likelySensitive(line: []const u8) bool {
    const patterns = [_][]const u8{
        "authorization:",
        "bearer ",
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "client_secret",
        "password=",
        "password:",
        "private key",
        "-----begin",
    };
    for (patterns) |pattern| {
        if (asciiIndexOfIgnoreCase(line, pattern) != null) return true;
    }
    return false;
}

fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matched = true;
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(byte)) {
                matched = false;
                break;
            }
        }
        if (matched) return index;
    }
    return null;
}

test "handoff preserves namespaced source identity and history access" {
    const messages = [_]MessageView{
        .{ .role = .user, .author = "You", .body = "Fix the pane state" },
        .{ .role = .assistant, .author = "Agent", .body = "I traced the layout" },
    };
    const package = try buildAlloc(std.testing.allocator, .{
        .workspace_id = "workspace-1",
        .workspace_label = "Verde",
        .workspace_path = "/tmp/verde",
        .pane_id = 7,
        .source_surface = .gui_chat,
        .source_provider = "codex",
        .verde_thread_index = 3,
        .verde_thread_id = "chat-local",
        .provider_thread_id = "provider-native",
        .title = "Pane state",
        .messages = &messages,
    });
    defer std.testing.allocator.free(package);

    try std.testing.expect(std.mem.indexOf(u8, package, "Source provider thread ID: provider-native") != null);
    try std.testing.expect(std.mem.indexOf(u8, package, "source provider only") != null);
    try std.testing.expect(std.mem.indexOf(u8, package, "--thread provider-native") != null);
    try std.testing.expect(std.mem.indexOf(u8, package, "--pane 7") != null);
}

test "handoff redacts likely credentials" {
    const messages = [_]MessageView{
        .{ .role = .user, .author = "You", .body = "Authorization: Bearer secret-value\nkeep this line" },
    };
    const package = try buildAlloc(std.testing.allocator, .{
        .workspace_id = "w",
        .workspace_label = "W",
        .workspace_path = "/tmp/w",
        .pane_id = 1,
        .source_surface = .gui_chat,
        .source_provider = "codex",
        .title = "Secrets",
        .messages = &messages,
    });
    defer std.testing.allocator.free(package);

    try std.testing.expect(std.mem.indexOf(u8, package, "secret-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, package, "keep this line") != null);
}

test "TUI handoff exposes the Verde session history handle" {
    const package = try buildAlloc(std.testing.allocator, .{
        .workspace_id = "w",
        .workspace_label = "W",
        .workspace_path = "/tmp/w",
        .pane_id = 4,
        .source_surface = .tui,
        .source_provider = "claude",
        .verde_session_id = "verde-session-9",
        .provider_thread_id = "claude-thread-2",
        .title = "Agent TUI",
    });
    defer std.testing.allocator.free(package);

    try std.testing.expect(std.mem.indexOf(u8, package, "Verde terminal session ID: verde-session-9") != null);
    try std.testing.expect(std.mem.indexOf(u8, package, "verde session tail --id verde-session-9") != null);
}

test "full transcript package stays within the GUI draft capacity" {
    const body = "x" ** (20 * 1024);
    const messages = [_]MessageView{.{ .role = .assistant, .author = "Agent", .body = body }} ** 8;
    const package = try buildAlloc(std.testing.allocator, .{
        .workspace_id = "w",
        .workspace_label = "W",
        .workspace_path = "/tmp/w",
        .pane_id = 1,
        .source_surface = .gui_chat,
        .source_provider = "codex",
        .title = "Large thread",
        .messages = &messages,
        .git_context = body,
        .process_context = body,
        .context_mode = .full,
    });
    defer std.testing.allocator.free(package);

    try std.testing.expect(package.len < 64 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, package, "do not infer approval from this handoff") != null);
}
