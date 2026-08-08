//! Daemon-owned SQLite store adapter (M3 sole writer after Phase 3 flip).
//!
//! After endpoint ownership the production daemon opens `{pref}/state.sqlite`
//! (hermetic tests may redirect via `VERDE_SESSION_DAEMON_STORE_DIR`). The
//! adapter owns the transaction, receipt, and durable revision boundary.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const schema = @import("../db/schema.zig");
const transcript_apply = @import("../chat/transcript_apply.zig");
const platform_runtime = @import("platform_runtime");

const store_protocol = headless.store;
const protocol = headless.protocol;

/// Test-only fault injection for crash/busy/latency ITs (B9). Armed only via
/// `initWithFault` or the env-selected store override path; production `init`
/// always uses `.none`.
pub const StoreFault = enum {
    none,
    commit_stall,
    crash_before_commit,
    crash_after_commit,
};

/// Stall duration when `StoreFault.commit_stall` is armed (before commit).
pub const STORE_FAULT_COMMIT_STALL_MS: u64 = 1500;

pub const StoreError = error{
    Conflict,
    InvalidParams,
    ResourceNotFound,
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
    thread_upsert: store_protocol.ThreadUpsertRequest,
    message_append: store_protocol.MessageAppendRequest,
    surface_upsert: store_protocol.SurfaceUpsertRequest,
    surface_clear: store_protocol.SurfaceClearRequest,
    chat_completion_upsert: store_protocol.NotificationChatCompletionUpsertRequest,
    chat_completion_clear: store_protocol.NotificationChatCompletionClearRequest,
};

pub const TurnStatus = enum {
    accepted,
    running,
    waiting_approval,
    completed,
    failed,
    aborted,
    interrupted,
};

pub const TurnCommitRequest = struct {
    turn_id: []const u8,
    workspace_id: []const u8,
    local_thread_id: []const u8,
    status: TurnStatus,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    provider: []const u8,
    provider_thread_id: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    user_message_id: ?[]const u8 = null,
    /// Rows are already ordered by transcript_apply; the store appends them
    /// in this order. Empty synthesized-row IDs are assigned at this boundary
    /// from the turn identity and row index.
    messages: []const store_protocol.Message = &.{},
    /// The stop path carries this Q5 input through the commit seam. The pure
    /// transcript application happens before this store call.
    followup_pending: bool = false,
    /// A completed turn gets a notification ledger row. When omitted, the
    /// store derives it from the turn identity and finish timestamp.
    completion: ?store_protocol.ChatCompletion = null,
    /// Internal daemon commits do not need a registered client identity, but
    /// receipts retain the existing non-empty client-id invariant.
    client_id: []const u8 = "daemon",
};

pub const CompactionErrorData = struct {
    compacted_before_seq: u64,
};

/// Wire-compatible structured error for a tail cursor below the compaction
/// horizon. The sessionizer owns the live tail; this helper keeps its error
/// code and data shape centralized in the store seam.
pub const CompactionError = struct {
    code: []const u8,
    message: []const u8,
    data: CompactionErrorData,
};

pub fn compactionError(compacted_before_seq: u64) CompactionError {
    return .{
        .code = protocol.ERR_REVISION_EXPIRED,
        .message = "turn event cursor is below the compaction horizon",
        .data = .{ .compacted_before_seq = compacted_before_seq },
    };
}

pub const TERMINAL_PROCESS_OUTCOME_TTL_MS: i64 = 15 * std.time.ms_per_min;

/// Borrowed input shape for the drain-time lease transfer.
pub const LeaseRecord = struct {
    workspace_id: []const u8,
    lease_id: []const u8,
    owner: []const u8,
    client_id: []const u8,
    command: []const u8,
    resources: []const []const u8,
    created_at_ms: i64,
    expires_at_ms: i64,
    last_renewal_ms: i64,
};

pub const TerminalProcessOutcomeStatus = enum {
    completed,
    failed,
    cancelled,
    crashed,
    unknown,
};

/// Borrowed input shape mirroring process_registry.TerminalProcessOutcome.
pub const TerminalProcessOutcome = struct {
    workspace_id: []const u8,
    process_id: []const u8,
    generation: u64,
    session_id: []const u8,
    command: []const u8,
    cwd: []const u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    finished_at_ms: i64,
    dock_id: u32,
    pane_id: ?u32,
    owner_kind: []const u8,
    owner_title: []const u8,
    provider: ?[]const u8,
    status: TerminalProcessOutcomeStatus,
    exit_code: ?u32,
    signal: ?u32,
    cancellation_reason: ?[]const u8,
};

pub const ImportedLeaseRecord = struct {
    workspace_id: []u8,
    lease_id: []u8,
    owner: []u8,
    client_id: []u8,
    command: []u8,
    resources: std.ArrayListUnmanaged([]u8) = .empty,
    created_at_ms: i64,
    expires_at_ms: i64,
    last_renewal_ms: i64,

    pub fn deinit(self: *ImportedLeaseRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.lease_id);
        allocator.free(self.owner);
        allocator.free(self.client_id);
        allocator.free(self.command);
        for (self.resources.items) |resource| allocator.free(resource);
        self.resources.deinit(allocator);
    }
};

pub const ImportedTerminalProcessOutcome = struct {
    workspace_id: []u8,
    process_id: []u8,
    generation: u64,
    session_id: []u8,
    command: []u8,
    cwd: []u8,
    pid: ?u32,
    process_group: ?u32,
    started_at_ms: i64,
    finished_at_ms: i64,
    dock_id: u32,
    pane_id: ?u32,
    owner_kind: []u8,
    owner_title: []u8,
    provider: ?[]u8,
    status: TerminalProcessOutcomeStatus,
    exit_code: ?u32,
    signal: ?u32,
    cancellation_reason: ?[]u8,

    pub fn deinit(self: *ImportedTerminalProcessOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.process_id);
        allocator.free(self.session_id);
        allocator.free(self.command);
        allocator.free(self.cwd);
        allocator.free(self.owner_kind);
        allocator.free(self.owner_title);
        if (self.provider) |value| allocator.free(value);
        if (self.cancellation_reason) |value| allocator.free(value);
    }
};

pub const ImportedLeasesAndOutcomes = struct {
    leases: std.ArrayListUnmanaged(ImportedLeaseRecord) = .empty,
    outcomes: std.ArrayListUnmanaged(ImportedTerminalProcessOutcome) = .empty,

    pub fn deinit(self: *ImportedLeasesAndOutcomes, allocator: std.mem.Allocator) void {
        for (self.leases.items) |*lease| lease.deinit(allocator);
        self.leases.deinit(allocator);
        for (self.outcomes.items) |*outcome| outcome.deinit(allocator);
        self.outcomes.deinit(allocator);
    }
};

const SNAPSHOT_REPLACE_OPERATION = store_protocol.METHOD_STATE_SNAPSHOT_REPLACE;
const WORKSPACE_UPSERT_OPERATION = store_protocol.METHOD_WORKSPACE_UPSERT;
const THREAD_UPSERT_OPERATION = store_protocol.METHOD_CHAT_THREAD_UPSERT;
const MESSAGE_APPEND_OPERATION = store_protocol.METHOD_CHAT_MESSAGE_APPEND;
const SURFACE_UPSERT_OPERATION = store_protocol.METHOD_SURFACE_UPSERT;
const SURFACE_CLEAR_OPERATION = store_protocol.METHOD_SURFACE_CLEAR;
const CHAT_COMPLETION_UPSERT_OPERATION = store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT;
const CHAT_COMPLETION_CLEAR_OPERATION = store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR;
// Reserved receipt operation for durable turn commits; keep it distinct from
// future wire method names so receipt identity cannot silently overlap.
const TURN_COMMIT_OPERATION: []const u8 = "chat.turn.commit";
const RESPONSE_STATUS_OK: i64 = 0;

