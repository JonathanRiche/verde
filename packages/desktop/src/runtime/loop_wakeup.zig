//! Cross-thread wake-up for the SDL event loop.
//!
//! Background threads (provider send workers, stream callbacks) mutate state
//! the render loop displays, but the loop sleeps in SDL_WaitEventTimeout and
//! would otherwise only notice those changes on the next timeout tick. Pushing
//! a registered SDL user event wakes the loop promptly. An atomic sequence and
//! pending flag keep that wake coalesced until the main loop covers it with a
//! frame, so high-rate streams cannot flood the queue or outrun display pacing.

const std = @import("std");
const sdl = @import("zsdl3");

extern fn SDL_RegisterEvents(numevents: c_int) u32;

var wake_event_type: u32 = 0;
var wake_pending: std.atomic.Value(bool) = .init(false);
var wake_sequence: std.atomic.Value(u64) = .init(0);

pub const NotifyResult = enum {
    queued,
    coalesced,
    unavailable,
};

/// Registers the custom SDL event. Call once on the main thread after
/// sdl.init and before any background thread can call notify().
pub fn init() void {
    std.debug.assert(wake_event_type == 0);
    wake_event_type = SDL_RegisterEvents(1);
}

/// Thread-safe. Queues a wake event for the main loop unless one is already
/// pending. No-op (drops the wake) before init(); callers only mutate state
/// the main loop will pick up on its fallback timeout anyway.
pub fn notify() void {
    _ = notifyResult();
}

/// Thread-safe variant that exposes whether an existing wake covered this update.
pub fn notifyResult() NotifyResult {
    if (wake_event_type == 0) return .unavailable;
    _ = wake_sequence.fetchAdd(1, .acq_rel);
    return queueWakeEvent();
}

fn queueWakeEvent() NotifyResult {
    if (wake_pending.swap(true, .acq_rel)) return .coalesced;
    var event: sdl.Event = std.mem.zeroes(sdl.Event);
    event.common.type = @enumFromInt(wake_event_type);
    if (!sdl.pushEvent(&event)) {
        // Queue full or filtered: clear the flag so a later notify retries.
        wake_pending.store(false, .release);
        return .unavailable;
    }
    return .queued;
}

/// Returns whether `event` is the registered wake event without consuming it.
pub fn isWakeEvent(event: *const sdl.Event) bool {
    return wake_event_type != 0 and @intFromEnum(event.type) == wake_event_type;
}

/// Returns the latest update sequence when `event` is our wake event. The
/// coalescing flag stays armed until finish() so updates arriving while the
/// main loop polls and renders cannot flood the SDL queue.
pub fn consume(event: *const sdl.Event) ?u64 {
    if (!isWakeEvent(event)) return null;
    return wake_sequence.load(.acquire);
}

/// Releases a consumed wake after the main loop has covered its state. If an
/// update arrived after consume(), one follow-up event is queued immediately.
pub fn finish(observed_sequence: u64) void {
    wake_pending.store(false, .release);
    if (wake_sequence.load(.acquire) != observed_sequence) _ = queueWakeEvent();
}

test "wake notifications report unavailable and coalesced states without queueing duplicates" {
    const previous_type = wake_event_type;
    const previous_pending = wake_pending.load(.acquire);
    const previous_sequence = wake_sequence.load(.acquire);
    defer {
        wake_event_type = previous_type;
        wake_pending.store(previous_pending, .release);
        wake_sequence.store(previous_sequence, .release);
    }

    wake_event_type = 0;
    wake_pending.store(false, .release);
    wake_sequence.store(0, .release);
    try std.testing.expectEqual(NotifyResult.unavailable, notifyResult());

    wake_event_type = 1;
    wake_pending.store(true, .release);
    try std.testing.expectEqual(NotifyResult.coalesced, notifyResult());
    try std.testing.expect(wake_pending.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), wake_sequence.load(.acquire));
}

test "consumed wake stays coalesced until the covered frame finishes" {
    const previous_type = wake_event_type;
    const previous_pending = wake_pending.load(.acquire);
    const previous_sequence = wake_sequence.load(.acquire);
    defer {
        wake_event_type = previous_type;
        wake_pending.store(previous_pending, .release);
        wake_sequence.store(previous_sequence, .release);
    }

    wake_event_type = 1;
    wake_pending.store(true, .release);
    wake_sequence.store(7, .release);
    var event: sdl.Event = std.mem.zeroes(sdl.Event);
    event.common.type = @enumFromInt(wake_event_type);

    try std.testing.expectEqual(@as(?u64, 7), consume(&event));
    try std.testing.expect(wake_pending.load(.acquire));
    finish(7);
    try std.testing.expect(!wake_pending.load(.acquire));
}
