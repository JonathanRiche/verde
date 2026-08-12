//! Review-mode snapshot used when the session daemon is not reachable.

const std = @import("std");
const headless = @import("headless");

const protocol = headless.protocol;
const store = headless.store_protocol;
const changes = headless.changes_protocol;

pub fn respond(allocator: std.mem.Allocator, request_json: []const u8) ![]u8 {
    var parsed = protocol.parseRequest(allocator, request_json) catch {
        return protocol.encodeErrorResponse(allocator, 0, protocol.ERR_INVALID_REQUEST, "invalid request");
    };
    defer parsed.deinit();
    return respondParsed(allocator, parsed.request);
}

pub fn respondParsed(allocator: std.mem.Allocator, request: protocol.Request) ![]u8 {
    const id = request.id;
    if (std.mem.eql(u8, request.method, "core.status")) {
        return protocol.encodeOkResponse(allocator, id, statusResult());
    }
    if (std.mem.eql(u8, request.method, "core.capabilities")) {
        return protocol.encodeOkResponse(allocator, id, capabilitiesResult());
    }
    if (std.mem.eql(u8, request.method, store.METHOD_CORE_SNAPSHOT)) {
        return protocol.encodeOkResponse(allocator, id, snapshotResult());
    }
    if (std.mem.eql(u8, request.method, changes.METHOD_CORE_CHANGES)) {
        return protocol.encodeOkResponse(allocator, id, changesResult());
    }
    if (std.mem.eql(u8, request.method, "workspaces") or std.mem.eql(u8, request.method, "workspace.list")) {
        return protocol.encodeOkResponse(allocator, id, workspaceListResult());
    }
    if (std.mem.eql(u8, request.method, "session.list")) {
        return protocol.encodeOkResponse(allocator, id, .{ .sessions = sessions });
    }
    if (std.mem.eql(u8, request.method, "chat.thread.get")) {
        return protocol.encodeOkResponse(allocator, id, .{ .thread = threads[0], .store_revision = 12 });
    }
    if (std.mem.eql(u8, request.method, "daemon.client.register")) {
        return protocol.encodeOkResponse(allocator, id, .{ .client_id = "web-mock-client", .persistent = false });
    }
    if (std.mem.eql(u8, request.method, "session.tail") or std.mem.eql(u8, request.method, "session.screen")) {
        return protocol.encodeOkResponse(allocator, id, .{
            .id = "sess-shell",
            .running = true,
            .text = "verde mock session\r\n$ ",
            .offset = 0,
            .next_offset = 22,
        });
    }
    return protocol.encodeErrorResponse(
        allocator,
        id,
        protocol.ERR_CAPABILITY_UNAVAILABLE,
        "daemon offline; only core.*, chat.thread.get, and session.list/tail are mocked",
    );
}

pub fn statusResult() protocol.StatusResult {
    return .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = 18,
        .pid = 0,
        .session_count = 2,
        .chat_turn_count = 1,
        .capabilities = .phase1(),
    };
}

pub fn capabilitiesResult() protocol.CapabilitiesResult {
    return .{
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = .phase1(),
    };
}

pub fn snapshotResult() store.CoreSnapshotResult {
    return .{
        .snapshot = .{
            .schema_version = 1,
            .store_revision = 12,
            .selected_workspace_index = 0,
            .sidebar_collapsed = false,
            .workspaces = &workspaces,
            .surface_states = &surfaces,
            .chat_completions = &.{},
        },
        .store_revision = 12,
        .change_cursor = 40,
        .sessions = &sessions,
        .turns = &turns,
        .incomplete_scopes = &.{},
    };
}

pub fn changesResult() changes.ChangesResult {
    return .{
        .entries = &.{},
        .next_cursor = 40,
        .journal_floor_seq = 1,
        .heartbeat = true,
        .store_revision = 12,
    };
}

const workspaces = [_]store.Workspace{
    .{
        .workspace_id = "ws-verde",
        .label = "verde-headless",
        .path = "/home/rtg/development/worktrees/verde/verde-headless",
        .unread_count = 1,
        .provider = "codex",
        .harness = "local_cli",
        .threads = &threads,
        .messages = &.{},
    },
    .{
        .workspace_id = "ws-website",
        .label = "website",
        .path = "/home/rtg/development/worktrees/verde/verde-headless/packages/website",
        .provider = "claude",
        .harness = "local_cli",
        .threads = &.{},
        .messages = &.{},
    },
};

