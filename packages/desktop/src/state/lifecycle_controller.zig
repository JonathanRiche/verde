//! Dirty-state debounce and interaction lifecycle tracking.

const std = @import("std");
const platform_runtime = @import("platform_runtime");
const persistence = @import("persistence.zig");

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
        log.err("failed to save native state: {s}", .{@errorName(err)});
        return;
    };
    self.lifecycle.clearDirty();
}

pub fn persistThreadBlocking(self: anytype, project_index: usize, thread_index: usize) !void {
    const project = &self.project_controller.projects.items[project_index];
    var arena = std.heap.ArenaAllocator.init(self.storage.allocator);
    defer arena.deinit();
    const snapshot = try persistence.threadSnapshot(arena.allocator(), &project.threads.items[thread_index]);
    try self.storage.saveThread(project.id, thread_index, snapshot);
}

pub fn flushDirtyNow(self: anytype) void {
    if (!self.lifecycle.dirty) return;

    var persisted = self.buildPersistedState(std.heap.page_allocator) catch |err| {
        log.err("failed to snapshot native state: {s}", .{@errorName(err)});
        return;
    };
    errdefer persisted.deinit();

    const pref_path = std.heap.page_allocator.dupe(u8, self.storage.pref_path) catch |err| {
        log.err("failed to prepare async native state save: {s}", .{@errorName(err)});
        return;
    };
    errdefer std.heap.page_allocator.free(pref_path);

    const worker = std.Thread.spawn(.{}, persistence.saveWorker, .{ pref_path, persisted }) catch |err| {
        log.err("failed to start async native state save: {s}", .{@errorName(err)});
        return;
    };
    worker.detach();
    self.lifecycle.clearDirty();
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
