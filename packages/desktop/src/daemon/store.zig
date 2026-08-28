//! Daemon-owned SQLite store adapter (M3 sole writer after Phase 3 flip).
//!
//! After endpoint ownership the production daemon opens `{pref}/state.sqlite`
//! (hermetic tests may redirect via `VERDE_SESSION_DAEMON_STORE_DIR`). The
//! adapter owns the transaction, receipt, and durable revision boundary.

const std = @import("std");
const zqlite = @import("zqlite");
const headless = @import("headless");

const schema = @import("../db/schema.zig");
const access_store = @import("access_store.zig");
const connect_store = @import("connect_store.zig");
const transcript_apply = @import("../chat/transcript_apply.zig");
const platform_runtime = @import("platform_runtime");

const store_protocol = headless.store;
const protocol = headless.protocol;
const log = std.log.scoped(.daemon_store);

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
    RuntimeIdentityMismatch,
    InvalidRuntimeIdentity,
    PageCursorInvalid,
    PageCursorStale,
    PageCursorMismatch,
    OutOfMemory,
};

/// Identity pair bound to the authoritative daemon SQLite store.
pub const RuntimeIdentity = schema.RuntimeIdentity;

/// Maximum repositories accepted in one workspace manifest.
pub const MAX_WORKSPACE_REPOSITORIES: usize = 64;
/// Maximum runtime bindings accepted for one repository.
pub const MAX_REPOSITORY_BINDINGS: usize = 64;
/// Maximum encoded repository identifier length.
pub const MAX_REPOSITORY_ID_BYTES: usize = 128;
/// Maximum encoded repository display-label length.
pub const MAX_REPOSITORY_LABEL_BYTES: usize = 256;
/// Maximum absolute checkout-root length.
pub const MAX_REPOSITORY_PATH_BYTES: usize = 4 * 1024;
/// Maximum credential-free VCS identity length.
pub const MAX_VCS_IDENTITY_BYTES: usize = 2 * 1024;
/// Maximum default-branch name length.
pub const MAX_DEFAULT_BRANCH_BYTES: usize = 255;

/// Metadata whose identity is stable across runtime-local checkouts.
/// `vcs_identity` is an optional credential-free fetch identity, never a URL
/// carrying userinfo, query tokens, fragments, or percent-encoded secrets.
pub const RepositoryDefinition = store_protocol.RepositoryDefinition;

/// Receipt-backed stable repository metadata mutation.
pub const WorkspaceRepositoryUpsertRequest = store_protocol.WorkspaceRepositoryUpsertRequest;

/// Receipt-backed repository reference removal mutation.
pub const WorkspaceRepositoryRemoveRequest = store_protocol.WorkspaceRepositoryRemoveRequest;

/// Receipt-backed workspace default selection mutation.
pub const WorkspaceDefaultRepositorySetRequest = store_protocol.WorkspaceDefaultRepositorySetRequest;

/// Receipt-backed runtime-local checkout binding mutation.
pub const WorkspaceRepositoryBindingUpsertRequest = store_protocol.WorkspaceRepositoryBindingUpsertRequest;

/// Receipt-backed checkout-reference removal mutation.
pub const WorkspaceRepositoryBindingRemoveRequest = store_protocol.WorkspaceRepositoryBindingRemoveRequest;

/// Allocator-owned manifest returned by `loadWorkspaceRepositoryManifest`.
pub const OwnedWorkspaceRepositoryManifest = struct {
    workspace_id: []u8,
    default_repository_id: []u8,
    repositories: []store_protocol.Repository,

    pub fn deinit(self: *OwnedWorkspaceRepositoryManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.default_repository_id);
        for (self.repositories) |repository| freeOwnedRepository(allocator, repository);
        allocator.free(self.repositories);
        self.* = undefined;
    }
};

/// Allocator-owned exact runtime binding returned by the targeted loader.
pub const OwnedWorkspaceRepositoryBinding = struct {
    workspace_id: []u8,
    repository_id: []u8,
    runtime_id: []u8,
    root_path: []u8,
    availability: []u8,

    pub fn deinit(self: *OwnedWorkspaceRepositoryBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.repository_id);
        allocator.free(self.runtime_id);
        allocator.free(self.root_path);
        allocator.free(self.availability);
        self.* = undefined;
    }
};

/// Validate a runtime-independent cwd carried by a client. Null selects the
/// repository root; absolute, parent, dot, empty-segment, and Windows-shaped
/// paths are rejected before filesystem resolution.
pub fn validateRepositoryRelativeCwd(relative_cwd: ?[]const u8) StoreError!void {
    if (relative_cwd) |value| {
        if (!validRepositoryCwd(value)) return error.InvalidParams;
    }
}

pub const Mutation = union(enum) {
    snapshot_replace: store_protocol.SnapshotReplaceRequest,
    workspace_upsert: store_protocol.WorkspaceUpsertRequest,
    workspace_repository_upsert: WorkspaceRepositoryUpsertRequest,
    workspace_repository_remove: WorkspaceRepositoryRemoveRequest,
    workspace_default_repository_set: WorkspaceDefaultRepositorySetRequest,
    workspace_repository_binding_upsert: WorkspaceRepositoryBindingUpsertRequest,
    workspace_repository_binding_remove: WorkspaceRepositoryBindingRemoveRequest,
    thread_upsert: store_protocol.ThreadUpsertRequest,
    chat_draft_set: store_protocol.ChatDraftSetRequest,
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
    harness: []const u8 = "local_cli",
    provider_thread_id: ?[]const u8 = null,
    /// Missing owners are created inside the receipt-backed commit. Existing
    /// owners retain GUI metadata; only turn-owned provider identity changes.
    workspace: ?store_protocol.Workspace = null,
    thread: ?store_protocol.Thread = null,
    /// Automatic titles may replace only the exact first-prompt fallback
    /// observed by the worker. This keeps a concurrent manual rename intact.
    expected_thread_title: ?[]const u8 = null,
    generated_title: ?[]const u8 = null,
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

/// One durable acceptance transition: owner creation, provider identity, the
/// user row, and the running ledger share one revision and rollback boundary.
pub const TurnAcceptanceRequest = struct {
    mutation: store_protocol.MutationHeader,
    turn_id: []const u8,
    workspace: store_protocol.Workspace,
    thread: store_protocol.Thread,
    started_at_ms: i64,
    provider: []const u8,
    harness: []const u8,
    provider_thread_id: ?[]const u8 = null,
    user_message: store_protocol.Message,
};

pub const TurnOwnerInsertions = struct {
    workspace: bool = false,
    thread: bool = false,
};

const AcceptanceTestHold = struct {
    acquired: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),
};

