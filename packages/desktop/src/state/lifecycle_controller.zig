//! Dirty-state debounce and interaction lifecycle tracking.

const std = @import("std");

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

test "lifecycle debounce requires both dirty and interaction quiet periods" {
    var state: State = .{};
    state.noteInteraction(100);
    state.markDirty(200);
    try std.testing.expect(!state.shouldFlush(800, 750));
    try std.testing.expect(state.shouldFlush(950, 750));
    state.clearDirty();
    try std.testing.expect(!state.shouldFlush(2000, 750));
}