pub const Store = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    path: [:0]u8,
    conn: zqlite.Conn,
    /// Test-only; production construction always leaves `.none`.
    fault: StoreFault = .none,

    /// Open the exact database path as the sole store writer.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) StoreError!Self {
        return initWithFault(allocator, db_path, .none);
    }

    /// Open the store with an optional test-only fault hook (B9). Production
    /// always uses `.none`; hermetic ITs may arm stalls/crashes via env.
    pub fn initWithFault(allocator: std.mem.Allocator, db_path: []const u8, fault: StoreFault) StoreError!Self {
        const path = try allocator.dupeZ(u8, db_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = zqlite.open(path, flags) catch |err| return mapOpenError(err);
        errdefer conn.close();

        conn.busyTimeout(schema.BUSY_TIMEOUT_MS) catch |err| return mapOpenError(err);
        schema.initializeToVersion(conn, schema.MAX_SUPPORTED_VERSION) catch |err| return mapOpenError(err);

        return .{
            .allocator = allocator,
            .path = path,
            .conn = conn,
            .fault = fault,
        };
    }

    pub fn deinit(self: *Self) void {
        self.conn.close();
        self.allocator.free(self.path);
    }

    /// Commit the open transaction, optionally applying the test-only fault hook.
    /// Why: stall/crash arms exist only for ITs (B9); production always sees `.none`.
    fn commitWithFault(self: *Self) StoreError!void {
        // Test-only: hold the open transaction while sleeping so the busy/lock
        // boundary and latency ITs exercise real writer contention.
        if (self.fault == .commit_stall) {
            platform_runtime.sleepMillis(STORE_FAULT_COMMIT_STALL_MS);
        }
        // Test-only: abort with no unwind so SQLite journal recovery is exercised.
        if (self.fault == .crash_before_commit) {
            std.process.abort();
        }
        self.conn.commit() catch |err| return mapStoreError(err);
        // Test-only: process death after durable commit (exactly-once on reopen).
        if (self.fault == .crash_after_commit) {
            std.process.abort();
        }
    }

    /// Return the durable revision currently recorded by the store.
    pub fn storeRevision(self: *const Self) StoreError!u64 {
        return self.readStoreRevision() catch |err| return mapStoreError(err);
    }

    /// Apply one supported mutation serially and return its durable receipt.
    pub fn applyMutation(self: *Self, mutation: Mutation) StoreError!store_protocol.WriteResult {
        validateMutation(mutation) catch |err| return err;
        const fingerprint = try self.mutationFingerprint(mutation);
        defer self.allocator.free(fingerprint);

        const operation = mutationOperation(mutation);

        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const prior_receipt = self.receiptFor(mutationHeader(mutation), operation, fingerprint) catch |err| return mapStoreError(err);
        if (prior_receipt) |result| {
            self.conn.rollback();
            transaction_open = false;
            return result;
        }

        const current_revision = self.readStoreRevision() catch |err| return mapStoreError(err);

        // Message identity is independent of the transport request key. A
        // retry with a fresh key must not append the same client message.
        //
        // Normative ordering (M3 track resolution): recognized duplicates and
        // conflicting payloads on the same (thread_id, message_id) win over
        // the expected-revision guard. Idempotent replays apply nothing, so a
        // stale expected_store_revision must not reject a retrying client that
        // reconnected with a fresh request_key. Conflicting payloads return
        // Conflict before the guard as the more specific error. The guard only
        // rejects NEW state transitions computed from stale reads.
        const message_key = switch (mutation) {
            .message_append => |request| self.messageKeyStatus(request) catch |err| return mapStoreError(err),
            else => null,
        };
        if (message_key) |status| {
            if (status.conflict) return error.Conflict;
            // Report the live store revision (not the original message-key
            // revision): duplicates apply nothing and must not bump, but the
            // receipt should reflect the store's current watermark.
            const result: store_protocol.WriteResult = .{
                .store_revision = current_revision,
                .applied = false,
                .duplicate = true,
            };
            self.insertReceipt(mutationHeader(mutation), operation, fingerprint, result) catch |err| return mapStoreError(err);
            try self.commitWithFault();
            transaction_open = false;
            return result;
        }

        try checkExpectedRevision(mutation, current_revision);

        const next_revision = std.math.add(u64, current_revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;
        var applied = true;
        switch (mutation) {
            .snapshot_replace => |request| self.applySnapshot(request.snapshot, next_revision_sql) catch |err| return mapStoreError(err),
            .workspace_upsert => |request| self.applyWorkspace(request.workspace) catch |err| return mapStoreError(err),
            .thread_upsert => |request| self.applyThread(request) catch |err| return mapStoreError(err),
            .message_append => |request| self.applyMessageAppend(request, next_revision_sql) catch |err| return mapStoreError(err),
            .surface_upsert => |request| self.applySurfaceUpsert(request.surface) catch |err| return mapStoreError(err),
            .surface_clear => |request| applied = self.applySurfaceClear(request) catch |err| return mapStoreError(err),
            .chat_completion_upsert => |request| self.applyChatCompletionUpsert(request.completion) catch |err| return mapStoreError(err),
            .chat_completion_clear => |request| applied = self.applyChatCompletionClear(request) catch |err| return mapStoreError(err),
        }

        self.conn.exec(
            "update store_state set store_revision = ?1 where id = 1",
            .{next_revision_sql},
        ) catch |err| return mapStoreError(err);
        const result: store_protocol.WriteResult = .{
            .store_revision = next_revision,
            .applied = applied,
            .duplicate = false,
        };
        self.insertReceipt(mutationHeader(mutation), operation, fingerprint, result) catch |err| return mapStoreError(err);

        try self.commitWithFault();
        transaction_open = false;
        return result;
    }

    /// Convenience entry point for the transitional snapshot command.
    pub fn replaceSnapshot(self: *Self, request: store_protocol.SnapshotReplaceRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .snapshot_replace = request });
    }

    /// Convenience entry point for the first granular phase-1 mutation.
    pub fn upsertWorkspace(self: *Self, request: store_protocol.WorkspaceUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_upsert = request });
    }

    pub fn upsertThread(self: *Self, request: store_protocol.ThreadUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .thread_upsert = request });
    }

    pub fn appendMessage(self: *Self, request: store_protocol.MessageAppendRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .message_append = request });
    }

    pub fn upsertSurface(self: *Self, request: store_protocol.SurfaceUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .surface_upsert = request });
    }

    pub fn clearSurface(self: *Self, request: store_protocol.SurfaceClearRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .surface_clear = request });
    }

    pub fn upsertChatCompletion(self: *Self, request: store_protocol.NotificationChatCompletionUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .chat_completion_upsert = request });
    }

    pub fn clearChatCompletion(self: *Self, request: store_protocol.NotificationChatCompletionClearRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .chat_completion_clear = request });
    }

    /// Commit an already-applied terminal transcript and its durable turn
    /// summary atomically. The generated request key is the public retry
    /// identity required by the M4 contract, so receipt replay returns the
    /// original revision without appending rows or bumping the revision.
    pub fn commitTurn(self: *Self, request: TurnCommitRequest) StoreError!store_protocol.WriteResult {
        validateTurnCommit(request) catch |err| return err;

        const request_key = std.fmt.allocPrint(self.allocator, "turn:{s}:commit", .{request.turn_id}) catch return error.OutOfMemory;
        defer self.allocator.free(request_key);
        const header: store_protocol.MutationHeader = .{
            .request_key = request_key,
            .client_id = request.client_id,
        };
        // Match the S1 mutation convention: client_id identifies the caller
        // but is not part of the logical turn state or its replay fingerprint.
        const fingerprint = self.encodeFingerprint(.{
            .turn_id = request.turn_id,
            .workspace_id = request.workspace_id,
            .local_thread_id = request.local_thread_id,
            .status = request.status,
            .started_at_ms = request.started_at_ms,
            .finished_at_ms = request.finished_at_ms,
            .provider = request.provider,
            .provider_thread_id = request.provider_thread_id,
            .error_message = request.error_message,
            .user_message_id = request.user_message_id,
            .messages = request.messages,
            .followup_pending = request.followup_pending,
            .completion = request.completion,
        }) catch |err| return err;
        defer self.allocator.free(fingerprint);

        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const prior_receipt = self.receiptFor(header, TURN_COMMIT_OPERATION, fingerprint) catch |err| return mapStoreError(err);
        if (prior_receipt) |result| {
            self.conn.rollback();
            transaction_open = false;
            return result;
        }

        const current_revision = self.readStoreRevision() catch |err| return mapStoreError(err);
        const next_revision = std.math.add(u64, current_revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;

        self.insertTurnMessages(request, next_revision_sql) catch |err| return mapStoreError(err);
        self.insertTurnLedger(request, next_revision_sql) catch |err| return mapStoreError(err);
        if (request.status == .completed) {
            const completion: store_protocol.ChatCompletion = request.completion orelse .{
                .workspace_id = request.workspace_id,
                .local_thread_id = request.local_thread_id,
                .completed_at_ms = request.finished_at_ms orelse request.started_at_ms,
            };
            self.applyChatCompletionUpsert(completion) catch |err| return mapStoreError(err);
        }

        self.conn.exec(
            "update store_state set store_revision = ?1 where id = 1",
            .{next_revision_sql},
        ) catch |err| return mapStoreError(err);
        const result: store_protocol.WriteResult = .{
            .store_revision = next_revision,
            .applied = true,
            .duplicate = false,
        };
        self.insertReceipt(header, TURN_COMMIT_OPERATION, fingerprint, result) catch |err| return mapStoreError(err);
        self.conn.commit() catch |err| return mapStoreError(err);
        transaction_open = false;
        return result;
    }

    /// Replace the drain transfer snapshot in one transaction. An empty set is
    /// still a real snapshot: both transfer tables are cleared and store_revision
    /// advances exactly once so a successor never resurrects a stale predecessor.
    /// The transfer is intentionally not receipt-backed: the old daemon owns this
    /// call during shutdown, and the successor imports the committed snapshot.
    pub fn persistLeasesAndOutcomes(
        self: *Self,
        leases: []const LeaseRecord,
        outcomes: []const TerminalProcessOutcome,
    ) StoreError!store_protocol.WriteResult {
        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const revision = self.readStoreRevision() catch |err| return mapStoreError(err);
        const next_revision = std.math.add(u64, revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;

        self.conn.execNoArgs(
            \\delete from terminal_process_outcomes;
            \\delete from workspace_leases;
        ) catch |err| return mapStoreError(err);
        for (leases) |lease| self.insertLeaseTransfer(lease) catch |err| return mapStoreError(err);
        for (outcomes) |outcome| self.insertOutcomeTransfer(outcome) catch |err| return mapStoreError(err);

        self.conn.exec(
            "update store_state set store_revision = ?1 where id = 1",
            .{next_revision_sql},
        ) catch |err| return mapStoreError(err);
        self.conn.commit() catch |err| return mapStoreError(err);
        transaction_open = false;
        return .{ .store_revision = next_revision, .applied = true, .duplicate = false };
    }

    /// Load the committed transfer snapshot and remove expired records. Import
    /// pruning deliberately does not advance store_revision: the drain commit
    /// is the single durable revision event observed by the replacement.
    pub fn importLeasesAndOutcomes(self: *Self, now_ms: i64) StoreError!ImportedLeasesAndOutcomes {
        var imported: ImportedLeasesAndOutcomes = .{};
        errdefer imported.deinit(self.allocator);

        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const outcome_cutoff = std.math.sub(i64, now_ms, TERMINAL_PROCESS_OUTCOME_TTL_MS) catch std.math.minInt(i64);
        self.conn.exec(
            "delete from workspace_leases where expires_at_ms <= ?1",
            .{now_ms},
        ) catch |err| return mapStoreError(err);
        self.conn.exec(
            "delete from terminal_process_outcomes where finished_at_ms < ?1",
            .{outcome_cutoff},
        ) catch |err| return mapStoreError(err);

        var lease_rows = self.conn.rows(
            "select workspace_id, lease_id, owner, client_id, command, resources_json, created_at_ms, expires_at_ms, last_renewal_ms from workspace_leases where expires_at_ms > ?1 order by workspace_id, lease_id",
            .{now_ms},
        ) catch |err| return mapStoreError(err);
        defer lease_rows.deinit();
        while (lease_rows.next()) |row| {
            var lease = copyImportedLease(self.allocator, row) catch |err| return mapStoreError(err);
            var lease_owned = true;
            defer if (lease_owned) lease.deinit(self.allocator);
            imported.leases.append(self.allocator, lease) catch |err| return mapStoreError(err);
            lease_owned = false;
        }
        if (lease_rows.err) |err| return mapStoreError(err);

        var outcome_rows = self.conn.rows(
            "select workspace_id, process_id, generation, session_id, command, cwd, pid, process_group, started_at_ms, finished_at_ms, dock_id, pane_id, owner_kind, owner_title, provider, status, exit_code, signal, cancellation_reason from terminal_process_outcomes where finished_at_ms >= ?1 order by workspace_id, finished_at_ms, process_id",
            .{outcome_cutoff},
        ) catch |err| return mapStoreError(err);
        defer outcome_rows.deinit();
        while (outcome_rows.next()) |row| {
            var outcome = copyImportedOutcome(self.allocator, row) catch |err| return mapStoreError(err);
            var outcome_owned = true;
            defer if (outcome_owned) outcome.deinit(self.allocator);
            imported.outcomes.append(self.allocator, outcome) catch |err| return mapStoreError(err);
            outcome_owned = false;
        }
        if (outcome_rows.err) |err| return mapStoreError(err);

        self.conn.commit() catch |err| return mapStoreError(err);
        transaction_open = false;
        return imported;
    }

    fn insertLeaseTransfer(self: *Self, lease: LeaseRecord) !void {
        if (lease.workspace_id.len == 0 or lease.lease_id.len == 0 or lease.owner.len == 0 or lease.client_id.len == 0) {
            return error.InvalidParams;
        }
        const resources_json = try store_protocol.encode(self.allocator, lease.resources);
        defer self.allocator.free(resources_json);
        try self.conn.exec(
            "insert into workspace_leases (workspace_id, lease_id, owner, client_id, command, resources_json, created_at_ms, expires_at_ms, last_renewal_ms) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            .{
                lease.workspace_id,
                lease.lease_id,
                lease.owner,
                lease.client_id,
                lease.command,
                resources_json,
                lease.created_at_ms,
                lease.expires_at_ms,
                lease.last_renewal_ms,
            },
        );
    }

    fn insertOutcomeTransfer(self: *Self, outcome: TerminalProcessOutcome) !void {
        if (outcome.workspace_id.len == 0 or outcome.process_id.len == 0 or outcome.session_id.len == 0) {
            return error.InvalidParams;
        }
        try self.conn.exec(
            "insert into terminal_process_outcomes (workspace_id, process_id, generation, session_id, command, cwd, pid, process_group, started_at_ms, finished_at_ms, dock_id, pane_id, owner_kind, owner_title, provider, status, exit_code, signal, cancellation_reason) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
            .{
                outcome.workspace_id,
                outcome.process_id,
                @as(i64, @intCast(outcome.generation)),
                outcome.session_id,
                outcome.command,
                outcome.cwd,
                if (outcome.pid) |value| @as(i64, @intCast(value)) else null,
                if (outcome.process_group) |value| @as(i64, @intCast(value)) else null,
                outcome.started_at_ms,
                outcome.finished_at_ms,
                @as(i64, @intCast(outcome.dock_id)),
                if (outcome.pane_id) |value| @as(i64, @intCast(value)) else null,
                outcome.owner_kind,
                outcome.owner_title,
                outcome.provider,
                @tagName(outcome.status),
                if (outcome.exit_code) |value| @as(i64, @intCast(value)) else null,
                if (outcome.signal) |value| @as(i64, @intCast(value)) else null,
                outcome.cancellation_reason,
            },
        );
    }

    fn copyImportedLease(allocator: std.mem.Allocator, row: anytype) !ImportedLeaseRecord {
        const workspace_id = try allocator.dupe(u8, row.text(0));
        errdefer allocator.free(workspace_id);
        const lease_id = try allocator.dupe(u8, row.text(1));
        errdefer allocator.free(lease_id);
        const owner = try allocator.dupe(u8, row.text(2));
        errdefer allocator.free(owner);
        const client_id = try allocator.dupe(u8, row.text(3));
        errdefer allocator.free(client_id);
        const command = try allocator.dupe(u8, row.text(4));
        errdefer allocator.free(command);
        var resources = try copyResources(allocator, row.text(5));
        errdefer freeOwnedResources(allocator, &resources);
        return .{
            .workspace_id = workspace_id,
            .lease_id = lease_id,
            .owner = owner,
            .client_id = client_id,
            .command = command,
            .resources = resources,
            .created_at_ms = row.int(6),
            .expires_at_ms = row.int(7),
            .last_renewal_ms = row.int(8),
        };
    }

    fn copyImportedOutcome(allocator: std.mem.Allocator, row: anytype) !ImportedTerminalProcessOutcome {
        const workspace_id = try allocator.dupe(u8, row.text(0));
        errdefer allocator.free(workspace_id);
        const process_id = try allocator.dupe(u8, row.text(1));
        errdefer allocator.free(process_id);
        const session_id = try allocator.dupe(u8, row.text(3));
        errdefer allocator.free(session_id);
        const command = try allocator.dupe(u8, row.text(4));
        errdefer allocator.free(command);
        const cwd = try allocator.dupe(u8, row.text(5));
        errdefer allocator.free(cwd);
        const owner_kind = try allocator.dupe(u8, row.text(12));
        errdefer allocator.free(owner_kind);
        const owner_title = try allocator.dupe(u8, row.text(13));
        errdefer allocator.free(owner_title);
        const provider = try dupeNullableText(allocator, row.nullableText(14));
        errdefer if (provider) |value| allocator.free(value);
        const cancellation_reason = try dupeNullableText(allocator, row.nullableText(18));
        errdefer if (cancellation_reason) |value| allocator.free(value);
        const status = try parseOutcomeStatus(row.text(15));
        return .{
            .workspace_id = workspace_id,
            .process_id = process_id,
            .generation = try requiredU64(row.int(2)),
            .session_id = session_id,
            .command = command,
            .cwd = cwd,
            .pid = try optionalU32(row.nullableInt(6)),
            .process_group = try optionalU32(row.nullableInt(7)),
            .started_at_ms = row.int(8),
            .finished_at_ms = row.int(9),
            .dock_id = try requiredU32(row.int(10)),
            .pane_id = try optionalU32(row.nullableInt(11)),
            .owner_kind = owner_kind,
            .owner_title = owner_title,
            .provider = provider,
            .status = status,
            .exit_code = try optionalU32(row.nullableInt(16)),
            .signal = try optionalU32(row.nullableInt(17)),
            .cancellation_reason = cancellation_reason,
        };
    }

    fn readStoreRevision(self: *const Self) !u64 {
        const row = (try self.conn.row("select store_revision from store_state where id = 1", .{})) orelse
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
            "select operation, fingerprint, store_revision, response_status, response_payload from store_receipts where request_key = ?1",
            .{mutation.request_key},
        )) orelse return null;
        defer row.deinit();

        if (!std.mem.eql(u8, row.text(0), operation) or !std.mem.eql(u8, row.text(1), fingerprint)) {
            return error.Conflict;
        }
        if (row.int(3) != RESPONSE_STATUS_OK) return error.StoreCorrupt;
        const response_payload = row.nullableText(4) orelse return error.StoreCorrupt;
        return store_protocol.decodeLeaky(store_protocol.WriteResult, self.allocator, response_payload) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.StoreCorrupt;
        };
    }

    fn insertReceipt(
        self: *Self,
        mutation: store_protocol.MutationHeader,
        operation: []const u8,
        fingerprint: []const u8,
        result: store_protocol.WriteResult,
    ) !void {
        // Durable WriteResult JSON for exact receipt replay (B4). Reuses the
        // same JSON encoder as mutation fingerprints; this is the response
        // body, not a hash of the result.
        const response_payload = self.encodeFingerprint(result) catch |err| return err;
        defer self.allocator.free(response_payload);
        try self.conn.exec(
            "insert into store_receipts (request_key, operation, fingerprint, store_revision, response_payload, response_status) values (?1, ?2, ?3, ?4, ?5, ?6)",
            .{
                mutation.request_key,
                operation,
                fingerprint,
                @as(i64, @intCast(result.store_revision)),
                response_payload,
                RESPONSE_STATUS_OK,
            },
        );
    }

    const MessageKeyStatus = struct {
        store_revision: u64,
        conflict: bool,
    };

    fn messageKeyStatus(
        self: *const Self,
        request: store_protocol.MessageAppendRequest,
    ) !?MessageKeyStatus {
        return self.messageKeyStatusFor(request.workspace_id, request.thread_id, request.message);
    }

    fn messageKeyStatusFor(
        self: *const Self,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        message: store_protocol.Message,
    ) !?MessageKeyStatus {
        const fingerprint = self.encodeFingerprint(message) catch |err| return err;
        defer self.allocator.free(fingerprint);
        const thread_row = (try self.conn.row(
            "select t.id from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ workspace_id, local_thread_id },
        )) orelse return error.ResourceNotFound;
        defer thread_row.deinit();
        const thread_id = thread_row.int(0);
        const row = (try self.conn.row(
            "select message_fingerprint, store_revision from client_message_keys where thread_id = ?1 and message_id = ?2",
            .{ thread_id, message.message_id },
        )) orelse return null;
        defer row.deinit();
        const stored_fingerprint = row.nullableText(0) orelse return error.StoreCorrupt;
        const stored_revision = row.int(1);
        if (stored_revision < 0) return error.StoreCorrupt;
        return .{
            .store_revision = @intCast(stored_revision),
            .conflict = !std.mem.eql(u8, stored_fingerprint, fingerprint),
        };
    }

    fn mutationFingerprint(self: *const Self, mutation: Mutation) StoreError![]u8 {
        return switch (mutation) {
            .snapshot_replace => |request| self.encodeFingerprint(.{
                .snapshot = request.snapshot,
                .bootstrap = request.bootstrap,
            }),
            .workspace_upsert => |request| self.encodeFingerprint(request.workspace),
            .thread_upsert => |request| self.encodeFingerprint(.{
                .workspace_id = request.workspace_id,
                .thread = request.thread,
            }),
            .message_append => |request| self.encodeFingerprint(.{
                .workspace_id = request.workspace_id,
                .thread_id = request.thread_id,
                .message = request.message,
            }),
            .surface_upsert => |request| self.encodeFingerprint(request.surface),
            .surface_clear => |request| self.encodeFingerprint(.{
                .session_id = request.session_id,
                .workspace_id = request.workspace_id,
            }),
            .chat_completion_upsert => |request| self.encodeFingerprint(request.completion),
            .chat_completion_clear => |request| self.encodeFingerprint(.{
                .workspace_id = request.workspace_id,
                .local_thread_id = request.local_thread_id,
            }),
        };
    }

    fn encodeFingerprint(self: *const Self, value: anytype) StoreError![]u8 {
        return store_protocol.encode(self.allocator, value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.Internal;
        };
    }

    fn applySnapshot(self: *Self, snapshot: store_protocol.Snapshot, store_revision: i64) !void {
        if (snapshot.schema_version != 1) return error.InvalidParams;

        try self.conn.execNoArgs(
            \\delete from client_message_keys;
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
            try self.insertWorkspaceAtRevision(workspace, workspace_index, snapshot, workspace_index == 0, store_revision);
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
                "values (?1, coalesce(?2, (select max(sort_index) + 1 from workspaces), 0), ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24) " ++
                "on conflict(workspace_id) do update set label = excluded.label, path = excluded.path, archived = excluded.archived, unread_count = excluded.unread_count, collapsed = excluded.collapsed, thread_list_expanded = excluded.thread_list_expanded, terminal_height = excluded.terminal_height, terminal_layout_json = excluded.terminal_layout_json, terminal_docks_json = excluded.terminal_docks_json, workspace_layout_json = excluded.workspace_layout_json, selected_thread_index = excluded.selected_thread_index, companion_thread_local_id = excluded.companion_thread_local_id, herdr_remote_alias = excluded.herdr_remote_alias, herdr_session_name = excluded.herdr_session_name, herdr_workspace_id = excluded.herdr_workspace_id, herdr_local_dir = excluded.herdr_local_dir, herdr_remote_cwd = excluded.herdr_remote_cwd, herdr_last_pane_id = excluded.herdr_last_pane_id, herdr_attach_dock_id = excluded.herdr_attach_dock_id, herdr_attach_pane_id = excluded.herdr_attach_pane_id, herdr_pane_links_json = excluded.herdr_pane_links_json, herdr_updated_at_ms = excluded.herdr_updated_at_ms",
            workspaceValues(workspace, null),
        );
    }

    fn applyThread(self: *Self, request: store_protocol.ThreadUpsertRequest) !void {
        const thread = request.thread;
        const workspace_row_id = (try self.conn.row(
            "select id from workspaces where workspace_id = ?1",
            .{request.workspace_id},
        )) orelse return error.ResourceNotFound;
        defer workspace_row_id.deinit();
        const workspace_id = workspace_row_id.int(0);
        const primary_draft_image = try firstAttachment(thread.draft_image, thread.draft_images);
        const provider_code = try providerCode(thread.provider);
        const harness_code = try harnessCode(thread.harness);
        const reasoning_code = if (thread.reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (thread.fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (thread.access_mode) |value| try accessModeCode(value) else null;

        const existing = try self.conn.row(
            "select id from threads where workspace_id = ?1 and local_thread_id = ?2",
            .{ workspace_id, thread.local_thread_id },
        );
        if (existing) |row| {
            defer row.deinit();
            try self.conn.exec(
                "update threads set title = ?1, archived = ?2, committed = ?3, last_activity_at = ?4, provider_thread_id = ?5, model_ref = ?6, reasoning_effort = ?7, reasoning_variant = ?8, fast_mode = ?9, access_mode = ?10, provider = ?11, harness = ?12, tui_dock_id = ?13, draft = ?14, draft_image_path = ?15, draft_image_mime = ?16, draft_image_byte_size = ?17 where id = ?18",
                .{
                    thread.title,
                    boolToInt(thread.archived),
                    boolToInt(thread.committed),
                    thread.last_activity_at,
                    thread.provider_thread_id,
                    thread.model_ref,
                    reasoning_code,
                    thread.reasoning_variant,
                    fast_code,
                    access_code,
                    provider_code,
                    harness_code,
                    if (thread.tui_dock_id) |value| @as(i64, @intCast(value)) else null,
                    thread.draft,
                    if (primary_draft_image) |value| value.path else null,
                    if (primary_draft_image) |value| value.mime else null,
                    if (primary_draft_image) |value| @as(i64, @intCast(value.byte_size)) else null,
                    row.int(0),
                },
            );
            return;
        }

        try self.insertThread(
            workspace_id,
            null,
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
            &.{},
            null,
        );
    }

    fn applyMessageAppend(self: *Self, request: store_protocol.MessageAppendRequest, store_revision: i64) !void {
        const thread_row_id = (try self.conn.row(
            "select t.id from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ request.workspace_id, request.thread_id },
        )) orelse return error.ResourceNotFound;
        defer thread_row_id.deinit();
        const thread_id = thread_row_id.int(0);

        const next_sort = (try self.conn.row(
            "select coalesce(max(sort_index) + 1, 0) from messages where thread_id = ?1",
            .{thread_id},
        )) orelse return error.StoreCorrupt;
        defer next_sort.deinit();
        const sort_index = next_sort.int(0);
        try self.insertMessage(thread_id, sort_index, request.message);

        const message_fingerprint = self.encodeFingerprint(request.message) catch |err| return err;
        defer self.allocator.free(message_fingerprint);
        try self.conn.exec(
            "insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index, created_at_ms, updated_at_ms, store_revision) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            .{
                thread_id,
                request.message.message_id,
                message_fingerprint,
                sort_index,
                request.message.created_at_ms,
                request.message.updated_at_ms,
                store_revision,
            },
        );
    }

    fn insertTurnMessages(self: *Self, request: TurnCommitRequest, store_revision: i64) !void {
        const thread_row = (try self.conn.row(
            "select t.id from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ request.workspace_id, request.local_thread_id },
        )) orelse return error.ResourceNotFound;
        defer thread_row.deinit();
        const thread_id = thread_row.int(0);

        const next_sort_row = (try self.conn.row(
            "select coalesce(max(sort_index) + 1, 0) from messages where thread_id = ?1",
            .{thread_id},
        )) orelse return error.StoreCorrupt;
        defer next_sort_row.deinit();
        var next_sort = next_sort_row.int(0);

        for (request.messages, 0..) |message, row_index| {
            // transcript_apply deliberately leaves synthesized rows without a
            // client identity. Minting here keeps the reducer pure while
            // making retries stable and keeping the generated namespace apart
            // from client-supplied message IDs.
            {
                var stored_message = message;
                var synthesized_id: ?[]u8 = null;
                defer if (synthesized_id) |id| self.allocator.free(id);
                if (message.message_id.len == 0) {
                    const id = std.fmt.allocPrint(self.allocator, "turn:{s}:msg:{d}", .{ request.turn_id, row_index }) catch return error.OutOfMemory;
                    synthesized_id = id;
                    stored_message.message_id = id;
                }

                if (self.messageKeyStatusFor(request.workspace_id, request.local_thread_id, stored_message)) |existing| {
                    if (existing) |status| {
                        if (status.conflict) {
                            // Amendment-2 F1: the turn's user row is idempotent
                            // by IDENTITY, not fingerprint. A stable-turn_id
                            // replay after an interrupted sweep re-sends the
                            // acceptance user row with drifted prompt/timestamps;
                            // the originally staged row stays authoritative
                            // (first-writer-wins). All other rows keep strict
                            // fingerprint conflicts.
                            const is_user_row = if (request.user_message_id) |uid|
                                std.mem.eql(u8, stored_message.message_id, uid)
                            else
                                false;
                            if (!is_user_row) return error.Conflict;
                        }
                        continue;
                    }
                } else |err| return err;

                try self.insertMessage(thread_id, next_sort, stored_message);
                try self.insertMessageKey(thread_id, next_sort, stored_message, store_revision);
            }
            next_sort += 1;
        }
    }

    fn insertTurnLedger(self: *Self, request: TurnCommitRequest, store_revision: i64) !void {
        // Upsert: supersedes acceptance-stage / interrupted rows inside commitTurn's
        // transaction (no external pre-delete). Receipt replay still short-circuits
        // before this call, so a duplicate commit never mutates the ledger.
        try self.conn.exec(
            "insert into chat_turns (turn_id, workspace_id, local_thread_id, status, started_at_ms, finished_at_ms, provider, provider_thread_id, error_message, user_message_id, committed_store_revision) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11) on conflict(turn_id) do update set workspace_id = excluded.workspace_id, local_thread_id = excluded.local_thread_id, status = excluded.status, started_at_ms = excluded.started_at_ms, finished_at_ms = excluded.finished_at_ms, provider = excluded.provider, provider_thread_id = excluded.provider_thread_id, error_message = excluded.error_message, user_message_id = excluded.user_message_id, committed_store_revision = excluded.committed_store_revision",
            .{
                request.turn_id,
                request.workspace_id,
                request.local_thread_id,
                @tagName(request.status),
                request.started_at_ms,
                request.finished_at_ms,
                request.provider,
                request.provider_thread_id,
                request.error_message,
                request.user_message_id,
                store_revision,
            },
        );
    }

    fn applySurfaceUpsert(self: *Self, surface: store_protocol.SurfaceState) !void {
        if (surface.session_id.len == 0) return error.InvalidParams;
        try self.conn.exec(
            "insert into surface_completions (session_id, workspace_id, workspace_path, dock_id, pane_id, provider, provider_thread_id, title, status, status_changed_at_ms, completed_at_ms, last_event_title, last_event_body) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13) on conflict(session_id) do update set workspace_id = excluded.workspace_id, workspace_path = excluded.workspace_path, dock_id = excluded.dock_id, pane_id = excluded.pane_id, provider = excluded.provider, provider_thread_id = excluded.provider_thread_id, title = excluded.title, status = excluded.status, status_changed_at_ms = excluded.status_changed_at_ms, completed_at_ms = excluded.completed_at_ms, last_event_title = excluded.last_event_title, last_event_body = excluded.last_event_body",
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

    fn applySurfaceClear(self: *Self, request: store_protocol.SurfaceClearRequest) !bool {
        if (request.session_id.len == 0) return error.InvalidParams;
        if (request.workspace_id) |workspace_id| {
            try self.conn.exec(
                "delete from surface_completions where session_id = ?1 and workspace_id = ?2",
                .{ request.session_id, workspace_id },
            );
        } else {
            try self.conn.exec("delete from surface_completions where session_id = ?1", .{request.session_id});
        }
        return self.conn.changes() > 0;
    }

    fn applyChatCompletionUpsert(self: *Self, completion: store_protocol.ChatCompletion) !void {
        if (completion.workspace_id.len == 0 or completion.local_thread_id.len == 0) return error.InvalidParams;
        try self.conn.exec(
            "insert into chat_completions (workspace_id, local_thread_id, completed_at_ms) values (?1, ?2, ?3) on conflict(workspace_id, local_thread_id) do update set completed_at_ms = excluded.completed_at_ms",
            .{ completion.workspace_id, completion.local_thread_id, completion.completed_at_ms },
        );
    }

    fn applyChatCompletionClear(self: *Self, request: store_protocol.NotificationChatCompletionClearRequest) !bool {
        if (request.workspace_id.len == 0 or request.local_thread_id.len == 0) return error.InvalidParams;
        try self.conn.exec(
            "delete from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
            .{ request.workspace_id, request.local_thread_id },
        );
        return self.conn.changes() > 0;
    }

    fn insertWorkspace(
        self: *Self,
        workspace: store_protocol.Workspace,
        workspace_index: usize,
        snapshot: store_protocol.Snapshot,
        is_first_workspace: bool,
    ) !void {
        return self.insertWorkspaceAtRevision(workspace, workspace_index, snapshot, is_first_workspace, null);
    }

    fn insertWorkspaceAtRevision(
        self: *Self,
        workspace: store_protocol.Workspace,
        workspace_index: usize,
        snapshot: store_protocol.Snapshot,
        is_first_workspace: bool,
        store_revision: ?i64,
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
                store_revision,
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
                    store_revision,
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
        store_revision: ?i64,
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
            if (store_revision) |revision| {
                if (message.message_id.len != 0) try self.insertMessageKey(thread_row_id, @intCast(message_index), message, revision);
            }
        }
    }

    fn insertMessage(self: *Self, thread_row_id: i64, sort_index: i64, message: store_protocol.Message) !void {
        const role_code = try roleCode(message.role);
        const kind_code = if (message.tool_call_kind) |value| try toolCallKindCode(value) else null;
        const status_code = if (message.tool_call_status) |value| try toolCallStatusCode(value) else null;
        const image = try firstAttachment(message.image, message.images);

        try self.conn.exec(
            "insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime, image_byte_size, tool_call_id, tool_call_kind, tool_call_status, message_id, created_at_ms, updated_at_ms) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
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
                if (message.message_id.len != 0) message.message_id else null,
                message.created_at_ms,
                message.updated_at_ms,
            },
        );
    }

    fn insertMessageKey(
        self: *Self,
        thread_row_id: i64,
        sort_index: i64,
        message: store_protocol.Message,
        store_revision: i64,
    ) !void {
        const fingerprint = self.encodeFingerprint(message) catch |err| return err;
        defer self.allocator.free(fingerprint);
        try self.conn.exec(
            "insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index, created_at_ms, updated_at_ms, store_revision) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            .{ thread_row_id, message.message_id, fingerprint, sort_index, message.created_at_ms, message.updated_at_ms, store_revision },
        );
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

fn mutationHeader(mutation: Mutation) store_protocol.MutationHeader {
    return switch (mutation) {
        .snapshot_replace => |request| request.mutation,
        .workspace_upsert => |request| request.mutation,
        .thread_upsert => |request| request.mutation,
        .message_append => |request| request.mutation,
        .surface_upsert => |request| request.mutation,
        .surface_clear => |request| request.mutation,
        .chat_completion_upsert => |request| request.mutation,
        .chat_completion_clear => |request| request.mutation,
    };
}

fn mutationOperation(mutation: Mutation) []const u8 {
    return switch (mutation) {
        .snapshot_replace => SNAPSHOT_REPLACE_OPERATION,
        .workspace_upsert => WORKSPACE_UPSERT_OPERATION,
        .thread_upsert => THREAD_UPSERT_OPERATION,
        .message_append => MESSAGE_APPEND_OPERATION,
        .surface_upsert => SURFACE_UPSERT_OPERATION,
        .surface_clear => SURFACE_CLEAR_OPERATION,
        .chat_completion_upsert => CHAT_COMPLETION_UPSERT_OPERATION,
        .chat_completion_clear => CHAT_COMPLETION_CLEAR_OPERATION,
    };
}

fn validateMutation(mutation: Mutation) StoreError!void {
    const header = mutationHeader(mutation);
    if (header.request_key.len == 0 or header.client_id.len == 0) return error.InvalidParams;
    switch (mutation) {
        .snapshot_replace => |request| {
            if (!request.bootstrap and request.mutation.expected_store_revision == null) return error.InvalidParams;
        },
        .workspace_upsert => |request| {
            if (request.workspace.workspace_id.len == 0 or request.workspace.label.len == 0 or request.workspace.path.len == 0) return error.InvalidParams;
            if (request.workspace.threads.len != 0 or request.workspace.messages.len != 0) return error.InvalidParams;
        },
        .thread_upsert => |request| {
            if (request.workspace_id.len == 0 or request.thread.local_thread_id.len == 0) return error.InvalidParams;
            if (request.thread.messages.len != 0) return error.InvalidParams;
            _ = try firstAttachment(request.thread.draft_image, request.thread.draft_images);
        },
        .message_append => |request| {
            if (request.workspace_id.len == 0 or request.thread_id.len == 0 or request.message.message_id.len == 0) return error.InvalidParams;
            _ = try firstAttachment(request.message.image, request.message.images);
        },
        .surface_upsert => |request| {
            if (request.surface.session_id.len == 0) return error.InvalidParams;
        },
        .surface_clear => |request| {
            if (request.session_id.len == 0) return error.InvalidParams;
        },
        .chat_completion_upsert => |request| {
            if (request.completion.workspace_id.len == 0 or request.completion.local_thread_id.len == 0) return error.InvalidParams;
        },
        .chat_completion_clear => |request| {
            if (request.workspace_id.len == 0 or request.local_thread_id.len == 0) return error.InvalidParams;
        },
    }
}

fn validateTurnCommit(request: TurnCommitRequest) StoreError!void {
    if (request.turn_id.len == 0 or request.workspace_id.len == 0 or request.local_thread_id.len == 0 or request.provider.len == 0) {
        return error.InvalidParams;
    }
    if (request.client_id.len == 0) return error.InvalidParams;
    if (request.completion) |completion| {
        if (!std.mem.eql(u8, completion.workspace_id, request.workspace_id) or
            !std.mem.eql(u8, completion.local_thread_id, request.local_thread_id)) return error.InvalidParams;
    }
    for (request.messages) |message| {
        _ = try firstAttachment(message.image, message.images);
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
    if (err == error.StoreMetadataMissing) return error.StoreCorrupt;
    return mapSqliteError(err);
}

fn mapStoreError(err: anyerror) StoreError {
    if (err == error.Conflict) return error.Conflict;
    if (err == error.InvalidParams) return error.InvalidParams;
    if (err == error.ResourceNotFound) return error.ResourceNotFound;
    if (err == error.CapabilityUnavailable) return error.CapabilityUnavailable;
    if (err == error.Internal) return error.Internal;
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (err == error.StoreCorrupt or err == error.StoreMetadataMissing) return error.StoreCorrupt;
    return mapSqliteError(err);
}

fn dupeNullableText(allocator: std.mem.Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn optionalU32(value: ?i64) !?u32 {
    const integer = value orelse return null;
    if (integer < 0 or integer > std.math.maxInt(u32)) return error.StoreCorrupt;
    return @intCast(integer);
}

fn requiredU32(value: i64) !u32 {
    if (value < 0 or value > std.math.maxInt(u32)) return error.StoreCorrupt;
    return @intCast(value);
}

fn requiredU64(value: i64) !u64 {
    if (value < 0) return error.StoreCorrupt;
    return @intCast(value);
}

fn copyResources(allocator: std.mem.Allocator, resources_json: []const u8) !std.ArrayListUnmanaged([]u8) {
    var parsed = std.json.parseFromSlice([][]const u8, allocator, resources_json, .{
        .allocate = .alloc_always,
    }) catch return error.StoreCorrupt;
    defer parsed.deinit();

    var resources: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer freeOwnedResources(allocator, &resources);
    for (parsed.value) |resource| {
        const owned = try allocator.dupe(u8, resource);
        resources.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return resources;
}

fn freeOwnedResources(allocator: std.mem.Allocator, resources: *std.ArrayListUnmanaged([]u8)) void {
    for (resources.items) |resource| allocator.free(resource);
    resources.deinit(allocator);
    resources.* = .empty;
}

fn parseOutcomeStatus(value: []const u8) !TerminalProcessOutcomeStatus {
    inline for (std.meta.fields(TerminalProcessOutcomeStatus)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.StoreCorrupt;
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

fn testThread(id: []const u8, title: []const u8) store_protocol.Thread {
    return .{ .local_thread_id = id, .title = title };
}

fn testHeader(request_key: []const u8, expected_store_revision: ?u64) store_protocol.MutationHeader {
    return .{
        .request_key = request_key,
        .expected_store_revision = expected_store_revision,
        .client_id = "test-client",
    };
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

test "lease and terminal outcome transfer is durable, pruned, and one revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    // Empty transfer is a real snapshot: clears tables and bumps once.
    const empty = try store.persistLeasesAndOutcomes(&.{}, &.{});
    try std.testing.expectEqual(@as(u64, 1), empty.store_revision);
    try std.testing.expect(empty.applied);
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());
    try std.testing.expectEqual(@as(i64, 0), try transferLeaseCount(&store));
    try std.testing.expectEqual(@as(i64, 0), try transferOutcomeCount(&store));

    const resources = [_][]const u8{ "build", "src" };
    const leases = [_]LeaseRecord{
        .{
            .workspace_id = "workspace-transfer",
            .lease_id = "lease:keep",
            .owner = "owner-a",
            .client_id = "client-a",
            .command = "zig build",
            .resources = &resources,
            .created_at_ms = 10,
            .expires_at_ms = 200,
            .last_renewal_ms = 100,
        },
        .{
            .workspace_id = "workspace-transfer",
            .lease_id = "lease:boundary",
            .owner = "owner-boundary",
            .client_id = "client-boundary",
            .command = "zig fmt",
            .resources = &.{"fmt"},
            .created_at_ms = 11,
            // expires == now is deleted on import and excluded by the > select.
            .expires_at_ms = 150,
            .last_renewal_ms = 60,
        },
        .{
            .workspace_id = "workspace-transfer",
            .lease_id = "lease:expired",
            .owner = "owner-b",
            .client_id = "client-b",
            .command = "zig test",
            .resources = &.{"test"},
            .created_at_ms = 10,
            .expires_at_ms = 100,
            .last_renewal_ms = 50,
        },
    };
    const outcomes = [_]TerminalProcessOutcome{.{
        .workspace_id = "workspace-transfer",
        .process_id = "term:session-1:1",
        .generation = 1,
        .session_id = "session-1",
        .command = "zig build",
        .cwd = "/workspace",
        .pid = 42,
        .process_group = null,
        .started_at_ms = 20,
        .finished_at_ms = 120,
        .dock_id = 0,
        .pane_id = null,
        .owner_kind = "terminal",
        .owner_title = "Build",
        .provider = "codex",
        .status = .failed,
        .exit_code = 1,
        .signal = null,
        .cancellation_reason = "test",
    }};

    const persisted = try store.persistLeasesAndOutcomes(&leases, &outcomes);
    try std.testing.expectEqual(@as(u64, 2), persisted.store_revision);
    try std.testing.expect(persisted.applied);
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
    try std.testing.expectEqual(@as(i64, 3), try transferLeaseCount(&store));
    try std.testing.expectEqual(@as(i64, 1), try transferOutcomeCount(&store));

    var imported = try store.importLeasesAndOutcomes(150);
    defer imported.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), imported.leases.items.len);
    try std.testing.expectEqual(@as(i64, 1), try transferLeaseCount(&store));
    try std.testing.expectEqualStrings("lease:keep", imported.leases.items[0].lease_id);
    try std.testing.expectEqualStrings("owner-a", imported.leases.items[0].owner);
    try std.testing.expectEqualStrings("client-a", imported.leases.items[0].client_id);
    try std.testing.expectEqualStrings("zig build", imported.leases.items[0].command);
    try std.testing.expectEqual(@as(i64, 10), imported.leases.items[0].created_at_ms);
    try std.testing.expectEqual(@as(i64, 200), imported.leases.items[0].expires_at_ms);
    try std.testing.expectEqual(@as(i64, 100), imported.leases.items[0].last_renewal_ms);
    try std.testing.expectEqual(@as(usize, 2), imported.leases.items[0].resources.items.len);
    try std.testing.expectEqualStrings("build", imported.leases.items[0].resources.items[0]);
    try std.testing.expectEqual(@as(usize, 1), imported.outcomes.items.len);
    try std.testing.expectEqualStrings("term:session-1:1", imported.outcomes.items[0].process_id);
    try std.testing.expectEqual(TerminalProcessOutcomeStatus.failed, imported.outcomes.items[0].status);
    try std.testing.expectEqual(@as(?u32, 42), imported.outcomes.items[0].pid);
    try std.testing.expectEqualStrings("test", imported.outcomes.items[0].cancellation_reason.?);
    // Import prunes only; it does not bump revision.
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());

    // Empty drain over a stale non-empty snapshot clears transfer rows and bumps once.
    const cleared = try store.persistLeasesAndOutcomes(&.{}, &.{});
    try std.testing.expectEqual(@as(u64, 3), cleared.store_revision);
    try std.testing.expect(cleared.applied);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());
    try std.testing.expectEqual(@as(i64, 0), try transferLeaseCount(&store));
    try std.testing.expectEqual(@as(i64, 0), try transferOutcomeCount(&store));
    var after_empty = try store.importLeasesAndOutcomes(150);
    defer after_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), after_empty.leases.items.len);
    try std.testing.expectEqual(@as(usize, 0), after_empty.outcomes.items.len);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());
}