/// Post-commit notification hook (M5-P2 change journal). Invoked strictly
/// AFTER the SQLite transaction commits durably and never on receipt-replay,
/// message-key-duplicate, or rollback paths — a fired callback therefore
/// proves a NEW durable revision exists. Callbacks run on the committing
/// thread (the store queue, under the store service mutex, never under
/// lockDaemon) and must not call back into this store.
pub const CommitHook = struct {
    context: *anyopaque,
    on_mutation_committed: *const fn (
        context: *anyopaque,
        mutation: *const Mutation,
        result: store_protocol.WriteResult,
    ) void,
    on_turn_committed: *const fn (
        context: *anyopaque,
        request: *const TurnCommitRequest,
        inserted: TurnOwnerInsertions,
        result: store_protocol.WriteResult,
    ) void,
    on_acceptance_committed: *const fn (
        context: *anyopaque,
        request: *const TurnAcceptanceRequest,
        inserted: TurnOwnerInsertions,
        result: store_protocol.WriteResult,
    ) void,
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
const WORKSPACE_REPOSITORY_UPSERT_OPERATION: []const u8 = "workspace.repository.upsert";
const WORKSPACE_REPOSITORY_REMOVE_OPERATION: []const u8 = "workspace.repository.remove";
const WORKSPACE_DEFAULT_REPOSITORY_SET_OPERATION: []const u8 = "workspace.repository.default.set";
const WORKSPACE_REPOSITORY_BINDING_UPSERT_OPERATION: []const u8 = "workspace.repository.binding.upsert";
const WORKSPACE_REPOSITORY_BINDING_REMOVE_OPERATION: []const u8 = "workspace.repository.binding.remove";
const THREAD_UPSERT_OPERATION = store_protocol.METHOD_CHAT_THREAD_UPSERT;
const CHAT_DRAFT_SET_OPERATION = store_protocol.METHOD_CHAT_DRAFT_SET;
const MESSAGE_APPEND_OPERATION = store_protocol.METHOD_CHAT_MESSAGE_APPEND;
const SURFACE_UPSERT_OPERATION = store_protocol.METHOD_SURFACE_UPSERT;
const SURFACE_CLEAR_OPERATION = store_protocol.METHOD_SURFACE_CLEAR;
const CHAT_COMPLETION_UPSERT_OPERATION = store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT;
const CHAT_COMPLETION_CLEAR_OPERATION = store_protocol.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR;
// Reserved receipt operation for durable turn commits; keep it distinct from
// future wire method names so receipt identity cannot silently overlap.
const TURN_COMMIT_OPERATION: []const u8 = "chat.turn.commit";
const TURN_ACCEPT_OPERATION: []const u8 = "chat.turn.accept";
const RESPONSE_STATUS_OK: i64 = 0;
const FINGERPRINT_PREFIX: []const u8 = "sha256:";
const FINGERPRINT_HEX_LEN: usize = std.crypto.hash.sha2.Sha256.digest_length * 2;
const FINGERPRINT_LEN: usize = FINGERPRINT_PREFIX.len + FINGERPRINT_HEX_LEN;
const COMPACTION_MIN_FREE_BYTES: u64 = 64 * 1024 * 1024;

pub const Store = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    path: [:0]u8,
    conn: zqlite.Conn,
    /// Test-only; production construction always leaves `.none`.
    fault: StoreFault = .none,
    /// Optional post-commit journal hook; production installs it at store
    /// service construction (M5-P2). Never fired for replays or rollbacks.
    commit_hook: ?CommitHook = null,
    /// Unit-test-only acceptance controls. Production construction leaves both
    /// unset, so they cannot delay or fail a live transaction.
    acceptance_test_hold: ?AcceptanceTestHold = null,
    acceptance_test_fail_before_revision: bool = false,

    /// Open the exact database path as the sole store writer.
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) StoreError!Self {
        return initInternal(allocator, db_path, .none, null);
    }

    /// Open the store with an optional test-only fault hook (B9). Production
    /// always uses `.none`; hermetic ITs may arm stalls/crashes via env.
    pub fn initWithFault(allocator: std.mem.Allocator, db_path: []const u8, fault: StoreFault) StoreError!Self {
        return initInternal(allocator, db_path, fault, null);
    }

    /// Open the production store and atomically bind or verify its identity.
    /// Existing v8 stores must already carry this exact pair; only a database
    /// that was pre-v8 before this open may receive the one-time seed.
    pub fn initWithRuntimeIdentity(
        allocator: std.mem.Allocator,
        db_path: []const u8,
        fault: StoreFault,
        identity: RuntimeIdentity,
    ) StoreError!Self {
        return initInternal(allocator, db_path, fault, identity);
    }

    fn initInternal(
        allocator: std.mem.Allocator,
        db_path: []const u8,
        fault: StoreFault,
        runtime_identity: ?RuntimeIdentity,
    ) StoreError!Self {
        const path = try allocator.dupeZ(u8, db_path);
        errdefer allocator.free(path);

        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        const conn = zqlite.open(path, flags) catch |err| return mapOpenError(err);
        errdefer conn.close();

        conn.busyTimeout(schema.BUSY_TIMEOUT_MS) catch |err| return mapOpenError(err);
        if (runtime_identity) |identity| {
            schema.initializeStoreWithRuntimeIdentity(conn, identity) catch |err| return mapOpenError(err);
        } else {
            schema.initializeToVersion(conn, schema.MAX_SUPPORTED_VERSION) catch |err| return mapOpenError(err);
        }
        access_store.initialize(conn) catch |err| return mapOpenError(err);
        if (runtime_identity) |identity| {
            connect_store.initialize(conn, identity.runtime_id, identity.instance_id) catch |err|
                return mapOpenError(err);
        }
        const migrated_fingerprint_bytes = migrateLegacyFingerprints(allocator, conn) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return mapOpenError(err);
        };
        compactFreedPages(conn, COMPACTION_MIN_FREE_BYTES) catch |err| {
            // Fingerprint conversion is already durable. A failed VACUUM only
            // postpones disk reclamation and must not make the store unusable.
            log.warn("database compaction deferred after fingerprint migration: {s}", .{@errorName(err)});
        };
        if (migrated_fingerprint_bytes > 0) {
            log.info("migrated legacy store fingerprints bytes={d}", .{migrated_fingerprint_bytes});
        }
        // Terminal turn identity outlives workspace retention ownership. This
        // ledger is intentionally independent from `chat_turns`, whose rows
        // may be tombstoned by an observed snapshot deletion.
        conn.execNoArgs(
            \\create table if not exists terminal_turn_replay_guard (
            \\    turn_id text primary key,
            \\    status text not null
            \\);
        ) catch |err| return mapOpenError(err);
        conn.execNoArgs(
            \\insert or ignore into terminal_turn_replay_guard (turn_id, status)
            \\select turn_id, status from chat_turns
            \\where status in ('completed', 'failed', 'aborted');
        ) catch |err| return mapOpenError(err);

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
        switch (mutation) {
            .snapshot_replace => |request| self.guardSnapshotTransaction(request, current_revision) catch |err|
                return mapStoreError(err),
            else => {},
        }

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
            .snapshot_replace => |request| if (request.bootstrap)
                self.applySnapshotFullRewrite(request.snapshot, next_revision_sql) catch |err| return mapStoreError(err)
            else
                self.applySnapshot(request.snapshot, next_revision_sql) catch |err| return mapStoreError(err),
            .workspace_upsert => |request| self.applyWorkspace(request.workspace) catch |err| return mapStoreError(err),
            .workspace_repository_upsert => |request| self.applyWorkspaceRepositoryUpsert(request) catch |err| return mapStoreError(err),
            .workspace_repository_remove => |request| self.applyWorkspaceRepositoryRemove(request) catch |err| return mapStoreError(err),
            .workspace_default_repository_set => |request| self.applyWorkspaceDefaultRepositorySet(request) catch |err| return mapStoreError(err),
            .workspace_repository_binding_upsert => |request| self.applyWorkspaceRepositoryBindingUpsert(request) catch |err| return mapStoreError(err),
            .workspace_repository_binding_remove => |request| self.applyWorkspaceRepositoryBindingRemove(request) catch |err| return mapStoreError(err),
            .thread_upsert => |request| self.applyThread(request) catch |err| return mapStoreError(err),
            .chat_draft_set => |request| self.applyChatDraftSet(request) catch |err| return mapStoreError(err),
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
        // Post-commit boundary: the transaction is durable above this line, so
        // the journal hook can only ever observe committed revisions (the M3
        // "no event before commit" invariant extended to journal entries).
        // Replay and message-key duplicate paths return earlier and never
        // reach this hook: no new revision, no journal entry.
        if (self.commit_hook) |hook| hook.on_mutation_committed(hook.context, &mutation, result);
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

    /// Create or update stable repository metadata without replacing bindings.
    pub fn upsertWorkspaceRepository(
        self: *Self,
        request: WorkspaceRepositoryUpsertRequest,
    ) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_repository_upsert = request });
    }

    /// Remove one repository reference and its bindings. No filesystem path is touched.
    pub fn removeWorkspaceRepository(
        self: *Self,
        request: WorkspaceRepositoryRemoveRequest,
    ) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_repository_remove = request });
    }

    /// Select an existing repository as the workspace default.
    pub fn setWorkspaceDefaultRepository(
        self: *Self,
        request: WorkspaceDefaultRepositorySetRequest,
    ) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_default_repository_set = request });
    }

    /// Create or update an absolute checkout root for one canonical runtime ID.
    pub fn upsertWorkspaceRepositoryBinding(
        self: *Self,
        request: WorkspaceRepositoryBindingUpsertRequest,
    ) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_repository_binding_upsert = request });
    }

    /// Remove only the runtime-local checkout reference. Checkout data is never deleted.
    pub fn removeWorkspaceRepositoryBinding(
        self: *Self,
        request: WorkspaceRepositoryBindingRemoveRequest,
    ) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .workspace_repository_binding_remove = request });
    }

    /// Load one bounded, allocator-owned manifest from a consistent SQLite snapshot.
    pub fn loadWorkspaceRepositoryManifest(
        self: *Self,
        workspace_id: []const u8,
    ) StoreError!OwnedWorkspaceRepositoryManifest {
        if (!validWorkspaceId(workspace_id)) return error.InvalidParams;

        self.conn.execNoArgs("begin") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        const header = blk: {
            const workspace_row = (self.conn.row(
                "select id, workspace_id, default_repository_id from workspaces where workspace_id = ?1",
                .{workspace_id},
            ) catch |err| return mapStoreError(err)) orelse return error.ResourceNotFound;
            defer workspace_row.deinit();
            const owned_workspace_id = self.allocator.dupe(u8, workspace_row.text(1)) catch return error.OutOfMemory;
            errdefer self.allocator.free(owned_workspace_id);
            const default_repository_id = self.allocator.dupe(u8, workspace_row.text(2)) catch return error.OutOfMemory;
            break :blk .{
                .workspace_row_id = workspace_row.int(0),
                .workspace_id = owned_workspace_id,
                .default_repository_id = default_repository_id,
            };
        };
        const owned_workspace_id = header.workspace_id;
        errdefer self.allocator.free(owned_workspace_id);
        const default_repository_id = header.default_repository_id;
        errdefer self.allocator.free(default_repository_id);
        var repositories: std.ArrayListUnmanaged(store_protocol.Repository) = .empty;
        errdefer {
            for (repositories.items) |repository| freeOwnedRepository(self.allocator, repository);
            repositories.deinit(self.allocator);
        }
        var found_primary = false;
        var found_default = false;
        {
            var rows = self.conn.rows(
                "select id, repository_id, label, vcs_identity, default_branch " ++
                    "from workspace_repositories where workspace_id = ?1 order by sort_index, repository_id",
                .{header.workspace_row_id},
            ) catch |err| return mapStoreError(err);
            defer rows.deinit();
            while (rows.next()) |row| {
                if (repositories.items.len >= MAX_WORKSPACE_REPOSITORIES) return error.StoreCorrupt;
                const definition: RepositoryDefinition = .{
                    .repository_id = row.text(1),
                    .label = row.text(2),
                    .vcs_identity = row.nullableText(3),
                    .default_branch = row.nullableText(4),
                };
                if (!repositoryDefinitionValid(definition)) return error.StoreCorrupt;
                const repository = self.copyStoredRepository(row.int(0), definition) catch |err| return mapStoreError(err);
                errdefer freeOwnedRepository(self.allocator, repository);
                found_primary = found_primary or std.mem.eql(u8, definition.repository_id, store_protocol.PRIMARY_REPOSITORY_ID);
                found_default = found_default or std.mem.eql(u8, definition.repository_id, default_repository_id);
                repositories.append(self.allocator, repository) catch return error.OutOfMemory;
            }
            if (rows.err) |err| return mapStoreError(err);
        }
        if (!found_primary or !found_default) return error.StoreCorrupt;

        const owned_repositories = repositories.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        errdefer {
            for (owned_repositories) |repository| freeOwnedRepository(self.allocator, repository);
            self.allocator.free(owned_repositories);
        }
        self.conn.commit() catch |err| return mapStoreError(err);
        transaction_open = false;
        return .{
            .workspace_id = owned_workspace_id,
            .default_repository_id = default_repository_id,
            .repositories = owned_repositories,
        };
    }

    /// Load one exact runtime binding. Callers must match `runtime_id` to the
    /// authenticated daemon identity and resolve any relative cwd beneath the
    /// returned root with filesystem-aware symlink containment checks.
    pub fn loadWorkspaceRepositoryBinding(
        self: *Self,
        workspace_id: []const u8,
        repository_id: []const u8,
        runtime_id: []const u8,
    ) StoreError!OwnedWorkspaceRepositoryBinding {
        if (!validWorkspaceId(workspace_id) or !validRouteId(repository_id) or !validRuntimeId(runtime_id)) {
            return error.InvalidParams;
        }
        const row = (self.conn.row(
            \\select workspace.workspace_id, repository.repository_id,
            \\       binding.runtime_id, binding.root_path, binding.availability
            \\from workspaces workspace
            \\join workspace_repositories repository on repository.workspace_id = workspace.id
            \\join workspace_repository_bindings binding on binding.repository_row_id = repository.id
            \\where workspace.workspace_id = ?1 and repository.repository_id = ?2 and binding.runtime_id = ?3
        , .{ workspace_id, repository_id, runtime_id }) catch |err| return mapStoreError(err)) orelse
            return error.ResourceNotFound;
        defer row.deinit();
        const binding: store_protocol.RepositoryBinding = .{
            .runtime_id = row.text(2),
            .root_path = row.text(3),
            .availability = row.text(4),
        };
        if (!repositoryBindingValid(binding)) return error.StoreCorrupt;

        const owned_workspace_id = self.allocator.dupe(u8, row.text(0)) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_workspace_id);
        const owned_repository_id = self.allocator.dupe(u8, row.text(1)) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_repository_id);
        const owned_runtime_id = self.allocator.dupe(u8, binding.runtime_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_runtime_id);
        const root_path = self.allocator.dupe(u8, binding.root_path) catch return error.OutOfMemory;
        errdefer self.allocator.free(root_path);
        const availability = self.allocator.dupe(u8, binding.availability) catch return error.OutOfMemory;
        return .{
            .workspace_id = owned_workspace_id,
            .repository_id = owned_repository_id,
            .runtime_id = owned_runtime_id,
            .root_path = root_path,
            .availability = availability,
        };
    }

    fn copyStoredRepository(
        self: *Self,
        repository_row_id: i64,
        definition: RepositoryDefinition,
    ) !store_protocol.Repository {
        const repository_id = try self.allocator.dupe(u8, definition.repository_id);
        errdefer self.allocator.free(repository_id);
        const label = try self.allocator.dupe(u8, definition.label);
        errdefer self.allocator.free(label);
        const vcs_identity = try dupeNullableText(self.allocator, definition.vcs_identity);
        errdefer if (vcs_identity) |value| self.allocator.free(value);
        const default_branch = try dupeNullableText(self.allocator, definition.default_branch);
        errdefer if (default_branch) |value| self.allocator.free(value);

        var bindings: std.ArrayListUnmanaged(store_protocol.RepositoryBinding) = .empty;
        errdefer {
            for (bindings.items) |binding| freeOwnedRepositoryBinding(self.allocator, binding);
            bindings.deinit(self.allocator);
        }
        var rows = try self.conn.rows(
            "select runtime_id, root_path, availability from workspace_repository_bindings " ++
                "where repository_row_id = ?1 order by runtime_id",
            .{repository_row_id},
        );
        defer rows.deinit();
        while (rows.next()) |row| {
            if (bindings.items.len >= MAX_REPOSITORY_BINDINGS) return error.StoreCorrupt;
            const binding: store_protocol.RepositoryBinding = .{
                .runtime_id = row.text(0),
                .root_path = row.text(1),
                .availability = row.text(2),
            };
            if (!repositoryBindingValid(binding)) return error.StoreCorrupt;
            const owned_binding = try copyRepositoryBinding(self.allocator, binding);
            errdefer freeOwnedRepositoryBinding(self.allocator, owned_binding);
            try bindings.append(self.allocator, owned_binding);
        }
        if (rows.err) |err| return err;
        return .{
            .repository_id = repository_id,
            .label = label,
            .vcs_identity = vcs_identity,
            .default_branch = default_branch,
            .bindings = try bindings.toOwnedSlice(self.allocator),
        };
    }

    pub fn upsertThread(self: *Self, request: store_protocol.ThreadUpsertRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .thread_upsert = request });
    }

    pub fn setChatDraft(self: *Self, request: store_protocol.ChatDraftSetRequest) StoreError!store_protocol.WriteResult {
        return self.applyMutation(.{ .chat_draft_set = request });
    }

    fn guardSnapshotTransaction(
        self: *Self,
        request: store_protocol.SnapshotReplaceRequest,
        current_revision: u64,
    ) !void {
        if (request.bootstrap) {
            // Bootstrap is a one-time import capability, not an unguarded
            // replacement mode. A replay with the same request key returned
            // above; every fresh bootstrap must find a pristine store.
            if (current_revision != 0 or try self.hasBootstrapOwnedState()) {
                return error.Conflict;
            }
        }

        // Legacy all-null committed rows may predate stable thread identity.
        // Any explicit route is different: deleting an unaddressable row in
        // reconcile would silently erase its immutable remote destination.
        const unaddressable = try self.conn.row(
            \\select 1 from threads
            \\where committed != 0
            \\  and (local_thread_id is null or local_thread_id = '')
            \\  and not (
            \\      profile_id is null and runtime_id is null and
            \\      repository_id is null and repository_cwd is null
            \\  )
            \\limit 1
        , .{});
        if (unaddressable) |row| {
            row.deinit();
            return error.InvalidParams;
        }
    }

    fn hasBootstrapOwnedState(self: *Self) !bool {
        const row = (try self.conn.row(
            \\select
            \\    exists(select 1 from app_state)
            \\ or exists(select 1 from workspaces)
            \\ or exists(select 1 from threads)
            \\ or exists(select 1 from messages)
            \\ or exists(select 1 from surface_completions)
            \\ or exists(select 1 from chat_completions)
            \\ or exists(select 1 from store_receipts)
            \\ or exists(select 1 from client_message_keys)
            \\ or exists(select 1 from workspace_leases)
            \\ or exists(select 1 from terminal_process_outcomes)
            \\ or exists(select 1 from chat_turns)
            \\ or exists(select 1 from terminal_turn_replay_guard)
        , .{})) orelse return error.StoreCorrupt;
        defer row.deinit();
        return row.int(0) != 0;
    }

    /// Accept a chat turn under one receipt-backed SQLite transaction. The
    /// receipt check intentionally precedes owner repair so replay is inert.
    pub fn acceptTurn(self: *Self, request: TurnAcceptanceRequest) StoreError!store_protocol.WriteResult {
        try validateTurnAcceptance(request);
        const user_attachment = try firstAttachment(request.user_message.image, request.user_message.images);
        const fingerprint = self.fingerprintValue(.{
            .turn_id = request.turn_id,
            .workspace_id = request.workspace.workspace_id,
            .local_thread_id = request.thread.local_thread_id,
            .provider = request.provider,
            .harness = request.harness,
            .provider_thread_id = request.provider_thread_id,
            // Acceptance replay may legitimately carry new wall-clock
            // timestamps, but it must never run a provider with content that
            // differs from the durable first writer.
            .user_message = .{
                .message_id = request.user_message.message_id,
                .role = request.user_message.role,
                .author = request.user_message.author,
                .body = request.user_message.body,
                .attachment = user_attachment,
            },
        }) catch |err| return err;
        defer self.allocator.free(fingerprint);

        self.conn.execNoArgs("begin immediate") catch |err| return mapStoreError(err);
        var transaction_open = true;
        defer if (transaction_open) self.conn.rollback();

        if (self.acceptance_test_hold) |hold| {
            hold.acquired.store(true, .release);
            while (!hold.release.load(.acquire)) std.atomic.spinLoopHint();
        }

        const prior_receipt = self.receiptFor(request.mutation, TURN_ACCEPT_OPERATION, fingerprint) catch |err| return mapStoreError(err);
        if (prior_receipt) |result| {
            self.conn.rollback();
            transaction_open = false;
            return .{ .store_revision = result.store_revision, .applied = false, .duplicate = true };
        }

        const current_revision = self.readStoreRevision() catch |err| return mapStoreError(err);
        if (request.mutation.expected_store_revision) |expected| {
            if (expected != current_revision) return error.Conflict;
        }
        const next_revision = std.math.add(u64, current_revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;

        const legacy_staged = self.isLegacyStagedAcceptance(request) catch |err| return mapStoreError(err);

        const inserted: TurnOwnerInsertions = .{
            .workspace = self.insertChatTurnWorkspaceIfMissing(request.workspace) catch |err| return mapStoreError(err),
            .thread = self.insertChatTurnThreadIfMissing(request.workspace.workspace_id, request.thread) catch |err| return mapStoreError(err),
        };
        self.updateTurnPresentationMetadata(
            request.workspace.workspace_id,
            request.thread,
        ) catch |err| return mapStoreError(err);
        self.updateTurnExecutionSettings(
            request.workspace.workspace_id,
            request.thread,
        ) catch |err| return mapStoreError(err);
        self.updateTurnProviderIdentity(
            request.workspace.workspace_id,
            request.thread.local_thread_id,
            request.provider,
            request.harness,
            request.provider_thread_id,
        ) catch |err| return mapStoreError(err);
        if (!legacy_staged) {
            self.applyMessageAppend(.{
                .mutation = request.mutation,
                .workspace_id = request.workspace.workspace_id,
                .thread_id = request.thread.local_thread_id,
                .message = request.user_message,
            }, next_revision_sql) catch |err| return mapStoreError(err);
        }
        self.insertTurnLedger(.{
            .turn_id = request.turn_id,
            .workspace_id = request.workspace.workspace_id,
            .local_thread_id = request.thread.local_thread_id,
            .status = .running,
            .started_at_ms = request.started_at_ms,
            .provider = request.provider,
            .harness = request.harness,
            .provider_thread_id = request.provider_thread_id,
            .user_message_id = request.user_message.message_id,
        }, next_revision_sql) catch |err| return mapStoreError(err);
        if (self.acceptance_test_fail_before_revision) return error.Internal;
        self.conn.exec("update store_state set store_revision = ?1 where id = 1", .{next_revision_sql}) catch |err| return mapStoreError(err);
        const result: store_protocol.WriteResult = .{ .store_revision = next_revision, .applied = true, .duplicate = false };
        self.insertReceipt(request.mutation, TURN_ACCEPT_OPERATION, fingerprint, result) catch |err| return mapStoreError(err);
        try self.commitWithFault();
        transaction_open = false;
        if (self.commit_hook) |hook| hook.on_acceptance_committed(hook.context, &request, inserted, result);
        return result;
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
        const fingerprint = self.fingerprintValue(.{
            .turn_id = request.turn_id,
            .workspace_id = request.workspace_id,
            .local_thread_id = request.local_thread_id,
            .status = request.status,
            .started_at_ms = request.started_at_ms,
            .finished_at_ms = request.finished_at_ms,
            .provider = request.provider,
            .harness = request.harness,
            .provider_thread_id = request.provider_thread_id,
            .expected_thread_title = request.expected_thread_title,
            .generated_title = request.generated_title,
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
            return .{
                .store_revision = result.store_revision,
                .applied = false,
                .duplicate = true,
            };
        }

        const current_revision = self.readStoreRevision() catch |err| return mapStoreError(err);
        const next_revision = std.math.add(u64, current_revision, 1) catch return error.StoreUnavailable;
        const next_revision_sql: i64 = std.math.cast(i64, next_revision) orelse return error.StoreUnavailable;

        // Self-healing owner creation belongs inside this receipt-backed
        // transaction. A replay above cannot resurrect a deleted owner.
        var inserted: TurnOwnerInsertions = .{};
        if (request.workspace) |workspace| {
            inserted.workspace = self.insertChatTurnWorkspaceIfMissing(workspace) catch |err| return mapStoreError(err);
        }
        if (request.thread) |thread| {
            inserted.thread = self.insertChatTurnThreadIfMissing(request.workspace_id, thread) catch |err| return mapStoreError(err);
            self.updateTurnPresentationMetadata(request.workspace_id, thread) catch |err| return mapStoreError(err);
            self.updateTurnExecutionSettings(request.workspace_id, thread) catch |err| return mapStoreError(err);
        }
        if (request.generated_title) |generated_title| {
            self.applyGeneratedTurnTitle(
                request.workspace_id,
                request.local_thread_id,
                request.expected_thread_title.?,
                generated_title,
            ) catch |err| return mapStoreError(err);
        }
        // Provider identity is turn-owned. Assign all three columns including
        // null provider_thread_id so a provider switch clears stale identity.
        self.updateTurnProviderIdentity(
            request.workspace_id,
            request.local_thread_id,
            request.provider,
            request.harness,
            request.provider_thread_id,
        ) catch |err| return mapStoreError(err);
        self.insertTurnMessages(request, next_revision_sql) catch |err| return mapStoreError(err);
        self.insertTurnLedger(request, next_revision_sql) catch |err| return mapStoreError(err);
        self.insertTerminalTurnReplayGuard(request) catch |err| return mapStoreError(err);
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
        // Post-commit boundary (A2): turn commits are store commits and fire
        // the same hook. A replayed duplicate turn receipt returned above
        // without committing, so it can never append a second journal entry.
        if (self.commit_hook) |hook| hook.on_turn_committed(hook.context, &request, inserted, result);
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

    const LegacyReceipt = struct {
        store_revision: u64,
    };

    /// Read one pre-atomic-acceptance receipt as compatibility evidence. Unlike
    /// ordinary replay, every malformed or semantically impossible legacy row
    /// is a compatibility mismatch; SQLite access failures still propagate.
    fn legacyReceiptFor(
        self: *const Self,
        mutation: store_protocol.MutationHeader,
        operation: []const u8,
        fingerprint: []const u8,
    ) !?LegacyReceipt {
        const row = (try self.conn.row(
            "select operation, fingerprint, store_revision, response_status, response_payload from store_receipts where request_key = ?1",
            .{mutation.request_key},
        )) orelse return null;
        defer row.deinit();

        if (!std.mem.eql(u8, row.text(0), operation) or !std.mem.eql(u8, row.text(1), fingerprint)) {
            return error.Conflict;
        }
        const revision_sql = row.int(2);
        if (revision_sql < 0 or row.int(3) != RESPONSE_STATUS_OK) return error.Conflict;
        const response_payload = row.nullableText(4) orelse return error.Conflict;
        const result = store_protocol.decodeLeaky(store_protocol.WriteResult, self.allocator, response_payload) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.Conflict;
        };
        const store_revision: u64 = @intCast(revision_sql);
        if (result.store_revision != store_revision or !result.applied or result.duplicate) return error.Conflict;
        return .{ .store_revision = store_revision };
    }

    fn insertReceipt(
        self: *Self,
        mutation: store_protocol.MutationHeader,
        operation: []const u8,
        fingerprint: []const u8,
        result: store_protocol.WriteResult,
    ) !void {
        // Durable WriteResult JSON for exact receipt replay (B4). This remains
        // the response body; only request fingerprints are reduced to digests.
        const response_payload = self.encodeValue(result) catch |err| return err;
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
        const fingerprint = self.fingerprintValue(message) catch |err| return err;
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
            .snapshot_replace => |request| self.fingerprintValue(.{
                .snapshot = request.snapshot,
                .bootstrap = request.bootstrap,
            }),
            .workspace_upsert => |request| self.fingerprintValue(request.workspace),
            .workspace_repository_upsert => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .repository = request.repository,
            }),
            .workspace_repository_remove => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .repository_id = request.repository_id,
            }),
            .workspace_default_repository_set => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .repository_id = request.repository_id,
            }),
            .workspace_repository_binding_upsert => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .repository_id = request.repository_id,
                .binding = request.binding,
            }),
            .workspace_repository_binding_remove => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .repository_id = request.repository_id,
                .runtime_id = request.runtime_id,
            }),
            .thread_upsert => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .thread = request.thread,
            }),
            .chat_draft_set => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .local_thread_id = request.local_thread_id,
                .text = request.text,
                .append = request.append,
            }),
            .message_append => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .thread_id = request.thread_id,
                .message = request.message,
            }),
            .surface_upsert => |request| self.fingerprintValue(request.surface),
            .surface_clear => |request| self.fingerprintValue(.{
                .session_id = request.session_id,
                .workspace_id = request.workspace_id,
            }),
            .chat_completion_upsert => |request| self.fingerprintValue(request.completion),
            .chat_completion_clear => |request| self.fingerprintValue(.{
                .workspace_id = request.workspace_id,
                .local_thread_id = request.local_thread_id,
                .completed_at_ms = request.completed_at_ms,
            }),
        };
    }

    fn fingerprintValue(self: *const Self, value: anytype) StoreError![]u8 {
        const encoded = try self.encodeValue(value);
        defer self.allocator.free(encoded);
        const fingerprint = fingerprintBytes(encoded);
        return self.allocator.dupe(u8, &fingerprint) catch error.OutOfMemory;
    }

    fn encodeValue(self: *const Self, value: anytype) StoreError![]u8 {
        return store_protocol.encode(self.allocator, value) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.Internal;
        };
    }

    /// Reconcile a normal GUI snapshot without rewriting paged-out transcript
    /// history. Snapshot metadata is authoritative at its observed revision,
    /// while loaded message tails replace only their declared sort-index
    /// ranges. Daemon-owned rows absent from a tail are moved aside by row id
    /// and appended after the replacement, so preserving them never copies
    /// their potentially multi-megabyte bodies through SQLite's WAL.
    fn applySnapshot(self: *Self, snapshot: store_protocol.Snapshot, store_revision: i64) !void {
        if (snapshot.schema_version != 1) return error.InvalidParams;

        try self.prepareSnapshotTargets(snapshot);
        try self.conn.exec(
            "insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, ?1, ?2) " ++
                "on conflict(id) do update set selected_workspace_index = excluded.selected_workspace_index, sidebar_collapsed = excluded.sidebar_collapsed",
            .{ @as(i64, @intCast(snapshot.selected_workspace_index)), boolToInt(snapshot.sidebar_collapsed) },
        );

        // An omitted workspace is a deliberate deletion once the GUI has
        // observed every committed turn which refers to it. A newer daemon
        // turn keeps the existing rows in place until a later projection.
        try self.conn.exec(
            \\delete from chat_turns
            \\where committed_store_revision is not null
            \\  and committed_store_revision <= ?1
            \\  and not exists (
            \\      select 1 from temp.snapshot_workspace_targets target
            \\      where target.workspace_id = chat_turns.workspace_id
            \\  )
        , .{@as(i64, @intCast(snapshot.store_revision))});
        try self.conn.exec(
            \\delete from workspaces
            \\where not exists (
            \\        select 1 from temp.snapshot_workspace_targets target
            \\        where target.workspace_id = workspaces.workspace_id
            \\    )
            \\  and not exists (
            \\        select 1 from chat_turns turn
            \\        where turn.workspace_id = workspaces.workspace_id
            \\          and turn.committed_store_revision is not null
            \\          and turn.committed_store_revision > ?1
            \\    )
        , .{@as(i64, @intCast(snapshot.store_revision))});
        try self.conn.execNoArgs(
            \\delete from chat_completions
            \\where not exists (
            \\    select 1 from workspaces where workspaces.workspace_id = chat_completions.workspace_id
            \\);
        );

        // Move existing order values out of the non-negative target range.
        // Retained, omitted workspaces receive deterministic positions after
        // every workspace carried by this snapshot.
        try self.conn.exec(
            \\insert into snapshot_workspace_positions (workspace_row_id, sort_index)
            \\select w.id, ?1 + row_number() over (order by w.sort_index) - 1
            \\from workspaces w
            \\where not exists (
            \\    select 1 from snapshot_workspace_targets target
            \\    where target.workspace_id = w.workspace_id
            \\)
        , .{@as(i64, @intCast(snapshot.workspaces.len))});
        try self.conn.execNoArgs("update workspaces set sort_index = -id");

        for (snapshot.workspaces, 0..) |workspace, workspace_index| {
            try self.upsertSnapshotWorkspace(workspace, workspace_index);
            const workspace_row = (try self.conn.row(
                "select id from workspaces where workspace_id = ?1",
                .{workspace.workspace_id},
            )) orelse return error.StoreCorrupt;
            const workspace_row_id = workspace_row.int(0);
            workspace_row.deinit();
            try self.reconcileSnapshotThreads(snapshot, workspace, workspace_index == 0, workspace_row_id, store_revision);
            try self.reconcileWorkspaceRepositories(workspace_row_id, workspace);
        }

        try self.conn.execNoArgs(
            \\update workspaces
            \\set sort_index = (
            \\    select position.sort_index from snapshot_workspace_positions position
            \\    where position.workspace_row_id = workspaces.id
            \\)
            \\where exists (
            \\    select 1 from snapshot_workspace_positions position
            \\    where position.workspace_row_id = workspaces.id
            \\);
        );
        for (snapshot.surface_states) |surface| try self.applySurfaceUpsert(surface);
        for (snapshot.chat_completions) |completion| try self.applyChatCompletionUpsert(completion);
    }

    fn prepareSnapshotTargets(self: *Self, snapshot: store_protocol.Snapshot) !void {
        try self.conn.execNoArgs(
            \\create temp table if not exists snapshot_workspace_targets (
            \\    workspace_id text primary key,
            \\    sort_index integer not null
            \\);
            \\create temp table if not exists snapshot_thread_targets (
            \\    workspace_id text not null,
            \\    local_thread_id text not null,
            \\    sort_index integer not null,
            \\    primary key (workspace_id, local_thread_id)
            \\);
            \\create temp table if not exists snapshot_workspace_positions (
            \\    workspace_row_id integer primary key,
            \\    sort_index integer not null
            \\);
            \\create temp table if not exists snapshot_thread_positions (
            \\    thread_row_id integer primary key,
            \\    sort_index integer not null
            \\);
            \\create temp table if not exists snapshot_message_positions (
            \\    message_row_id integer primary key,
            \\    original_sort_index integer not null
            \\);
            \\create temp table if not exists snapshot_message_restore_positions (
            \\    message_row_id integer primary key,
            \\    sort_index integer not null
            \\);
            \\delete from snapshot_workspace_targets;
            \\delete from snapshot_thread_targets;
            \\delete from snapshot_workspace_positions;
            \\delete from snapshot_thread_positions;
            \\delete from snapshot_message_positions;
            \\delete from snapshot_message_restore_positions;
        );
        for (snapshot.workspaces, 0..) |workspace, workspace_index| {
            if (workspace.workspace_id.len == 0 or workspace.label.len == 0 or workspace.path.len == 0) {
                return error.InvalidParams;
            }
            try self.conn.exec(
                "insert into snapshot_workspace_targets (workspace_id, sort_index) values (?1, ?2)",
                .{ workspace.workspace_id, @as(i64, @intCast(workspace_index)) },
            );
            for (workspace.threads, 0..) |thread, thread_index| {
                if (thread.local_thread_id.len == 0) continue;
                try self.conn.exec(
                    "insert into snapshot_thread_targets (workspace_id, local_thread_id, sort_index) values (?1, ?2, ?3)",
                    .{ workspace.workspace_id, thread.local_thread_id, @as(i64, @intCast(thread_index)) },
                );
            }
        }
    }

    fn upsertSnapshotWorkspace(self: *Self, workspace: store_protocol.Workspace, workspace_index: usize) !void {
        try self.conn.exec(
            "insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count, collapsed, thread_list_expanded, terminal_height, terminal_layout_json, terminal_docks_json, workspace_layout_json, selected_thread_index, companion_thread_local_id, herdr_remote_alias, herdr_session_name, herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id, herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json, herdr_updated_at_ms) " ++
                "values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24) " ++
                "on conflict(workspace_id) do update set sort_index = excluded.sort_index, label = excluded.label, path = excluded.path, archived = excluded.archived, unread_count = excluded.unread_count, collapsed = excluded.collapsed, thread_list_expanded = excluded.thread_list_expanded, terminal_height = excluded.terminal_height, terminal_layout_json = excluded.terminal_layout_json, terminal_docks_json = excluded.terminal_docks_json, workspace_layout_json = excluded.workspace_layout_json, selected_thread_index = excluded.selected_thread_index, companion_thread_local_id = excluded.companion_thread_local_id, herdr_remote_alias = excluded.herdr_remote_alias, herdr_session_name = excluded.herdr_session_name, herdr_workspace_id = excluded.herdr_workspace_id, herdr_local_dir = excluded.herdr_local_dir, herdr_remote_cwd = excluded.herdr_remote_cwd, herdr_last_pane_id = excluded.herdr_last_pane_id, herdr_attach_dock_id = excluded.herdr_attach_dock_id, herdr_attach_pane_id = excluded.herdr_attach_pane_id, herdr_pane_links_json = excluded.herdr_pane_links_json, herdr_updated_at_ms = excluded.herdr_updated_at_ms",
            workspaceValues(workspace, @as(i64, @intCast(workspace_index))),
        );
    }

    fn reconcileSnapshotThreads(
        self: *Self,
        snapshot: store_protocol.Snapshot,
        workspace: store_protocol.Workspace,
        is_first_workspace: bool,
        workspace_row_id: i64,
        store_revision: i64,
    ) !void {
        // Null-id rows are legacy compatibility rows and have no durable
        // identity. Stable omitted rows survive only when committed or owned
        // by a daemon turn; abandoned GUI drafts are deletions.
        try self.conn.exec("delete from threads where workspace_id = ?1 and local_thread_id is null", .{workspace_row_id});
        try self.conn.exec(
            \\delete from threads
            \\where workspace_id = ?1
            \\  and local_thread_id is not null
            \\  and not exists (
            \\      select 1 from snapshot_thread_targets target
            \\      where target.workspace_id = ?2 and target.local_thread_id = threads.local_thread_id
            \\  )
            \\  and committed = 0
            \\  and not exists (
            \\      select 1 from chat_turns turn
            \\      where turn.workspace_id = ?2 and turn.local_thread_id = threads.local_thread_id
            \\  )
        , .{ workspace_row_id, workspace.workspace_id });

        const snapshot_thread_count: usize = if (workspace.threads.len == 0) 1 else workspace.threads.len;
        try self.conn.exec(
            \\insert into snapshot_thread_positions (thread_row_id, sort_index)
            \\select t.id, ?3 + row_number() over (order by t.sort_index) - 1
            \\from threads t
            \\where t.workspace_id = ?1
            \\  and not exists (
            \\      select 1 from snapshot_thread_targets target
            \\      where target.workspace_id = ?2 and target.local_thread_id = t.local_thread_id
            \\  )
        , .{ workspace_row_id, workspace.workspace_id, @as(i64, @intCast(snapshot_thread_count)) });
        try self.conn.exec("update threads set sort_index = -id where workspace_id = ?1", .{workspace_row_id});

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
                0,
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
                0,
                legacy_messages,
                null,
                null,
                null,
                null,
                null,
                store_revision,
            );
        } else {
            for (workspace.threads, 0..) |thread, thread_index| {
                try self.reconcileSnapshotThread(workspace_row_id, thread, thread_index, store_revision);
            }
        }

        try self.conn.exec(
            \\update threads
            \\set sort_index = (
            \\    select position.sort_index from snapshot_thread_positions position
            \\    where position.thread_row_id = threads.id
            \\)
            \\where workspace_id = ?1 and exists (
            \\    select 1 from snapshot_thread_positions position
            \\    where position.thread_row_id = threads.id
            \\)
        , .{workspace_row_id});
    }

    fn reconcileSnapshotThread(
        self: *Self,
        workspace_row_id: i64,
        thread: store_protocol.Thread,
        thread_index: usize,
        store_revision: i64,
    ) !void {
        var existing_thread_id: ?i64 = null;
        if (thread.local_thread_id.len != 0) {
            const existing = try self.conn.row(
                "select id from threads where workspace_id = ?1 and local_thread_id = ?2",
                .{ workspace_row_id, thread.local_thread_id },
            );
            if (existing) |row| {
                existing_thread_id = row.int(0);
                row.deinit();
            }
        }
        if (existing_thread_id == null) {
            try self.insertThread(
                workspace_row_id,
                @as(i64, @intCast(thread_index)),
                thread.title,
                thread.archived,
                thread.committed,
                if (thread.local_thread_id.len == 0) null else thread.local_thread_id,
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
                thread.message_offset,
                thread.messages,
                thread.cwd,
                thread.profile_id,
                thread.runtime_id,
                thread.repository_id,
                thread.repository_cwd,
                store_revision,
            );
            return;
        }

        const thread_row_id = existing_thread_id.?;
        const provider_code = try providerCode(thread.provider);
        const harness_code = try harnessCode(thread.harness);
        const reasoning_code = if (thread.reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (thread.fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (thread.access_mode) |value| try accessModeCode(value) else null;
        const primary_draft_image = try firstAttachment(thread.draft_image, thread.draft_images);
        const draft_images_json = try encodeExtraImagesJson(self.allocator, thread.draft_images);
        defer if (draft_images_json) |value| self.allocator.free(value);
        try self.conn.exec(
            "update threads set sort_index = ?1, title = ?2, archived = ?3, committed = ?4, last_activity_at = ?5, provider_thread_id = ?6, model_ref = ?7, reasoning_effort = ?8, reasoning_variant = ?9, fast_mode = ?10, access_mode = ?11, provider = ?12, harness = ?13, tui_dock_id = ?14, draft = ?15, draft_image_path = ?16, draft_image_mime = ?17, draft_image_byte_size = ?18, draft_images_json = ?19, cwd = ?20, profile_id = ?21, runtime_id = ?22, repository_id = ?23, repository_cwd = ?24 where id = ?25",
            .{
                @as(i64, @intCast(thread_index)),
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
                draft_images_json,
                thread.cwd,
                thread.profile_id,
                thread.runtime_id,
                thread.repository_id,
                thread.repository_cwd,
                thread_row_id,
            },
        );
        try self.replaceSnapshotMessageTail(thread_row_id, thread.message_offset, thread.messages, store_revision);
    }

    fn replaceSnapshotMessageTail(
        self: *Self,
        thread_row_id: i64,
        message_offset: usize,
        messages: []const store_protocol.Message,
        store_revision: i64,
    ) !void {
        const offset: i64 = @intCast(message_offset);
        try self.conn.execNoArgs(
            \\delete from snapshot_message_positions;
            \\delete from snapshot_message_restore_positions;
        );
        try self.conn.exec(
            \\insert into snapshot_message_positions (message_row_id, original_sort_index)
            \\select m.id, m.sort_index
            \\from messages m
            \\where m.thread_id = ?1 and m.sort_index >= ?2 and m.message_id is not null and (
            \\    m.message_id like 'turn:%'
            \\    or m.message_id in (
            \\        select user_message_id from chat_turns
            \\        where user_message_id is not null and committed_store_revision is not null
            \\    )
            \\)
        , .{ thread_row_id, offset });
        try self.conn.execNoArgs(
            \\update messages
            \\set sort_index = -id
            \\where id in (select message_row_id from snapshot_message_positions);
        );
        try self.conn.exec(
            "delete from messages where thread_id = ?1 and sort_index >= ?2",
            .{ thread_row_id, offset },
        );

        for (messages, 0..) |message, message_index| {
            const sort_index = offset + @as(i64, @intCast(message_index));
            try self.insertMessage(thread_row_id, sort_index, message);
            if (message.message_id.len != 0) try self.insertMessageKey(thread_row_id, sort_index, message, store_revision);
        }

        const next_sort_row = (try self.conn.row(
            "select coalesce(max(sort_index) + 1, 0) from messages where thread_id = ?1 and sort_index >= 0",
            .{thread_row_id},
        )) orelse return error.StoreCorrupt;
        const next_sort = next_sort_row.int(0);
        next_sort_row.deinit();
        try self.conn.exec(
            \\insert into snapshot_message_restore_positions (message_row_id, sort_index)
            \\select position.message_row_id,
            \\       ?1 + row_number() over (order by position.original_sort_index) - 1
            \\from snapshot_message_positions position
            \\join messages m on m.id = position.message_row_id
            \\where m.sort_index < 0
        , .{next_sort});
        try self.conn.execNoArgs(
            \\update messages
            \\set sort_index = (
            \\    select position.sort_index from snapshot_message_restore_positions position
            \\    where position.message_row_id = messages.id
            \\)
            \\where id in (select message_row_id from snapshot_message_restore_positions);
        );
        try self.conn.exec(
            \\delete from client_message_keys
            \\where thread_id = ?1 and not exists (
            \\    select 1 from messages m
            \\    where m.thread_id = client_message_keys.thread_id
            \\      and m.message_id = client_message_keys.message_id
            \\)
        , .{thread_row_id});
        try self.conn.exec(
            \\update client_message_keys
            \\set sort_index = (
            \\    select m.sort_index from messages m
            \\    where m.thread_id = client_message_keys.thread_id
            \\      and m.message_id = client_message_keys.message_id
            \\)
            \\where thread_id = ?1
        , .{thread_row_id});
    }

    /// Identity-preserving full rewrite used only for one-time legacy import.
    ///
    /// The GUI snapshot is not the transcript authority anymore: rows the
    /// daemon committed (`turn:{id}:msg:{n}` plus ledger-referenced client
    /// user ids) and thread rows created daemon-side (MCP `chat.thread.upsert`
    /// / turn staging — their `local_thread_id` is public API since M4-P5)
    /// must survive a snapshot the GUI built before observing them. The wipe
    /// therefore stages those rows in temp tables first and re-homes any of
    /// them the snapshot did not carry, all inside applyMutation's single
    /// `begin immediate` transaction.
    fn applySnapshotFullRewrite(self: *Self, snapshot: store_protocol.Snapshot, store_revision: i64) !void {
        if (snapshot.schema_version != 1) return error.InvalidParams;

        // Stage the protected sets before the wipe. Thread scope: any thread
        // with a stable id that is committed or ledger-referenced — the GUI
        // never deliberately omits a committed thread from its snapshot (only
        // uncommitted trailing drafts / pristine legacy companions are ever
        // dropped), so an omitted committed thread is one the GUI has not
        // observed. Message scope: daemon-minted `turn:%` ids plus rows a
        // committed ledger entry references as its user row.
        //
        // The staging tables are created once per connection (`if not exists`)
        // and emptied per apply: repeated DROP/CREATE would be schema ops,
        // which SQLite refuses (SQLITE_LOCKED) while any statement on the
        // connection is unfinalized.
        try self.conn.execNoArgs(
            \\create temp table if not exists preserved_chat_threads (
            \\    workspace_key text not null,
            \\    sort_index integer not null,
            \\    title text not null,
            \\    archived integer not null,
            \\    committed integer not null,
            \\    local_thread_id text not null,
            \\    last_activity_at integer,
            \\    provider_thread_id text,
            \\    model_ref text,
            \\    reasoning_effort integer,
            \\    reasoning_variant text,
            \\    fast_mode integer,
            \\    access_mode integer,
            \\    provider integer not null,
            \\    harness integer not null,
            \\    tui_dock_id integer,
            \\    draft text not null,
            \\    draft_image_path text,
            \\    draft_image_mime text,
            \\    draft_image_byte_size integer,
            \\    draft_images_json text,
            \\    cwd text,
            \\    profile_id text,
            \\    runtime_id text,
            \\    repository_id text,
            \\    repository_cwd text
            \\);
            \\create temp table if not exists preserved_workspaces (
            \\    workspace_id text not null,
            \\    sort_index integer not null,
            \\    label text not null,
            \\    path text not null,
            \\    archived integer not null,
            \\    unread_count integer not null,
            \\    collapsed integer not null,
            \\    thread_list_expanded integer not null,
            \\    terminal_height real,
            \\    terminal_layout_json text,
            \\    terminal_docks_json text,
            \\    workspace_layout_json text,
            \\    selected_thread_index integer not null,
            \\    companion_thread_local_id text,
            \\    herdr_remote_alias text,
            \\    herdr_session_name text,
            \\    herdr_workspace_id text,
            \\    herdr_local_dir text,
            \\    herdr_remote_cwd text,
            \\    herdr_last_pane_id text,
            \\    herdr_attach_dock_id integer,
            \\    herdr_attach_pane_id integer,
            \\    herdr_pane_links_json text,
            \\    herdr_updated_at_ms integer
            \\);
            \\create temp table if not exists preserved_chat_messages (
            \\    workspace_key text not null,
            \\    thread_key text not null,
            \\    sort_index integer not null,
            \\    role integer not null,
            \\    author text not null,
            \\    body text not null,
            \\    image_path text,
            \\    image_mime text,
            \\    image_byte_size integer,
            \\    tool_call_id text,
            \\    tool_call_kind integer,
            \\    tool_call_status integer,
            \\    message_id text not null,
            \\    created_at_ms integer,
            \\    updated_at_ms integer,
            \\    key_fingerprint text,
            \\    key_created_at_ms integer,
            \\    key_updated_at_ms integer,
            \\    key_store_revision integer,
            \\    extra_images_json text
            \\);
            \\create temp table if not exists preserved_lazy_messages (
            \\    workspace_key text not null,
            \\    thread_key text not null,
            \\    sort_index integer not null,
            \\    role integer not null,
            \\    author text not null,
            \\    body text not null,
            \\    image_path text,
            \\    image_mime text,
            \\    image_byte_size integer,
            \\    tool_call_id text,
            \\    tool_call_kind integer,
            \\    tool_call_status integer,
            \\    message_id text,
            \\    created_at_ms integer,
            \\    updated_at_ms integer,
            \\    key_fingerprint text,
            \\    key_created_at_ms integer,
            \\    key_updated_at_ms integer,
            \\    key_store_revision integer,
            \\    extra_images_json text
            \\);
            \\delete from preserved_chat_threads;
            \\delete from preserved_chat_messages;
            \\delete from preserved_lazy_messages;
            \\delete from preserved_workspaces;
        );
        try self.conn.exec(
            \\insert into preserved_workspaces
            \\select w.workspace_id, w.sort_index, w.label, w.path, w.archived, w.unread_count,
            \\       w.collapsed, w.thread_list_expanded, w.terminal_height, w.terminal_layout_json,
            \\       w.terminal_docks_json, w.workspace_layout_json, w.selected_thread_index,
            \\       w.companion_thread_local_id, w.herdr_remote_alias, w.herdr_session_name,
            \\       w.herdr_workspace_id, w.herdr_local_dir, w.herdr_remote_cwd, w.herdr_last_pane_id,
            \\       w.herdr_attach_dock_id, w.herdr_attach_pane_id, w.herdr_pane_links_json,
            \\       w.herdr_updated_at_ms
            \\from workspaces w
            \\where exists (
            \\    select 1 from chat_turns ct
            \\    where ct.workspace_id = w.workspace_id
            \\      and ct.committed_store_revision > 0
            \\      and ct.committed_store_revision > ?1
            \\)
        , .{@as(i64, @intCast(snapshot.store_revision))});
        try self.conn.execNoArgs(
            \\insert into preserved_chat_threads
            \\select w.workspace_id, t.sort_index, t.title, t.archived, t.committed, t.local_thread_id,
            \\       t.last_activity_at, t.provider_thread_id, t.model_ref, t.reasoning_effort,
            \\       t.reasoning_variant, t.fast_mode, t.access_mode, t.provider, t.harness, t.tui_dock_id,
            \\       t.draft, t.draft_image_path, t.draft_image_mime, t.draft_image_byte_size,
            \\       t.draft_images_json, t.cwd, t.profile_id, t.runtime_id, t.repository_id, t.repository_cwd
            \\from threads t join workspaces w on w.id = t.workspace_id
            \\where t.local_thread_id is not null and (
            \\    t.committed != 0
            \\    or exists (
            \\        select 1 from chat_turns ct
            \\        where ct.workspace_id = w.workspace_id and ct.local_thread_id = t.local_thread_id
            \\    )
            \\);
            \\insert into preserved_chat_messages
            \\select w.workspace_id, t.local_thread_id, m.sort_index, m.role, m.author, m.body,
            \\       m.image_path, m.image_mime, m.image_byte_size,
            \\       m.tool_call_id, m.tool_call_kind, m.tool_call_status,
            \\       m.message_id, m.created_at_ms, m.updated_at_ms,
            \\       k.message_fingerprint, k.created_at_ms, k.updated_at_ms, k.store_revision,
            \\       m.extra_images_json
            \\from messages m
            \\join threads t on t.id = m.thread_id
            \\join workspaces w on w.id = t.workspace_id
            \\left join client_message_keys k on k.thread_id = m.thread_id and k.message_id = m.message_id
            \\where t.local_thread_id is not null and m.message_id is not null and (
            \\    m.message_id like 'turn:%'
            \\    or m.message_id in (
            \\        select user_message_id from chat_turns
            \\        where user_message_id is not null and committed_store_revision is not null
            \\    )
            \\);
        );

        // A bounded GUI projection explicitly declares how many older rows it
        // omitted. Preserve that exact prefix, including legacy null-id rows,
        // while the loaded tail is replaced at its original sort indexes.
        for (snapshot.workspaces) |workspace| {
            for (workspace.threads) |thread| {
                if (thread.message_offset == 0 or thread.local_thread_id.len == 0) continue;
                try self.conn.exec(
                    \\insert into preserved_lazy_messages
                    \\select w.workspace_id, t.local_thread_id, m.sort_index, m.role, m.author, m.body,
                    \\       m.image_path, m.image_mime, m.image_byte_size,
                    \\       m.tool_call_id, m.tool_call_kind, m.tool_call_status,
                    \\       m.message_id, m.created_at_ms, m.updated_at_ms,
                    \\       k.message_fingerprint, k.created_at_ms, k.updated_at_ms, k.store_revision,
                    \\       m.extra_images_json
                    \\from messages m
                    \\join threads t on t.id = m.thread_id
                    \\join workspaces w on w.id = t.workspace_id
                    \\left join client_message_keys k on k.thread_id = m.thread_id and k.message_id = m.message_id
                    \\where w.workspace_id = ?1 and t.local_thread_id = ?2 and m.sort_index < ?3
                , .{ workspace.workspace_id, thread.local_thread_id, @as(i64, @intCast(thread.message_offset)) });
            }
        }

        // Surface and chat completion rows stay out of the wipe: targeted
        // daemon mutations own both ledgers post-flip. Snapshot rows may merge
        // through upsert below, while omission from a GUI compatibility
        // snapshot must not erase a concurrent notification/session update.
        try self.conn.execNoArgs(
            \\delete from client_message_keys;
            \\delete from messages;
            \\delete from threads;
            \\delete from app_state;
            \\delete from workspaces;
        );
        try self.conn.exec(
            "insert into app_state (id, selected_workspace_index, sidebar_collapsed) values (1, ?1, ?2)",
            .{ @as(i64, @intCast(snapshot.selected_workspace_index)), boolToInt(snapshot.sidebar_collapsed) },
        );

        for (snapshot.workspaces, 0..) |workspace, workspace_index| {
            try self.insertWorkspaceAtRevision(workspace, workspace_index, snapshot, workspace_index == 0, store_revision);
        }
        for (snapshot.surface_states) |surface| try self.applySurfaceUpsert(surface);
        for (snapshot.chat_completions) |completion| try self.applyChatCompletionUpsert(completion);

        // Omitted workspaces whose retained turns were already within the
        // GUI's observed revision are deliberate deletions. Remove their
        // ledger ownership in this same guarded transaction so no future
        // snapshot can resurrect them. Newer, not-yet-observed turns were
        // staged above and remain protected until a later snapshot carries
        // their workspace.
        try self.conn.exec(
            \\delete from chat_turns
            \\where committed_store_revision is not null
            \\  and committed_store_revision <= ?1
            \\  and not exists (
            \\      select 1 from workspaces w where w.workspace_id = chat_turns.workspace_id
            \\  )
        , .{@as(i64, @intCast(snapshot.store_revision))});
        try self.conn.exec(
            \\delete from chat_completions
            \\where not exists (
            \\    select 1 from workspaces w where w.workspace_id = chat_completions.workspace_id
            \\)
        , .{});

        try self.restorePreservedChatRows();
        // Empty (never DROP — schema op) so stale copies of transcript rows
        // do not outlive the apply.
        try self.conn.execNoArgs(
            \\delete from preserved_chat_threads;
            \\delete from preserved_chat_messages;
            \\delete from preserved_lazy_messages;
            \\delete from preserved_workspaces;
        );
    }

    /// Re-home staged daemon-owned rows the snapshot did not carry.
    ///
    /// Scope rules: a workspace absent from the snapshot is normally a
    /// deliberate GUI-side project deletion — its threads and rows are not
    /// resurrected. M5-P4 Amendment 1 carves out one exception: a workspace
    /// holding a turn committed AFTER the snapshot's observed store revision
    /// is restored, because that daemon-owned content was not yet visible to
    /// the GUI. Historical committed turns are not preservation keys: an
    /// omission after their revision is a deliberate deletion and the ledger
    /// ownership is removed atomically in applySnapshot.
    /// A thread absent from the snapshot whose workspace survives is restored
    /// (the GUI cannot have observed it — see applySnapshot). A message id the
    /// snapshot already carries wins on position/content (M4-P3 parity makes
    /// content equal). Attachment fields are the exception: older GUI
    /// projections can carry the accepted row identity while omitting its
    /// daemon-owned images, so sparse attachment columns are enriched from
    /// the preserved row before missing identities are restored. Identity is
    /// what must never fork, so a second row for an existing
    /// (thread, message_id) is never inserted — pinned by the
    /// `messages_thread_message_id_idx` unique index as a hard belt.
    ///
    /// Sort-index coherence: restored rows append after the snapshot's rows
    /// (`max(sort_index) + 1` base plus a per-partition row_number offset, so
    /// the per-thread/per-workspace unique(sort_index) constraints cannot
    /// collide). Unobserved daemon rows are always newer than everything the
    /// GUI carried for that thread — sends are serialized per thread and the
    /// GUI observes a turn's rows before it can start the next one — so
    /// appending preserves transcript order, and the post-adoption flush
    /// carries every id and converges to exactly one copy per identity.
    fn restorePreservedChatRows(self: *Self) !void {
        // A GUI snapshot can learn the accepted user-row ID before it learns
        // the attachment payload. The snapshot copy wins for presentation
        // fields and ordering, but an omitted image is not a deletion: sent
        // transcript rows are immutable. Restore both the legacy primary and
        // additive extras before the identity guard below skips this row.
        try self.conn.execNoArgs(
            \\update messages as m
            \\set (image_path, image_mime, image_byte_size, extra_images_json) = (
            \\    select coalesce(m.image_path, p.image_path),
            \\           coalesce(m.image_mime, p.image_mime),
            \\           coalesce(m.image_byte_size, p.image_byte_size),
            \\           coalesce(m.extra_images_json, p.extra_images_json)
            \\    from temp.preserved_chat_messages p
            \\    join workspaces w on w.workspace_id = p.workspace_key
            \\    join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\    where m.thread_id = t.id and m.message_id = p.message_id
            \\)
            \\where exists (
            \\    select 1
            \\    from temp.preserved_chat_messages p
            \\    join workspaces w on w.workspace_id = p.workspace_key
            \\    join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\    where m.thread_id = t.id and m.message_id = p.message_id
            \\      and ((m.image_path is null and p.image_path is not null)
            \\        or (m.extra_images_json is null and p.extra_images_json is not null))
            \\);
        );
        // M5-P4 Amendment 1 workspace belt: re-home ledger-referenced
        // workspaces first so the thread/message restores below can join
        // them. Restored rows append after the snapshot's workspaces
        // (global unique sort_index, same max+row_number pattern as threads).
        try self.conn.execNoArgs(
            \\insert into workspaces (workspace_id, sort_index, label, path, archived, unread_count,
            \\                        collapsed, thread_list_expanded, terminal_height, terminal_layout_json,
            \\                        terminal_docks_json, workspace_layout_json, selected_thread_index,
            \\                        companion_thread_local_id, herdr_remote_alias, herdr_session_name,
            \\                        herdr_workspace_id, herdr_local_dir, herdr_remote_cwd, herdr_last_pane_id,
            \\                        herdr_attach_dock_id, herdr_attach_pane_id, herdr_pane_links_json,
            \\                        herdr_updated_at_ms)
            \\select p.workspace_id,
            \\       (select coalesce(max(w2.sort_index) + 1, 0) from workspaces w2)
            \\           + (row_number() over (order by p.sort_index) - 1),
            \\       p.label, p.path, p.archived, p.unread_count, p.collapsed, p.thread_list_expanded,
            \\       p.terminal_height, p.terminal_layout_json, p.terminal_docks_json,
            \\       p.workspace_layout_json, p.selected_thread_index, p.companion_thread_local_id,
            \\       p.herdr_remote_alias, p.herdr_session_name, p.herdr_workspace_id, p.herdr_local_dir,
            \\       p.herdr_remote_cwd, p.herdr_last_pane_id, p.herdr_attach_dock_id, p.herdr_attach_pane_id,
            \\       p.herdr_pane_links_json, p.herdr_updated_at_ms
            \\from temp.preserved_workspaces p
            \\where not exists (
            \\    select 1 from workspaces w3 where w3.workspace_id = p.workspace_id
            \\);
        );
        try self.conn.execNoArgs(
            \\insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime,
            \\                      image_byte_size, extra_images_json, tool_call_id, tool_call_kind, tool_call_status,
            \\                      message_id, created_at_ms, updated_at_ms)
            \\select t.id, p.sort_index, p.role, p.author, p.body, p.image_path, p.image_mime,
            \\       p.image_byte_size, p.extra_images_json, p.tool_call_id, p.tool_call_kind, p.tool_call_status,
            \\       p.message_id, p.created_at_ms, p.updated_at_ms
            \\from temp.preserved_lazy_messages p
            \\join workspaces w on w.workspace_id = p.workspace_key
            \\join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\where not exists (
            \\    select 1 from messages m3
            \\    where m3.thread_id = t.id and m3.sort_index = p.sort_index
            \\)
            \\-- Identity guard, not just position: a snapshot row can carry this
            \\-- message_id at a DIFFERENT sort_index (post-adoption reflow). The
            \\-- doc contract says the snapshot's copy wins; without this filter
            \\-- the messages_thread_message_id_idx belt aborts the whole apply as
            \\-- a constraint failure, permanently rejecting the GUI's flush.
            \\and (p.message_id is null or not exists (
            \\    select 1 from messages m4
            \\    where m4.thread_id = t.id and m4.message_id = p.message_id
            \\));
            \\insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index,
            \\                                 created_at_ms, updated_at_ms, store_revision)
            \\select t.id, p.message_id, p.key_fingerprint, p.sort_index,
            \\       p.key_created_at_ms, p.key_updated_at_ms, p.key_store_revision
            \\from temp.preserved_lazy_messages p
            \\join workspaces w on w.workspace_id = p.workspace_key
            \\join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\where p.message_id is not null and p.key_fingerprint is not null
            \\  and not exists (
            \\      select 1 from client_message_keys k2
            \\      where k2.thread_id = t.id and k2.message_id = p.message_id
            \\  );
        );
        try self.conn.execNoArgs(
            \\insert into threads (workspace_id, sort_index, title, archived, committed, local_thread_id,
            \\                     last_activity_at, provider_thread_id, model_ref, reasoning_effort,
            \\                     reasoning_variant, fast_mode, access_mode, provider, harness, tui_dock_id,
            \\                     draft, draft_image_path, draft_image_mime, draft_image_byte_size, draft_images_json, cwd,
            \\                     profile_id, runtime_id, repository_id, repository_cwd)
            \\select w.id,
            \\       (select coalesce(max(t2.sort_index) + 1, 0) from threads t2 where t2.workspace_id = w.id)
            \\           + (row_number() over (partition by p.workspace_key order by p.sort_index) - 1),
            \\       p.title, p.archived, p.committed, p.local_thread_id, p.last_activity_at,
            \\       p.provider_thread_id, p.model_ref, p.reasoning_effort, p.reasoning_variant,
            \\       p.fast_mode, p.access_mode, p.provider, p.harness, p.tui_dock_id,
            \\       p.draft, p.draft_image_path, p.draft_image_mime, p.draft_image_byte_size, p.draft_images_json, p.cwd,
            \\       p.profile_id, p.runtime_id, p.repository_id, p.repository_cwd
            \\from temp.preserved_chat_threads p
            \\join workspaces w on w.workspace_id = p.workspace_key
            \\where not exists (
            \\    select 1 from threads t3
            \\    where t3.workspace_id = w.id and t3.local_thread_id = p.local_thread_id
            \\);
        );
        try self.conn.execNoArgs(
            \\insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime,
            \\                      image_byte_size, extra_images_json, tool_call_id, tool_call_kind, tool_call_status,
            \\                      message_id, created_at_ms, updated_at_ms)
            \\select t.id,
            \\       (select coalesce(max(m2.sort_index) + 1, 0) from messages m2 where m2.thread_id = t.id)
            \\           + (row_number() over (partition by p.workspace_key, p.thread_key order by p.sort_index) - 1),
            \\       p.role, p.author, p.body, p.image_path, p.image_mime, p.image_byte_size,
            \\       p.extra_images_json, p.tool_call_id, p.tool_call_kind, p.tool_call_status,
            \\       p.message_id, p.created_at_ms, p.updated_at_ms
            \\from temp.preserved_chat_messages p
            \\join workspaces w on w.workspace_id = p.workspace_key
            \\join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\where not exists (
            \\    select 1 from messages m3
            \\    where m3.thread_id = t.id and m3.message_id = p.message_id
            \\);
        );
        // Keys of restored rows keep their original fingerprint/revision so a
        // later same-turn replay commit still resolves duplicate-by-identity
        // (the F1 user-row exception tolerates the fingerprint drift). Rows
        // the snapshot carried already re-wrote their key on insert.
        try self.conn.execNoArgs(
            \\insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index,
            \\                                 created_at_ms, updated_at_ms, store_revision)
            \\select t.id, p.message_id, p.key_fingerprint, m.sort_index,
            \\       p.key_created_at_ms, p.key_updated_at_ms, p.key_store_revision
            \\from temp.preserved_chat_messages p
            \\join workspaces w on w.workspace_id = p.workspace_key
            \\join threads t on t.workspace_id = w.id and t.local_thread_id = p.thread_key
            \\join messages m on m.thread_id = t.id and m.message_id = p.message_id
            \\where p.key_fingerprint is not null and not exists (
            \\    select 1 from client_message_keys k2
            \\    where k2.thread_id = t.id and k2.message_id = p.message_id
            \\);
        );
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
        const workspace_row_id = try self.requireWorkspaceRowId(workspace.workspace_id);
        try self.reconcileWorkspaceRepositories(workspace_row_id, workspace);
    }

    fn applyWorkspaceRepositoryUpsert(self: *Self, request: WorkspaceRepositoryUpsertRequest) !void {
        const workspace_row_id = try self.requireWorkspaceRowId(request.workspace_id);
        const existing = try self.conn.row(
            "select id from workspace_repositories where workspace_id = ?1 and repository_id = ?2",
            .{ workspace_row_id, request.repository.repository_id },
        );
        if (existing) |row| {
            row.deinit();
        } else {
            const count_row = (try self.conn.row(
                "select count(*) from workspace_repositories where workspace_id = ?1",
                .{workspace_row_id},
            )) orelse return error.StoreCorrupt;
            const repository_count = count_row.int(0);
            count_row.deinit();
            if (repository_count >= @as(i64, MAX_WORKSPACE_REPOSITORIES)) return error.CapabilityUnavailable;
        }
        try self.conn.exec(
            "insert into workspace_repositories (workspace_id, repository_id, sort_index, label, vcs_identity, default_branch) " ++
                "values (?1, ?2, coalesce((select max(sort_index) + 1 from workspace_repositories where workspace_id = ?1), 0), ?3, ?4, ?5) " ++
                "on conflict(workspace_id, repository_id) do update set label = excluded.label, " ++
                "vcs_identity = excluded.vcs_identity, default_branch = excluded.default_branch",
            .{
                workspace_row_id,
                request.repository.repository_id,
                request.repository.label,
                request.repository.vcs_identity,
                request.repository.default_branch,
            },
        );
    }

    fn applyWorkspaceRepositoryRemove(self: *Self, request: WorkspaceRepositoryRemoveRequest) !void {
        const workspace_row_id = try self.requireWorkspaceRowId(request.workspace_id);
        const repository_row = (try self.conn.row(
            "select id, repository_id = (select default_repository_id from workspaces where id = ?1) " ++
                "from workspace_repositories where workspace_id = ?1 and repository_id = ?2",
            .{ workspace_row_id, request.repository_id },
        )) orelse return error.ResourceNotFound;
        const repository_row_id = repository_row.int(0);
        const is_default = repository_row.int(1) != 0;
        repository_row.deinit();
        if (is_default) return error.Conflict;

        const referenced = (try self.conn.row(
            "select 1 from threads where workspace_id = ?1 and coalesce(repository_id, 'primary') = ?2 limit 1",
            .{ workspace_row_id, request.repository_id },
        ));
        if (referenced) |row| {
            row.deinit();
            return error.Conflict;
        }
        try self.conn.exec("delete from workspace_repositories where id = ?1", .{repository_row_id});
        if (self.conn.changes() == 0) return error.ResourceNotFound;
    }

    fn applyWorkspaceDefaultRepositorySet(self: *Self, request: WorkspaceDefaultRepositorySetRequest) !void {
        const workspace_row_id = try self.requireWorkspaceRowId(request.workspace_id);
        const repository = try self.conn.row(
            "select 1 from workspace_repositories where workspace_id = ?1 and repository_id = ?2",
            .{ workspace_row_id, request.repository_id },
        );
        if (repository) |row| {
            row.deinit();
        } else {
            return error.ResourceNotFound;
        }
        try self.conn.exec(
            "update workspaces set default_repository_id = ?1 where id = ?2",
            .{ request.repository_id, workspace_row_id },
        );
    }

    fn applyWorkspaceRepositoryBindingUpsert(
        self: *Self,
        request: WorkspaceRepositoryBindingUpsertRequest,
    ) !void {
        const workspace_row_id = try self.requireWorkspaceRowId(request.workspace_id);
        const repository_row_id = try self.requireRepositoryRowId(workspace_row_id, request.repository_id);
        const existing = try self.conn.row(
            "select 1 from workspace_repository_bindings where repository_row_id = ?1 and runtime_id = ?2",
            .{ repository_row_id, request.binding.runtime_id },
        );
        if (existing) |row| {
            row.deinit();
        } else {
            const count_row = (try self.conn.row(
                "select count(*) from workspace_repository_bindings where repository_row_id = ?1",
                .{repository_row_id},
            )) orelse return error.StoreCorrupt;
            const binding_count = count_row.int(0);
            count_row.deinit();
            if (binding_count >= @as(i64, MAX_REPOSITORY_BINDINGS)) return error.CapabilityUnavailable;
        }
        try self.upsertRepositoryBindingRow(repository_row_id, request.binding);
        if (std.mem.eql(u8, request.repository_id, store_protocol.PRIMARY_REPOSITORY_ID) and
            try self.isStoreRuntime(request.binding.runtime_id))
        {
            // The legacy workspace path remains the current runtime's primary
            // checkout projection. Updating it never performs filesystem I/O.
            try self.conn.exec(
                "update workspaces set path = ?1 where id = ?2",
                .{ request.binding.root_path, workspace_row_id },
            );
        }
    }

    fn applyWorkspaceRepositoryBindingRemove(
        self: *Self,
        request: WorkspaceRepositoryBindingRemoveRequest,
    ) !void {
        const workspace_row_id = try self.requireWorkspaceRowId(request.workspace_id);
        const repository_row_id = try self.requireRepositoryRowId(workspace_row_id, request.repository_id);
        try self.conn.exec(
            "delete from workspace_repository_bindings where repository_row_id = ?1 and runtime_id = ?2",
            .{ repository_row_id, request.runtime_id },
        );
        if (self.conn.changes() == 0) return error.ResourceNotFound;
    }

    fn reconcileWorkspaceRepositories(
        self: *Self,
        workspace_row_id: i64,
        workspace: store_protocol.Workspace,
    ) !void {
        // An empty list is the decode-compatible legacy shape. Preserve any
        // richer manifest already learned instead of letting an old client
        // erase it, while the v9 insert trigger guarantees stable `primary`.
        if (workspace.repositories.len == 0) {
            try self.ensureWorkspaceThreadRepositoriesExist(workspace_row_id);
            return;
        }

        try self.conn.execNoArgs(
            \\create temp table if not exists repository_manifest_targets (
            \\    repository_id text primary key
            \\);
            \\delete from repository_manifest_targets;
        );
        for (workspace.repositories) |repository| {
            try self.conn.exec(
                "insert into repository_manifest_targets (repository_id) values (?1)",
                .{repository.repository_id},
            );
        }

        const referenced_omission = try self.conn.row(
            \\select 1
            \\from workspace_repositories repository
            \\join threads thread on thread.workspace_id = repository.workspace_id
            \\where repository.workspace_id = ?1
            \\  and not exists (
            \\      select 1 from repository_manifest_targets target
            \\      where target.repository_id = repository.repository_id
            \\  )
            \\  and coalesce(thread.repository_id, 'primary') = repository.repository_id
            \\limit 1
        , .{workspace_row_id});
        if (referenced_omission) |row| {
            row.deinit();
            return error.Conflict;
        }

        for (workspace.repositories, 0..) |repository, repository_index| {
            try self.conn.exec(
                "insert into workspace_repositories (workspace_id, repository_id, sort_index, label, vcs_identity, default_branch) " ++
                    "values (?1, ?2, ?3, ?4, ?5, ?6) " ++
                    "on conflict(workspace_id, repository_id) do update set sort_index = excluded.sort_index, " ++
                    "label = excluded.label, vcs_identity = excluded.vcs_identity, default_branch = excluded.default_branch",
                .{
                    workspace_row_id,
                    repository.repository_id,
                    @as(i64, @intCast(repository_index)),
                    repository.label,
                    repository.vcs_identity,
                    repository.default_branch,
                },
            );
            const repository_row_id = try self.requireRepositoryRowId(workspace_row_id, repository.repository_id);
            try self.conn.exec(
                "delete from workspace_repository_bindings where repository_row_id = ?1",
                .{repository_row_id},
            );
            for (repository.bindings) |binding| try self.upsertRepositoryBindingRow(repository_row_id, binding);
        }

        const default_repository_id = workspace.default_repository_id orelse store_protocol.PRIMARY_REPOSITORY_ID;
        try self.conn.exec(
            "update workspaces set default_repository_id = ?1 where id = ?2",
            .{ default_repository_id, workspace_row_id },
        );
        try self.conn.exec(
            \\delete from workspace_repositories
            \\where workspace_id = ?1
            \\  and not exists (
            \\      select 1 from repository_manifest_targets target
            \\      where target.repository_id = workspace_repositories.repository_id
            \\  )
        , .{workspace_row_id});

        try self.conn.exec(
            \\update workspaces
            \\set path = (
            \\    select binding.root_path
            \\    from workspace_repository_bindings binding
            \\    join workspace_repositories repository on repository.id = binding.repository_row_id
            \\    join store_state state on state.id = 1 and state.runtime_id = binding.runtime_id
            \\    where repository.workspace_id = ?1 and repository.repository_id = 'primary'
            \\)
            \\where id = ?1 and exists (
            \\    select 1
            \\    from workspace_repository_bindings binding
            \\    join workspace_repositories repository on repository.id = binding.repository_row_id
            \\    join store_state state on state.id = 1 and state.runtime_id = binding.runtime_id
            \\    where repository.workspace_id = ?1 and repository.repository_id = 'primary'
            \\)
        , .{workspace_row_id});
        try self.ensureWorkspaceThreadRepositoriesExist(workspace_row_id);
    }

    fn ensureWorkspaceThreadRepositoriesExist(self: *Self, workspace_row_id: i64) !void {
        const missing = try self.conn.row(
            \\select 1 from threads thread
            \\where thread.workspace_id = ?1 and not exists (
            \\    select 1 from workspace_repositories repository
            \\    where repository.workspace_id = thread.workspace_id
            \\      and repository.repository_id = coalesce(thread.repository_id, 'primary')
            \\)
            \\limit 1
        , .{workspace_row_id});
        if (missing) |row| {
            row.deinit();
            return error.InvalidParams;
        }
    }

    fn upsertRepositoryBindingRow(
        self: *Self,
        repository_row_id: i64,
        binding: store_protocol.RepositoryBinding,
    ) !void {
        try self.conn.exec(
            "insert into workspace_repository_bindings (repository_row_id, runtime_id, root_path, availability) " ++
                "values (?1, ?2, ?3, ?4) on conflict(repository_row_id, runtime_id) do update set " ++
                "root_path = excluded.root_path, availability = excluded.availability",
            .{ repository_row_id, binding.runtime_id, binding.root_path, binding.availability },
        );
    }

    fn requireWorkspaceRowId(self: *Self, workspace_id: []const u8) !i64 {
        const row = (try self.conn.row(
            "select id from workspaces where workspace_id = ?1",
            .{workspace_id},
        )) orelse return error.ResourceNotFound;
        defer row.deinit();
        return row.int(0);
    }

    fn requireRepositoryRowId(self: *Self, workspace_row_id: i64, repository_id: []const u8) !i64 {
        const row = (try self.conn.row(
            "select id from workspace_repositories where workspace_id = ?1 and repository_id = ?2",
            .{ workspace_row_id, repository_id },
        )) orelse return error.ResourceNotFound;
        defer row.deinit();
        return row.int(0);
    }

    fn isStoreRuntime(self: *Self, runtime_id: []const u8) !bool {
        const row = (try self.conn.row(
            "select runtime_id from store_state where id = 1",
            .{},
        )) orelse return error.StoreCorrupt;
        defer row.deinit();
        const stored_runtime_id = row.nullableText(0) orelse return false;
        return std.mem.eql(u8, stored_runtime_id, runtime_id);
    }

    fn applyThread(self: *Self, request: store_protocol.ThreadUpsertRequest) !void {
        const thread = request.thread;
        const workspace_row_id = (try self.conn.row(
            "select id from workspaces where workspace_id = ?1",
            .{request.workspace_id},
        )) orelse return error.ResourceNotFound;
        defer workspace_row_id.deinit();
        const workspace_id = workspace_row_id.int(0);
        _ = try self.requireRepositoryRowId(
            workspace_id,
            thread.repository_id orelse store_protocol.PRIMARY_REPOSITORY_ID,
        );
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
            const draft_images_json = try encodeExtraImagesJson(self.allocator, thread.draft_images);
            defer if (draft_images_json) |value| self.allocator.free(value);
            try self.conn.exec(
                "update threads set title = ?1, archived = ?2, committed = ?3, last_activity_at = ?4, provider_thread_id = ?5, model_ref = ?6, reasoning_effort = ?7, reasoning_variant = ?8, fast_mode = ?9, access_mode = ?10, provider = ?11, harness = ?12, tui_dock_id = ?13, draft = ?14, draft_image_path = ?15, draft_image_mime = ?16, draft_image_byte_size = ?17, draft_images_json = ?18, cwd = ?19, profile_id = ?20, runtime_id = ?21, repository_id = ?22, repository_cwd = ?23 where id = ?24",
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
                    draft_images_json,
                    thread.cwd,
                    thread.profile_id,
                    thread.runtime_id,
                    thread.repository_id,
                    thread.repository_cwd,
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
            0,
            &.{},
            thread.cwd,
            thread.profile_id,
            thread.runtime_id,
            thread.repository_id,
            thread.repository_cwd,
            null,
        );
    }

    fn applyChatDraftSet(self: *Self, request: store_protocol.ChatDraftSetRequest) !void {
        const statement = if (request.append)
            "update threads set draft = draft || ?1 where workspace_id = (select id from workspaces where workspace_id = ?2) and local_thread_id = ?3"
        else
            "update threads set draft = ?1 where workspace_id = (select id from workspaces where workspace_id = ?2) and local_thread_id = ?3";
        try self.conn.exec(statement, .{ request.text, request.workspace_id, request.local_thread_id });
        if (self.conn.changes() == 0) return error.ResourceNotFound;
    }

    fn insertChatTurnWorkspaceIfMissing(self: *Self, workspace: store_protocol.Workspace) !bool {
        try self.conn.exec(
            "insert into workspaces (workspace_id, sort_index, label, path) " ++
                "values (?1, coalesce((select max(sort_index) + 1 from workspaces), 0), ?2, ?3) " ++
                "on conflict(workspace_id) do nothing",
            .{ workspace.workspace_id, workspace.label, workspace.path },
        );
        const inserted = self.conn.changes() > 0;
        if (inserted) {
            const workspace_row_id = try self.requireWorkspaceRowId(workspace.workspace_id);
            try self.reconcileWorkspaceRepositories(workspace_row_id, workspace);
        }
        return inserted;
    }

    fn insertChatTurnThreadIfMissing(
        self: *Self,
        workspace_id: []const u8,
        thread: store_protocol.Thread,
    ) !bool {
        const workspace_row_id = try self.requireWorkspaceRowId(workspace_id);
        _ = try self.requireRepositoryRowId(
            workspace_row_id,
            thread.repository_id orelse store_protocol.PRIMARY_REPOSITORY_ID,
        );
        const provider_code = try providerCode(thread.provider);
        const harness_code = try harnessCode(thread.harness);
        const reasoning_code = if (thread.reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (thread.fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (thread.access_mode) |value| try accessModeCode(value) else null;
        try self.conn.exec(
            "insert into threads (workspace_id, sort_index, title, local_thread_id, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, profile_id, runtime_id, repository_id, repository_cwd) " ++
                "select w.id, coalesce((select max(t.sort_index) + 1 from threads t where t.workspace_id = w.id), 0), ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15 " ++
                "from workspaces w where w.workspace_id = ?1 " ++
                "on conflict(workspace_id, local_thread_id) where local_thread_id is not null do nothing",
            .{
                workspace_id,
                thread.title,
                thread.local_thread_id,
                thread.provider_thread_id,
                thread.model_ref,
                reasoning_code,
                thread.reasoning_variant,
                fast_code,
                access_code,
                provider_code,
                harness_code,
                thread.profile_id,
                thread.runtime_id,
                thread.repository_id,
                thread.repository_cwd,
            },
        );
        if (self.conn.changes() > 0) return true;
        const owner = try self.conn.row(
            "select 1 from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ workspace_id, thread.local_thread_id },
        );
        if (owner) |row| {
            row.deinit();
            return false;
        }
        return error.ResourceNotFound;
    }

    fn updateTurnExecutionSettings(
        self: *Self,
        workspace_id: []const u8,
        thread: store_protocol.Thread,
    ) !void {
        const reasoning_code = if (thread.reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (thread.fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (thread.access_mode) |value| try accessModeCode(value) else null;
        try self.conn.exec(
            "update threads set model_ref = ?1, reasoning_effort = ?2, reasoning_variant = ?3, fast_mode = ?4, access_mode = ?5, " ++
                "profile_id = coalesce(?6, profile_id), runtime_id = coalesce(?7, runtime_id), " ++
                "repository_id = coalesce(?8, repository_id), repository_cwd = coalesce(?9, repository_cwd) " ++
                "where workspace_id = (select id from workspaces where workspace_id = ?10) and local_thread_id = ?11",
            .{
                thread.model_ref,
                reasoning_code,
                thread.reasoning_variant,
                fast_code,
                access_code,
                thread.profile_id,
                thread.runtime_id,
                thread.repository_id,
                thread.repository_cwd,
                workspace_id,
                thread.local_thread_id,
            },
        );
        if (self.conn.changes() == 0) return error.ResourceNotFound;
    }

    /// First-turn acceptance owns the prompt fallback. GUI draft rows are
    /// uncommitted; daemon-created and desktop-presented rows can already be
    /// committed, so every reserved empty-thread label remains replaceable
    /// until its first accepted prompt.
    fn updateTurnPresentationMetadata(
        self: *Self,
        workspace_id: []const u8,
        thread: store_protocol.Thread,
    ) !void {
        try self.conn.exec(
            "update threads set title = case when committed = 0 or " ++
                "(title in (?1, ?2, ?3) and not exists " ++
                "(select 1 from messages m where m.thread_id = threads.id)) then ?4 else title end, committed = 1 " ++
                "where workspace_id = (select id from workspaces where workspace_id = ?5) and local_thread_id = ?6",
            .{ "New Chat", "New chat", "New thread", thread.title, workspace_id, thread.local_thread_id },
        );
        if (self.conn.changes() > 0) return;
        const owner = try self.conn.row(
            "select 1 from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ workspace_id, thread.local_thread_id },
        );
        if (owner) |row| {
            row.deinit();
            return;
        }
        return error.ResourceNotFound;
    }

    fn applyGeneratedTurnTitle(
        self: *Self,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        expected_title: []const u8,
        generated_title: []const u8,
    ) !void {
        try self.conn.exec(
            "update threads set title = ?1 where workspace_id = (select id from workspaces where workspace_id = ?2) " ++
                "and local_thread_id = ?3 and title = ?4",
            .{ generated_title, workspace_id, local_thread_id, expected_title },
        );
    }

    /// True only for the opening user prompt while the durable title still
    /// matches the fallback the worker intends to replace.
    pub fn canGenerateAutomaticTitle(
        self: *Self,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        expected_title: []const u8,
    ) StoreError!bool {
        const row = self.conn.row(
            "select count(*) from threads t join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?1 and t.local_thread_id = ?2 and t.title = ?3 " ++
                "and (select count(*) from messages m where m.thread_id = t.id and m.role = 0) = 1",
            .{ workspace_id, local_thread_id, expected_title },
        ) catch |err| return mapStoreError(err);
        const result = row orelse return error.StoreCorrupt;
        defer result.deinit();
        return result.int(0) == 1;
    }

    /// Check the current durable title without exposing SQLite row identity.
    pub fn threadTitleEquals(
        self: *Self,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        expected_title: []const u8,
    ) StoreError!bool {
        const row = self.conn.row(
            "select count(*) from threads t join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?1 and t.local_thread_id = ?2 and t.title = ?3",
            .{ workspace_id, local_thread_id, expected_title },
        ) catch |err| return mapStoreError(err);
        const result = row orelse return error.StoreCorrupt;
        defer result.deinit();
        return result.int(0) == 1;
    }

    /// Adopt only the exact protocol-19 acceptance shape written before the
    /// atomic acceptance receipt existed. The three old receipts prove the
    /// row was staged by the turn path; the ledger, key fingerprint, and row
    /// checks prevent an unrelated message with the same public ID from being
    /// mistaken for that staging write.
    fn isLegacyStagedAcceptance(self: *Self, request: TurnAcceptanceRequest) !bool {
        const workspace_key = try std.fmt.allocPrint(self.allocator, "turn:{s}:stage-ws", .{request.turn_id});
        defer self.allocator.free(workspace_key);
        const thread_key = try std.fmt.allocPrint(self.allocator, "turn:{s}:stage-thread", .{request.turn_id});
        defer self.allocator.free(thread_key);
        const user_key = try std.fmt.allocPrint(self.allocator, "turn:{s}:stage-user", .{request.turn_id});
        defer self.allocator.free(user_key);

        const evidence = (try self.conn.row(
            "select " ++
                "exists(select 1 from chat_turns where turn_id = ?1), " ++
                "exists(select 1 from store_receipts where request_key in (?2, ?3, ?4)), " ++
                "exists(select 1 from client_message_keys k join threads t on t.id = k.thread_id join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?5 and t.local_thread_id = ?6 and k.message_id = ?7)",
            .{ request.turn_id, workspace_key, thread_key, user_key, request.workspace.workspace_id, request.thread.local_thread_id, request.user_message.message_id },
        )) orelse return error.StoreCorrupt;
        defer evidence.deinit();
        if (evidence.int(0) == 0 and evidence.int(1) == 0 and evidence.int(2) == 0) return false;

        const workspace_fingerprint = try self.fingerprintValue(request.workspace);
        defer self.allocator.free(workspace_fingerprint);
        const workspace_receipt = try self.legacyReceiptFor(.{
            .request_key = workspace_key,
            .client_id = "daemon",
        }, WORKSPACE_UPSERT_OPERATION, workspace_fingerprint);
        if (workspace_receipt == null) return error.Conflict;

        // HEAD's stage-thread request predated provider-thread and execution-
        // setting persistence. Reconstruct that exact request shape rather
        // than fingerprinting the richer retry request and mistaking omitted
        // legacy evidence for a contradiction.
        var legacy_thread = request.thread;
        legacy_thread.provider_thread_id = null;
        legacy_thread.model_ref = null;
        legacy_thread.reasoning_effort = null;
        legacy_thread.reasoning_variant = null;
        legacy_thread.fast_mode = null;
        legacy_thread.access_mode = null;
        legacy_thread.cwd = null;
        legacy_thread.profile_id = null;
        legacy_thread.runtime_id = null;
        legacy_thread.repository_id = null;
        legacy_thread.repository_cwd = null;
        const thread_fingerprint = try self.fingerprintValue(.{
            .workspace_id = request.workspace.workspace_id,
            .thread = legacy_thread,
        });
        defer self.allocator.free(thread_fingerprint);
        const thread_receipt = try self.legacyReceiptFor(.{
            .request_key = thread_key,
            .client_id = "daemon",
        }, THREAD_UPSERT_OPERATION, thread_fingerprint);
        if (thread_receipt == null) return error.Conflict;

        const workspace_revision = workspace_receipt.?.store_revision;
        const expected_thread_revision = std.math.add(u64, workspace_revision, 1) catch return error.Conflict;
        if (thread_receipt.?.store_revision != expected_thread_revision) return error.Conflict;

        const ledger = (try self.conn.row(
            "select workspace_id, local_thread_id, status, started_at_ms, finished_at_ms, provider, " ++
                "provider_thread_id, error_message, user_message_id, committed_store_revision " ++
                "from chat_turns where turn_id = ?1",
            .{request.turn_id},
        )) orelse return error.Conflict;
        defer ledger.deinit();
        const legacy_running = std.mem.eql(u8, ledger.text(2), "running") and ledger.nullableInt(4) == null;
        const legacy_interrupted = std.mem.eql(u8, ledger.text(2), "interrupted") and ledger.nullableInt(4) != null;
        if (!std.mem.eql(u8, ledger.text(0), request.workspace.workspace_id) or
            !std.mem.eql(u8, ledger.text(1), request.thread.local_thread_id) or
            !(legacy_running or legacy_interrupted) or
            !std.mem.eql(u8, ledger.text(5), request.provider) or
            // HEAD omitted provider_thread_id from this insert for both new
            // and continuing provider threads. A non-null durable value is
            // therefore not the legacy shape and remains conflicting.
            ledger.nullableText(6) != null or
            ledger.nullableText(7) != null or
            !optionalBytesEqual(ledger.nullableText(8), request.user_message.message_id) or
            ledger.nullableInt(9) != null)
        {
            return error.Conflict;
        }

        const message_row = (try self.conn.row(
            "select k.message_fingerprint, m.message_id, m.role, m.author, m.body, " ++
                "m.image_path, m.image_mime, m.image_byte_size, m.tool_call_id, m.tool_call_kind, m.tool_call_status, " ++
                "m.created_at_ms, m.updated_at_ms, k.store_revision " ++
                "from client_message_keys k join messages m on m.thread_id = k.thread_id and m.sort_index = k.sort_index " ++
                "join threads t on t.id = k.thread_id join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?1 and t.local_thread_id = ?2 and k.message_id = ?3",
            .{ request.workspace.workspace_id, request.thread.local_thread_id, request.user_message.message_id },
        )) orelse return error.Conflict;
        defer message_row.deinit();

        // Legacy client keys used to retain the serialized message itself.
        // Startup now reduces that payload to a digest, so reconstruct HEAD's
        // exact sparse staging DTO and verify both the row and its digest.
        const stored_message: store_protocol.Message = .{
            .message_id = request.user_message.message_id,
            .role = "user",
            .author = "You",
            .body = request.user_message.body,
            .created_at_ms = ledger.int(3),
            .updated_at_ms = ledger.int(3),
        };
        const stored_message_fingerprint = try self.fingerprintValue(stored_message);
        defer self.allocator.free(stored_message_fingerprint);
        const incoming_image = firstAttachment(request.user_message.image, request.user_message.images) catch return error.Conflict;
        if (!std.mem.eql(u8, message_row.text(0), stored_message_fingerprint) or
            !std.mem.eql(u8, stored_message.role, request.user_message.role) or
            !std.mem.eql(u8, stored_message.author, request.user_message.author) or
            // HEAD's staged Message literal omitted both image encodings, so
            // compatibility can authorize only the same durable no-attachment
            // shape rather than inventing absent first-writer evidence.
            incoming_image != null or
            !storedMessageMatchesRow(stored_message, message_row))
        {
            return error.Conflict;
        }

        const user_fingerprint = try self.fingerprintValue(.{
            .workspace_id = request.workspace.workspace_id,
            .thread_id = request.thread.local_thread_id,
            .message = stored_message,
        });
        defer self.allocator.free(user_fingerprint);
        const user_receipt = try self.legacyReceiptFor(.{
            .request_key = user_key,
            .client_id = "daemon",
        }, MESSAGE_APPEND_OPERATION, user_fingerprint);
        if (user_receipt == null) return error.Conflict;
        const expected_user_revision = std.math.add(u64, thread_receipt.?.store_revision, 1) catch return error.Conflict;
        if (user_receipt.?.store_revision != expected_user_revision or
            message_row.int(13) < 0 or
            @as(u64, @intCast(message_row.int(13))) != user_receipt.?.store_revision)
        {
            return error.Conflict;
        }
        return true;
    }

    fn updateTurnProviderIdentity(
        self: *Self,
        workspace_id: []const u8,
        local_thread_id: []const u8,
        provider: []const u8,
        harness: []const u8,
        provider_thread_id: ?[]const u8,
    ) !void {
        try self.conn.exec(
            "update threads set provider = ?1, harness = ?2, provider_thread_id = ?3 " ++
                "where id = (select t.id from threads t join workspaces w on w.id = t.workspace_id " ++
                "where w.workspace_id = ?4 and t.local_thread_id = ?5)",
            .{ try providerCode(provider), try harnessCode(harness), provider_thread_id, workspace_id, local_thread_id },
        );
        if (self.conn.changes() == 0) {
            const row = try self.conn.row(
                "select 1 from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
                .{ workspace_id, local_thread_id },
            );
            if (row) |existing| existing.deinit() else return error.ResourceNotFound;
        }
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

        const message_fingerprint = self.fingerprintValue(request.message) catch |err| return err;
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

    fn insertTerminalTurnReplayGuard(self: *Self, request: TurnCommitRequest) !void {
        try self.conn.exec(
            "insert into terminal_turn_replay_guard (turn_id, status) values (?1, ?2) on conflict(turn_id) do update set status = excluded.status",
            .{ request.turn_id, @tagName(request.status) },
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
        if (request.completed_at_ms) |completed_at_ms| {
            try self.conn.exec(
                "delete from chat_completions where workspace_id = ?1 and local_thread_id = ?2 and completed_at_ms <= ?3",
                .{ request.workspace_id, request.local_thread_id, completed_at_ms },
            );
        } else {
            // Compatibility for older clients that did not identify the
            // completion they were acknowledging.
            try self.conn.exec(
                "delete from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
                .{ request.workspace_id, request.local_thread_id },
            );
        }
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
                0,
                legacy_messages,
                null,
                null,
                null,
                null,
                null,
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
                    thread.message_offset,
                    thread.messages,
                    thread.cwd,
                    thread.profile_id,
                    thread.runtime_id,
                    thread.repository_id,
                    thread.repository_cwd,
                    store_revision,
                );
            }
        }
        try self.reconcileWorkspaceRepositories(workspace_row_id, workspace);
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
        message_offset: usize,
        messages: []const store_protocol.Message,
        cwd: ?[]const u8,
        profile_id: ?[]const u8,
        runtime_id: ?[]const u8,
        repository_id: ?[]const u8,
        repository_cwd: ?[]const u8,
        store_revision: ?i64,
    ) !void {
        const provider_code = try providerCode(provider);
        const harness_code = try harnessCode(harness);
        const reasoning_code = if (reasoning_effort) |value| try reasoningEffortCode(value) else null;
        const fast_code = if (fast_mode) |value| try fastModeCode(value) else null;
        const access_code = if (access_mode) |value| try accessModeCode(value) else null;
        const primary_draft_image = try firstAttachment(draft_image, draft_images);
        const draft_images_json = try encodeExtraImagesJson(self.allocator, draft_images);
        defer if (draft_images_json) |value| self.allocator.free(value);

        try self.conn.exec(
            "insert into threads (workspace_id, sort_index, title, archived, committed, local_thread_id, last_activity_at, provider_thread_id, model_ref, reasoning_effort, reasoning_variant, fast_mode, access_mode, provider, harness, tui_dock_id, draft, draft_image_path, draft_image_mime, draft_image_byte_size, draft_images_json, cwd, profile_id, runtime_id, repository_id, repository_cwd) " ++
                "values (?1, coalesce(?2, (select coalesce(max(sort_index) + 1, 0) from threads where workspace_id = ?1)), ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)",
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
                draft_images_json,
                cwd,
                profile_id,
                runtime_id,
                repository_id,
                repository_cwd,
            },
        );
        const thread_row_id = self.conn.lastInsertedRowId();
        for (messages, 0..) |message, message_index| {
            const durable_index = message_offset + message_index;
            try self.insertMessage(thread_row_id, @intCast(durable_index), message);
            if (store_revision) |revision| {
                if (message.message_id.len != 0) try self.insertMessageKey(thread_row_id, @intCast(durable_index), message, revision);
            }
        }
    }

    fn insertMessage(self: *Self, thread_row_id: i64, sort_index: i64, message: store_protocol.Message) !void {
        const role_code = try roleCode(message.role);
        const kind_code = if (message.tool_call_kind) |value| try toolCallKindCode(value) else null;
        const status_code = if (message.tool_call_status) |value| try toolCallStatusCode(value) else null;
        const image = try firstAttachment(message.image, message.images);
        const extra_images_json = try encodeExtraImagesJson(self.allocator, message.images);
        defer if (extra_images_json) |value| self.allocator.free(value);

        // M5-P4 Amendment 1 duplicate-id invariant: a snapshot carrying the
        // same (thread, message_id) twice must refresh position/content in
        // place (identity wins) instead of wedging the whole replace on the
        // partial unique index. The freed sort_index slot stays reserved to
        // this statement's sequence, so the per-thread unique(sort_index)
        // cannot collide.
        try self.conn.exec(
            "insert into messages (thread_id, sort_index, role, author, body, image_path, image_mime, image_byte_size, extra_images_json, tool_call_id, tool_call_kind, tool_call_status, message_id, created_at_ms, updated_at_ms) values (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15) " ++
                "on conflict(thread_id, message_id) where message_id is not null do update set sort_index = excluded.sort_index, role = excluded.role, author = excluded.author, body = excluded.body, image_path = coalesce(excluded.image_path, messages.image_path), image_mime = coalesce(excluded.image_mime, messages.image_mime), image_byte_size = coalesce(excluded.image_byte_size, messages.image_byte_size), extra_images_json = coalesce(excluded.extra_images_json, messages.extra_images_json), tool_call_id = excluded.tool_call_id, tool_call_kind = excluded.tool_call_kind, tool_call_status = excluded.tool_call_status, created_at_ms = excluded.created_at_ms, updated_at_ms = excluded.updated_at_ms",
            .{
                thread_row_id,
                sort_index,
                role_code,
                message.author,
                message.body,
                if (image) |value| value.path else null,
                if (image) |value| value.mime else null,
                if (image) |value| @as(i64, @intCast(value.byte_size)) else null,
                extra_images_json,
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
        const fingerprint = self.fingerprintValue(message) catch |err| return err;
        defer self.allocator.free(fingerprint);
        // M5-P4 Amendment 1: same duplicate-id tolerance as the message row —
        // the key table's (thread_id, message_id) primary key must follow the
        // refreshed row instead of failing the replace.
        try self.conn.exec(
            "insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index, created_at_ms, updated_at_ms, store_revision) values (?1, ?2, ?3, ?4, ?5, ?6, ?7) " ++
                "on conflict(thread_id, message_id) do update set message_fingerprint = excluded.message_fingerprint, sort_index = excluded.sort_index, created_at_ms = excluded.created_at_ms, updated_at_ms = excluded.updated_at_ms, store_revision = excluded.store_revision",
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
        .workspace_repository_upsert => |request| request.mutation,
        .workspace_repository_remove => |request| request.mutation,
        .workspace_default_repository_set => |request| request.mutation,
        .workspace_repository_binding_upsert => |request| request.mutation,
        .workspace_repository_binding_remove => |request| request.mutation,
        .thread_upsert => |request| request.mutation,
        .chat_draft_set => |request| request.mutation,
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
        .workspace_repository_upsert => WORKSPACE_REPOSITORY_UPSERT_OPERATION,
        .workspace_repository_remove => WORKSPACE_REPOSITORY_REMOVE_OPERATION,
        .workspace_default_repository_set => WORKSPACE_DEFAULT_REPOSITORY_SET_OPERATION,
        .workspace_repository_binding_upsert => WORKSPACE_REPOSITORY_BINDING_UPSERT_OPERATION,
        .workspace_repository_binding_remove => WORKSPACE_REPOSITORY_BINDING_REMOVE_OPERATION,
        .thread_upsert => THREAD_UPSERT_OPERATION,
        .chat_draft_set => CHAT_DRAFT_SET_OPERATION,
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
            if (!request.bootstrap and request.snapshot.store_revision != request.mutation.expected_store_revision.?) {
                // A payload may only be guarded by the revision it actually
                // observed. This rejects both stale relabeling and carried
                // workspace resurrection before the transaction mutates rows.
                return error.Conflict;
            }
            for (request.snapshot.workspaces) |workspace| {
                try validateWorkspaceRepositoryManifest(workspace);
                for (workspace.threads) |thread| try validateThreadRoute(thread);
            }
        },
        .workspace_upsert => |request| {
            if (request.workspace.workspace_id.len == 0 or request.workspace.label.len == 0 or request.workspace.path.len == 0) return error.InvalidParams;
            if (request.workspace.threads.len != 0 or request.workspace.messages.len != 0) return error.InvalidParams;
            try validateWorkspaceRepositoryManifest(request.workspace);
        },
        .workspace_repository_upsert => |request| {
            if (!validWorkspaceId(request.workspace_id) or !repositoryDefinitionValid(request.repository)) {
                return error.InvalidParams;
            }
        },
        .workspace_repository_remove => |request| {
            if (!validWorkspaceId(request.workspace_id) or !validRouteId(request.repository_id) or
                std.mem.eql(u8, request.repository_id, store_protocol.PRIMARY_REPOSITORY_ID))
            {
                return error.InvalidParams;
            }
        },
        .workspace_default_repository_set => |request| {
            if (!validWorkspaceId(request.workspace_id) or !validRouteId(request.repository_id)) {
                return error.InvalidParams;
            }
        },
        .workspace_repository_binding_upsert => |request| {
            if (!validWorkspaceId(request.workspace_id) or !validRouteId(request.repository_id) or
                !repositoryBindingValid(request.binding))
            {
                return error.InvalidParams;
            }
        },
        .workspace_repository_binding_remove => |request| {
            if (!validWorkspaceId(request.workspace_id) or !validRouteId(request.repository_id) or
                !validRuntimeId(request.runtime_id))
            {
                return error.InvalidParams;
            }
        },
        .thread_upsert => |request| {
            if (request.workspace_id.len == 0 or request.thread.local_thread_id.len == 0) return error.InvalidParams;
            if (request.thread.messages.len != 0) return error.InvalidParams;
            try validateThreadRoute(request.thread);
            _ = try firstAttachment(request.thread.draft_image, request.thread.draft_images);
        },
        .chat_draft_set => |request| {
            if (request.workspace_id.len == 0 or request.local_thread_id.len == 0) return error.InvalidParams;
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
    if ((request.expected_thread_title == null) != (request.generated_title == null)) return error.InvalidParams;
    if (request.expected_thread_title) |value| if (value.len == 0) return error.InvalidParams;
    if (request.generated_title) |value| if (value.len == 0) return error.InvalidParams;
    _ = providerCode(request.provider) catch return error.InvalidParams;
    _ = harnessCode(request.harness) catch return error.InvalidParams;
    if (request.workspace) |workspace| {
        if (!std.mem.eql(u8, workspace.workspace_id, request.workspace_id) or workspace.label.len == 0 or workspace.path.len == 0 or
            workspace.threads.len != 0 or workspace.messages.len != 0) return error.InvalidParams;
        try validateWorkspaceRepositoryManifest(workspace);
    }
    if (request.thread) |thread| {
        if (!std.mem.eql(u8, thread.local_thread_id, request.local_thread_id) or thread.messages.len != 0 or
            !std.mem.eql(u8, thread.provider, request.provider) or !std.mem.eql(u8, thread.harness, request.harness) or
            !optionalBytesEqual(thread.provider_thread_id, request.provider_thread_id)) return error.InvalidParams;
        try validateThreadRoute(thread);
    }
    if (request.completion) |completion| {
        if (!std.mem.eql(u8, completion.workspace_id, request.workspace_id) or
            !std.mem.eql(u8, completion.local_thread_id, request.local_thread_id)) return error.InvalidParams;
    }
    for (request.messages) |message| {
        _ = try firstAttachment(message.image, message.images);
    }
}

fn validateTurnAcceptance(request: TurnAcceptanceRequest) StoreError!void {
    if (request.mutation.request_key.len == 0 or request.mutation.client_id.len == 0 or
        request.turn_id.len == 0 or request.workspace.workspace_id.len == 0 or
        request.workspace.label.len == 0 or request.workspace.path.len == 0 or
        request.thread.local_thread_id.len == 0 or request.user_message.message_id.len == 0)
    {
        return error.InvalidParams;
    }
    if (request.workspace.threads.len != 0 or request.workspace.messages.len != 0 or request.thread.messages.len != 0) return error.InvalidParams;
    try validateWorkspaceRepositoryManifest(request.workspace);
    if (!std.mem.eql(u8, request.thread.provider, request.provider) or
        !std.mem.eql(u8, request.thread.harness, request.harness) or
        !optionalBytesEqual(request.thread.provider_thread_id, request.provider_thread_id)) return error.InvalidParams;
    try validateThreadRoute(request.thread);
    _ = providerCode(request.provider) catch return error.InvalidParams;
    _ = harnessCode(request.harness) catch return error.InvalidParams;
    _ = try firstAttachment(request.user_message.image, request.user_message.images);
}

fn validateThreadRoute(thread: store_protocol.Thread) StoreError!void {
    const route_absent = thread.profile_id == null and thread.runtime_id == null and
        thread.repository_id == null and thread.repository_cwd == null;
    if (route_absent) return;
    if (thread.committed and thread.local_thread_id.len == 0) return error.InvalidParams;
    const profile_id = thread.profile_id orelse return error.InvalidParams;
    const repository_id = thread.repository_id orelse return error.InvalidParams;
    if (!validRouteId(profile_id) or !validRouteId(repository_id)) return error.InvalidParams;
    if (thread.committed and !std.mem.eql(u8, profile_id, "local") and thread.runtime_id == null) {
        return error.InvalidParams;
    }
    if (thread.runtime_id) |runtime_id| {
        if (runtime_id.len != 32) return error.InvalidParams;
        for (runtime_id) |byte| {
            if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidParams;
        }
    }
    if (thread.repository_cwd) |relative_cwd| {
        if (!validRepositoryCwd(relative_cwd)) return error.InvalidParams;
    }
}

fn validRouteId(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_REPOSITORY_ID_BYTES) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return false;
    }
    return true;
}

fn validRepositoryCwd(value: []const u8) bool {
    if (value.len == 0 or value.len > 4 * 1024 or value[0] == '/' or
        !std.unicode.utf8ValidateSlice(value))
    {
        return false;
    }
    for (value) |byte| {
        if (byte == '\\' or byte == ':' or std.ascii.isControl(byte)) return false;
    }
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

fn validateWorkspaceRepositoryManifest(workspace: store_protocol.Workspace) StoreError!void {
    if (!validWorkspaceId(workspace.workspace_id)) return error.InvalidParams;
    if (workspace.repositories.len > MAX_WORKSPACE_REPOSITORIES) return error.CapabilityUnavailable;
    if (workspace.repositories.len == 0) {
        if (workspace.default_repository_id) |repository_id| {
            if (!std.mem.eql(u8, repository_id, store_protocol.PRIMARY_REPOSITORY_ID)) return error.InvalidParams;
        }
        return;
    }

    const default_repository_id = workspace.default_repository_id orelse store_protocol.PRIMARY_REPOSITORY_ID;
    if (!validRouteId(default_repository_id)) return error.InvalidParams;
    var found_primary = false;
    var found_default = false;
    for (workspace.repositories, 0..) |repository, repository_index| {
        const definition: RepositoryDefinition = .{
            .repository_id = repository.repository_id,
            .label = repository.label,
            .vcs_identity = repository.vcs_identity,
            .default_branch = repository.default_branch,
        };
        if (!repositoryDefinitionValid(definition)) return error.InvalidParams;
        if (repository.bindings.len > MAX_REPOSITORY_BINDINGS) return error.CapabilityUnavailable;
        for (workspace.repositories[0..repository_index]) |prior| {
            if (std.mem.eql(u8, prior.repository_id, repository.repository_id)) return error.InvalidParams;
        }
        for (repository.bindings, 0..) |binding, binding_index| {
            if (!repositoryBindingValid(binding)) return error.InvalidParams;
            for (repository.bindings[0..binding_index]) |prior| {
                if (std.mem.eql(u8, prior.runtime_id, binding.runtime_id)) return error.InvalidParams;
            }
        }
        found_primary = found_primary or std.mem.eql(u8, repository.repository_id, store_protocol.PRIMARY_REPOSITORY_ID);
        found_default = found_default or std.mem.eql(u8, repository.repository_id, default_repository_id);
    }
    if (!found_primary or !found_default) return error.InvalidParams;

    for (workspace.threads) |thread| {
        const repository_id = thread.repository_id orelse store_protocol.PRIMARY_REPOSITORY_ID;
        var found = false;
        for (workspace.repositories) |repository| {
            if (std.mem.eql(u8, repository.repository_id, repository_id)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidParams;
    }
}

fn repositoryDefinitionValid(definition: RepositoryDefinition) bool {
    if (!validRouteId(definition.repository_id) or
        !validBoundedDisplayText(definition.label, MAX_REPOSITORY_LABEL_BYTES))
    {
        return false;
    }
    if (definition.vcs_identity) |value| {
        if (!validVcsIdentity(value)) return false;
    }
    if (definition.default_branch) |value| {
        if (!validDefaultBranch(value)) return false;
    }
    return true;
}

fn repositoryBindingValid(binding: store_protocol.RepositoryBinding) bool {
    return validRuntimeId(binding.runtime_id) and
        validAbsoluteRepositoryPath(binding.root_path) and
        (std.mem.eql(u8, binding.availability, "available") or
            std.mem.eql(u8, binding.availability, "missing") or
            std.mem.eql(u8, binding.availability, "unknown"));
}

fn validWorkspaceId(value: []const u8) bool {
    if (value.len == 0 or value.len > 512 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}

fn validRuntimeId(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn validBoundedDisplayText(value: []const u8, max_bytes: usize) bool {
    if (value.len == 0 or value.len > max_bytes or !std.unicode.utf8ValidateSlice(value)) return false;
    if (std.ascii.isWhitespace(value[0]) or std.ascii.isWhitespace(value[value.len - 1])) return false;
    for (value) |byte| if (std.ascii.isControl(byte)) return false;
    return true;
}

fn validAbsoluteRepositoryPath(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_REPOSITORY_PATH_BYTES or
        !std.unicode.utf8ValidateSlice(value))
    {
        return false;
    }
    for (value) |byte| if (std.ascii.isControl(byte)) return false;

    if (value[0] == '/') {
        if (std.mem.findScalar(u8, value, '\\') != null) return false;
        if (value.len == 1) return false;
        return validPathSegments(value[1..], "/", 1);
    }
    if (value.len >= 3 and std.ascii.isAlphabetic(value[0]) and value[1] == ':' and
        (value[2] == '/' or value[2] == '\\'))
    {
        if (value.len == 3) return false;
        const separator: u8 = value[2];
        const other_separator: u8 = if (separator == '/') '\\' else '/';
        if (std.mem.findScalar(u8, value[3..], other_separator) != null or
            std.mem.findScalar(u8, value[2..], ':') != null)
        {
            return false;
        }
        const delimiters = if (separator == '/') "/" else "\\";
        return validPathSegments(value[3..], delimiters, 1);
    }
    if (std.mem.startsWith(u8, value, "\\\\") and
        !std.mem.startsWith(u8, value, "\\\\?\\") and
        !std.mem.startsWith(u8, value, "\\\\.\\"))
    {
        if (std.mem.findScalar(u8, value[2..], '/') != null) return false;
        return validPathSegments(value[2..], "\\", 3);
    }
    return false;
}

fn validPathSegments(value: []const u8, delimiters: []const u8, minimum_segments: usize) bool {
    var count: usize = 0;
    var segments = std.mem.splitAny(u8, value, delimiters);
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        count += 1;
    }
    return count >= minimum_segments;
}

fn validVcsIdentity(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_VCS_IDENTITY_BYTES or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.findScalar(u8, value, '?') != null or
        std.mem.findScalar(u8, value, '#') != null or
        std.mem.findScalar(u8, value, '\\') != null or
        std.mem.findScalar(u8, value, '%') != null)
    {
        return false;
    }
    for (value) |byte| if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;

    if (std.mem.find(u8, value, "://")) |scheme_end| {
        const scheme = value[0..scheme_end];
        const is_ssh = std.mem.eql(u8, scheme, "ssh");
        if (!is_ssh and !std.mem.eql(u8, scheme, "https") and
            !std.mem.eql(u8, scheme, "git"))
        {
            return false;
        }
        const authority_start = scheme_end + 3;
        if (authority_start >= value.len) return false;
        const path_offset = std.mem.findScalar(u8, value[authority_start..], '/') orelse return false;
        const authority_end = authority_start + path_offset;
        const authority = value[authority_start..authority_end];
        return validVcsAuthority(authority, is_ssh) and validVcsPath(value[authority_end + 1 ..]);
    }

    const at_index = std.mem.findScalar(u8, value, '@') orelse return false;
    if (!validVcsUser(value[0..at_index]) or
        std.mem.findScalar(u8, value[at_index + 1 ..], '@') != null)
    {
        return false;
    }
    const host_and_path = value[at_index + 1 ..];
    const colon_index = std.mem.findScalar(u8, host_and_path, ':') orelse return false;
    return validVcsHost(host_and_path[0..colon_index]) and validVcsPath(host_and_path[colon_index + 1 ..]);
}

fn validVcsAuthority(authority: []const u8, allow_user: bool) bool {
    if (authority.len == 0 or std.mem.findScalar(u8, authority, '%') != null) return false;
    var host_port = authority;
    if (std.mem.findScalar(u8, authority, '@')) |at_index| {
        if (!allow_user or !validVcsUser(authority[0..at_index]) or
            std.mem.findScalar(u8, authority[at_index + 1 ..], '@') != null)
        {
            return false;
        }
        host_port = authority[at_index + 1 ..];
    }
    return validVcsHostPort(host_port);
}

fn validVcsUser(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or vcsSegmentLooksCredentialBearing(value)) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') return false;
    }
    return true;
}

fn validVcsHostPort(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == '[') {
        const close_index = std.mem.findScalar(u8, value, ']') orelse return false;
        if (close_index <= 1 or !validBracketedVcsHost(value[1..close_index])) return false;
        if (close_index + 1 == value.len) return true;
        return value[close_index + 1] == ':' and validNumericPort(value[close_index + 2 ..]);
    }
    if (std.mem.findScalar(u8, value, ':')) |colon_index| {
        if (std.mem.findScalar(u8, value[colon_index + 1 ..], ':') != null) return false;
        return validVcsHost(value[0..colon_index]) and validNumericPort(value[colon_index + 1 ..]);
    }
    return validVcsHost(value);
}

fn validVcsHost(value: []const u8) bool {
    if (value.len == 0 or value.len > 253 or !std.ascii.isAlphanumeric(value[0]) or
        !std.ascii.isAlphanumeric(value[value.len - 1]))
    {
        return false;
    }
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') return false;
    }
    return true;
}

fn validBracketedVcsHost(value: []const u8) bool {
    for (value) |byte| {
        if (!std.ascii.isHex(byte) and byte != ':' and byte != '.') return false;
    }
    return true;
}

fn validNumericPort(value: []const u8) bool {
    if (value.len == 0 or value.len > 5) return false;
    var port: u32 = 0;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
        port = port * 10 + (byte - '0');
    }
    return port > 0 and port <= 65535;
}

