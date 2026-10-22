//! PipeWire backend for Live voice. `libpipewire-0.3.so.0` is opened with
//! `dlopen` the first time Live starts, so Verde starts (and reports Live as
//! unavailable) on machines without PipeWire, and the build needs no
//! PipeWire headers. The few C ABI structs we touch are declared here, and
//! the one SPA pod we send (an audio/raw `EnumFormat`) is assembled as bytes;
//! both are stable PipeWire ABI.
//!
//! Each Live conversation gets its own `pw_context` on a `pw_thread_loop`.
//! With echo cancellation, `libpipewire-module-echo-cancel` (WebRTC AEC) is
//! loaded into that context: its nodes belong to this client and vanish when
//! the conversation ends or the process dies. The capture stream reads the
//! module's cleaned source, and the playback stream feeds its sink, which is
//! the AEC's reference signal. PipeWire's stream adapter converts to S16 mono
//! at the provider rates, so no resampling happens here.
//!
//! The RT `process` callbacks only copy samples into or out of `pcm.Ring`s.

const std = @import("std");
const pcm = @import("pcm.zig");
const audio = @import("audio.zig");
const sync = @import("sync.zig");

const log = std.log.scoped(.live_audio);

const LIBRARY = "libpipewire-0.3.so.0";
const ECHO_CANCEL_MODULE = "libpipewire-module-echo-cancel";

// ---- C ABI ---------------------------------------------------------------------

const Opaque = anyopaque;

/// `struct spa_hook`: list link, callbacks, removed, priv.
const Hook = extern struct { words: [6]usize = @splat(0) };

const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const anyopaque = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

const SpaChunk = extern struct { offset: u32, size: u32, stride: i32, flags: i32 };
const SpaData = extern struct { type: u32, flags: u32, fd: i64, mapoffset: u32, maxsize: u32, data: ?*anyopaque, chunk: *SpaChunk };
const SpaBuffer = extern struct { n_metas: u32, n_datas: u32, metas: ?*anyopaque, datas: [*]SpaData };
const PwBuffer = extern struct { buffer: *SpaBuffer, user_data: ?*anyopaque, size: u64, requested: u64, time: u64 };

const DIRECTION_INPUT: u32 = 0;
const DIRECTION_OUTPUT: u32 = 1;
const ID_ANY: u32 = 0xffff_ffff;
const FLAG_AUTOCONNECT: u32 = 1 << 0;
const FLAG_MAP_BUFFERS: u32 = 1 << 2;
const FLAG_RT_PROCESS: u32 = 1 << 4;
const STATE_ERROR: c_int = -1;

const Api = struct {
    lib: std.DynLib,
    init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    thread_loop_new: *const fn ([*:0]const u8, ?*const anyopaque) callconv(.c) ?*Opaque,
    thread_loop_get_loop: *const fn (*Opaque) callconv(.c) ?*Opaque,
    thread_loop_start: *const fn (*Opaque) callconv(.c) c_int,
    thread_loop_stop: *const fn (*Opaque) callconv(.c) void,
    thread_loop_destroy: *const fn (*Opaque) callconv(.c) void,
    thread_loop_lock: *const fn (*Opaque) callconv(.c) void,
    thread_loop_unlock: *const fn (*Opaque) callconv(.c) void,
    context_new: *const fn (*Opaque, ?*Opaque, usize) callconv(.c) ?*Opaque,
    context_destroy: *const fn (*Opaque) callconv(.c) void,
    context_connect: *const fn (*Opaque, ?*Opaque, usize) callconv(.c) ?*Opaque,
    context_load_module: *const fn (*Opaque, [*:0]const u8, ?[*:0]const u8, ?*Opaque) callconv(.c) ?*Opaque,
    core_disconnect: *const fn (*Opaque) callconv(.c) c_int,
    impl_module_destroy: *const fn (*Opaque) callconv(.c) void,
    properties_new_string: *const fn ([*:0]const u8) callconv(.c) ?*Opaque,
    stream_new: *const fn (*Opaque, [*:0]const u8, ?*Opaque) callconv(.c) ?*Opaque,
    stream_add_listener: *const fn (*Opaque, *Hook, *const StreamEvents, ?*anyopaque) callconv(.c) void,
    stream_connect: *const fn (*Opaque, u32, u32, u32, [*]const *const anyopaque, u32) callconv(.c) c_int,
    stream_destroy: *const fn (*Opaque) callconv(.c) void,
    stream_dequeue_buffer: *const fn (*Opaque) callconv(.c) ?*PwBuffer,
    stream_queue_buffer: *const fn (*Opaque, *PwBuffer) callconv(.c) c_int,

    fn load() ?Api {
        var lib = std.DynLib.open(LIBRARY) catch return null;
        var api: Api = undefined;
        api.lib = lib;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "lib")) continue;
            const symbol = "pw_" ++ field.name;
            @field(api, field.name) = lib.lookup(field.type, symbol) orelse {
                log.warn("PipeWire is missing {s}", .{symbol});
                lib.close();
                return null;
            };
        }
        return api;
    }
};

