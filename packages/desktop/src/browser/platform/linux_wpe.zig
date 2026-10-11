//! Linux browser backend implemented as an offscreen WPE WebKit helper process.

const std = @import("std");
const builtin = @import("builtin");
const browser_input = @import("../input.zig");
const browser_queue = @import("../queue.zig");
const browser_texture = @import("../texture.zig");
const browser_types = @import("../types.zig");
const ipc = @import("linux_ipc.zig");
const fp = @import("frame_protocol.zig");
const loop_wakeup = @import("loop_wakeup");

const log = std.log.scoped(.linux_wpe);

const DEFAULT_WIDTH: u32 = 1280;
const DEFAULT_HEIGHT: u32 = 720;
const FRAME_FD_BASE: std.posix.fd_t = 240;
const FRAME_SLOT_COUNT: usize = 3;
/// The helper's end of the zero-copy frame socket sits right after the shm slots.
const FRAME_SOCKET_FD: std.posix.fd_t = fp.socket_fd;
comptime {
    std.debug.assert(FRAME_SOCKET_FD == FRAME_FD_BASE + FRAME_SLOT_COUNT);
}
/// Cached dma-buf imports per helper (WebKit cycles through a few buffers).
const DMABUF_KEY_CACHE = 16;
const FRAME_BYTES_MAX: usize = 4096 * 2160 * 4;
const IPC_LINE_BUFFER_BYTES = 256 * 1024;

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

fn monotonicTimestampNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

fn monotonicTimestampNsU64() u64 {
    return @intCast(@max(monotonicTimestampNs(), 0));
}

fn nanosToMillis(nanos: i128) f64 {
    return @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn deleteFramePath(path: []const u8) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    std.Io.Dir.deleteFileAbsolute(threaded.io(), path) catch {};
}

fn frameLogEnabled() bool {
    const value = std.c.getenv("VERDE_BROWSER_FRAME_LOG") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "1");
}

pub fn configuredPresentationKind() browser_types.PresentationKind {
    return .offscreen_texture;
}

pub fn configuredSupportsInspector() bool {
    return true;
}

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    queue: *SharedQueue,
    frame: *SharedFrame,
    stdout_file: std.Io.File,
};

const SharedQueue = struct {
    mutex: Mutex = .{},
    events: browser_queue.EventQueue = .{},

    /// Releases any queued browser events.
    fn deinit(self: *SharedQueue, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.events.deinit(allocator);
    }

    /// Adds a new event received from the helper stdout reader thread.
    fn push(self: *SharedQueue, allocator: std.mem.Allocator, event: browser_types.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.push(allocator, event);
    }

    /// Removes and returns the oldest queued event, if one exists.
    fn pop(self: *SharedQueue) ?browser_types.Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.pop();
    }
};

const FrameRelease = struct {
    sequence: u64,
    slot: u8,
};

const MetricSamples = struct {
    values: [256]u64 = undefined,
    len: usize = 0,

    fn add(self: *MetricSamples, value: u64) void {
        if (self.len >= self.values.len) return;
        self.values[self.len] = value;
        self.len += 1;
    }

    fn percentile(self: *const MetricSamples, percent: usize) u64 {
        if (self.len == 0) return 0;
        var sorted: [256]u64 = undefined;
        @memcpy(sorted[0..self.len], self.values[0..self.len]);
        var index: usize = 1;
        while (index < self.len) : (index += 1) {
            const value = sorted[index];
            var cursor = index;
            while (cursor > 0 and sorted[cursor - 1] > value) : (cursor -= 1) {
                sorted[cursor] = sorted[cursor - 1];
            }
            sorted[cursor] = value;
        }
        return sorted[((self.len - 1) * percent) / 100];
    }

    fn clear(self: *MetricSamples) void {
        self.len = 0;
    }
};

const FrameMetrics = struct {
    received: u64 = 0,
    stale_rejected: u64 = 0,
    pending_overwritten: u64 = 0,
    slot_releases: u64 = 0,
    wake_requested: u64 = 0,
    wake_coalesced: u64 = 0,
    upload_deferred: u64 = 0,
    upload_completed: u64 = 0,
    screenshot_copies: u64 = 0,
    presented: u64 = 0,
    last_received_ns: u64 = 0,
    last_presented_ns: u64 = 0,
    last_input_serial: u64 = 0,
    last_presented_input_serial: u64 = 0,
    last_report_ns: u64 = 0,
    receive_intervals: MetricSamples = .{},
    present_intervals: MetricSamples = .{},
    helper_transport: MetricSamples = .{},
    export_to_receive: MetricSamples = .{},
    export_to_present: MetricSamples = .{},
    input_to_frame: MetricSamples = .{},
    input_to_present: MetricSamples = .{},
    upload_duration: MetricSamples = .{},

    fn noteReceived(self: *FrameMetrics, event: ipc.Event, received_at_ns: u64) void {
        self.received += 1;
        if (self.last_received_ns > 0 and received_at_ns >= self.last_received_ns) {
            self.receive_intervals.add(received_at_ns - self.last_received_ns);
        }
        if (event.helper_sent_at_ns > 0 and received_at_ns >= event.helper_sent_at_ns) {
            self.helper_transport.add(received_at_ns - event.helper_sent_at_ns);
        }
        if (event.exported_at_ns > 0 and received_at_ns >= event.exported_at_ns) {
            self.export_to_receive.add(received_at_ns - event.exported_at_ns);
        }
        if (event.input_serial != 0 and event.input_serial != self.last_input_serial) {
            self.last_input_serial = event.input_serial;
            if (event.input_sent_at_ns > 0 and received_at_ns >= event.input_sent_at_ns) {
                self.input_to_frame.add(received_at_ns - event.input_sent_at_ns);
            }
        }
        self.last_received_ns = received_at_ns;
    }

    fn notePresented(self: *FrameMetrics, input_serial: u64, input_sent_at_ns: u64, exported_at_ns: u64, presented_at_ns: u64) void {
        self.presented += 1;
        if (self.last_presented_ns > 0 and presented_at_ns >= self.last_presented_ns) {
            self.present_intervals.add(presented_at_ns - self.last_presented_ns);
        }
        if (exported_at_ns > 0 and presented_at_ns >= exported_at_ns) {
            self.export_to_present.add(presented_at_ns - exported_at_ns);
        }
        if (input_serial != 0 and input_serial != self.last_presented_input_serial) {
            self.last_presented_input_serial = input_serial;
            if (input_sent_at_ns > 0 and presented_at_ns >= input_sent_at_ns) {
                self.input_to_present.add(presented_at_ns - input_sent_at_ns);
            }
        }
        self.last_presented_ns = presented_at_ns;
    }

    fn maybeLog(self: *FrameMetrics, now_ns: u64) void {
        if (!frameLogEnabled()) return;
        if (self.last_report_ns != 0 and now_ns - self.last_report_ns < std.time.ns_per_s) return;
        self.last_report_ns = now_ns;
        log.info(
            "frame-pipeline received={} presented={} stale={} overwritten={} releases={} wakes={}/{} upload_deferred={} uploaded={} screenshots={} receive_interval_ms[p50={d:.2} p95={d:.2} p99={d:.2}] present_interval_ms[p50={d:.2} p95={d:.2} p99={d:.2}] transport_ms[p50={d:.2} p95={d:.2} p99={d:.2}]",
            .{
                self.received,
                self.presented,
                self.stale_rejected,
                self.pending_overwritten,
                self.slot_releases,
                self.wake_requested,
                self.wake_coalesced,
                self.upload_deferred,
                self.upload_completed,
                self.screenshot_copies,
                nanosToMillis(@intCast(self.receive_intervals.percentile(50))),
                nanosToMillis(@intCast(self.receive_intervals.percentile(95))),
                nanosToMillis(@intCast(self.receive_intervals.percentile(99))),
                nanosToMillis(@intCast(self.present_intervals.percentile(50))),
                nanosToMillis(@intCast(self.present_intervals.percentile(95))),
                nanosToMillis(@intCast(self.present_intervals.percentile(99))),
                nanosToMillis(@intCast(self.helper_transport.percentile(50))),
                nanosToMillis(@intCast(self.helper_transport.percentile(95))),
                nanosToMillis(@intCast(self.helper_transport.percentile(99))),
            },
        );
        log.info(
            "frame-latency export_receive_ms[p50={d:.2} p95={d:.2} p99={d:.2}] export_present_ms[p50={d:.2} p95={d:.2} p99={d:.2}] input_receive_ms[p50={d:.2} p95={d:.2} p99={d:.2}] input_present_ms[p50={d:.2} p95={d:.2} p99={d:.2}] upload_ms[p50={d:.2} p95={d:.2} p99={d:.2}]",
            .{
                nanosToMillis(@intCast(self.export_to_receive.percentile(50))),
                nanosToMillis(@intCast(self.export_to_receive.percentile(95))),
                nanosToMillis(@intCast(self.export_to_receive.percentile(99))),
                nanosToMillis(@intCast(self.export_to_present.percentile(50))),
                nanosToMillis(@intCast(self.export_to_present.percentile(95))),
                nanosToMillis(@intCast(self.export_to_present.percentile(99))),
                nanosToMillis(@intCast(self.input_to_frame.percentile(50))),
                nanosToMillis(@intCast(self.input_to_frame.percentile(95))),
                nanosToMillis(@intCast(self.input_to_frame.percentile(99))),
                nanosToMillis(@intCast(self.input_to_present.percentile(50))),
                nanosToMillis(@intCast(self.input_to_present.percentile(95))),
                nanosToMillis(@intCast(self.input_to_present.percentile(99))),
                nanosToMillis(@intCast(self.upload_duration.percentile(50))),
                nanosToMillis(@intCast(self.upload_duration.percentile(95))),
                nanosToMillis(@intCast(self.upload_duration.percentile(99))),
            },
        );
        self.receive_intervals.clear();
        self.present_intervals.clear();
        self.helper_transport.clear();
        self.export_to_receive.clear();
        self.export_to_present.clear();
        self.input_to_frame.clear();
        self.input_to_present.clear();
        self.upload_duration.clear();
    }
};

