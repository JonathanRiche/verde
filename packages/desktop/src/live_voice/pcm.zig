//! PCM16 mono helpers for Live voice: a streaming resampler for audio
//! backends that cannot convert rates themselves, a lock-free
//! single-producer/single-consumer sample ring shared with real-time audio
//! callbacks, and a loudness meter for the UI. Nothing here allocates after
//! init, blocks, or logs, so it is safe on an audio thread.

const std = @import("std");

/// Bytes of PCM16 mono for `ms` milliseconds at `rate`.
pub fn chunkBytes(rate: u32, ms: u32) usize {
    return @as(usize, rate / 1000 * ms) * 2;
}

/// 0..1 loudness (RMS, scaled so speech sits mid-range).
pub fn level(samples: []const i16) f32 {
    if (samples.len == 0) return 0.0;
    var sum: f64 = 0.0;
    for (samples) |sample| {
        const value: f64 = @floatFromInt(sample);
        sum += value * value;
    }
    const rms = @sqrt(sum / @as(f64, @floatFromInt(samples.len))) / 32768.0;
    return @floatCast(std.math.clamp(rms * 4.0, 0.0, 1.0));
}

/// Copies little-endian PCM16 bytes into `out`; returns samples written.
/// Network buffers carry no alignment guarantee, so this never casts.
pub fn decodeSamples(bytes: []const u8, out: []i16) usize {
    const n = @min(bytes.len / 2, out.len);
    for (out[0..n], 0..) |*sample, index| sample.* = std.mem.readInt(i16, bytes[index * 2 ..][0..2], .little);
    return n;
}

pub fn bytesOf(samples: []const i16) []const u8 {
    return std.mem.sliceAsBytes(samples);
}

/// Streaming linear resampler with a 2-pole low-pass ahead of downsampling.
/// The fractional phase, filter state, and last sample carry across
/// `process` calls, so chunk boundaries are seamless.
pub const Resampler = struct {
    from: u32,
    to: u32,
    /// Input samples advanced per output sample.
    step: f64,
    /// Next output's offset inside the segment from `previous` to the next input.
    position: f64 = 0.0,
    previous: f32 = 0.0,
    filter: ?Biquad,

    pub fn init(from: u32, to: u32) Resampler {
        std.debug.assert(from > 0 and to > 0);
        const step = @as(f64, @floatFromInt(from)) / @as(f64, @floatFromInt(to));
        return .{
            .from = from,
            .to = to,
            .step = step,
            .filter = if (to < from) Biquad.lowPass(0.45 / step) else null,
        };
    }

    pub fn identity(self: *const Resampler) bool {
        return self.from == self.to;
    }

    /// Upper bound of output samples for `input_len` input samples.
    pub fn maxOutput(self: *const Resampler, input_len: usize) usize {
        return @as(usize, @intFromFloat(@ceil(@as(f64, @floatFromInt(input_len)) / self.step))) + 2;
    }

    /// Resamples `input` into `out` (at least `maxOutput(input.len)` long);
    /// returns the number of samples written.
    pub fn process(self: *Resampler, input: []const i16, out: []i16) usize {
        if (self.identity()) {
            const n = @min(input.len, out.len);
            @memcpy(out[0..n], input[0..n]);
            return n;
        }
        var written: usize = 0;
        for (input) |sample| {
            var current: f32 = @floatFromInt(sample);
            if (self.filter) |*f| current = f.run(current);
            while (self.position < 1.0) : (self.position += self.step) {
                if (written == out.len) break;
                const fraction: f32 = @floatCast(self.position);
                out[written] = clampSample(self.previous + (current - self.previous) * fraction);
                written += 1;
            }
            self.position -= 1.0;
            self.previous = current;
        }
        return written;
    }
};

/// RBJ low-pass biquad, Q = 1/sqrt(2).
const Biquad = struct {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32 = 0,
    x2: f32 = 0,
    y1: f32 = 0,
    y2: f32 = 0,

    /// `cutoff` is a fraction of the input rate (0..0.5).
    fn lowPass(cutoff: f64) Biquad {
        const w0 = 2.0 * std.math.pi * std.math.clamp(cutoff, 0.01, 0.49);
        const alpha = @sin(w0) / (2.0 * std.math.sqrt1_2);
        const cos_w0 = @cos(w0);
        const a0 = 1.0 + alpha;
        return .{
            .b0 = @floatCast((1.0 - cos_w0) / 2.0 / a0),
            .b1 = @floatCast((1.0 - cos_w0) / a0),
            .b2 = @floatCast((1.0 - cos_w0) / 2.0 / a0),
            .a1 = @floatCast(-2.0 * cos_w0 / a0),
            .a2 = @floatCast((1.0 - alpha) / a0),
        };
    }

    fn run(self: *Biquad, x: f32) f32 {
        const y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        return y;
    }
};

fn clampSample(value: f32) i16 {
    return @intFromFloat(std.math.clamp(@round(value), -32768.0, 32767.0));
}