var api_mutex: sync.Mutex = .{};
var api_state: enum { unloaded, loaded, missing } = .unloaded;
var api_value: Api = undefined;

/// Opens libpipewire once per process; it stays loaded (unloading it under
/// live threads is unsafe).
fn sharedApi() ?*const Api {
    api_mutex.lock();
    defer api_mutex.unlock();
    switch (api_state) {
        .loaded => return &api_value,
        .missing => return null,
        .unloaded => {
            if (Api.load()) |api| {
                api_value = api;
                api_state = .loaded;
                api_value.init(null, null);
                return &api_value;
            }
            log.info("PipeWire not available; Live voice is off", .{});
            api_state = .missing;
            return null;
        },
    }
}

// ---- SPA format pod --------------------------------------------------------------

const SPA_TYPE_ID: u32 = 3;
const SPA_TYPE_INT: u32 = 4;
const SPA_TYPE_OBJECT: u32 = 15;
const SPA_TYPE_OBJECT_FORMAT: u32 = 0x40003;
const SPA_PARAM_ENUM_FORMAT: u32 = 3;
const SPA_FORMAT_MEDIA_TYPE: u32 = 1;
const SPA_FORMAT_MEDIA_SUBTYPE: u32 = 2;
const SPA_FORMAT_AUDIO_FORMAT: u32 = 0x10001;
const SPA_FORMAT_AUDIO_RATE: u32 = 0x10003;
const SPA_FORMAT_AUDIO_CHANNELS: u32 = 0x10004;
const SPA_MEDIA_TYPE_AUDIO: u32 = 1;
const SPA_MEDIA_SUBTYPE_RAW: u32 = 1;
const SPA_AUDIO_FORMAT_S16_LE: u32 = 0x103;

pub const FORMAT_POD_BYTES = 8 + 8 + 5 * 24;

/// `SPA_PARAM_EnumFormat` for S16LE mono at `rate`: an object pod whose five
/// properties are each `{key, flags, {size=4, type}, value, pad}`.
pub fn formatPod(out: *align(8) [FORMAT_POD_BYTES]u8, rate: u32) void {
    var words: [FORMAT_POD_BYTES / 4]u32 = undefined;
    words[0] = FORMAT_POD_BYTES - 8; // body size
    words[1] = SPA_TYPE_OBJECT;
    words[2] = SPA_TYPE_OBJECT_FORMAT;
    words[3] = SPA_PARAM_ENUM_FORMAT;
    const props = [_][3]u32{
        .{ SPA_FORMAT_MEDIA_TYPE, SPA_TYPE_ID, SPA_MEDIA_TYPE_AUDIO },
        .{ SPA_FORMAT_MEDIA_SUBTYPE, SPA_TYPE_ID, SPA_MEDIA_SUBTYPE_RAW },
        .{ SPA_FORMAT_AUDIO_FORMAT, SPA_TYPE_ID, SPA_AUDIO_FORMAT_S16_LE },
        .{ SPA_FORMAT_AUDIO_RATE, SPA_TYPE_INT, rate },
        .{ SPA_FORMAT_AUDIO_CHANNELS, SPA_TYPE_INT, 1 },
    };
    for (props, 0..) |prop, index| {
        const base = 4 + index * 6;
        words[base + 0] = prop[0]; // key
        words[base + 1] = 0; // flags
        words[base + 2] = 4; // value size
        words[base + 3] = prop[1]; // value type
        words[base + 4] = prop[2]; // value
        words[base + 5] = 0; // pad to 8
    }
    @memcpy(out, std.mem.sliceAsBytes(&words));
}

