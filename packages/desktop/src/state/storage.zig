//! Native state database ownership and legacy JSON loading.
//!
//! After the M3 Phase 3 authority flip, production mutations go through the
//! session daemon (`state.snapshot.replace` and granular store methods). The
//! local SQLite handle is read-only for bulk startup/offline projection and
//! never runs schema initialization or writes.

const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("zsdl3");
const headless = @import("headless");
const db_client = @import("../db/client.zig");
const db_types = @import("../db/types.zig");
const sessionizer = @import("../terminal/sessionizer.zig");
const platform_runtime = @import("platform_runtime");
const persistence = @import("persistence.zig");

const ORG_NAME: [:0]const u8 = "verde";
const APP_NAME: [:0]const u8 = "Native";
pub const LEGACY_STATE_FILE_NAME = "state.json";
pub const PENDING_STATE_SPOOL_FILE_NAME = "pending-state-spool.json";
const PENDING_STATE_SPOOL_TEMP_FILE_NAME = "pending-state-spool.json.tmp";
// A close-time spool contains both the current projection and, when available,
// its merge baseline. Real stores can therefore require roughly twice their
// durable JSON footprint. Keep replay bounded, but leave room for two copies of
// the largest field state seen in production (about 136 MiB).
const PENDING_STATE_SPOOL_MAX_BYTES: usize = 384 * 1024 * 1024;
const SNAPSHOT_REQUEST_HEADROOM_BYTES: usize = 64 * 1024;
/// Focus acknowledgements are best-effort UI bookkeeping and must never own
/// more than a short background transport window.
const ACKNOWLEDGEMENT_TIMEOUT_MS: u32 = 500;
/// Client unregister runs after all durable state is owned and must not hold
/// process exit behind an unhealthy daemon.
const CLIENT_CLOSE_TIMEOUT_MS: u32 = 750;
const LoadedPersistedState = db_types.LoadedState;
const PersistedState = db_types.PersistedState;
const PersistedThread = db_types.PersistedThread;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const log = std.log.scoped(.native_shell);

pub const SurfaceCommitProof = struct {
    request_key: []const u8,
    store_revision: u64,
};

pub const SurfaceCommitProofClassification = enum {
    current,
    superseded,
    invalid,
};

/// Map the Store wire DTO to the one canonical durable surface shape.
pub fn protocolSurfaceToPersisted(surface: headless.store.SurfaceState) ?PersistedSurfaceState {
    return .{
        .session_id = surface.session_id,
        .workspace_id = surface.workspace_id,
        .workspace_path = surface.workspace_path,
        .dock_id = surface.dock_id,
        .pane_id = surface.pane_id,
        .provider = if (surface.provider) |value| std.meta.stringToEnum(db_types.SurfaceProvider, value) orelse return null else null,
        .provider_thread_id = surface.provider_thread_id,
        .title = surface.title,
        .status = std.meta.stringToEnum(db_types.SurfaceStatus, surface.status) orelse return null,
        .status_changed_at_ms = surface.status_changed_at_ms,
        .completed_at_ms = surface.completed_at_ms,
        .last_event_title = surface.last_event_title,
        .last_event_body = surface.last_event_body,
    };
}

fn guardedSurfaceClearRequest(request_key: []const u8, client_id: []const u8, expected_revision: u64, session_id: []const u8) headless.store.SurfaceClearRequest {
    return .{
        .mutation = .{
            .request_key = request_key,
            .expected_store_revision = expected_revision,
            .client_id = client_id,
        },
        .session_id = session_id,
    };
}

pub const PendingAdoptionRow = struct {
    /// Legacy f76364f7 sidecars stored an absolute transcript index here.
    /// It remains readable as an optional hint, but repair validation is
    /// turn-scoped because unrelated turns may shift the durable transcript.
    row_index: ?usize = null,
    role: db_types.ChatRole,
    author: []const u8,
    body: []const u8,
};

pub const PendingAdoptionRepair = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    turn_id: []const u8,
    rows: []const PendingAdoptionRow = &.{},
};

pub const PendingStateSpool = struct {
    version: u32 = 1,
    capture_revision: u64,
    baseline_revision: ?u64 = null,
    current: PersistedState,
    baseline: ?PersistedState = null,
    adoption_repairs: []const PendingAdoptionRepair = &.{},
};

pub const LoadedPendingStateSpool = struct {
    arena: std.heap.ArenaAllocator,
    value: PendingStateSpool,

    pub fn deinit(self: *LoadedPendingStateSpool) void {
        self.arena.deinit();
    }
};

