//! Wire DTOs for the daemon-owned M3 state store.
//!
//! This module deliberately contains only JSON-safe protocol data.  It does
//! not import the desktop state model or the SQLite implementation.

const std = @import("std");
const protocol = @import("protocol.zig");
// The composite snapshot references the volatile registry DTOs directly so
// the envelope has exactly one wire definition (m5_design §2 module-edge choice).
const registry_protocol = @import("registry_protocol.zig");

// Stable storage method names.  These are wire identifiers, not dispatcher
// implementation names, and must not be changed after publication.
pub const METHOD_STATE_SNAPSHOT_REPLACE: []const u8 = "state.snapshot.replace";
pub const METHOD_WORKSPACE_UPSERT: []const u8 = "workspace.upsert";
pub const METHOD_CHAT_THREAD_UPSERT: []const u8 = "chat.thread.upsert";
pub const METHOD_CHAT_MESSAGE_APPEND: []const u8 = "chat.message.append";
pub const METHOD_SURFACE_UPSERT: []const u8 = "surface.upsert";
pub const METHOD_SURFACE_CLEAR: []const u8 = "surface.clear";
pub const METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT: []const u8 =
    "notification.chatCompletion.upsert";
pub const METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR: []const u8 =
    "notification.chatCompletion.clear";
pub const METHOD_CORE_SNAPSHOT: []const u8 = "core.snapshot";
pub const METHOD_DAEMON_STORE_STATUS: []const u8 = "daemon.storeStatus";
pub const METHOD_CHAT_THREAD_GET: []const u8 = "chat.thread.get";
pub const METHOD_CHAT_THREAD_LIST: []const u8 = "chat.thread.list";
pub const METHOD_CHAT_TURN_RECORD: []const u8 = "chat.turn.record";

pub const STATE_SNAPSHOT_REPLACE_METHOD = METHOD_STATE_SNAPSHOT_REPLACE;
pub const WORKSPACE_UPSERT_METHOD = METHOD_WORKSPACE_UPSERT;
pub const CHAT_THREAD_UPSERT_METHOD = METHOD_CHAT_THREAD_UPSERT;
pub const CHAT_MESSAGE_APPEND_METHOD = METHOD_CHAT_MESSAGE_APPEND;
pub const SURFACE_UPSERT_METHOD = METHOD_SURFACE_UPSERT;
pub const SURFACE_CLEAR_METHOD = METHOD_SURFACE_CLEAR;
pub const NOTIFICATION_CHAT_COMPLETION_UPSERT_METHOD = METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT;
pub const NOTIFICATION_CHAT_COMPLETION_CLEAR_METHOD = METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR;
pub const CORE_SNAPSHOT_METHOD = METHOD_CORE_SNAPSHOT;
pub const DAEMON_STORE_STATUS_METHOD = METHOD_DAEMON_STORE_STATUS;
pub const CHAT_THREAD_GET_METHOD = METHOD_CHAT_THREAD_GET;
pub const CHAT_THREAD_LIST_METHOD = METHOD_CHAT_THREAD_LIST;
pub const CHAT_TURN_RECORD_METHOD = METHOD_CHAT_TURN_RECORD;

// Re-export the shared storage error names from the one protocol error owner.
pub const ERR_CONFLICT = protocol.ERR_CONFLICT;
pub const ERR_INVALID_PARAMS = protocol.ERR_INVALID_PARAMS;
pub const ERR_RESOURCE_NOT_FOUND = protocol.ERR_RESOURCE_NOT_FOUND;
pub const ERR_INVALID_STATE = protocol.ERR_INVALID_STATE;
pub const ERR_CAPABILITY_UNAVAILABLE = protocol.ERR_CAPABILITY_UNAVAILABLE;
pub const ERR_INTERNAL = protocol.ERR_INTERNAL;
pub const ERR_STORE_BUSY = protocol.ERR_STORE_BUSY;
pub const ERR_SCHEMA_TOO_NEW = protocol.ERR_SCHEMA_TOO_NEW;
pub const ERR_STORE_CORRUPT = protocol.ERR_STORE_CORRUPT;
pub const ERR_STORE_UNAVAILABLE = protocol.ERR_STORE_UNAVAILABLE;

