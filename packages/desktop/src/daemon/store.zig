//! Test-only phase-1 adapter for the daemon-owned SQLite store.
//!
//! Production construction is intentionally absent until the M3 authority
//! flip. The adapter owns the transaction, receipt, and durable revision
//! boundary while it is exercised against an explicitly supplied database path.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const schema = @import("../db/schema.zig");

const store_protocol = headless.store;

pub const StoreError = error{
    Conflict,
    InvalidParams,
    CapabilityUnavailable,
    Internal,
    StoreBusy,
    SchemaTooNew,
    StoreCorrupt,
    StoreUnavailable,
    OutOfMemory,
};

pub const Mutation = union(enum) {
    snapshot_replace: store_protocol.SnapshotReplaceRequest,
    workspace_upsert: store_protocol.WorkspaceUpsertRequest,
};

const SNAPSHOT_REPLACE_OPERATION = store_protocol.METHOD_STATE_SNAPSHOT_REPLACE;
const WORKSPACE_UPSERT_OPERATION = store_protocol.METHOD_WORKSPACE_UPSERT;
const STORE_ADAPTER_VERSION: i64 = 1;

// This is deliberately separate from PRAGMA user_version. These tables are a
// phase-1 stand-in; phase 2 must fold them into db/schema.zig's real v1 -> v2
// migration chain instead of silently extending the main schema version here.
// Phase 1 reconstructs WriteResult from its receipt; phase 2's real schema
// migration must add the response payload/status fields.
const STORE_METADATA_SQL: [:0]const u8 =
    \\create table if not exists daemon_store_meta (
    \\    id integer primary key check (id = 1),
    \\    adapter_version integer not null check (adapter_version >= 0)
    \\);
    \\create table if not exists daemon_store_state (
    \\    id integer primary key check (id = 1),
    \\    store_revision integer not null check (store_revision >= 0)
    \\);
    \\create table if not exists daemon_store_receipts (
    \\    request_key text primary key,
    \\    operation text not null,
    \\    fingerprint text not null,
    \\    store_revision integer not null check (store_revision >= 0)
    \\);
    \\create table if not exists daemon_store_message_keys (
    \\    thread_id integer not null,
    \\    message_id text not null,
    \\    sort_index integer not null,
    \\    created_at_ms integer,
    \\    updated_at_ms integer,
    \\    primary key (thread_id, message_id)
    \\);
;