test "import maps out-of-range transfer integers to StoreCorrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const outcomes = [_]TerminalProcessOutcome{.{
        .workspace_id = "workspace-corrupt",
        .process_id = "term:session-corrupt:1",
        .generation = 1,
        .session_id = "session-corrupt",
        .command = "zig build",
        .cwd = "/workspace",
        .pid = 7,
        .process_group = null,
        .started_at_ms = 20,
        .finished_at_ms = 120,
        .dock_id = 1,
        .pane_id = null,
        .owner_kind = "terminal",
        .owner_title = "Build",
        .provider = null,
        .status = .completed,
        .exit_code = 0,
        .signal = null,
        .cancellation_reason = null,
    }};
    _ = try store.persistLeasesAndOutcomes(&.{}, &outcomes);

    // Negative generation would panic under unguarded @intCast on release=safe.
    try store.conn.exec(
        "update terminal_process_outcomes set generation = -1 where process_id = ?1",
        .{"term:session-corrupt:1"},
    );
    try std.testing.expectError(error.StoreCorrupt, store.importLeasesAndOutcomes(150));

    // Restore a valid generation then poison dock_id.
    try store.conn.exec(
        "update terminal_process_outcomes set generation = 1, dock_id = -1 where process_id = ?1",
        .{"term:session-corrupt:1"},
    );
    try std.testing.expectError(error.StoreCorrupt, store.importLeasesAndOutcomes(150));

    // Invalid non-null optional integer must also be StoreCorrupt, not silent null.
    try store.conn.exec(
        "update terminal_process_outcomes set dock_id = 1, pid = -1 where process_id = ?1",
        .{"term:session-corrupt:1"},
    );
    try std.testing.expectError(error.StoreCorrupt, store.importLeasesAndOutcomes(150));
}

