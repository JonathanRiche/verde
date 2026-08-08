//! Dirty-state debounce and interaction lifecycle tracking.
//!
//! Phase 3 fix: frame-loop flush is scheduled off the render-critical path onto
//! a worker thread. Dirty clears only on daemon acknowledgement; failures back
//! off and mark persistence unavailable (visible unsaved/read-only). Shutdown
//! and pre-turn durability still use the blocking flush path.

const std = @import("std");
const platform_runtime = @import("platform_runtime");
const db_types = @import("../db/types.zig");
const storage_mod = @import("storage.zig");

const SAVE_DEBOUNCE_MS: i64 = 750;
/// Minimum delay before retrying a failed frame-loop flush (avoids per-frame storms).
const FLUSH_RETRY_BACKOFF_MS: i64 = 2000;
/// When persistence is unavailable, probe no more often than this interval.
const FLUSH_UNAVAILABLE_PROBE_MS: i64 = 5000;
const log = std.log.scoped(.native_shell);

const LoadedPersistedState = db_types.LoadedState;
const Storage = storage_mod.Storage;

const FlushWorkerResult = struct {
    success: bool = false,
    conflict: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const FlushWorkerArgs = struct {
    allocator: std.mem.Allocator,
    storage: *const Storage,
    loaded: ?LoadedPersistedState,
    baseline: ?LoadedPersistedState,
    observed_revision: u64,
    result: *FlushWorkerResult,
};

pub const State = struct {
    dirty: bool = false,
    last_dirty_at_ms: i64 = 0,
    last_interaction_at_ms: i64 = 0,
    /// Monotonic count of markDirty calls; an ack may clear dirty only when no
    /// mutation arrived after the acked snapshot was built.
    dirty_generation: u64 = 0,
    /// Worker currently running a daemon snapshot replace for a frame-loop flush.
    flush_in_flight: bool = false,
    flush_worker: ?std.Thread = null,
    flush_result: ?*FlushWorkerResult = null,
    flush_args: ?*FlushWorkerArgs = null,
    /// dirty_generation at the moment the in-flight worker's snapshot was built.
    flush_snapshot_generation: u64 = 0,
    /// Earliest wall-clock ms to attempt another frame-loop flush after a failure.
    next_flush_attempt_ms: i64 = 0,
    /// Payload rejected because its capture-time revision lost a race. It is
    /// retained until the cursor refresh rebases its local UI edits.
    rebase_snapshot: ?LoadedPersistedState = null,
    /// Daemon projection observed when the conflicted payload was captured.
    /// This distinguishes a local addition from an identity deleted remotely.
    rebase_baseline: ?LoadedPersistedState = null,
    /// Last successfully applied daemon projection, before local UI overlays.
    projection_baseline: ?LoadedPersistedState = null,

    pub fn markDirty(self: *State, now_ms: i64) void {
        self.dirty = true;
        self.last_dirty_at_ms = now_ms;
        self.dirty_generation +%= 1;
    }

    /// Clear dirty only if the acked snapshot covered every mutation so far;
    /// a stale ack leaves dirty set so the next flush picks up the newer state.
    pub fn clearDirtyForGeneration(self: *State, generation: u64) void {
        if (self.dirty_generation == generation) self.dirty = false;
    }

    pub fn noteInteraction(self: *State, now_ms: i64) void {
        self.last_interaction_at_ms = now_ms;
    }

    pub fn shouldFlush(self: State, now_ms: i64, debounce_ms: i64) bool {
        return self.dirty and
            now_ms - self.last_dirty_at_ms >= debounce_ms and
            now_ms - self.last_interaction_at_ms >= debounce_ms;
    }

    pub fn clearDirty(self: *State) void {
        self.dirty = false;
    }

    pub fn deinit(self: *State) void {
        if (self.rebase_snapshot) |*snapshot| snapshot.deinit();
        self.rebase_snapshot = null;
        if (self.rebase_baseline) |*snapshot| snapshot.deinit();
        self.rebase_baseline = null;
        if (self.projection_baseline) |*snapshot| snapshot.deinit();
        self.projection_baseline = null;
    }
};

pub fn markDirty(self: anytype) void {
    const now_ms = platform_runtime.unixTimestampMs();
    self.lifecycle.noteInteraction(now_ms);
    self.lifecycle.markDirty(now_ms);
}

pub fn noteInteraction(self: anytype) void {
    self.lifecycle.noteInteraction(platform_runtime.unixTimestampMs());
}

/// Frame-loop entry: poll any in-flight flush, then schedule a worker if due.
/// Never blocks on ensureDaemon/socket/fsync on the render thread.
pub fn flushIfDirty(self: anytype) void {
    pollFlushWorker(self);
    const now = platform_runtime.unixTimestampMs();
    if (!self.lifecycle.shouldFlush(now, SAVE_DEBOUNCE_MS)) return;
    if (self.lifecycle.flush_in_flight) return;
    if (now < self.lifecycle.next_flush_attempt_ms) return;

    scheduleFlushWorker(self, now);
}

fn scheduleFlushWorker(self: anytype, now_ms: i64) void {
    if (self.lifecycle.rebase_snapshot != null) return;
    if (self.hasUnresolvedAdoptionRows()) {
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    }
    const storage = self.storage;
    const observed_revision = storage.currentProjectionObservedRevision();
    var persisted = self.buildPersistedState(storage.allocator) catch |err| {
        log.err("failed to snapshot native state for async flush: {s}", .{@errorName(err)});
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    var baseline: ?LoadedPersistedState = if (self.lifecycle.projection_baseline) |snapshot|
        self.clonePersistedState(storage.allocator, snapshot.value) catch |err| {
            log.err("failed to capture daemon merge baseline: {s}", .{@errorName(err)});
            persisted.deinit();
            self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
            return;
        }
    else
        null;

    const result = storage.allocator.create(FlushWorkerResult) catch {
        if (baseline) |*snapshot| snapshot.deinit();
        persisted.deinit();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    result.* = .{};

    const args = storage.allocator.create(FlushWorkerArgs) catch {
        if (baseline) |*snapshot| snapshot.deinit();
        storage.allocator.destroy(result);
        persisted.deinit();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    args.* = .{
        .allocator = storage.allocator,
        .storage = storage,
        .loaded = persisted,
        .baseline = baseline,
        .observed_revision = observed_revision,
        .result = result,
    };

    const thread = std.Thread.spawn(.{}, flushWorkerMain, .{args}) catch |err| {
        log.err("failed to spawn state flush worker: {s}", .{@errorName(err)});
        // Take loaded back so we can deinit; args holds the moved value.
        var owned = args.loaded.?;
        owned.deinit();
        if (args.baseline) |*snapshot| snapshot.deinit();
        storage.allocator.destroy(args);
        storage.allocator.destroy(result);
        storage.markPersistenceUnavailable();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    self.lifecycle.flush_worker = thread;
    self.lifecycle.flush_result = result;
    self.lifecycle.flush_args = args;
    self.lifecycle.flush_in_flight = true;
    // Single-threaded scheduling: the snapshot above covers every mutation
    // up to this generation, and markDirty cannot interleave within this call.
    self.lifecycle.flush_snapshot_generation = self.lifecycle.dirty_generation;
}

fn flushWorkerMain(args: *FlushWorkerArgs) void {
    args.storage.saveCaptured(args.loaded.?.value, args.observed_revision) catch |err| {
        args.result.success = false;
        args.result.conflict = err == error.StoreRevisionConflict;
        args.result.done.store(true, .release);
        return;
    };
    args.result.success = true;
    args.result.done.store(true, .release);
}

/// Join a completed flush worker and apply ack / backoff. Safe to call every frame.
pub fn pollFlushWorker(self: anytype) void {
    if (!self.lifecycle.flush_in_flight) return;
    const result = self.lifecycle.flush_result orelse return;
    if (!result.done.load(.acquire)) return;

    if (self.lifecycle.flush_worker) |thread| {
        thread.join();
        self.lifecycle.flush_worker = null;
    }
    const success = result.success;
    const conflict = result.conflict;
    const storage = self.storage;
    if (self.lifecycle.flush_args) |args| {
        if (conflict) {
            if (self.lifecycle.rebase_snapshot) |*old| old.deinit();
            if (self.lifecycle.rebase_baseline) |*old| old.deinit();
            self.lifecycle.rebase_snapshot = args.loaded;
            args.loaded = null;
            self.lifecycle.rebase_baseline = args.baseline;
            args.baseline = null;
        }
        if (args.loaded) |*loaded| loaded.deinit();
        if (args.baseline) |*baseline| baseline.deinit();
        storage.allocator.destroy(args);
        self.lifecycle.flush_args = null;
    }
    storage.allocator.destroy(result);
    self.lifecycle.flush_result = null;
    self.lifecycle.flush_in_flight = false;

    const now = platform_runtime.unixTimestampMs();
    if (success) {
        self.lifecycle.clearDirtyForGeneration(self.lifecycle.flush_snapshot_generation);
        self.lifecycle.next_flush_attempt_ms = 0;
    } else if (conflict) {
        log.warn("async native state save conflicted; awaiting cursor rebase", .{});
        self.lifecycle.next_flush_attempt_ms = now + FLUSH_RETRY_BACKOFF_MS;
    } else {
        log.err("async native state save failed; retaining dirty and backing off", .{});
        storage.markPersistenceUnavailable();
        self.lifecycle.next_flush_attempt_ms = now + FLUSH_UNAVAILABLE_PROBE_MS;
    }
}

/// Blocking flush for shutdown and latency-sensitive pre-turn durability.
/// Waits for any in-flight worker first, then performs a synchronous save.
pub fn flushDirtyBlocking(self: anytype) void {
    // Drain any scheduled frame flush before a blocking path.
    if (self.lifecycle.flush_in_flight) {
        if (self.lifecycle.flush_worker) |thread| {
            thread.join();
            self.lifecycle.flush_worker = null;
        }
        pollFlushWorker(self);
    }
    while (self.lifecycle.dirty) {
        if (self.lifecycle.rebase_snapshot != null or self.hasUnresolvedAdoptionRows()) {
            self.completePendingProjectionRepairBlocking() catch |err| {
                log.err("failed to complete shutdown projection repair: {s}", .{@errorName(err)});
                return;
            };
        }
        const observed_revision = self.storage.currentProjectionObservedRevision();
        var persisted = self.buildPersistedState(self.storage.allocator) catch |err| {
            log.err("failed to snapshot native state: {s}", .{@errorName(err)});
            return;
        };
        var persisted_owned = true;
        defer if (persisted_owned) persisted.deinit();
        self.storage.saveCaptured(persisted.value, observed_revision) catch |err| {
            if (err == error.StoreRevisionConflict) {
                var baseline_copy: ?LoadedPersistedState = null;
                if (self.lifecycle.projection_baseline) |baseline| {
                    baseline_copy = self.clonePersistedState(self.storage.allocator, baseline.value) catch |clone_err| {
                        persisted.deinit();
                        persisted_owned = false;
                        log.err("failed to retain shutdown merge baseline: {s}", .{@errorName(clone_err)});
                        return;
                    };
                }
                if (self.lifecycle.rebase_snapshot) |*old| old.deinit();
                if (self.lifecycle.rebase_baseline) |*old| old.deinit();
                self.lifecycle.rebase_snapshot = persisted;
                persisted_owned = false;
                self.lifecycle.rebase_baseline = baseline_copy;
                // Loop only after a fresh remote projection has been merged
                // into the current frame state; the retry captures that result
                // under its newly observed revision.
                continue;
            }
            log.err("failed to save native state via daemon: {s}", .{@errorName(err)});
            self.storage.markPersistenceUnavailable();
            self.lifecycle.next_flush_attempt_ms = platform_runtime.unixTimestampMs() + FLUSH_RETRY_BACKOFF_MS;
            return;
        };
        persisted.deinit();
        persisted_owned = false;
        self.lifecycle.clearDirty();
        self.lifecycle.next_flush_attempt_ms = 0;
    }
}

/// Pre-turn thread durability: full compatibility snapshot through the daemon (blocking).
/// Indices are unused in Phase 3 — the bridge serializes full app state; Phase 4
/// owns targeted thread/message writes.
pub fn persistThreadBlocking(self: anytype, project_index: usize, thread_index: usize) !void {
    _ = project_index;
    _ = thread_index;
    const now_ms = platform_runtime.unixTimestampMs();
    self.lifecycle.markDirty(now_ms);
    flushDirtyBlocking(self);
    if (self.lifecycle.dirty) return error.StoreMutationFailed;
}

/// Interactive "flush now": schedule off-thread (same as flushIfDirty body).
/// Callers that need ack use flushDirtyBlocking.
pub fn flushDirtyNow(self: anytype) void {
    const now = platform_runtime.unixTimestampMs();
    pollFlushWorker(self);
    if (!self.lifecycle.dirty) return;
    if (self.lifecycle.flush_in_flight) return;
    if (now < self.lifecycle.next_flush_attempt_ms) return;
    scheduleFlushWorker(self, now);
}

test "lifecycle debounce requires both dirty and interaction quiet periods" {
    var state: State = .{};
    state.noteInteraction(100);
    state.markDirty(200);
    try std.testing.expect(!state.shouldFlush(800, 750));
    try std.testing.expect(state.shouldFlush(950, 750));
    state.clearDirty();
    try std.testing.expect(!state.shouldFlush(2000, 750));
}

test "stale flush ack does not clear dirty for later mutations" {
    var state: State = .{};
    state.markDirty(100);
    const scheduled_generation = state.dirty_generation;
    // Mutation lands while the worker is in flight: its ack is stale.
    state.markDirty(200);
    state.clearDirtyForGeneration(scheduled_generation);
    try std.testing.expect(state.dirty);
    // An ack covering the latest generation clears normally.
    state.clearDirtyForGeneration(state.dirty_generation);
    try std.testing.expect(!state.dirty);
}

test "shutdown blocking flush repairs conflict or terminal adoption before saving" {
    const FakeStorage = struct {
        allocator: std.mem.Allocator,
        saves: usize = 0,

        fn currentProjectionObservedRevision(_: *const @This()) u64 {
            return 9;
        }
        fn saveCaptured(self: *@This(), _: db_types.PersistedState, revision: u64) !void {
            try std.testing.expectEqual(@as(u64, 9), revision);
            self.saves += 1;
        }
        fn markPersistenceUnavailable(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: State = .{},
        storage: *FakeStorage,
        unresolved_adoption: bool = true,
        repairs: usize = 0,

        fn hasUnresolvedAdoptionRows(self: *@This()) bool {
            return self.unresolved_adoption;
        }
        fn completePendingProjectionRepairBlocking(self: *@This()) !void {
            self.repairs += 1;
            self.unresolved_adoption = false;
            if (self.lifecycle.rebase_snapshot) |*snapshot| snapshot.deinit();
            self.lifecycle.rebase_snapshot = null;
            if (self.lifecycle.rebase_baseline) |*snapshot| snapshot.deinit();
            self.lifecycle.rebase_baseline = null;
        }
        fn buildPersistedState(_: *@This(), allocator: std.mem.Allocator) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn clonePersistedState(_: *@This(), allocator: std.mem.Allocator, _: db_types.PersistedState) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
    };

    var storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var state: FakeState = .{ .storage = &storage };
    state.lifecycle.dirty = true;
    state.lifecycle.rebase_snapshot = LoadedPersistedState.init(std.testing.allocator);
    state.lifecycle.rebase_baseline = LoadedPersistedState.init(std.testing.allocator);
    flushDirtyBlocking(&state);
    defer state.lifecycle.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.repairs);
    try std.testing.expectEqual(@as(usize, 1), storage.saves);
    try std.testing.expect(!state.lifecycle.dirty);
    try std.testing.expect(!state.unresolved_adoption);
    try std.testing.expect(state.lifecycle.rebase_snapshot == null);
}

test "lifecycle backoff gate skips flush while next_attempt is in the future" {
    var state: State = .{};
    state.markDirty(0);
    state.noteInteraction(0);
    state.next_flush_attempt_ms = 5000;
    try std.testing.expect(state.shouldFlush(1000, 750));
    try std.testing.expect(1000 < state.next_flush_attempt_ms);
}