/// Mutable session state for daemon-routed mutations. Owned by Storage and
/// reachable through a const Storage pointer so AppState can keep `*const Storage`.
const StoreSession = struct {
    // Zig 0.16: no std.Thread.Mutex; match the rest of desktop with atomic spin lock.
    mutex: std.atomic.Mutex = .unlocked,
    client_id: ?[]u8 = null,
    store_revision: u64 = 0,
    /// True once we have observed a revision from RO load, storeStatus, or a write receipt.
    revision_known: bool = false,
    /// Revision whose durable projection was actually applied to AppState.
    /// This is deliberately separate from `store_revision`, which can move
    /// ahead after a status read or another writer's receipt.
    projection_observed_revision: u64 = 0,
    /// False when the daemon is unavailable or replacement is blocked; GUI stays
    /// visibly read-only/unsaved and never falls back to a direct writer.
    persistence_available: bool = true,
    request_counter: u64 = 0,
    // M5-P4 change-cursor projection sync (composite core.snapshot + journal
    // cursor). The cursor is nonce-scoped: it is only meaningful together with
    // the envelope identity below, and it is cleared whenever incremental
    // entries can no longer be trusted (journal expiry or daemon replacement)
    // so the cursor loop reseeds through exactly one composite snapshot.
    change_cursor: u64 = 0,
    change_cursor_known: bool = false,
    /// Owned copy of the last accepted envelope's instance nonce.
    instance_nonce: ?[]u8 = null,
    registry_revision: u64 = 0,
    /// Wall-clock ms of the last accepted changes/snapshot sync; 0 = never.
    projection_synced_at_ms: i64 = 0,

    fn lock(self: *StoreSession) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *StoreSession) void {
        self.mutex.unlock();
    }

    fn deinit(self: *StoreSession, allocator: std.mem.Allocator) void {
        if (self.client_id) |id| allocator.free(id);
        self.client_id = null;
        if (self.instance_nonce) |nonce| allocator.free(nonce);
        self.instance_nonce = null;
    }
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    projection_store_dir: []const u8,
    /// Read-only projection handle; null when no DB exists yet.
    client: ?db_client.Client = null,
    store_session: *StoreSession,

    pub fn init(allocator: std.mem.Allocator) !Storage {
        const pref_path = sdl.getPrefPath(ORG_NAME, APP_NAME) orelse return error.SdlError;
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);
        const effective_dir = try sessionizer.effectiveStoreDirectory(allocator, owned_pref_path);
        errdefer allocator.free(effective_dir.path);
        return initOwnedPaths(allocator, owned_pref_path, effective_dir.path);
    }

    /// Hermetic/test constructor that skips SDL pref-path resolution.
    pub fn initWithPrefPath(allocator: std.mem.Allocator, pref_path: []const u8) !Storage {
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);
        const effective_dir = try sessionizer.effectiveStoreDirectory(allocator, owned_pref_path);
        errdefer allocator.free(effective_dir.path);
        return initOwnedPaths(allocator, owned_pref_path, effective_dir.path);
    }

    fn initWithPaths(allocator: std.mem.Allocator, pref_path: []const u8, projection_store_dir: []const u8) !Storage {
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);
        const owned_projection_store_dir = try allocator.dupe(u8, projection_store_dir);
        errdefer allocator.free(owned_projection_store_dir);
        return initOwnedPaths(allocator, owned_pref_path, owned_projection_store_dir);
    }

    fn initOwnedPaths(allocator: std.mem.Allocator, owned_pref_path: []u8, owned_projection_store_dir: []u8) !Storage {
        const store_session = try allocator.create(StoreSession);
        errdefer allocator.destroy(store_session);
        store_session.* = .{};

        const client = try openReadOnlyOptional(allocator, owned_projection_store_dir);
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
            .projection_store_dir = owned_projection_store_dir,
            .client = client,
            .store_session = store_session,
        };
    }

    pub fn deinit(self: *Storage) void {
        // Best-effort unregister so long-lived daemons do not accumulate orphans (NIT-4).
        self.unregisterStoreClientBestEffort();
        if (self.client) |*client| client.deinit();
        self.store_session.deinit(self.allocator);
        self.allocator.destroy(self.store_session);
        self.allocator.free(self.projection_store_dir);
        self.allocator.free(self.pref_path);
    }

    pub fn load(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        if (self.client) |*client| {
            if (try client.load(allocator)) |loaded| {
                // Pin the durable revision observed in the same RO transaction so
                // launch-2 does not resend a guard-less bootstrap against a non-empty store.
                self.noteStoreRevision(loaded.store_revision);
                self.noteProjectionObservedRevision(loaded.store_revision);
                return loaded;
            }
            // DB exists but has no app snapshot (e.g. CLI-notify-only history):
            // still pin the real revision so the first flush is guarded.
            self.noteStoreRevision(client.storeRevision() catch 0);
            self.noteProjectionObservedRevision(self.currentStoreRevision());
        } else {
            // No DB yet: revision 0 is known; first write may bootstrap or use expected=0.
            self.noteStoreRevision(0);
            self.noteProjectionObservedRevision(0);
        }
        if (try self.loadLegacyJson(allocator)) |loaded| {
            errdefer {
                var owned_loaded = loaded;
                owned_loaded.deinit();
            }
            // Legacy import bootstraps only into a genuinely empty store; a
            // non-empty store (CLI history) gets a guarded replace instead so
            // the daemon's conflict check stays meaningful.
            const use_bootstrap = self.currentStoreRevision() == 0;
            try self.replaceSnapshot(loaded.value, use_bootstrap, self.currentProjectionObservedRevision());
            try self.reopenReadOnly();
            return loaded;
        }
        return null;
    }

    /// Read the current durable projection through an independent RO
    /// connection. Composite attach uses this after obtaining the daemon's
    /// cursor and volatile scopes, avoiding a full-store JSON response while
    /// retaining a revision paired with the SQLite read transaction.
    pub fn loadProjection(self: *const Storage, allocator: std.mem.Allocator) !LoadedPersistedState {
        var client = (try openReadOnlyOptional(allocator, self.projection_store_dir)) orelse {
            var empty = LoadedPersistedState.init(allocator);
            empty.store_revision = 0;
            return empty;
        };
        defer client.deinit();
        if (try client.load(allocator)) |loaded| return loaded;
        var empty = LoadedPersistedState.init(allocator);
        empty.store_revision = try client.storeRevision();
        return empty;
    }

    pub fn loadLegacyJson(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{});
        defer dir.close(threaded.io());

        const bytes = dir.readFileAlloc(threaded.io(), LEGACY_STATE_FILE_NAME, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);

        var loaded = LoadedPersistedState.init(allocator);
        errdefer loaded.deinit();
        loaded.value = try std.json.parseFromSliceLeaky(PersistedState, loaded.allocator(), bytes, .{
            .allocate = .alloc_always,
        });
        return loaded;
    }

    /// Load a close-time durability spool. The file remains until a later
    /// full-snapshot acknowledgement, so a crash during replay is idempotent.
    pub fn loadPendingStateSpool(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPendingStateSpool {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{});
        defer dir.close(threaded.io());
        const bytes = dir.readFileAlloc(
            threaded.io(),
            PENDING_STATE_SPOOL_FILE_NAME,
            allocator,
            .limited(PENDING_STATE_SPOOL_MAX_BYTES),
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const value = try std.json.parseFromSliceLeaky(PendingStateSpool, arena.allocator(), bytes, .{
            .allocate = .alloc_always,
        });
        if (value.version != 1) return error.UnsupportedPendingStateSpoolVersion;
        return .{ .arena = arena, .value = value };
    }

    /// Atomically replace and fsync the close-time spool before state teardown.
    pub fn writePendingStateSpool(self: *const Storage, spool: PendingStateSpool) !void {
        // Count first so an oversized state cannot make valueAlloc grow beyond
        // the replay ceiling before the limit is enforced.
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try std.json.Stringify.value(spool, .{ .whitespace = .minified }, &counter.writer);
        if (counter.fullCount() > PENDING_STATE_SPOOL_MAX_BYTES) return error.PendingStateSpoolExceedsReplayLimit;
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, spool, .{ .whitespace = .minified });
        defer self.allocator.free(encoded);
        std.debug.assert(encoded.len == counter.fullCount());
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        // Directory fsync cannot operate on Linux O_PATH handles; iteration
        // capability makes std.Io open a real readable directory descriptor.
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{
            .iterate = builtin.os.tag != .windows,
        });
        defer dir.close(threaded.io());
        var file = try dir.createFile(threaded.io(), PENDING_STATE_SPOOL_TEMP_FILE_NAME, .{ .truncate = true });
        var file_open = true;
        defer if (file_open) file.close(threaded.io());
        try file.writeStreamingAll(threaded.io(), encoded);
        try file.sync(threaded.io());
        file.close(threaded.io());
        file_open = false;
        try dir.rename(PENDING_STATE_SPOOL_TEMP_FILE_NAME, dir, PENDING_STATE_SPOOL_FILE_NAME, threaded.io());
        // POSIX rename durability requires the containing directory metadata
        // to reach disk too. Windows does not expose directory sync through
        // std.Io and its rename primitive has different persistence semantics.
        if (builtin.os.tag != .windows) {
            const dir_file: std.Io.File = .{
                .handle = dir.handle,
                .flags = .{ .nonblocking = false },
            };
            try dir_file.sync(threaded.io());
        }
    }

    /// Conservative allocation-free preflight for the compatibility snapshot
    /// request. The protocol envelope and converted enum strings add bytes, so
    /// reserve fixed headroom below the daemon's hard request ceiling.
    pub fn stateFitsSnapshotTransport(_: *const Storage, state: PersistedState) !bool {
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try std.json.Stringify.value(state, .{ .whitespace = .minified }, &counter.writer);
        return counter.fullCount() <= headless.protocol.MAX_MESSAGE_BYTES - SNAPSHOT_REQUEST_HEADROOM_BYTES;
    }

    pub fn clearPendingStateSpool(self: *const Storage) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.pref_path, .{});
        defer dir.close(threaded.io());
        dir.deleteFile(threaded.io(), PENDING_STATE_SPOOL_FILE_NAME) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    pub fn clearPendingStateSpoolBestEffort(self: *const Storage) void {
        self.clearPendingStateSpool() catch |err| {
            log.warn("failed to remove acknowledged pending-state spool: {s}", .{@errorName(err)});
        };
    }

    /// Compatibility whole-state save via `state.snapshot.replace`.
    pub fn save(self: *const Storage, state: PersistedState) !void {
        try self.saveCaptured(state, self.currentProjectionObservedRevision());
    }

    /// Persist one frame-thread capture under the exact revision that
    /// projection observed while that payload was built. The worker must not
    /// relabel it with a later guard learned from a cursor refresh.
    pub fn saveCaptured(self: *const Storage, state: PersistedState, observed_revision: u64) !void {
        try self.replaceSnapshot(state, false, observed_revision);
        try self.reopenReadOnly();
    }

    // Phase 4 owns incremental thread writes. Phase 3 keep-alive: full snapshot
    // via `save` / `persistThreadBlocking` (lifecycle builds the full state).
    // This stub remains so accidental Client-style call sites fail loudly.
    pub fn saveThread(_: *const Storage, _: []const u8, _: usize, _: PersistedThread) !void {
        return error.UseFullSnapshotSave;
    }

    pub fn upsertSurfaceState(self: *const Storage, surface: PersistedSurfaceState) !void {
        // NEW-2: gate on the same persistence_available clock as frame-loop
        // flush backoff — never run ensureDaemon's 5s spawn-poll on event threads
        // after a prior store failure. Self-heals when a snapshot flush succeeds.
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const protocol_surface = try persistence.surfaceToProtocol(a, surface);
        const result = try self.withClientRetry(a, "surface.upsert", struct {
            fn call(storage: *const Storage, arena_inner: std.mem.Allocator, op: []const u8, client_id: []const u8, expected: u64, s: headless.store.SurfaceState) !headless.store.WriteResult {
                const req: headless.store.SurfaceUpsertRequest = .{
                    .mutation = .{
                        .request_key = try storage.nextRequestKey(arena_inner, op),
                        .expected_store_revision = if (expected == 0) null else expected,
                        .client_id = client_id,
                    },
                    .surface = s,
                };
                return storage.callStoreMutationAllowConflict(headless.store.METHOD_SURFACE_UPSERT, req);
            }
        }.call, protocol_surface);
        self.noteStoreRevision(result.store_revision);
    }

    pub fn clearSurfaceCompletion(self: *const Storage, acknowledged: PersistedSurfaceState) !bool {
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const observation = try self.observeSurfaceCompletion(acknowledged);
            if (!observation.matches) return false;
            const client_id = try self.ensureExistingDaemonStoreClientId(ACKNOWLEDGEMENT_TIMEOUT_MS);
            defer self.allocator.free(client_id);
            const req = guardedSurfaceClearRequest(
                try self.nextRequestKey(a, "surface.clear"),
                client_id,
                observation.store_revision,
                acknowledged.session_id,
            );
            const result = self.callStoreMutationAllowConflictWithTimeout(
                headless.store.METHOD_SURFACE_CLEAR,
                req,
                ACKNOWLEDGEMENT_TIMEOUT_MS,
                false,
            ) catch |err| switch (err) {
                error.UnknownClientId => {
                    self.clearCachedClientId();
                    if (attempt == 0) continue;
                    return err;
                },
                error.StoreRevisionConflict => {
                    if (attempt == 0) continue;
                    const final_observation = try self.observeSurfaceCompletion(acknowledged);
                    if (!final_observation.matches) return false;
                    return err;
                },
                else => return err,
            };
            self.noteStoreRevision(result.store_revision);
            return result.applied;
        }
        unreachable;
    }

    const SurfaceCompletionObservation = struct {
        store_revision: u64,
        matches: bool,
    };

    fn observeSurfaceCompletion(self: *const Storage, acknowledged: PersistedSurfaceState) !SurfaceCompletionObservation {
        var client = (try openReadOnlyOptional(self.allocator, self.projection_store_dir)) orelse return error.SessionDaemonUnavailable;
        defer client.deinit();
        // Revision must be read first. A replacement after this read either is
        // seen by the identity query or makes the guarded clear conflict.
        const revision = try client.storeRevision();
        const matches = acknowledged.status == .done and try client.surfaceStateMatches(acknowledged);
        self.noteStoreRevision(revision);
        return .{ .store_revision = revision, .matches = matches };
    }

    pub fn clearSurfaceState(self: *const Storage, session_id: []const u8) !bool {
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try self.withAcknowledgementClientRetry(a, "surface.clear", struct {
            fn call(storage: *const Storage, arena_inner: std.mem.Allocator, op: []const u8, client_id: []const u8, expected: u64, sid: []const u8) !headless.store.WriteResult {
                const req: headless.store.SurfaceClearRequest = .{
                    .mutation = .{ .request_key = try storage.nextRequestKey(arena_inner, op), .expected_store_revision = if (expected == 0) null else expected, .client_id = client_id },
                    .session_id = sid,
                };
                return storage.callStoreMutationAllowConflictWithTimeout(headless.store.METHOD_SURFACE_CLEAR, req, ACKNOWLEDGEMENT_TIMEOUT_MS, false);
            }
        }.call, session_id);
        self.noteStoreRevision(result.store_revision);
        return result.applied;
    }

    pub fn upsertChatCompletion(self: *const Storage, completion: PersistedChatCompletion) !void {
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const payload: headless.store.ChatCompletion = .{
            .workspace_id = completion.workspace_id,
            .local_thread_id = completion.local_thread_id,
            .completed_at_ms = completion.completed_at_ms,
        };
        const result = try self.withClientRetry(a, "notification.chatCompletion.upsert", struct {
            fn call(storage: *const Storage, arena_inner: std.mem.Allocator, op: []const u8, client_id: []const u8, expected: u64, c: headless.store.ChatCompletion) !headless.store.WriteResult {
                const req: headless.store.NotificationChatCompletionUpsertRequest = .{
                    .mutation = .{
                        .request_key = try storage.nextRequestKey(arena_inner, op),
                        .expected_store_revision = if (expected == 0) null else expected,
                        .client_id = client_id,
                    },
                    .completion = c,
                };
                return storage.callStoreMutationAllowConflict(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT, req);
            }
        }.call, payload);
        self.noteStoreRevision(result.store_revision);
    }

    pub fn clearChatCompletion(self: *const Storage, workspace_id: []const u8, local_thread_id: []const u8) !bool {
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pair: struct { []const u8, []const u8 } = .{ workspace_id, local_thread_id };
        const result = try self.withAcknowledgementClientRetry(a, "notification.chatCompletion.clear", struct {
            fn call(storage: *const Storage, arena_inner: std.mem.Allocator, op: []const u8, client_id: []const u8, expected: u64, ids: struct { []const u8, []const u8 }) !headless.store.WriteResult {
                const req: headless.store.NotificationChatCompletionClearRequest = .{
                    .mutation = .{
                        .request_key = try storage.nextRequestKey(arena_inner, op),
                        .expected_store_revision = if (expected == 0) null else expected,
                        .client_id = client_id,
                    },
                    .workspace_id = ids[0],
                    .local_thread_id = ids[1],
                };
                return storage.callStoreMutationAllowConflictWithTimeout(
                    headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR,
                    req,
                    ACKNOWLEDGEMENT_TIMEOUT_MS,
                    false,
                );
            }
        }.call, pair);
        self.noteStoreRevision(result.store_revision);
        return result.applied;
    }

    pub fn classifySurfaceUpsertCommitProof(
        self: *const Storage,
        proof: SurfaceCommitProof,
        surface: headless.store.SurfaceState,
    ) !SurfaceCommitProofClassification {
        const persisted = protocolSurfaceToPersisted(surface) orelse return .invalid;
        const fingerprint = try headless.store.encode(self.allocator, surface);
        defer self.allocator.free(fingerprint);
        var client = (try openReadOnlyOptional(self.allocator, self.projection_store_dir)) orelse return .invalid;
        defer client.deinit();
        if (!try client.committedReceiptMatches(
            proof.request_key,
            headless.store.METHOD_SURFACE_UPSERT,
            fingerprint,
            proof.store_revision,
        )) return .invalid;
        return if (try client.surfaceStateMatches(persisted)) .current else .superseded;
    }

    pub fn classifySurfaceClearCommitProof(
        self: *const Storage,
        proof: SurfaceCommitProof,
        session_id: []const u8,
    ) !SurfaceCommitProofClassification {
        const fingerprint = try headless.store.encode(self.allocator, .{
            .session_id = session_id,
            .workspace_id = @as(?[]const u8, null),
        });
        defer self.allocator.free(fingerprint);
        var client = (try openReadOnlyOptional(self.allocator, self.projection_store_dir)) orelse return .invalid;
        defer client.deinit();
        if (!try client.committedReceiptMatches(
            proof.request_key,
            headless.store.METHOD_SURFACE_CLEAR,
            fingerprint,
            proof.store_revision,
        )) return .invalid;
        return if (try client.surfaceStateAbsent(session_id)) .current else .superseded;
    }

    pub fn isPersistenceAvailable(self: *const Storage) bool {
        self.store_session.lock();
        defer self.store_session.unlock();
        return self.store_session.persistence_available;
    }

    pub fn markPersistenceUnavailable(self: *const Storage) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        self.store_session.persistence_available = false;
    }

    pub fn currentStoreRevision(self: *const Storage) u64 {
        self.store_session.lock();
        defer self.store_session.unlock();
        return self.store_session.store_revision;
    }

    pub fn noteStoreRevision(self: *const Storage, revision: u64) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        // The durable revision is globally monotonic, so an out-of-order ack
        // (flush worker vs a concurrent granular mutation) must never regress
        // the cached guard.
        if (self.store_session.revision_known) {
            self.store_session.store_revision = @max(self.store_session.store_revision, revision);
        } else {
            self.store_session.store_revision = revision;
        }
        self.store_session.revision_known = true;
        self.store_session.persistence_available = true;
    }

    pub fn currentProjectionObservedRevision(self: *const Storage) u64 {
        self.store_session.lock();
        defer self.store_session.unlock();
        return self.store_session.projection_observed_revision;
    }

    pub fn currentInstanceNonceAlloc(self: *const Storage, allocator: std.mem.Allocator) ![]u8 {
        self.store_session.lock();
        defer self.store_session.unlock();
        return allocator.dupe(u8, self.store_session.instance_nonce orelse "");
    }

    fn noteProjectionObservedRevision(self: *const Storage, revision: u64) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        self.store_session.projection_observed_revision = revision;
    }

    /// Clear cached client identity so the next mutation re-registers (MAJOR-1).
    pub fn clearCachedClientId(self: *const Storage) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        if (self.store_session.client_id) |id| {
            self.allocator.free(id);
            self.store_session.client_id = null;
        }
    }

    /// Refresh durable revision from the RO projection or daemon.storeStatus.
    pub fn refreshStoreRevision(self: *const Storage) !u64 {
        // Prefer a fresh RO open of the local projection (no daemon required).
        // The purpose-built revision read avoids loading the full projection
        // on the conflict path and also covers projection-less DBs.
        if (openReadOnlyOptional(self.allocator, self.projection_store_dir)) |maybe_client| {
            if (maybe_client) |client_owned| {
                var client = client_owned;
                defer client.deinit();
                if (client.storeRevision()) |revision| {
                    self.noteStoreRevision(revision);
                    return revision;
                } else |_| {}
            }
        } else |_| {}

        // Fall back to daemon.storeStatus when the RO path cannot pin a revision.
        try self.ensureDaemon();
        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
            .timeout_ms = CLIENT_CLOSE_TIMEOUT_MS,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        const empty_params: struct {} = .{};
        var parsed = client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params) catch |err| {
            self.markPersistenceUnavailable();
            return err;
        };
        defer parsed.deinit();
        if (parsed.response.err) |_| {
            self.markPersistenceUnavailable();
            return error.SessionDaemonUnavailable;
        }
        const status = try client.decodeStoreStatus(&parsed);
        self.noteStoreRevision(status.store_revision);
        return status.store_revision;
    }

    fn refreshStoreRevisionFromExistingDaemon(self: *const Storage, timeout_ms: u32) !u64 {
        if (openReadOnlyOptional(self.allocator, self.projection_store_dir)) |maybe_client| {
            if (maybe_client) |client_owned| {
                var client = client_owned;
                defer client.deinit();
                if (client.storeRevision()) |revision| {
                    self.noteStoreRevision(revision);
                    return revision;
                } else |_| {}
            }
        } else |_| {}

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
            .timeout_ms = timeout_ms,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        const empty_params: struct {} = .{};
        var parsed = client.call(headless.store.METHOD_DAEMON_STORE_STATUS, empty_params) catch |err| {
            self.markPersistenceUnavailable();
            return err;
        };
        defer parsed.deinit();
        if (parsed.response.err) |_| {
            self.markPersistenceUnavailable();
            return error.SessionDaemonUnavailable;
        }
        const status = try client.decodeStoreStatus(&parsed);
        self.noteStoreRevision(status.store_revision);
        return status.store_revision;
    }

    // -----------------------------------------------------------------------
    // M5-P4 change-cursor projection plumbing.
    //
    // The desktop read flip keeps ONE nonce-scoped cursor here (next to the
    // durable store_revision guard) so the cursor loop thread and the main
    // loop share a single synchronized view. Nonce-change handling reuses the
    // M2-P3 reset path: the cached daemon client_id is cleared (MAJOR-1
    // re-register rule) and the volatile projection is re-pulled by the
    // cursor-triggered conversions, while the durable half is only ever
    // VALIDATED by store_revision (noteStoreRevision is monotonic) — the
    // journal is never a second source of truth.
    // -----------------------------------------------------------------------

    pub const ChangesNoteOutcome = struct {
        /// Incremental entries can no longer be trusted; the cursor loop must
        /// refresh through exactly ONE composite snapshot before resuming.
        snapshot_required: bool,
        /// The daemon instance changed (envelope nonce mismatch) — reuse the
        /// M2-P3 reset/resync path.
        instance_changed: bool,
    };

    /// Check the nonce boundary without acknowledging any entries. A caller
    /// that received real changes must first re-read and apply their durable
    /// projection, then publish the replacement snapshot cursor through
    /// noteCompositeSnapshotSeed. This keeps the old cursor dirty/retryable
    /// across transport, decode, allocation, and main-thread apply failures.
    pub fn inspectChangesResult(
        self: *const Storage,
        result: headless.changes_protocol.ChangesResult,
    ) ChangesNoteOutcome {
        self.store_session.lock();
        const previous: ?headless.registry.RegistryRevisionEnvelope = if (self.store_session.change_cursor_known) .{
            .instance_nonce = self.store_session.instance_nonce orelse "",
            .registry_revision = self.store_session.registry_revision,
        } else null;
        const instance_changed = if (previous) |p| p.shouldResetProjection(result.envelope) else false;
        const snapshot_required = result.expired or instance_changed;
        if (snapshot_required) self.store_session.change_cursor_known = false;
        self.store_session.unlock();
        if (instance_changed) self.clearCachedClientId();
        return .{
            .snapshot_required = snapshot_required,
            .instance_changed = instance_changed,
        };
    }

    /// Advance the change cursor from one accepted `core.changes` reply.
    ///
    /// PENDING_FIXES #27: the client-side nonce rule is the ONLY guard against
    /// a stale cross-instance cursor receiving a valid-looking heartbeat with
    /// a regressed next_cursor after daemon replacement — the server never
    /// forces a resync. This funnels EVERY changes result (heartbeats
    /// included) through `headless.client.advanceChangeCursor`, whose contract
    /// is `snapshot_required = result.expired or instance_changed`.
    pub fn noteChangesResult(
        self: *const Storage,
        result: headless.changes_protocol.ChangesResult,
    ) ChangesNoteOutcome {
        self.store_session.lock();
        const previous: ?headless.registry.RegistryRevisionEnvelope = if (self.store_session.change_cursor_known) .{
            .instance_nonce = self.store_session.instance_nonce orelse "",
            .registry_revision = self.store_session.registry_revision,
        } else null;
        const instance_changed = if (previous) |p| p.shouldResetProjection(result.envelope) else false;
        const advance = headless.client.advanceChangeCursor(previous, result);
        if (advance.snapshot_required) {
            // Do NOT adopt next_cursor: for expiry it is unusable, and for a
            // replaced instance it belongs to a projection we have not
            // resynced yet. Clearing forces the single snapshot fallback.
            self.store_session.change_cursor_known = false;
        } else {
            self.store_session.change_cursor = advance.next_cursor;
            self.store_session.change_cursor_known = true;
            self.store_session.registry_revision = result.envelope.registry_revision;
            self.store_session.projection_synced_at_ms = platform_runtime.unixTimestampMs();
        }
        self.store_session.unlock();

        // Durable revision is globally monotonic across instances: always
        // safe to fold in (noteStoreRevision clamps with @max).
        self.noteStoreRevision(result.store_revision);
        if (instance_changed) self.clearCachedClientId();
        return .{
            .snapshot_required = advance.snapshot_required,
            .instance_changed = instance_changed,
        };
    }

    /// Publish a seed only AFTER its owned composite payload has been applied
    /// to AppState. This is the apply-before-advance half of the cursor
    /// contract; callers must not invoke it merely because decoding succeeded.
    ///
    /// Seed (or reseed) cursor + envelope from one composite `core.snapshot`.
    /// The daemon captures the journal cursor BEFORE either state read, so a
    /// cursor seeded here can only over-deliver — never miss — entries
    /// relative to the snapshot contents (M5-P2 capture order).
    pub const PreparedCompositeSnapshotSeed = struct {
        instance_nonce: []u8,
        registry_revision: u64,
        change_cursor: u64,
        store_revision: u64,
    };

    /// Perform the only fallible seed work before the AppState projection is
    /// swapped. Committing this value below is allocation-free.
    pub fn prepareCompositeSnapshotSeed(
        self: *const Storage,
        envelope: headless.registry.RegistryRevisionEnvelope,
        change_cursor: u64,
        store_revision: u64,
    ) !PreparedCompositeSnapshotSeed {
        return .{
            .instance_nonce = try self.allocator.dupe(u8, envelope.instance_nonce),
            .registry_revision = envelope.registry_revision,
            .change_cursor = change_cursor,
            .store_revision = store_revision,
        };
    }

    pub fn discardPreparedCompositeSnapshotSeed(self: *const Storage, prepared: PreparedCompositeSnapshotSeed) void {
        self.allocator.free(prepared.instance_nonce);
    }

    /// Allocation-free publication, called only after the fully built
    /// projection has been swapped into AppState.
    pub fn commitPreparedCompositeSnapshotSeed(
        self: *const Storage,
        prepared: PreparedCompositeSnapshotSeed,
    ) void {
        self.store_session.lock();
        if (self.store_session.instance_nonce) |old| self.allocator.free(old);
        self.store_session.instance_nonce = prepared.instance_nonce;
        self.store_session.registry_revision = prepared.registry_revision;
        self.store_session.change_cursor = prepared.change_cursor;
        self.store_session.change_cursor_known = true;
        self.store_session.projection_synced_at_ms = platform_runtime.unixTimestampMs();
        self.store_session.projection_observed_revision = prepared.store_revision;
        if (self.store_session.revision_known) {
            self.store_session.store_revision = @max(self.store_session.store_revision, prepared.store_revision);
        } else {
            self.store_session.store_revision = prepared.store_revision;
        }
        self.store_session.revision_known = true;
        self.store_session.persistence_available = true;
        self.store_session.unlock();
    }

    /// Compatibility helper for tests and non-AppState callers. Production
    /// projection application uses prepare/commit around its atomic swap.
    pub fn noteCompositeSnapshotSeed(
        self: *const Storage,
        envelope: headless.registry.RegistryRevisionEnvelope,
        change_cursor: u64,
        store_revision: u64,
    ) !void {
        const prepared = try self.prepareCompositeSnapshotSeed(envelope, change_cursor, store_revision);
        self.commitPreparedCompositeSnapshotSeed(prepared);
    }

    /// Cursor for the next core.changes poll; null when the loop must
    /// bootstrap/fallback through a composite snapshot first.
    pub fn currentChangeCursorForPoll(self: *const Storage) ?u64 {
        self.store_session.lock();
        defer self.store_session.unlock();
        if (!self.store_session.change_cursor_known) return null;
        return self.store_session.change_cursor;
    }

    /// `revision_expired` arrives as a structured RPC error (never a result),
    /// so the cursor invalidation has its own entry point (Q7: converts into
    /// exactly one snapshot fallback, then a fresh cursor resumes).
    pub fn invalidateChangeCursorForSnapshotFallback(self: *const Storage) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        self.store_session.change_cursor_known = false;
    }

    pub fn daemonProjectionEverSynced(self: *const Storage) bool {
        self.store_session.lock();
        defer self.store_session.unlock();
        return self.store_session.projection_synced_at_ms != 0;
    }

    /// Freshness check for the stale indicator and projection-served Live
    /// reads: true only when a sync happened within `window_ms`.
    pub fn daemonProjectionSyncedWithinMs(self: *const Storage, now_ms: i64, window_ms: i64) bool {
        self.store_session.lock();
        defer self.store_session.unlock();
        if (self.store_session.projection_synced_at_ms == 0) return false;
        return now_ms - self.store_session.projection_synced_at_ms <= window_ms;
    }

    fn replaceSnapshot(self: *const Storage, state: PersistedState, bootstrap: bool, observed_revision: u64) !void {
        // Non-bootstrap flushes must never send expected=null against a non-empty store.
        if (!bootstrap and !self.revisionIsKnown()) {
            _ = self.refreshStoreRevision() catch |err| {
                log.warn("failed to pin store_revision before snapshot replace: {s}", .{@errorName(err)});
            };
        }

        const first = try self.replaceSnapshotOnce(state, bootstrap, observed_revision);
        if (first) |result| {
            self.noteStoreRevision(result.store_revision);
            self.noteProjectionObservedRevision(result.store_revision);
            return;
        }
        // A conflict means this payload was built from an older projection.
        // Refresh the guard for the next independently rebuilt flush, but
        // never resend the same stale snapshot under the newer revision: that
        // would erase the mutation which caused the conflict.
        if (bootstrap) return error.StoreRevisionConflict;
        _ = try self.refreshStoreRevision();
        return error.StoreRevisionConflict;
    }

    /// Returns null only on conflict (so the caller can refresh+retry). Other errors propagate.
    fn replaceSnapshotOnce(
        self: *const Storage,
        state: PersistedState,
        bootstrap: bool,
        observed_revision: u64,
    ) !?headless.store.WriteResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const snapshot = try persistence.persistedStateToProtocolSnapshot(a, state, observed_revision);
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, if (bootstrap) "snapshot.bootstrap" else "snapshot.replace");
        // bootstrap=true is reserved for legacy JSON import only. Normal saves
        // always send an expected revision (including 0 for an empty store).
        const expected: ?u64 = if (bootstrap) null else observed_revision;
        const request: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = expected,
                .client_id = client_id,
            },
            .snapshot = snapshot,
            .bootstrap = bootstrap,
        };
        return self.callStoreMutationAllowConflict(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, request) catch |err| {
            if (err == error.StoreRevisionConflict) return null;
            // Stale client_id after daemon restart: clear, re-register, one retry.
            if (err == error.UnknownClientId) {
                self.clearCachedClientId();
                const retry_id = try self.ensureStoreClientId();
                defer self.allocator.free(retry_id);
                const retry_key = try self.nextRequestKey(a, if (bootstrap) "snapshot.bootstrap" else "snapshot.replace");
                const retry_req: headless.store.SnapshotReplaceRequest = .{
                    .mutation = .{
                        .request_key = retry_key,
                        .expected_store_revision = expected,
                        .client_id = retry_id,
                    },
                    .snapshot = snapshot,
                    .bootstrap = bootstrap,
                };
                return self.callStoreMutationAllowConflict(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, retry_req) catch |retry_err| {
                    if (retry_err == error.StoreRevisionConflict) return null;
                    return retry_err;
                };
            }
            return err;
        };
    }

    fn revisionIsKnown(self: *const Storage) bool {
        self.store_session.lock();
        defer self.store_session.unlock();
        return self.store_session.revision_known;
    }

    fn ensureDaemon(self: *const Storage) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const exe_path = try std.process.executablePathAlloc(threaded.io(), self.allocator);
        defer self.allocator.free(exe_path);
        sessionizer.ensureDaemon(self.allocator, self.pref_path, exe_path) catch |err| {
            self.markPersistenceUnavailable();
            return err;
        };
    }

    fn ensureStoreClientId(self: *const Storage) ![]u8 {
        return self.ensureStoreClientIdWithOptionalTimeout(null);
    }

    fn ensureExistingDaemonStoreClientId(self: *const Storage, timeout_ms: u32) ![]u8 {
        return self.ensureStoreClientIdWithOptionalTimeout(timeout_ms);
    }

    fn ensureStoreClientIdWithOptionalTimeout(self: *const Storage, timeout_ms: ?u32) ![]u8 {
        self.store_session.lock();
        if (self.store_session.client_id) |id| {
            const owned = try self.allocator.dupe(u8, id);
            self.store_session.unlock();
            return owned;
        }
        self.store_session.unlock();

        if (timeout_ms == null) try self.ensureDaemon();

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
            .timeout_ms = timeout_ms orelse 5_000,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var registered = try client.call(headless.registry.METHOD_DAEMON_CLIENT_REGISTER, .{ .persistent = true });
        defer registered.deinit();
        if (registered.response.err) |_| {
            self.markPersistenceUnavailable();
            return error.SessionDaemonUnavailable;
        }
        const reg = try client.decodeClientRegister(&registered);

        self.store_session.lock();
        defer self.store_session.unlock();
        if (self.store_session.client_id) |existing| {
            return try self.allocator.dupe(u8, existing);
        }
        const owned = try self.allocator.dupe(u8, reg.client_id);
        self.store_session.client_id = owned;
        return try self.allocator.dupe(u8, owned);
    }

    fn unregisterStoreClientBestEffort(self: *const Storage) void {
        self.store_session.lock();
        const client_id = self.store_session.client_id orelse {
            self.store_session.unlock();
            return;
        };
        const id_copy = self.allocator.dupe(u8, client_id) catch {
            self.store_session.unlock();
            return;
        };
        self.store_session.unlock();
        defer self.allocator.free(id_copy);

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var closed = client.call(headless.registry.METHOD_DAEMON_CLIENT_CLOSE, .{ .client_id = id_copy }) catch return;
        defer closed.deinit();
        // Tolerate failure silently (daemon already gone, etc.).
    }

    fn nextRequestKey(self: *const Storage, arena: std.mem.Allocator, op: []const u8) ![]const u8 {
        self.store_session.lock();
        self.store_session.request_counter +%= 1;
        const counter = self.store_session.request_counter;
        self.store_session.unlock();
        return try std.fmt.allocPrint(arena, "desktop:{s}:{d}:{d}", .{
            op,
            platform_runtime.unixTimestampMs(),
            counter,
        });
    }

    /// NEW-2: skip ensureDaemon when persistence is already known unavailable so
    /// surface/completion event threads do not stall up to 5s on every click.
    /// Mirrors the frame-loop `next_flush_attempt_ms` gate (lifecycle_controller)
    /// via the shared `persistence_available` clock — restored only by a successful
    /// write receipt (`noteStoreRevision`) or explicit recovery.
    fn ensureGranularMutationAllowed(self: *const Storage) !void {
        if (!self.isPersistenceAvailable()) return error.SessionDaemonUnavailable;
    }

    /// On unknown-client or a stale optimistic guard, refresh the single
    /// relevant owner and retry once. Granular mutations cannot defer a
    /// conflict to a whole-snapshot flush: doing so lets that later snapshot
    /// erase the explicit remote notification/session mutation.
    fn withClientRetry(
        self: *const Storage,
        arena: std.mem.Allocator,
        op: []const u8,
        comptime callFn: anytype,
        payload: anytype,
    ) !headless.store.WriteResult {
        var expected = self.currentStoreRevision();
        var client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        return callFn(self, arena, op, client_id, expected, payload) catch |err| {
            switch (err) {
                error.UnknownClientId => {
                    self.clearCachedClientId();
                    const retry_id = try self.ensureStoreClientId();
                    self.allocator.free(client_id);
                    client_id = retry_id;
                },
                error.StoreRevisionConflict => {
                    expected = try self.refreshStoreRevision();
                },
                else => return err,
            }
            return callFn(self, arena, op, client_id, expected, payload);
        };
    }

    /// Focus clears are idempotent and already off-thread. They may register
    /// with an existing daemon, but never start or replace one: that keeps an
    /// owned acknowledgement worker's close-time join to finite subsecond
    /// phases even when registration or the clear exhausts its budget.
    fn withAcknowledgementClientRetry(
        self: *const Storage,
        arena: std.mem.Allocator,
        op: []const u8,
        comptime callFn: anytype,
        payload: anytype,
    ) !headless.store.WriteResult {
        var expected = self.currentStoreRevision();
        var client_id = try self.ensureExistingDaemonStoreClientId(ACKNOWLEDGEMENT_TIMEOUT_MS);
        defer self.allocator.free(client_id);
        return callFn(self, arena, op, client_id, expected, payload) catch |err| {
            switch (err) {
                error.UnknownClientId => {
                    self.clearCachedClientId();
                    const retry_id = try self.ensureExistingDaemonStoreClientId(ACKNOWLEDGEMENT_TIMEOUT_MS);
                    self.allocator.free(client_id);
                    client_id = retry_id;
                },
                error.StoreRevisionConflict => {
                    expected = try self.refreshStoreRevisionFromExistingDaemon(ACKNOWLEDGEMENT_TIMEOUT_MS);
                },
                else => return err,
            }
            return callFn(self, arena, op, client_id, expected, payload);
        };
    }

    fn callStoreMutationAllowConflict(self: *const Storage, method: []const u8, params: anytype) !headless.store.WriteResult {
        return self.callStoreMutationAllowConflictWithTimeout(method, params, 5_000, true);
    }

    fn callStoreMutationAllowConflictWithTimeout(
        self: *const Storage,
        method: []const u8,
        params: anytype,
        timeout_ms: u32,
        ensure_daemon: bool,
    ) !headless.store.WriteResult {
        // Focus acknowledgements already obtained a daemon-issued client id
        // and may skip this redundant status round-trip. Other mutations keep
        // the existing recovery behavior when the cached daemon disappeared.
        if (ensure_daemon) try self.ensureDaemon();

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
            .timeout_ms = timeout_ms,
        };
        var client = sessionizer.headlessClient(decode_arena.allocator(), &transport);
        var parsed = client.call(method, params) catch |err| {
            self.markPersistenceUnavailable();
            return err;
        };
        defer parsed.deinit();
        if (parsed.response.err) |err| {
            log.err("store mutation {s} failed: {s} ({s})", .{ method, err.code, err.message });
            if (std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE) or
                std.mem.eql(u8, err.code, headless.protocol.ERR_UNKNOWN_METHOD) or
                std.mem.eql(u8, err.code, "method_not_found"))
            {
                self.markPersistenceUnavailable();
                return error.SessionDaemonUnavailable;
            }
            if (std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) {
                // Do not mark unavailable yet — caller may refresh+retry once.
                return error.StoreRevisionConflict;
            }
            // NEW-5(c): sniff only the daemon's actual message ("unknown client_id"),
            // not a broad "client_id" substring that would spuriously re-register.
            if (std.mem.eql(u8, err.code, headless.protocol.ERR_INVALID_PARAMS) and
                std.mem.indexOf(u8, err.message, "unknown client_id") != null)
            {
                return error.UnknownClientId;
            }
            self.markPersistenceUnavailable();
            return error.StoreMutationFailed;
        }
        const result = try client.decodeWriteResult(&parsed);
        return .{
            .store_revision = result.store_revision,
            .applied = result.applied,
            .duplicate = result.duplicate,
        };
    }

    fn reopenReadOnly(self: *const Storage) !void {
        const mutable: *Storage = @constCast(self);
        if (mutable.client) |*client| {
            client.deinit();
            mutable.client = null;
        }
        mutable.client = openReadOnlyOptional(self.allocator, self.projection_store_dir) catch |err| return err;
    }
};