// ---- device ----------------------------------------------------------------------

pub const Device = struct {
    allocator: std.mem.Allocator,
    api: *const Api,
    rings: audio.Rings,
    loop: *Opaque,
    context: ?*Opaque = null,
    core: ?*Opaque = null,
    module: ?*Opaque = null,
    capture: ?*Opaque = null,
    playback: ?*Opaque = null,
    capture_hook: Hook = .{},
    playback_hook: Hook = .{},
    capture_events: StreamEvents = .{ .process = captureProcess, .state_changed = stateChanged },
    playback_events: StreamEvents = .{ .process = playbackProcess, .state_changed = stateChanged },
    capture_pod: [FORMAT_POD_BYTES]u8 align(8) = undefined,
    playback_pod: [FORMAT_POD_BYTES]u8 align(8) = undefined,
    captured: std.atomic.Value(u64) = .init(0),
    echo_cancel: bool = false,

    pub fn start(allocator: std.mem.Allocator, config: audio.Config, rings: audio.Rings) audio.Error!*Device {
        const api = sharedApi() orelse return error.Unavailable;
        const loop = api.thread_loop_new("verde-live-audio", null) orelse return error.Unavailable;
        const self = allocator.create(Device) catch {
            api.thread_loop_destroy(loop);
            return error.OutOfMemory;
        };
        self.* = .{ .allocator = allocator, .api = api, .rings = rings, .loop = loop };
        if (api.thread_loop_start(loop) < 0) {
            api.thread_loop_destroy(loop);
            allocator.destroy(self);
            return error.Unavailable;
        }
        api.thread_loop_lock(loop);
        const ok = self.open(config);
        api.thread_loop_unlock(loop);
        if (!ok) {
            self.stop();
            return error.Unavailable;
        }
        return self;
    }

    /// Stops callbacks and releases every PipeWire object. Blocking.
    pub fn stop(self: *Device) void {
        const api = self.api;
        api.thread_loop_lock(self.loop);
        if (self.capture) |stream| api.stream_destroy(stream);
        if (self.playback) |stream| api.stream_destroy(stream);
        self.capture = null;
        self.playback = null;
        if (self.module) |module| api.impl_module_destroy(module);
        self.module = null;
        if (self.core) |core| _ = api.core_disconnect(core);
        self.core = null;
        api.thread_loop_unlock(self.loop);
        api.thread_loop_stop(self.loop);
        if (self.context) |context| api.context_destroy(context);
        api.thread_loop_destroy(self.loop);
        self.allocator.destroy(self);
    }

    pub fn echoCancelling(self: *Device) bool {
        return self.echo_cancel;
    }

    pub fn capturedFrames(self: *Device) u64 {
        return self.captured.load(.monotonic);
    }

    /// Runs with the thread loop locked.
    fn open(self: *Device, config: audio.Config) bool {
        const api = self.api;
        const pw_loop = api.thread_loop_get_loop(self.loop) orelse return false;
        self.context = api.context_new(pw_loop, null, 0) orelse return false;
        self.core = api.context_connect(self.context.?, null, 0) orelse {
            log.warn("could not connect to the PipeWire daemon", .{});
            return false;
        };

        var names: NodeNames = .init();
        if (config.echo_cancel and echoCancelAllowed()) {
            var args_buffer: [1024]u8 = undefined;
            const args = names.moduleArgs(&args_buffer) orelse return false;
            self.module = api.context_load_module(self.context.?, ECHO_CANCEL_MODULE, args, null);
            self.echo_cancel = self.module != null;
            if (!self.echo_cancel) log.info("PipeWire echo-cancel unavailable; Live voice runs half-duplex", .{});
        }

        var props_buffer: [512]u8 = undefined;
        const capture_props = names.streamProps(&props_buffer, .capture, self.echo_cancel) orelse return false;
        self.capture = api.stream_new(self.core.?, "Verde Live microphone", api.properties_new_string(capture_props)) orelse return false;
        const playback_props = names.streamProps(&props_buffer, .playback, self.echo_cancel) orelse return false;
        self.playback = api.stream_new(self.core.?, "Verde Live voice", api.properties_new_string(playback_props)) orelse return false;
        api.stream_add_listener(self.capture.?, &self.capture_hook, &self.capture_events, self);
        api.stream_add_listener(self.playback.?, &self.playback_hook, &self.playback_events, self);

        formatPod(&self.capture_pod, config.capture_rate);
        formatPod(&self.playback_pod, config.playback_rate);
        const flags = FLAG_AUTOCONNECT | FLAG_MAP_BUFFERS | FLAG_RT_PROCESS;
        var capture_params = [_]*const anyopaque{&self.capture_pod};
        var playback_params = [_]*const anyopaque{&self.playback_pod};
        if (api.stream_connect(self.capture.?, DIRECTION_INPUT, ID_ANY, flags, &capture_params, 1) < 0) return false;
        if (api.stream_connect(self.playback.?, DIRECTION_OUTPUT, ID_ANY, flags, &playback_params, 1) < 0) return false;
        return true;
    }

    fn captureProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Device = @ptrCast(@alignCast(data orelse return));
        const stream = self.capture orelse return;
        const buffer = self.api.stream_dequeue_buffer(stream) orelse return;
        defer _ = self.api.stream_queue_buffer(stream, buffer);
        if (buffer.buffer.n_datas == 0) return;
        const block = &buffer.buffer.datas[0];
        const base: [*]const u8 = @ptrCast(block.data orelse return);
        const offset = @min(block.chunk.offset % @max(block.maxsize, 1), block.maxsize);
        const size = @min(block.chunk.size, block.maxsize - offset);
        if (size < 2 or (@intFromPtr(base + offset) & 1) != 0) return;
        const samples: [*]const i16 = @ptrCast(@alignCast(base + offset));
        const count = size / 2;
        _ = self.rings.capture.write(samples[0..count]);
        _ = self.captured.fetchAdd(count, .monotonic);
    }

    fn playbackProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Device = @ptrCast(@alignCast(data orelse return));
        const stream = self.playback orelse return;
        const buffer = self.api.stream_dequeue_buffer(stream) orelse return;
        defer _ = self.api.stream_queue_buffer(stream, buffer);
        if (buffer.buffer.n_datas == 0) return;
        const block = &buffer.buffer.datas[0];
        const raw = block.data orelse return;
        if ((@intFromPtr(raw) & 1) != 0) return;
        const capacity = block.maxsize / 2;
        var frames: usize = if (buffer.requested > 0) @min(@as(usize, @intCast(buffer.requested)), capacity) else @min(capacity, 1024);
        if (frames == 0) frames = capacity;
        const out: [*]i16 = @ptrCast(@alignCast(raw));
        const got = self.rings.playback.read(out[0..frames]);
        // Underrun or idle: silence, never stale samples.
        @memset(out[got..frames], 0);
        block.chunk.offset = 0;
        block.chunk.stride = 2;
        block.chunk.size = @intCast(frames * 2);
        buffer.size = frames;
    }

    fn stateChanged(_: ?*anyopaque, _: c_int, state: c_int, message: ?[*:0]const u8) callconv(.c) void {
        if (state == STATE_ERROR) log.warn("PipeWire stream error: {s}", .{if (message) |text| std.mem.span(text) else "unknown"});
    }
};