/// Common metadata carried by every store mutation.
pub const MutationHeader = struct {
    /// Stable retry identity for the logical mutation.  This is not the RPC id.
    request_key: []const u8,
    /// Optimistic-concurrency guard for the durable store revision.
    expected_store_revision: ?u64 = null,
    /// Opaque ID issued by daemon.client.register.
    client_id: []const u8,
};

/// Receipt returned after a store mutation commits, or after a recognized retry.
pub const WriteResult = struct {
    store_revision: u64,
    applied: bool,
    duplicate: bool = false,
};

/// A daemon-hosted file or a future remote-safe attachment reference.
pub const Attachment = struct {
    path: []const u8,
    mime: []const u8,
    byte_size: usize = 0,
    attachment_id: ?[]const u8 = null,
};

/// Compatibility metadata for a workspace's durable Herdr link.
pub const HerdrWorkspaceLink = struct {
    remote_alias: []const u8 = "",
    session_name: []const u8,
    workspace_id: []const u8,
    local_dir: []const u8,
    remote_cwd: ?[]const u8 = null,
    last_pane_id: ?[]const u8 = null,
    attach_dock_id: ?u32 = null,
    attach_pane_id: ?u32 = null,
    pane_links_json: ?[]const u8 = null,
    updated_at_ms: i64 = 0,
};

/// Durable workspace metadata plus compatibility presentation fields.
pub const Workspace = struct {
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    archived: bool = false,
    unread_count: u32 = 0,
    collapsed: ?bool = null,
    thread_list_expanded: ?bool = null,
    terminal_height: ?f32 = null,
    terminal_layout_json: ?[]const u8 = null,
    terminal_docks_json: ?[]const u8 = null,
    workspace_layout_json: ?[]const u8 = null,
    /// Client-scoped compatibility state retained while snapshot replacement exists.
    selected_thread_index: usize = 0,
    companion_thread_local_id: ?[]const u8 = null,
    herdr_link: ?HerdrWorkspaceLink = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
    draft: []const u8 = "",
    threads: []const Thread = &.{},
    messages: []const Message = &.{},
};

/// A durable transcript row.  Role/provider/tool values remain strings so new
/// daemon variants can pass through older clients.
pub const Message = struct {
    /// Legacy snapshot rows may omit this field; chat.message.append must
    /// reject an empty message ID with invalid_params.
    message_id: []const u8 = "",
    role: []const u8,
    author: []const u8,
    body: []const u8,
    images: []const Attachment = &.{},
    /// Legacy single-image compatibility field used by the pre-M3 snapshot.
    image: ?Attachment = null,
    tool_call_id: ?[]const u8 = null,
    tool_call_kind: ?[]const u8 = null,
    tool_call_status: ?[]const u8 = null,
    created_at_ms: ?i64 = null,
    updated_at_ms: ?i64 = null,
};

/// Thread metadata keyed by (workspace_id, local_thread_id).
pub const Thread = struct {
    local_thread_id: []const u8,
    title: []const u8,
    archived: bool = false,
    committed: bool = true,
    last_activity_at: ?i64 = null,
    provider_thread_id: ?[]const u8 = null,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    reasoning_variant: ?[]const u8 = null,
    fast_mode: ?[]const u8 = null,
    access_mode: ?[]const u8 = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
    tui_dock_id: ?u32 = null,
    draft: []const u8 = "",
    draft_image: ?Attachment = null,
    draft_images: []const Attachment = &.{},
    messages: []const Message = &.{},
};

/// Durable state for one terminal surface.
pub const SurfaceState = struct {
    session_id: []const u8,
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    dock_id: u32 = 0,
    pane_id: ?u32 = null,
    provider: ?[]const u8 = null,
    provider_thread_id: ?[]const u8 = null,
    title: []const u8 = "",
    status: []const u8 = "idle",
    status_changed_at_ms: i64 = 0,
    completed_at_ms: i64 = 0,
    last_event_title: ?[]const u8 = null,
    last_event_body: ?[]const u8 = null,
};

