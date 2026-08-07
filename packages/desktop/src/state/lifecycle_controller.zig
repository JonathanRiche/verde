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
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const FlushWorkerArgs = struct {
    allocator: std.mem.Allocator,
    storage: *const Storage,
    loaded: LoadedPersistedState,
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
    const storage: *const Storage = self.storage;
    var persisted = self.buildPersistedState(storage.allocator) catch |err| {
        log.err("failed to snapshot native state for async flush: {s}", .{@errorName(err)});
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };

    const result = storage.allocator.create(FlushWorkerResult) catch {
        persisted.deinit();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    result.* = .{};

    const args = storage.allocator.create(FlushWorkerArgs) catch {
        storage.allocator.destroy(result);
        persisted.deinit();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    args.* = .{
        .allocator = storage.allocator,
        .storage = storage,
        .loaded = persisted,
        .result = result,
    };

    const thread = std.Thread.spawn(.{}, flushWorkerMain, .{args}) catch |err| {
        log.err("failed to spawn state flush worker: {s}", .{@errorName(err)});
        // Take loaded back so we can deinit; args holds the moved value.
        var owned = args.loaded;
        owned.deinit();
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
    args.storage.save(args.loaded.value) catch {
        args.result.success = false;
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
    const storage: *const Storage = self.storage;
    if (self.lifecycle.flush_args) |args| {
        args.loaded.deinit();
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
        const storage: *const Storage = self.storage;
        if (self.lifecycle.flush_result) |result| {
            if (result.success)
                self.lifecycle.clearDirtyForGeneration(self.lifecycle.flush_snapshot_generation);
            storage.allocator.destroy(result);
            self.lifecycle.flush_result = null;
        }
        if (self.lifecycle.flush_args) |args| {
            args.loaded.deinit();
            storage.allocator.destroy(args);
            self.lifecycle.flush_args = null;
        }
        self.lifecycle.flush_in_flight = false;
    }
    if (!self.lifecycle.dirty) return;
    var persisted = self.buildPersistedState(self.storage.allocator) catch |err| {
        log.err("failed to snapshot native state: {s}", .{@errorName(err)});
        return;
    };
    defer persisted.deinit();
    self.storage.save(persisted.value) catch |err| {
        log.err("failed to save native state via daemon: {s}", .{@errorName(err)});
        self.storage.markPersistenceUnavailable();
        self.lifecycle.next_flush_attempt_ms = platform_runtime.unixTimestampMs() + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    self.lifecycle.clearDirty();
    self.lifecycle.next_flush_attempt_ms = 0;
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

test "lifecycle backoff gate skips flush while next_attempt is in the future" {
    var state: State = .{};
    state.markDirty(0);
    state.noteInteraction(0);
    state.next_flush_attempt_ms = 5000;
    try std.testing.expect(state.shouldFlush(1000, 750));
    try std.testing.expect(1000 < state.next_flush_attempt_ms);
}