fn echoCancelAllowed() bool {
    const value = std.c.getenv("VERDE_LIVE_AEC") orelse return true;
    const text = std.mem.span(value);
    return !(std.mem.eql(u8, text, "off") or std.mem.eql(u8, text, "0") or std.mem.eql(u8, text, "false"));
}

/// Per-process node names, so two Verde instances never target each other's
/// echo canceller.
const NodeNames = struct {
    pid: c_int,

    fn init() NodeNames {
        return .{ .pid = std.c.getpid() };
    }

    fn moduleArgs(self: NodeNames, buffer: []u8) ?[:0]const u8 {
        // Low session priority keeps WirePlumber from making the virtual
        // nodes the system default while Live runs.
        return std.fmt.bufPrintZ(buffer,
            \\{{ library.name = aec/libspa-aec-webrtc audio.channels = 1 audio.position = [ MONO ]
            \\ capture.props = {{ node.name = "verde-live-aec-capture-{d}" node.passive = true }}
            \\ source.props = {{ node.name = "verde-live-aec-source-{d}" node.description = "Verde Live (echo cancelled)" priority.session = 0 priority.driver = 0 }}
            \\ sink.props = {{ node.name = "verde-live-aec-sink-{d}" node.description = "Verde Live (echo reference)" priority.session = 0 priority.driver = 0 }}
            \\ playback.props = {{ node.name = "verde-live-aec-playback-{d}" node.passive = true }} }}
        , .{ self.pid, self.pid, self.pid, self.pid }) catch null;
    }

    fn streamProps(self: NodeNames, buffer: []u8, direction: enum { capture, playback }, echo_cancel: bool) ?[:0]const u8 {
        const category = if (direction == .capture) "Capture" else "Playback";
        const node = if (direction == .capture) "verde-live-mic" else "verde-live-voice";
        const target_kind = if (direction == .capture) "source" else "sink";
        if (!echo_cancel) return std.fmt.bufPrintZ(buffer,
            \\media.type=Audio media.category={s} media.role=Communication application.name=Verde node.name={s}
        , .{ category, node }) catch null;
        return std.fmt.bufPrintZ(buffer,
            \\media.type=Audio media.category={s} media.role=Communication application.name=Verde node.name={s} target.object=verde-live-aec-{s}-{d} node.dont-fallback=true
        , .{ category, node, target_kind, self.pid }) catch null;
    }
};