/// Legacy completion notification ledger row.
pub const ChatCompletion = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    completed_at_ms: i64,
};

/// Compatibility snapshot transported through state.snapshot.replace.
pub const Snapshot = struct {
    schema_version: u32 = 1,
    store_revision: u64 = 0,
    selected_workspace_index: usize = 0,
    sidebar_collapsed: bool = false,
    workspaces: []const Workspace = &.{},
    surface_states: []const SurfaceState = &.{},
    chat_completions: []const ChatCompletion = &.{},
    provider: ?[]const u8 = null,
    harness: ?[]const u8 = null,
    draft: ?[]const u8 = null,
    messages: ?[]const Message = null,
};

/// Request for the transitional whole-state replacement.
pub const SnapshotReplaceRequest = struct {
    mutation: MutationHeader,
    snapshot: Snapshot,
    /// Only bootstrap may omit the expected revision guard.
    bootstrap: bool = false,
};

pub const WorkspaceUpsertRequest = struct {
    mutation: MutationHeader,
    workspace: Workspace,
};

pub const ThreadUpsertRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    thread: Thread,
};

pub const MessageAppendRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    thread_id: []const u8,
    message: Message,
};

pub const SurfaceUpsertRequest = struct {
    mutation: MutationHeader,
    surface: SurfaceState,
};

pub const SurfaceClearRequest = struct {
    mutation: MutationHeader,
    session_id: []const u8,
    workspace_id: ?[]const u8 = null,
};

pub const NotificationChatCompletionUpsertRequest = struct {
    mutation: MutationHeader,
    completion: ChatCompletion,
};

pub const NotificationChatCompletionClearRequest = struct {
    mutation: MutationHeader,
    workspace_id: []const u8,
    local_thread_id: []const u8,
};

// Frozen scope names for the M5 composite core.snapshot request.  An absent
// scopes field means store-only, preserving the M3 shape.
pub const SNAPSHOT_SCOPE_STORE: []const u8 = "store";
pub const SNAPSHOT_SCOPE_REGISTRY: []const u8 = "registry";
pub const SNAPSHOT_SCOPE_SESSIONS: []const u8 = "sessions";
pub const SNAPSHOT_SCOPE_TURNS: []const u8 = "turns";

/// Optional filters for a coherent daemon snapshot read.
pub const CoreSnapshotRequest = struct {
    workspace_id: ?[]const u8 = null,
    after_store_revision: ?u64 = null,
    /// M5 additive scope selection (SNAPSHOT_SCOPE_* names).  Null keeps the
    /// M3 store-only behavior so old clients never change meaning.
    scopes: ?[]const []const u8 = null,
};

/// Volatile terminal-session summary for the composite snapshot's `sessions`
/// scope.  Field names mirror the established session.list summary wire names.
pub const SessionSummary = struct {
    session_id: []const u8 = "",
    workspace_id: []const u8 = "",
    workspace_path: []const u8 = "",
    cwd: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    dock_id: ?u32 = null,
    pane_id: ?u32 = null,
    pid: ?i64 = null,
    running: bool = false,
    status: []const u8 = "",
    exit_status: ?i64 = null,
};

pub const CoreSnapshotResult = struct {
    snapshot: Snapshot,
    store_revision: u64,
    // M5 additive composite sections.  Every default is absent/empty so the
    // M3 store-only result shape decodes unchanged when no scopes were asked.
    /// Volatile revision namespace; present when any volatile scope was read.
    envelope: ?registry_protocol.RegistryRevisionEnvelope = null,
    /// Journal cursor to start core.changes polling from this snapshot.
    change_cursor: ?u64 = null,
    processes: []const registry_protocol.ProcessSnapshot = &.{},
    leases: []const registry_protocol.LeaseRecord = &.{},
    sessions: []const SessionSummary = &.{},
    turns: []const TurnRecord = &.{},
    /// Scopes the daemon could not fully serve yet (e.g. chat before the
    /// M4-P4 authority flip).  Honest partial snapshots instead of blocking.
    incomplete_scopes: []const []const u8 = &.{},
};