pub const Store = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    path: [:0]u8,
    conn: zqlite.Conn,

    /// Open the exact database path as the phase-1 test adapter.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) StoreError!Self {
        const path = try allocator.dupeZ(u8, db_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = zqlite.open(path, flags) catch |err| return mapOpenError(err);
        errdefer conn.close();

        conn.busyTimeout(schema.BUSY_TIMEOUT_MS) catch |err| return mapOpenError(err);
        schema.initialize(conn) catch |err| return mapOpenError(err);
        ensureStoreMetadata(conn) catch |err| return mapOpenError(err);

        return .{
            .allocator = allocator,
            .path = path,
            .conn = conn,
        };
    }

    pub fn deinit(self: *Self) void {
        self.conn.close();
        self.allocator.free(self.path);
    }

    /// Return the durable revision currently recorded by the store.
    pub fn storeRevision(self: *const Self) StoreError!u64 {
        return self.readStoreRevision() catch |err| return mapStoreError(err);
    }

    /// Apply one supported mutation serially and return its durable receipt.
    pub fn applyMutation(self: *Self, mutation: Mutation) StoreError!store_protocol.WriteResult {
        const fingerprint = try self.mutationFingerprint(mutation);
        defer self.allocator.free(fingerprint);

        const operation = mutationOperation(mutation);
        validateMutation(mutation) catch |err| return err;

        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const prior_receipt = self.receiptFor(mutationHeader(mutation), operation, fingerprint) catch |err| return mapStoreError(err);
        if (prior_receipt) |result| {
            return result;
        }

        const current_revision = self.readStoreRevision() catch |err| return mapStoreError(err);
        try checkExpectedRevision(mutation, current_revision);

        switch (mutation) {
            .snapshot_replace => |request| self.applySnapshot(request.snapshot) catch |err| return mapStoreError(err),
            .workspace_upsert => |request| self.applyWorkspace(request.workspace) catch |err| return mapStoreError(err),
        }

        const next_revision = std.math.add(u64, current_revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;
        self.conn.exec(
            "update daemon_store_state set store_revision = ?1 where id = 1",
            .{next_revision_sql},
        ) catch |err| return mapStoreError(err);
        self.conn.exec(
            "insert into daemon_store_receipts (request_key, operation, fingerprint, store_revision) values (?1, ?2, ?3, ?4)",
            .{ mutationHeader(mutation).request_key, operation, fingerprint, next_revision_sql },
        ) catch |err| return mapStoreError(err);

        self.conn.commit() catch |err| return mapStoreError(err);
        transaction_open = false;
        return .{
            .store_revision = next_revision,
            .applied = true,
            .duplicate = false,
        };
    }

    /// Convenience entry point for the transitional snapshot command.
    pub fn replaceSnapshot(self: *Self, request: store_protocol.SnapshotReplaceRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .snapshot_replace = request });
    }

    /// Convenience entry point for the first granular phase-1 mutation.
    pub fn upsertWorkspace(self: *Self, request: store_protocol.WorkspaceUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_upsert = request });
    }

    fn readStoreRevision(self: *const Self) !u64 {
        const row = (try self.conn.row("select store_revision from daemon_store_state where id = 1", .{})) orelse
            return error.StoreMetadataMissing;
        defer row.deinit();
        const revision = row.int(0);
        if (revision < 0) return error.StoreCorrupt;
        return @intCast(revision);
    }

    fn receiptFor(
        self: *const Self,
        mutation: store_protocol.MutationHeader,
        operation: []const u8,
        fingerprint: []const u8,
    ) !?store_protocol.WriteResult {
        const row = (try self.conn.row(
            "select operation, fingerprint, store_revision from daemon_store_receipts where request_key = ?1",
            .{mutation.request_key},
        )) orelse return null;
        defer row.deinit();

        if (!std.mem.eql(u8, row.text(0), operation) or !std.mem.eql(u8, row.text(1), fingerprint)) {
            return error.Conflict;
        }
        const revision = row.int(2);
        if (revision < 0) return error.StoreCorrupt;
        return .{
            .store_revision = @intCast(revision),
            .applied = false,
            .duplicate = true,
        };
    }

    fn mutationFingerprint(self: *const Self, mutation: Mutation) StoreError![]u8 {
        return switch (mutation) {
            .snapshot_replace => |request| self.encodeFingerprint(.{
                .snapshot = request.snapshot,
                .bootstrap = request.bootstrap,
            }),
            .workspace_upsert => |request| self.encodeFingerprint(request.workspace),
        };
    }

    fn encodeFingerprint(self: *const Self, value: anytype) StoreError![]u8 {
        return store_protocol.encode(self.allocator, value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.Internal;
        };
    }

    fn applySnapshot(self: *Self, snapshot: store_protocol.Snapshot) !void {
        if (snapshot.schema_version != 1) return error.InvalidParams;

        try self.conn.execNoArgs(
            \\delete from daemon_store_message_keys;
            \\delete from messages;
            \\delete from threads;
            \\delete from app_state;
            \\delete from workspaces;
            \\delete from surface_completions;
            \\delete from chat_completions;
        );
        try self.conn.exec(
            "insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, ?1, ?2)",
            .{ @as(i64, @intCast(snapshot.selected_workspace_index)), boolToInt(snapshot.sidebar_collapsed) },
        );

        for (snapshot.workspaces, 0..) |workspace, workspace_index| {
            try self.insertWorkspace(workspace, workspace_index, snapshot, workspace_index == 0);
        }
        for (snapshot.surface_states) |surface| try self.insertSurface(surface);
        for (snapshot.chat_completions) |completion| try self.insertChatCompletion(completion);
    }

    fn applyWorkspace(self: *Self, workspace: store_protocol.Workspace) !void {
        if (workspace.workspace_id.len == 0 or workspace.label.len == 0 or workspace.path.len == 0) {
            return error.InvalidParams;
        }
        // A targeted workspace write must not smuggle transcript replacement
        // through the metadata operation. The snapshot command owns that path.
        if (workspace.threads.len != 0 or workspace.messages.len != 0) return error.InvalidParams;

        try self.conn.exec(
            "insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms) " ++
                "values (?1, coalesce((select max(sort_index) + 1 from workspaces), 0), ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24) " ++
                "on conflict(workspace_id) do update set label = excluded.label, path = excluded.path, archived = excluded.archived, unread_count = excluded.unread_count, collapsed = excluded.collapsed, thread_list_expanded = excluded.thread_list_expanded, terminal_height = excluded.terminal_height, terminal_layout_json = excluded.terminal_layout_json, terminal_docks_json = excluded.terminal_docks_json, workspace_layout_json = excluded.workspace_layout_json, selected_thread_index = excluded.selected_thread_index, companion_thread_local_id = excluded.companion_thread_local_id, herdr_remote_alias = excluded.herdr_remote_alias, herdr_session_name = excluded.herdr_session_name, herdr_workspace_id = excluded.herdr_workspace_id, herdr_local_dir = excluded.herdr_local_dir, herdr_remote_cwd = excluded.herdr_remote_cwd, herdr_last_pane_id = excluded.herdr_last_pane_id, herdr_attach_dock_id = excluded.herdr_attach_dock_id, herdr_attach_pane_id = excluded.herdr_attach_pane_id, herdr_pane_links_json = excluded.herdr_pane_links_json, herdr_updated_at_ms = excluded.herdr_updated_at_ms",
            workspaceValues(workspace, null),
        );
    }

    fn insertWorkspace(
        self: *Self,
        workspace: store_protocol.Workspace,
        workspace_index: usize,
        snapshot: store_protocol.Snapshot,
        is_first_workspace: bool,
    ) !void {
        if (workspace.workspace_id.len == 0 or workspace.label.len == 0 or workspace.path.len == 0) {
            return error.InvalidParams;
        }
        try self.conn.exec(
            "insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms) " ++
                "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)",
            workspaceValues(workspace, @as(i64, @intCast(workspace_index))),
        );
        // Capture the workspaces rowid before any other insert can change it.
        const workspace_row_id = self.conn.lastInsertedRowId();
        if (workspace.threads.len == 0) {
            const legacy_messages = if (workspace.messages.len != 0)
                workspace.messages
            else if (is_first_workspace)
                (snapshot.messages orelse &[_]store_protocol.Message{})
            else
                &[_]store_protocol.Message{};
            const provider = if (is_first_workspace) snapshot.provider orelse workspace.provider else workspace.provider;
            const harness = if (is_first_workspace) snapshot.harness orelse workspace.harness else workspace.harness;
            const draft = if (is_first_workspace) snapshot.draft orelse workspace.draft else workspace.draft;
            try self.insertThread(
                workspace_row_id,
                null,
                "New thread",
                workspace.archived,
                legacy_messages.len != 0,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                provider,
                harness,
                null,
                draft,
                null,
                &.{},
                legacy_messages,
            );
        } else {
            for (workspace.threads, 0..) |thread, thread_index| {
                try self.insertThread(
                    workspace_row_id,
                    @as(i64, @intCast(thread_index)),
                    thread.title,
                    thread.archived,
                    thread.committed,
                    thread.local_thread_id,
                    thread.last_activity_at,
                    thread.provider_thread_id,
                    thread.model_ref,
                    thread.reasoning_effort,
                    thread.reasoning_variant,
                    thread.fast_mode,
                    thread.access_mode,
                    thread.provider,
                    thread.harness,
                    thread.tui_dock_id,
                    thread.draft,
                    thread.draft_image,
                    thread.draft_images,
                    thread.messages,
                );
            }
        }
    }

    fn insertThread(
        self: *Self,
        workspace_row_id: i64,
        sort_index: ?i64,
        title: []const u8,
        archived: bool,
        committed: bool,
        local_thread_id: ?[]const u8,
        last_activity_at: ?i64,
        provider_thread_id: ?[]const u8,
        model_ref: ?[]const u8,
        reasoning_effort: ?[]const u8,
        reasoning_variant: ?[]const u8,
        fast_mode: ?[]const u8,
        access_mode: ?[]const u8,
        provider: []const u8,
        harness: []const u8,
        tui_dock_id: ?u32,
        draft: []const u8,
        draft_image: ?store_protocol.Attachment,
        draft_images: []const store_protocol.Attachment,
        messages: []const store_protocol.Message,
    ) !void {
        const provider_code = try providerCode(provider);
        const harness_code = try harnessCode(harness);
        const reasoning_code = if (reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (access_mode) |value| try accessModeCode(value) else null;
        const primary_draft_image = try firstAttachment(draft_image, draft_images);

        try self.conn.exec(
            "insert into threads (workspace_id, sort_index, title, archived, committed, local_thread_id, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, tui_dock_id, draft, draft_image_path, draft_image_mime, draft_image_byte_size) " ++
                "values (?1, coalesce(?2, (select coalesce(max(sort_index) + 1, 0) from threads where workspace_id = ?1)), ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
            .{
                workspace_row_id,
                sort_index,
                title,
                boolToInt(archived),
                boolToInt(committed),
                local_thread_id,
                last_activity_at,
                provider_thread_id,
                model_ref,
                reasoning_code,
                reasoning_variant,
                fast_code,
                access_code,
                provider_code,
                harness_code,
                if (tui_dock_id) |value| @as(i64, @intCast(value)) else null,
                draft,
                if (primary_draft_image) |value| value.path else null,
                if (primary_draft_image) |value| value.mime else null,
                if (primary_draft_image) |value| @as(i64, @intCast(value.byte_size)) else null,
            },
        );
        const thread_row_id = self.conn.lastInsertedRowId();
        for (messages, 0..) |message, message_index| {
            try self.insertMessage(thread_row_id, @intCast(message_index), message);
        }
    }

    fn insertMessage(self: *Self, thread_row_id: i64, sort_index: i64, message: store_protocol.Message) !void {
        const role_code = try roleCode(message.role);
        const kind_code = if (message.tool_call_kind) |value| try toolCallKindCode(value) else null;
        const status_code = if (message.tool_call_status) |value| try toolCallStatusCode(value) else null;
        const image = try firstAttachment(message.image, message.images);

        try self.conn.exec(
            "insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            .{
                thread_row_id,
                sort_index,
                role_code,
                message.author,
                message.body,
                if (image) |value| value.path else null,
                if (image) |value| value.mime else null,
                if (image) |value| @as(i64, @intCast(value.byte_size)) else null,
                message.tool_call_id,
                kind_code,
                status_code,
            },
        );

        if (message.message_id.len != 0) {
            try self.conn.exec(
                "insert into daemon_store_message_keys (thread_id, message_id, sort_index, created_at_ms, updated_at_ms) values (?1, ?2, ?3, ?4, ?5)",
                .{ thread_row_id, message.message_id, sort_index, message.created_at_ms, message.updated_at_ms },
            );
        }
    }

    fn insertSurface(self: *Self, surface: store_protocol.SurfaceState) !void {
        if (surface.session_id.len == 0) return error.InvalidParams;
        try self.conn.exec(
            "insert into surface_completions (session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, status, status_changed_at_ms, completed_at_ms, last_event_title, last_event_body) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            .{
                surface.session_id,
                surface.workspace_id,
                surface.workspace_path,
                @as(i64, @intCast(surface.dock_id)),
                if (surface.pane_id) |value| @as(i64, @intCast(value)) else null,
                if (surface.provider) |value| try surfaceProviderCode(value) else null,
                surface.provider_thread_id,
                surface.title,
                try surfaceStatusCode(surface.status),
                surface.status_changed_at_ms,
                surface.completed_at_ms,
                surface.last_event_title,
                surface.last_event_body,
            },
        );
    }

    fn insertChatCompletion(self: *Self, completion: store_protocol.ChatCompletion) !void {
        try self.conn.exec(
            "insert into chat_completions (workspace_id, local_thread_id, completed_at_ms) values (?1, ?2, ?3)",
            .{ completion.workspace_id, completion.local_thread_id, completion.completed_at_ms },
        );
    }
};