fn transferLeaseCount(store: *const Store) !i64 {
    const row = (try store.conn.row("select count(*) from workspace_leases", .{})).?;
    defer row.deinit();
    return row.int(0);
}

fn transferOutcomeCount(store: *const Store) !i64 {
    const row = (try store.conn.row("select count(*) from terminal_process_outcomes", .{})).?;
    defer row.deinit();
    return row.int(0);
}

test "turn commit is durable, ordered, exactly once, and revision guarded by receipt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const workspace = testWorkspace("workspace-turn", "Turn workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("turn-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-turn", "Turn thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("turn-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const messages = [_]store_protocol.Message{
        .{
            .message_id = "turn-message-1",
            .role = "assistant",
            .author = "codex",
            .body = "first row",
            .created_at_ms = 101,
            .updated_at_ms = 102,
        },
        .{
            .message_id = "turn-message-2",
            .role = "system",
            .author = "System",
            .body = "second row",
            .created_at_ms = 103,
            .updated_at_ms = 104,
        },
    };
    const request: TurnCommitRequest = .{
        .turn_id = "turn-1",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 100,
        .finished_at_ms = 110,
        .provider = "codex",
        .provider_thread_id = "provider-turn-1",
        .user_message_id = "user-message-1",
        .messages = &messages,
        .completion = .{
            .workspace_id = workspace.workspace_id,
            .local_thread_id = thread.local_thread_id,
            .completed_at_ms = 110,
        },
    };

    const first = try store.commitTurn(request);
    try std.testing.expectEqual(@as(u64, 3), first.store_revision);
    try std.testing.expect(first.applied);
    try std.testing.expect(!first.duplicate);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    var rows = try store.conn.rows(
        "select message_id, body, created_at_ms, updated_at_ms from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
        .{thread.local_thread_id},
    );
    defer rows.deinit();
    var row_count: usize = 0;
    while (rows.next()) |row| : (row_count += 1) {
        if (row_count == 0) {
            try std.testing.expectEqualStrings("turn-message-1", row.text(0));
            try std.testing.expectEqualStrings("first row", row.text(1));
            try std.testing.expectEqual(@as(i64, 101), row.int(2));
            try std.testing.expectEqual(@as(i64, 102), row.int(3));
        } else if (row_count == 1) {
            try std.testing.expectEqualStrings("turn-message-2", row.text(0));
            try std.testing.expectEqualStrings("second row", row.text(1));
            try std.testing.expectEqual(@as(i64, 103), row.int(2));
            try std.testing.expectEqual(@as(i64, 104), row.int(3));
        }
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), row_count);

    var ledger = (try store.conn.row(
        "select status, provider_thread_id, user_message_id, committed_store_revision from chat_turns where turn_id = ?1",
        .{request.turn_id},
    )).?;
    defer ledger.deinit();
    try std.testing.expectEqualStrings("completed", ledger.text(0));
    try std.testing.expectEqualStrings("provider-turn-1", ledger.text(1));
    try std.testing.expectEqualStrings("user-message-1", ledger.text(2));
    try std.testing.expectEqual(@as(i64, 3), ledger.int(3));

    var completion = (try store.conn.row(
        "select count(*) from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
        .{ workspace.workspace_id, thread.local_thread_id },
    )).?;
    defer completion.deinit();
    try std.testing.expectEqual(@as(i64, 1), completion.int(0));

    const replay = try store.commitTurn(request);
    try std.testing.expectEqual(first.store_revision, replay.store_revision);
    try std.testing.expect(replay.applied);
    try std.testing.expect(!replay.duplicate);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    var replay_rows = (try store.conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer replay_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), replay_rows.int(0));
}