const SharedFrame = struct {
    mutex: Mutex = .{},
    slots: [FRAME_SLOT_COUNT][]align(std.heap.page_size_min) u8 = undefined,
    slot_ready: [FRAME_SLOT_COUNT]bool = [_]bool{false} ** FRAME_SLOT_COUNT,
    current_slot: ?u8 = null,
    /// The latest frame came over the frame socket (no shm pixels).
    current_dmabuf: bool = false,
    releases: [FRAME_SLOT_COUNT * 2]FrameRelease = undefined,
    release_count: usize = 0,
    path: ?[]u8 = null,
    sequence: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    byte_len: usize = 0,
    dirty: bool = false,
    exported_at_ns: u64 = 0,
    published_at_ns: u64 = 0,
    helper_sent_at_ns: u64 = 0,
    received_at_ns: u64 = 0,
    input_serial: u64 = 0,
    input_sent_at_ns: u64 = 0,
    uploaded_sequence: u64 = 0,
    uploaded_exported_at_ns: u64 = 0,
    uploaded_input_serial: u64 = 0,
    uploaded_input_sent_at_ns: u64 = 0,
    presented_sequence: u64 = 0,
    /// Latest helper paint ack: request token and the frame sequence that
    /// was current when the resumed page finished painting.
    paint_ack_token: u64 = 0,
    paint_ack_sequence: u64 = 0,
    metrics: FrameMetrics = .{},

    /// Records a helper paint ack ("<token>:<frame sequence>").
    fn notePaintAck(self: *SharedFrame, payload: []const u8) void {
        const ack = parsePaintAck(payload) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.paint_ack_token = ack.token;
        self.paint_ack_sequence = ack.sequence;
    }

    /// True once `token` was acked and the frame current at the ack has
    /// arrived (the helper may write the ack before that frame's event).
    fn paintAckSatisfied(self: *SharedFrame, token: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.paint_ack_token == token and self.sequence >= self.paint_ack_sequence;
    }

    /// Releases the latest published helper frame metadata.
    fn deinit(self: *SharedFrame, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.path) |path| {
            deleteFramePath(path);
            allocator.free(path);
        }
        for (0..FRAME_SLOT_COUNT) |index| {
            if (!self.slot_ready[index]) continue;
            std.posix.munmap(self.slots[index]);
            self.slot_ready[index] = false;
        }
        self.path = null;
        self.current_slot = null;
        self.current_dmabuf = false;
        self.sequence = 0;
        self.width = 0;
        self.height = 0;
        self.byte_len = 0;
        self.dirty = false;
        self.release_count = 0;
    }

    fn queueReleaseLocked(self: *SharedFrame, release: FrameRelease) void {
        if (release.sequence == 0) return;
        for (self.releases[0..self.release_count]) |pending| {
            if (pending.sequence == release.sequence and pending.slot == release.slot) return;
        }
        if (self.release_count >= self.releases.len) return;
        self.releases[self.release_count] = release;
        self.release_count += 1;
    }

    fn popRelease(self: *SharedFrame) ?FrameRelease {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.release_count == 0) return null;
        self.release_count -= 1;
        return self.releases[self.release_count];
    }

    fn restoreRelease(self: *SharedFrame, release: FrameRelease) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.queueReleaseLocked(release);
    }

    fn noteWake(self: *SharedFrame, result: loop_wakeup.NotifyResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.wake_requested += 1;
        if (result == .coalesced) self.metrics.wake_coalesced += 1;
    }

    /// Replaces the latest published helper frame metadata without copying its pixels.
    fn update(self: *SharedFrame, allocator: std.mem.Allocator, event: ipc.Event) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (event.frame_sequence <= self.sequence) {
            self.metrics.stale_rejected += 1;
            if (event.frame_path) |path| {
                deleteFramePath(path);
            } else if (event.frame_slot < FRAME_SLOT_COUNT) {
                const is_current = event.frame_sequence == self.sequence and self.current_slot == event.frame_slot;
                if (!is_current) self.queueReleaseLocked(.{ .sequence = event.frame_sequence, .slot = event.frame_slot });
            }
            return false;
        }
        const dmabuf = event.frame_path == null and event.frame_slot == fp.dmabuf_frame_slot;
        if (event.frame_path == null and !dmabuf) {
            if (event.frame_slot >= FRAME_SLOT_COUNT) return error.InvalidFrameSlot;
            if (!self.slot_ready[event.frame_slot]) return error.InvalidFrameSlot;
            if (event.byte_len > self.slots[event.frame_slot].len) return error.FrameTooLarge;
        }

        if (self.current_slot) |slot| {
            self.queueReleaseLocked(.{ .sequence = self.sequence, .slot = slot });
        }
        if (self.dirty) self.metrics.pending_overwritten += 1;
        if (self.path) |old_path| {
            deleteFramePath(old_path);
            allocator.free(old_path);
            self.path = null;
        }
        self.current_dmabuf = dmabuf;
        if (event.frame_path) |path| {
            self.path = try allocator.dupe(u8, path);
            self.current_slot = null;
        } else if (dmabuf) {
            // Pixels arrived over the frame socket; the main thread imports them.
            self.current_slot = null;
        } else {
            self.current_slot = event.frame_slot;
        }

        self.sequence = event.frame_sequence;
        self.width = event.width;
        self.height = event.height;
        self.byte_len = event.byte_len;
        self.exported_at_ns = event.exported_at_ns;
        self.published_at_ns = event.published_at_ns;
        self.helper_sent_at_ns = event.helper_sent_at_ns;
        self.received_at_ns = monotonicTimestampNsU64();
        self.input_serial = event.input_serial;
        self.input_sent_at_ns = event.input_sent_at_ns;
        self.dirty = true;
        self.metrics.noteReceived(event, self.received_at_ns);
        return true;
    }

    /// Uploads the latest dirty helper snapshot into the pane texture.
    fn uploadIntoTexture(
        self: *SharedFrame,
        allocator: std.mem.Allocator,
        frame_buffer: *std.ArrayList(u8),
        texture: *browser_texture.PaneTexture,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.dirty or self.width == 0 or self.height == 0 or self.byte_len == 0) return false;

        const read_start = monotonicTimestampNs();
        var upload_pixels: []const u8 = undefined;
        if (self.path) |path| {
            try frame_buffer.resize(allocator, self.byte_len);
            var threaded = std.Io.Threaded.init_single_threaded;
            const file = try std.Io.Dir.openFileAbsolute(threaded.io(), path, .{ .mode = .read_only });
            defer file.close(threaded.io());
            var read_buffer: [8 * 1024]u8 = undefined;
            var reader = file.reader(threaded.io(), &read_buffer);
            try reader.interface.readSliceAll(frame_buffer.items[0..self.byte_len]);
            upload_pixels = frame_buffer.items[0..self.byte_len];
        } else {
            const slot = self.current_slot orelse return false;
            upload_pixels = self.slots[slot][0..self.byte_len];
        }
        const read_end = monotonicTimestampNs();

        const upload_start = monotonicTimestampNs();
        const result = try texture.uploadBgraImmediately(self.width, self.height, upload_pixels);
        const upload_end = monotonicTimestampNs();
        switch (result) {
            .deferred => {
                self.metrics.upload_deferred += 1;
                return false;
            },
            .uploaded => {
                self.metrics.upload_completed += 1;
                self.metrics.upload_duration.add(@intCast(@max(upload_end - upload_start, 0)));
                self.uploaded_sequence = self.sequence;
                self.uploaded_exported_at_ns = self.exported_at_ns;
                self.uploaded_input_serial = self.input_serial;
                self.uploaded_input_sent_at_ns = self.input_sent_at_ns;
                self.dirty = false;
            },
        }
        if (self.path) |path| {
            deleteFramePath(path);
            allocator.free(path);
            self.path = null;
        }
        if (frameLogEnabled()) {
            log.info(
                "snapshot frame seq={} exported_ns={} published_ns={} helper_sent_ns={} received_ns={} read_ms={d:.3} upload_ms={d:.3} bytes={} size={}x{}",
                .{
                    self.sequence,
                    self.exported_at_ns,
                    self.published_at_ns,
                    self.helper_sent_at_ns,
                    self.received_at_ns,
                    nanosToMillis(read_end - read_start),
                    nanosToMillis(upload_end - upload_start),
                    self.byte_len,
                    self.width,
                    self.height,
                },
            );
        }
        return true;
    }

    /// Records that a dma-buf frame up to `sequence` is bound to the pane
    /// texture, settling the matching `frame_ready` whichever arrived first.
    fn noteDmabufShown(self: *SharedFrame, sequence: u64, exported_at_ns: u64, imported: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (imported) {
            self.metrics.upload_completed += 1;
            self.uploaded_sequence = sequence;
            self.uploaded_exported_at_ns = exported_at_ns;
            self.uploaded_input_serial = 0;
            self.uploaded_input_sent_at_ns = 0;
        }
        if (self.current_dmabuf and self.dirty and self.sequence <= sequence) {
            self.dirty = false;
            if (self.sequence == self.uploaded_sequence) {
                self.uploaded_input_serial = self.input_serial;
                self.uploaded_input_sent_at_ns = self.input_sent_at_ns;
            }
        }
    }

    /// Sequence of the newest frame the helper announced on stdout, and
    /// whether it was a dma-buf frame.
    fn latest(self: *SharedFrame) struct { sequence: u64, dmabuf: bool } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .sequence = self.sequence, .dmabuf = self.current_dmabuf };
    }

    fn notePresented(self: *SharedFrame, presented_at_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.uploaded_sequence == 0 or self.uploaded_sequence == self.presented_sequence) return;
        self.presented_sequence = self.uploaded_sequence;
        self.metrics.notePresented(
            self.uploaded_input_serial,
            self.uploaded_input_sent_at_ns,
            self.uploaded_exported_at_ns,
            presented_at_ns,
        );
        self.metrics.maybeLog(presented_at_ns);
    }
};