fn openReadOnlyOptional(allocator: std.mem.Allocator, pref_path: []const u8) !?db_client.Client {
    return db_client.Client.initReadOnly(allocator, pref_path) catch |err| switch (err) {
        error.CantOpen => null,
        else => err,
    };
}

test "conditional surface clear encodes revision zero as a present CAS guard" {
    const req = guardedSurfaceClearRequest("zero-guard", "test-client", 0, "session-zero");
    try std.testing.expect(req.mutation.expected_store_revision != null);
    try std.testing.expectEqual(@as(u64, 0), req.mutation.expected_store_revision.?);
}

test "RO load pins store_revision from store_state for launch-2 guard" {
    // BLOCKER-1 session-lifecycle pin: a DB left at revision ≥1 must teach
    // Storage the guard without a mutation, so the next replace is not bootstrap.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const pref_path = try std.testing.allocator.dupe(u8, path_buf[0..path_len]);
    defer std.testing.allocator.free(pref_path);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ pref_path, "state.sqlite" });
    defer std.testing.allocator.free(db_path);

    {
        const store = @import("../daemon/store.zig");
        var writer = try store.Store.init(std.testing.allocator, db_path);
        defer writer.deinit();
        const result = try writer.applyMutation(.{
            .workspace_upsert = .{
                .mutation = .{
                    .request_key = "pin-ws",
                    .client_id = "test-client",
                },
                .workspace = .{
                    .workspace_id = "pin-ws",
                    .label = "Pinned",
                    .path = "/pin",
                },
            },
        });
        try std.testing.expectEqual(@as(u64, 1), result.store_revision);
    }

    var storage = try Storage.initWithPrefPath(std.testing.allocator, pref_path);
    defer storage.deinit();
    try std.testing.expect(storage.client != null);
    // A workspace upsert bumps the revision but writes no app_state row, so
    // the projection is legitimately absent — the guard must be pinned anyway.
    const loaded = try storage.load(std.testing.allocator);
    try std.testing.expect(loaded == null);
    try std.testing.expect(storage.revisionIsKnown());
    // Non-bootstrap replace must use expected=1, never bootstrap=true.
    try std.testing.expectEqual(@as(u64, 1), storage.currentStoreRevision());
}