test "transcript_apply rows commit with deterministic IDs and replay exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-apply", "Apply workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("apply-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-apply", "Apply thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("apply-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const events = [_]transcript_apply.ChatEvent{
        .{ .kind = "assistant_delta", .payload_json = "{\"text\":\"synthesized row\"}" },
        .{ .kind = "message", .payload_json = "{\"title\":\"Existing\",\"body\":\"real row\",\"message_id\":\"real-message-id\"}" },
    };
    const outcome: transcript_apply.WorkerOutcome = .{
        .status = .completed,
        .provider = "codex",
    };
    const applied = try transcript_apply.apply(std.testing.allocator, &events, outcome);
    defer transcript_apply.freeMessages(std.testing.allocator, applied);
    try std.testing.expectEqual(@as(usize, 2), applied.len);
    try std.testing.expectEqual(@as(usize, 0), applied[0].message_id.len);
    try std.testing.expectEqualStrings("real-message-id", applied[1].message_id);

    const request: TurnCommitRequest = .{
        .turn_id = "turn-apply",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 300,
        .finished_at_ms = 310,
        .provider = outcome.provider,
        .messages = applied,
    };
    try std.testing.expectEqualStrings("chat.turn.commit", TURN_COMMIT_OPERATION);
    const first = try store.commitTurn(request);
    try std.testing.expectEqual(@as(u64, 3), first.store_revision);

    var rows = try store.conn.rows(
        "select message_id, body from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
        .{thread.local_thread_id},
    );
    defer rows.deinit();
    var row_count: usize = 0;
    while (rows.next()) |row| : (row_count += 1) {
        if (row_count == 0) {
            try std.testing.expectEqualStrings("turn:turn-apply:msg:0", row.text(0));
            try std.testing.expectEqualStrings("synthesized row", row.text(1));
        } else if (row_count == 1) {
            try std.testing.expectEqualStrings("real-message-id", row.text(0));
            try std.testing.expectEqualStrings("real row", row.text(1));
        }
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), row_count);

    const replay = try store.commitTurn(request);
    try std.testing.expectEqual(first.store_revision, replay.store_revision);
    try std.testing.expect(replay.applied);
    try std.testing.expect(!replay.duplicate);
    var replay_rows = (try store.conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer replay_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), replay_rows.int(0));
    try std.testing.expectEqual(@as(usize, 0), applied[0].message_id.len);
}