fn ensureStoreMetadata(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(STORE_METADATA_SQL);
    try conn.exec(
        "insert or ignore into daemon_store_meta (id, adapter_version) values (1, ?1)",
        .{STORE_ADAPTER_VERSION},
    );
    const marker = (try conn.row("select adapter_version from daemon_store_meta where id = 1", .{})) orelse
        return error.StoreMetadataMissing;
    defer marker.deinit();
    const adapter_version = marker.int(0);
    if (adapter_version > STORE_ADAPTER_VERSION) return error.StoreAdapterTooNew;
    if (adapter_version != STORE_ADAPTER_VERSION) return error.StoreMetadataInvalid;
    try conn.exec("insert or ignore into daemon_store_state (id, store_revision) values (1, 0)", .{});
    try conn.commit();
}

fn mutationHeader(mutation: Mutation) store_protocol.MutationHeader {
    return switch (mutation) {
        .snapshot_replace => |request| request.mutation,
        .workspace_upsert => |request| request.mutation,
    };
}

fn mutationOperation(mutation: Mutation) []const u8 {
    return switch (mutation) {
        .snapshot_replace => SNAPSHOT_REPLACE_OPERATION,
        .workspace_upsert => WORKSPACE_UPSERT_OPERATION,
    };
}

fn validateMutation(mutation: Mutation) StoreError!void {
    const header = mutationHeader(mutation);
    if (header.request_key.len == 0 or header.client_id.len == 0) return error.InvalidParams;
    switch (mutation) {
        .snapshot_replace => |request| {
            if (!request.bootstrap and request.mutation.expected_store_revision == null) return error.InvalidParams;
        },
        .workspace_upsert => {},
    }
}

