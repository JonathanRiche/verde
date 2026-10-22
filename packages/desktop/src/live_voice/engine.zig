//! Live voice engine: one network thread per Live session. It mints the
//! provider session through an injected hook (a daemon RPC in the app), owns
//! the audio device and the provider WebSocket, and runs the conversation
//! (reconnecting on drops or `goAway`). The GUI never blocks on it: it reads
//! `status()`, drains `takeNotes`, and posts commands (tool results, injected
//! companion updates, mute, interrupt, stop) that wake the thread through an
//! eventfd.
//!
//! Audio never crosses this file's queues: the device callbacks and this
//! thread share only lock-free `pcm.Ring`s. Tokens, audio, and transcripts are
//! never logged.
//!
//! This file imports nothing from the GUI, so the engine can move into a
//! helper process unchanged.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const pcm = @import("pcm.zig");
const audio = @import("audio.zig");
const websocket = @import("websocket.zig");
const Machine = @import("session.zig");
const sync = @import("sync.zig");

const Self = @This();
const log = std.log.scoped(.live_voice);

/// The run loop needs Linux (eventfd + PipeWire); elsewhere `start` reports
/// the platform as unsupported without compiling it.
pub const supported = builtin.os.tag == .linux;

const CHUNK_MS: u32 = 40;
const CAPTURE_RING_MS: usize = 2_000;
/// Rounded up to a power of two (~87 s at 24 kHz, 4 MB); replies stream faster than real time.
const PLAYBACK_RING_SECONDS: usize = 64;
const POLL_MS: i32 = 20;
const TICK_MS: i64 = 1_000;
const LEVEL_MS: i64 = 80;
/// No captured frames this long after start: echo-cancel nodes never linked.
const CAPTURE_WATCHDOG_MS: i64 = 3_000;

pub const MintResult = union(enum) {
    /// `voice.session.create` result JSON, owned by the engine allocator.
    json: []u8,
    failure: Machine.Failure,
};

pub const Hooks = struct {
    context: ?*anyopaque,
    /// Mints a provider session. Blocking; runs on the engine thread.
    mint: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator) MintResult,
    /// Called after notes or status change (wakes the GUI loop). Thread-safe.
    wake: *const fn () void,
};

/// What the GUI hears from the conversation. Strings are owned by the
/// engine allocator; free with `deinit`.
pub const Note = union(enum) {
    /// A conversation (re)started with this provider.
    connected: struct { provider: []u8, voice: []u8 },
    user_partial: struct { text: []u8, cumulative: bool, item_id: ?[]u8 },
    user_text: struct { text: []u8, item_id: ?[]u8 },
    assistant_text: []u8,
    response_started,
    interrupted,
    turn_done,
    tool_call: struct { call_id: []u8, name: []u8, arguments: []u8 },
    /// Once a second while live (transcript idle closing).
    tick,
    /// The session is over (status says why).
    ended,

    pub fn deinit(self: Note, allocator: std.mem.Allocator) void {
        switch (self) {
            .connected => |v| {
                allocator.free(v.provider);
                allocator.free(v.voice);
            },
            .user_partial => |v| {
                allocator.free(v.text);
                if (v.item_id) |id| allocator.free(id);
            },
            .user_text => |v| {
                allocator.free(v.text);
                if (v.item_id) |id| allocator.free(id);
            },
            .assistant_text => |text| allocator.free(text),
            .tool_call => |v| {
                allocator.free(v.call_id);
                allocator.free(v.name);
                allocator.free(v.arguments);
            },
            .response_started, .interrupted, .turn_done, .tick, .ended => {},
        }
    }
};

pub const Status = struct {
    phase: Machine.Phase = .off,
    activity: Machine.Activity = .listening,
    failure: ?Machine.Failure = null,
    echo_cancel: bool = true,
    muted: bool = false,
    input_level: f32 = 0,
    output_level: f32 = 0,
};

const Command = union(enum) {
    send: []u8,
    stop,
    interrupt,
};

allocator: std.mem.Allocator,
hooks: Hooks,
thread: ?std.Thread = null,
wake_fd: i32 = -1,
mutex: sync.Mutex = .{},
status_value: Status = .{},
notes: std.ArrayList(Note) = .empty,
commands: std.ArrayList(Command) = .empty,
muted: std.atomic.Value(bool) = .init(false),
stop_requested: std.atomic.Value(bool) = .init(false),
finished: std.atomic.Value(bool) = .init(false),
/// Engine-thread state.
machine: Machine = .{},
kind: protocol.Kind = .openai_ga,