/// Owns the Linux browser helper process and translates its stdout into browser events plus pane frames.
/// Mirrors VERDE_BROWSER_LINUX_HIDDEN_PAINT_GRACE_MS (15 s) in linux_wpe.c,
/// with a margin so a capture near the boundary still wakes the page.
const HIDDEN_PAINT_RESUME_AFTER_NS: u64 = 13 * std.time.ns_per_s;
/// Bound for the helper's paint ack (two animation frames plus a quiet
/// window). Missing it means the page could not prove a current frame.
const PAINT_ACK_WAIT_MAX_MS: u32 = 1500;
const PAINT_ACK_WAIT_STEP_MS: u32 = 5;

/// A FRAME received over the frame socket, not yet bound to the pane texture.
const PendingDmabuf = struct {
    msg: fp.Frame,
    rx: fp.Received,
};

/// The dma-buf frame the pane texture currently shows.
const ShownDmabuf = struct {
    sequence: u64,
    key: u64,
    texture_id: c_uint,
    width: u32,
    height: u32,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    child_pid: ?std.posix.pid_t = null,
    child_process_group: ?std.posix.pid_t = null,
    stdin_file: ?std.Io.File = null,
    queue: *SharedQueue,
    frame: *SharedFrame,
    frame_buffer: std.ArrayList(u8) = .empty,
    reader_thread: ?std.Thread = null,
    pane_width: u32 = DEFAULT_WIDTH,
    pane_height: u32 = DEFAULT_HEIGHT,
    pane_screen_x: i32 = 0,
    pane_screen_y: i32 = 0,
    pane_scale: f32 = 1.0,
    /// Monotonic time the pane was hidden; the helper stops painting a hidden
    /// page after HIDDEN_PAINT_GRACE_MS, so captures must wake it first.
    hidden_since_ns: ?u64 = null,
    /// Last resume_painting request token; acks echo it back.
    paint_ack_token: u64 = 0,
    host_window: u64 = 0,
    current_url: ?[]u8 = null,
    next_input_serial: u64 = 0,
    /// GUI end of the zero-copy frame socket (null: shm slots only).
    frame_socket: ?std.posix.fd_t = null,
    frame_mode: fp.Mode = .shm,
    dmabuf_pending: ?PendingDmabuf = null,
    dmabuf_shown: ?ShownDmabuf = null,
    dmabuf_keys: [DMABUF_KEY_CACHE]u64 = @splat(0),
    dmabuf_key_count: usize = 0,
    /// A dma-buf frame was bound outside `uploadFrame` (screenshot); the next
    /// upload refreshes the pane texture metadata.
    dmabuf_texture_stale: bool = false,
    dmabuf_import_failed_logged: bool = false,
    /// Renderer texture id of the pane, from the last `uploadFrame`.
    pane_texture_id: c_uint = 0,

    /// Creates the helper-backed Linux browser controller.
    pub fn init(allocator: std.mem.Allocator) !Controller {
        const queue = try allocator.create(SharedQueue);
        queue.* = .{};
        errdefer allocator.destroy(queue);

        const frame = try allocator.create(SharedFrame);
        frame.* = .{};
        errdefer allocator.destroy(frame);

        var controller: Controller = .{
            .allocator = allocator,
            .queue = queue,
            .frame = frame,
        };
        errdefer controller.frame_buffer.deinit(allocator);
        try controller.spawnHelper();
        return controller;
    }

    /// Terminates the helper process and releases queued events.
    pub fn deinit(self: *Controller) void {
        if (self.child_pid != null) {
            self.sendCommand(.{ .kind = .quit }) catch {};
            self.closeChildStdin();
            // WebKit descendants can inherit the helper's protocol stdout and
            // keep the reader blocked after the helper exits. Bound the whole
            // process group before joining the reader so teardown cannot wedge
            // Verde's UI thread.
            self.terminateChild();
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        self.closeFrameSocket();
        if (self.current_url) |url| self.allocator.free(url);
        self.frame_buffer.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.frame.deinit(self.allocator);
        self.allocator.destroy(self.queue);
        self.allocator.destroy(self.frame);
    }

    pub fn shutdown(self: *Controller) void {
        self.deinit();
    }

    pub fn runtimeKind(self: *const Controller) browser_types.RuntimeKind {
        _ = self;
        return .native_webview;
    }

    pub fn isRuntimeInitialized(self: *const Controller) bool {
        return self.child_pid != null;
    }

    pub fn runtimeMode(self: *const Controller) browser_types.RuntimeMode {
        _ = self;
        return .keep_warm;
    }

    pub fn supportsInspector(self: *const Controller) bool {
        _ = self;
        return configuredSupportsInspector();
    }

    pub fn supportsPopout(self: *const Controller) bool {
        _ = self;
        return false;
    }

    pub fn paneSessionId(self: *const Controller) ?browser_types.SessionId {
        if (self.child_pid == null) return null;
        return 1;
    }

    pub fn paneTexture(self: *const Controller) ?browser_texture.PaneTexture {
        _ = self;
        return null;
    }

    /// Forwards the host window handle to the helper (diagnostics only on Linux).
    pub fn setHostWindow(self: *Controller, handle: ?*anyopaque) !void {
        self.host_window = if (handle) |value| @intFromPtr(value) else 0;
        try self.sendCommand(.{
            .kind = .set_host_window,
            .host_window = self.host_window,
        });
    }

    /// Linux always presents helper frames as an offscreen texture.
    pub fn presentationKind(self: *const Controller) browser_types.PresentationKind {
        _ = self;
        return configuredPresentationKind();
    }

    /// Requests that the Linux browser helper warm the offscreen browser surface.
    pub fn show(self: *Controller) !void {
        self.hidden_since_ns = null;
        try self.sendCommand(.{
            .kind = .show,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
        });
    }

    /// Requests that the Linux browser helper pause its surface updates.
    pub fn hide(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .hide });
        if (self.hidden_since_ns == null) self.hidden_since_ns = monotonicTimestampNsU64();
    }

    /// Toggles the Linux browser helper window by delegating to the shared controller visibility state.
    pub fn toggle(self: *Controller) !void {
        _ = self;
    }

    /// Updates the offscreen browser size to match the pane viewport.
    pub fn resizePane(self: *Controller, width: u32, height: u32) !void {
        try self.setPaneBounds(.{
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = width,
            .height = height,
            .scale = self.pane_scale,
        });
    }

    /// Moves and resizes the helper-owned native surface to the Palette browser content rectangle.
    pub fn setPaneBounds(self: *Controller, bounds: browser_types.PaneBounds) !void {
        self.pane_width = @max(bounds.width, 1);
        self.pane_height = @max(bounds.height, 1);
        self.pane_screen_x = bounds.screen_x;
        self.pane_screen_y = bounds.screen_y;
        self.pane_scale = @max(bounds.scale, 0.05);
        try self.sendCommand(.{
            .kind = .set_bounds,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
        });
    }

    /// Navigates the Linux browser helper to the requested URL.
    pub fn navigate(self: *Controller, url: []const u8) !void {
        try self.setCurrentUrl(url);
        try self.sendCommand(.{
            .kind = .navigate,
            .width = self.pane_width,
            .height = self.pane_height,
            .scale = self.pane_scale,
            .screen_x = self.pane_screen_x,
            .screen_y = self.pane_screen_y,
            .payload = url,
        });
    }

    /// Evaluates JavaScript inside the Linux browser helper.
    pub fn eval(self: *Controller, js: []const u8) !void {
        try self.sendCommand(.{ .kind = .eval, .payload = js });
    }

    /// Sends a host-originated JSON payload into the Linux browser helper.
    pub fn postJson(self: *Controller, json: []const u8) !void {
        try self.sendCommand(.{ .kind = .post_json, .payload = json });
    }

    /// Navigates backward through the helper using WPE WebKit history.
    pub fn goBack(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .go_back });
    }

    /// Navigates forward through the helper using WPE WebKit history.
    pub fn goForward(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .go_forward });
    }

    /// Imports cookies into the shared network session via the helper. The JSON
    /// payload is an array of cookie objects; values are never logged. Sent
    /// regardless of presentation mode since the helper owns the cookie store.
    pub fn importCookies(self: *Controller, json: []const u8) !void {
        try self.sendCommand(.{ .kind = .import_cookies, .payload = json });
    }

    /// Reloads the helper page using WPE WebKit navigation.
    pub fn reload(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .reload });
    }

    /// Gives the visible helper's WebKit view native focus when that presentation is active.
    pub fn focus(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .focus });
    }

    /// Clears native focus from the visible helper when that presentation is active.
    pub fn blur(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .blur });
    }

    /// Sends pointer motion, click, and wheel input into the offscreen browser.
    pub fn handleMouse(self: *Controller, event: browser_input.MouseEvent) !bool {
        if (event.button) |button| {
            try self.sendCommand(.{
                .kind = .mouse_button,
                .x = event.x,
                .y = event.y,
                .button = encodeMouseButton(button),
                .pressed = event.pressed,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        if (event.wheel_x != 0.0 or event.wheel_y != 0.0) {
            try self.sendCommand(.{
                .kind = .mouse_wheel,
                .x = event.x,
                .y = event.y,
                .wheel_x = event.wheel_x,
                .wheel_y = event.wheel_y,
                .wheel_multiplier = event.wheel_multiplier,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        try self.sendCommand(.{
            .kind = .mouse_move,
            .x = event.x,
            .y = event.y,
            .ctrl = event.ctrl,
            .shift = event.shift,
            .alt = event.alt,
            .super = event.super,
        });
        return true;
    }

    /// Sends key and text input into the offscreen browser.
    pub fn handleKey(self: *Controller, event: browser_input.KeyEvent) !bool {
        if (event.text) |text| {
            if (text.len == 0) return false;
            try self.sendCommand(.{
                .kind = .text_input,
                .payload = text,
                .ctrl = event.ctrl,
                .shift = event.shift,
                .alt = event.alt,
                .super = event.super,
            });
            return true;
        }
        if (event.key_code == 0) return false;
        // WebKit interprets printable keysyms on dispatch and inserts the
        // character itself, but the platform text_input event (the `.text` branch
        // above) is the source of truth for typed text — it alone carries
        // shifted and IME-composed characters. Dispatching printable keysyms
        // here as well doubles every typed character, so swallow them and let
        // text_input deliver the text. Ctrl/Alt/Super combos still dispatch
        // so in-page shortcuts keep working.
        const printable = event.key_code >= 0x20 and event.key_code <= 0x7f;
        if (printable and !event.ctrl and !event.alt and !event.super) return true;
        try self.sendCommand(.{
            .kind = .key_input,
            .key_code = event.key_code,
            .pressed = event.pressed,
            .ctrl = event.ctrl,
            .shift = event.shift,
            .alt = event.alt,
            .super = event.super,
        });
        return true;
    }

    /// Activates a context-menu item previously reported by the helper.
    pub fn activateContextMenuItem(self: *Controller, index: u32) !void {
        try self.sendCommand(.{ .kind = .context_menu_activate, .width = index });
    }

    /// Dismisses the helper's active context menu, if any.
    pub fn dismissContextMenu(self: *Controller) !void {
        try self.sendCommand(.{ .kind = .context_menu_dismiss });
    }

    /// Returns the next browser event received from the Linux browser helper, if available.
    pub fn popEvent(self: *Controller) ?browser_types.Event {
        return self.queue.pop();
    }

    /// Alias used by the shared backend contract.
    pub fn pollEvent(self: *Controller) ?browser_types.Event {
        return self.popEvent();
    }

    /// Uploads the latest helper snapshot into the pane texture, if a new frame is ready.
    pub fn uploadFrame(self: *Controller, texture: *browser_texture.PaneTexture) !bool {
        try self.flushFrameReleases();
        self.pumpFrameSocket();
        var uploaded = try self.frame.uploadIntoTexture(self.allocator, &self.frame_buffer, texture);
        if (uploaded) {
            // A shm frame replaced the dma-buf one in the same texture.
            self.retireShownDmabuf(0, texture.width, texture.height);
        }
        if (self.dmabuf_pending) |pending| {
            self.dmabuf_pending = null;
            if (self.applyDmabuf(pending, texture.texture_id)) uploaded = true;
        }
        if (self.dmabuf_shown) |shown| {
            if (uploaded or self.dmabuf_texture_stale or texture.texture_id != shown.texture_id) {
                texture.update(shown.texture_id, shown.width, shown.height, true);
                uploaded = true;
            }
            self.dmabuf_texture_stale = false;
            self.frame.noteDmabufShown(shown.sequence, 0, false);
        }
        self.pane_texture_id = texture.texture_id;
        try self.flushFrameReleases();
        return uploaded;
    }

    /// Records when the app successfully submitted the render containing the latest uploaded frame.
    pub fn noteFramePresented(self: *Controller) void {
        self.frame.notePresented(monotonicTimestampNsU64());
    }

    /// Returns a caller-owned copy of the most recent helper frame, or null when
    /// no frame has been produced yet (e.g. browser not shown).
    pub fn copyFramePixels(self: *Controller, allocator: std.mem.Allocator) !?browser_texture.CopiedFrame {
        try self.refreshPausedFrame();
        if (self.frame.latest().dmabuf) {
            // The newest frame lives only on the GPU: bind it if needed, then
            // read the pane texture back.
            self.pumpFrameSocket();
            if (self.dmabuf_pending) |pending| {
                self.dmabuf_pending = null;
                const texture_id = if (self.dmabuf_shown) |shown| shown.texture_id else self.pane_texture_id;
                if (self.applyDmabuf(pending, texture_id)) self.dmabuf_texture_stale = true;
            }
            self.flushFrameReleases() catch {};
            const shown = self.dmabuf_shown orelse return null;
            const importer = browser_texture.dmabufImporter() orelse return null;
            self.frame.mutex.lock();
            self.frame.metrics.screenshot_copies += 1;
            self.frame.mutex.unlock();
            return try importer.readback(importer.context, allocator, shown.texture_id, shown.width, shown.height);
        }
        var frame_width: u32 = 0;
        var frame_height: u32 = 0;
        var frame_byte_len: usize = 0;
        {
            self.frame.mutex.lock();
            defer self.frame.mutex.unlock();
            frame_width = self.frame.width;
            frame_height = self.frame.height;
            frame_byte_len = self.frame.byte_len;
            if (self.frame.current_slot) |slot| {
                if (frame_byte_len == 0 or frame_width == 0 or frame_height == 0 or
                    self.frame.slots[slot].len < frame_byte_len) return null;
                self.frame.metrics.screenshot_copies += 1;
                return .{
                    .width = frame_width,
                    .height = frame_height,
                    .format = .bgra,
                    .pixels = try allocator.dupe(u8, self.frame.slots[slot][0..frame_byte_len]),
                };
            }
        }
        // Temp-file fallback frames retain the main-thread-owned upload buffer.
        if (frame_byte_len == 0 or frame_width == 0 or frame_height == 0) return null;
        if (self.frame_buffer.items.len < frame_byte_len) return null;
        return .{
            .width = frame_width,
            .height = frame_height,
            .format = .bgra,
            .pixels = try allocator.dupe(u8, self.frame_buffer.items[0..frame_byte_len]),
        };
    }

    /// A hidden page stops painting after the helper's grace period, leaving
    /// the shared slot holding whatever it showed then. Before a capture, wake
    /// it and wait (bounded) for a newer frame. No new frame within the bound
    /// means nothing was damaged, so the held frame is still current.
    fn refreshPausedFrame(self: *Controller) !void {
        const hidden_since_ns = self.hidden_since_ns orelse return;
        if (self.child_pid == null) return;
        const now_ns = monotonicTimestampNsU64();
        if (now_ns -| hidden_since_ns < HIDDEN_PAINT_RESUME_AFTER_NS) return;
        self.paint_ack_token +%= 1;
        if (self.paint_ack_token == 0) self.paint_ack_token = 1;
        const token = self.paint_ack_token;
        try self.sendCommand(.{ .kind = .resume_painting, .frame_sequence = token });
        var waited_ms: u32 = 0;
        while (waited_ms < PAINT_ACK_WAIT_MAX_MS) : (waited_ms += PAINT_ACK_WAIT_STEP_MS) {
            // Hidden panes never upload, so return slots here or the helper
            // can only defer the frame it is waiting to publish.
            self.flushFrameReleases() catch {};
            self.pumpFrameSocket();
            if (self.frame.paintAckSatisfied(token)) {
                // The helper restarted its grace at the request; captures
                // within it see live painting.
                self.hidden_since_ns = now_ns;
                return;
            }
            sleepMillis(PAINT_ACK_WAIT_STEP_MS);
        }
        // No ack: a hung or busy page cannot prove its held frame is current.
        log.warn("browser capture: hidden page did not acknowledge a fresh paint within {d} ms", .{PAINT_ACK_WAIT_MAX_MS});
        return error.BrowserFrameStale;
    }

    // Launches the installed browser helper binary beside the desktop executable.
    fn spawnHelper(self: *Controller) !void {
        const helper_path = try browserHelperPath(self.allocator);
        defer self.allocator.free(helper_path);

        const stdin_pipe = try createProtocolPipe();
        errdefer {
            _ = std.c.close(stdin_pipe[0]);
            _ = std.c.close(stdin_pipe[1]);
        }
        const stdout_pipe = try createProtocolPipe();
        errdefer {
            _ = std.c.close(stdout_pipe[0]);
            _ = std.c.close(stdout_pipe[1]);
        }
        const frame_fds: ?[FRAME_SLOT_COUNT]std.posix.fd_t = createFrameSlots(self.frame, self.allocator) catch |err| frame_fds: {
            log.warn("Linux WebKit shared frame slots unavailable: {}; falling back to temp-frame files", .{err});
            break :frame_fds null;
        };
        var frame_fds_to_close = frame_fds;
        errdefer if (frame_fds_to_close) |fds| {
            for (fds) |fd| _ = std.c.close(fd);
            self.frame.deinit(self.allocator);
        };
        // Zero-copy frames need the shm slots too (the helper falls back to
        // them per frame), so the socket only comes with them.
        const frame_socket_pair: ?[2]std.posix.fd_t = if (frame_fds != null) createFrameSocketPair() catch |err| pair: {
            log.warn("browser frame socket unavailable: {}; using shm frames", .{err});
            break :pair null;
        } else null;
        var frame_socket_to_close = frame_socket_pair;
        errdefer if (frame_socket_to_close) |pair| {
            _ = std.c.close(pair[0]);
            _ = std.c.close(pair[1]);
        };

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const helper_path_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_path}, 0);
        const helper_dir = std.fs.path.dirname(helper_path) orelse return error.BrowserUnavailable;
        const helper_dir_z = try std.fmt.allocPrintSentinel(arena, "{s}", .{helper_dir}, 0);
        const argv = try arena.allocSentinel(?[*:0]u8, 1, null);
        argv[0] = helper_path_z.ptr;
        const child_pid = std.c.fork();
        if (child_pid < 0) return error.Unexpected;
        if (child_pid == 0) {
            execHelperChild(helper_dir_z.ptr, helper_path_z.ptr, argv.ptr, stdin_pipe, stdout_pipe, frame_fds, if (frame_socket_pair) |pair| pair[1] else null);
        }
        if (frame_socket_pair) |pair| {
            _ = std.c.close(pair[1]);
            self.frame_socket = pair[0];
            frame_socket_to_close = null;
        }

        if (frame_fds) |fds| {
            for (fds) |fd| _ = std.c.close(fd);
            frame_fds_to_close = null;
        }
        _ = std.c.close(stdin_pipe[0]);
        _ = std.c.close(stdout_pipe[1]);
        const stdin_file: std.Io.File = .{ .handle = stdin_pipe[1], .flags = .{ .nonblocking = false } };
        const stdout_file: std.Io.File = .{ .handle = stdout_pipe[0], .flags = .{ .nonblocking = false } };

        self.child_pid = child_pid;
        self.child_process_group = child_pid;
        self.stdin_file = stdin_file;
        _ = std.c.setpgid(child_pid, child_pid);

        const context = try self.allocator.create(ReaderContext);
        context.* = .{
            .allocator = self.allocator,
            .queue = self.queue,
            .frame = self.frame,
            .stdout_file = stdout_file,
        };
        errdefer self.allocator.destroy(context);

        self.reader_thread = try std.Thread.spawn(.{}, helperReaderMain, .{context});
        // The helper waits (bounded) for HELLO while it creates the view.
        self.sendFrameHello();
    }

    // Serializes and sends one JSON-line command to the browser helper.
    fn sendCommand(self: *Controller, command: ipc.Command) !void {
        _ = self.child_pid orelse return error.BrowserUnavailable;
        const stdin_file = self.stdin_file orelse return error.BrowserUnavailable;
        var outbound = command;
        if (commandWakesFrame(command.kind)) {
            self.next_input_serial +%= 1;
            if (self.next_input_serial == 0) self.next_input_serial = 1;
            outbound.input_serial = self.next_input_serial;
            outbound.input_sent_at_ns = monotonicTimestampNsU64();
        }
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, outbound, .{});
        defer self.allocator.free(encoded);

        var write_buffer: [8 * 1024]u8 = undefined;
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        var writer = stdin_file.writer(threaded.io(), &write_buffer);
        try writer.interface.writeAll(encoded);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    fn flushFrameReleases(self: *Controller) !void {
        while (self.frame.popRelease()) |release| {
            self.sendCommand(.{
                .kind = .frame_release,
                .frame_sequence = release.sequence,
                .frame_slot = release.slot,
            }) catch |err| {
                self.frame.restoreRelease(release);
                return err;
            };
            self.frame.mutex.lock();
            self.frame.metrics.slot_releases += 1;
            self.frame.mutex.unlock();
        }
    }

    /// Announces the dma-buf formats the renderer can import. An empty list
    /// (no importer, or a backend without dma-buf import) selects shm.
    fn sendFrameHello(self: *Controller) void {
        const socket = self.frame_socket orelse return;
        const hello = self.allocator.create(fp.Hello) catch {
            self.closeFrameSocket();
            return;
        };
        defer self.allocator.destroy(hello);
        hello.* = .{};
        if (frameTransportForcedShm()) {
            log.info("browser frame transport forced to shm", .{});
        } else if (browser_texture.dmabufImporter()) |importer| {
            var formats: std.ArrayList(browser_texture.DmabufFormat) = .empty;
            defer formats.deinit(self.allocator);
            importer.formats(importer.context, self.allocator, &formats) catch |err| {
                log.warn("dma-buf import formats unavailable: {}; using shm frames", .{err});
                formats.clearRetainingCapacity();
            };
            for (formats.items) |format| {
                if (hello.count >= fp.max_formats) break;
                hello.formats[hello.count] = .{ .fourcc = format.fourcc, .modifier = format.modifier };
                hello.count += 1;
            }
        }
        fp.send(socket, std.mem.asBytes(hello)[0..hello.wireLen()], &.{}) catch |err| {
            log.warn("browser frame socket HELLO failed: {}; using shm frames", .{err});
            self.closeFrameSocket();
            return;
        };
        log.info("browser frame socket: offered {d} dma-buf format(s)", .{hello.count});
    }

    /// Drains the frame socket: keeps the newest FRAME pending, hands
    /// superseded ones straight back (their damage carries forward), and
    /// records the negotiated mode. Main thread only.
    fn pumpFrameSocket(self: *Controller) void {
        const socket = self.frame_socket orelse return;
        var buffer: [@sizeOf(fp.Frame) + 64]u8 align(8) = undefined;
        while (true) {
            const received = fp.recv(socket, &buffer) catch |err| {
                if (err != error.Closed) log.warn("browser frame socket receive failed: {}", .{err});
                // The helper falls back to shm on hangup; so do we.
                self.closeFrameSocket();
                return;
            } orelse return;
            var rx = received;
            if (fp.as(fp.Frame, &buffer, rx.len)) |frame_msg| {
                var msg = frame_msg.*;
                if (self.dmabuf_pending) |*older| {
                    self.releaseHelperFrame(older.msg.sequence, -1);
                    older.rx.closeFds();
                    mergeDamage(&msg, &older.msg);
                }
                self.dmabuf_pending = .{ .msg = msg, .rx = rx };
            } else if (fp.as(fp.ModeMsg, &buffer, rx.len)) |mode| {
                rx.closeFds();
                self.frame_mode = mode.mode;
                log.info("browser frame transport: {s}", .{if (mode.mode == .dmabuf) "dmabuf (zero-copy)" else "shm"});
            } else {
                rx.closeFds();
            }
        }
    }

    /// Binds a received dma-buf frame to `texture_id` (0 = allocate).
    /// Releases it right away when it is stale or cannot be imported.
    fn applyDmabuf(self: *Controller, pending_frame: PendingDmabuf, texture_id: c_uint) bool {
        var pending = pending_frame;
        defer pending.rx.closeFds();
        const msg = &pending.msg;
        const shown_sequence = if (self.dmabuf_shown) |shown| shown.sequence else 0;
        const latest = self.frame.latest();
        // A newer shm frame (per-frame fallback) already superseded this one.
        const superseded = msg.sequence <= shown_sequence or (!latest.dmabuf and msg.sequence < latest.sequence);
        const valid = msg.plane_count > 0 and msg.plane_count <= fp.max_planes and
            pending.rx.fd_count >= msg.plane_count and msg.width > 0 and msg.height > 0;
        const importer = browser_texture.dmabufImporter();
        if (superseded or !valid or importer == null) {
            self.releaseHelperFrame(msg.sequence, -1);
            return false;
        }

        var frame: browser_texture.DmabufFrame = .{
            .width = msg.width,
            .height = msg.height,
            .fourcc = msg.fourcc,
            .modifier = msg.modifier,
            .plane_count = @intCast(msg.plane_count),
        };
        for (0..msg.plane_count) |index| {
            frame.planes[index] = .{ .fd = pending.rx.fds[index], .offset = msg.planes[index].offset, .stride = msg.planes[index].stride };
        }
        // Explicit sync: the render-done fence follows the planes and moves to
        // the importer. Without it the import waits on implicit fences.
        if (msg.flags & fp.frame_flag_fence != 0 and pending.rx.fd_count > msg.plane_count) {
            frame.acquire_fence = pending.rx.fds[msg.plane_count];
            pending.rx.fds[msg.plane_count] = -1;
        }
        var rects: [fp.max_damage]browser_texture.DamageRect = undefined;
        frame.damage = textureDamage(msg, &rects);

        const result = importer.?.import(importer.?.context, texture_id, frame) catch |err| {
            if (!self.dmabuf_import_failed_logged) {
                self.dmabuf_import_failed_logged = true;
                log.warn("dma-buf import failed: {} (fourcc 0x{x} modifier 0x{x} planes {d})", .{ err, msg.fourcc, msg.modifier, msg.plane_count });
            }
            self.releaseHelperFrame(msg.sequence, -1);
            return false;
        };
        if (self.dmabuf_shown == null and frameLogEnabled()) {
            log.info("dma-buf frame {d}x{d} fourcc 0x{x} modifier 0x{x} planes {d}", .{ msg.width, msg.height, msg.fourcc, msg.modifier, msg.plane_count });
        }
        self.retireShownDmabuf(result.key, msg.width, msg.height);
        if (std.mem.indexOfScalar(u64, self.dmabuf_keys[0..self.dmabuf_key_count], result.key) == null) {
            if (self.dmabuf_key_count == self.dmabuf_keys.len) {
                // More distinct buffers than expected: drop the oldest import.
                importer.?.forget(importer.?.context, self.dmabuf_keys[0]);
                std.mem.copyForwards(u64, self.dmabuf_keys[0 .. self.dmabuf_keys.len - 1], self.dmabuf_keys[1..]);
                self.dmabuf_key_count -= 1;
            }
            self.dmabuf_keys[self.dmabuf_key_count] = result.key;
            self.dmabuf_key_count += 1;
        }
        self.dmabuf_shown = .{
            .sequence = msg.sequence,
            .key = result.key,
            .texture_id = result.texture_id,
            .width = msg.width,
            .height = msg.height,
        };
        self.frame.noteDmabufShown(msg.sequence, msg.exported_at_ns, true);
        return true;
    }

    /// Hands the shown dma-buf frame back once the texture shows another
    /// buffer (`new_key`, 0 = shm pixels). The release fence lets WebKit reuse
    /// the buffer as soon as the GPU stopped sampling it. A size change means
    /// WebKit reallocated, so every other cached import is dropped.
    fn retireShownDmabuf(self: *Controller, new_key: u64, width: u32, height: u32) void {
        const shown = self.dmabuf_shown orelse return;
        const importer = browser_texture.dmabufImporter();
        const fence: c_int = if (importer != null and shown.key != new_key) importer.?.release_fence(importer.?.context, shown.key) else -1;
        self.releaseHelperFrame(shown.sequence, fence);
        if (width != shown.width or height != shown.height or new_key == 0) {
            if (importer) |active| {
                for (self.dmabuf_keys[0..self.dmabuf_key_count]) |key| {
                    if (key != new_key) active.forget(active.context, key);
                }
            }
            self.dmabuf_key_count = 0;
        }
        self.dmabuf_shown = null;
    }

    /// RELEASE(sequence) with an optional sync_file, which this closes.
    fn releaseHelperFrame(self: *Controller, sequence: u64, fence: c_int) void {
        defer if (fence >= 0) {
            _ = std.c.close(fence);
        };
        const socket = self.frame_socket orelse return;
        const msg: fp.Release = .{ .sequence = sequence, .flags = if (fence >= 0) fp.release_flag_fence else 0 };
        const fds: []const c_int = if (fence >= 0) &.{fence} else &.{};
        fp.send(socket, std.mem.asBytes(&msg), fds) catch |err| {
            log.warn("browser frame release failed: {}", .{err});
        };
        self.frame.mutex.lock();
        self.frame.metrics.slot_releases += 1;
        self.frame.mutex.unlock();
    }

    /// Drops every dma-buf import and closes the frame socket.
    fn closeFrameSocket(self: *Controller) void {
        if (self.dmabuf_pending) |*pending| {
            self.releaseHelperFrame(pending.msg.sequence, -1);
            pending.rx.closeFds();
            self.dmabuf_pending = null;
        }
        if (browser_texture.dmabufImporter()) |importer| {
            for (self.dmabuf_keys[0..self.dmabuf_key_count]) |key| importer.forget(importer.context, key);
        }
        self.dmabuf_key_count = 0;
        self.dmabuf_shown = null;
        if (self.frame_socket) |socket| _ = std.c.close(socket);
        self.frame_socket = null;
        self.frame_mode = .shm;
    }

    // Closes the helper stdin pipe so the helper reader thread can observe EOF and exit cleanly.
    fn closeChildStdin(self: *Controller) void {
        const stdin_file = self.stdin_file orelse return;
        var threaded = std.Io.Threaded.init_single_threaded;
        stdin_file.close(threaded.io());
        self.stdin_file = null;
    }

    // Tracks the last requested URL so reopening the pane preserves browser location.
    fn setCurrentUrl(self: *Controller, url: []const u8) !void {
        if (self.current_url) |current| self.allocator.free(current);
        self.current_url = try self.allocator.dupe(u8, url);
    }

    fn terminateChild(self: *Controller) void {
        const child_pid = self.child_pid orelse return;
        const child_process_group = self.child_process_group orelse child_pid;
        var child_reaped = waitForChildExit(child_pid, 250);
        std.posix.kill(-child_process_group, std.posix.SIG.TERM) catch {};
        if (child_reaped) {
            // Give WebKit's network/web processes a moment to exit on TERM,
            // but return as soon as the group is empty rather than always
            // stalling the UI thread for the full grace period.
            waitForProcessGroupExit(child_process_group, 250);
        } else {
            child_reaped = waitForChildExit(child_pid, 250);
        }
        std.posix.kill(-child_process_group, std.posix.SIG.KILL) catch {};
        if (!child_reaped) _ = waitForChildExit(child_pid, 250);
        self.child_pid = null;
        self.child_process_group = null;
    }
};

fn visibleHelperEnabled() bool {
    if (waylandDiagnosticHelperEnabled()) return true;
    const override_value = if (std.c.getenv("VERDE_BROWSER_LINUX_SHOW_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const unsafe_wayland = if (std.c.getenv("VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER")) |value_ptr| std.mem.span(value_ptr) else null;
    const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |value_ptr| std.mem.span(value_ptr) else null;
    const gdk_backend = if (std.c.getenv("GDK_BACKEND")) |value_ptr| std.mem.span(value_ptr) else null;
    return visibleHelperEnabledFromValues(override_value, unsafe_wayland, session_type, gdk_backend);
}

fn createProtocolPipe() ![2]std.posix.fd_t {
    // Provider processes can launch concurrently with the browser helper. Set
    // CLOEXEC atomically so an unrelated exec cannot retain the write end and
    // prevent the reader thread from ever observing EOF during browser teardown.
    var pipe_fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe2(&pipe_fds, .{ .CLOEXEC = true }) != 0) return error.Unexpected;
    return pipe_fds;
}

test "browser helper protocol pipes close across unrelated execs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pipe_fds = try createProtocolPipe();
    defer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
    }

    for (pipe_fds) |fd| {
        const flags = std.c.fcntl(fd, std.c.F.GETFD);
        try std.testing.expect(flags >= 0);
        try std.testing.expect(flags & std.c.FD_CLOEXEC != 0);
    }
}

fn createFrameSocketPair() ![2]std.posix.fd_t {
    var pair: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET | std.os.linux.SOCK.CLOEXEC, 0, &pair);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.SystemResources;
    return pair;
}

fn commandWakesFrame(kind: ipc.CommandKind) bool {
    return switch (kind) {
        .show,
        .set_bounds,
        .resize_pane,
        .navigate,
        .eval,
        .post_json,
        .go_back,
        .go_forward,
        .reload,
        .focus,
        .mouse_move,
        .mouse_button,
        .mouse_wheel,
        .key_input,
        .text_input,
        .context_menu_activate,
        .import_cookies,
        .resume_painting,
        => true,
        .hide, .set_host_window, .blur, .context_menu_dismiss, .frame_release, .quit => false,
    };
}

fn waylandDiagnosticHelperEnabled() bool {
    const override_value = if (std.c.getenv("VERDE_BROWSER_LINUX_WAYLAND_HELPER")) |value_ptr|
        std.mem.span(value_ptr)
    else if (std.c.getenv("VERDE_BROWSER_LINUX_NATIVE_WAYLAND_SURFACE")) |value_ptr|
        std.mem.span(value_ptr)
    else
        null;
    const session_type = if (std.c.getenv("XDG_SESSION_TYPE")) |value_ptr| std.mem.span(value_ptr) else null;
    const wayland_display = if (std.c.getenv("WAYLAND_DISPLAY")) |value_ptr| std.mem.span(value_ptr) else null;
    const gdk_backend = if (std.c.getenv("GDK_BACKEND")) |value_ptr| std.mem.span(value_ptr) else null;
    return waylandDiagnosticHelperEnabledFromValues(override_value, session_type, wayland_display, gdk_backend);
}

fn waylandDiagnosticHelperEnabledFromValues(override_value: ?[]const u8, session_type: ?[]const u8, wayland_display: ?[]const u8, gdk_backend: ?[]const u8) bool {
    if (override_value) |value| {
        if (std.mem.eql(u8, value, "0")) return false;
        if (!std.mem.eql(u8, value, "1")) return false;
    } else {
        return false;
    }
    if (session_type) |value| {
        if (std.mem.eql(u8, value, "wayland")) return true;
        if (std.mem.eql(u8, value, "x11")) return false;
    }
    if (wayland_display) |value| {
        if (value.len > 0) return true;
    }
    if (gdk_backend) |value| {
        return std.mem.indexOf(u8, value, "wayland") != null;
    }
    return false;
}

fn visibleHelperEnabledFromValues(override_value: ?[]const u8, unsafe_wayland: ?[]const u8, session_type: ?[]const u8, gdk_backend: ?[]const u8) bool {
    _ = unsafe_wayland;

    if (override_value) |value| {
        if (std.mem.eql(u8, value, "1")) return true;
        if (std.mem.eql(u8, value, "0")) return false;
    }
    if (session_type) |value| {
        if (std.mem.eql(u8, value, "x11")) return true;
        if (std.mem.eql(u8, value, "wayland")) return true;
    }
    if (gdk_backend) |value| {
        return std.mem.indexOf(u8, value, "wayland") != null or std.mem.indexOf(u8, value, "x11") != null;
    }
    return false;
}

test "visible helper selection honors overrides and session defaults" {
    try std.testing.expect(visibleHelperEnabledFromValues("1", null, "wayland", null));
    try std.testing.expect(visibleHelperEnabledFromValues("1", "1", "wayland", null));
    try std.testing.expect(!visibleHelperEnabledFromValues("0", null, "x11", null));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, "x11", null));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, "wayland", "x11"));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, null, "x11"));
    try std.testing.expect(visibleHelperEnabledFromValues(null, null, null, "x11,wayland"));
}

