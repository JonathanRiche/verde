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
        if (self.client) |*client| client.deinit();
        self.store_session.deinit(self.allocator);
        self.allocator.destroy(self.store_session);
        self.allocator.free(self.pref_path);
    }

    pub fn load(self: *const Storage, allocator: std.mem.Allocator) !?LoadedPersistedState {
        if (self.client) |*client| {
            if (try client.load(allocator)) |loaded| {
                // Best-effort revision pin from the same projection when present.
                return loaded;
            }
        }
        if (try self.loadLegacyJson(allocator)) |loaded| {
            errdefer {
                var owned_loaded = loaded;
                owned_loaded.deinit();
            }
            // Legacy import is a daemon bootstrap mutation — never a direct writer.
            try self.replaceSnapshot(loaded.value, true);
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

    /// Targeted pre-turn thread durability is intentionally not a direct write.
    /// Lifecycle routes `persistThreadBlocking` through a full daemon snapshot.
    pub fn saveThread(_: *const Storage, _: []const u8, _: usize, _: PersistedThread) !void {
        return error.UseFullSnapshotSave;
    }

    pub fn upsertSurfaceState(self: *const Storage, surface: PersistedSurfaceState) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const protocol_surface = try persistence.surfaceToProtocol(a, surface);
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, "surface.upsert");
        const expected = self.currentStoreRevision();
        const request: headless.store.SurfaceUpsertRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = if (expected == 0) null else expected,
                .client_id = client_id,
            },
            .surface = protocol_surface,
        };
        const result = try self.callStoreMutation(headless.store.METHOD_SURFACE_UPSERT, request);
        self.noteStoreRevision(result.store_revision);
    }

    pub fn clearSurfaceState(self: *const Storage, session_id: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, "surface.clear");
        const expected = self.currentStoreRevision();
        const request: headless.store.SurfaceClearRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = if (expected == 0) null else expected,
                .client_id = client_id,
            },
            .session_id = session_id,
        };
        const result = try self.callStoreMutation(headless.store.METHOD_SURFACE_CLEAR, request);
        self.noteStoreRevision(result.store_revision);
        return result.applied;
    }

    pub fn upsertChatCompletion(self: *const Storage, completion: PersistedChatCompletion) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, "notification.chatCompletion.upsert");
        const expected = self.currentStoreRevision();
        const request: headless.store.NotificationChatCompletionUpsertRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = if (expected == 0) null else expected,
                .client_id = client_id,
            },
            .completion = .{
                .workspace_id = completion.workspace_id,
                .local_thread_id = completion.local_thread_id,
                .completed_at_ms = completion.completed_at_ms,
            },
        };
        const result = try self.callStoreMutation(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_UPSERT, request);
        self.noteStoreRevision(result.store_revision);
    }

    pub fn clearChatCompletion(self: *const Storage, workspace_id: []const u8, local_thread_id: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, "notification.chatCompletion.clear");
        const expected = self.currentStoreRevision();
        const request: headless.store.NotificationChatCompletionClearRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = if (expected == 0) null else expected,
                .client_id = client_id,
            },
            .workspace_id = workspace_id,
            .local_thread_id = local_thread_id,
        };
        const result = try self.callStoreMutation(headless.store.METHOD_NOTIFICATION_CHAT_COMPLETION_CLEAR, request);
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

    fn noteStoreRevision(self: *const Storage, revision: u64) void {
        self.store_session.lock();
        defer self.store_session.unlock();
        self.store_session.store_revision = revision;
        self.store_session.persistence_available = true;
    }

    fn replaceSnapshot(self: *const Storage, state: PersistedState, bootstrap: bool) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const snapshot = try persistence.persistedStateToProtocolSnapshot(a, state, self.currentStoreRevision());
        const client_id = try self.ensureStoreClientId();
        defer self.allocator.free(client_id);
        const request_key = try self.nextRequestKey(a, if (bootstrap) "snapshot.bootstrap" else "snapshot.replace");
        const expected = self.currentStoreRevision();
        const request: headless.store.SnapshotReplaceRequest = .{
            .mutation = .{
                .request_key = request_key,
                .expected_store_revision = if (bootstrap or expected == 0) null else expected,
                .client_id = client_id,
            },
            .snapshot = snapshot,
            .bootstrap = bootstrap or expected == 0,
        };
        const result = try self.callStoreMutation(headless.store.METHOD_STATE_SNAPSHOT_REPLACE, request);
        self.noteStoreRevision(result.store_revision);
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
            // Another thread won the race; keep the first and return a copy of it.
            return try self.allocator.dupe(u8, existing);
        }
        const owned = try self.allocator.dupe(u8, reg.client_id);
        self.store_session.client_id = owned;
        return try self.allocator.dupe(u8, owned);
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

    fn callStoreMutation(self: *const Storage, method: []const u8, params: anytype) !headless.store.WriteResult {
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
            self.markPersistenceUnavailable();
            log.err("store mutation {s} failed: {s} ({s})", .{ method, err.code, err.message });
            if (std.mem.eql(u8, err.code, headless.protocol.ERR_CAPABILITY_UNAVAILABLE) or
                std.mem.eql(u8, err.code, headless.protocol.ERR_UNKNOWN_METHOD) or
                std.mem.eql(u8, err.code, "method_not_found"))
            {
                return error.SessionDaemonUnavailable;
            }
            if (std.mem.eql(u8, err.code, headless.protocol.ERR_CONFLICT)) return error.StoreRevisionConflict;
            return error.StoreMutationFailed;
        }
        const result = try client.decodeWriteResult(&parsed);
        // Copy out of the decode arena before it is torn down.
        return .{
            .store_revision = result.store_revision,
            .applied = result.applied,
            .duplicate = result.duplicate,
        };
    }

    fn reopenReadOnly(self: *const Storage) !void {
        // Storage is const; mutate the optional client through a fixed pointer.
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
        // Missing DB is normal on first launch; the daemon creates it on first write.
        error.CantOpen => null,
        else => err,
    };
}