fn checkExpectedRevision(mutation: Mutation, current_revision: u64) StoreError!void {
    const header = mutationHeader(mutation);
    if (header.expected_store_revision) |expected| {
        if (expected != current_revision) return error.Conflict;
    } else if (mutation == .snapshot_replace and current_revision != 0) {
        return error.Conflict;
    }
}

fn firstAttachment(single: ?store_protocol.Attachment, many: []const store_protocol.Attachment) !?store_protocol.Attachment {
    if (many.len > 1) return error.CapabilityUnavailable;
    if (many.len == 0) return single;
    if (single) |legacy| {
        if (!attachmentsEqual(legacy, many[0])) return error.InvalidParams;
    }
    return many[0];
}

fn attachmentsEqual(left: store_protocol.Attachment, right: store_protocol.Attachment) bool {
    return std.mem.eql(u8, left.path, right.path) and
        std.mem.eql(u8, left.mime, right.mime) and
        left.byte_size == right.byte_size and
        optionalBytesEqual(left.attachment_id, right.attachment_id);
}

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn workspaceValues(workspace: store_protocol.Workspace, sort_index: ?i64) struct {
    []const u8,
    ?i64,
    []const u8,
    []const u8,
    i64,
    i64,
    i64,
    i64,
    ?f32,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    i64,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    ?[]const u8,
    ?i64,
    ?i64,
    ?[]const u8,
    ?i64,
} {
    const link = workspace.herdr_link;
    return .{
        workspace.workspace_id,
        sort_index,
        workspace.label,
        workspace.path,
        boolToInt(workspace.archived),
        @as(i64, @intCast(workspace.unread_count)),
        boolToInt(workspace.collapsed orelse false),
        boolToInt(workspace.thread_list_expanded orelse false),
        workspace.terminal_height,
        workspace.terminal_layout_json,
        workspace.terminal_docks_json,
        workspace.workspace_layout_json,
        @as(i64, @intCast(workspace.selected_thread_index)),
        workspace.companion_thread_local_id,
        if (link) |value| value.remote_alias else null,
        if (link) |value| value.session_name else null,
        if (link) |value| value.workspace_id else null,
        if (link) |value| value.local_dir else null,
        if (link) |value| value.remote_cwd else null,
        if (link) |value| value.last_pane_id else null,
        if (link) |value| if (value.attach_dock_id) |id| @as(i64, @intCast(id)) else null else null,
        if (link) |value| if (value.attach_pane_id) |id| @as(i64, @intCast(id)) else null else null,
        if (link) |value| value.pane_links_json else null,
        if (link) |value| value.updated_at_ms else null,
    };
}

