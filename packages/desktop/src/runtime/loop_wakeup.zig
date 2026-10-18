//! Cross-thread wake-up for the desktop event loop.
//!
//! Background threads (provider send workers, stream callbacks) mutate state
//! the render loop displays, but the loop sleeps in `App.waitEvent` and would
//! otherwise only notice those changes on the next timeout tick. Posting the
//! loop's wake value through the platform's thread-safe wakeup wakes the loop
//! promptly. An atomic sequence and pending flag keep that wake coalesced until
//! the main loop covers it with a frame, so high-rate streams cannot flood the
//! queue or outrun display pacing.
//!
//! This module stays free of the UI platform so non-GUI roots can import it:
//! the GUI registers the platform's wakeup function with `init`.

const std = @import("std");

/// `Event.user` payload that identifies the loop wake.
pub const wake_value: u64 = 0x7665_7264_6577_616b; // "verdewak"

pub const PostFn = *const fn (ctx: *anyopaque, value: u64) void;

const Poster = struct {
    ctx: *anyopaque,
    post: PostFn,
};

var poster: ?Poster = null;
var wake_pending: std.atomic.Value(bool) = .init(false);
var wake_sequence: std.atomic.Value(u64) = .init(0);
/// Bumped by every wake except `notifyTextureFrameResult`: the main loop
/// compares it across frames to tell "only a browser texture changed" from
/// "state the UI lays out changed".
var layout_sequence: std.atomic.Value(u64) = .init(0);

pub const NotifyResult = enum {
    queued,
    coalesced,
    unavailable,
};

/// Registers the thread-safe poster (the GUI passes `App.wakeup`). Call once
/// on the main thread before any background thread can call notify().
pub fn init(ctx: *anyopaque, post: PostFn) void {
    std.debug.assert(poster == null);
    poster = .{ .ctx = ctx, .post = post };
}

/// Unregisters the poster before the platform app is torn down.
pub fn deinit() void {
    poster = null;
    wake_pending.store(false, .release);
}

/// Thread-safe. Queues a wake event for the main loop unless one is already
/// pending. No-op (drops the wake) before init(); callers only mutate state
/// the main loop will pick up on its fallback timeout anyway.
pub fn notify() void {
    _ = notifyResult();
}

/// Thread-safe variant that exposes whether an existing wake covered this update.
pub fn notifyResult() NotifyResult {
    if (poster == null) return .unavailable;
    _ = layout_sequence.fetchAdd(1, .acq_rel);
    _ = wake_sequence.fetchAdd(1, .acq_rel);
    return queueWakeEvent();
}

/// Thread-safe. Like `notifyResult`, for updates that only replace the pixels
/// of an already laid-out texture (a new browser frame): the wake does not
/// bump `layoutSequence`, so the main loop may present it without rebuilding
/// the UI.
pub fn notifyTextureFrameResult() NotifyResult {
    if (poster == null) return .unavailable;
    _ = wake_sequence.fetchAdd(1, .acq_rel);
    return queueWakeEvent();
}

/// Count of layout-relevant wakes so far (every wake but texture frames).
pub fn layoutSequence() u64 {
    return layout_sequence.load(.acquire);
}

fn queueWakeEvent() NotifyResult {
    const active = poster orelse return .unavailable;
    if (wake_pending.swap(true, .acq_rel)) return .coalesced;
    active.post(active.ctx, wake_value);
    return .queued;
}

/// Returns whether a `.user` payload is the loop wake without consuming it.
pub fn isWakeValue(value: u64) bool {
    return value == wake_value;
}

/// Returns the latest update sequence when `value` is our wake. The
/// coalescing flag stays armed until finish() so updates arriving while the
/// main loop polls and renders cannot flood the event queue.
pub fn consume(value: u64) ?u64 {
    if (!isWakeValue(value)) return null;
    return wake_sequence.load(.acquire);
}

/// Releases a consumed wake after the main loop has covered its state. If an
/// update arrived after consume(), one follow-up wake is queued immediately.
pub fn finish(observed_sequence: u64) void {
    wake_pending.store(false, .release);
    if (wake_sequence.load(.acquire) != observed_sequence) _ = queueWakeEvent();
}

const TestPoster = struct {
    posts: usize = 0,
    last: u64 = 0,

    fn post(ctx: *anyopaque, value: u64) void {
        const self: *TestPoster = @ptrCast(@alignCast(ctx));
        self.posts += 1;
        self.last = value;
    }
};

test "wake notifications report unavailable and coalesced states without queueing duplicates" {
    const previous_poster = poster;
    const previous_pending = wake_pending.load(.acquire);
    const previous_sequence = wake_sequence.load(.acquire);
    defer {
        poster = previous_poster;
        wake_pending.store(previous_pending, .release);
        wake_sequence.store(previous_sequence, .release);
    }

    poster = null;
    wake_pending.store(false, .release);
    wake_sequence.store(0, .release);
    try std.testing.expectEqual(NotifyResult.unavailable, notifyResult());

    var sink: TestPoster = .{};
    poster = .{ .ctx = &sink, .post = TestPoster.post };
    try std.testing.expectEqual(NotifyResult.queued, notifyResult());
    try std.testing.expectEqual(@as(usize, 1), sink.posts);
    try std.testing.expectEqual(wake_value, sink.last);
    try std.testing.expectEqual(NotifyResult.coalesced, notifyResult());
    try std.testing.expectEqual(@as(usize, 1), sink.posts);
    try std.testing.expect(wake_pending.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), wake_sequence.load(.acquire));
}

test "consumed wake stays coalesced until the covered frame finishes" {
    const previous_poster = poster;
    const previous_pending = wake_pending.load(.acquire);
    const previous_sequence = wake_sequence.load(.acquire);
    defer {
        poster = previous_poster;
        wake_pending.store(previous_pending, .release);
        wake_sequence.store(previous_sequence, .release);
    }

    var sink: TestPoster = .{};
    poster = .{ .ctx = &sink, .post = TestPoster.post };
    wake_pending.store(true, .release);
    wake_sequence.store(7, .release);

    try std.testing.expectEqual(@as(?u64, null), consume(1));
    try std.testing.expectEqual(@as(?u64, 7), consume(wake_value));
    try std.testing.expect(wake_pending.load(.acquire));
    finish(7);
    try std.testing.expect(!wake_pending.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), sink.posts);

    wake_pending.store(true, .release);
    _ = wake_sequence.fetchAdd(1, .acq_rel);
    finish(7);
    try std.testing.expectEqual(@as(usize, 1), sink.posts);
}