/// Lock-free single-producer/single-consumer ring of samples. Capacity is a
/// power of two. A producer-side `requestFlush` drops everything queued at the
/// consumer's next `read` (barge-in), without the producer touching the read
/// index.
pub const Ring = struct {
    buffer: []i16,
    mask: usize,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),
    flush_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, min_capacity: usize) !Ring {
        const capacity = std.math.ceilPowerOfTwo(usize, @max(min_capacity, 2)) catch return error.OutOfMemory;
        const buffer = try allocator.alloc(i16, capacity);
        return .{ .buffer = buffer, .mask = capacity - 1 };
    }

    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }

    /// Samples waiting to be read.
    pub fn available(self: *const Ring) usize {
        return self.head.load(.acquire) -% self.tail.load(.acquire);
    }

    /// Producer: queues as many samples as fit; returns how many.
    pub fn write(self: *Ring, samples: []const i16) usize {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        const free = self.buffer.len - (head -% tail);
        const n = @min(free, samples.len);
        for (samples[0..n], 0..) |sample, offset| self.buffer[(head +% offset) & self.mask] = sample;
        self.head.store(head +% n, .release);
        return n;
    }

    /// Consumer: reads up to `out.len` samples; returns how many.
    pub fn read(self: *Ring, out: []i16) usize {
        const head = self.head.load(.acquire);
        var tail = self.tail.load(.monotonic);
        if (self.flush_requested.swap(false, .acq_rel)) {
            tail = head;
            self.tail.store(tail, .release);
            return 0;
        }
        const n = @min(head -% tail, out.len);
        for (out[0..n], 0..) |*slot, offset| slot.* = self.buffer[(tail +% offset) & self.mask];
        self.tail.store(tail +% n, .release);
        return n;
    }

    /// Producer (or anyone): the consumer drops all queued samples on its next read.
    pub fn requestFlush(self: *Ring) void {
        self.flush_requested.store(true, .release);
    }
};

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

test "level is zero for silence and grows with loudness" {
    try testing.expectEqual(@as(f32, 0.0), level(&.{ 0, 0, 0 }));
    const quiet = level(&.{ 800, -800, 800, -800 });
    const loud = level(&.{ 8000, -8000, 8000, -8000 });
    try testing.expect(quiet > 0.0 and loud > quiet and loud <= 1.0);
    try testing.expectEqual(@as(usize, 960), chunkBytes(24_000, 20));
}

test "resampler keeps length ratios across chunk boundaries" {
    var resampler = Resampler.init(48_000, 24_000);
    var input: [480]i16 = undefined;
    for (&input, 0..) |*sample, index| sample.* = @intCast(@as(i32, @intCast(index % 100)) * 100);
    var out: [1024]i16 = undefined;
    var total: usize = 0;
    for (0..10) |_| total += resampler.process(&input, &out);
    // 4800 input samples at 2:1 give 2400 outputs, within one sample of phase.
    try testing.expect(total >= 2399 and total <= 2401);

    var up = Resampler.init(16_000, 24_000);
    total = 0;
    for (0..10) |_| total += up.process(input[0..160], &out);
    try testing.expect(total >= 2399 and total <= 2401);
}

test "resampler passes a DC level and a low tone, and is identity at equal rates" {
    var down = Resampler.init(48_000, 16_000);
    var input: [960]i16 = @splat(10_000);
    var out: [512]i16 = undefined;
    _ = down.process(&input, &out);
    const n = down.process(&input, &out);
    // After the filter settles, DC passes unchanged.
    try testing.expect(@abs(@as(i32, out[n - 1]) - 10_000) < 50);

    var same = Resampler.init(24_000, 24_000);
    const copied = same.process(&.{ 1, 2, 3 }, &out);
    try testing.expectEqualSlices(i16, &.{ 1, 2, 3 }, out[0..copied]);

    // A 300 Hz tone survives 48k -> 24k with most of its amplitude.
    var tone_resampler = Resampler.init(48_000, 24_000);
    var tone: [4800]i16 = undefined;
    for (&tone, 0..) |*sample, index| {
        const t = @as(f64, @floatFromInt(index)) / 48_000.0;
        sample.* = @intFromFloat(@sin(2.0 * std.math.pi * 300.0 * t) * 16_000.0);
    }
    var tone_out: [2600]i16 = undefined;
    const tone_n = tone_resampler.process(&tone, &tone_out);
    var peak: i16 = 0;
    for (tone_out[200..tone_n]) |sample| peak = @max(peak, sample);
    try testing.expect(peak > 14_000);
}

test "resampler attenuates content above the output Nyquist" {
    var resampler = Resampler.init(48_000, 16_000);
    var tone: [4800]i16 = undefined;
    for (&tone, 0..) |*sample, index| {
        const t = @as(f64, @floatFromInt(index)) / 48_000.0;
        sample.* = @intFromFloat(@sin(2.0 * std.math.pi * 15_000.0 * t) * 16_000.0);
    }
    var out: [1700]i16 = undefined;
    const n = resampler.process(&tone, &out);
    var peak: i32 = 0;
    for (out[100..n]) |sample| peak = @max(peak, @as(i32, @abs(sample)));
    try testing.expect(peak < 6_000);
}

test "ring wraps, drops overflow, and flushes on request" {
    var ring = try Ring.init(testing.allocator, 6);
    defer ring.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 8), ring.buffer.len);
    try testing.expectEqual(@as(usize, 5), ring.write(&.{ 1, 2, 3, 4, 5 }));
    var out: [8]i16 = undefined;
    try testing.expectEqual(@as(usize, 3), ring.read(out[0..3]));
    try testing.expectEqualSlices(i16, &.{ 1, 2, 3 }, out[0..3]);
    // Wraps past the end; only 6 slots are free.
    try testing.expectEqual(@as(usize, 6), ring.write(&.{ 6, 7, 8, 9, 10, 11, 12 }));
    try testing.expectEqual(@as(usize, 8), ring.available());
    try testing.expectEqual(@as(usize, 8), ring.read(&out));
    try testing.expectEqualSlices(i16, &.{ 4, 5, 6, 7, 8, 9, 10, 11 }, &out);
    _ = ring.write(&.{ 1, 2, 3 });
    ring.requestFlush();
    try testing.expectEqual(@as(usize, 0), ring.read(&out));
    try testing.expectEqual(@as(usize, 0), ring.available());
    _ = ring.write(&.{9});
    try testing.expectEqual(@as(usize, 1), ring.read(&out));
}