const threads = [_]store.Thread{
    .{
        .local_thread_id = "thread-web-app",
        .title = "Scaffold the web client",
        .last_activity_at = 1_780_000_000_000,
        .model_ref = "gpt-5.3-codex",
        .access_mode = "supervised",
        .provider = "codex",
        .harness = "local_cli",
        .draft = "",
        .messages = &messages,
    },
    .{
        .local_thread_id = "thread-mobile",
        .title = "Mobile-first pane layout",
        .last_activity_at = 1_779_900_000_000,
        .model_ref = "opus-4.6",
        .provider = "claude",
        .harness = "local_cli",
        .messages = &.{},
    },
};

const messages = [_]store.Message{
    .{
        .message_id = "msg-user-1",
        .role = "user",
        .author = "you",
        .body = "Scaffold a Solid web client that talks to the headless daemon over a Zig gateway.",
        .created_at_ms = 1_779_800_000_000,
    },
    .{
        .message_id = "msg-cmd-1",
        .role = "system",
        .author = "codex",
        .body = "packages/web_app/build.zig",
        .tool_call_kind = "shell",
        .tool_call_status = "completed",
        .created_at_ms = 1_779_800_100_000,
    },
    .{
        .message_id = "msg-asst-1",
        .role = "assistant",
        .author = "codex",
        .body =
        \\The web client is a **first-party headless client**, not a second desktop.
        \\
        \\- Solid + Vite owns presentation
        \\- Zig owns the localhost HTTP/WebSocket hop
        \\- `core.snapshot` + `core.changes` keep the projection live
        \\
        \\On a phone you get one focused surface and a workspace drawer. On a wide screen the rail comes back.
        ,
        .created_at_ms = 1_779_800_200_000,
    },
};

const surfaces = [_]store.SurfaceState{
    .{
        .session_id = "sess-shell",
        .workspace_id = "ws-verde",
        .title = "fish",
        .status = "idle",
    },
    .{
        .session_id = "sess-grok",
        .workspace_id = "ws-verde",
        .provider = "grok",
        .title = "grok",
        .status = "working",
        .last_event_title = "Ran command",
    },
};

const sessions = [_]store.SessionSummary{
    .{
        .session_id = "sess-shell",
        .workspace_id = "ws-verde",
        .label = "fish",
        .command = "fish",
        .running = true,
        .status = "idle",
    },
    .{
        .session_id = "sess-grok",
        .workspace_id = "ws-verde",
        .label = "grok",
        .command = "grok",
        .running = true,
        .status = "working",
    },
};

const turns = [_]store.TurnRecord{
    .{
        .turn_id = "turn-1",
        .workspace_id = "ws-verde",
        .local_thread_id = "thread-web-app",
        .status = "completed",
        .started_at_ms = 1_779_800_000_000,
        .finished_at_ms = 1_779_800_400_000,
        .provider = "codex",
    },
};

const WorkspaceList = struct {
    selected_workspace_index: usize = 0,
    workspaces: []const WorkspaceListItem,
};

const WorkspaceListItem = struct {
    index: usize,
    id: []const u8,
    label: []const u8,
    path: []const u8,
    archived: bool = false,
    thread_count: usize,
    pane_count: usize,
};

fn workspaceListResult() WorkspaceList {
    return .{
        .workspaces = &.{
            .{
                .index = 0,
                .id = "ws-verde",
                .label = "verde-headless",
                .path = "/home/rtg/development/worktrees/verde/verde-headless",
                .thread_count = 2,
                .pane_count = 2,
            },
            .{
                .index = 1,
                .id = "ws-website",
                .label = "website",
                .path = "/home/rtg/development/worktrees/verde/verde-headless/packages/website",
                .thread_count = 0,
                .pane_count = 0,
            },
        },
    };
}

test "mock status encodes" {
    const json = try respondParsed(std.testing.allocator, .{
        .id = 7,
        .method = "core.status",
        .params = .null,
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pid\":0") != null);
}