/// The status request is intentionally empty; the daemon chooses its current
/// queue/drain state rather than trusting client-supplied flags.
pub const StoreStatusRequest = struct {};

pub const StoreStatusResult = struct {
    schema_version: u32 = 0,
    store_revision: u64 = 0,
    writer_ready: bool = false,
    queued_mutation_count: usize = 0,
    drain_state: []const u8 = "open",
};

/// Identifies one durable thread for a direct transcript read.
pub const ThreadGetRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
};

/// A bounded thread-list row. Messages are deliberately absent from this DTO.
pub const ThreadListItem = struct {
    local_thread_id: []const u8,
    title: []const u8,
    archived: bool = false,
    committed: bool = true,
    last_activity_at: ?i64 = null,
    provider_thread_id: ?[]const u8 = null,
    model_ref: ?[]const u8 = null,
    provider: []const u8 = "opencode",
    harness: []const u8 = "local_cli",
};

/// One durable thread and the revision from which it was read.
pub const ThreadGetResult = struct {
    thread: Thread,
    store_revision: u64,
};

/// Bounded per-workspace thread metadata query.
pub const ThreadListRequest = struct {
    workspace_id: []const u8,
    limit: u32 = 100,
    cursor: ?[]const u8 = null,
};

/// Bounded per-workspace thread metadata result.
pub const ThreadListResult = struct {
    threads: []const ThreadListItem = &.{},
    next_cursor: ?[]const u8 = null,
    store_revision: u64 = 0,
};

/// Durable summary of one accepted chat turn.
pub const TurnRecord = struct {
    turn_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    status: []const u8,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    provider: []const u8,
    provider_thread_id: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    user_message_id: ?[]const u8 = null,
    committed_store_revision: ?u64 = null,
};

/// Direct lookup request for one durable turn ledger row.
pub const TurnRecordRequest = struct {
    turn_id: []const u8,
};

/// Compatibility names for callers that describe list rows as summaries.
pub const ThreadSummary = ThreadListItem;
pub const ThreadListEntry = ThreadListItem;

// Descriptive aliases keep the wire vocabulary usable at call sites without
// introducing duplicate representations.
pub const ImageAttachment = Attachment;
pub const Surface = SurfaceState;
pub const CompletionLedgerEntry = ChatCompletion;
pub const SnapshotQueryRequest = CoreSnapshotRequest;
pub const SnapshotQueryResult = CoreSnapshotResult;

/// Encode any store DTO using the standard JSON object representation.
pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.write(value);
    return try writer.toOwnedSlice();
}