fn validVcsPath(value: []const u8) bool {
    if (value.len == 0 or value[0] == '/' or value[value.len - 1] == '/' or
        std.mem.find(u8, value, "//") != null)
    {
        return false;
    }
    var segments = std.mem.splitScalar(u8, value, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..") or
            vcsSegmentLooksCredentialBearing(segment))
        {
            return false;
        }
        for (segment) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and
                byte != '-' and byte != '+' and byte != '~')
            {
                return false;
            }
        }
    }
    return true;
}

fn vcsSegmentLooksCredentialBearing(segment: []const u8) bool {
    const exact = [_][]const u8{ "oauth2", "token", "x-access-token" };
    for (exact) |candidate| if (std.ascii.eqlIgnoreCase(segment, candidate)) return true;
    const prefixes = [_][]const u8{ "ghp_", "github_pat_", "glpat-" };
    for (prefixes) |prefix| {
        if (segment.len >= prefix.len and std.ascii.eqlIgnoreCase(segment[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn validDefaultBranch(value: []const u8) bool {
    if (value.len == 0 or value.len > MAX_DEFAULT_BRANCH_BYTES or
        !std.unicode.utf8ValidateSlice(value) or value[0] == '/' or value[value.len - 1] == '/' or
        value[0] == '.' or value[value.len - 1] == '.' or
        std.mem.eql(u8, value, "@") or std.mem.endsWith(u8, value, ".lock") or
        std.mem.find(u8, value, "..") != null or std.mem.find(u8, value, "//") != null or
        std.mem.find(u8, value, "@{") != null)
    {
        return false;
    }
    for (value) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte) or
            byte == '~' or byte == '^' or byte == ':' or byte == '?' or
            byte == '*' or byte == '[' or byte == '\\')
        {
            return false;
        }
    }
    return true;
}

fn copyRepositoryBinding(
    allocator: std.mem.Allocator,
    binding: store_protocol.RepositoryBinding,
) !store_protocol.RepositoryBinding {
    const runtime_id = try allocator.dupe(u8, binding.runtime_id);
    errdefer allocator.free(runtime_id);
    const root_path = try allocator.dupe(u8, binding.root_path);
    errdefer allocator.free(root_path);
    const availability = try allocator.dupe(u8, binding.availability);
    return .{
        .runtime_id = runtime_id,
        .root_path = root_path,
        .availability = availability,
    };
}

fn freeOwnedRepositoryBinding(allocator: std.mem.Allocator, binding: store_protocol.RepositoryBinding) void {
    allocator.free(binding.runtime_id);
    allocator.free(binding.root_path);
    allocator.free(binding.availability);
}

fn freeOwnedRepository(allocator: std.mem.Allocator, repository: store_protocol.Repository) void {
    allocator.free(repository.repository_id);
    allocator.free(repository.label);
    if (repository.vcs_identity) |value| allocator.free(value);
    if (repository.default_branch) |value| allocator.free(value);
    for (repository.bindings) |binding| freeOwnedRepositoryBinding(allocator, binding);
    allocator.free(repository.bindings);
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
    if (many.len == 0) return single;
    if (single) |legacy| {
        if (!attachmentsEqual(legacy, many[0])) return error.InvalidParams;
    }
    return many[0];
}

/// Attachments past the primary. The primary stays in the legacy single
/// image columns for old readers; everything after it rides in the additive
/// `*_images_json` column so no attachment is silently narrowed to one.
fn extraAttachments(many: []const store_protocol.Attachment) []const store_protocol.Attachment {
    if (many.len <= 1) return &.{};
    return many[1..];
}

/// Stored shape of one extra attachment inside a `*_images_json` column
/// (shared with the read-only projection client).
pub const StoredExtraImage = schema.StoredExtraImage;

/// Encode attachments past the primary as a compact JSON array, or null when
/// at most one attachment exists. Caller frees the returned slice.
fn encodeExtraImagesJson(allocator: std.mem.Allocator, many: []const store_protocol.Attachment) StoreError!?[]u8 {
    const extras = extraAttachments(many);
    if (extras.len == 0) return null;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    s.beginArray() catch return error.OutOfMemory;
    for (extras) |attachment| {
        s.write(StoredExtraImage{
            .path = attachment.path,
            .mime = attachment.mime,
            .byte_size = attachment.byte_size,
        }) catch return error.OutOfMemory;
    }
    s.endArray() catch return error.OutOfMemory;
    return writer.toOwnedSlice() catch return error.OutOfMemory;
}

fn attachmentsEqual(left: store_protocol.Attachment, right: store_protocol.Attachment) bool {
    return std.mem.eql(u8, left.path, right.path) and
        std.mem.eql(u8, left.mime, right.mime) and
        left.byte_size == right.byte_size and
        optionalBytesEqual(left.attachment_id, right.attachment_id);
}

fn optionalAttachmentEqual(left: ?store_protocol.Attachment, right: ?store_protocol.Attachment) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return attachmentsEqual(left_value, right_value);
    }
    return right == null;
}