test "aborted turn carries followup intent and compaction expiry uses revision_expired data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-aborted", "Aborted workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("aborted-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-aborted", "Aborted thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("aborted-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const request: TurnCommitRequest = .{
        .turn_id = "turn-aborted",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .aborted,
        .started_at_ms = 200,
        .finished_at_ms = 210,
        .provider = "codex",
        .followup_pending = true,
    };
    const result = try store.commitTurn(request);
    try std.testing.expectEqual(@as(u64, 3), result.store_revision);
    var ledger = (try store.conn.row("select status from chat_turns where turn_id = ?1", .{request.turn_id})).?;
    defer ledger.deinit();
    try std.testing.expectEqualStrings("aborted", ledger.text(0));
    var completion = (try store.conn.row(
        "select count(*) from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
        .{ workspace.workspace_id, thread.local_thread_id },
    )).?;
    defer completion.deinit();
    try std.testing.expectEqual(@as(i64, 0), completion.int(0));

    const expiry = compactionError(17);
    try std.testing.expectEqualStrings(protocol.ERR_REVISION_EXPIRED, expiry.code);
    try std.testing.expectEqual(@as(u64, 17), expiry.data.compacted_before_seq);
    const encoded = try store_protocol.encode(std.testing.allocator, expiry);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "compacted_before_seq") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "revision_expired") != null);
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