test "Wayland diagnostic helper selection requires explicit Wayland opt-in" {
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", "wayland", null, null));
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", null, "wayland-1", null));
    try std.testing.expect(waylandDiagnosticHelperEnabledFromValues("1", null, null, "wayland"));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues(null, "wayland", "wayland-1", null));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues("0", "wayland", "wayland-1", null));
    try std.testing.expect(!waylandDiagnosticHelperEnabledFromValues("1", "x11", "wayland-1", "wayland"));
}

/// Resolves the installed Linux browser helper path beside the running desktop executable.
fn browserHelperPath(allocator: std.mem.Allocator) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const exe_dir = try std.process.executableDirPathAlloc(threaded.io(), allocator);
    defer allocator.free(exe_dir);
    return try std.fs.path.join(allocator, &.{ exe_dir, "verde-browser-linux" });
}

/// Reads JSON-line events from the helper stdout pipe and stores them in thread-safe queues.
fn helperReaderMain(context: *ReaderContext) !void {
    defer context.allocator.destroy(context);
    defer _ = std.c.close(context.stdout_file.handle);

    var read_buffer: [IPC_LINE_BUFFER_BYTES]u8 = undefined;
    var threaded = std.Io.Threaded.init_single_threaded;
    var reader = context.stdout_file.reader(threaded.io(), &read_buffer);

    while (true) {
        const maybe_line = try reader.interface.takeDelimiter('\n');
        if (maybe_line == null) return;

        const line = std.mem.trimEnd(u8, maybe_line.?, "\r");
        if (line.len == 0) continue;

        var parsed = try std.json.parseFromSlice(ipc.Event, context.allocator, line, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        if (parsed.value.kind == .frame_ready) {
            _ = try context.frame.update(context.allocator, parsed.value);
            // Only the pane texture changes; pollBrowser reports anything else.
            const wake_result = loop_wakeup.notifyTextureFrameResult();
            context.frame.noteWake(wake_result);
            continue;
        }

        if (parsed.value.kind == .paint_ack) {
            context.frame.notePaintAck(parsed.value.payload orelse "");
            continue;
        }

        const event = try convertHelperEvent(context.allocator, parsed.value);
        try context.queue.push(context.allocator, event);
        loop_wakeup.notify();
    }
}

/// Converts the helper JSON event into the desktop browser event union.
fn convertHelperEvent(allocator: std.mem.Allocator, event: ipc.Event) !browser_types.Event {
    return switch (event.kind) {
        .opened => .opened,
        .closed => .closed,
        .navigated => .{ .navigated = try allocator.dupe(u8, event.payload orelse "about:blank") },
        .title_changed => .{ .title_changed = try allocator.dupe(u8, event.payload orelse "") },
        .document_loaded => .document_loaded,
        .js_message => .{ .js_message = try allocator.dupe(u8, event.payload orelse "{}") },
        .eval_result => .{ .eval_result = try allocator.dupe(u8, event.payload orelse "null") },
        .context_menu => .{ .context_menu = try allocator.dupe(u8, event.payload orelse "{}") },
        .context_menu_dismissed => .context_menu_dismissed,
        .cursor_changed => .{ .cursor_changed = browser_types.CursorShape.parse(event.payload orelse "default") },
        .cookies_imported => .{ .cookies_imported = std.fmt.parseUnsigned(u32, event.payload orelse "0", 10) catch 0 },
        .failed => .{ .failed = try allocator.dupe(u8, event.payload orelse "Linux browser helper failed.") },
        .frame_ready, .paint_ack => unreachable,
    };
}

const PaintAck = struct { token: u64, sequence: u64 };

fn parsePaintAck(payload: []const u8) ?PaintAck {
    const colon = std.mem.indexOfScalar(u8, payload, ':') orelse return null;
    return .{
        .token = std.fmt.parseUnsigned(u64, payload[0..colon], 10) catch return null,
        .sequence = std.fmt.parseUnsigned(u64, payload[colon + 1 ..], 10) catch return null,
    };
}

test "paint ack requires the acked token and the frame current at the ack" {
    try std.testing.expectEqual(PaintAck{ .token = 7, .sequence = 42 }, parsePaintAck("7:42").?);
    try std.testing.expect(parsePaintAck("7") == null);
    try std.testing.expect(parsePaintAck("x:1") == null);

    var frame: SharedFrame = .{};
    frame.sequence = 41;
    try std.testing.expect(!frame.paintAckSatisfied(7));
    frame.notePaintAck("7:42");
    // Ack written before its frame's event: not yet current.
    try std.testing.expect(!frame.paintAckSatisfied(7));
    frame.sequence = 42;
    try std.testing.expect(frame.paintAckSatisfied(7));
    // A stale ack for an earlier request never satisfies a newer one.
    try std.testing.expect(!frame.paintAckSatisfied(8));
}

/// `VERDE_BROWSER_LINUX_FRAME_TRANSPORT=shm` keeps frames on the shm slots
/// (the helper honours it too; offering no formats makes it explicit).
fn frameTransportForcedShm() bool {
    const value = std.c.getenv("VERDE_BROWSER_LINUX_FRAME_TRANSPORT") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), "shm");
}