// ---- tests -------------------------------------------------------------------------

test "format pod is an audio/raw S16LE mono EnumFormat object" {
    var pod: [FORMAT_POD_BYTES]u8 align(8) = undefined;
    formatPod(&pod, 24_000);
    const words = std.mem.bytesAsSlice(u32, &pod);
    try std.testing.expectEqual(@as(u32, FORMAT_POD_BYTES - 8), words[0]);
    try std.testing.expectEqual(SPA_TYPE_OBJECT, words[1]);
    try std.testing.expectEqual(SPA_TYPE_OBJECT_FORMAT, words[2]);
    try std.testing.expectEqual(SPA_PARAM_ENUM_FORMAT, words[3]);
    // Fourth property: rate.
    try std.testing.expectEqual(SPA_FORMAT_AUDIO_RATE, words[4 + 3 * 6]);
    try std.testing.expectEqual(SPA_TYPE_INT, words[4 + 3 * 6 + 3]);
    try std.testing.expectEqual(@as(u32, 24_000), words[4 + 3 * 6 + 4]);
    try std.testing.expectEqual(SPA_AUDIO_FORMAT_S16_LE, words[4 + 2 * 6 + 4]);
}

test "node names are per process and stream props target them only with AEC" {
    const names: NodeNames = .{ .pid = 42 };
    var buffer: [1024]u8 = undefined;
    const args = names.moduleArgs(&buffer).?;
    try std.testing.expect(std.mem.indexOf(u8, args, "verde-live-aec-source-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, args, "aec/libspa-aec-webrtc") != null);
    var props_buffer: [512]u8 = undefined;
    const with = names.streamProps(&props_buffer, .capture, true).?;
    try std.testing.expect(std.mem.indexOf(u8, with, "target.object=verde-live-aec-source-42") != null);
    const without = names.streamProps(&props_buffer, .playback, false).?;
    try std.testing.expect(std.mem.indexOf(u8, without, "target.object") == null);
    try std.testing.expect(std.mem.indexOf(u8, without, "media.category=Playback") != null);
}