fn boolToInt(value: bool) i64 {
    return if (value) 1 else 0;
}

fn providerCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "opencode")) return 0;
    if (std.mem.eql(u8, value, "codex")) return 1;
    if (std.mem.eql(u8, value, "cursor")) return 2;
    if (std.mem.eql(u8, value, "claude")) return 3;
    return error.InvalidParams;
}

fn harnessCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "local_cli")) return 0;
    if (std.mem.eql(u8, value, "remote_session")) return 1;
    return error.InvalidParams;
}

fn reasoningEffortCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "low")) return 0;
    if (std.mem.eql(u8, value, "medium")) return 1;
    if (std.mem.eql(u8, value, "high")) return 2;
    if (std.mem.eql(u8, value, "xhigh")) return 3;
    if (std.mem.eql(u8, value, "max")) return 4;
    return error.InvalidParams;
}

fn fastModeCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "off")) return 0;
    if (std.mem.eql(u8, value, "on")) return 1;
    return error.InvalidParams;
}

fn accessModeCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "full_access")) return 0;
    if (std.mem.eql(u8, value, "supervised")) return 1;
    return error.InvalidParams;
}

fn roleCode(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "system")) return 0;
    if (std.mem.eql(u8, value, "user")) return 1;
    if (std.mem.eql(u8, value, "assistant")) return 2;
    return error.InvalidParams;
}

