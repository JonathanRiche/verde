//! Live voice conversation state, independent of audio and network I/O:
//! the phase (off → connecting → live → reconnecting / failed), what the
//! conversation is doing while live (listening, thinking, speaking), the mic
//! gate (mute and the half-duplex echo fallback), reconnect budget, and the
//! silence timeout. The engine thread drives it; it is pure and unit tested.

const std = @import("std");

pub const MAX_RECONNECTS: u8 = 3;
/// No speech either way for this long ends the session.
pub const SILENCE_MS: i64 = 120_000;
/// Without echo cancellation the mic stays closed this long after playback.
pub const HALF_DUPLEX_TAIL_MS: i64 = 350;
/// Mic loudness that counts as the user talking for the silence timeout.
pub const SPEECH_LEVEL: f32 = 0.08;

pub const Phase = enum {
    off,
    connecting,
    live,
    reconnecting,
    failed,

    pub fn active(self: Phase) bool {
        return self == .connecting or self == .live or self == .reconnecting;
    }
};

pub const Activity = enum { listening, thinking, speaking };

/// Why Live stopped or could not start; `message` is the user-facing text.
pub const Failure = enum {
    not_configured,
    key_rejected,
    provider_unavailable,
    daemon_unavailable,
    unsupported_daemon,
    unsupported_protocol,
    audio_unavailable,
    audio_unsupported_platform,
    dropped,
    provider_error,

    pub fn message(self: Failure) []const u8 {
        return switch (self) {
            .not_configured => "Add an xAI, OpenAI or Gemini API key for Live voice (XAI_API_KEY in the daemon's environment, or from the phone app).",
            .key_rejected => "The voice provider rejected the API key.",
            .provider_unavailable => "Couldn't reach the voice provider. Try again.",
            .daemon_unavailable => "Couldn't reach the Verde daemon.",
            .unsupported_daemon => "Live voice needs a newer Verde daemon. Relaunch Verde.",
            .unsupported_protocol => "This voice provider isn't supported yet.",
            .audio_unavailable => "Couldn't open the microphone or speakers (PipeWire).",
            .audio_unsupported_platform => "Live voice isn't available on this platform yet.",
            .dropped => "The live connection dropped.",
            .provider_error => "The voice provider ended the conversation.",
        };
    }

    /// Maps a daemon RPC error code.
    pub fn fromDaemonCode(code: []const u8) Failure {
        if (std.mem.eql(u8, code, "voice_not_configured")) return .not_configured;
        if (std.mem.eql(u8, code, "voice_key_rejected")) return .key_rejected;
        if (std.mem.eql(u8, code, "voice_provider_unavailable")) return .provider_unavailable;
        if (std.mem.eql(u8, code, "unknown_method") or std.mem.eql(u8, code, "method_not_found")) return .unsupported_daemon;
        return .provider_unavailable;
    }
};

/// Conversation signals the machine reacts to (normalized provider events
/// plus local audio facts).
pub const Signal = enum {
    reply_audio,
    reply_text,
    user_speech,
    response_started,
    interrupted,
    turn_done,
    tool_call,
    /// The playback ring ran dry.
    playback_idle,
};

pub const DropDecision = union(enum) {
    reconnect: struct { delay_ms: i64 },
    fail: Failure,
};

phase: Phase = .off,
activity: Activity = .listening,
muted: bool = false,
/// Echo cancellation is active (full duplex). Without it the mic is gated
/// while the companion speaks.
echo_cancel: bool = true,
failure: ?Failure = null,
attempts: u8 = 0,
last_activity_ms: i64 = 0,
mic_closed_until_ms: i64 = 0,
/// The model's turn finished; `playback_idle` returns to listening.
turn_finished: bool = false,

const Self = @This();

pub fn start(self: *Self, now: i64) void {
    const muted = self.muted;
    self.* = .{ .phase = .connecting, .muted = muted, .last_activity_ms = now };
}

/// The socket is open and the session configured.
pub fn ready(self: *Self, now: i64) void {
    if (!self.phase.active()) return;
    self.phase = .live;
    self.activity = .listening;
    self.failure = null;
    self.last_activity_ms = now;
}

pub fn observe(self: *Self, signal: Signal, now: i64) void {
    if (self.phase != .live) return;
    switch (signal) {
        .reply_audio => {
            self.activity = .speaking;
            self.turn_finished = false;
            self.last_activity_ms = now;
        },
        .reply_text => {},
        .user_speech => {
            self.last_activity_ms = now;
            if (self.activity != .speaking) self.activity = .listening;
        },
        .response_started, .tool_call => {
            if (self.activity != .speaking) self.activity = .thinking;
            self.turn_finished = false;
        },
        .interrupted => {
            // Barge-in: playback was flushed; the user has the floor.
            self.activity = .listening;
            self.last_activity_ms = now;
            self.mic_closed_until_ms = 0;
        },
        .turn_done => {
            self.turn_finished = true;
            if (self.activity == .thinking) self.activity = .listening;
        },
        .playback_idle => {
            if (self.activity == .speaking) {
                self.activity = if (self.turn_finished) .listening else .thinking;
                if (!self.echo_cancel) self.mic_closed_until_ms = now + HALF_DUPLEX_TAIL_MS;
            }
        },
    }
}

