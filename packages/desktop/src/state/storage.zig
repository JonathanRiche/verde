//! Native state database ownership and legacy JSON loading.
//!
//! After the M3 Phase 3 authority flip, production mutations go through the
//! session daemon (`state.snapshot.replace` and granular store methods). The
//! local SQLite handle is read-only for bulk startup/offline projection and
//! never runs schema initialization or writes.

const std = @import("std");
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
const LoadedPersistedState = db_types.LoadedState;
const PersistedState = db_types.PersistedState;
const PersistedThread = db_types.PersistedThread;
const PersistedSurfaceState = db_types.PersistedSurfaceState;
const PersistedChatCompletion = db_types.PersistedChatCompletion;
const log = std.log.scoped(.native_shell);

/// Mutable session state for daemon-routed mutations. Owned by Storage and
/// reachable through a const Storage pointer so AppState can keep `*const Storage`.
const StoreSession = struct {
    // Zig 0.16: no std.Thread.Mutex; match the rest of desktop with atomic spin lock.
    mutex: std.atomic.Mutex = .unlocked,
    client_id: ?[]u8 = null,
    store_revision: u64 = 0,
    /// True once we have observed a revision from RO load, storeStatus, or a write receipt.
    revision_known: bool = false,
    /// False when the daemon is unavailable or replacement is blocked; GUI stays
    /// visibly read-only/unsaved and never falls back to a direct writer.
    persistence_available: bool = true,
    request_counter: u64 = 0,

    fn lock(self: *StoreSession) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *StoreSession) void {
        self.mutex.unlock();
    }

    fn deinit(self: *StoreSession, allocator: std.mem.Allocator) void {
        if (self.client_id) |id| allocator.free(id);
        self.client_id = null;
    }
};