/// `newer` replaces `older` without `older` ever being shown, so the damage
/// against the frame on screen is the union of both (0 rects = whole frame;
/// overflow folds into the last rect's bounding box).
fn mergeDamage(newer: *fp.Frame, older: *const fp.Frame) void {
    if (newer.damage_count == 0) return;
    if (older.damage_count == 0 or older.width != newer.width or older.height != newer.height) {
        newer.damage_count = 0;
        return;
    }
    for (older.damage[0..@min(older.damage_count, fp.max_damage)]) |rect| {
        if (newer.damage_count < fp.max_damage) {
            newer.damage[newer.damage_count] = rect;
            newer.damage_count += 1;
        } else {
            const last = &newer.damage[fp.max_damage - 1];
            const x0 = @min(last.x, rect.x);
            const y0 = @min(last.y, rect.y);
            const x1 = @max(last.x +| last.w, rect.x +| rect.w);
            const y1 = @max(last.y +| last.h, rect.y +| rect.h);
            last.* = .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
        }
    }
}

/// Producer damage clamped to the buffer; empty = the whole frame.
fn textureDamage(msg: *const fp.Frame, out: *[fp.max_damage]browser_texture.DamageRect) []const browser_texture.DamageRect {
    const width: i32 = @intCast(@min(msg.width, std.math.maxInt(i32)));
    const height: i32 = @intCast(@min(msg.height, std.math.maxInt(i32)));
    var count: usize = 0;
    for (msg.damage[0..@min(msg.damage_count, fp.max_damage)]) |rect| {
        const x0 = std.math.clamp(rect.x, 0, width);
        const y0 = std.math.clamp(rect.y, 0, height);
        const x1 = std.math.clamp(rect.x +| rect.w, 0, width);
        const y1 = std.math.clamp(rect.y +| rect.h, 0, height);
        if (x1 <= x0 or y1 <= y0) continue;
        out[count] = .{ .x = @intCast(x0), .y = @intCast(y0), .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
        count += 1;
    }
    return out[0..count];
}

test "superseded dma-buf frames merge their damage into the next frame" {
    var older: fp.Frame = .{ .width = 100, .height = 50, .damage_count = 1 };
    older.damage[0] = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    var newer: fp.Frame = .{ .width = 100, .height = 50, .damage_count = 1 };
    newer.damage[0] = .{ .x = 10, .y = 10, .w = 5, .h = 5 };
    mergeDamage(&newer, &older);
    try std.testing.expectEqual(@as(u32, 2), newer.damage_count);
    try std.testing.expectEqual(@as(i32, 1), newer.damage[1].x);

    // A whole-frame older frame makes the merge whole.
    older.damage_count = 0;
    mergeDamage(&newer, &older);
    try std.testing.expectEqual(@as(u32, 0), newer.damage_count);

    var rects: [fp.max_damage]browser_texture.DamageRect = undefined;
    var clipped: fp.Frame = .{ .width = 20, .height = 20, .damage_count = 2 };
    clipped.damage[0] = .{ .x = -5, .y = 15, .w = 10, .h = 10 };
    clipped.damage[1] = .{ .x = 30, .y = 0, .w = 4, .h = 4 };
    const damage = textureDamage(&clipped, &rects);
    try std.testing.expectEqual(@as(usize, 1), damage.len);
    try std.testing.expectEqual(browser_texture.DamageRect{ .x = 0, .y = 15, .w = 5, .h = 5 }, damage[0]);
}

test "dma-buf frame_ready events are accepted without a shm slot" {
    var frame: SharedFrame = .{};
    defer frame.deinit(std.testing.allocator);
    const accepted = try frame.update(std.testing.allocator, .{
        .kind = .frame_ready,
        .frame_sequence = 3,
        .frame_slot = fp.dmabuf_frame_slot,
        .width = 64,
        .height = 32,
        .byte_len = 0,
    });
    try std.testing.expect(accepted);
    try std.testing.expect(frame.latest().dmabuf);
    try std.testing.expectEqual(@as(usize, 0), frame.release_count);
    frame.noteDmabufShown(3, 0, true);
    try std.testing.expect(!frame.dirty);
}

fn execHelperChild(
    helper_dir_z: [*:0]const u8,
    helper_path_z: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    stdin_pipe: [2]std.posix.fd_t,
    stdout_pipe: [2]std.posix.fd_t,
    frame_fds: ?[FRAME_SLOT_COUNT]std.posix.fd_t,
    frame_socket: ?std.posix.fd_t,
) noreturn {
    _ = std.c.setpgid(0, 0);
    if (std.c.dup2(stdin_pipe[0], std.c.STDIN_FILENO) < 0) std.c._exit(126);
    if (std.c.dup2(stdout_pipe[1], std.c.STDOUT_FILENO) < 0) std.c._exit(126);
    // Move every inherited fd above the target range first so no dup2 can
    // clobber a source that already sits at 240..243.
    const temporary_floor: c_int = FRAME_SOCKET_FD + 1;
    if (frame_fds) |fds| {
        var temporary_fds: [FRAME_SLOT_COUNT]std.posix.fd_t = undefined;
        inline for (fds, 0..) |frame_fd, index| {
            const temporary_fd = std.c.fcntl(frame_fd, std.c.F.DUPFD, temporary_floor);
            if (temporary_fd < 0) std.c._exit(126);
            temporary_fds[index] = temporary_fd;
        }
        const temporary_socket: ?std.posix.fd_t = if (frame_socket) |socket| socket: {
            const temporary_fd = std.c.fcntl(socket, std.c.F.DUPFD, temporary_floor);
            if (temporary_fd < 0) std.c._exit(126);
            break :socket temporary_fd;
        } else null;
        inline for (temporary_fds, 0..) |temporary_fd, index| {
            if (std.c.dup2(temporary_fd, FRAME_FD_BASE + @as(std.posix.fd_t, @intCast(index))) < 0) std.c._exit(126);
        }
        if (temporary_socket) |temporary_fd| {
            if (std.c.dup2(temporary_fd, FRAME_SOCKET_FD) < 0) std.c._exit(126);
        }
    }

    _ = std.c.close(stdin_pipe[0]);
    _ = std.c.close(stdin_pipe[1]);
    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stdout_pipe[1]);
    closeInheritedFileDescriptors();

    var empty_signal_mask = std.posix.sigemptyset();
    std.posix.sigprocmask(std.c.SIG.SETMASK, &empty_signal_mask, null);
    restoreDefaultSignal(std.posix.SIG.PIPE);
    if (std.c.chdir(helper_dir_z) != 0) std.c._exit(126);

    // The snapshot helper renders into a texture owned by Palette, whose pane
    // dimensions are already framebuffer pixels. Inheriting a global GDK_SCALE
    // would make WebKit produce an oversized DPR surface that Palette then
    // downsamples, causing visibly soft text on scale-1 outputs.
    _ = setenv("GDK_SCALE", "1", 1);
    _ = unsetenv("GDK_DPI_SCALE");
    if (frame_fds != null) {
        _ = setenv("VERDE_BROWSER_LINUX_FRAME0_FD", "240", 1);
        _ = setenv("VERDE_BROWSER_LINUX_FRAME1_FD", "241", 1);
        _ = setenv("VERDE_BROWSER_LINUX_FRAME2_FD", "242", 1);
        if (frame_socket != null) _ = setenv(fp.socket_env, std.fmt.comptimePrint("{d}", .{FRAME_SOCKET_FD}), 1);
    }
    if (frame_fds == null or frame_socket == null) _ = unsetenv(fp.socket_env);

    _ = std.c.execve(helper_path_z, argv, std.c.environ);
    std.c._exit(127);
}

