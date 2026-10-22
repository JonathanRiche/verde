//! Audio device seam for Live voice. A backend captures PCM16 mono at
//! `Config.capture_rate` into `Rings.capture` and plays `Rings.playback` at
//! `Config.playback_rate`. It converts rates itself or uses `pcm.Resampler`.
//! Callbacks only touch the lock-free rings. Linux uses PipeWire; macOS and
//! Windows are stubs until their backends land (CoreAudio VoiceProcessingIO /
//! WASAPI with the communications AEC effect).

const std = @import("std");
const builtin = @import("builtin");
const pcm = @import("pcm.zig");

pub const Config = struct {
    capture_rate: u32,
    playback_rate: u32,
    /// Try system echo cancellation (PipeWire module-echo-cancel).
    echo_cancel: bool = true,
};

pub const Rings = struct {
    capture: *pcm.Ring,
    playback: *pcm.Ring,
};

pub const Error = error{ Unsupported, Unavailable, OutOfMemory };

/// The platform backend. Every implementation provides:
/// `start(allocator, Config, Rings) Error!*Device`, `stop(*Device)` (blocks
/// until callbacks have stopped), `echoCancelling(*Device) bool`, and
/// `capturedFrames(*Device) u64` (a liveness counter for the watchdog).
pub const Device = switch (builtin.os.tag) {
    .linux => @import("audio_pipewire.zig").Device,
    else => Unsupported,
};

/// Placeholder backend for platforms without one yet.
pub const Unsupported = struct {
    pub fn start(_: std.mem.Allocator, _: Config, _: Rings) Error!*Unsupported {
        return error.Unsupported;
    }
    pub fn stop(_: *Unsupported) void {}
    pub fn echoCancelling(_: *Unsupported) bool {
        return false;
    }
    pub fn capturedFrames(_: *Unsupported) u64 {
        return 0;
    }
};

test "unsupported backend refuses to start" {
    var capture = try pcm.Ring.init(std.testing.allocator, 16);
    defer capture.deinit(std.testing.allocator);
    var playback = try pcm.Ring.init(std.testing.allocator, 16);
    defer playback.deinit(std.testing.allocator);
    try std.testing.expectError(error.Unsupported, Unsupported.start(std.testing.allocator, .{ .capture_rate = 24_000, .playback_rate = 24_000 }, .{ .capture = &capture, .playback = &playback }));
}