fn storedMessageMatchesRow(message: store_protocol.Message, row: anytype) bool {
    if (!std.mem.eql(u8, row.text(1), message.message_id) or
        row.int(2) != (roleCode(message.role) catch return false) or
        !std.mem.eql(u8, row.text(3), message.author) or
        !std.mem.eql(u8, row.text(4), message.body) or
        !optionalBytesEqual(row.nullableText(8), message.tool_call_id) or
        !optionalIntEqual(row.nullableInt(9), if (message.tool_call_kind) |value| toolCallKindCode(value) catch return false else null) or
        !optionalIntEqual(row.nullableInt(10), if (message.tool_call_status) |value| toolCallStatusCode(value) catch return false else null) or
        !optionalIntEqual(row.nullableInt(11), message.created_at_ms) or
        !optionalIntEqual(row.nullableInt(12), message.updated_at_ms))
    {
        return false;
    }
    const image = firstAttachment(message.image, message.images) catch return false;
    if (image) |value| {
        if (!optionalBytesEqual(row.nullableText(5), value.path) or
            !optionalBytesEqual(row.nullableText(6), value.mime) or
            !optionalIntEqual(row.nullableInt(7), @intCast(value.byte_size)) or
            value.attachment_id != null)
        {
            return false;
        }
    } else if (row.nullableText(5) != null or row.nullableText(6) != null or row.nullableInt(7) != null) {
        return false;
    }
    return true;
}