/// The user's mic level for one chunk (keeps the session from timing out).
pub fn heard(self: *Self, level: f32, now: i64) void {
    if (level > SPEECH_LEVEL and self.micOpen(now)) self.last_activity_ms = now;
}

/// Whether captured audio goes to the provider right now.
pub fn micOpen(self: *const Self, now: i64) bool {
    if (self.phase != .live or self.muted) return false;
    if (self.echo_cancel) return true;
    return self.activity != .speaking and now >= self.mic_closed_until_ms;
}

/// The connection dropped or the server asked us to go away.
pub fn dropped(self: *Self, go_away: bool) DropDecision {
    // Never got live: retrying would fail the same way.
    if (self.phase == .connecting and !go_away) return self.fail(.dropped);
    self.attempts += 1;
    if (self.attempts > MAX_RECONNECTS) return self.fail(.dropped);
    self.phase = .reconnecting;
    return .{ .reconnect = .{ .delay_ms = 500 * @as(i64, self.attempts) } };
}

pub fn fail(self: *Self, failure: Failure) DropDecision {
    self.phase = .failed;
    self.failure = failure;
    self.activity = .listening;
    return .{ .fail = failure };
}

pub fn stop(self: *Self) void {
    const muted = self.muted;
    self.* = .{ .muted = muted };
}

/// True when the conversation has been silent too long and should end.
pub fn silent(self: *const Self, now: i64) bool {
    return self.phase == .live and now - self.last_activity_ms > SILENCE_MS;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "start, ready, and a spoken reply cycle through activities" {
    var machine: Self = .{};
    machine.start(0);
    try testing.expectEqual(Phase.connecting, machine.phase);
    try testing.expect(!machine.micOpen(0));
    machine.ready(10);
    try testing.expectEqual(Phase.live, machine.phase);
    try testing.expect(machine.micOpen(10));
    machine.observe(.user_speech, 20);
    try testing.expectEqual(Activity.listening, machine.activity);
    machine.observe(.response_started, 30);
    try testing.expectEqual(Activity.thinking, machine.activity);
    machine.observe(.reply_audio, 40);
    try testing.expectEqual(Activity.speaking, machine.activity);
    machine.observe(.turn_done, 50);
    try testing.expectEqual(Activity.speaking, machine.activity);
    machine.observe(.playback_idle, 60);
    try testing.expectEqual(Activity.listening, machine.activity);
}

test "barge-in returns the floor to the user" {
    var machine: Self = .{};
    machine.start(0);
    machine.ready(0);
    machine.observe(.reply_audio, 1);
    machine.observe(.interrupted, 2);
    try testing.expectEqual(Activity.listening, machine.activity);
    try testing.expect(machine.micOpen(2));
}

test "half duplex closes the mic while speaking and for a tail" {
    var machine: Self = .{};
    machine.start(0);
    machine.echo_cancel = false;
    machine.ready(0);
    try testing.expect(machine.micOpen(0));
    machine.observe(.reply_audio, 100);
    try testing.expect(!machine.micOpen(100));
    machine.observe(.turn_done, 200);
    machine.observe(.playback_idle, 300);
    try testing.expect(!machine.micOpen(300 + HALF_DUPLEX_TAIL_MS - 1));
    try testing.expect(machine.micOpen(300 + HALF_DUPLEX_TAIL_MS));
}

test "mute keeps the mic closed and survives restarts" {
    var machine: Self = .{};
    machine.muted = true;
    machine.start(0);
    machine.ready(0);
    try testing.expect(!machine.micOpen(0));
    machine.stop();
    try testing.expect(machine.muted);
    try testing.expectEqual(Phase.off, machine.phase);
}

test "drops reconnect up to the budget, then fail; a drop before live fails" {
    var machine: Self = .{};
    machine.start(0);
    try testing.expectEqual(Failure.dropped, machine.dropped(false).fail);
    try testing.expectEqual(Phase.failed, machine.phase);

    machine.start(0);
    machine.ready(0);
    for (1..MAX_RECONNECTS + 1) |attempt| {
        const decision = machine.dropped(false);
        try testing.expectEqual(@as(i64, 500 * @as(i64, @intCast(attempt))), decision.reconnect.delay_ms);
        try testing.expectEqual(Phase.reconnecting, machine.phase);
        machine.ready(0);
    }
    try testing.expect(machine.dropped(true) == .fail);
    try testing.expectEqualStrings(Failure.dropped.message(), machine.failure.?.message());
}

test "silence ends the session; speech and replies keep it alive" {
    var machine: Self = .{};
    machine.start(0);
    machine.ready(0);
    try testing.expect(!machine.silent(SILENCE_MS));
    machine.heard(0.5, 1000);
    try testing.expect(!machine.silent(SILENCE_MS + 1000));
    try testing.expect(machine.silent(SILENCE_MS + 1001));
    machine.heard(0.01, SILENCE_MS + 1001);
    try testing.expect(machine.silent(SILENCE_MS + 1001));
    try testing.expectEqual(Failure.key_rejected, Failure.fromDaemonCode("voice_key_rejected"));
    try testing.expectEqual(Failure.unsupported_daemon, Failure.fromDaemonCode("unknown_method"));
}