/// Spawns the engine thread. On platforms without a backend the session
/// fails at once with `audio_unsupported_platform`.
pub fn start(allocator: std.mem.Allocator, hooks: Hooks, muted: bool) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .hooks = hooks };
    self.muted.store(muted, .release);
    self.status_value.muted = muted;
    if (comptime !supported) {
        self.status_value.phase = .failed;
        self.status_value.failure = .audio_unsupported_platform;
        try self.notes.append(allocator, .ended);
        self.finished.store(true, .release);
        return self;
    }
    const fd = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    if (std.os.linux.errno(fd) != .SUCCESS) return error.SystemResources;
    self.wake_fd = @intCast(fd);
    errdefer _ = std.os.linux.close(self.wake_fd);
    self.status_value.phase = .connecting;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
    return self;
}

/// Joins the thread (call only once `finished()`, or accept the wait) and frees.
pub fn destroy(self: *Self) void {
    self.requestStop();
    if (self.thread) |thread| thread.join();
    if (comptime supported) if (self.wake_fd >= 0) {
        _ = std.os.linux.close(self.wake_fd);
    };
    for (self.notes.items) |pending| pending.deinit(self.allocator);
    self.notes.deinit(self.allocator);
    for (self.commands.items) |command| if (command == .send) self.allocator.free(command.send);
    self.commands.deinit(self.allocator);
    self.allocator.destroy(self);
}

/// Ends the session soon; never blocks.
pub fn requestStop(self: *Self) void {
    self.stop_requested.store(true, .release);
    self.post(.stop);
}

pub fn isFinished(self: *const Self) bool {
    return self.finished.load(.acquire);
}

pub fn status(self: *Self) Status {
    self.mutex.lock();
    defer self.mutex.unlock();
    var value = self.status_value;
    value.muted = self.muted.load(.acquire);
    return value;
}

pub fn setMuted(self: *Self, muted: bool) void {
    self.muted.store(muted, .release);
    self.wakeThread();
}

/// Stops the companion's reply now (half-duplex barge-in by click).
pub fn interrupt(self: *Self) void {
    self.post(.interrupt);
}

/// Answers a tool call; `output` is a JSON object.
pub fn sendToolResult(self: *Self, call_id: []const u8, name: []const u8, output: std.json.Value) void {
    const messages = protocol.toolResultAlloc(self.allocator, self.kindSnapshot(), call_id, name, output) catch return;
    defer self.allocator.free(messages);
    for (messages) |message| self.post(.{ .send = message });
}

/// Injects a user-side text (a companion update) that asks for a spoken answer.
pub fn inject(self: *Self, text: []const u8) void {
    const messages = protocol.injectAlloc(self.allocator, self.kindSnapshot(), text) catch return;
    defer self.allocator.free(messages);
    for (messages) |message| self.post(.{ .send = message });
}

/// Moves pending notes into `out` (caller frees each with `Note.deinit`).
pub fn takeNotes(self: *Self, out: *std.ArrayList(Note), allocator: std.mem.Allocator) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    try out.appendSlice(allocator, self.notes.items);
    self.notes.clearRetainingCapacity();
}

// ---- engine thread -------------------------------------------------------------

fn kindSnapshot(self: *Self) protocol.Kind {
    self.mutex.lock();
    defer self.mutex.unlock();
    return self.kind;
}

fn post(self: *Self, command: Command) void {
    self.mutex.lock();
    self.commands.append(self.allocator, command) catch {
        self.mutex.unlock();
        if (command == .send) self.allocator.free(command.send);
        return;
    };
    self.mutex.unlock();
    self.wakeThread();
}

fn wakeThread(self: *Self) void {
    if (comptime !supported) return;
    if (self.wake_fd < 0) return;
    const one: u64 = 1;
    _ = std.os.linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
}

fn drainWake(self: *Self) void {
    var value: u64 = 0;
    _ = std.os.linux.read(self.wake_fd, std.mem.asBytes(&value), 8);
}

fn note(self: *Self, value: Note) void {
    self.mutex.lock();
    self.notes.append(self.allocator, value) catch {
        self.mutex.unlock();
        value.deinit(self.allocator);
        return;
    };
    self.mutex.unlock();
    self.hooks.wake();
}

fn dupe(self: *Self, text: []const u8) ?[]u8 {
    return self.allocator.dupe(u8, text) catch null;
}

fn publish(self: *Self) void {
    self.mutex.lock();
    self.status_value.phase = self.machine.phase;
    self.status_value.activity = self.machine.activity;
    self.status_value.failure = self.machine.failure;
    self.status_value.echo_cancel = self.machine.echo_cancel;
    self.mutex.unlock();
    self.hooks.wake();
}

