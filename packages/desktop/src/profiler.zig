const std = @import("std");

const FRAME_CAPACITY = 240;
pub const SLOW_FRAME_NS: u64 = 33 * std.time.ns_per_ms;
pub const HITCH_FRAME_NS: u64 = 100 * std.time.ns_per_ms;

pub const Section = enum {
    event_handling,
    poll_picker,
    poll_models,
    poll_send,
    poll_browser,
    poll_terminals,
    render_setup,
    render_root,
    flush_dirty,
    draw_backend,
    swap_window,
};

pub const section_count = @typeInfo(Section).@"enum".fields.len;

pub const FrameSample = struct {
    sequence: u64 = 0,
    timestamp_ms: i64 = 0,
    active_ns: u64 = 0,
    waited_ns: u64 = 0,
    rendered: bool = false,
    sections: [section_count]u64 = [_]u64{0} ** section_count,

    pub fn add(self: *FrameSample, section: Section, ns: u64) void {
        self.sections[@intFromEnum(section)] +|= ns;
        self.active_ns +|= ns;
    }

    pub fn sectionNs(self: *const FrameSample, section: Section) u64 {
        return self.sections[@intFromEnum(section)];
    }
};

pub const Snapshot = struct {
    count: usize,
    latest: FrameSample,
    avg_active_ns: u64,
    max_active_ns: u64,
    slow_count: usize,
    hitch_count: usize,
};

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

var mutex: Mutex = .{};
var samples: [FRAME_CAPACITY]FrameSample = [_]FrameSample{.{}} ** FRAME_CAPACITY;
var total: usize = 0;
var sequence: u64 = 0;

pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

pub fn elapsedNs(start: i128) u64 {
    const end = nowNs();
    if (end <= start) return 0;
    return @intCast(end - start);
}

pub fn recordFrame(sample: FrameSample) void {
    mutex.lock();
    defer mutex.unlock();

    var stored = sample;
    stored.sequence = sequence;
    sequence +%= 1;
    stored.timestamp_ms = unixTimestampMs();

    const slot = total % FRAME_CAPACITY;
    samples[slot] = stored;
    total +%= 1;
}

fn unixTimestampMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

pub fn frameCount() usize {
    mutex.lock();
    defer mutex.unlock();
    return @min(total, FRAME_CAPACITY);
}

pub fn frameAt(oldest_index: usize) ?FrameSample {
    mutex.lock();
    defer mutex.unlock();

    const count = @min(total, FRAME_CAPACITY);
    if (oldest_index >= count) return null;

    const first = if (total < FRAME_CAPACITY) 0 else total % FRAME_CAPACITY;
    const slot = (first + oldest_index) % FRAME_CAPACITY;
    return samples[slot];
}

pub fn snapshot() Snapshot {
    mutex.lock();
    defer mutex.unlock();

    const count = @min(total, FRAME_CAPACITY);
    if (count == 0) {
        return .{
            .count = 0,
            .latest = .{},
            .avg_active_ns = 0,
            .max_active_ns = 0,
            .slow_count = 0,
            .hitch_count = 0,
        };
    }

    const first = if (total < FRAME_CAPACITY) 0 else total % FRAME_CAPACITY;
    var active_sum: u128 = 0;
    var max_active: u64 = 0;
    var slow_count: usize = 0;
    var hitch_count: usize = 0;
    var latest = FrameSample{};

    for (0..count) |index| {
        const sample = samples[(first + index) % FRAME_CAPACITY];
        latest = sample;
        active_sum += sample.active_ns;
        max_active = @max(max_active, sample.active_ns);
        if (sample.active_ns >= SLOW_FRAME_NS) slow_count += 1;
        if (sample.active_ns >= HITCH_FRAME_NS) hitch_count += 1;
    }

    return .{
        .count = count,
        .latest = latest,
        .avg_active_ns = @intCast(active_sum / count),
        .max_active_ns = max_active,
        .slow_count = slow_count,
        .hitch_count = hitch_count,
    };
}

pub fn sectionName(section: Section) []const u8 {
    return switch (section) {
        .event_handling => "event handling",
        .poll_picker => "poll picker",
        .poll_models => "poll models",
        .poll_send => "poll send",
        .poll_browser => "poll browser",
        .poll_terminals => "poll terminals",
        .render_setup => "render setup",
        .render_root => "render root",
        .flush_dirty => "flush dirty",
        .draw_backend => "draw backend",
        .swap_window => "swap window",
    };
}

pub fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}