test "projection load uses an independent coherent RO transaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const pref_path = path_buf[0..path_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ pref_path, db_client.STATE_DB_NAME });
    defer std.testing.allocator.free(db_path);
    const projects = [_]db_types.PersistedProject{.{
        .id = "large-state-workspace",
        .label = "Loaded without daemon JSON",
        .path = "/tmp/large-state-workspace",
    }};
    {
        var writer = try db_client.Client.init(std.testing.allocator, pref_path);
        defer writer.deinit();
        try writer.save(.{ .projects = &projects });
    }
    {
        const store = @import("../daemon/store.zig");
        var writer = try store.Store.init(std.testing.allocator, db_path);
        defer writer.deinit();
        const result = try writer.applyMutation(.{
            .workspace_upsert = .{
                .mutation = .{
                    .request_key = "projection-load-revision",
                    .client_id = "test-client",
                },
                .workspace = .{
                    .workspace_id = "large-state-workspace",
                    .label = "Loaded without daemon JSON",
                    .path = "/tmp/large-state-workspace",
                },
            },
        });
        try std.testing.expectEqual(@as(u64, 1), result.store_revision);
    }

    var storage = try Storage.initWithPrefPath(std.testing.allocator, pref_path);
    defer storage.deinit();
    var loaded = try storage.loadProjection(std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.store_revision);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.projects.len);
    try std.testing.expectEqualStrings("Loaded without daemon JSON", loaded.value.projects[0].label);
}

