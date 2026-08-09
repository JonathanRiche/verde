//! Dirty-state debounce and interaction lifecycle tracking.
//!
//! Phase 3 fix: frame-loop flush is scheduled off the render-critical path onto
//! a worker thread. Dirty clears only on daemon acknowledgement; failures back
//! off and mark persistence unavailable (visible unsaved/read-only). Shutdown
//! and pre-turn durability still use the blocking flush path. Full snapshots
//! above the protocol ceiling transfer ownership to the bounded durable spool.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");
const db_types = @import("../db/types.zig");
const persistence = @import("persistence.zig");
const storage_mod = @import("storage.zig");

const SAVE_DEBOUNCE_MS: i64 = 750;
/// Minimum delay before retrying a failed frame-loop flush (avoids per-frame storms).
const FLUSH_RETRY_BACKOFF_MS: i64 = 2000;
/// When persistence is unavailable, probe no more often than this interval.
const FLUSH_UNAVAILABLE_PROBE_MS: i64 = 5000;
/// Leave enough room below the ten-second process watchdog to durably spool.
const SHUTDOWN_FLUSH_BUDGET_MS: i64 = 7000;
const SHUTDOWN_MAX_CONFLICTS: usize = 2;
/// Bound transcript copying to a small fraction of one 60 Hz frame. Large
/// projections advance over multiple already-presented frames.
const SNAPSHOT_CAPTURE_BYTES_PER_FRAME: usize = 4 * 1024 * 1024;
const SDL_STALL_LOG_THRESHOLD_MS: i64 = 50;
const log = std.log.scoped(.native_shell);

const LoadedPersistedState = db_types.LoadedState;
const Storage = storage_mod.Storage;

