//! Cross-thread wake-up for the SDL event loop.
//!
//! Background threads (provider send workers, stream callbacks) mutate state
//! the render loop displays, but the loop sleeps in SDL_WaitEventTimeout and
//! would otherwise only notice those changes on the next timeout tick (250ms
//! while a send is pending). Pushing a registered SDL user event wakes the
//! loop immediately, so streamed tokens render at arrival rate instead of
//! ~4fps. An atomic flag coalesces bursts: at most one wake event sits in the
//! SDL queue at a time, so high token rates cannot flood the queue.

const std = @import("std");
const sdl = @import("zsdl3");

extern fn SDL_RegisterEvents(numevents: c_int) u32;

var wake_event_type: u32 = 0;
var wake_pending: std.atomic.Value(bool) = .init(false);

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
    if (wake_event_type == 0) return;
    if (wake_pending.swap(true, .acq_rel)) return;
    var event: sdl.Event = std.mem.zeroes(sdl.Event);
    event.common.type = @enumFromInt(wake_event_type);
    if (!sdl.pushEvent(&event)) {
        // Queue full or filtered: clear the flag so a later notify retries.
        wake_pending.store(false, .release);
    }
}

/// Returns true when `event` is our wake event and clears the coalescing
/// flag so the next notify() can queue a fresh wake. Main loop only.
pub fn consume(event: *const sdl.Event) bool {
    if (wake_event_type == 0) return false;
    if (@intFromEnum(event.type) != wake_event_type) return false;
    wake_pending.store(false, .release);
    return true;
}