test "effective projection store is independent from pref artifacts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "pref", .fromMode(0o755));
    try tmp.dir.createDir(std.testing.io, "store", .fromMode(0o755));
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const pref_path = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "pref" });
    defer allocator.free(pref_path);
    const store_dir = try std.fs.path.join(allocator, &.{ root_buf[0..root_len], "store" });
    defer allocator.free(store_dir);
    const db_path = try std.fs.path.join(allocator, &.{ store_dir, db_client.STATE_DB_NAME });
    defer allocator.free(db_path);

    const surface: headless.store.SurfaceState = .{
        .session_id = "override-session",
        .workspace_id = "override-workspace",
        .workspace_path = "/override",
        .dock_id = 1,
        .pane_id = 2,
        .title = "Override surface",
        .status = "done",
        .status_changed_at_ms = 10,
        .completed_at_ms = 11,
    };
    var surface_revision: u64 = 0;
    const projects = [_]db_types.PersistedProject{.{
        .id = "override-workspace",
        .label = "Override",
        .path = "/override",
    }};
    {
        var writer = try db_client.Client.init(allocator, store_dir);
        defer writer.deinit();
        try writer.save(.{ .projects = &projects });
    }
    {
        const store = @import("../daemon/store.zig");
        var writer = try store.Store.init(allocator, db_path);
        defer writer.deinit();
        _ = try writer.applyMutation(.{ .workspace_upsert = .{
            .mutation = .{ .request_key = "override-workspace", .client_id = "test-client" },
            .workspace = .{ .workspace_id = "override-workspace", .label = "Override", .path = "/override" },
        } });
        const result = try writer.applyMutation(.{ .surface_upsert = .{
            .mutation = .{ .request_key = "override-surface", .expected_store_revision = 1, .client_id = "test-client" },
            .surface = surface,
        } });
        surface_revision = result.store_revision;
    }

    var storage = try Storage.initWithPaths(allocator, pref_path, store_dir);
    defer storage.deinit();
    try std.testing.expectEqualStrings(pref_path, storage.pref_path);
    try std.testing.expectEqualStrings(store_dir, storage.projection_store_dir);
    try std.testing.expect(storage.client != null);
    var loaded = try storage.loadProjection(allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(surface_revision, loaded.store_revision);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.projects.len);
    try std.testing.expectEqual(surface_revision, try storage.refreshStoreRevision());
    try std.testing.expectEqual(
        SurfaceCommitProofClassification.current,
        try storage.classifySurfaceUpsertCommitProof(.{
            .request_key = "override-surface",
            .store_revision = surface_revision,
        }, surface),
    );

    // Non-SQLite state remains rooted in pref_path even with a distinct store.
    try storage.writePendingStateSpool(.{ .capture_revision = surface_revision, .current = .{} });
    var spool = (try storage.loadPendingStateSpool(allocator)).?;
    defer spool.deinit();
    try std.testing.expectEqual(surface_revision, spool.value.capture_revision);
    try std.testing.expectEqualStrings(pref_path, storage.pref_path);
}