fn closeInheritedFileDescriptors() void {
    const limits = std.posix.getrlimit(.NOFILE) catch return;
    const max_fd: usize = @intCast(@min(limits.cur, 4096));
    var fd: usize = 3;
    while (fd < max_fd) : (fd += 1) {
        if (fd >= FRAME_FD_BASE and fd <= FRAME_SOCKET_FD) continue;
        _ = std.c.close(@intCast(fd));
    }
}

// Creates shared frame slots so the WebKit helper can publish pixels without rewriting files.
fn createFrameSlots(frame: *SharedFrame, allocator: std.mem.Allocator) ![FRAME_SLOT_COUNT]std.posix.fd_t {
    var frame_fds: [FRAME_SLOT_COUNT]std.posix.fd_t = undefined;
    errdefer frame.deinit(allocator);

    inline for (0..FRAME_SLOT_COUNT) |index| {
        const frame_name = try std.fmt.allocPrint(allocator, "verde-browser-linux-frame-{d}", .{index});
        defer allocator.free(frame_name);

        frame_fds[index] = try std.posix.memfd_create(frame_name, std.posix.MFD.CLOEXEC);
        errdefer _ = std.c.close(frame_fds[index]);

        if (std.c.ftruncate(frame_fds[index], FRAME_BYTES_MAX) != 0) return error.Unexpected;
        frame.slots[index] = try std.posix.mmap(
            null,
            FRAME_BYTES_MAX,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            frame_fds[index],
            0,
        );
        // A fresh memfd reads as zeros; touching it would commit every page
        // of the 4K-sized slot up front.
        frame.slot_ready[index] = true;
    }
    return frame_fds;
}