fn toolCallKindCode(value: []const u8) !i64 {
    const names = [_][]const u8{ "read", "edit", "delete", "move", "search", "execute", "think", "fetch", "mcp", "other" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

fn toolCallStatusCode(value: []const u8) !i64 {
    const names = [_][]const u8{ "pending", "in_progress", "completed", "failed", "cancelled", "unknown" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

fn surfaceProviderCode(value: []const u8) !i64 {
    const names = [_][]const u8{ "opencode", "codex", "cursor", "claude", "grok", "amp" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

fn surfaceStatusCode(value: []const u8) !i64 {
    const names = [_][]const u8{ "idle", "working", "waiting", "done", "error" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

fn mapOpenError(err: anyerror) StoreError {
    if (err == error.DatabaseSchemaTooNew) return error.SchemaTooNew;
    if (err == error.DatabaseSchemaInvalid or err == error.MissingSchemaVersion) return error.StoreCorrupt;
    if (err == error.StoreAdapterTooNew) return error.SchemaTooNew;
    if (err == error.StoreMetadataInvalid or err == error.StoreMetadataMissing) return error.StoreCorrupt;
    return mapSqliteError(err);
}

fn mapStoreError(err: anyerror) StoreError {
    if (err == error.Conflict) return error.Conflict;
    if (err == error.InvalidParams) return error.InvalidParams;
    if (err == error.CapabilityUnavailable) return error.CapabilityUnavailable;
    if (err == error.Internal) return error.Internal;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.StoreCorrupt or err == error.StoreMetadataMissing or err == error.StoreMetadataInvalid) return error.StoreCorrupt;
    if (err == error.StoreAdapterTooNew) return error.SchemaTooNew;
    return mapSqliteError(err);
}

fn mapSqliteError(err: anyerror) StoreError {
    if (err == error.Busy or err == error.Locked or err == error.BusyTimeout or err == error.LockedSharedCache) return error.StoreBusy;
    if (err == error.Corrupt or err == error.NotADB or err == error.CorruptVTab or err == error.CorruptSequence or err == error.CorruptIndex) return error.StoreCorrupt;
    if (err == error.Constraint or
        err == error.ConstraintCheck or
        err == error.ConstraintCommithook or
        err == error.ConstraintForeignKey or
        err == error.ConstraintFunction or
        err == error.ConstraintNotNull or
        err == error.ConstraintPrimaryKey or
        err == error.ConstraintTrigger or
        err == error.ConstraintUnique or
        err == error.ConstraintVTab or
        err == error.ConstraintRowId or
        err == error.ConstraintPinned or
        err == error.ConstraintDatatype) return error.InvalidParams;
    if (err == error.Internal or err == error.Misuse) return error.Internal;
    return error.StoreUnavailable;
}

fn testDbPath(tmp: *std.testing.TmpDir) ![:0]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    return std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
}

fn testWorkspace(id: []const u8, label: []const u8) store_protocol.Workspace {
    return .{ .workspace_id = id, .label = label, .path = id };
}

// Borrow caller-owned storage; returning &.{workspace} would leave the DTO
// pointing at this helper's temporary array after the helper returns.
fn testSnapshot(workspaces: []const store_protocol.Workspace) store_protocol.Snapshot {
    return .{ .workspaces = workspaces };
}

fn testSnapshotRequest(
    request_key: []const u8,
    expected_store_revision: ?u64,
    bootstrap: bool,
    snapshot: store_protocol.Snapshot,
) store_protocol.SnapshotReplaceRequest {
    return .{
        .mutation = .{
            .request_key = request_key,
            .expected_store_revision = expected_store_revision,
            .client_id = "test-client",
        },
        .snapshot = snapshot,
        .bootstrap = bootstrap,
    };
}

fn testWorkspaceRequest(
    request_key: []const u8,
    expected_store_revision: ?u64,
    workspace: store_protocol.Workspace,
) store_protocol.WorkspaceUpsertRequest {
    return .{
        .mutation = .{
            .request_key = request_key,
            .expected_store_revision = expected_store_revision,
            .client_id = "test-client",
        },
        .workspace = workspace,
    };
}

fn workspaceCount(store: *const Store) !i64 {
    const row = (try store.conn.row("select count(*) from workspaces", .{})).?;
    defer row.deinit();
    return row.int(0);
}

fn workspaceLabel(store: *const Store, workspace_id: []const u8) ![]u8 {
    const row = (try store.conn.row("select label from workspaces where workspace_id = ?1", .{workspace_id})).?;
    defer row.deinit();
    return std.testing.allocator.dupe(u8, row.text(0));
}

test "store commit increments durable revision and survives reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const workspace = testWorkspace("workspace-1", "First");
    const workspaces = [_]store_protocol.Workspace{workspace};
    const request = testSnapshotRequest("snapshot-1", null, true, testSnapshot(&workspaces));
    {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        const result = try store.applyMutation(.{ .snapshot_replace = request });
        try std.testing.expectEqual(@as(u64, 1), result.store_revision);
        try std.testing.expect(result.applied);
        try std.testing.expect(!result.duplicate);
        try std.testing.expectEqual(@as(i64, 1), try workspaceCount(&store));
    }

    var reopened = try Store.init(std.testing.allocator, db_path);
    defer reopened.deinit();
    try std.testing.expectEqual(@as(u64, 1), try reopened.storeRevision());
    const label = try workspaceLabel(&reopened, "workspace-1");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("First", label);
}

test "store duplicate request returns the original receipt without reapplying" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-1", "First");
    const workspaces = [_]store_protocol.Workspace{workspace};
    const first_request = testSnapshotRequest("same-key", null, true, testSnapshot(&workspaces));
    _ = try store.applyMutation(.{ .snapshot_replace = first_request });

    const duplicate = try store.applyMutation(.{ .snapshot_replace = first_request });
    try std.testing.expectEqual(@as(u64, 1), duplicate.store_revision);
    try std.testing.expect(!duplicate.applied);
    try std.testing.expect(duplicate.duplicate);
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());

    var retried_request = testSnapshotRequest("same-key", 99, true, testSnapshot(&workspaces));
    retried_request.mutation.client_id = "replacement-client";
    const duplicate_after_replacement = try store.applyMutation(.{ .snapshot_replace = retried_request });
    try std.testing.expectEqual(@as(u64, 1), duplicate_after_replacement.store_revision);
    try std.testing.expect(!duplicate_after_replacement.applied);
    try std.testing.expect(duplicate_after_replacement.duplicate);

    const changed_workspace = testWorkspace("workspace-1", "Changed");
    const changed_workspaces = [_]store_protocol.Workspace{changed_workspace};
    var changed_request = testSnapshotRequest("same-key", 99, true, testSnapshot(&changed_workspaces));
    changed_request.mutation.client_id = "replacement-client";
    try std.testing.expectError(error.Conflict, store.applyMutation(.{ .snapshot_replace = changed_request }));
    const label = try workspaceLabel(&store, "workspace-1");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("First", label);
}

test "store threads use workspace rowids when legacy compat rowids diverge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    // Simulate a legacy compatibility table whose rowid sequence is unrelated
    // to workspaces. The adapter must not use that table's last insert id.
    try store.conn.execNoArgs(
        \\create table daemon_store_workspace_compat (
        \\    workspace_id text primary key,
        \\    provider text not null,
        \\    harness text not null,
        \\    draft text not null
        \\);
    );
    try store.conn.exec(
        "insert into daemon_store_workspace_compat (rowid, workspace_id, provider, harness, draft) values (?1, ?2, ?3, ?4, ?5)",
        .{ @as(i64, 99), "legacy", "opencode", "local_cli", "" },
    );

    const workspace = testWorkspace("workspace-1", "First");
    const workspaces = [_]store_protocol.Workspace{workspace};
    const snapshot = testSnapshot(&workspaces);
    try store.insertWorkspace(workspace, 0, snapshot, true);

    const row = (try store.conn.row(
        "select w.id, t.workspace_id from workspaces w join threads t on t.workspace_id = w.id where w.workspace_id = ?1",
        .{workspace.workspace_id},
    )).?;
    defer row.deinit();
    try std.testing.expectEqual(row.int(0), row.int(1));
}

test "store expected revision mismatch conflicts without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-1", "First");
    const workspaces = [_]store_protocol.Workspace{workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("snapshot-1", null, true, testSnapshot(&workspaces)) });

    const request = testWorkspaceRequest("workspace-2", 0, testWorkspace("workspace-1", "Changed"));
    try std.testing.expectError(error.Conflict, store.applyMutation(.{ .workspace_upsert = request }));
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());
    const label = try workspaceLabel(&store, "workspace-1");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("First", label);
}