test "M5-P4 reconnect-from-cursor: same-instance results advance the cursor and pin the durable revision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    // Bootstrap requires a snapshot seed first.
    try std.testing.expect(storage.currentChangeCursorForPoll() == null);
    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 3 }, 7, 4);
    try std.testing.expectEqual(@as(?u64, 7), storage.currentChangeCursorForPoll());
    try std.testing.expectEqual(@as(u64, 4), storage.currentStoreRevision());
    try std.testing.expect(storage.daemonProjectionEverSynced());

    // A same-nonce reply (entries or heartbeat) advances without a fallback.
    const advanced = storage.noteChangesResult(.{
        .entries = &.{},
        .next_cursor = 9,
        .journal_floor_seq = 0,
        .expired = false,
        .heartbeat = true,
        .envelope = .{ .instance_nonce = "nonce-a", .registry_revision = 5 },
        .store_revision = 6,
    });
    try std.testing.expect(!advanced.snapshot_required and !advanced.instance_changed);
    try std.testing.expectEqual(@as(?u64, 9), storage.currentChangeCursorForPoll());
    try std.testing.expectEqual(@as(u64, 6), storage.currentStoreRevision());
}

test "M5-P4 dirty entries remain unacknowledged until their projection re-read applies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 1 }, 7, 10);
    const result: headless.changes_protocol.ChangesResult = .{
        .entries = &.{.{
            .change_seq = 8,
            .topic = "workspace",
            .resource_id = "workspace-new",
            .store_revision = 11,
        }},
        .next_cursor = 8,
        .envelope = .{ .instance_nonce = "nonce-a", .registry_revision = 1 },
        .store_revision = 11,
    };
    const inspection = storage.inspectChangesResult(result);
    try std.testing.expect(!inspection.snapshot_required);
    // A failed list/snapshot re-read leaves both the effective cursor and the
    // GUI flush guard at the last applied projection.
    try std.testing.expectEqual(@as(?u64, 7), storage.currentChangeCursorForPoll());
    try std.testing.expectEqual(@as(u64, 10), storage.currentStoreRevision());
    // Successful application publishes the replacement snapshot cursor only
    // afterward (the call below models that explicit main-thread boundary).
    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 1 }, 9, 11);
    try std.testing.expectEqual(@as(?u64, 9), storage.currentChangeCursorForPoll());
    try std.testing.expectEqual(@as(u64, 11), storage.currentStoreRevision());
}