test "store migrates populated v1 WAL state into the v4 chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const legacy = try zqlite.open(db_path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    defer legacy.close();
    try schema.initialize(legacy);
    try legacy.execNoArgs(
        \\insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, 0, 0);
        \\insert into workspaces (workspace_id, sort_index, label, path) values ('legacy-workspace', 0, 'Legacy', '/legacy');
    );
    _ = try tmp.dir.statFile(std.testing.io, "state.sqlite-wal", .{});

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    try std.testing.expectEqual(@as(i64, 4), blk: {
        const row = (try store.conn.row("pragma user_version", .{})).?;
        defer row.deinit();
        break :blk row.int(0);
    });
    try std.testing.expectEqual(@as(i64, 1), try workspaceCount(&store));
    try std.testing.expectEqual(@as(u64, 0), try store.storeRevision());
    try std.testing.expect(try schema.testHasColumn(store.conn, "store_receipts", "response_payload"));
}

test "granular mutations are durable, idempotent, and revision guarded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const workspace = testWorkspace("workspace-1", "Workspace");
    const workspace_result = try store.upsertWorkspace(.{
        .mutation = testHeader("workspace-1", null),
        .workspace = workspace,
    });
    try std.testing.expectEqual(@as(u64, 1), workspace_result.store_revision);

    const thread = testThread("thread-1", "Thread");
    const thread_result = try store.upsertThread(.{
        .mutation = testHeader("thread-1", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });
    try std.testing.expectEqual(@as(u64, 2), thread_result.store_revision);

    const message: store_protocol.Message = .{
        .message_id = "message-1",
        .role = "user",
        .author = "You",
        .body = "hello",
    };
    const append_request: store_protocol.MessageAppendRequest = .{
        .mutation = testHeader("message-1", 2),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = message,
    };
    const append_result = try store.appendMessage(append_request);
    try std.testing.expectEqual(@as(u64, 3), append_result.store_revision);

    const request_duplicate = try store.appendMessage(append_request);
    try std.testing.expectEqual(append_result.store_revision, request_duplicate.store_revision);
    try std.testing.expectEqual(append_result.applied, request_duplicate.applied);
    try std.testing.expectEqual(append_result.duplicate, request_duplicate.duplicate);

    var fresh_key_duplicate = append_request;
    fresh_key_duplicate.mutation = testHeader("message-duplicate", 0);
    const natural_duplicate = try store.appendMessage(fresh_key_duplicate);
    try std.testing.expectEqual(@as(u64, 3), natural_duplicate.store_revision);
    try std.testing.expect(!natural_duplicate.applied);
    try std.testing.expect(natural_duplicate.duplicate);

    var collision = fresh_key_duplicate;
    collision.mutation = testHeader("message-collision", 3);
    collision.message.body = "changed";
    try std.testing.expectError(error.Conflict, store.appendMessage(collision));
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    try std.testing.expectError(error.Conflict, store.upsertThread(.{
        .mutation = testHeader("stale-thread", 0),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    }));

    const surface_result = try store.upsertSurface(.{
        .mutation = testHeader("surface-1", 3),
        .surface = .{ .session_id = "session-1", .status = "done" },
    });
    try std.testing.expectEqual(@as(u64, 4), surface_result.store_revision);
    const clear_surface = try store.clearSurface(.{
        .mutation = testHeader("surface-clear", 4),
        .session_id = "session-1",
    });
    try std.testing.expect(clear_surface.applied);
    try std.testing.expectEqual(@as(u64, 5), clear_surface.store_revision);
    const clear_missing_surface = try store.clearSurface(.{
        .mutation = testHeader("surface-clear-missing", 5),
        .session_id = "missing",
    });
    try std.testing.expect(!clear_missing_surface.applied);
    try std.testing.expectEqual(@as(u64, 6), clear_missing_surface.store_revision);

    const completion_result = try store.upsertChatCompletion(.{
        .mutation = testHeader("completion-1", 6),
        .completion = .{ .workspace_id = workspace.workspace_id, .local_thread_id = thread.local_thread_id, .completed_at_ms = 7 },
    });
    try std.testing.expectEqual(@as(u64, 7), completion_result.store_revision);
    const clear_completion = try store.clearChatCompletion(.{
        .mutation = testHeader("completion-clear", 7),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
    });
    try std.testing.expect(clear_completion.applied);
    const clear_missing_completion = try store.clearChatCompletion(.{
        .mutation = testHeader("completion-clear-missing", 8),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
    });
    try std.testing.expect(!clear_missing_completion.applied);
    try std.testing.expectEqual(@as(u64, 9), clear_missing_completion.store_revision);
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
    const first = try store.applyMutation(.{ .snapshot_replace = first_request });

    const duplicate = try store.applyMutation(.{ .snapshot_replace = first_request });
    try std.testing.expectEqual(first.store_revision, duplicate.store_revision);
    try std.testing.expectEqual(first.applied, duplicate.applied);
    try std.testing.expectEqual(first.duplicate, duplicate.duplicate);
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());

    var retried_request = testSnapshotRequest("same-key", 99, true, testSnapshot(&workspaces));
    retried_request.mutation.client_id = "replacement-client";
    const duplicate_after_replacement = try store.applyMutation(.{ .snapshot_replace = retried_request });
    try std.testing.expectEqual(first.store_revision, duplicate_after_replacement.store_revision);
    try std.testing.expectEqual(first.applied, duplicate_after_replacement.applied);
    try std.testing.expectEqual(first.duplicate, duplicate_after_replacement.duplicate);

    const changed_workspace = testWorkspace("workspace-1", "Changed");
    const changed_workspaces = [_]store_protocol.Workspace{changed_workspace};
    var changed_request = testSnapshotRequest("same-key", 99, true, testSnapshot(&changed_workspaces));
    changed_request.mutation.client_id = "replacement-client";
    try std.testing.expectError(error.Conflict, store.applyMutation(.{ .snapshot_replace = changed_request }));
    const label = try workspaceLabel(&store, "workspace-1");
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("First", label);
}

test "receipt response payload replays exactly after store reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const workspace = testWorkspace("workspace-1", "First");
    const workspaces = [_]store_protocol.Workspace{workspace};
    const request = testSnapshotRequest("reopen-key", null, true, testSnapshot(&workspaces));
    var original: store_protocol.WriteResult = undefined;
    {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        original = try store.applyMutation(.{ .snapshot_replace = request });
    }

    var reopened = try Store.init(std.testing.allocator, db_path);
    defer reopened.deinit();
    var retry = request;
    retry.mutation = testHeader("reopen-key", 99);
    retry.mutation.client_id = "replacement-client";
    const replay = try reopened.applyMutation(.{ .snapshot_replace = retry });
    try std.testing.expectEqual(original.store_revision, replay.store_revision);
    try std.testing.expectEqual(original.applied, replay.applied);
    try std.testing.expectEqual(original.duplicate, replay.duplicate);
}

