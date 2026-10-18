//! Main-loop cadence helpers for coalescing work without changing visible timing.

const std = @import("std");

pub const FramePacer = struct {
    last_render_ms: ?i64 = null,
    wake_render_pending: bool = false,

    /// Records that a cross-thread update needs a frame.
    pub fn requestWakeRender(self: *FramePacer) void {
        self.wake_render_pending = true;
    }

    /// Returns whether a pending cross-thread update may render at this display cadence.
    pub fn wakeRenderDue(self: FramePacer, now_ms: i64, interval_ms: i64) bool {
        return self.wake_render_pending and intervalElapsed(self.last_render_ms, now_ms, interval_ms);
    }

    /// Returns whether a continuous animation is due for its next frame.
    pub fn continuousFrameDue(self: FramePacer, now_ms: i64, interval_ms: i64) bool {
        return intervalElapsed(self.last_render_ms, now_ms, interval_ms);
    }

    /// Shortens the next event wait so a coalesced wake update is never delayed past its frame deadline.
    pub fn nextWaitTimeoutMs(self: FramePacer, now_ms: i64, base_timeout_ms: c_int, interval_ms: i64) c_int {
        if (!self.wake_render_pending) return base_timeout_ms;
        const last_render_ms = self.last_render_ms orelse return 0;
        if (now_ms < last_render_ms) return 0;
        const elapsed_ms = now_ms - last_render_ms;
        if (elapsed_ms >= interval_ms) return 0;
        const remaining_ms: c_int = @intCast(interval_ms - elapsed_ms);
        return @min(base_timeout_ms, remaining_ms);
    }

    /// Marks the latest submitted frame as covering all updates observed so far.
    pub fn noteRendered(self: *FramePacer, now_ms: i64) void {
        self.last_render_ms = now_ms;
        self.wake_render_pending = false;
    }

    /// Clears a wake request after the corresponding state was covered by a frame attempt.
    pub fn clearWakeRender(self: *FramePacer) void {
        self.wake_render_pending = false;
    }
};

pub const PresentationDemand = struct {
    pending: bool = false,
    /// The pending frame needs a UI rebuild. False while the only pending
    /// change is new browser texture contents, which can be presented by
    /// replaying the previous frame's batch.
    layout: bool = false,

    /// Records state that has not yet reached a swapchain presentation.
    pub fn request(self: *PresentationDemand) void {
        self.pending = true;
        self.layout = true;
    }

    /// Records new contents of a texture the last laid-out frame already
    /// shows (browser frames). Coalesces with, never downgrades, `request`.
    pub fn requestTextureOnly(self: *PresentationDemand) void {
        self.pending = true;
    }

    /// True when the pending frame may skip the UI rebuild.
    pub fn textureOnly(self: PresentationDemand) bool {
        return self.pending and !self.layout;
    }

    /// Records completion of a render attempt.
    pub fn noteAttempt(self: *PresentationDemand, presented: bool) void {
        if (presented) {
            self.pending = false;
            self.layout = false;
        }
    }

    /// A pending presentation retries without depending on an unrelated SDL wakeup.
    pub fn nextWaitTimeoutMs(self: PresentationDemand, base_timeout_ms: c_int, retry_timeout_ms: c_int) c_int {
        return if (self.pending) @min(base_timeout_ms, retry_timeout_ms) else base_timeout_ms;
    }
};

pub const Cadence = struct {
    last_run_ms: ?i64 = null,

    /// Claims this poll slot when its interval has elapsed.
    pub fn shouldRun(self: *Cadence, now_ms: i64, interval_ms: i64) bool {
        if (!intervalElapsed(self.last_run_ms, now_ms, interval_ms)) return false;
        self.last_run_ms = now_ms;
        return true;
    }
};

fn intervalElapsed(last_ms: ?i64, now_ms: i64, interval_ms: i64) bool {
    const previous_ms = last_ms orelse return true;
    return now_ms < previous_ms or now_ms - previous_ms >= interval_ms;
}

test "rapid switch keeps the final frame scheduled when swapchain acquisition is deferred" {
    var demand: PresentationDemand = .{};

    demand.request(); // Alt+1
    demand.request(); // Alt+2 coalesces before a frame
    demand.request(); // Alt+3 is the final visible target
    demand.noteAttempt(false); // no swapchain texture was acquired

    try std.testing.expect(demand.pending);
    try std.testing.expectEqual(@as(c_int, 16), demand.nextWaitTimeoutMs(1000, 16));

    demand.noteAttempt(true);
    try std.testing.expect(!demand.pending);
}

test "texture-only demand never downgrades a pending layout frame" {
    var demand: PresentationDemand = .{};
    demand.requestTextureOnly();
    try std.testing.expect(demand.textureOnly());
    demand.request();
    demand.requestTextureOnly();
    try std.testing.expect(demand.pending);
    try std.testing.expect(!demand.textureOnly());
    // A deferred attempt keeps the layout requirement.
    demand.noteAttempt(false);
    try std.testing.expect(!demand.textureOnly());
    demand.noteAttempt(true);
    try std.testing.expect(!demand.pending);
    demand.requestTextureOnly();
    try std.testing.expect(demand.textureOnly());
}