test "M5-P4 replacement resync (#27): regressed heartbeat under a new nonce forces the snapshot fallback" {
    // PENDING_FIXES #27: after daemon replacement a stale cursor gets .ok
    // heartbeats with next_cursor regressed to the fresh journal's tail — no
    // revision_expired. Only the client-side nonce compare catches it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 3 }, 40, 5);
    // Simulate a stale cached client identity from the replaced instance.
    storage.store_session.lock();
    storage.store_session.client_id = try std.testing.allocator.dupe(u8, "replaced-instance-client");
    storage.store_session.unlock();

    const outcome = storage.noteChangesResult(.{
        .entries = &.{},
        .next_cursor = 0, // regressed, valid-looking
        .journal_floor_seq = 0,
        .expired = false,
        .heartbeat = true,
        .envelope = .{ .instance_nonce = "nonce-b", .registry_revision = 1 },
        .store_revision = 6,
    });
    try std.testing.expect(outcome.snapshot_required);
    try std.testing.expect(outcome.instance_changed);
    // Cursor invalidated → the loop's next iteration performs the single
    // composite-snapshot fallback; regressed cursor 0 was NOT adopted.
    try std.testing.expect(storage.currentChangeCursorForPoll() == null);
    // Durable revision only moves forward (globally monotonic across instances).
    try std.testing.expectEqual(@as(u64, 6), storage.currentStoreRevision());
    // M2-P3 reset reuse: cached client id cleared for re-register.
    storage.store_session.lock();
    try std.testing.expect(storage.store_session.client_id == null);
    storage.store_session.unlock();

    // The fallback reseeds under the new nonce and the loop resumes.
    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-b", .registry_revision = 1 }, 2, 6);
    try std.testing.expectEqual(@as(?u64, 2), storage.currentChangeCursorForPoll());
}