test "store failed replacement rolls back revision and data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-1", "Kept");
    const workspaces = [_]store_protocol.Workspace{workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("snapshot-1", null, true, testSnapshot(&workspaces)) });

    const duplicate_workspace: store_protocol.Workspace = testWorkspace("workspace-2", "New");
    const failed_workspaces = [_]store_protocol.Workspace{ duplicate_workspace, duplicate_workspace };
    const failed_snapshot: store_protocol.Snapshot = .{ .workspaces = &failed_workspaces };
    const request = testSnapshotRequest("snapshot-2", 1, false, failed_snapshot);
    try std.testing.expectError(error.InvalidParams, store.applyMutation(.{ .snapshot_replace = request }));
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());
    try std.testing.expectEqual(@as(i64, 1), try workspaceCount(&store));
    const label = try workspaceLabel(&store, "workspace-1");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("Kept", label);
}

test "store refuses a schema newer than the supported database layer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path, flags);
    try conn.execNoArgs("pragma user_version = 99");
    conn.close();

    try std.testing.expectError(error.SchemaTooNew, Store.init(std.testing.allocator, db_path));

    conn = try zqlite.open(db_path, zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode);
    defer conn.close();
    const row = (try conn.row("pragma user_version", .{})).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 99), row.int(0));
}

test "store refuses a newer adapter metadata version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    store.deinit();

    var conn = try zqlite.open(db_path, zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
    try conn.exec("update daemon_store_meta set adapter_version = ?1 where id = 1", .{@as(i64, 99)});
    conn.close();

    try std.testing.expectError(error.SchemaTooNew, Store.init(std.testing.allocator, db_path));
}