fn optionalIntEqual(left: ?i64, right: ?i64) bool {
    if (left) |left_value| return right != null and left_value == right.?;
    return right == null;
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
    if (std.mem.eql(u8, value, "pi")) return 4;
    if (std.mem.eql(u8, value, "fx")) return 5;
    if (std.mem.eql(u8, value, "grok")) return 6;
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
    if (std.mem.eql(u8, value, "user")) return 0;
    if (std.mem.eql(u8, value, "assistant")) return 1;
    if (std.mem.eql(u8, value, "system")) return 2;
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
    const names = [_][]const u8{ "opencode", "codex", "cursor", "claude", "grok", "amp", "pi", "fx" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

fn surfaceStatusCode(value: []const u8) !i64 {
    const names = [_][]const u8{ "idle", "working", "waiting", "done", "error" };
    for (names, 0..) |name, index| if (std.mem.eql(u8, value, name)) return @intCast(index);
    return error.InvalidParams;
}

const ReceiptFingerprintUpdate = struct {
    request_key: []u8,
    fingerprint: [FINGERPRINT_LEN]u8,
};

const MessageFingerprintUpdate = struct {
    thread_id: i64,
    message_id: []u8,
    fingerprint: [FINGERPRINT_LEN]u8,
};

fn migrateLegacyFingerprints(allocator: std.mem.Allocator, conn: zqlite.Conn) !u64 {
    var receipt_updates: std.ArrayList(ReceiptFingerprintUpdate) = .empty;
    defer {
        for (receipt_updates.items) |update| allocator.free(update.request_key);
        receipt_updates.deinit(allocator);
    }
    var message_updates: std.ArrayList(MessageFingerprintUpdate) = .empty;
    defer {
        for (message_updates.items) |update| allocator.free(update.message_id);
        message_updates.deinit(allocator);
    }

    try conn.execNoArgs("begin immediate");
    errdefer conn.rollback();

    var migrated_bytes: u64 = 0;
    {
        var rows = try conn.rows("select request_key, fingerprint from store_receipts", .{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const existing = row.text(1);
            if (isDigestFingerprint(existing)) continue;
            const request_key = try allocator.dupe(u8, row.text(0));
            receipt_updates.append(allocator, .{
                .request_key = request_key,
                .fingerprint = fingerprintBytes(existing),
            }) catch |err| {
                allocator.free(request_key);
                return err;
            };
            migrated_bytes +|= @intCast(existing.len);
        }
        if (rows.err) |err| return err;
    }
    {
        var rows = try conn.rows("select thread_id, message_id, message_fingerprint from client_message_keys", .{});
        defer rows.deinit();
        while (rows.next()) |row| {
            const existing = row.text(2);
            if (isDigestFingerprint(existing)) continue;
            const message_id = try allocator.dupe(u8, row.text(1));
            message_updates.append(allocator, .{
                .thread_id = row.int(0),
                .message_id = message_id,
                .fingerprint = fingerprintBytes(existing),
            }) catch |err| {
                allocator.free(message_id);
                return err;
            };
            migrated_bytes +|= @intCast(existing.len);
        }
        if (rows.err) |err| return err;
    }

    for (receipt_updates.items) |*update| {
        try conn.exec(
            "update store_receipts set fingerprint = ?1 where request_key = ?2",
            .{ update.fingerprint[0..], update.request_key },
        );
    }
    for (message_updates.items) |*update| {
        try conn.exec(
            "update client_message_keys set message_fingerprint = ?1 where thread_id = ?2 and message_id = ?3",
            .{ update.fingerprint[0..], update.thread_id, update.message_id },
        );
    }
    try conn.commit();
    return migrated_bytes;
}

fn compactFreedPages(conn: zqlite.Conn, min_free_bytes: u64) !void {
    const page_size: u64 = blk: {
        var row = (try conn.row("pragma page_size", .{})) orelse return error.StoreMetadataMissing;
        defer row.deinit();
        const value = row.int(0);
        if (value <= 0) return error.StoreMetadataMissing;
        break :blk @intCast(value);
    };
    const free_pages: u64 = blk: {
        var row = (try conn.row("pragma freelist_count", .{})) orelse return error.StoreMetadataMissing;
        defer row.deinit();
        const value = row.int(0);
        if (value < 0) return error.StoreMetadataMissing;
        break :blk @intCast(value);
    };
    const free_bytes = std.math.mul(u64, page_size, free_pages) catch std.math.maxInt(u64);
    if (free_bytes < min_free_bytes) return;

    {
        var checkpoint = (try conn.row("pragma wal_checkpoint(truncate)", .{})) orelse return error.StoreUnavailable;
        defer checkpoint.deinit();
        if (checkpoint.int(0) != 0) return error.Busy;
    }
    try conn.execNoArgs("vacuum");
    log.info("compacted daemon store free_bytes={d}", .{free_bytes});
}

fn fingerprintBytes(value: []const u8) [FINGERPRINT_LEN]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var fingerprint: [FINGERPRINT_LEN]u8 = undefined;
    @memcpy(fingerprint[0..FINGERPRINT_PREFIX.len], FINGERPRINT_PREFIX);
    @memcpy(fingerprint[FINGERPRINT_PREFIX.len..], &hex);
    return fingerprint;
}

fn isDigestFingerprint(value: []const u8) bool {
    if (value.len != FINGERPRINT_LEN or !std.mem.startsWith(u8, value, FINGERPRINT_PREFIX)) return false;
    for (value[FINGERPRINT_PREFIX.len..]) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return true;
}

fn mapOpenError(err: anyerror) StoreError {
    if (err == error.DatabaseSchemaTooNew) return error.SchemaTooNew;
    if (err == error.DatabaseSchemaInvalid or err == error.MissingSchemaVersion) return error.StoreCorrupt;
    if (err == error.StoreMetadataMissing or err == error.StoreMetadataCorrupt) return error.StoreCorrupt;
    if (err == error.RuntimeIdentityMismatch) return error.RuntimeIdentityMismatch;
    if (err == error.InvalidRuntimeIdentity) return error.InvalidRuntimeIdentity;
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
    if (err == error.RuntimeIdentityMismatch) return error.RuntimeIdentityMismatch;
    if (err == error.InvalidRuntimeIdentity) return error.InvalidRuntimeIdentity;
    if (err == error.PageCursorInvalid) return error.PageCursorInvalid;
    if (err == error.PageCursorStale) return error.PageCursorStale;
    if (err == error.PageCursorMismatch) return error.PageCursorMismatch;
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

test "identity-bound store initializes durable access tables" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.initWithRuntimeIdentity(
        std.testing.allocator,
        db_path,
        .none,
        .{
            .runtime_id = "0123456789abcdef0123456789abcdef",
            .instance_id = "fedcba9876543210fedcba9876543210",
        },
    );
    defer store.deinit();

    var row = (try store.conn.row(
        \\select count(*) from sqlite_schema
        \\where type = 'table' and name in ('runtime_pairing_grants', 'runtime_devices')
    , .{})).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 2), row.int(0));
}

fn seedLegacyStagedAcceptance(store: *Store, request: TurnAcceptanceRequest) !void {
    const workspace_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-ws", .{request.turn_id});
    defer std.testing.allocator.free(workspace_key);
    const thread_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-thread", .{request.turn_id});
    defer std.testing.allocator.free(thread_key);
    const user_key = try std.fmt.allocPrint(std.testing.allocator, "turn:{s}:stage-user", .{request.turn_id});
    defer std.testing.allocator.free(user_key);
    // Reproduce stageAcceptedChatTurn from committed HEAD literally. These
    // sparse DTOs, unguarded daemon headers, and the ledger column list are
    // the compatibility contract; do not seed them from the richer request.
    _ = try store.upsertWorkspace(.{
        .mutation = .{ .request_key = workspace_key, .client_id = "daemon" },
        .workspace = .{
            .workspace_id = request.workspace.workspace_id,
            .label = request.workspace.workspace_id,
            .path = request.workspace.path,
        },
    });
    _ = try store.upsertThread(.{
        .mutation = .{ .request_key = thread_key, .client_id = "daemon" },
        .workspace_id = request.workspace.workspace_id,
        .thread = .{
            .local_thread_id = request.thread.local_thread_id,
            .title = request.thread.title,
            .provider = request.provider,
            .harness = request.harness,
        },
    });
    _ = try store.appendMessage(.{
        .mutation = .{ .request_key = user_key, .client_id = "daemon" },
        .workspace_id = request.workspace.workspace_id,
        .thread_id = request.thread.local_thread_id,
        .message = .{
            .message_id = request.user_message.message_id,
            .role = "user",
            .author = "You",
            .body = request.user_message.body,
            .created_at_ms = request.started_at_ms,
            .updated_at_ms = request.started_at_ms,
        },
    });
    try store.conn.exec(
        "insert or ignore into chat_turns (turn_id, workspace_id, local_thread_id, status, started_at_ms, provider, user_message_id) " ++
            "values (?1, ?2, ?3, 'running', ?4, ?5, ?6)",
        .{
            request.turn_id,
            request.workspace.workspace_id,
            request.thread.local_thread_id,
            request.started_at_ms,
            request.provider,
            request.user_message.message_id,
        },
    );
    // Reproduce the startup interrupted-turn sweep, including deliberate
    // finished-at drift relative to both the staged row and a later retry.
    try store.conn.exec(
        "update chat_turns set status = 'interrupted', finished_at_ms = coalesce(finished_at_ms, ?1) where turn_id = ?2",
        .{ request.started_at_ms + 91, request.turn_id },
    );
}

const LegacyEvidenceAttack = enum {
    workspace_receipt_revision,
    thread_receipt_revision,
    user_receipt_revision,
    response_revision,
    response_applied,
    response_duplicate,
    response_status,
    non_contiguous_revisions,
    client_key_revision,
    malformed_response,
    operation,
    fingerprint,
    missing_receipt,
    provider,
    content,
};

const LegacyStateSnapshot = struct {
    revision: u64,
    workspace: []u8,
    thread: []u8,
    message: []u8,
    message_key: []u8,
    ledger: []u8,
    receipts: []u8,
    replay_guard: []u8,

    fn capture(allocator: std.mem.Allocator, store: *Store) !LegacyStateSnapshot {
        const row = (try store.conn.row(
            "select (select store_revision from store_state where id = 1), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(workspace_id)||char(31)||quote(label)||char(31)||quote(path) v from workspaces order by workspace_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(w.workspace_id)||char(31)||quote(t.local_thread_id)||char(31)||quote(t.title)||char(31)||quote(t.provider_thread_id)||char(31)||t.provider||char(31)||t.harness v from threads t join workspaces w on w.id=t.workspace_id order by w.workspace_id,t.local_thread_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(message_id)||char(31)||quote(role)||char(31)||quote(author)||char(31)||quote(body)||char(31)||quote(image_path)||char(31)||quote(image_mime)||char(31)||quote(image_byte_size)||char(31)||quote(created_at_ms)||char(31)||quote(updated_at_ms) v from messages order by thread_id,sort_index)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(message_id)||char(31)||quote(message_fingerprint)||char(31)||quote(sort_index)||char(31)||quote(created_at_ms)||char(31)||quote(updated_at_ms)||char(31)||quote(store_revision) v from client_message_keys order by thread_id,message_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(turn_id)||char(31)||quote(workspace_id)||char(31)||quote(local_thread_id)||char(31)||quote(status)||char(31)||quote(started_at_ms)||char(31)||quote(finished_at_ms)||char(31)||quote(provider)||char(31)||quote(provider_thread_id)||char(31)||quote(error_message)||char(31)||quote(user_message_id)||char(31)||quote(committed_store_revision) v from chat_turns order by turn_id)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(request_key)||char(31)||quote(operation)||char(31)||quote(fingerprint)||char(31)||quote(store_revision)||char(31)||quote(response_status)||char(31)||quote(response_payload) v from store_receipts order by request_key)), ''), " ++
                "coalesce((select group_concat(v, char(30)) from (select quote(turn_id)||char(31)||quote(status) v from terminal_turn_replay_guard order by turn_id)), '')",
            .{},
        )) orelse return error.StoreCorrupt;
        defer row.deinit();
        return .{
            .revision = try requiredU64(row.int(0)),
            .workspace = try allocator.dupe(u8, row.text(1)),
            .thread = try allocator.dupe(u8, row.text(2)),
            .message = try allocator.dupe(u8, row.text(3)),
            .message_key = try allocator.dupe(u8, row.text(4)),
            .ledger = try allocator.dupe(u8, row.text(5)),
            .receipts = try allocator.dupe(u8, row.text(6)),
            .replay_guard = try allocator.dupe(u8, row.text(7)),
        };
    }

    fn deinit(self: LegacyStateSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
        allocator.free(self.thread);
        allocator.free(self.message);
        allocator.free(self.message_key);
        allocator.free(self.ledger);
        allocator.free(self.receipts);
        allocator.free(self.replay_guard);
    }

    fn expectEqual(expected: LegacyStateSnapshot, actual: LegacyStateSnapshot) !void {
        try std.testing.expectEqual(expected.revision, actual.revision);
        try std.testing.expectEqualStrings(expected.workspace, actual.workspace);
        try std.testing.expectEqualStrings(expected.thread, actual.thread);
        try std.testing.expectEqualStrings(expected.message, actual.message);
        try std.testing.expectEqualStrings(expected.message_key, actual.message_key);
        try std.testing.expectEqualStrings(expected.ledger, actual.ledger);
        try std.testing.expectEqualStrings(expected.receipts, actual.receipts);
        try std.testing.expectEqualStrings(expected.replay_guard, actual.replay_guard);
    }
};

fn runLegacyEvidenceAttack(attack: LegacyEvidenceAttack) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("legacy-nonzero-prefix", null),
        .workspace = testWorkspace("legacy-prefix-workspace", "Legacy prefix"),
    });
    var request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:evidence-turn:accept", null),
        .turn_id = "evidence-turn",
        .workspace = testWorkspace("evidence-workspace", "evidence-workspace"),
        .thread = .{ .local_thread_id = "evidence-thread", .title = "Evidence", .provider = "codex" },
        .started_at_ms = 10,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{ .message_id = "evidence-user", .role = "user", .author = "You", .body = "original", .created_at_ms = 10, .updated_at_ms = 10 },
    };
    try seedLegacyStagedAcceptance(&store, request);
    try std.testing.expectEqual(@as(u64, 4), try store.storeRevision());

    switch (attack) {
        .workspace_receipt_revision => try store.conn.exec("update store_receipts set store_revision = 40 where request_key = 'turn:evidence-turn:stage-ws'", .{}),
        .thread_receipt_revision => try store.conn.exec("update store_receipts set store_revision = 40 where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .user_receipt_revision => try store.conn.exec("update store_receipts set store_revision = 40 where request_key = 'turn:evidence-turn:stage-user'", .{}),
        .response_revision => try store.conn.exec("update store_receipts set response_payload = '{\"store_revision\":40,\"applied\":true,\"duplicate\":false}' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .response_applied => try store.conn.exec("update store_receipts set response_payload = '{\"store_revision\":3,\"applied\":false,\"duplicate\":false}' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .response_duplicate => try store.conn.exec("update store_receipts set response_payload = '{\"store_revision\":3,\"applied\":true,\"duplicate\":true}' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .response_status => try store.conn.exec("update store_receipts set response_status = 500 where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .non_contiguous_revisions => {
            try store.conn.exec("update store_receipts set store_revision = 4, response_payload = '{\"store_revision\":4,\"applied\":true,\"duplicate\":false}' where request_key = 'turn:evidence-turn:stage-thread'", .{});
            try store.conn.exec("update store_receipts set store_revision = 5, response_payload = '{\"store_revision\":5,\"applied\":true,\"duplicate\":false}' where request_key = 'turn:evidence-turn:stage-user'", .{});
            try store.conn.exec("update client_message_keys set store_revision = 5 where message_id = 'evidence-user'", .{});
        },
        .client_key_revision => try store.conn.exec("update client_message_keys set store_revision = 40 where message_id = 'evidence-user'", .{}),
        .malformed_response => try store.conn.exec("update store_receipts set response_payload = '{malformed' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .operation => try store.conn.exec("update store_receipts set operation = 'wrong-operation' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .fingerprint => try store.conn.exec("update store_receipts set fingerprint = 'wrong-fingerprint' where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .missing_receipt => try store.conn.exec("delete from store_receipts where request_key = 'turn:evidence-turn:stage-thread'", .{}),
        .provider => {
            request.provider = "claude";
            request.thread.provider = "claude";
        },
        .content => request.user_message.body = "changed",
    }

    const before = try LegacyStateSnapshot.capture(std.testing.allocator, &store);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    const after = try LegacyStateSnapshot.capture(std.testing.allocator, &store);
    defer after.deinit(std.testing.allocator);
    try before.expectEqual(after);
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
    var bound_snapshot = snapshot;
    if (!bootstrap) bound_snapshot.store_revision = expected_store_revision orelse 0;
    return .{
        .mutation = .{
            .request_key = request_key,
            .expected_store_revision = expected_store_revision,
            .client_id = "test-client",
        },
        .snapshot = bound_snapshot,
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

test "repository manifest CRUD is receipt-backed and never deletes checkout data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root_path = root_buf[0..root_len];
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repository-sentinel", .data = "keep" });

    const runtime_id = "0123456789abcdef0123456789abcdef";
    var store = try Store.initWithRuntimeIdentity(std.testing.allocator, db_path, .none, .{
        .runtime_id = runtime_id,
        .instance_id = "fedcba9876543210fedcba9876543210",
    });
    defer store.deinit();

    var workspace = testWorkspace("manifest-workspace", "Manifest workspace");
    workspace.path = root_path;
    _ = try store.upsertWorkspace(testWorkspaceRequest("manifest-workspace", null, workspace));

    var legacy_manifest = try store.loadWorkspaceRepositoryManifest("manifest-workspace");
    defer legacy_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("primary", legacy_manifest.default_repository_id);
    try std.testing.expectEqual(@as(usize, 1), legacy_manifest.repositories.len);
    try std.testing.expectEqualStrings(runtime_id, legacy_manifest.repositories[0].bindings[0].runtime_id);
    try std.testing.expectEqualStrings(root_path, legacy_manifest.repositories[0].bindings[0].root_path);

    _ = try store.upsertWorkspaceRepository(.{
        .mutation = testHeader("repo-api-upsert", 1),
        .workspace_id = "manifest-workspace",
        .repository = .{
            .repository_id = "repo-api",
            .label = "API",
            .vcs_identity = "https://example.com/org/api.git",
            .default_branch = "main",
        },
    });
    _ = try store.upsertWorkspaceRepositoryBinding(.{
        .mutation = testHeader("repo-api-binding", 2),
        .workspace_id = "manifest-workspace",
        .repository_id = "repo-api",
        .binding = .{ .runtime_id = runtime_id, .root_path = root_path },
    });
    _ = try store.setWorkspaceDefaultRepository(.{
        .mutation = testHeader("repo-api-default", 3),
        .workspace_id = "manifest-workspace",
        .repository_id = "repo-api",
    });

    var manifest = try store.loadWorkspaceRepositoryManifest("manifest-workspace");
    defer manifest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("repo-api", manifest.default_repository_id);
    try std.testing.expectEqual(@as(usize, 2), manifest.repositories.len);
    try std.testing.expectEqualStrings("repo-api", manifest.repositories[1].repository_id);
    try std.testing.expectEqualStrings("https://example.com/org/api.git", manifest.repositories[1].vcs_identity.?);
    try std.testing.expectEqualStrings("main", manifest.repositories[1].default_branch.?);
    try std.testing.expectEqualStrings(root_path, manifest.repositories[1].bindings[0].root_path);

    var binding = try store.loadWorkspaceRepositoryBinding("manifest-workspace", "repo-api", runtime_id);
    defer binding.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(root_path, binding.root_path);
    try std.testing.expectEqualStrings("available", binding.availability);

    const remove_binding: WorkspaceRepositoryBindingRemoveRequest = .{
        .mutation = testHeader("repo-api-binding-remove", 4),
        .workspace_id = "manifest-workspace",
        .repository_id = "repo-api",
        .runtime_id = runtime_id,
    };
    const removed = try store.removeWorkspaceRepositoryBinding(remove_binding);
    try std.testing.expectEqual(@as(u64, 5), removed.store_revision);
    const replayed = try store.removeWorkspaceRepositoryBinding(remove_binding);
    try std.testing.expectEqual(@as(u64, 5), replayed.store_revision);
    try std.testing.expectEqual(@as(u64, 5), try store.storeRevision());
    try std.testing.expectError(
        error.ResourceNotFound,
        store.loadWorkspaceRepositoryBinding("manifest-workspace", "repo-api", runtime_id),
    );

    _ = try store.setWorkspaceDefaultRepository(.{
        .mutation = testHeader("primary-default", 5),
        .workspace_id = "manifest-workspace",
        .repository_id = "primary",
    });
    _ = try store.removeWorkspaceRepository(.{
        .mutation = testHeader("repo-api-remove", 6),
        .workspace_id = "manifest-workspace",
        .repository_id = "repo-api",
    });
    _ = try tmp.dir.statFile(std.testing.io, "repository-sentinel", .{});
    var final_manifest = try store.loadWorkspaceRepositoryManifest("manifest-workspace");
    defer final_manifest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), final_manifest.repositories.len);
    try std.testing.expectEqualStrings("primary", final_manifest.repositories[0].repository_id);
}

test "repository persistence rejects credential-shaped identities and broad roots" {
    try std.testing.expect(validVcsIdentity("https://example.com/org/api.git"));
    try std.testing.expect(validVcsIdentity("ssh://git@example.com:22/org/api.git"));
    try std.testing.expect(validVcsIdentity("git@example.com:org/api.git"));
    const rejected_identities = [_][]const u8{
        "https://token@example.com/org/api.git",
        "https://user%3Apass%40example.com/org/api.git",
        "https://example.com:secret/org/api.git",
        "https://example.com/org/api.git?access_token=secret",
        "https://example.com/ghp_secret/repo.git",
        "ssh://ghp_secret@example.com/org/api.git",
        "ghp_secret@example.com:org/api.git",
        "oauth2:secret@gitlab.com:org/api.git",
        "example.com/org/api.git",
    };
    for (rejected_identities) |identity| try std.testing.expect(!validVcsIdentity(identity));

    try std.testing.expect(validAbsoluteRepositoryPath("/srv/verde/api"));
    try std.testing.expect(validAbsoluteRepositoryPath("C:\\src\\api"));
    try std.testing.expect(validAbsoluteRepositoryPath("C:/src/api"));
    try std.testing.expect(validAbsoluteRepositoryPath("\\\\server\\share\\api"));
    const rejected_roots = [_][]const u8{
        "/",
        "C:\\",
        "C:/",
        "\\\\server\\share",
        "relative/repo",
        "/srv/../secret",
        "/srv/repo/",
    };
    for (rejected_roots) |root_path| try std.testing.expect(!validAbsoluteRepositoryPath(root_path));

    try validateRepositoryRelativeCwd(null);
    try validateRepositoryRelativeCwd("services/api");
    try std.testing.expectError(error.InvalidParams, validateRepositoryRelativeCwd("/absolute"));
    try std.testing.expectError(error.InvalidParams, validateRepositoryRelativeCwd("../escape"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    _ = try store.upsertWorkspace(testWorkspaceRequest(
        "credential-workspace",
        null,
        testWorkspace("credential-workspace", "Credential workspace"),
    ));
    for (rejected_identities) |identity| {
        try std.testing.expectError(error.InvalidParams, store.upsertWorkspaceRepository(.{
            .mutation = testHeader("rejected-credential", 1),
            .workspace_id = "credential-workspace",
            .repository = .{ .repository_id = "secret-repo", .label = "Secret", .vcs_identity = identity },
        }));
    }
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());
    var persisted = (try store.conn.row(
        "select count(*) from workspace_repositories where repository_id = 'secret-repo'",
        .{},
    )).?;
    defer persisted.deinit();
    try std.testing.expectEqual(@as(i64, 0), persisted.int(0));
    var receipt = (try store.conn.row(
        "select count(*) from store_receipts where request_key = 'rejected-credential'",
        .{},
    )).?;
    defer receipt.deinit();
    try std.testing.expectEqual(@as(i64, 0), receipt.int(0));
}

test "repository removal preserves referenced thread routes and loader is bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const repositories = [_]store_protocol.Repository{
        .{ .repository_id = "primary", .label = "Primary" },
        .{ .repository_id = "repo-api", .label = "API" },
    };
    var workspace = testWorkspace("referenced-repository-workspace", "Referenced repositories");
    workspace.repositories = &repositories;
    _ = try store.upsertWorkspace(testWorkspaceRequest("referenced-repositories", null, workspace));
    _ = try store.upsertThread(.{
        .mutation = testHeader("referenced-repository-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = .{
            .local_thread_id = "repo-api-thread",
            .title = "API thread",
            .profile_id = "local",
            .repository_id = "repo-api",
        },
    });
    try std.testing.expectError(error.Conflict, store.removeWorkspaceRepository(.{
        .mutation = testHeader("referenced-repository-remove", 2),
        .workspace_id = workspace.workspace_id,
        .repository_id = "repo-api",
    }));
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());

    const workspace_row_id = try store.requireWorkspaceRowId(workspace.workspace_id);
    const repository_row_id = try store.requireRepositoryRowId(workspace_row_id, "repo-api");
    const hex_digits = "0123456789abcdef";
    var runtime_id: [32]u8 = [_]u8{'0'} ** 32;
    for (0..MAX_REPOSITORY_BINDINGS) |index| {
        runtime_id[30] = hex_digits[(index / 16) % 16];
        runtime_id[31] = hex_digits[index % 16];
        try store.conn.exec(
            "insert into workspace_repository_bindings (repository_row_id, runtime_id, root_path, availability) " ++
                "values (?1, ?2, '/srv/verde/repository', 'available')",
            .{ repository_row_id, runtime_id[0..] },
        );
    }
    try std.testing.expectError(error.CapabilityUnavailable, store.upsertWorkspaceRepositoryBinding(.{
        .mutation = testHeader("bounded-binding-upsert", 2),
        .workspace_id = workspace.workspace_id,
        .repository_id = "repo-api",
        .binding = .{
            .runtime_id = "ffffffffffffffffffffffffffffffff",
            .root_path = "/srv/verde/repository",
        },
    }));
    runtime_id[30] = '4';
    runtime_id[31] = '0';
    try store.conn.exec(
        "insert into workspace_repository_bindings (repository_row_id, runtime_id, root_path, availability) " ++
            "values (?1, ?2, '/srv/verde/repository', 'available')",
        .{ repository_row_id, runtime_id[0..] },
    );
    try std.testing.expectError(
        error.StoreCorrupt,
        store.loadWorkspaceRepositoryManifest(workspace.workspace_id),
    );
    try store.conn.exec(
        "delete from workspace_repository_bindings where repository_row_id = ?1",
        .{repository_row_id},
    );

    var id_buf: [32]u8 = undefined;
    for (0..MAX_WORKSPACE_REPOSITORIES - 2) |index| {
        const repository_id = try std.fmt.bufPrint(&id_buf, "overflow-{d}", .{index});
        try store.conn.exec(
            "insert into workspace_repositories (workspace_id, repository_id, sort_index, label) values (?1, ?2, ?3, 'Overflow')",
            .{ workspace_row_id, repository_id, @as(i64, @intCast(index + 2)) },
        );
    }
    try std.testing.expectError(error.CapabilityUnavailable, store.upsertWorkspaceRepository(.{
        .mutation = testHeader("bounded-repository-upsert", 2),
        .workspace_id = workspace.workspace_id,
        .repository = .{ .repository_id = "one-too-many", .label = "Overflow" },
    }));
    try store.conn.exec(
        "insert into workspace_repositories (workspace_id, repository_id, sort_index, label) values (?1, 'one-too-many', ?2, 'Overflow')",
        .{ workspace_row_id, @as(i64, MAX_WORKSPACE_REPOSITORIES) },
    );
    try std.testing.expectError(
        error.StoreCorrupt,
        store.loadWorkspaceRepositoryManifest(workspace.workspace_id),
    );
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
}

test "thread runtime route persists once and committed route rejects drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const route_repositories = [_]store_protocol.Repository{
        .{ .repository_id = "primary", .label = "Primary" },
        .{ .repository_id = "repo-api", .label = "API" },
    };
    var route_workspace = testWorkspace("route-workspace", "Route workspace");
    route_workspace.repositories = &route_repositories;
    _ = try store.upsertWorkspace(testWorkspaceRequest(
        "route-workspace",
        null,
        route_workspace,
    ));
    const draft: store_protocol.Thread = .{
        .local_thread_id = "route-thread",
        .title = "Route thread",
        .committed = false,
        .profile_id = "remote-box",
        .repository_id = "repo-api",
        .repository_cwd = "services/api",
    };
    _ = try store.upsertThread(.{
        .mutation = testHeader("route-draft", 1),
        .workspace_id = "route-workspace",
        .thread = draft,
    });

    var committed = draft;
    committed.committed = true;
    committed.runtime_id = "0123456789abcdef0123456789abcdef";
    _ = try store.upsertThread(.{
        .mutation = testHeader("route-pin", 2),
        .workspace_id = "route-workspace",
        .thread = committed,
    });

    {
        const row = (try store.conn.row(
            "select profile_id, runtime_id, repository_id, repository_cwd from threads where local_thread_id = 'route-thread'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("remote-box", row.text(0));
        try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", row.text(1));
        try std.testing.expectEqualStrings("repo-api", row.text(2));
        try std.testing.expectEqualStrings("services/api", row.text(3));
    }

    var drifted = committed;
    drifted.profile_id = "local";
    try std.testing.expectError(error.InvalidParams, store.upsertThread(.{
        .mutation = testHeader("route-drift", 3),
        .workspace_id = "route-workspace",
        .thread = drifted,
    }));
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    var unlocked = committed;
    unlocked.committed = false;
    try std.testing.expectError(error.InvalidParams, store.upsertThread(.{
        .mutation = testHeader("route-unlock", 3),
        .workspace_id = "route-workspace",
        .thread = unlocked,
    }));
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    const partial: store_protocol.Thread = .{
        .local_thread_id = "partial-route",
        .title = "Partial route",
        .profile_id = "remote-box",
    };
    try std.testing.expectError(error.InvalidParams, store.upsertThread(.{
        .mutation = testHeader("route-partial", 3),
        .workspace_id = "route-workspace",
        .thread = partial,
    }));
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());
}