test "M5-P4 journal expiry invalidates the cursor for exactly one snapshot fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 1 }, 1, 1);
    storage.invalidateChangeCursorForSnapshotFallback();
    try std.testing.expect(storage.currentChangeCursorForPoll() == null);
    // One snapshot fallback restores incremental polling.
    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 2 }, 12, 9);
    try std.testing.expectEqual(@as(?u64, 12), storage.currentChangeCursorForPoll());
    // The expired-result shape (result.expired=true) also routes through the
    // #27 rule: snapshot_required regardless of nonce equality.
    const outcome = storage.noteChangesResult(.{
        .entries = &.{},
        .next_cursor = 12,
        .journal_floor_seq = 12,
        .expired = true,
        .heartbeat = false,
        .envelope = .{ .instance_nonce = "nonce-a", .registry_revision = 2 },
        .store_revision = 9,
    });
    try std.testing.expect(outcome.snapshot_required);
    try std.testing.expect(!outcome.instance_changed);
    try std.testing.expect(storage.currentChangeCursorForPoll() == null);
}

test "clearCachedClientId drops the registered identity for re-register" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const pref_path = try std.testing.allocator.dupe(u8, path_buf[0..path_len]);
    defer std.testing.allocator.free(pref_path);

    var storage = try Storage.initWithPrefPath(std.testing.allocator, pref_path);
    defer storage.deinit();

    storage.store_session.lock();
    storage.store_session.client_id = try std.testing.allocator.dupe(u8, "stale-daemon-client");
    storage.store_session.unlock();

    storage.clearCachedClientId();
    storage.store_session.lock();
    defer storage.store_session.unlock();
    try std.testing.expect(storage.store_session.client_id == null);
}

test "capture revision remains bound when the write guard advances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    try storage.noteCompositeSnapshotSeed(.{ .instance_nonce = "nonce-a", .registry_revision = 1 }, 4, 7);
    const captured = storage.currentProjectionObservedRevision();
    storage.noteStoreRevision(9);
    try std.testing.expectEqual(@as(u64, 7), captured);
    try std.testing.expectEqual(@as(u64, 7), storage.currentProjectionObservedRevision());
    try std.testing.expectEqual(@as(u64, 9), storage.currentStoreRevision());
}

test "pending state spool is durable, replayable, and acknowledgement-cleared" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();

    const baseline_projects = [_]db_types.PersistedProject{.{
        .id = "spool-workspace",
        .label = "Before",
        .path = "/tmp/spool-workspace",
    }};
    const current_projects = [_]db_types.PersistedProject{.{
        .id = "spool-workspace",
        .label = "Unsaved after repair failure",
        .path = "/tmp/spool-workspace",
    }};
    const rows = [_]PendingAdoptionRow{.{
        .row_index = 1,
        .role = .assistant,
        .author = "Codex",
        .body = "unsaved reply",
    }};
    const repairs = [_]PendingAdoptionRepair{.{
        .workspace_id = "spool-workspace",
        .local_thread_id = "spool-thread",
        .turn_id = "spool-turn",
        .rows = &rows,
    }};
    try storage.writePendingStateSpool(.{
        .capture_revision = 41,
        .baseline_revision = 41,
        .current = .{ .projects = &current_projects },
        .baseline = .{ .projects = &baseline_projects },
        .adoption_repairs = &repairs,
    });

    var loaded = (try storage.loadPendingStateSpool(std.testing.allocator)).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 41), loaded.value.capture_revision);
    try std.testing.expectEqual(@as(?u64, 41), loaded.value.baseline_revision);
    try std.testing.expectEqualStrings("Unsaved after repair failure", loaded.value.current.projects[0].label);
    try std.testing.expectEqualStrings("Before", loaded.value.baseline.?.projects[0].label);
    try std.testing.expectEqualStrings("spool-turn", loaded.value.adoption_repairs[0].turn_id);
    // f76364f7 encoded row_index as a required bare number. The optional hint
    // keeps that exact old JSON shape readable while new validation ignores it.
    try std.testing.expectEqual(@as(?usize, 1), loaded.value.adoption_repairs[0].rows[0].row_index);
    try storage.clearPendingStateSpool();
    try std.testing.expect((try storage.loadPendingStateSpool(std.testing.allocator)) == null);
}

test "snapshot transport preflight rejects a full-state payload without allocating its request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    var storage = try Storage.initWithPrefPath(std.testing.allocator, path_buf[0..path_len]);
    defer storage.deinit();
    try std.testing.expect(try storage.stateFitsSnapshotTransport(.{}));

    const body = try std.testing.allocator.alloc(u8, headless.protocol.MAX_MESSAGE_BYTES);
    defer std.testing.allocator.free(body);
    @memset(body, 'x');
    const messages = [_]db_types.PersistedMessage{.{
        .role = .assistant,
        .author = "test",
        .body = body,
    }};
    try std.testing.expect(!try storage.stateFitsSnapshotTransport(.{ .messages = &messages }));
}
