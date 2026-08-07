//! Dirty-state debounce and interaction lifecycle tracking.
//!
//! Phase 3: flush completion means daemon acknowledgement of
//! `state.snapshot.replace`, not launch of a detached SQLite save worker.

const std = @import("std");
const platform_runtime = @import("platform_runtime");

const SAVE_DEBOUNCE_MS: i64 = 750;
const log = std.log.scoped(.native_shell);

pub const State = struct {
    dirty: bool = false,
    last_dirty_at_ms: i64 = 0,
    last_interaction_at_ms: i64 = 0,

    pub fn markDirty(self: *State, now_ms: i64) void {
        self.dirty = true;
        self.last_dirty_at_ms = now_ms;
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

pub fn flushIfDirty(self: anytype) void {
    const now = platform_runtime.unixTimestampMs();
    if (!self.lifecycle.shouldFlush(now, SAVE_DEBOUNCE_MS)) return;
    flushDirtyNow(self);
}

pub fn flushDirtyBlocking(self: anytype) void {
    if (!self.lifecycle.dirty) return;
    var persisted = self.buildPersistedState(self.storage.allocator) catch |err| {
        log.err("failed to snapshot native state: {s}", .{@errorName(err)});
        return;
    };
    defer persisted.deinit();
    self.storage.save(persisted.value) catch |err| {
        log.err("failed to save native state via daemon: {s}", .{@errorName(err)});
        // Keep dirty so a later flush can retry; mark the UI read-only path.
        self.storage.markPersistenceUnavailable();
        return;
    };
    self.lifecycle.clearDirty();
}

/// Pre-turn thread durability: full compatibility snapshot through the daemon.
pub fn persistThreadBlocking(self: anytype, project_index: usize, thread_index: usize) !void {
    _ = project_index;
    _ = thread_index;
    var persisted = try self.buildPersistedState(self.storage.allocator);
    defer persisted.deinit();
    try self.storage.save(persisted.value);
    self.lifecycle.clearDirty();
}

/// Flush dirty state and wait for daemon acknowledgement (no detached worker).
pub fn flushDirtyNow(self: anytype) void {
    flushDirtyBlocking(self);
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