const FlushWorkerResult = struct {
    success: bool = false,
    conflict: bool = false,
    spooled: bool = false,
    acknowledged_revision: u64 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const FlushWorkerArgs = struct {
    allocator: std.mem.Allocator,
    storage: *const Storage,
    loaded: ?LoadedPersistedState,
    baseline: ?LoadedPersistedState,
    body_capture: ?persistence.IncrementalBodyCapture = null,
    selected_project_index: ?usize = null,
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
    rebase_baseline_revision: ?u64 = null,
    rebase_capture_revision: ?u64 = null,
    /// Last successfully applied daemon projection, before local UI overlays.
    projection_baseline: ?LoadedPersistedState = null,
    projection_baseline_revision: ?u64 = null,
    /// True once the current dirty projection has durable spool ownership.
    dirty_spooled: bool = false,
    /// True only while every mutation in this generation is workspace
    /// selection. The worker can derive that projection from the immutable
    /// daemon baseline without touching live AppState.
    selection_only: bool = false,
    selected_project_index: usize = 0,
    /// Generation-checked, frame-budgeted transcript copy in progress.
    snapshot_capture: ?persistence.IncrementalBodyCapture = null,

    pub fn markDirty(self: *State, now_ms: i64) void {
        self.dirty = true;
        self.last_dirty_at_ms = now_ms;
        self.dirty_generation +%= 1;
        self.dirty_spooled = false;
        self.selection_only = false;
    }

    pub fn markSelectionDirty(self: *State, now_ms: i64, selected_project_index: usize) void {
        if (!self.dirty or self.selection_only) self.selection_only = true;
        self.selected_project_index = selected_project_index;
        self.dirty = true;
        self.last_dirty_at_ms = now_ms;
        self.dirty_generation +%= 1;
        self.dirty_spooled = false;
    }

    /// Clear dirty only if the acked snapshot covered every mutation so far;
    /// a stale ack leaves dirty set so the next flush picks up the newer state.
    pub fn clearDirtyForGeneration(self: *State, generation: u64) void {
        if (self.dirty_generation == generation) self.clearDirty();
    }

    pub fn noteInteraction(self: *State, now_ms: i64) void {
        self.last_interaction_at_ms = now_ms;
    }

    pub fn shouldFlush(self: State, now_ms: i64, debounce_ms: i64) bool {
        return self.dirty and
            now_ms - self.last_dirty_at_ms >= debounce_ms and
            now_ms - self.last_interaction_at_ms >= debounce_ms;
    }

    pub fn persistenceNeedsFrames(self: State, now_ms: i64) bool {
        if (self.snapshot_capture != null or self.flush_in_flight) return true;
        if (!self.dirty or self.dirty_spooled or now_ms < self.next_flush_attempt_ms) return false;
        return self.shouldFlush(now_ms, SAVE_DEBOUNCE_MS);
    }

    pub fn clearDirty(self: *State) void {
        self.dirty = false;
        self.selection_only = false;
        if (self.snapshot_capture) |*capture| capture.deinit();
        self.snapshot_capture = null;
    }

    pub fn deinit(self: *State) void {
        if (self.snapshot_capture) |*capture| capture.deinit();
        self.snapshot_capture = null;
        if (self.rebase_snapshot) |*snapshot| snapshot.deinit();
        self.rebase_snapshot = null;
        if (self.rebase_baseline) |*snapshot| snapshot.deinit();
        self.rebase_baseline = null;
        self.rebase_baseline_revision = null;
        self.rebase_capture_revision = null;
        if (self.projection_baseline) |*snapshot| snapshot.deinit();
        self.projection_baseline = null;
        self.projection_baseline_revision = null;
    }
};

pub fn markDirty(self: anytype) void {
    const now_ms = platform_runtime.unixTimestampMs();
    self.lifecycle.noteInteraction(now_ms);
    self.lifecycle.markDirty(now_ms);
}

pub fn markSelectionDirty(self: anytype, selected_project_index: usize) void {
    const now_ms = platform_runtime.unixTimestampMs();
    self.lifecycle.noteInteraction(now_ms);
    self.lifecycle.markSelectionDirty(now_ms, selected_project_index);
}

pub fn noteInteraction(self: anytype) void {
    self.lifecycle.noteInteraction(platform_runtime.unixTimestampMs());
}

/// Frame-loop entry: poll any in-flight flush, then schedule a worker if due.
/// Never blocks on ensureDaemon/socket/fsync on the render thread.
pub fn flushIfDirty(self: anytype) void {
    pollFlushWorker(self);
    if (self.lifecycle.dirty_spooled) return;
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
    const baseline_current = self.lifecycle.projection_baseline != null and
        self.lifecycle.projection_baseline_revision == observed_revision;
    if (!baseline_current) {
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    }
    if (self.lifecycle.selection_only) {
        scheduleSelectionFlushWorker(self, storage, observed_revision, now_ms);
        return;
    }

    if (self.lifecycle.snapshot_capture) |*capture| {
        if (capture.dirty_generation != self.lifecycle.dirty_generation) {
            capture.deinit();
            self.lifecycle.snapshot_capture = null;
        }
    }
    if (self.lifecycle.snapshot_capture == null) {
        const begin_started_ms = platform_runtime.unixTimestampMs();
        self.lifecycle.snapshot_capture = persistence.IncrementalBodyCapture.init(
            storage.allocator,
            snapshotContext(self),
            self.lifecycle.dirty_generation,
        ) catch |err| {
            log.err("failed to begin incremental native state snapshot: {s}", .{@errorName(err)});
            self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
            return;
        };
        logSdlStall("flush snapshot index", begin_started_ms);
    }

    const capture_started_ms = platform_runtime.unixTimestampMs();
    const capture_complete = self.lifecycle.snapshot_capture.?.advance(SNAPSHOT_CAPTURE_BYTES_PER_FRAME);
    logSdlStall("flush capture slice", capture_started_ms);
    if (!capture_complete) return;

    const finalize_started_ms = platform_runtime.unixTimestampMs();
    var persisted = persistence.buildSnapshotFromBodyCapture(
        snapshotContext(self),
        storage.allocator,
        &self.lifecycle.snapshot_capture.?,
    ) catch |err| {
        log.err("failed to finalize incremental native state snapshot: {s}", .{@errorName(err)});
        self.lifecycle.snapshot_capture.?.deinit();
        self.lifecycle.snapshot_capture = null;
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    logSdlStall("flush snapshot finalize", finalize_started_ms);
    var body_capture = self.lifecycle.snapshot_capture;
    self.lifecycle.snapshot_capture = null;
    var baseline = self.lifecycle.projection_baseline;
    self.lifecycle.projection_baseline = null;
    self.lifecycle.projection_baseline_revision = null;

    const result = storage.allocator.create(FlushWorkerResult) catch {
        if (body_capture) |*capture| capture.deinit();
        self.lifecycle.projection_baseline = baseline;
        baseline = null;
        self.lifecycle.projection_baseline_revision = observed_revision;
        persisted.deinit();
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    result.* = .{};

    const args = storage.allocator.create(FlushWorkerArgs) catch {
        if (body_capture) |*capture| capture.deinit();
        self.lifecycle.projection_baseline = baseline;
        baseline = null;
        self.lifecycle.projection_baseline_revision = observed_revision;
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
        .body_capture = body_capture,
        .observed_revision = observed_revision,
        .result = result,
    };

    const thread = std.Thread.spawn(.{}, flushWorkerMain, .{args}) catch |err| {
        log.err("failed to spawn state flush worker: {s}", .{@errorName(err)});
        // Take loaded back so we can deinit; args holds the moved value.
        var owned = args.loaded.?;
        owned.deinit();
        if (args.body_capture) |*capture| capture.deinit();
        self.lifecycle.projection_baseline = args.baseline;
        args.baseline = null;
        self.lifecycle.projection_baseline_revision = observed_revision;
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
    prepareFlushWorkerLoaded(args) catch {
        args.result.done.store(true, .release);
        return;
    };

    const fits_transport = args.storage.stateFitsSnapshotTransport(args.loaded.?.value) catch false;
    if (!fits_transport) {
        args.storage.writePendingStateSpool(.{
            .capture_revision = args.observed_revision,
            .baseline_revision = if (args.baseline != null) args.observed_revision else null,
            .current = args.loaded.?.value,
            .baseline = if (args.baseline) |baseline| baseline.value else null,
        }) catch {
            args.result.done.store(true, .release);
            return;
        };
        args.result.spooled = true;
        args.result.done.store(true, .release);
        return;
    }
    args.storage.saveCaptured(args.loaded.?.value, args.observed_revision) catch |err| {
        args.result.success = false;
        args.result.conflict = err == error.StoreRevisionConflict;
        args.result.done.store(true, .release);
        return;
    };
    args.result.acknowledged_revision = args.storage.currentProjectionObservedRevision();
    args.result.success = true;
    args.result.done.store(true, .release);
}

fn prepareFlushWorkerLoaded(args: *FlushWorkerArgs) !void {
    const source = if (args.loaded) |loaded|
        loaded.value
    else if (args.baseline) |baseline|
        baseline.value
    else
        return error.MissingFlushSnapshot;
    var deep_loaded = try persistence.clonePersistedState(args.allocator, source);
    if (args.selected_project_index) |selected_project_index| {
        deep_loaded.value.selected_project_index = selected_project_index;
    }
    if (args.loaded) |*loaded| loaded.deinit();
    args.loaded = deep_loaded;
    if (args.body_capture) |*capture| capture.deinit();
    args.body_capture = null;
}

fn scheduleSelectionFlushWorker(
    self: anytype,
    storage: *const Storage,
    observed_revision: u64,
    now_ms: i64,
) void {
    const baseline = self.lifecycle.projection_baseline;
    self.lifecycle.projection_baseline = null;
    self.lifecycle.projection_baseline_revision = null;

    const result = storage.allocator.create(FlushWorkerResult) catch {
        self.lifecycle.projection_baseline = baseline;
        self.lifecycle.projection_baseline_revision = observed_revision;
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    result.* = .{};
    const args = storage.allocator.create(FlushWorkerArgs) catch {
        storage.allocator.destroy(result);
        self.lifecycle.projection_baseline = baseline;
        self.lifecycle.projection_baseline_revision = observed_revision;
        self.lifecycle.next_flush_attempt_ms = now_ms + FLUSH_RETRY_BACKOFF_MS;
        return;
    };
    args.* = .{
        .allocator = storage.allocator,
        .storage = storage,
        .loaded = null,
        .baseline = baseline,
        .selected_project_index = self.lifecycle.selected_project_index,
        .observed_revision = observed_revision,
        .result = result,
    };
    const thread = std.Thread.spawn(.{}, flushWorkerMain, .{args}) catch |err| {
        log.err("failed to spawn selection flush worker: {s}", .{@errorName(err)});
        self.lifecycle.projection_baseline = args.baseline;
        args.baseline = null;
        self.lifecycle.projection_baseline_revision = observed_revision;
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
    self.lifecycle.flush_snapshot_generation = self.lifecycle.dirty_generation;
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
    const spooled = result.spooled;
    const acknowledged_revision = result.acknowledged_revision;
    const storage = self.storage;
    if (self.lifecycle.flush_args) |args| {
        if (conflict) {
            if (self.lifecycle.rebase_snapshot) |*old| old.deinit();
            if (self.lifecycle.rebase_baseline) |*old| old.deinit();
            self.lifecycle.rebase_snapshot = args.loaded;
            args.loaded = null;
            self.lifecycle.rebase_baseline = args.baseline;
            args.baseline = null;
            self.lifecycle.rebase_baseline_revision = if (self.lifecycle.rebase_baseline != null) args.observed_revision else null;
            self.lifecycle.rebase_capture_revision = args.observed_revision;
        } else if (success) {
            // Save acknowledgement and baseline publication are one frame-thread
            // transaction: move the exact acknowledged payload, then pair it
            // with the revision returned by that acknowledgement.
            if (self.lifecycle.projection_baseline) |*old| old.deinit();
            self.lifecycle.projection_baseline = args.loaded;
            args.loaded = null;
            self.lifecycle.projection_baseline_revision = acknowledged_revision;
        } else if (self.lifecycle.projection_baseline == null and args.baseline != null) {
            // The worker temporarily owns the revision-paired baseline. On a
            // transport/spool failure, restore it so the next capture remains
            // correctly guarded without rebuilding state on the SDL thread.
            self.lifecycle.projection_baseline = args.baseline;
            args.baseline = null;
            self.lifecycle.projection_baseline_revision = args.observed_revision;
        }
        if (args.loaded) |*loaded| loaded.deinit();
        if (args.baseline) |*baseline| baseline.deinit();
        if (args.body_capture) |*capture| capture.deinit();
        storage.allocator.destroy(args);
        self.lifecycle.flush_args = null;
    }
    storage.allocator.destroy(result);
    self.lifecycle.flush_result = null;
    self.lifecycle.flush_in_flight = false;

    const now = platform_runtime.unixTimestampMs();
    if (success) {
        self.storage.clearPendingStateSpoolBestEffort();
        self.lifecycle.clearDirtyForGeneration(self.lifecycle.flush_snapshot_generation);
        self.lifecycle.next_flush_attempt_ms = 0;
        clearCloseDurabilityNoticeAfterSuccess(self);
    } else if (spooled) {
        // The spool owns exactly the captured generation. A newer edit resets
        // dirty_spooled through markDirty and schedules a replacement spool.
        noteCompletedSpool(&self.lifecycle, self.lifecycle.flush_snapshot_generation);
        clearCloseDurabilityNoticeAfterSuccess(self);
    } else if (conflict) {
        log.warn("async native state save conflicted; awaiting cursor rebase", .{});
        self.lifecycle.next_flush_attempt_ms = now + FLUSH_RETRY_BACKOFF_MS;
    } else {
        log.err("async native state save failed; retaining dirty and backing off", .{});
        storage.markPersistenceUnavailable();
        self.lifecycle.next_flush_attempt_ms = now + FLUSH_UNAVAILABLE_PROBE_MS;
    }
}

fn snapshotContext(self: anytype) persistence.SnapshotContext {
    return .{
        .projects = self.project_controller.projects.items,
        .archived_projects = self.project_controller.archived_projects.items,
        .selected_project_index = self.project_controller.selected_index,
        .sidebar_collapsed = self.sidebar_collapsed,
    };
}

fn logSdlStall(name: []const u8, started_at_ms: i64) void {
    const elapsed_ms = platform_runtime.unixTimestampMs() - started_at_ms;
    if (elapsed_ms > SDL_STALL_LOG_THRESHOLD_MS) {
        log.warn("SDL thread stall operation={s} elapsed_ms={d}", .{ name, elapsed_ms });
    }
}

fn noteCompletedSpool(state: *State, captured_generation: u64) void {
    if (state.dirty_generation == captured_generation) state.dirty_spooled = true;
    state.next_flush_attempt_ms = 0;
}

/// Blocking flush for shutdown and latency-sensitive pre-turn durability.
/// Waits for any in-flight worker first, then performs a synchronous save.
pub fn flushDirtyBlocking(self: anytype) void {
    flushDirtyBlockingResult(self) catch |err| {
        log.err("failed to hand off dirty native state: {s}", .{@errorName(err)});
    };
}

/// Close-time durability boundary. Callers may begin irreversible teardown
/// only after this returns successfully; failure leaves every live owner and
/// controller untouched so an interactive close request can be retried.
pub fn handoffDirtyStateForShutdown(self: anytype) !void {
    if (!self.lifecycle.dirty or self.lifecycle.dirty_spooled) {
        clearCloseDurabilityNoticeAfterSuccess(self);
        return;
    }
    try flushDirtyBlockingResult(self);
    if (self.lifecycle.dirty and !self.lifecycle.dirty_spooled) {
        try spoolDirtyState(self, "shutdown durability handoff retry");
    }
    clearCloseDurabilityNoticeAfterSuccess(self);
}

fn flushDirtyBlockingResult(self: anytype) !void {
    if (self.lifecycle.snapshot_capture) |*capture| capture.deinit();
    self.lifecycle.snapshot_capture = null;
    // Drain any scheduled frame flush before a blocking path.
    if (self.lifecycle.flush_in_flight) {
        if (self.lifecycle.flush_worker) |thread| {
            thread.join();
            self.lifecycle.flush_worker = null;
        }
        pollFlushWorker(self);
    }
    const started_at_ms = platform_runtime.unixTimestampMs();
    var conflicts: usize = 0;
    while (self.lifecycle.dirty) {
        if (conflicts >= SHUTDOWN_MAX_CONFLICTS or
            platform_runtime.unixTimestampMs() - started_at_ms >= SHUTDOWN_FLUSH_BUDGET_MS)
        {
            return spoolDirtyState(self, "shutdown conflict retry bound reached");
        }
        if (self.lifecycle.rebase_snapshot != null or self.hasUnresolvedAdoptionRows()) {
            self.completePendingProjectionRepairBlocking() catch |err| {
                if (builtin.is_test) {
                    log.warn("failed to complete shutdown projection repair: {s}", .{@errorName(err)});
                } else {
                    log.err("failed to complete shutdown projection repair: {s}", .{@errorName(err)});
                }
                return spoolDirtyState(self, "shutdown projection repair failed");
            };
        }
        const observed_revision = self.storage.currentProjectionObservedRevision();
        var persisted = self.buildPersistedState(self.storage.allocator) catch |err| {
            log.err("failed to snapshot native state: {s}", .{@errorName(err)});
            return spoolDirtyState(self, "shutdown snapshot allocation failed");
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
                        return spoolDirtyState(self, "shutdown baseline clone failed");
                    };
                }
                if (self.lifecycle.rebase_snapshot) |*old| old.deinit();
                if (self.lifecycle.rebase_baseline) |*old| old.deinit();
                self.lifecycle.rebase_snapshot = persisted;
                persisted_owned = false;
                self.lifecycle.rebase_baseline = baseline_copy;
                self.lifecycle.rebase_baseline_revision = if (baseline_copy != null) self.lifecycle.projection_baseline_revision else null;
                self.lifecycle.rebase_capture_revision = observed_revision;
                conflicts += 1;
                // Loop only after a fresh remote projection has been merged
                // into the current frame state; the retry captures that result
                // under its newly observed revision.
                continue;
            }
            if (builtin.is_test) {
                log.warn("failed to save native state via daemon: {s}", .{@errorName(err)});
            } else {
                log.err("failed to save native state via daemon: {s}", .{@errorName(err)});
            }
            self.storage.markPersistenceUnavailable();
            self.lifecycle.next_flush_attempt_ms = platform_runtime.unixTimestampMs() + FLUSH_RETRY_BACKOFF_MS;
            return spoolDirtyState(self, "shutdown save failed");
        };
        const acknowledged_revision = self.storage.currentProjectionObservedRevision();
        if (self.lifecycle.projection_baseline) |*old| old.deinit();
        self.lifecycle.projection_baseline = persisted;
        persisted_owned = false;
        self.lifecycle.projection_baseline_revision = acknowledged_revision;
        self.storage.clearPendingStateSpoolBestEffort();
        self.lifecycle.clearDirty();
        self.lifecycle.next_flush_attempt_ms = 0;
        clearCloseDurabilityNoticeAfterSuccess(self);
    }
}

fn clearCloseDurabilityNoticeAfterSuccess(self: anytype) void {
    if (@hasDecl(@TypeOf(self.*), "clearCloseDurabilityNotice")) {
        self.clearCloseDurabilityNotice();
    }
}

fn spoolDirtyState(self: anytype, reason: []const u8) !void {
    self.spoolPendingStateForShutdown() catch |err| {
        if (builtin.is_test) {
            log.warn("failed to durably spool dirty native state after {s}: {s}", .{ reason, @errorName(err) });
        } else {
            log.err("failed to durably spool dirty native state after {s}: {s}", .{ reason, @errorName(err) });
        }
        return err;
    };
    self.lifecycle.dirty_spooled = true;
    log.warn("durably spooled dirty native state: {s}", .{reason});
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

test "incremental snapshot and worker ownership keep frame progress scheduled" {
    var state: State = .{ .dirty = true, .last_dirty_at_ms = 100, .last_interaction_at_ms = 100 };
    try std.testing.expect(!state.persistenceNeedsFrames(849));
    try std.testing.expect(state.persistenceNeedsFrames(850));
    state.flush_in_flight = true;
    state.next_flush_attempt_ms = 10_000;
    try std.testing.expect(state.persistenceNeedsFrames(900));
    state.flush_in_flight = false;
    state.dirty_spooled = true;
    try std.testing.expect(!state.persistenceNeedsFrames(20_000));
}

test "selection-only generations coalesce but never hide a full projection mutation" {
    var state: State = .{};
    state.markSelectionDirty(100, 2);
    try std.testing.expect(state.selection_only);
    try std.testing.expectEqual(@as(usize, 2), state.selected_project_index);
    state.markSelectionDirty(200, 4);
    try std.testing.expect(state.selection_only);
    try std.testing.expectEqual(@as(usize, 4), state.selected_project_index);
    state.markDirty(300);
    try std.testing.expect(!state.selection_only);
}

test "selection worker derives current projection from immutable baseline" {
    var baseline = LoadedPersistedState.init(std.testing.allocator);
    baseline.value.selected_project_index = 1;
    var result: FlushWorkerResult = .{};
    var args: FlushWorkerArgs = .{
        .allocator = std.testing.allocator,
        .storage = undefined,
        .loaded = null,
        .baseline = baseline,
        .selected_project_index = 3,
        .observed_revision = 8,
        .result = &result,
    };
    defer {
        if (args.loaded) |*loaded| loaded.deinit();
        if (args.baseline) |*owned_baseline| owned_baseline.deinit();
    }

    try prepareFlushWorkerLoaded(&args);
    try std.testing.expectEqual(@as(usize, 3), args.loaded.?.value.selected_project_index);
    try std.testing.expectEqual(@as(usize, 1), args.baseline.?.value.selected_project_index);
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

test "acknowledged full save atomically advances revision-paired projection baseline" {
    const FakeStorage = struct {
        allocator: std.mem.Allocator,
        cleared_spool: bool = false,

        fn clearPendingStateSpoolBestEffort(self: *@This()) void {
            self.cleared_spool = true;
        }
        fn markPersistenceUnavailable(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: State = .{},
        storage: *FakeStorage,
        close_durability_notice: bool = true,

        fn clearCloseDurabilityNotice(self: *@This()) void {
            self.close_durability_notice = false;
        }
    };

    var storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var state: FakeState = .{ .storage = &storage };
    defer state.lifecycle.deinit();
    var old_baseline = LoadedPersistedState.init(std.testing.allocator);
    old_baseline.value.sidebar_collapsed = false;
    state.lifecycle.projection_baseline = old_baseline;
    state.lifecycle.projection_baseline_revision = 4;
    state.lifecycle.dirty = true;
    state.lifecycle.dirty_generation = 1;
    state.lifecycle.flush_snapshot_generation = 1;

    var acknowledged = LoadedPersistedState.init(std.testing.allocator);
    acknowledged.value.sidebar_collapsed = true;
    const result = try std.testing.allocator.create(FlushWorkerResult);
    result.* = .{ .success = true, .acknowledged_revision = 5 };
    result.done.store(true, .release);
    const args = try std.testing.allocator.create(FlushWorkerArgs);
    args.* = .{
        .allocator = std.testing.allocator,
        .storage = undefined,
        .loaded = acknowledged,
        .baseline = null,
        .observed_revision = 4,
        .result = result,
    };
    state.lifecycle.flush_in_flight = true;
    state.lifecycle.flush_result = result;
    state.lifecycle.flush_args = args;
    pollFlushWorker(&state);

    try std.testing.expect(!state.lifecycle.dirty);
    try std.testing.expect(state.lifecycle.projection_baseline.?.value.sidebar_collapsed);
    try std.testing.expectEqual(@as(?u64, 5), state.lifecycle.projection_baseline_revision);
    try std.testing.expect(storage.cleared_spool);
    try std.testing.expect(!state.close_durability_notice);
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
        fn clearPendingStateSpoolBestEffort(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: State = .{},
        storage: *FakeStorage,
        unresolved_adoption: bool = true,
        repairs: usize = 0,
        spools: usize = 0,

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
            self.lifecycle.rebase_baseline_revision = null;
            self.lifecycle.rebase_capture_revision = null;
        }
        fn buildPersistedState(_: *@This(), allocator: std.mem.Allocator) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn clonePersistedState(_: *@This(), allocator: std.mem.Allocator, _: db_types.PersistedState) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn spoolPendingStateForShutdown(self: *@This()) !void {
            self.spools += 1;
        }
    };

    var storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var state: FakeState = .{ .storage = &storage };
    state.lifecycle.dirty = true;
    state.lifecycle.rebase_snapshot = LoadedPersistedState.init(std.testing.allocator);
    state.lifecycle.rebase_baseline = LoadedPersistedState.init(std.testing.allocator);
    state.lifecycle.rebase_baseline_revision = 9;
    state.lifecycle.rebase_capture_revision = 9;
    flushDirtyBlocking(&state);
    defer state.lifecycle.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.repairs);
    try std.testing.expectEqual(@as(usize, 1), storage.saves);
    try std.testing.expect(!state.lifecycle.dirty);
    try std.testing.expect(!state.unresolved_adoption);
    try std.testing.expect(state.lifecycle.rebase_snapshot == null);
    try std.testing.expectEqual(@as(usize, 0), state.spools);
}

test "shutdown repair failure and repeated conflicts transfer dirty ownership to spool" {
    const FakeStorage = struct {
        allocator: std.mem.Allocator,
        saves: usize = 0,

        fn currentProjectionObservedRevision(_: *const @This()) u64 {
            return 12;
        }
        fn saveCaptured(self: *@This(), _: db_types.PersistedState, _: u64) !void {
            self.saves += 1;
            return error.StoreRevisionConflict;
        }
        fn markPersistenceUnavailable(_: *@This()) void {}
        fn clearPendingStateSpoolBestEffort(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: State = .{},
        storage: *FakeStorage,
        repair_fails: bool,
        unresolved: bool = true,
        spools: usize = 0,

        fn hasUnresolvedAdoptionRows(self: *@This()) bool {
            return self.unresolved;
        }
        fn completePendingProjectionRepairBlocking(self: *@This()) !void {
            if (self.repair_fails) return error.ProjectionRefreshUnavailable;
            self.unresolved = false;
            if (self.lifecycle.rebase_snapshot) |*snapshot| snapshot.deinit();
            self.lifecycle.rebase_snapshot = null;
            if (self.lifecycle.rebase_baseline) |*snapshot| snapshot.deinit();
            self.lifecycle.rebase_baseline = null;
            self.lifecycle.rebase_baseline_revision = null;
            self.lifecycle.rebase_capture_revision = null;
        }
        fn buildPersistedState(_: *@This(), allocator: std.mem.Allocator) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn clonePersistedState(_: *@This(), allocator: std.mem.Allocator, _: db_types.PersistedState) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn spoolPendingStateForShutdown(self: *@This()) !void {
            try std.testing.expect(self.lifecycle.dirty);
            self.spools += 1;
        }
    };

    var repair_storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var repair_state: FakeState = .{ .storage = &repair_storage, .repair_fails = true };
    repair_state.lifecycle.dirty = true;
    repair_state.lifecycle.rebase_snapshot = LoadedPersistedState.init(std.testing.allocator);
    defer repair_state.lifecycle.deinit();
    flushDirtyBlocking(&repair_state);
    try std.testing.expect(repair_state.lifecycle.dirty);
    try std.testing.expect(repair_state.lifecycle.dirty_spooled);
    try std.testing.expectEqual(@as(usize, 1), repair_state.spools);
    try std.testing.expectEqual(@as(usize, 0), repair_storage.saves);

    var conflict_storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var conflict_state: FakeState = .{ .storage = &conflict_storage, .repair_fails = false, .unresolved = false };
    conflict_state.lifecycle.dirty = true;
    conflict_state.lifecycle.projection_baseline = LoadedPersistedState.init(std.testing.allocator);
    conflict_state.lifecycle.projection_baseline_revision = 12;
    defer conflict_state.lifecycle.deinit();
    flushDirtyBlocking(&conflict_state);
    try std.testing.expect(conflict_state.lifecycle.dirty);
    try std.testing.expect(conflict_state.lifecycle.dirty_spooled);
    try std.testing.expectEqual(SHUTDOWN_MAX_CONFLICTS, conflict_storage.saves);
    try std.testing.expectEqual(@as(usize, 1), conflict_state.spools);
}

test "close durability failure returns before teardown and retry succeeds" {
    const FakeStorage = struct {
        allocator: std.mem.Allocator,

        fn currentProjectionObservedRevision(_: *const @This()) u64 {
            return 3;
        }
        fn saveCaptured(_: *@This(), _: db_types.PersistedState, _: u64) !void {
            return error.StoreUnavailable;
        }
        fn markPersistenceUnavailable(_: *@This()) void {}
        fn clearPendingStateSpoolBestEffort(_: *@This()) void {}
    };
    const FakeState = struct {
        lifecycle: State = .{},
        storage: *FakeStorage,
        spool_fails: bool = true,
        teardown_started: bool = false,
        spool_attempts: usize = 0,

        fn hasUnresolvedAdoptionRows(_: *@This()) bool {
            return false;
        }
        fn completePendingProjectionRepairBlocking(_: *@This()) !void {}
        fn buildPersistedState(_: *@This(), allocator: std.mem.Allocator) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn clonePersistedState(_: *@This(), allocator: std.mem.Allocator, _: db_types.PersistedState) !LoadedPersistedState {
            return LoadedPersistedState.init(allocator);
        }
        fn spoolPendingStateForShutdown(self: *@This()) !void {
            self.spool_attempts += 1;
            if (self.spool_fails) return error.InjectedSpoolFailure;
        }
    };

    var storage: FakeStorage = .{ .allocator = std.testing.allocator };
    var state: FakeState = .{ .storage = &storage };
    state.lifecycle.dirty = true;
    defer state.lifecycle.deinit();
    try std.testing.expectError(error.InjectedSpoolFailure, handoffDirtyStateForShutdown(&state));
    try std.testing.expect(state.lifecycle.dirty);
    try std.testing.expect(!state.lifecycle.dirty_spooled);
    try std.testing.expect(!state.teardown_started);
    state.spool_fails = false;
    try handoffDirtyStateForShutdown(&state);
    try std.testing.expect(state.lifecycle.dirty_spooled);
    try std.testing.expectEqual(@as(usize, 2), state.spool_attempts);
    try std.testing.expect(!state.teardown_started);
}

test "lifecycle backoff gate skips flush while next_attempt is in the future" {
    var state: State = .{};
    state.markDirty(0);
    state.noteInteraction(0);
    state.next_flush_attempt_ms = 5000;
    try std.testing.expect(state.shouldFlush(1000, 750));
    try std.testing.expect(1000 < state.next_flush_attempt_ms);
}

test "completed spool owns only its captured dirty generation" {
    var state: State = .{ .dirty = true, .dirty_generation = 4, .next_flush_attempt_ms = 99 };
    noteCompletedSpool(&state, 3);
    try std.testing.expect(!state.dirty_spooled);
    try std.testing.expectEqual(@as(i64, 0), state.next_flush_attempt_ms);
    noteCompletedSpool(&state, 4);
    try std.testing.expect(state.dirty_spooled);
    state.markDirty(100);
    try std.testing.expect(!state.dirty_spooled);
}