pub const Storage = struct {
    allocator: std.mem.Allocator,
    pref_path: []const u8,
    /// Read-only projection handle; null when no DB exists yet.
    client: ?db_client.Client = null,
    store_session: *StoreSession,

    pub fn init(allocator: std.mem.Allocator) !Storage {
        const pref_path = sdl.getPrefPath(ORG_NAME, APP_NAME) orelse return error.SdlError;
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);

        const store_session = try allocator.create(StoreSession);
        errdefer allocator.destroy(store_session);
        store_session.* = .{};

        const client = openReadOnlyOptional(allocator, owned_pref_path) catch |err| {
            allocator.destroy(store_session);
            return err;
        };
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
            .client = client,
            .store_session = store_session,
        };
    }

    /// Hermetic/test constructor that skips SDL pref-path resolution.
    pub fn initWithPrefPath(allocator: std.mem.Allocator, pref_path: []const u8) !Storage {
        const owned_pref_path = try allocator.dupe(u8, pref_path);
        errdefer allocator.free(owned_pref_path);

        const store_session = try allocator.create(StoreSession);
        errdefer allocator.destroy(store_session);
        store_session.* = .{};

        const client = openReadOnlyOptional(allocator, owned_pref_path) catch |err| {
            allocator.destroy(store_session);
            return err;
        };
        return .{
            .allocator = allocator,
            .pref_path = owned_pref_path,
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
        self.allocator.free(self.pref_path);
    }

    pub fn load(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        if (self.client) |*client| {
            if (try client.load(allocator)) |loaded| {
                // Pin the durable revision observed in the same RO transaction so
                // launch-2 does not resend a guard-less bootstrap against a non-empty store.
                self.noteStoreRevision(loaded.store_revision);
                return loaded;
            }
            // DB exists but has no app snapshot (e.g. CLI-notify-only history):
            // still pin the real revision so the first flush is guarded.
            self.noteStoreRevision(client.storeRevision() catch 0);
        } else {
            // No DB yet: revision 0 is known; first write may bootstrap or use expected=0.
            self.noteStoreRevision(0);
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
            try self.replaceSnapshot(loaded.value, use_bootstrap);
            try self.reopenReadOnly();
            return loaded;
        }
        return null;
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

    /// Compatibility whole-state save via `state.snapshot.replace`.
    pub fn save(self: *const Storage, state: PersistedState) !void {
        try self.replaceSnapshot(state, false);
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

    pub fn clearSurfaceState(self: *const Storage, session_id: []const u8) !bool {
        try self.ensureGranularMutationAllowed();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const result = try self.withClientRetry(a, "surface.clear", struct {
            fn call(storage: *const Storage, arena_inner: std.mem.Allocator, op: []const u8, client_id: []const u8, expected: u64, sid: []const u8) !headless.store.WriteResult {
                const req: headless.store.SurfaceClearRequest = .{
                    .mutation = .{
                        .request_key = try storage.nextRequestKey(arena_inner, op),
                        .expected_store_revision = if (expected == 0) null else expected,
                        .client_id = client_id,
                    },
                    .session_id = sid,
                };
                return storage.callStoreMutationAllowConflict(headless.store.METHOD_SURFACE_CLEAR, req);
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
        const result = try self.withClientRetry(a, "notification.chatCompletion.clear", struct {
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
                return storage.callStoreMutationAllowConflict(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR, req);
            }
        }.call, pair);
        self.noteStoreRevision(result.store_revision);
        return result.applied;
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
        if (openReadOnlyOptional(self.allocator, self.pref_path)) |maybe_client| {
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

    fn replaceSnapshot(self: *const Storage, state: PersistedState, bootstrap: bool) !void {
        // Non-bootstrap flushes must never send expected=null against a non-empty store.
        if (!bootstrap and !self.revisionIsKnown()) {
            _ = self.refreshStoreRevision() catch |err| {
                log.warn("failed to pin store_revision before snapshot replace: {s}", .{@errorName(err)});
            };
        }

        const first = try self.replaceSnapshotOnce(state, bootstrap);
        if (first) |result| {
            self.noteStoreRevision(result.store_revision);
            return;
        }
        // first == null means conflict → refresh + single retry (never re-bootstrap).
        if (bootstrap) return error.StoreRevisionConflict;
        _ = try self.refreshStoreRevision();
        const second = try self.replaceSnapshotOnce(state, false);
        if (second) |result| {
            self.noteStoreRevision(result.store_revision);
            return;
        }
        self.markPersistenceUnavailable();
        return error.StoreRevisionConflict;
    }

    /// Returns null only on conflict (so the caller can refresh+retry). Other errors propagate.
    fn replaceSnapshotOnce(
        self: *const Storage,
        state: PersistedState,
        bootstrap: bool,
    ) !?headless.store.WriteResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const snapshot = try persistence.persistedStateToProtocolSnapshot(a, state, self.currentStoreRevision());
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, if (bootstrap) "snapshot.bootstrap" else "snapshot.replace");
        // bootstrap=true is reserved for legacy JSON import only. Normal saves
        // always send an expected revision (including 0 for an empty store).
        const expected: ?u64 = if (bootstrap) null else self.currentStoreRevision();
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
        self.store_session.lock();
        if (self.store_session.client_id) |id| {
            const owned = try self.allocator.dupe(u8, id);
            self.store_session.unlock();
            return owned;
        }
        self.store_session.unlock();

        try self.ensureDaemon();

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
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

    /// On unknown-client (daemon restart), clear cache, re-register, retry once (MAJOR-1).
    /// Granular StoreRevisionConflict is intentionally not refresh+retried here:
    /// the next whole-snapshot flush (`replaceSnapshot`) refreshes the guard and
    /// self-heals. Event-thread mutators must stay cheap (no nested refresh/IPC).
    fn withClientRetry(
        self: *const Storage,
        arena: std.mem.Allocator,
        op: []const u8,
        comptime callFn: anytype,
        payload: anytype,
    ) !headless.store.WriteResult {
        const expected = self.currentStoreRevision();
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        return callFn(self, arena, op, client_id, expected, payload) catch |err| {
            if (err != error.UnknownClientId) return err;
            self.clearCachedClientId();
            const retry_id = try self.ensureStoreClientId();
            defer self.allocator.free(retry_id);
            return callFn(self, arena, op, retry_id, expected, payload);
        };
    }

    fn callStoreMutationAllowConflict(self: *const Storage, method: []const u8, params: anytype) !headless.store.WriteResult {
        try self.ensureDaemon();

        var decode_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer decode_arena.deinit();
        var transport: sessionizer.HeadlessTransport = .{
            .allocator = decode_arena.allocator(),
            .pref_path = self.pref_path,
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
        mutable.client = openReadOnlyOptional(self.allocator, self.pref_path) catch |err| return err;
    }
};

fn openReadOnlyOptional(allocator: std.mem.Allocator, pref_path: []const u8) !?db_client.Client {
    return db_client.Client.initReadOnly(allocator, pref_path) catch |err| switch (err) {
        error.CantOpen => null,
        else => err,
    };
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