fn publishLevels(self: *Self, input: f32, output: f32) void {
    self.mutex.lock();
    self.status_value.input_level = input;
    self.status_value.output_level = output;
    self.mutex.unlock();
    self.hooks.wake();
}

fn nowMs() i64 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

fn run(self: *Self) void {
    defer {
        self.machine.muted = self.muted.load(.acquire);
        if (self.machine.phase != .failed) self.machine.stop();
        self.publishLevels(0, 0);
        self.publish();
        self.note(.ended);
        self.finished.store(true, .release);
        self.hooks.wake();
    }
    self.machine.start(nowMs());
    self.publish();
    while (!self.stop_requested.load(.acquire)) {
        const minted = self.hooks.mint(self.hooks.context, self.allocator);
        const json = switch (minted) {
            .failure => |failure| {
                _ = self.machine.fail(failure);
                return;
            },
            .json => |text| text,
        };
        defer self.allocator.free(json);
        if (self.stop_requested.load(.acquire)) return;
        const ending = self.converse(json);
        switch (ending) {
            .stopped, .failed => return,
            .reconnect => |delay_ms| {
                self.publish();
                if (!self.sleepInterruptible(delay_ms)) return;
            },
        }
    }
}

/// Waits `ms` unless a stop arrives first; false when stopping.
fn sleepInterruptible(self: *Self, ms: i64) bool {
    const deadline = nowMs() + ms;
    while (!self.stop_requested.load(.acquire)) {
        const left = deadline - nowMs();
        if (left <= 0) return true;
        var fds = [_]std.posix.pollfd{.{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&fds, @intCast(@min(left, 1000))) catch {};
        self.drainWake();
    }
    return false;
}

const Ending = union(enum) { stopped, failed, reconnect: i64 };

fn dropped(self: *Self, go_away: bool) Ending {
    return switch (self.machine.dropped(go_away)) {
        .reconnect => |r| .{ .reconnect = r.delay_ms },
        .fail => .failed,
    };
}

fn fail(self: *Self, failure: Machine.Failure) Ending {
    _ = self.machine.fail(failure);
    return .failed;
}

const Conversation = struct {
    engine: *Self,
    kind: protocol.Kind,
    capture: pcm.Ring,
    playback: pcm.Ring,
    device: ?*audio.Device = null,
    socket: ?*websocket.Client = null,
    decoded: std.ArrayList(i16) = .empty,
    output_level: f32 = 0,
    outcome: ?Ending = null,

    /// `websocket.Client.receive` handler: one provider message.
    pub fn onMessage(self: *Conversation, payload: []const u8) !void {
        const engine = self.engine;
        var arena_state = std.heap.ArenaAllocator.init(engine.allocator);
        defer arena_state.deinit();
        const now = nowMs();
        for (try protocol.parse(arena_state.allocator(), self.kind, payload)) |event| switch (event) {
            .ready => {
                engine.machine.ready(now);
                engine.publish();
            },
            .audio => |bytes| {
                try self.decoded.resize(engine.allocator, bytes.len / 2);
                const count = pcm.decodeSamples(bytes, self.decoded.items);
                const written = self.playback.write(self.decoded.items[0..count]);
                if (written < count) log.warn("live playback buffer full; dropped {d} samples", .{count - written});
                self.output_level = @max(self.output_level * 0.8, pcm.level(self.decoded.items[0..count]));
                const was = engine.machine.activity;
                engine.machine.observe(.reply_audio, now);
                if (was != engine.machine.activity) engine.publish();
            },
            .assistant_text => |text| if (engine.dupe(text)) |owned| engine.note(.{ .assistant_text = owned }),
            .user_partial => |partial| {
                engine.machine.observe(.user_speech, now);
                const text = engine.dupe(partial.text) orelse continue;
                const item = if (partial.item_id) |id| engine.dupe(id) else null;
                engine.note(.{ .user_partial = .{ .text = text, .cumulative = partial.cumulative, .item_id = item } });
            },
            .user_text => |final| {
                engine.machine.observe(.user_speech, now);
                const text = engine.dupe(final.text) orelse continue;
                const item = if (final.item_id) |id| engine.dupe(id) else null;
                engine.note(.{ .user_text = .{ .text = text, .item_id = item } });
            },
            .response_started => {
                engine.machine.observe(.response_started, now);
                engine.publish();
                engine.note(.response_started);
            },
            .interrupted => {
                self.playback.requestFlush();
                engine.machine.observe(.interrupted, now);
                engine.publish();
                engine.note(.interrupted);
            },
            .turn_done => {
                engine.machine.observe(.turn_done, now);
                engine.publish();
                engine.note(.turn_done);
            },
            .tool_call => |call| {
                engine.machine.observe(.tool_call, now);
                engine.publish();
                const arguments = std.json.Stringify.valueAlloc(engine.allocator, call.arguments, .{}) catch continue;
                const call_id = engine.dupe(call.call_id) orelse {
                    engine.allocator.free(arguments);
                    continue;
                };
                const name = engine.dupe(call.name) orelse {
                    engine.allocator.free(arguments);
                    engine.allocator.free(call_id);
                    continue;
                };
                engine.note(.{ .tool_call = .{ .call_id = call_id, .name = name, .arguments = arguments } });
            },
            .go_away => {
                self.outcome = engine.dropped(true);
                return error.Ending;
            },
            .failure => {
                // The code may name the cause; it is not user text and is not logged.
                self.outcome = engine.fail(.provider_error);
                return error.Ending;
            },
            .ignored => {},
        };
    }

    fn deinit(self: *Conversation) void {
        const allocator = self.engine.allocator;
        if (self.socket) |socket| {
            socket.close();
            socket.destroy();
        }
        if (self.device) |device| device.stop();
        self.capture.deinit(allocator);
        self.playback.deinit(allocator);
        self.decoded.deinit(allocator);
    }
};

fn converse(self: *Self, json: []const u8) Ending {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return self.fail(.provider_unavailable);
    if (root != .object) return self.fail(.provider_unavailable);
    const fields = root.object;
    const provider = protocol.stringOf(fields.get("provider")) orelse "";
    const kind = protocol.Kind.from(protocol.stringOf(fields.get("protocol")) orelse "", provider) orelse return self.fail(.unsupported_protocol);
    const url = protocol.stringOf(fields.get("websocket_url")) orelse return self.fail(.provider_unavailable);
    const token = protocol.stringOf(fields.get("token")) orelse "";
    const bearer = std.mem.eql(u8, protocol.stringOf(fields.get("auth")) orelse "", "bearer");
    const config: protocol.SessionConfig = .{
        .model = protocol.stringOf(fields.get("model")) orelse "",
        .voice = protocol.stringOf(fields.get("voice")) orelse "",
        .instructions = protocol.stringOf(fields.get("instructions")) orelse "",
        .tools = fields.get("tools") orelse .null,
    };
    {
        self.mutex.lock();
        self.kind = kind;
        self.mutex.unlock();
    }

    var conversation: Conversation = .{
        .engine = self,
        .kind = kind,
        .capture = pcm.Ring.init(self.allocator, kind.inputRate() * CAPTURE_RING_MS / 1000) catch return self.fail(.audio_unavailable),
        .playback = pcm.Ring.init(self.allocator, kind.outputRate() * PLAYBACK_RING_SECONDS) catch return self.fail(.audio_unavailable),
    };
    defer conversation.deinit();
    const device_config: audio.Config = .{ .capture_rate = kind.inputRate(), .playback_rate = kind.outputRate(), .echo_cancel = self.machine.echo_cancel };
    const rings: audio.Rings = .{ .capture = &conversation.capture, .playback = &conversation.playback };
    conversation.device = audio.Device.start(self.allocator, device_config, rings) catch |err| return self.fail(switch (err) {
        error.Unsupported => .audio_unsupported_platform,
        else => .audio_unavailable,
    });
    self.machine.echo_cancel = conversation.device.?.echoCancelling();

    conversation.socket = websocket.Client.connect(self.allocator, url, if (bearer) token else null) catch |err| {
        if (err == error.Unauthorized) return self.fail(.key_rejected);
        if (self.machine.phase == .connecting) return self.fail(.provider_unavailable);
        return self.dropped(false);
    };
    const socket = conversation.socket.?;
    {
        const setup = protocol.setupAlloc(self.allocator, kind, config) catch return self.fail(.provider_unavailable);
        defer self.allocator.free(setup);
        socket.sendText(setup) catch return self.dropped(false);
    }
    if (self.dupe(provider)) |owned_provider| {
        if (self.dupe(config.voice)) |owned_voice| {
            self.note(.{ .connected = .{ .provider = owned_provider, .voice = owned_voice } });
        } else self.allocator.free(owned_provider);
    }
    if (kind.readyOnOpen()) self.machine.ready(nowMs());
    self.publish();

    const chunk_samples: usize = kind.inputRate() / 1000 * CHUNK_MS;
    const chunk = self.allocator.alloc(i16, chunk_samples) catch return self.fail(.audio_unavailable);
    defer self.allocator.free(chunk);
    const started_ms = nowMs();
    var last_tick = started_ms;
    var last_level = started_ms;
    var input_level: f32 = 0;
    var watchdog_armed = self.machine.echo_cancel;
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |command| if (command == .send) self.allocator.free(command.send);
        commands.deinit(self.allocator);
    }

    while (true) {
        if (self.stop_requested.load(.acquire)) return .stopped;

        // Socket first: replies and barge-in matter most.
        var readable = socket.hasBuffered();
        if (!readable) {
            var fds = [_]std.posix.pollfd{
                .{ .fd = socket.fd(), .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, POLL_MS) catch 0;
            if (fds[1].revents != 0) self.drainWake();
            readable = fds[0].revents != 0;
        }
        if (readable) {
            socket.receive(&conversation) catch |err| {
                if (conversation.outcome) |outcome| return outcome;
                if (err == error.OutOfMemory) return self.fail(.provider_unavailable);
                return self.dropped(false);
            };
        }

        // Commands from the GUI.
        {
            self.mutex.lock();
            std.mem.swap(std.ArrayList(Command), &commands, &self.commands);
            self.mutex.unlock();
        }
        for (commands.items) |command| switch (command) {
            .send => |message| {
                defer self.allocator.free(message);
                socket.sendText(message) catch return self.dropped(false);
            },
            .stop => return .stopped,
            .interrupt => {
                conversation.playback.requestFlush();
                self.machine.observe(.interrupted, nowMs());
                self.publish();
                self.note(.interrupted);
            },
        };
        commands.clearRetainingCapacity();

        // Microphone: whole chunks only, gated by mute and half duplex.
        const now = nowMs();
        self.machine.muted = self.muted.load(.acquire);
        while (conversation.capture.available() >= chunk_samples) {
            _ = conversation.capture.read(chunk);
            const level = pcm.level(chunk);
            input_level = @max(input_level * 0.7, level);
            self.machine.heard(level, now);
            if (!self.machine.micOpen(now)) continue;
            const message = protocol.audioAlloc(self.allocator, kind, pcm.bytesOf(chunk)) catch continue;
            defer self.allocator.free(message);
            socket.sendText(message) catch return self.dropped(false);
        }
        if (!self.machine.micOpen(now)) input_level = 0;

        // Playback drained: the companion finished speaking.
        if (self.machine.activity == .speaking and conversation.playback.available() == 0) {
            self.machine.observe(.playback_idle, now);
            self.publish();
        }

        // Echo-cancel nodes that never linked: fall back to plain devices.
        if (watchdog_armed and now - started_ms > CAPTURE_WATCHDOG_MS) {
            watchdog_armed = false;
            if (conversation.device.?.capturedFrames() == 0) {
                log.warn("no audio through PipeWire echo-cancel; retrying without it", .{});
                conversation.device.?.stop();
                conversation.device = null;
                self.machine.echo_cancel = false;
                conversation.device = audio.Device.start(self.allocator, .{
                    .capture_rate = kind.inputRate(),
                    .playback_rate = kind.outputRate(),
                    .echo_cancel = false,
                }, rings) catch return self.fail(.audio_unavailable);
                self.publish();
            }
        }

        if (now - last_level >= LEVEL_MS) {
            last_level = now;
            conversation.output_level *= 0.6;
            if (conversation.playback.available() == 0) conversation.output_level = 0;
            self.publishLevels(input_level, conversation.output_level);
        }
        if (now - last_tick >= TICK_MS) {
            last_tick = now;
            if (self.machine.phase == .live) self.note(.tick);
            if (self.machine.silent(now)) return .stopped;
        }
    }
}

test "notes free their strings" {
    const allocator = std.testing.allocator;
    const value: Note = .{ .tool_call = .{ .call_id = try allocator.dupe(u8, "c"), .name = try allocator.dupe(u8, "n"), .arguments = try allocator.dupe(u8, "{}") } };
    value.deinit(allocator);
    const partial: Note = .{ .user_partial = .{ .text = try allocator.dupe(u8, "hi"), .cumulative = true, .item_id = try allocator.dupe(u8, "i") } };
    partial.deinit(allocator);
}

test "engine compiles" {
    var run_it = false;
    _ = &run_it;
    if (run_it) {
        const engine = try start(std.testing.allocator, undefined, false);
        engine.destroy();
    }
}