test "thread runtime route bootstrap cannot replace a nonempty committed store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const route_repositories = [_]store_protocol.Repository{
        .{ .repository_id = "primary", .label = "Primary" },
        .{ .repository_id = "repo-api", .label = "API" },
    };
    var route_workspace = testWorkspace("bootstrap-route-workspace", "Route workspace");
    route_workspace.repositories = &route_repositories;
    _ = try store.upsertWorkspace(testWorkspaceRequest(
        "bootstrap-route-workspace",
        null,
        route_workspace,
    ));
    const committed: store_protocol.Thread = .{
        .local_thread_id = "bootstrap-route-thread",
        .title = "Remote route",
        .committed = true,
        .profile_id = "remote-box",
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .repository_id = "repo-api",
        .repository_cwd = "services/api",
    };
    _ = try store.upsertThread(.{
        .mutation = testHeader("bootstrap-route-thread", 1),
        .workspace_id = "bootstrap-route-workspace",
        .thread = committed,
    });

    const same_threads = [_]store_protocol.Thread{committed};
    const same_workspaces = [_]store_protocol.Workspace{.{
        .workspace_id = "bootstrap-route-workspace",
        .label = "Route workspace",
        .path = "bootstrap-route-workspace",
        .threads = &same_threads,
    }};
    try std.testing.expectError(error.Conflict, store.replaceSnapshot(testSnapshotRequest(
        "late-bootstrap-same-route",
        null,
        true,
        testSnapshot(&same_workspaces),
    )));

    var drifted = committed;
    drifted.profile_id = "other-remote-box";
    const drifted_threads = [_]store_protocol.Thread{drifted};
    const drifted_workspaces = [_]store_protocol.Workspace{.{
        .workspace_id = "bootstrap-route-workspace",
        .label = "Route workspace",
        .path = "bootstrap-route-workspace",
        .threads = &drifted_threads,
    }};
    try std.testing.expectError(error.Conflict, store.replaceSnapshot(testSnapshotRequest(
        "late-bootstrap-drifted-route",
        null,
        true,
        testSnapshot(&drifted_workspaces),
    )));

    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
    const row = (try store.conn.row(
        "select committed, profile_id, runtime_id, repository_id, repository_cwd " ++
            "from threads where local_thread_id = 'bootstrap-route-thread'",
        .{},
    )).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.int(0));
    try std.testing.expectEqualStrings("remote-box", row.text(1));
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", row.text(2));
    try std.testing.expectEqualStrings("repo-api", row.text(3));
    try std.testing.expectEqualStrings("services/api", row.text(4));
}

test "thread runtime route requires stable identity once committed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const routed: store_protocol.Thread = .{
        .local_thread_id = "unpinned-remote-route",
        .title = "Unpinned remote route",
        .committed = true,
        .profile_id = "remote-box",
        .repository_id = "repo-api",
    };
    const routed_threads = [_]store_protocol.Thread{routed};
    const routed_workspaces = [_]store_protocol.Workspace{.{
        .workspace_id = "unpinned-workspace",
        .label = "Unpinned workspace",
        .path = "unpinned-workspace",
        .threads = &routed_threads,
    }};
    try std.testing.expectError(error.InvalidParams, store.replaceSnapshot(testSnapshotRequest(
        "unpinned-bootstrap",
        null,
        true,
        testSnapshot(&routed_workspaces),
    )));
    try std.testing.expectEqual(@as(u64, 0), try store.storeRevision());

    // The exact all-null route is the sole compatibility exception for a
    // committed pre-routing thread without a stable public identity.
    const legacy: store_protocol.Thread = .{
        .local_thread_id = "",
        .title = "Legacy local route",
        .committed = true,
    };
    const explicit_local: store_protocol.Thread = .{
        .local_thread_id = "explicit-local-route",
        .title = "Explicit local route",
        .committed = true,
        .profile_id = "local",
        .repository_id = "primary",
    };
    const legacy_threads = [_]store_protocol.Thread{ legacy, explicit_local };
    const legacy_workspaces = [_]store_protocol.Workspace{.{
        .workspace_id = "legacy-workspace",
        .label = "Legacy workspace",
        .path = "legacy-workspace",
        .threads = &legacy_threads,
    }};
    _ = try store.replaceSnapshot(testSnapshotRequest(
        "legacy-bootstrap",
        null,
        true,
        testSnapshot(&legacy_workspaces),
    ));
    const row = (try store.conn.row(
        "select local_thread_id, profile_id, runtime_id, repository_id, repository_cwd from threads where sort_index = 0",
        .{},
    )).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("", row.text(0));
    try std.testing.expect(row.nullableText(1) == null);
    try std.testing.expect(row.nullableText(2) == null);
    try std.testing.expect(row.nullableText(3) == null);
    try std.testing.expect(row.nullableText(4) == null);
    const explicit_row = (try store.conn.row(
        "select profile_id, runtime_id, repository_id from threads where local_thread_id = 'explicit-local-route'",
        .{},
    )).?;
    defer explicit_row.deinit();
    try std.testing.expectEqualStrings("local", explicit_row.text(0));
    try std.testing.expect(explicit_row.nullableText(1) == null);
    try std.testing.expectEqualStrings("primary", explicit_row.text(2));
}

test "committed non-local route without runtime pin stays quarantined" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const route_repositories = [_]store_protocol.Repository{
        .{ .repository_id = "primary", .label = "Primary" },
        .{ .repository_id = "repo-api", .label = "API" },
    };
    var route_workspace = testWorkspace("quarantined-pin-workspace", "Quarantined pin workspace");
    route_workspace.repositories = &route_repositories;
    _ = try store.upsertWorkspace(testWorkspaceRequest(
        "quarantined-pin-workspace",
        null,
        route_workspace,
    ));
    const draft: store_protocol.Thread = .{
        .local_thread_id = "quarantined-pin-thread",
        .title = "Quarantined remote route",
        .committed = false,
        .profile_id = "remote-box",
        .repository_id = "repo-api",
    };
    _ = try store.upsertThread(.{
        .mutation = testHeader("quarantined-pin-draft", 1),
        .workspace_id = "quarantined-pin-workspace",
        .thread = draft,
    });
    // Manufacture the pre-fix committed shape without the production API.
    try store.conn.execNoArgs(
        "update threads set committed = 1 where local_thread_id = 'quarantined-pin-thread'",
    );

    var attempted_pin = draft;
    attempted_pin.committed = true;
    attempted_pin.runtime_id = "0123456789abcdef0123456789abcdef";
    try std.testing.expectError(error.InvalidParams, store.upsertThread(.{
        .mutation = testHeader("quarantined-pin-attempt", 2),
        .workspace_id = "quarantined-pin-workspace",
        .thread = attempted_pin,
    }));
    try std.testing.expectEqual(@as(u64, 2), try store.storeRevision());
    const row = (try store.conn.row(
        "select committed, runtime_id from threads where local_thread_id = 'quarantined-pin-thread'",
        .{},
    )).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.int(0));
    try std.testing.expect(row.nullableText(1) == null);
}

test "thread runtime route quarantine prevents null identity reconcile deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    _ = try store.upsertWorkspace(testWorkspaceRequest(
        "quarantine-workspace",
        null,
        testWorkspace("quarantine-workspace", "Quarantine workspace"),
    ));
    try store.conn.exec(
        \\insert into threads (
        \\    workspace_id, sort_index, title, committed, local_thread_id,
        \\    provider, harness, profile_id, runtime_id, repository_id, repository_cwd
        \\)
        \\select id, 0, 'Opaque remote route', 1, null, ?2, ?3,
        \\       'remote-box', '0123456789abcdef0123456789abcdef', 'repo-api', 'services/api'
        \\from workspaces where workspace_id = ?1
    , .{ "quarantine-workspace", try providerCode("codex"), try harnessCode("local_cli") });

    const workspaces = [_]store_protocol.Workspace{
        testWorkspace("quarantine-workspace", "Quarantine workspace"),
    };
    try std.testing.expectError(error.InvalidParams, store.replaceSnapshot(testSnapshotRequest(
        "quarantine-reconcile",
        1,
        false,
        testSnapshot(&workspaces),
    )));
    try std.testing.expectEqual(@as(u64, 1), try store.storeRevision());
    const row = (try store.conn.row(
        "select profile_id, runtime_id, repository_id, repository_cwd from threads " ++
            "where local_thread_id is null",
        .{},
    )).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("remote-box", row.text(0));
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", row.text(1));
    try std.testing.expectEqualStrings("repo-api", row.text(2));
    try std.testing.expectEqualStrings("services/api", row.text(3));
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

test "daemon writes the shipped chat role codes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-role-codec", "Role codec");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("role-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-role-codec", "Role codec");
    _ = try store.upsertThread(.{
        .mutation = testHeader("role-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const messages = [_]store_protocol.Message{
        .{ .message_id = "role-user", .role = "user", .author = "You", .body = "user" },
        .{ .message_id = "role-assistant", .role = "assistant", .author = "Assistant", .body = "assistant" },
        .{ .message_id = "role-system", .role = "system", .author = "System", .body = "system" },
    };
    _ = try store.commitTurn(.{
        .turn_id = "turn-role-codec",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .messages = &messages,
    });

    const expected = [_]i64{ 0, 1, 2 };
    var rows = try store.conn.rows(
        "select role from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
        .{thread.local_thread_id},
    );
    defer rows.deinit();
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(expected[index], row.int(0));
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(expected.len, index);
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
    try std.testing.expect(!replay.applied);
    try std.testing.expect(replay.duplicate);
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    var replay_rows = (try store.conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer replay_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), replay_rows.int(0));
}

test "daemon chat turn ownership preserves workspace layout identity and composer draft" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("turn-owner-workspace", null),
        .workspace = .{
            .workspace_id = "workspace-owner",
            .label = "Friendly workspace",
            .path = "/tmp/friendly-workspace",
            .workspace_layout_json = "{\"version\":2,\"focused\":42}",
            .selected_thread_index = 1,
        },
    });
    _ = try store.upsertThread(.{
        .mutation = testHeader("turn-owner-thread", 1),
        .workspace_id = "workspace-owner",
        .thread = .{
            .local_thread_id = "thread-owner",
            .title = "Friendly thread",
            .draft = "unsent independent draft",
        },
    });

    _ = try store.acceptTurn(.{
        .mutation = testHeader("turn-owner-accept", 2),
        .turn_id = "turn-owner",
        .workspace = .{
            .workspace_id = "workspace-owner",
            .label = "workspace-owner",
            .path = "/tmp/friendly-workspace",
        },
        .thread = .{
            .local_thread_id = "thread-owner",
            .title = "Daemon turn title",
            .provider = "codex",
            .provider_thread_id = "provider-owner",
        },
        .started_at_ms = 100,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = "provider-owner",
        .user_message = .{
            .message_id = "turn-owner-user",
            .role = "user",
            .author = "You",
            .body = "hello",
        },
    });

    {
        const workspace_row = (try store.conn.row(
            "select label, path, workspace_layout_json, selected_thread_index from workspaces where workspace_id = ?1",
            .{"workspace-owner"},
        )).?;
        defer workspace_row.deinit();
        try std.testing.expectEqualStrings("Friendly workspace", workspace_row.text(0));
        try std.testing.expectEqualStrings("/tmp/friendly-workspace", workspace_row.text(1));
        try std.testing.expectEqualStrings("{\"version\":2,\"focused\":42}", workspace_row.text(2));
        try std.testing.expectEqual(@as(i64, 1), workspace_row.int(3));
    }

    {
        const thread_row = (try store.conn.row(
            "select title, draft from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
            .{ "workspace-owner", "thread-owner" },
        )).?;
        defer thread_row.deinit();
        try std.testing.expectEqualStrings("Friendly thread", thread_row.text(0));
        try std.testing.expectEqualStrings("unsent independent draft", thread_row.text(1));
    }

    _ = try store.commitTurn(.{
        .turn_id = "turn-owner",
        .workspace_id = "workspace-owner",
        .local_thread_id = "thread-owner",
        .status = .completed,
        .started_at_ms = 100,
        .finished_at_ms = 200,
        .provider = "codex",
        .provider_thread_id = "provider-owner",
        .messages = &.{},
        .client_id = "daemon",
    });
    const committed_thread_row = (try store.conn.row(
        "select provider_thread_id, draft from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
        .{ "workspace-owner", "thread-owner" },
    )).?;
    defer committed_thread_row.deinit();
    try std.testing.expectEqualStrings("provider-owner", committed_thread_row.text(0));
    try std.testing.expectEqualStrings("unsent independent draft", committed_thread_row.text(1));
}

test "protocol 19 staged acceptance upgrades atomically and replays without owner repair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:upgrade-turn:accept", null),
        .turn_id = "upgrade-turn",
        .workspace = testWorkspace("upgrade-workspace", "upgrade-workspace"),
        .thread = .{
            .local_thread_id = "upgrade-thread",
            .title = "Upgrade thread",
            .provider = "codex",
            .provider_thread_id = "provider-upgrade",
        },
        .started_at_ms = 100,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = "provider-upgrade",
        .user_message = .{
            .message_id = "upgrade-user",
            .role = "user",
            .author = "You",
            .body = "resume exactly once",
            .created_at_ms = 100,
            .updated_at_ms = 100,
        },
    };
    try seedLegacyStagedAcceptance(&store, request);
    const legacy_shape = (try store.conn.row(
        "select t.provider_thread_id, c.provider_thread_id, c.committed_store_revision, c.status, " ++
            "m.image_path, m.image_mime, m.image_byte_size, m.created_at_ms, m.updated_at_ms, " ++
            "(select count(*) from store_receipts) " ++
            "from threads t join workspaces w on w.id = t.workspace_id " ++
            "join chat_turns c on c.workspace_id = w.workspace_id and c.local_thread_id = t.local_thread_id " ++
            "join messages m on m.thread_id = t.id where c.turn_id = ?1",
        .{request.turn_id},
    )).?;
    defer legacy_shape.deinit();
    try std.testing.expect(legacy_shape.nullableText(0) == null);
    try std.testing.expect(legacy_shape.nullableText(1) == null);
    try std.testing.expect(legacy_shape.nullableInt(2) == null);
    try std.testing.expectEqualStrings("interrupted", legacy_shape.text(3));
    try std.testing.expect(legacy_shape.nullableText(4) == null);
    try std.testing.expect(legacy_shape.nullableText(5) == null);
    try std.testing.expect(legacy_shape.nullableInt(6) == null);
    try std.testing.expectEqual(@as(i64, 100), legacy_shape.int(7));
    try std.testing.expectEqual(@as(i64, 100), legacy_shape.int(8));
    try std.testing.expectEqual(@as(i64, 3), legacy_shape.int(9));

    const Counter = struct {
        count: usize = 0,
        inserted: TurnOwnerInsertions = .{},
        revision: u64 = 0,

        fn mutation(_: *anyopaque, _: *const Mutation, _: store_protocol.WriteResult) void {}
        fn turn(_: *anyopaque, _: *const TurnCommitRequest, _: TurnOwnerInsertions, _: store_protocol.WriteResult) void {}
        fn acceptance(context: *anyopaque, _: *const TurnAcceptanceRequest, inserted: TurnOwnerInsertions, result: store_protocol.WriteResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.inserted = inserted;
            self.revision = result.store_revision;
        }
    };
    var counter: Counter = .{};
    store.commit_hook = .{
        .context = &counter,
        .on_mutation_committed = Counter.mutation,
        .on_turn_committed = Counter.turn,
        .on_acceptance_committed = Counter.acceptance,
    };

    const accepted = try store.acceptTurn(request);
    try std.testing.expect(accepted.applied);
    try std.testing.expectEqual(@as(u64, 4), accepted.store_revision);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expect(!counter.inserted.workspace and !counter.inserted.thread);
    try std.testing.expectEqual(accepted.store_revision, counter.revision);
    const durable = (try store.conn.row(
        "select (select count(*) from messages), (select count(*) from client_message_keys), " ++
            "(select count(*) from store_receipts), c.status, c.committed_store_revision, m.body, m.created_at_ms " ++
            "from chat_turns c join messages m on m.message_id = c.user_message_id where c.turn_id = ?1",
        .{request.turn_id},
    )).?;
    defer durable.deinit();
    try std.testing.expectEqual(@as(i64, 1), durable.int(0));
    try std.testing.expectEqual(@as(i64, 1), durable.int(1));
    try std.testing.expectEqual(@as(i64, 4), durable.int(2));
    try std.testing.expectEqualStrings("running", durable.text(3));
    try std.testing.expectEqual(@as(i64, 4), durable.int(4));
    try std.testing.expectEqualStrings("resume exactly once", durable.text(5));
    try std.testing.expectEqual(@as(i64, 100), durable.int(6));
    const durable_image = (try store.conn.row(
        "select image_path, image_mime, image_byte_size from messages where message_id = ?1",
        .{request.user_message.message_id},
    )).?;
    defer durable_image.deinit();
    try std.testing.expect(durable_image.nullableText(0) == null);
    try std.testing.expect(durable_image.nullableText(1) == null);
    try std.testing.expect(durable_image.nullableInt(2) == null);

    const replay = try store.acceptTurn(request);
    try std.testing.expect(replay.duplicate and !replay.applied);
    try std.testing.expectEqual(accepted.store_revision, replay.store_revision);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try store.conn.exec("delete from workspaces where workspace_id = ?1", .{request.workspace.workspace_id});
    const replay_after_delete = try store.acceptTurn(request);
    try std.testing.expect(replay_after_delete.duplicate);
    const owner_count = (try store.conn.row("select count(*) from workspaces", .{})).?;
    defer owner_count.deinit();
    try std.testing.expectEqual(@as(i64, 0), owner_count.int(0));
}

test "protocol 19 staged acceptance upgrades with null continuing provider thread" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:null-provider-upgrade:accept", null),
        .turn_id = "null-provider-upgrade",
        .workspace = testWorkspace("null-provider-workspace", "null-provider-workspace"),
        .thread = .{ .local_thread_id = "null-provider-thread", .title = "Null provider thread", .provider = "codex" },
        .started_at_ms = 44,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = null,
        .user_message = .{
            .message_id = "null-provider-user",
            .role = "user",
            .author = "You",
            .body = "resume without a provider thread",
            .created_at_ms = 144,
            .updated_at_ms = 145,
        },
    };
    try seedLegacyStagedAcceptance(&store, request);

    const accepted = try store.acceptTurn(request);
    try std.testing.expect(accepted.applied);
    try std.testing.expectEqual(@as(u64, 4), accepted.store_revision);
    const durable = (try store.conn.row(
        "select c.provider_thread_id, m.image_path, m.created_at_ms, " ++
            "(select count(*) from messages), (select count(*) from client_message_keys) " ++
            "from chat_turns c join messages m on m.message_id = c.user_message_id where c.turn_id = ?1",
        .{request.turn_id},
    )).?;
    defer durable.deinit();
    try std.testing.expect(durable.nullableText(0) == null);
    try std.testing.expect(durable.nullableText(1) == null);
    try std.testing.expectEqual(@as(i64, 44), durable.int(2));
    try std.testing.expectEqual(@as(i64, 1), durable.int(3));
    try std.testing.expectEqual(@as(i64, 1), durable.int(4));
}

test "new acceptance replay binds immutable user content but permits timestamp drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:identity:accept", null),
        .turn_id = "identity-turn",
        .workspace = testWorkspace("identity-workspace", "Identity workspace"),
        .thread = .{ .local_thread_id = "identity-thread", .title = "Identity thread", .provider = "codex" },
        .started_at_ms = 70,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "identity-user",
            .role = "user",
            .author = "You",
            .body = "first writer prompt",
            .image = .{ .path = "/tmp/identity.png", .mime = "image/png", .byte_size = 17 },
            .created_at_ms = 70,
            .updated_at_ms = 71,
        },
    };
    const accepted = try store.acceptTurn(request);

    var timestamp_drift = request;
    timestamp_drift.user_message.created_at_ms = 700;
    timestamp_drift.user_message.updated_at_ms = 701;
    const replay = try store.acceptTurn(timestamp_drift);
    try std.testing.expect(replay.duplicate and !replay.applied);
    try std.testing.expectEqual(accepted.store_revision, replay.store_revision);

    var changed_role = request;
    changed_role.user_message.role = "assistant";
    try std.testing.expectError(error.Conflict, store.acceptTurn(changed_role));
    var changed_author = request;
    changed_author.user_message.author = "Someone else";
    try std.testing.expectError(error.Conflict, store.acceptTurn(changed_author));
    var changed_body = request;
    changed_body.user_message.body = "second writer prompt";
    try std.testing.expectError(error.Conflict, store.acceptTurn(changed_body));
    var changed_attachment = request;
    changed_attachment.user_message.image = .{ .path = "/tmp/changed.png", .mime = "image/png", .byte_size = 17 };
    try std.testing.expectError(error.Conflict, store.acceptTurn(changed_attachment));

    const unchanged = (try store.conn.row(
        "select (select store_revision from store_state where id = 1), " ++
            "(select count(*) from messages), (select count(*) from client_message_keys), " ++
            "(select count(*) from store_receipts), m.role, m.author, m.body, m.image_path, m.created_at_ms, m.updated_at_ms " ++
            "from messages m where m.message_id = ?1",
        .{request.user_message.message_id},
    )).?;
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(0));
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(1));
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(2));
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(3));
    try std.testing.expectEqual(@as(i64, 0), unchanged.int(4));
    try std.testing.expectEqualStrings("You", unchanged.text(5));
    try std.testing.expectEqualStrings("first writer prompt", unchanged.text(6));
    try std.testing.expectEqualStrings("/tmp/identity.png", unchanged.text(7));
    try std.testing.expectEqual(@as(i64, 70), unchanged.int(8));
    try std.testing.expectEqual(@as(i64, 71), unchanged.int(9));
}