test "store threads use workspace rowids when legacy compat rowids diverge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    // Simulate an unrelated legacy table whose rowid sequence is unrelated to
    // workspaces. The adapter must not use that table's last insert id.
    try store.conn.execNoArgs(
        \\create table legacy_workspace_compat (
        \\    workspace_id text primary key,
        \\    provider text not null,
        \\    harness text not null,
        \\    draft text not null
        \\);
    );
    try store.conn.exec(
        "insert into legacy_workspace_compat (rowid, workspace_id, provider, harness, draft) values (?1, ?2, ?3, ?4, ?5)",
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

test "fault hook stalls and crashes only when armed" {
    // Crash variants are not unit-testable in-process (abort kills the test
    // runner); they are covered by the headless-daemon-it subprocess scenarios.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const db_path = try testDbPath(&tmp);
        defer std.testing.allocator.free(db_path);

        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        try std.testing.expect(store.fault == .none);
        const started = platform_runtime.monotonicTimestampNs();
        const result = try store.applyMutation(.{
            .workspace_upsert = testWorkspaceRequest("fault-none", null, testWorkspace("ws-none", "None")),
        });
        const elapsed_ms = (platform_runtime.monotonicTimestampNs() - started) / std.time.ns_per_ms;
        try std.testing.expect(result.applied);
        // Unarmed path must not pay the commit_stall delay.
        try std.testing.expect(elapsed_ms < STORE_FAULT_COMMIT_STALL_MS / 2);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const db_path = try testDbPath(&tmp);
        defer std.testing.allocator.free(db_path);

        var store = try Store.initWithFault(std.testing.allocator, db_path, .commit_stall);
        defer store.deinit();
        const started = platform_runtime.monotonicTimestampNs();
        const result = try store.applyMutation(.{
            .workspace_upsert = testWorkspaceRequest("fault-stall", null, testWorkspace("ws-stall", "Stall")),
        });
        const elapsed_ms = (platform_runtime.monotonicTimestampNs() - started) / std.time.ns_per_ms;
        try std.testing.expect(result.applied);
        try std.testing.expect(elapsed_ms >= STORE_FAULT_COMMIT_STALL_MS);
    }
}

test "natural duplicate replay wins over stale expected revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const workspace = testWorkspace("workspace-1", "Workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("workspace-1", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-1", "Thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("thread-1", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const message: store_protocol.Message = .{
        .message_id = "message-1",
        .role = "user",
        .author = "You",
        .body = "hello",
    };
    const original_revision: u64 = 2;
    const append_result = try store.appendMessage(.{
        .mutation = testHeader("message-1", original_revision),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = message,
    });
    try std.testing.expectEqual(@as(u64, 3), append_result.store_revision);
    try std.testing.expect(append_result.applied);
    try std.testing.expect(!append_result.duplicate);

    // Advance revision with an unrelated mutation so the original revision is stale.
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("workspace-advance", 3),
        .workspace = testWorkspace("workspace-2", "Second"),
    });
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());

    // Same message identity + identical payload, fresh request_key, stale expected revision.
    const natural_duplicate = try store.appendMessage(.{
        .mutation = testHeader("message-1-retry", original_revision),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = message,
    });
    try std.testing.expect(!natural_duplicate.applied);
    try std.testing.expect(natural_duplicate.duplicate);
    try std.testing.expectEqual(@as(u64, 4), natural_duplicate.store_revision);
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());

    // Conflicting payload on the same key with the same stale revision → Conflict,
    // not a revision-mismatch path (more specific error wins before the guard).
    var collision = message;
    collision.body = "changed";
    try std.testing.expectError(error.Conflict, store.appendMessage(.{
        .mutation = testHeader("message-1-conflict", original_revision),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = collision,
    }));
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());
}

// Literal schema-v2 fixture: RO-open must accept a genuine v2-era DB without
// migration (S5 NIT-1 / production flip compatibility promise). Distinct from
// the MAX_SUPPORTED_VERSION pin below.
test "read-only reopen accepts literal schema v2 fixture without migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(db_path, flags);
        defer conn.close();
        try schema.initializeToVersion(conn, 2);
        try conn.exec(
            "insert into workspaces (workspace_id, sort_index, label, path) values (?1, 0, ?2, ?3)",
            .{ "v2-fixture-ws", "V2Fixture", "/v2-fixture" },
        );
        const version_row = (try conn.row("pragma user_version", .{})).?;
        defer version_row.deinit();
        try std.testing.expectEqual(@as(i64, 2), version_row.int(0));
    }

    const before_bytes = try tmp.dir.readFileAlloc(std.testing.io, "state.sqlite", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before_bytes);

    {
        const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(db_path, flags);
        defer conn.close();
        try schema.validateReadOnly(conn);

        const version_row = (try conn.row("pragma user_version", .{})).?;
        defer version_row.deinit();
        try std.testing.expectEqual(@as(i64, 2), version_row.int(0));

        const label_row = (try conn.row(
            "select label from workspaces where workspace_id = ?1",
            .{"v2-fixture-ws"},
        )).?;
        defer label_row.deinit();
        const label = try std.testing.allocator.dupe(u8, label_row.text(0));
        defer std.testing.allocator.free(label);
        try std.testing.expectEqualStrings("V2Fixture", label);

        // Store tables exist at v2; revision row is present and unmigrated.
        const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})).?;
        defer rev_row.deinit();
        try std.testing.expectEqual(@as(i64, 0), rev_row.int(0));

        try std.testing.expectError(error.ReadOnly, conn.execNoArgs("delete from workspaces"));
    }

    const after_bytes = try tmp.dir.readFileAlloc(std.testing.io, "state.sqlite", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after_bytes);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
}

// Read-only reopen of a store-created DB must accept the schema without
// migration or any main-file write (m3_design read-only contract; S5 pin).
// Store.init lands at MAX_SUPPORTED_VERSION (includes v2 store tables);
// validateReadOnly accepts CURRENT_VERSION..=MAX without migrating.
test "read-only reopen accepts schema v2 without migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const version_before: i64, const journal_before: []u8 = blk: {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        const result = try store.applyMutation(.{
            .workspace_upsert = testWorkspaceRequest(
                "ro-reopen-ws",
                null,
                testWorkspace("ro-workspace", "ReadOnly"),
            ),
        });
        try std.testing.expect(result.applied);
        try std.testing.expectEqual(@as(u64, 1), result.store_revision);

        const version_row = (try store.conn.row("pragma user_version", .{})).?;
        defer version_row.deinit();
        const version = version_row.int(0);
        try std.testing.expect(version >= schema.CURRENT_VERSION);
        try std.testing.expect(version <= schema.MAX_SUPPORTED_VERSION);
        // Store tables land at v2+; pin that we reopen a store-capable schema.
        try std.testing.expect(version >= 2);

        const journal_row = (try store.conn.row("pragma journal_mode", .{})).?;
        defer journal_row.deinit();
        break :blk .{ version, try std.testing.allocator.dupe(u8, journal_row.text(0)) };
    };
    defer std.testing.allocator.free(journal_before);

    const before_bytes = try tmp.dir.readFileAlloc(std.testing.io, "state.sqlite", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(before_bytes);
    const before_stat = try tmp.dir.statFile(std.testing.io, "state.sqlite", .{});

    {
        const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(db_path, flags);
        defer conn.close();
        // Accept without initialize/migrate (same pathway as db/client.zig initReadOnly).
        try schema.validateReadOnly(conn);

        const version_row = (try conn.row("pragma user_version", .{})).?;
        defer version_row.deinit();
        try std.testing.expectEqual(version_before, version_row.int(0));

        const journal_row = (try conn.row("pragma journal_mode", .{})).?;
        defer journal_row.deinit();
        try std.testing.expectEqualStrings(journal_before, journal_row.text(0));

        // Copy text before finalize (Zig 0.16 / zqlite lifetime rule).
        const label_row = (try conn.row(
            "select label from workspaces where workspace_id = ?1",
            .{"ro-workspace"},
        )).?;
        defer label_row.deinit();
        const label = try std.testing.allocator.dupe(u8, label_row.text(0));
        defer std.testing.allocator.free(label);
        try std.testing.expectEqualStrings("ReadOnly", label);

        const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})).?;
        defer rev_row.deinit();
        try std.testing.expectEqual(@as(i64, 1), rev_row.int(0));

        // RO open must not write (query_only / ReadOnly flags).
        try std.testing.expectError(error.ReadOnly, conn.execNoArgs("delete from workspaces"));
    }

    const after_bytes = try tmp.dir.readFileAlloc(std.testing.io, "state.sqlite", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after_bytes);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
    const after_stat = try tmp.dir.statFile(std.testing.io, "state.sqlite", .{});
    try std.testing.expectEqual(before_stat.size, after_stat.size);
    try std.testing.expectEqual(before_stat.mtime.nanoseconds, after_stat.mtime.nanoseconds);
}

// Clean writer close may leave -wal/-shm absent or residual; deleting them must
// not prevent a read-only open from seeing committed store data (S5 / m3_design).
test "read-only reopen succeeds after clean close removes WAL sidecars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        const result = try store.applyMutation(.{
            .workspace_upsert = testWorkspaceRequest(
                "ro-sidecar-ws",
                null,
                testWorkspace("ro-sidecar-workspace", "Sidecar"),
            ),
        });
        try std.testing.expect(result.applied);
        try std.testing.expectEqual(@as(u64, 1), result.store_revision);
    }

    // Sidecars are absent or harmless after clean close; force the -shm-absent case.
    tmp.dir.deleteFile(std.testing.io, "state.sqlite-wal") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    tmp.dir.deleteFile(std.testing.io, "state.sqlite-shm") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(db_path, flags);
    defer conn.close();
    try schema.validateReadOnly(conn);

    const label_row = (try conn.row(
        "select label from workspaces where workspace_id = ?1",
        .{"ro-sidecar-workspace"},
    )).?;
    defer label_row.deinit();
    const label = try std.testing.allocator.dupe(u8, label_row.text(0));
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("Sidecar", label);

    const rev_row = (try conn.row("select store_revision from store_state where id = 1", .{})).?;
    defer rev_row.deinit();
    try std.testing.expectEqual(@as(i64, 1), rev_row.int(0));
}