/// Decode a store DTO while ignoring fields introduced by a newer peer.
pub fn decode(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

/// Decode a store DTO into allocations owned by the caller's arena.
pub fn decodeLeaky(comptime T: type, allocator: std.mem.Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

test "store DTOs round trip every wire shape" {
    const allocator = std.testing.allocator;
    const attachment: Attachment = .{
        .path = "/tmp/image.png",
        .mime = "image/png",
        .byte_size = 12,
        .attachment_id = "att-1",
    };
    const message: Message = .{
        .message_id = "msg-1",
        .role = "assistant",
        .author = "daemon",
        .body = "hello",
        .images = &.{attachment},
        .image = attachment,
        .tool_call_id = "tool-1",
        .tool_call_kind = "shell",
        .tool_call_status = "completed",
        .created_at_ms = 10,
        .updated_at_ms = 11,
    };
    const thread: Thread = .{
        .local_thread_id = "thread-1",
        .title = "A thread",
        .archived = true,
        .committed = false,
        .last_activity_at = 20,
        .provider_thread_id = "provider-1",
        .model_ref = "model-1",
        .reasoning_effort = "high",
        .reasoning_variant = "balanced",
        .fast_mode = "on",
        .access_mode = "full_access",
        .provider = "codex",
        .harness = "local_cli",
        .tui_dock_id = 3,
        .draft = "draft",
        .draft_image = attachment,
        .draft_images = &.{attachment},
        .messages = &.{message},
    };
    const link: HerdrWorkspaceLink = .{
        .remote_alias = "origin",
        .session_name = "verde",
        .workspace_id = "workspace-1",
        .local_dir = "/work",
        .remote_cwd = "/remote/work",
        .last_pane_id = "pane-1",
        .attach_dock_id = 4,
        .attach_pane_id = 5,
        .pane_links_json = "[]",
        .updated_at_ms = 30,
    };
    const workspace: Workspace = .{
        .workspace_id = "workspace-1",
        .label = "Workspace",
        .path = "/work",
        .archived = true,
        .unread_count = 2,
        .collapsed = true,
        .thread_list_expanded = false,
        .terminal_height = 42.5,
        .terminal_layout_json = "{}",
        .terminal_docks_json = "[]",
        .workspace_layout_json = "{}",
        .selected_thread_index = 1,
        .companion_thread_local_id = "thread-1",
        .herdr_link = link,
        .provider = "codex",
        .harness = "local_cli",
        .draft = "workspace draft",
        .threads = &.{thread},
        .messages = &.{message},
    };
    const surface: SurfaceState = .{
        .session_id = "session-1",
        .workspace_id = "workspace-1",
        .workspace_path = "/work",
        .dock_id = 6,
        .pane_id = 7,
        .provider = "codex",
        .provider_thread_id = "provider-1",
        .title = "Build",
        .status = "working",
        .status_changed_at_ms = 40,
        .completed_at_ms = 41,
        .last_event_title = "Ran command",
        .last_event_body = "zig build",
    };
    const completion: ChatCompletion = .{
        .workspace_id = "workspace-1",
        .local_thread_id = "thread-1",
        .completed_at_ms = 43,
    };
    const snapshot: Snapshot = .{
        .schema_version = 2,
        .store_revision = 8,
        .selected_workspace_index = 1,
        .sidebar_collapsed = true,
        .workspaces = &.{workspace},
        .surface_states = &.{surface},
        .chat_completions = &.{completion},
        .provider = "codex",
        .harness = "local_cli",
        .draft = "global draft",
        .messages = &.{message},
    };
    const mutation: MutationHeader = .{
        .request_key = "request-1",
        .expected_store_revision = 7,
        .client_id = "client-1",
    };
    const thread_list_item: ThreadListItem = .{
        .local_thread_id = "thread-1",
        .title = "A thread",
        .archived = true,
        .committed = false,
        .last_activity_at = 20,
        .provider_thread_id = "provider-1",
        .model_ref = "model-1",
        .provider = "codex",
        .harness = "local_cli",
    };
    const turn_record: TurnRecord = .{
        .turn_id = "turn-1",
        .workspace_id = "workspace-1",
        .local_thread_id = "thread-1",
        .status = "completed",
        .started_at_ms = 50,
        .finished_at_ms = 60,
        .provider = "codex",
        .provider_thread_id = "provider-1",
        .error_message = null,
        .user_message_id = "message-1",
        .committed_store_revision = 9,
    };

    const values = .{
        mutation,
        WriteResult{ .store_revision = 8, .applied = true, .duplicate = false },
        attachment,
        link,
        message,
        thread,
        workspace,
        surface,
        completion,
        snapshot,
        SnapshotReplaceRequest{ .mutation = mutation, .snapshot = snapshot },
        WorkspaceUpsertRequest{ .mutation = mutation, .workspace = workspace },
        ThreadUpsertRequest{ .mutation = mutation, .workspace_id = "workspace-1", .thread = thread },
        MessageAppendRequest{ .mutation = mutation, .workspace_id = "workspace-1", .thread_id = "thread-1", .message = message },
        SurfaceUpsertRequest{ .mutation = mutation, .surface = surface },
        SurfaceClearRequest{ .mutation = mutation, .session_id = "session-1", .workspace_id = "workspace-1" },
        NotificationChatCompletionUpsertRequest{ .mutation = mutation, .completion = completion },
        NotificationChatCompletionClearRequest{ .mutation = mutation, .workspace_id = "workspace-1", .local_thread_id = "thread-1" },
        CoreSnapshotRequest{ .workspace_id = "workspace-1", .after_store_revision = 7 },
        CoreSnapshotRequest{
            .workspace_id = "workspace-1",
            .scopes = &.{ SNAPSHOT_SCOPE_STORE, SNAPSHOT_SCOPE_REGISTRY, SNAPSHOT_SCOPE_SESSIONS, SNAPSHOT_SCOPE_TURNS },
        },
        CoreSnapshotResult{ .snapshot = snapshot, .store_revision = 8 },
        CoreSnapshotResult{
            .snapshot = snapshot,
            .store_revision = 8,
            .envelope = .{ .instance_nonce = "daemon-a", .registry_revision = 12 },
            .change_cursor = 6,
            .processes = &.{.{ .id = "p1", .workspace_id = "workspace-1", .status = .running }},
            .leases = &.{.{ .workspace_id = "workspace-1", .id = "l1", .owner = "agent", .client_id = "client-1" }},
            .sessions = &.{.{
                .session_id = "session-1",
                .workspace_id = "workspace-1",
                .workspace_path = "/work",
                .cwd = "/work",
                .label = "Build",
                .command = "zig build",
                .dock_id = 6,
                .pane_id = 7,
                .pid = 4242,
                .running = true,
                .status = "running",
            }},
            .turns = &.{turn_record},
            .incomplete_scopes = &.{SNAPSHOT_SCOPE_TURNS},
        },
        StoreStatusRequest{},
        StoreStatusResult{ .schema_version = 2, .store_revision = 8, .writer_ready = true, .queued_mutation_count = 0, .drain_state = "open" },
        SnapshotReplaceRequest{ .mutation = mutation, .snapshot = snapshot, .bootstrap = true },
        ThreadGetRequest{ .workspace_id = "workspace-1", .local_thread_id = "thread-1" },
        ThreadListItem{ .local_thread_id = "thread-1", .title = "A thread", .archived = true, .committed = false, .last_activity_at = 20, .provider_thread_id = "provider-1", .model_ref = "model-1", .provider = "codex", .harness = "local_cli" },
        ThreadGetResult{ .thread = thread, .store_revision = 8 },
        ThreadListRequest{ .workspace_id = "workspace-1", .limit = 25, .cursor = "cursor-1" },
        ThreadListResult{ .threads = &.{thread_list_item}, .next_cursor = "cursor-2", .store_revision = 8 },
        turn_record,
        TurnRecordRequest{ .turn_id = "turn-1" },
    };
    inline for (values) |value| {
        const T = @TypeOf(value);
        const bytes = try encode(allocator, value);
        defer allocator.free(bytes);
        var parsed = try decode(T, allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqualDeep(value, parsed.value);
    }
}

test "request keys make duplicate receipts recognizable" {
    const allocator = std.testing.allocator;
    const first: WriteResult = .{ .store_revision = 9, .applied = true };
    const retry: WriteResult = .{ .store_revision = 9, .applied = false, .duplicate = true };
    const mutation: MutationHeader = .{ .request_key = "same-key", .client_id = "client" };
    const request: WorkspaceUpsertRequest = .{
        .mutation = mutation,
        .workspace = .{ .workspace_id = "workspace", .label = "W", .path = "/w" },
    };
    const bytes = try encode(allocator, request);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "same-key") != null);
    var parsed = try decode(WorkspaceUpsertRequest, allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("same-key", parsed.value.mutation.request_key);
    const retry_bytes = try encode(allocator, retry);
    defer allocator.free(retry_bytes);
    var parsed_retry = try decode(WriteResult, allocator, retry_bytes);
    defer parsed_retry.deinit();
    try std.testing.expect(first.store_revision == retry.store_revision);
    try std.testing.expect(!parsed_retry.value.applied);
    try std.testing.expect(parsed_retry.value.duplicate);
}

test "unknown fields and absent optionals are tolerated" {
    const allocator = std.testing.allocator;
    const raw =
        "{\"request_key\":\"hand-written\",\"client_id\":\"client\",\"future_field\":true}";
    var parsed = try decode(MutationHeader, allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("hand-written", parsed.value.request_key);
    try std.testing.expectEqualStrings("client", parsed.value.client_id);
    try std.testing.expect(parsed.value.expected_store_revision == null);

    var status = try decode(StoreStatusResult, allocator, "{\"store_revision\":4,\"future\":{}}");
    defer status.deinit();
    try std.testing.expectEqual(@as(u64, 4), status.value.store_revision);
    try std.testing.expectEqual(@as(u32, 0), status.value.schema_version);
    try std.testing.expect(!status.value.writer_ready);
    try std.testing.expectEqualStrings("open", status.value.drain_state);

    var surface = try decode(SurfaceState, allocator, "{\"session_id\":\"s\"}");
    defer surface.deinit();
    try std.testing.expectEqualStrings("idle", surface.value.status);

    var list = try decode(ThreadListResult, allocator, "{\"threads\":[{\"local_thread_id\":\"t\",\"title\":\"T\",\"future\":true}],\"future_result\":1}");
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.value.threads.len);
    try std.testing.expectEqualStrings("t", list.value.threads[0].local_thread_id);
    try std.testing.expectEqual(@as(u64, 0), list.value.store_revision);
}

test "decode owns strings after the input buffer is released" {
    const allocator = std.testing.allocator;
    const json =
        "{\"mutation\":{\"request_key\":\"request\",\"client_id\":\"client\"}," ++
        "\"workspace_id\":\"workspace\",\"thread_id\":\"thread\",\"message\":{" ++
        "\"message_id\":\"message\",\"role\":\"user\",\"author\":\"author\",\"body\":\"body\"}}";
    const input = try allocator.dupe(u8, json);
    var input_owned = true;
    defer if (input_owned) allocator.free(input);

    var parsed = try decode(MessageAppendRequest, allocator, input);
    defer parsed.deinit();

    @memset(input, 0xa5);
    allocator.free(input);
    input_owned = false;

    try std.testing.expectEqualStrings("request", parsed.value.mutation.request_key);
    try std.testing.expectEqualStrings("client", parsed.value.mutation.client_id);
    try std.testing.expectEqualStrings("workspace", parsed.value.workspace_id);
    try std.testing.expectEqualStrings("thread", parsed.value.thread_id);
    try std.testing.expectEqualStrings("message", parsed.value.message.message_id);
    try std.testing.expectEqualStrings("user", parsed.value.message.role);
    try std.testing.expectEqualStrings("author", parsed.value.message.author);
    try std.testing.expectEqualStrings("body", parsed.value.message.body);
}

test "M3 core.snapshot shapes are byte-compatible when scopes are absent" {
    const allocator = std.testing.allocator;
    // Frozen copies of the M3 wire shapes, exactly as published before M5.
    const M3CoreSnapshotRequest = struct {
        workspace_id: ?[]const u8 = null,
        after_store_revision: ?u64 = null,
    };
    const M3CoreSnapshotResult = struct {
        snapshot: Snapshot,
        store_revision: u64,
    };

    // Old-shape request bytes decode into the new struct with scopes absent.
    const m3_request: M3CoreSnapshotRequest = .{
        .workspace_id = "workspace-1",
        .after_store_revision = 7,
    };
    const m3_request_bytes = try encode(allocator, m3_request);
    defer allocator.free(m3_request_bytes);
    try std.testing.expectEqualStrings(
        "{\"workspace_id\":\"workspace-1\",\"after_store_revision\":7}",
        m3_request_bytes,
    );
    var new_request = try decode(CoreSnapshotRequest, allocator, m3_request_bytes);
    defer new_request.deinit();
    try std.testing.expectEqualStrings("workspace-1", new_request.value.workspace_id.?);
    try std.testing.expectEqual(@as(?u64, 7), new_request.value.after_store_revision);
    try std.testing.expect(new_request.value.scopes == null);

    // Old-shape result bytes decode into the new struct with every composite
    // section defaulted to absent/empty.
    const m3_result: M3CoreSnapshotResult = .{ .snapshot = .{}, .store_revision = 8 };
    const m3_result_bytes = try encode(allocator, m3_result);
    defer allocator.free(m3_result_bytes);
    var new_result = try decode(CoreSnapshotResult, allocator, m3_result_bytes);
    defer new_result.deinit();
    try std.testing.expectEqual(@as(u64, 8), new_result.value.store_revision);
    try std.testing.expect(new_result.value.envelope == null);
    try std.testing.expect(new_result.value.change_cursor == null);
    try std.testing.expectEqual(@as(usize, 0), new_result.value.processes.len);
    try std.testing.expectEqual(@as(usize, 0), new_result.value.leases.len);
    try std.testing.expectEqual(@as(usize, 0), new_result.value.sessions.len);
    try std.testing.expectEqual(@as(usize, 0), new_result.value.turns.len);
    try std.testing.expectEqual(@as(usize, 0), new_result.value.incomplete_scopes.len);

    // New-struct encodes (scopes absent) still parse through the frozen M3
    // shapes, so pre-M5 peers keep reading the same values.
    const scopeless_request_bytes = try encode(allocator, CoreSnapshotRequest{
        .workspace_id = "workspace-1",
        .after_store_revision = 7,
    });
    defer allocator.free(scopeless_request_bytes);
    var old_request = try decode(M3CoreSnapshotRequest, allocator, scopeless_request_bytes);
    defer old_request.deinit();
    try std.testing.expectEqualDeep(m3_request, old_request.value);

    const scopeless_result_bytes = try encode(allocator, CoreSnapshotResult{
        .snapshot = .{},
        .store_revision = 8,
    });
    defer allocator.free(scopeless_result_bytes);
    var old_result = try decode(M3CoreSnapshotResult, allocator, scopeless_result_bytes);
    defer old_result.deinit();
    try std.testing.expectEqualDeep(m3_result, old_result.value);
}

test "store method names and error codes are pinned" {
    try std.testing.expectEqualStrings("state.snapshot.replace", METHOD_STATE_SNAPSHOT_REPLACE);
    try std.testing.expectEqualStrings("workspace.upsert", METHOD_WORKSPACE_UPSERT);
    try std.testing.expectEqualStrings("chat.thread.upsert", METHOD_CHAT_THREAD_UPSERT);
    try std.testing.expectEqualStrings("chat.message.append", METHOD_CHAT_MESSAGE_APPEND);
    try std.testing.expectEqualStrings("surface.upsert", METHOD_SURFACE_UPSERT);
    try std.testing.expectEqualStrings("surface.clear", METHOD_SURFACE_CLEAR);
    try std.testing.expectEqualStrings("notification.chatCompletion.upsert", METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT);
    try std.testing.expectEqualStrings("notification.chatCompletion.clear", METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR);
    try std.testing.expectEqualStrings("core.snapshot", METHOD_CORE_SNAPSHOT);
    try std.testing.expectEqualStrings("daemon.storeStatus", METHOD_DAEMON_STORE_STATUS);
    try std.testing.expectEqualStrings("chat.thread.get", METHOD_CHAT_THREAD_GET);
    try std.testing.expectEqualStrings("chat.thread.list", METHOD_CHAT_THREAD_LIST);
    try std.testing.expectEqualStrings("chat.turn.record", METHOD_CHAT_TURN_RECORD);
    try std.testing.expectEqualStrings("store", SNAPSHOT_SCOPE_STORE);
    try std.testing.expectEqualStrings("registry", SNAPSHOT_SCOPE_REGISTRY);
    try std.testing.expectEqualStrings("sessions", SNAPSHOT_SCOPE_SESSIONS);
    try std.testing.expectEqualStrings("turns", SNAPSHOT_SCOPE_TURNS);
    try std.testing.expectEqualStrings("conflict", ERR_CONFLICT);
    try std.testing.expectEqualStrings("store_busy", ERR_STORE_BUSY);
    try std.testing.expectEqualStrings("schema_too_new", ERR_SCHEMA_TOO_NEW);
    try std.testing.expectEqualStrings("store_corrupt", ERR_STORE_CORRUPT);
    try std.testing.expectEqualStrings("store_unavailable", ERR_STORE_UNAVAILABLE);
}