test "protocol 19 staged acceptance rejects mismatched provenance without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:mismatch-turn:accept", null),
        .turn_id = "mismatch-turn",
        .workspace = testWorkspace("mismatch-workspace", "mismatch-workspace"),
        .thread = .{ .local_thread_id = "mismatch-thread", .title = "Mismatch", .provider = "codex" },
        .started_at_ms = 10,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{ .message_id = "mismatch-user", .role = "user", .author = "You", .body = "original", .created_at_ms = 10 },
    };
    try seedLegacyStagedAcceptance(&store, request);

    var body_mismatch = request;
    body_mismatch.user_message.body = "coincidental replacement";
    try std.testing.expectError(error.Conflict, store.acceptTurn(body_mismatch));
    try std.testing.expectEqual(@as(u64, 3), try store.storeRevision());

    var provider_mismatch = request;
    provider_mismatch.provider = "claude";
    provider_mismatch.thread.provider = "claude";
    try std.testing.expectError(error.Conflict, store.acceptTurn(provider_mismatch));
    var harness_mismatch = request;
    harness_mismatch.harness = "remote_session";
    harness_mismatch.thread.harness = "remote_session";
    try std.testing.expectError(error.Conflict, store.acceptTurn(harness_mismatch));

    try store.conn.exec("update chat_turns set provider_thread_id = 'forged-provider-thread' where turn_id = ?1", .{request.turn_id});
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    try store.conn.exec("update chat_turns set provider_thread_id = null where turn_id = ?1", .{request.turn_id});

    try store.conn.exec("update client_message_keys set message_id = 'wrong-client-key-owner' where message_id = ?1", .{request.user_message.message_id});
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    try store.conn.exec("update client_message_keys set message_id = ?1 where message_id = 'wrong-client-key-owner'", .{request.user_message.message_id});

    var turn_mismatch = request;
    turn_mismatch.turn_id = "coincidental-turn";
    turn_mismatch.mutation.request_key = "turn:coincidental-turn:accept";
    try std.testing.expectError(error.Conflict, store.acceptTurn(turn_mismatch));

    try store.conn.exec("update chat_turns set workspace_id = 'other-workspace' where turn_id = ?1", .{request.turn_id});
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    try store.conn.exec("update chat_turns set workspace_id = ?1 where turn_id = ?2", .{ request.workspace.workspace_id, request.turn_id });

    try store.conn.exec("update store_receipts set operation = 'wrong-owner' where request_key = 'turn:mismatch-turn:stage-thread'", .{});
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    try store.conn.exec("update store_receipts set operation = ?1 where request_key = 'turn:mismatch-turn:stage-thread'", .{THREAD_UPSERT_OPERATION});
    try store.conn.exec("delete from store_receipts where request_key = 'turn:mismatch-turn:stage-user'", .{});
    try std.testing.expectError(error.Conflict, store.acceptTurn(request));
    const unchanged = (try store.conn.row(
        "select (select store_revision from store_state where id = 1), " ++
            "(select count(*) from store_receipts where request_key = ?1), status, " ++
            "(select count(*) from messages), (select count(*) from client_message_keys) " ++
            "from chat_turns where turn_id = ?2",
        .{ request.mutation.request_key, request.turn_id },
    )).?;
    defer unchanged.deinit();
    try std.testing.expectEqual(@as(i64, 3), unchanged.int(0));
    try std.testing.expectEqual(@as(i64, 0), unchanged.int(1));
    try std.testing.expectEqualStrings("interrupted", unchanged.text(2));
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(3));
    try std.testing.expectEqual(@as(i64, 1), unchanged.int(4));
}

test "protocol 19 legacy receipt evidence is strict at a nonzero starting revision" {
    for (std.enums.values(LegacyEvidenceAttack)) |attack| {
        try runLegacyEvidenceAttack(attack);
    }
}

test "protocol 19 staged acceptance rollback retains first writer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const Counter = struct {
        count: usize = 0,
        fn mutation(_: *anyopaque, _: *const Mutation, _: store_protocol.WriteResult) void {}
        fn turn(_: *anyopaque, _: *const TurnCommitRequest, _: TurnOwnerInsertions, _: store_protocol.WriteResult) void {}
        fn acceptance(context: *anyopaque, _: *const TurnAcceptanceRequest, _: TurnOwnerInsertions, _: store_protocol.WriteResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var counter: Counter = .{};
    store.commit_hook = .{
        .context = &counter,
        .on_mutation_committed = Counter.mutation,
        .on_turn_committed = Counter.turn,
        .on_acceptance_committed = Counter.acceptance,
    };
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:rollback-upgrade:accept", null),
        .turn_id = "rollback-upgrade",
        .workspace = testWorkspace("rollback-upgrade-workspace", "rollback-upgrade-workspace"),
        .thread = .{ .local_thread_id = "rollback-upgrade-thread", .title = "Rollback", .provider = "codex" },
        .started_at_ms = 20,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{ .message_id = "rollback-upgrade-user", .role = "user", .author = "You", .body = "keep me", .created_at_ms = 20 },
    };
    try seedLegacyStagedAcceptance(&store, request);
    try store.conn.exec(
        "update threads set provider = 0 where local_thread_id = ?1",
        .{request.thread.local_thread_id},
    );
    store.acceptance_test_fail_before_revision = true;
    try std.testing.expectError(error.Internal, store.acceptTurn(request));
    store.acceptance_test_fail_before_revision = false;
    const retained = (try store.conn.row(
        "select (select store_revision from store_state where id = 1), t.provider, c.status, c.committed_store_revision, " ++
            "(select count(*) from messages where message_id = ?1), (select count(*) from store_receipts where request_key = ?2) " ++
            "from threads t join chat_turns c on c.local_thread_id = t.local_thread_id where c.turn_id = ?3",
        .{ request.user_message.message_id, request.mutation.request_key, request.turn_id },
    )).?;
    defer retained.deinit();
    try std.testing.expectEqual(@as(i64, 3), retained.int(0));
    try std.testing.expectEqual(@as(i64, 0), retained.int(1));
    try std.testing.expectEqualStrings("interrupted", retained.text(2));
    try std.testing.expect(retained.nullableInt(3) == null);
    try std.testing.expectEqual(@as(i64, 1), retained.int(4));
    try std.testing.expectEqual(@as(i64, 0), retained.int(5));
    try std.testing.expectEqual(@as(usize, 0), counter.count);
}

test "turn acceptance atomically creates owners journals one revision and replays before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const Counter = struct {
        count: usize = 0,
        inserted: TurnOwnerInsertions = .{},
        revision: u64 = 0,
        fn mutation(_: *anyopaque, _: *const Mutation, _: store_protocol.WriteResult) void {}
        fn turn(_: *anyopaque, _: *const TurnCommitRequest, _: TurnOwnerInsertions, _: store_protocol.WriteResult) void {}
        fn acceptance(context: *anyopaque, _: *const TurnAcceptanceRequest, inserted: TurnOwnerInsertions, result: store_protocol.WriteResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.inserted = inserted;
            self.revision = result.store_revision;
        }
    };
    var counter: Counter = .{};
    store.commit_hook = .{
        .context = &counter,
        .on_mutation_committed = Counter.mutation,
        .on_turn_committed = Counter.turn,
        .on_acceptance_committed = Counter.acceptance,
    };
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("missing-owner-accept", 0),
        .turn_id = "missing-owner-turn",
        .workspace = testWorkspace("missing-owner-workspace", "Missing owner"),
        .thread = .{
            .local_thread_id = "missing-owner-thread",
            .title = "Missing owner thread",
            .provider = "codex",
            .model_ref = "gpt-5.6-sol",
            .reasoning_effort = "medium",
            .fast_mode = "off",
            .access_mode = "full_access",
        },
        .started_at_ms = 10,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "missing-owner-user",
            .role = "user",
            .author = "You",
            .body = "accepted",
        },
    };
    const accepted = try store.acceptTurn(request);
    try std.testing.expectEqual(@as(u64, 1), accepted.store_revision);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expect(counter.inserted.workspace);
    try std.testing.expect(counter.inserted.thread);
    try std.testing.expectEqual(accepted.store_revision, counter.revision);
    const durable = (try store.conn.row(
        "select (select count(*) from workspaces), (select count(*) from threads), (select count(*) from messages), (select count(*) from chat_turns), " ++
            "t.model_ref, t.reasoning_effort, t.fast_mode, t.access_mode from threads t where t.local_thread_id = ?1",
        .{request.thread.local_thread_id},
    )).?;
    defer durable.deinit();
    try std.testing.expectEqual(@as(i64, 1), durable.int(0));
    try std.testing.expectEqual(@as(i64, 1), durable.int(1));
    try std.testing.expectEqual(@as(i64, 1), durable.int(2));
    try std.testing.expectEqual(@as(i64, 1), durable.int(3));
    try std.testing.expectEqualStrings("gpt-5.6-sol", durable.text(4));
    try std.testing.expectEqual(@as(i64, 1), durable.int(5));
    try std.testing.expectEqual(@as(i64, 0), durable.int(6));
    try std.testing.expectEqual(@as(i64, 0), durable.int(7));

    // Simulate an external deletion after the accepted receipt. Even with a
    // now-stale expected revision, receipt replay must be completely inert.
    try store.conn.exec("delete from workspaces where workspace_id = ?1", .{request.workspace.workspace_id});
    const replay = try store.acceptTurn(request);
    try std.testing.expect(replay.duplicate);
    try std.testing.expect(!replay.applied);
    try std.testing.expectEqual(accepted.store_revision, replay.store_revision);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    const after_replay = (try store.conn.row("select count(*) from workspaces", .{})).?;
    defer after_replay.deinit();
    try std.testing.expectEqual(@as(i64, 0), after_replay.int(0));
}

test "turn acceptance failure rolls back missing owners receipt ledger and revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    try std.testing.expectError(error.InvalidParams, store.acceptTurn(.{
        .mutation = testHeader("rollback-accept", 0),
        .turn_id = "rollback-turn",
        .workspace = testWorkspace("rollback-workspace", "Rollback"),
        .thread = .{ .local_thread_id = "rollback-thread", .title = "Rollback", .provider = "codex" },
        .started_at_ms = 1,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "rollback-user",
            .role = "not-a-role",
            .author = "You",
            .body = "must roll back",
        },
    }));
    try std.testing.expectEqual(@as(u64, 0), try store.storeRevision());
    const counts = (try store.conn.row(
        "select (select count(*) from workspaces), (select count(*) from threads), (select count(*) from messages), (select count(*) from chat_turns), (select count(*) from store_receipts)",
        .{},
    )).?;
    defer counts.deinit();
    var index: usize = 0;
    while (index < 5) : (index += 1) try std.testing.expectEqual(@as(i64, 0), counts.int(index));
}

test "turn acceptance provider switch clears stale identity without touching GUI metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("switch-workspace", null),
        .workspace = testWorkspace("switch-workspace", "Friendly switch"),
    });
    _ = try store.upsertThread(.{
        .mutation = testHeader("switch-thread", 1),
        .workspace_id = "switch-workspace",
        .thread = .{
            .local_thread_id = "switch-thread",
            .title = "User title",
            .provider = "opencode",
            .harness = "remote_session",
            .provider_thread_id = "stale-provider-thread",
            .draft = "independent draft",
        },
    });
    _ = try store.acceptTurn(.{
        .mutation = testHeader("switch-accept", 2),
        .turn_id = "switch-turn",
        .workspace = testWorkspace("switch-workspace", "placeholder"),
        .thread = .{ .local_thread_id = "switch-thread", .title = "placeholder", .provider = "codex", .harness = "local_cli" },
        .started_at_ms = 3,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = null,
        .user_message = .{ .message_id = "switch-user", .role = "user", .author = "You", .body = "switch" },
    });
    const row = (try store.conn.row(
        "select t.title, t.draft, t.provider, t.harness, t.provider_thread_id, c.provider, c.provider_thread_id " ++
            "from threads t join workspaces w on w.id = t.workspace_id join chat_turns c on c.workspace_id = w.workspace_id and c.local_thread_id = t.local_thread_id " ++
            "where w.workspace_id = ?1 and t.local_thread_id = ?2",
        .{ "switch-workspace", "switch-thread" },
    )).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("User title", row.text(0));
    try std.testing.expectEqualStrings("independent draft", row.text(1));
    try std.testing.expectEqual(@as(i64, 1), row.int(2));
    try std.testing.expectEqual(@as(i64, 0), row.int(3));
    try std.testing.expect(row.nullableText(4) == null);
    try std.testing.expectEqualStrings("codex", row.text(5));
    try std.testing.expect(row.nullableText(6) == null);

    _ = try store.commitTurn(.{
        .turn_id = "switch-turn",
        .workspace_id = "switch-workspace",
        .local_thread_id = "switch-thread",
        .status = .failed,
        .started_at_ms = 3,
        .finished_at_ms = 4,
        .provider = "codex",
        .harness = "local_cli",
        .provider_thread_id = null,
        .error_message = "failed before provider identity",
    });
    const failed = (try store.conn.row(
        "select t.provider_thread_id, c.provider_thread_id, c.status from threads t join workspaces w on w.id = t.workspace_id join chat_turns c on c.workspace_id = w.workspace_id and c.local_thread_id = t.local_thread_id where c.turn_id = ?1",
        .{"switch-turn"},
    )).?;
    defer failed.deinit();
    try std.testing.expect(failed.nullableText(0) == null);
    try std.testing.expect(failed.nullableText(1) == null);
    try std.testing.expectEqualStrings("failed", failed.text(2));
}

test "daemon turn titles commit the first prompt and preserve later manual renames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const workspace = testWorkspace("workspace-title", "Title workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("title-workspace", null),
        .workspace = workspace,
    });
    _ = try store.upsertThread(.{
        .mutation = testHeader("title-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = testThread("thread-title", "New thread"),
    });

    const acceptance: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:title:accept", 2),
        .turn_id = "turn-title",
        .workspace = workspace,
        .thread = .{ .local_thread_id = "thread-title", .title = "Explain durable chat titles", .provider = "codex" },
        .started_at_ms = 10,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "title-user",
            .role = "user",
            .author = "You",
            .body = "Explain durable chat titles",
        },
    };
    _ = try store.acceptTurn(acceptance);
    try std.testing.expect(try store.canGenerateAutomaticTitle(
        workspace.workspace_id,
        "thread-title",
        "Explain durable chat titles",
    ));
    var fallback = (try store.conn.row(
        "select title, committed from threads where local_thread_id = ?1",
        .{"thread-title"},
    )).?;
    defer fallback.deinit();
    try std.testing.expectEqualStrings("Explain durable chat titles", fallback.text(0));
    try std.testing.expectEqual(@as(i64, 1), fallback.int(1));

    _ = try store.commitTurn(.{
        .turn_id = "turn-title",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = "thread-title",
        .status = .completed,
        .started_at_ms = 10,
        .finished_at_ms = 20,
        .provider = "codex",
        .expected_thread_title = "Explain durable chat titles",
        .generated_title = "Durable Chat Titles",
    });
    try std.testing.expect(try store.threadTitleEquals(workspace.workspace_id, "thread-title", "Durable Chat Titles"));

    _ = try store.upsertThread(.{
        .mutation = testHeader("manual-title", 4),
        .workspace_id = workspace.workspace_id,
        .thread = testThread("thread-title", "My Manual Title"),
    });
    _ = try store.commitTurn(.{
        .turn_id = "turn-title-second",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = "thread-title",
        .status = .completed,
        .started_at_ms = 30,
        .finished_at_ms = 40,
        .provider = "opencode",
        .expected_thread_title = "Durable Chat Titles",
        .generated_title = "Should Not Win",
    });
    try std.testing.expect(try store.threadTitleEquals(workspace.workspace_id, "thread-title", "My Manual Title"));

    _ = try store.upsertThread(.{
        .mutation = testHeader("historical-title-thread", null),
        .workspace_id = workspace.workspace_id,
        .thread = testThread("thread-historical-title", "New Chat"),
    });
    _ = try store.appendMessage(.{
        .mutation = testHeader("historical-title-message", null),
        .workspace_id = workspace.workspace_id,
        .thread_id = "thread-historical-title",
        .message = .{
            .message_id = "historical-title-user",
            .role = "user",
            .author = "You",
            .body = "Original prompt",
        },
    });
    _ = try store.acceptTurn(.{
        .mutation = testHeader("historical-title-accept", null),
        .turn_id = "historical-title-turn",
        .workspace = workspace,
        .thread = .{ .local_thread_id = "thread-historical-title", .title = "Later prompt", .provider = "codex" },
        .started_at_ms = 50,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "historical-title-later-user",
            .role = "user",
            .author = "You",
            .body = "Later prompt",
        },
    });
    try std.testing.expect(try store.threadTitleEquals(workspace.workspace_id, "thread-historical-title", "New Chat"));
}

test "terminal turn missing-owner failure rolls back and replay cannot resurrect owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const bad_messages = [_]store_protocol.Message{.{
        .message_id = "commit-bad-message",
        .role = "invalid-role",
        .author = "System",
        .body = "rollback",
    }};
    const base: TurnCommitRequest = .{
        .turn_id = "commit-missing-turn",
        .workspace_id = "commit-missing-workspace",
        .local_thread_id = "commit-missing-thread",
        .status = .failed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .harness = "local_cli",
        .workspace = testWorkspace("commit-missing-workspace", "Commit missing"),
        .thread = .{ .local_thread_id = "commit-missing-thread", .title = "Commit missing", .provider = "codex" },
        .messages = &bad_messages,
    };
    try std.testing.expectError(error.InvalidParams, store.commitTurn(base));
    try std.testing.expectEqual(@as(u64, 0), try store.storeRevision());
    const rolled_back = (try store.conn.row("select (select count(*) from workspaces), (select count(*) from store_receipts)", .{})).?;
    defer rolled_back.deinit();
    try std.testing.expectEqual(@as(i64, 0), rolled_back.int(0));
    try std.testing.expectEqual(@as(i64, 0), rolled_back.int(1));

    var valid = base;
    valid.messages = &.{};
    const committed = try store.commitTurn(valid);
    try store.conn.exec("delete from workspaces where workspace_id = ?1", .{valid.workspace_id});
    const replay = try store.commitTurn(valid);
    try std.testing.expect(replay.duplicate);
    try std.testing.expectEqual(committed.store_revision, replay.store_revision);
    const owners = (try store.conn.row("select count(*) from workspaces", .{})).?;
    defer owners.deinit();
    try std.testing.expectEqual(@as(i64, 0), owners.int(0));
}

test "two Store connections race one turn acceptance idempotently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var first_store = try Store.init(std.testing.allocator, db_path);
    defer first_store.deinit();
    var second_store = try Store.init(std.testing.allocator, db_path);
    defer second_store.deinit();
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("race-accept", null),
        .turn_id = "race-turn",
        .workspace = testWorkspace("race-workspace", "Race"),
        .thread = .{ .local_thread_id = "race-thread", .title = "Race", .provider = "codex" },
        .started_at_ms = 1,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{ .message_id = "race-user", .role = "user", .author = "You", .body = "once" },
    };
    const FirstRunner = struct {
        fn run(store: *Store, req: TurnAcceptanceRequest, ready: *std.atomic.Value(u8), start: *std.atomic.Value(bool), result: *?store_protocol.WriteResult, failure: *?StoreError) void {
            _ = ready.fetchAdd(1, .release);
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            result.* = store.acceptTurn(req) catch |err| {
                failure.* = err;
                return;
            };
        }
    };
    const SecondRunner = struct {
        fn run(
            store: *Store,
            req: TurnAcceptanceRequest,
            ready: *std.atomic.Value(u8),
            start: *std.atomic.Value(bool),
            first_released: *std.atomic.Value(bool),
            contended: *std.atomic.Value(bool),
            result: *?store_protocol.WriteResult,
            failure: *?StoreError,
        ) void {
            _ = ready.fetchAdd(1, .release);
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            store.conn.busyTimeout(1) catch {
                failure.* = error.Internal;
                contended.store(true, .release);
                return;
            };
            _ = store.acceptTurn(req) catch |err| {
                if (err != error.StoreBusy) {
                    failure.* = err;
                    contended.store(true, .release);
                    return;
                }
                contended.store(true, .release);
                store.conn.busyTimeout(schema.BUSY_TIMEOUT_MS) catch {
                    failure.* = error.Internal;
                    return;
                };
                while (!first_released.load(.acquire)) std.atomic.spinLoopHint();
                result.* = store.acceptTurn(req) catch |retry_err| {
                    failure.* = retry_err;
                    return;
                };
                return;
            };
            failure.* = error.Internal;
            contended.store(true, .release);
        }
    };
    var ready = std.atomic.Value(u8).init(0);
    var first_start = std.atomic.Value(bool).init(false);
    var second_start = std.atomic.Value(bool).init(false);
    var first_acquired = std.atomic.Value(bool).init(false);
    var first_release = std.atomic.Value(bool).init(false);
    var second_contended = std.atomic.Value(bool).init(false);
    first_store.acceptance_test_hold = .{ .acquired = &first_acquired, .release = &first_release };
    var first_result: ?store_protocol.WriteResult = null;
    var second_result: ?store_protocol.WriteResult = null;
    var first_failure: ?StoreError = null;
    var second_failure: ?StoreError = null;
    const first_thread = try std.Thread.spawn(.{}, FirstRunner.run, .{ &first_store, request, &ready, &first_start, &first_result, &first_failure });
    const second_thread = try std.Thread.spawn(.{}, SecondRunner.run, .{ &second_store, request, &ready, &second_start, &first_release, &second_contended, &second_result, &second_failure });
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    first_start.store(true, .release);
    while (!first_acquired.load(.acquire)) std.atomic.spinLoopHint();
    second_start.store(true, .release);
    while (!second_contended.load(.acquire)) std.atomic.spinLoopHint();
    // The second connection returned StoreBusy while BEGIN IMMEDIATE was held;
    // this is proof of SQLite writer arbitration, not scheduler coincidence.
    first_release.store(true, .release);
    first_thread.join();
    second_thread.join();
    first_store.acceptance_test_hold = null;
    try std.testing.expect(first_failure == null);
    try std.testing.expect(second_failure == null);
    try std.testing.expect(first_result != null and second_result != null);
    try std.testing.expect(first_result.?.applied != second_result.?.applied);
    try std.testing.expect(first_result.?.duplicate != second_result.?.duplicate);
    try std.testing.expectEqual(@as(u64, 1), try first_store.storeRevision());
    const counts = (try first_store.conn.row(
        "select (select count(*) from workspaces), (select count(*) from threads), (select count(*) from messages), (select count(*) from chat_turns), (select count(*) from store_receipts)",
        .{},
    )).?;
    defer counts.deinit();
    var index: usize = 0;
    while (index < 5) : (index += 1) try std.testing.expectEqual(@as(i64, 1), counts.int(index));
}

test "committed turn receipt replay fires the journal hook exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-turn-hook", "Hook workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("turn-hook-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-turn-hook", "Hook thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("turn-hook-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const Counter = struct {
        count: usize = 0,
        revision: u64 = 0,

        fn mutation(_: *anyopaque, _: *const Mutation, _: store_protocol.WriteResult) void {}

        fn turn(context: *anyopaque, _: *const TurnCommitRequest, _: TurnOwnerInsertions, result: store_protocol.WriteResult) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.revision = result.store_revision;
        }

        fn acceptance(_: *anyopaque, _: *const TurnAcceptanceRequest, _: TurnOwnerInsertions, _: store_protocol.WriteResult) void {}
    };
    var counter: Counter = .{};
    store.commit_hook = .{
        .context = &counter,
        .on_mutation_committed = Counter.mutation,
        .on_turn_committed = Counter.turn,
        .on_acceptance_committed = Counter.acceptance,
    };
    const messages = [_]store_protocol.Message{.{
        .message_id = "turn-hook-message",
        .role = "assistant",
        .author = "Codex",
        .body = "once",
    }};
    const request: TurnCommitRequest = .{
        .turn_id = "turn-hook",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 1,
        .finished_at_ms = 2,
        .provider = "codex",
        .messages = &messages,
    };
    const first = try store.commitTurn(request);
    const replay = try store.commitTurn(request);
    try std.testing.expectEqual(first.store_revision, replay.store_revision);
    try std.testing.expect(!replay.applied);
    try std.testing.expect(replay.duplicate);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expectEqual(first.store_revision, counter.revision);
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
    try std.testing.expect(!replay.applied);
    try std.testing.expect(replay.duplicate);
    var replay_rows = (try store.conn.row(
        "select count(*) from messages where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer replay_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), replay_rows.int(0));
    try std.testing.expectEqual(@as(usize, 0), applied[0].message_id.len);
}

// M4-P4 fix Layer B (i): a GUI-shaped id-carrying snapshot after a daemon
// commit preserves every identity, the message keys, and the ledger's
// user_message_id reference — and an interrupted same-turn replay commit
// after the snapshot does not duplicate the user row.
test "snapshot replace preserves daemon-committed identities keys and ledger reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-belt", "Belt workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("belt-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-belt", "Belt thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("belt-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    // Acceptance staging shape: the client user row lands with its stable id.
    const user_message: store_protocol.Message = .{
        .message_id = "gui-msg:belt:1",
        .role = "user",
        .author = "You",
        .body = "belt hello",
        .created_at_ms = 10,
        .updated_at_ms = 10,
    };
    _ = try store.appendMessage(.{
        .mutation = testHeader("belt-user-stage", 2),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = user_message,
    });

    // Commit: F1 prepend (user row slot 0) + one synthesized assistant row.
    const commit_messages = [_]store_protocol.Message{
        user_message,
        .{ .message_id = "", .role = "assistant", .author = "Codex", .body = "belt-ok", .created_at_ms = 20, .updated_at_ms = 20 },
    };
    const commit = try store.commitTurn(.{
        .turn_id = "turn-belt",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 10,
        .finished_at_ms = 20,
        .provider = "codex",
        .user_message_id = "gui-msg:belt:1",
        .messages = &commit_messages,
    });
    try std.testing.expectEqual(@as(u64, 4), commit.store_revision);

    // Post-adoption GUI flush: full snapshot carrying both adopted ids.
    const snapshot_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:belt:1", .role = "user", .author = "You", .body = "belt hello" },
        .{ .message_id = "turn:turn-belt:msg:1", .role = "assistant", .author = "Codex", .body = "belt-ok" },
    };
    var snapshot_thread = testThread("thread-belt", "Belt thread");
    snapshot_thread.messages = &snapshot_messages;
    var snapshot_workspace = testWorkspace("workspace-belt", "Belt workspace");
    snapshot_workspace.threads = &.{snapshot_thread};
    const workspaces = [_]store_protocol.Workspace{snapshot_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("belt-flush-1", 4, false, testSnapshot(&workspaces)) });

    var rows = try store.conn.rows(
        "select message_id from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
        .{thread.local_thread_id},
    );
    defer rows.deinit();
    const ids: [2][]const u8 = .{ "gui-msg:belt:1", "turn:turn-belt:msg:1" };
    var row_count: usize = 0;
    while (rows.next()) |row| : (row_count += 1) {
        try std.testing.expect(row_count < ids.len);
        try std.testing.expectEqualStrings(ids[row_count], row.text(0));
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), row_count);

    var keys = (try store.conn.row(
        "select count(*) from client_message_keys where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer keys.deinit();
    try std.testing.expectEqual(@as(i64, 2), keys.int(0));

    // Ledger user_message_id must resolve to a real transcript row.
    var resolved = (try store.conn.row(
        \\select count(*) from chat_turns ct
        \\join threads t on t.local_thread_id = ct.local_thread_id
        \\join messages m on m.thread_id = t.id and m.message_id = ct.user_message_id
        \\where ct.turn_id = 'turn-belt'
    ,
        .{},
    )).?;
    defer resolved.deinit();
    try std.testing.expectEqual(@as(i64, 1), resolved.int(0));

    // Interrupted-replay corner: a second commit for the same turn with a
    // drifted user-row fingerprint must not duplicate the user row. Use a
    // fresh turn (no receipt) whose user row the snapshot already carries.
    const replay_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:belt:1", .role = "user", .author = "You", .body = "belt hello", .created_at_ms = 99, .updated_at_ms = 99 },
        .{ .message_id = "", .role = "assistant", .author = "Codex", .body = "belt-again", .created_at_ms = 100, .updated_at_ms = 100 },
    };
    _ = try store.commitTurn(.{
        .turn_id = "turn-belt-replay",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 99,
        .finished_at_ms = 100,
        .provider = "codex",
        .user_message_id = "gui-msg:belt:1",
        .messages = &replay_messages,
    });
    var user_rows = (try store.conn.row(
        "select count(*) from messages where message_id = 'gui-msg:belt:1'",
        .{},
    )).?;
    defer user_rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), user_rows.int(0));
}