fn waitForChildExit(child_pid: std.posix.pid_t, timeout_ms: u16) bool {
    var waited_ms: u16 = 0;
    while (waited_ms <= timeout_ms) {
        var status: c_int = 0;
        const result = std.c.waitpid(child_pid, &status, std.c.W.NOHANG);
        if (result == child_pid) return true;
        sleepMillis(5);
        waited_ms +|= 5;
    }
    return false;
}

fn waitForProcessGroupExit(process_group: std.posix.pid_t, timeout_ms: u16) void {
    var waited_ms: u16 = 0;
    while (waited_ms <= timeout_ms) : (waited_ms += 5) {
        // kill(-pgid, 0) fails with ESRCH once no member remains.
        if (std.c.kill(-process_group, @enumFromInt(0)) != 0) return;
        sleepMillis(5);
    }
}

fn sleepMillis(ms: u64) void {
    const request: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&request, null);
}

fn restoreDefaultSignal(signal_number: std.posix.SIG) void {
    const action: std.posix.Sigaction = if (@hasField(std.posix.Sigaction, "restorer"))
        .{
            .flags = 0,
            .handler = .{ .handler = null },
            .mask = std.posix.sigemptyset(),
            .restorer = null,
        }
    else
        .{
            .flags = 0,
            .handler = .{ .handler = null },
            .mask = std.posix.sigemptyset(),
        };
    std.posix.sigaction(signal_number, &action, null);
}

// Maps the shared browser mouse button enum to the helper protocol integer.
fn encodeMouseButton(button: browser_input.MouseButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 3,
        .back => 4,
        .forward => 5,
    };
}