// A snapshot cannot be relabeled with a newer guard. Once a current projection
// deliberately deletes a workspace, ownership rows are tombstoned while the
// independent terminal replay identity remains durable.
test "snapshot replace rejects stale relabel and tombstones ownership without replay identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("ws-belt2", "Ledger workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("wsbelt-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-belt2", "Ledger thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("wsbelt-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });
    const user_message: store_protocol.Message = .{
        .message_id = "gui-msg:wsbelt:1",
        .role = "user",
        .author = "You",
        .body = "wsbelt hello",
        .created_at_ms = 10,
        .updated_at_ms = 10,
    };
    _ = try store.appendMessage(.{
        .mutation = testHeader("wsbelt-user-stage", 2),
        .workspace_id = workspace.workspace_id,
        .thread_id = thread.local_thread_id,
        .message = user_message,
    });
    const commit_messages = [_]store_protocol.Message{
        user_message,
        .{ .message_id = "", .role = "assistant", .author = "Codex", .body = "wsbelt-ok", .created_at_ms = 20, .updated_at_ms = 20 },
    };
    _ = try store.commitTurn(.{
        .turn_id = "turn-wsbelt",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 10,
        .finished_at_ms = 20,
        .provider = "codex",
        .user_message_id = "gui-msg:wsbelt:1",
        .messages = &commit_messages,
    });
    // Control: a workspace with no turns at all is a plain deletion target.
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("wsbelt-plain", 4),
        .workspace = testWorkspace("ws-plain", "Plain workspace"),
    });

    // Guard is current, but the projection payload was captured at revision 2,
    // before the turn committed. This pins the pending-adoption distinction
    // independently of the optimistic guard.
    const carried = [_]store_protocol.Workspace{testWorkspace("ws-other", "Other workspace")};
    var unobserved_request = testSnapshotRequest("wsbelt-flush", 5, false, testSnapshot(&carried));
    unobserved_request.snapshot.store_revision = 2;
    try std.testing.expectError(error.Conflict, store.applyMutation(.{ .snapshot_replace = unobserved_request }));

    const counts = [_]struct { id: []const u8, expected: i64 }{
        .{ .id = "ws-belt2", .expected = 1 }, // stale payload changed nothing
        .{ .id = "ws-plain", .expected = 1 },
        .{ .id = "ws-other", .expected = 0 },
    };
    for (counts) |case| {
        var row = (try store.conn.row(
            "select count(*) from workspaces where workspace_id = ?1",
            .{case.id},
        )).?;
        defer row.deinit();
        try std.testing.expectEqual(case.expected, row.int(0));
    }

    // The preserved thread re-homed under the restored workspace with both
    // ledger-referenced rows, and the ledger reference resolves again.
    var restored_rows = (try store.conn.row(
        \\select count(*) from messages m
        \\join threads t on t.id = m.thread_id
        \\join workspaces w on w.id = t.workspace_id
        \\where w.workspace_id = 'ws-belt2' and t.local_thread_id = 'thread-belt2'
    ,
        .{},
    )).?;
    defer restored_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), restored_rows.int(0));
    var resolved = (try store.conn.row(
        \\select count(*) from chat_turns ct
        \\join threads t on t.local_thread_id = ct.local_thread_id
        \\join messages m on m.thread_id = t.id and m.message_id = ct.user_message_id
        \\where ct.turn_id = 'turn-wsbelt'
    ,
        .{},
    )).?;
    defer resolved.deinit();
    try std.testing.expectEqual(@as(i64, 1), resolved.int(0));

    // A current projection deliberately omits the workspace. Ownership
    // deletion and replay-guard retention are atomic in the same commit.
    const retained_control = [_]store_protocol.Workspace{testWorkspace("ws-other", "Other workspace")};
    const deletion_request = testSnapshotRequest(
        "wsbelt-delete-observed",
        5,
        false,
        testSnapshot(&retained_control),
    );
    _ = try store.applyMutation(.{ .snapshot_replace = deletion_request });
    var deleted_workspace = (try store.conn.row(
        "select count(*) from workspaces where workspace_id = 'ws-belt2'",
        .{},
    )).?;
    defer deleted_workspace.deinit();
    try std.testing.expectEqual(@as(i64, 0), deleted_workspace.int(0));
    var deleted_ledger = (try store.conn.row(
        "select count(*) from chat_turns where workspace_id = 'ws-belt2'",
        .{},
    )).?;
    defer deleted_ledger.deinit();
    try std.testing.expectEqual(@as(i64, 0), deleted_ledger.int(0));
    var replay_guard = (try store.conn.row(
        "select count(*) from terminal_turn_replay_guard where turn_id = 'turn-wsbelt' and status = 'completed'",
        .{},
    )).?;
    defer replay_guard.deinit();
    try std.testing.expectEqual(@as(i64, 1), replay_guard.int(0));
}

test "existing database backfills terminal replay guard on reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    {
        var legacy = try Store.init(std.testing.allocator, db_path);
        defer legacy.deinit();
        try legacy.conn.execNoArgs("drop table terminal_turn_replay_guard");
        try legacy.conn.exec(
            "insert into chat_turns (turn_id, workspace_id, local_thread_id, status, started_at_ms, finished_at_ms, provider) values (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            .{ "turn-pre-guard", "ws-old", "thread-old", "completed", @as(i64, 1), @as(i64, 2), "codex" },
        );
    }

    var reopened = try Store.init(std.testing.allocator, db_path);
    defer reopened.deinit();
    var row = (try reopened.conn.row(
        "select count(*) from terminal_turn_replay_guard where turn_id = 'turn-pre-guard' and status = 'completed'",
        .{},
    )).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.int(0));
}

// M5-P4 Amendment 1 duplicate-id invariant: one snapshot carrying the same
// (thread, message_id) twice applies cleanly — identity wins, the later
// occurrence refreshes position and content, and exactly one row plus one
// client key remain.
test "snapshot replace tolerates duplicate message ids by refreshing in place" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("dup-workspace", null),
        .workspace = testWorkspace("ws-dup", "Dup workspace"),
    });

    const snapshot_messages = [_]store_protocol.Message{
        .{ .message_id = "dup-1", .role = "user", .author = "You", .body = "first copy" },
        .{ .message_id = "", .role = "assistant", .author = "Codex", .body = "middle" },
        .{ .message_id = "dup-1", .role = "user", .author = "You", .body = "second copy" },
    };
    var snapshot_thread = testThread("thread-dup", "Dup thread");
    snapshot_thread.messages = &snapshot_messages;
    var snapshot_workspace = testWorkspace("ws-dup", "Dup workspace");
    snapshot_workspace.threads = &.{snapshot_thread};
    const workspaces = [_]store_protocol.Workspace{snapshot_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("dup-flush", 1, false, testSnapshot(&workspaces)) });

    var dup_row = (try store.conn.row(
        "select count(*), max(body), max(sort_index) from messages where message_id = 'dup-1'",
        .{},
    )).?;
    defer dup_row.deinit();
    try std.testing.expectEqual(@as(i64, 1), dup_row.int(0));
    try std.testing.expectEqualStrings("second copy", dup_row.text(1));
    try std.testing.expectEqual(@as(i64, 2), dup_row.int(2));
    var total_rows = (try store.conn.row(
        "select count(*) from messages",
        .{},
    )).?;
    defer total_rows.deinit();
    try std.testing.expectEqual(@as(i64, 2), total_rows.int(0));
    var key_rows = (try store.conn.row(
        "select count(*) from client_message_keys where message_id = 'dup-1'",
        .{},
    )).?;
    defer key_rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), key_rows.int(0));
}

test "bounded snapshot preserves unloaded legacy transcript prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("lazy-workspace", null),
        .workspace = testWorkspace("ws-lazy", "Lazy workspace"),
    });

    const initial_messages = [_]store_protocol.Message{
        .{ .role = "user", .author = "You", .body = "old zero" },
        .{ .role = "assistant", .author = "Assistant", .body = "old one" },
        .{ .role = "assistant", .author = "Assistant", .body = "old two" },
    };
    var initial_thread = testThread("thread-lazy", "Lazy thread");
    initial_thread.messages = &initial_messages;
    var initial_workspace = testWorkspace("ws-lazy", "Lazy workspace");
    initial_workspace.threads = &.{initial_thread};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest(
        "lazy-full",
        1,
        false,
        testSnapshot(&.{initial_workspace}),
    ) });

    try store.conn.exec(
        "create temp table lazy_prefix_mutations (operation text not null)",
        .{},
    );
    try store.conn.exec(
        \\create temp trigger observe_lazy_prefix_delete before delete on main.messages
        \\when old.sort_index < 2 begin
        \\    insert into lazy_prefix_mutations (operation) values ('delete');
        \\end
    , .{});
    try store.conn.exec(
        \\create temp trigger observe_lazy_prefix_update before update on main.messages
        \\when old.sort_index < 2 begin
        \\    insert into lazy_prefix_mutations (operation) values ('update');
        \\end
    , .{});

    const tail = [_]store_protocol.Message{.{
        .role = "assistant",
        .author = "Assistant",
        .body = "updated two",
    }};
    var bounded_thread = testThread("thread-lazy", "Lazy thread");
    bounded_thread.message_offset = 2;
    bounded_thread.messages = &tail;
    var bounded_workspace = testWorkspace("ws-lazy", "Lazy workspace");
    bounded_workspace.threads = &.{bounded_thread};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest(
        "lazy-tail",
        2,
        false,
        testSnapshot(&.{bounded_workspace}),
    ) });

    var rows = try store.conn.rows("select sort_index, body from messages order by sort_index", .{});
    defer rows.deinit();
    const expected = [_][]const u8{ "old zero", "old one", "updated two" };
    var index: usize = 0;
    while (rows.next()) |row| : (index += 1) {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(@as(i64, @intCast(index)), row.int(0));
        try std.testing.expectEqualStrings(expected[index], row.text(1));
    }
    if (rows.err) |err| return err;
    try std.testing.expectEqual(expected.len, index);
    var prefix_mutations = (try store.conn.row(
        "select count(*) from lazy_prefix_mutations",
        .{},
    )).?;
    defer prefix_mutations.deinit();
    try std.testing.expectEqual(@as(i64, 0), prefix_mutations.int(0));
}

// M4-P4 fix Layer B (ii): a mid-window snapshot (commit → GUI observation gap)
// missing the turn's synthesized rows preserves them with coherent order, and
// the converged post-adoption flush keeps exactly one copy per identity.
test "snapshot missing unobserved turn rows preserves them in transcript order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-mid", "Mid workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("mid-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-mid", "Mid thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("mid-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const commit_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:mid:1", .role = "user", .author = "You", .body = "mid hello", .created_at_ms = 10, .updated_at_ms = 10 },
        .{ .message_id = "", .role = "assistant", .author = "Codex", .body = "mid-a", .created_at_ms = 20, .updated_at_ms = 20 },
        .{ .message_id = "", .role = "system", .author = "Ran command", .body = "$ true", .created_at_ms = 21, .updated_at_ms = 21 },
    };
    const commit = try store.commitTurn(.{
        .turn_id = "turn-mid",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 10,
        .finished_at_ms = 21,
        .provider = "codex",
        .user_message_id = "gui-msg:mid:1",
        .messages = &commit_messages,
    });
    try std.testing.expectEqual(@as(u64, 3), commit.store_revision);

    const expected_ids = [_][]const u8{ "gui-msg:mid:1", "turn:turn-mid:msg:1", "turn:turn-mid:msg:2" };

    // Mid-window flush: the GUI knows only its own user row.
    const mid_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:mid:1", .role = "user", .author = "You", .body = "mid hello" },
    };
    var mid_thread = testThread("thread-mid", "Mid thread");
    mid_thread.messages = &mid_messages;
    var mid_workspace = testWorkspace("workspace-mid", "Mid workspace");
    mid_workspace.threads = &.{mid_thread};
    const mid_workspaces = [_]store_protocol.Workspace{mid_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("mid-flush-1", 3, false, testSnapshot(&mid_workspaces)) });

    {
        var rows = try store.conn.rows(
            "select message_id, sort_index from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
            .{thread.local_thread_id},
        );
        defer rows.deinit();
        var row_count: usize = 0;
        var last_sort: i64 = -1;
        while (rows.next()) |row| : (row_count += 1) {
            try std.testing.expect(row_count < expected_ids.len);
            try std.testing.expectEqualStrings(expected_ids[row_count], row.text(0));
            try std.testing.expect(row.int(1) > last_sort);
            last_sort = row.int(1);
        }
        if (rows.err) |err| return err;
        try std.testing.expectEqual(@as(usize, 3), row_count);
    }

    // Restored keys keep identities resolvable for later replay commits.
    var keys = (try store.conn.row(
        "select count(*) from client_message_keys where thread_id = (select id from threads where local_thread_id = ?1)",
        .{thread.local_thread_id},
    )).?;
    defer keys.deinit();
    try std.testing.expectEqual(@as(i64, 3), keys.int(0));

    // Converged post-adoption flush: all ids present, exactly one copy each.
    const full_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:mid:1", .role = "user", .author = "You", .body = "mid hello" },
        .{ .message_id = "turn:turn-mid:msg:1", .role = "assistant", .author = "Codex", .body = "mid-a" },
        .{ .message_id = "turn:turn-mid:msg:2", .role = "system", .author = "Ran command", .body = "$ true" },
    };
    var full_thread = testThread("thread-mid", "Mid thread");
    full_thread.messages = &full_messages;
    var full_workspace = testWorkspace("workspace-mid", "Mid workspace");
    full_workspace.threads = &.{full_thread};
    const full_workspaces = [_]store_protocol.Workspace{full_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("mid-flush-2", 4, false, testSnapshot(&full_workspaces)) });

    {
        var rows = try store.conn.rows(
            "select message_id from messages where thread_id = (select id from threads where local_thread_id = ?1) order by sort_index",
            .{thread.local_thread_id},
        );
        defer rows.deinit();
        var row_count: usize = 0;
        while (rows.next()) |row| : (row_count += 1) {
            try std.testing.expect(row_count < expected_ids.len);
            try std.testing.expectEqualStrings(expected_ids[row_count], row.text(0));
        }
        if (rows.err) |err| return err;
        try std.testing.expectEqual(@as(usize, 3), row_count);
    }
}

test "accepted multi-image user row and multi-image draft survive snapshot replace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);
    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    // Acceptance path: the durable user row is staged with the full
    // attachment list — primary in the legacy columns, extras as JSON.
    const user_images = [_]store_protocol.Attachment{
        .{ .path = "/tmp/shot-a.png", .mime = "image/png", .byte_size = 11 },
        .{ .path = "/tmp/shot-b.png", .mime = "image/jpeg", .byte_size = 22 },
    };
    const request: TurnAcceptanceRequest = .{
        .mutation = testHeader("turn:img-turn:accept", null),
        .turn_id = "img-turn",
        .workspace = testWorkspace("workspace-img", "Image workspace"),
        .thread = .{
            .local_thread_id = "thread-img",
            .title = "Image thread",
            .provider = "codex",
        },
        .started_at_ms = 100,
        .provider = "codex",
        .harness = "local_cli",
        .user_message = .{
            .message_id = "gui-msg:img:1",
            .role = "user",
            .author = "You",
            .body = "look at these",
            .image = user_images[0],
            .images = &user_images,
            .created_at_ms = 100,
            .updated_at_ms = 100,
        },
    };
    _ = try store.acceptTurn(request);
    {
        var row = (try store.conn.row(
            "select image_path, extra_images_json from messages where message_id = 'gui-msg:img:1'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("/tmp/shot-a.png", row.text(0));
        try std.testing.expect(std.mem.indexOf(u8, row.text(1), "/tmp/shot-b.png") != null);
    }

    // Composer path: a multi-image draft rides the thread upsert the same way.
    const draft_images = [_]store_protocol.Attachment{
        .{ .path = "/tmp/draft-a.png", .mime = "image/png", .byte_size = 33 },
        .{ .path = "/tmp/draft-b.png", .mime = "image/png", .byte_size = 44 },
    };
    var draft_thread = testThread("thread-img", "Image thread");
    draft_thread.draft = "pending prompt";
    draft_thread.draft_image = draft_images[0];
    draft_thread.draft_images = &draft_images;
    _ = try store.upsertThread(.{
        .mutation = testHeader("img-draft", null),
        .workspace_id = request.workspace.workspace_id,
        .thread = draft_thread,
    });
    {
        var row = (try store.conn.row(
            "select draft_image_path, draft_images_json from threads where local_thread_id = 'thread-img'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("/tmp/draft-a.png", row.text(0));
        try std.testing.expect(std.mem.indexOf(u8, row.text(1), "/tmp/draft-b.png") != null);
    }

    // Mid-window GUI flush that does not know the accepted user row yet: the
    // preserved-row pass must restore it with its extras intact, and the
    // payload thread carrying the full draft list keeps the draft columns.
    var mid_thread = testThread("thread-img", "Image thread");
    mid_thread.draft = "pending prompt";
    mid_thread.draft_image = draft_images[0];
    mid_thread.draft_images = &draft_images;
    var mid_workspace = testWorkspace("workspace-img", "Image workspace");
    mid_workspace.threads = &.{mid_thread};
    const mid_workspaces = [_]store_protocol.Workspace{mid_workspace};
    const mid_revision = try store.storeRevision();
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("img-flush-1", mid_revision, false, testSnapshot(&mid_workspaces)) });
    {
        var row = (try store.conn.row(
            "select m.image_path, m.extra_images_json, t.draft_image_path, t.draft_images_json " ++
                "from messages m join threads t on t.id = m.thread_id where m.message_id = 'gui-msg:img:1'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("/tmp/shot-a.png", row.text(0));
        try std.testing.expect(std.mem.indexOf(u8, row.text(1), "/tmp/shot-b.png") != null);
        try std.testing.expectEqualStrings("/tmp/draft-a.png", row.text(2));
        try std.testing.expect(std.mem.indexOf(u8, row.text(3), "/tmp/draft-b.png") != null);
    }

    // An old GUI can carry the accepted identity before its projection has
    // attachment metadata. Sparse means unknown, not removal, because sent
    // transcript rows are immutable.
    const sparse_messages = [_]store_protocol.Message{
        .{
            .message_id = "gui-msg:img:1",
            .role = "user",
            .author = "You",
            .body = "look at these",
        },
    };
    var sparse_thread = testThread("thread-img", "Image thread");
    sparse_thread.messages = &sparse_messages;
    var sparse_workspace = testWorkspace("workspace-img", "Image workspace");
    sparse_workspace.threads = &.{sparse_thread};
    const sparse_workspaces = [_]store_protocol.Workspace{sparse_workspace};
    const sparse_revision = try store.storeRevision();
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("img-flush-sparse", sparse_revision, false, testSnapshot(&sparse_workspaces)) });
    {
        var row = (try store.conn.row(
            "select image_path, extra_images_json from messages where message_id = 'gui-msg:img:1'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("/tmp/shot-a.png", row.text(0));
        try std.testing.expect(std.mem.indexOf(u8, row.text(1), "/tmp/shot-b.png") != null);
    }

    // A converged flush carrying the full image list still refreshes in place
    // with exactly one copy and every extra present.
    const full_messages = [_]store_protocol.Message{
        .{
            .message_id = "gui-msg:img:1",
            .role = "user",
            .author = "You",
            .body = "look at these",
            .image = user_images[0],
            .images = &user_images,
        },
    };
    var full_thread = testThread("thread-img", "Image thread");
    full_thread.messages = &full_messages;
    var full_workspace = testWorkspace("workspace-img", "Image workspace");
    full_workspace.threads = &.{full_thread};
    const full_workspaces = [_]store_protocol.Workspace{full_workspace};
    const full_revision = try store.storeRevision();
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("img-flush-2", full_revision, false, testSnapshot(&full_workspaces)) });
    {
        var row = (try store.conn.row(
            "select count(*), min(extra_images_json) from messages where message_id = 'gui-msg:img:1'",
            .{},
        )).?;
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
        try std.testing.expect(std.mem.indexOf(u8, row.text(1), "/tmp/shot-b.png") != null);
    }
}

// M4-P4 fix Layer B (iii) / MINOR-5: the daemon-owned chat_completions ledger
// survives a GUI snapshot that does not know the row yet; removal remains the
// targeted clear command only.
test "chat completion ledger survives snapshot lacking it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-done", "Done workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("done-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("thread-done", "Done thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("done-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });
    const commit_messages = [_]store_protocol.Message{
        .{ .message_id = "gui-msg:done:1", .role = "user", .author = "You", .body = "done hello" },
    };
    _ = try store.commitTurn(.{
        .turn_id = "turn-done",
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .status = .completed,
        .started_at_ms = 10,
        .finished_at_ms = 20,
        .provider = "codex",
        .user_message_id = "gui-msg:done:1",
        .messages = &commit_messages,
    });

    // Snapshot in the commit→observation window: no chat_completions payload.
    const workspaces = [_]store_protocol.Workspace{testWorkspace("workspace-done", "Done workspace")};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("done-flush", 3, false, testSnapshot(&workspaces)) });

    var survived = (try store.conn.row(
        "select count(*) from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
        .{ workspace.workspace_id, thread.local_thread_id },
    )).?;
    defer survived.deinit();
    try std.testing.expectEqual(@as(i64, 1), survived.int(0));

    const cleared = try store.clearChatCompletion(.{
        .mutation = testHeader("done-clear", 4),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .completed_at_ms = 20,
    });
    try std.testing.expect(cleared.applied);
    var removed = (try store.conn.row(
        "select count(*) from chat_completions where workspace_id = ?1 and local_thread_id = ?2",
        .{ workspace.workspace_id, thread.local_thread_id },
    )).?;
    defer removed.deinit();
    try std.testing.expectEqual(@as(i64, 0), removed.int(0));
}

test "surface ledger survives concurrent snapshot lacking it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-active", "Active workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("active-workspace", null),
        .workspace = workspace,
    });
    _ = try store.upsertSurface(.{
        .mutation = testHeader("active-surface", 1),
        .surface = .{
            .session_id = "session-active",
            .workspace_id = workspace.workspace_id,
            .workspace_path = workspace.path,
            .dock_id = 1,
            .pane_id = 3,
            .title = "Working surface",
            .status = "working",
            .status_changed_at_ms = 100,
        },
    });

    // The GUI captured R1 before the targeted surface mutation at R2, then
    // rebased its local layout and retries a snapshot that omits surfaces.
    const workspaces = [_]store_protocol.Workspace{workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest(
        "active-rebased-flush",
        2,
        false,
        testSnapshot(&workspaces),
    ) });

    var survived = (try store.conn.row(
        "select status, title, dock_id, pane_id from surface_completions where session_id = ?1",
        .{"session-active"},
    )).?;
    defer survived.deinit();
    try std.testing.expectEqual(try surfaceStatusCode("working"), survived.int(0));
    try std.testing.expectEqualStrings("Working surface", survived.text(1));
    try std.testing.expectEqual(@as(i64, 1), survived.int(2));
    try std.testing.expectEqual(@as(i64, 3), survived.int(3));
}

// M4-P5 verify MAJOR-3 amendment: daemon-created thread rows (MCP
// chat.thread.upsert — stable local_thread_id is public API) survive a GUI
// snapshot that never observed them, while uncommitted GUI drafts the GUI
// deliberately dropped stay deleted.
test "snapshot preserves daemon-created thread rows and still drops abandoned drafts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();
    const workspace = testWorkspace("workspace-mcp", "MCP workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("mcp-workspace", null),
        .workspace = workspace,
    });
    // MCP open_chat shape: committed thread, no messages, no GUI observation.
    const mcp_thread = testThread("thread-mcp", "MCP thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("mcp-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = mcp_thread,
    });

    // GUI flush 1 knows only its own uncommitted draft thread.
    var draft_thread = testThread("draft-1", "New thread");
    draft_thread.committed = false;
    var gui_workspace = testWorkspace("workspace-mcp", "MCP workspace");
    gui_workspace.threads = &.{draft_thread};
    const first_workspaces = [_]store_protocol.Workspace{gui_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("mcp-flush-1", 2, false, testSnapshot(&first_workspaces)) });

    var after_first = (try store.conn.row(
        "select count(*) from threads where local_thread_id = 'thread-mcp'",
        .{},
    )).?;
    defer after_first.deinit();
    try std.testing.expectEqual(@as(i64, 1), after_first.int(0));

    // GUI flush 2 dropped the abandoned draft (pane closed): the draft must
    // stay deleted while the daemon-created thread still survives.
    var empty_workspace = testWorkspace("workspace-mcp", "MCP workspace");
    empty_workspace.threads = &.{};
    const second_workspaces = [_]store_protocol.Workspace{empty_workspace};
    _ = try store.applyMutation(.{ .snapshot_replace = testSnapshotRequest("mcp-flush-2", 3, false, testSnapshot(&second_workspaces)) });

    var kept = (try store.conn.row(
        "select count(*) from threads where local_thread_id = 'thread-mcp'",
        .{},
    )).?;
    defer kept.deinit();
    try std.testing.expectEqual(@as(i64, 1), kept.int(0));
    var dropped = (try store.conn.row(
        "select count(*) from threads where local_thread_id = 'draft-1'",
        .{},
    )).?;
    defer dropped.deinit();
    try std.testing.expectEqual(@as(i64, 0), dropped.int(0));
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

test "store migrates populated v1 WAL state into the current chain" {
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
    try std.testing.expectEqual(schema.MAX_SUPPORTED_VERSION, blk: {
        const row = (try store.conn.row("pragma user_version", .{})).?;
        defer row.deinit();
        break :blk row.int(0);
    });
    try std.testing.expectEqual(@as(i64, 1), try workspaceCount(&store));
    try std.testing.expectEqual(@as(u64, 0), try store.storeRevision());
    try std.testing.expect(try schema.testHasColumn(store.conn, "store_receipts", "response_payload"));
    try std.testing.expect(try schema.testHasColumn(store.conn, "threads", "draft_images_json"));
    try std.testing.expect(try schema.testHasColumn(store.conn, "messages", "extra_images_json"));
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
    const stale_clear_completion = try store.clearChatCompletion(.{
        .mutation = testHeader("completion-clear-stale", 7),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .completed_at_ms = 6,
    });
    try std.testing.expect(!stale_clear_completion.applied);
    const clear_completion = try store.clearChatCompletion(.{
        .mutation = testHeader("completion-clear", 8),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .completed_at_ms = 7,
    });
    try std.testing.expect(clear_completion.applied);
    const clear_missing_completion = try store.clearChatCompletion(.{
        .mutation = testHeader("completion-clear-missing", 9),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .completed_at_ms = 7,
    });
    try std.testing.expect(!clear_missing_completion.applied);
    try std.testing.expectEqual(@as(u64, 10), clear_missing_completion.store_revision);
}

test "external chat draft mutation is atomic and rejects a stale GUI snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    var store = try Store.init(std.testing.allocator, db_path);
    defer store.deinit();

    const workspace = testWorkspace("draft-workspace", "Draft workspace");
    _ = try store.upsertWorkspace(.{
        .mutation = testHeader("draft-workspace", null),
        .workspace = workspace,
    });
    const thread = testThread("draft-thread", "Draft thread");
    _ = try store.upsertThread(.{
        .mutation = testHeader("draft-thread", 1),
        .workspace_id = workspace.workspace_id,
        .thread = thread,
    });

    const set = try store.setChatDraft(.{
        .mutation = testHeader("draft-set", 2),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .text = "stage for review",
    });
    try std.testing.expectEqual(@as(u64, 3), set.store_revision);
    const append = try store.setChatDraft(.{
        .mutation = testHeader("draft-append", 3),
        .workspace_id = workspace.workspace_id,
        .local_thread_id = thread.local_thread_id,
        .text = " please",
        .append = true,
    });
    try std.testing.expectEqual(@as(u64, 4), append.store_revision);

    const row = (try store.conn.row(
        "select draft from threads t join workspaces w on w.id = t.workspace_id where w.workspace_id = ?1 and t.local_thread_id = ?2",
        .{ workspace.workspace_id, thread.local_thread_id },
    )).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("stage for review please", row.text(0));

    const stale_thread: store_protocol.Thread = .{
        .local_thread_id = thread.local_thread_id,
        .title = thread.title,
        .draft = "",
    };
    const stale_workspace: store_protocol.Workspace = .{
        .workspace_id = workspace.workspace_id,
        .label = workspace.label,
        .path = workspace.path,
        .threads = &.{stale_thread},
    };
    try std.testing.expectError(error.Conflict, store.replaceSnapshot(.{
        .mutation = testHeader("stale-draft-snapshot", 2),
        .snapshot = .{
            .store_revision = 2,
            .workspaces = &.{stale_workspace},
        },
    }));
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
    {
        var receipt = (try store.conn.row("select fingerprint from store_receipts where request_key = 'same-key'", .{})).?;
        defer receipt.deinit();
        try std.testing.expectEqual(@as(usize, FINGERPRINT_LEN), receipt.text(0).len);
        try std.testing.expect(isDigestFingerprint(receipt.text(0)));
    }

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

test "legacy serialized receipt fingerprints migrate without breaking replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    const workspace = testWorkspace("legacy-fingerprint-workspace", "Before");
    const request = testWorkspaceRequest("legacy-fingerprint-key", null, workspace);
    const legacy_fingerprint = try store_protocol.encode(std.testing.allocator, workspace);
    defer std.testing.allocator.free(legacy_fingerprint);
    const legacy_message_fingerprint = "legacy-message-json";
    var original: store_protocol.WriteResult = undefined;
    {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        original = try store.applyMutation(.{ .workspace_upsert = request });
        try store.conn.exec(
            "update store_receipts set fingerprint = ?1 where request_key = ?2",
            .{ legacy_fingerprint, request.mutation.request_key },
        );
        try store.conn.execNoArgs(
            \\insert into threads (workspace_id, sort_index, title, local_thread_id, provider, harness)
            \\values ((select id from workspaces where workspace_id = 'legacy-fingerprint-workspace'), 0, 'Legacy key', 'legacy-key-thread', 0, 0);
            \\insert into client_message_keys (thread_id, message_id, message_fingerprint, sort_index, store_revision)
            \\values ((select id from threads where local_thread_id = 'legacy-key-thread'), 'legacy-message', 'legacy-message-json', 0, 1);
        );
    }

    var reopened = try Store.init(std.testing.allocator, db_path);
    defer reopened.deinit();
    {
        var receipt = (try reopened.conn.row(
            "select fingerprint from store_receipts where request_key = ?1",
            .{request.mutation.request_key},
        )).?;
        defer receipt.deinit();
        try std.testing.expect(isDigestFingerprint(receipt.text(0)));
        const expected_fingerprint = fingerprintBytes(legacy_fingerprint);
        try std.testing.expectEqualSlices(u8, &expected_fingerprint, receipt.text(0));
    }
    {
        var message_key = (try reopened.conn.row(
            "select message_fingerprint from client_message_keys where message_id = 'legacy-message'",
            .{},
        )).?;
        defer message_key.deinit();
        const expected_fingerprint = fingerprintBytes(legacy_message_fingerprint);
        try std.testing.expectEqualSlices(u8, &expected_fingerprint, message_key.text(0));
    }
    const replay = try reopened.applyMutation(.{ .workspace_upsert = request });
    try std.testing.expectEqual(original.store_revision, replay.store_revision);
    try std.testing.expectEqual(original.applied, replay.applied);
    try std.testing.expectEqual(original.duplicate, replay.duplicate);
}

test "fingerprint digest is stable and fixed-size" {
    const fingerprint = fingerprintBytes("abc");
    try std.testing.expectEqualStrings(
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &fingerprint,
    );
    try std.testing.expect(isDigestFingerprint(&fingerprint));
    try std.testing.expect(!isDigestFingerprint("abc"));
}

test "legacy fingerprint migration compacts released SQLite pages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try testDbPath(&tmp);
    defer std.testing.allocator.free(db_path);

    {
        var store = try Store.init(std.testing.allocator, db_path);
        store.deinit();
    }
    const legacy_fingerprint = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(legacy_fingerprint);
    @memset(legacy_fingerprint, 'x');
    {
        const conn = try zqlite.open(db_path, zqlite.OpenFlags.EXResCode);
        defer conn.close();
        try conn.exec(
            "insert into store_receipts (request_key, operation, fingerprint, store_revision, response_payload, response_status) values ('large-legacy', 'test', ?1, 0, '{}', 0)",
            .{legacy_fingerprint},
        );
        var checkpoint = (try conn.row("pragma wal_checkpoint(truncate)", .{})).?;
        checkpoint.deinit();
    }
    const size_before = (try tmp.dir.statFile(std.testing.io, "state.sqlite", .{})).size;

    {
        var store = try Store.init(std.testing.allocator, db_path);
        defer store.deinit();
        try compactFreedPages(store.conn, 1);
    }
    const size_after = (try tmp.dir.statFile(std.testing.io, "state.sqlite", .{})).size;
    try std.testing.expect(size_after < size_before);
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
