//! Dev-only: decode PNGs with Palette's codec and with stb_image, compare pixels and report
//! throughput. Not part of the library. `zig build bench-png -Doptimize=ReleaseFast -- FILES...`
//! Pass `--iters N` (default: auto, ~0.3 s per file per decoder) and `--no-verify` to skip
//! CRC/Adler checks (stb_image never checks them). `--fuzz N` instead mutates each file N times
//! and decodes it (use -Doptimize=ReleaseSafe).
const std = @import("std");
const image = @import("image");
const png = image.png;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_failure_reason() ?[*:0]const u8;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var stdout_buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &fw.interface;

    var fixed_iters: ?usize = null;
    var opts: png.DecodeOptions = .{};
    var fuzz_iters: usize = 0;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    var total_px_bytes: f64 = 0;
    var total_ours_s: f64 = 0;
    var total_stb_s: f64 = 0;
    var mismatches: usize = 0;
    var files: usize = 0;
    var i: usize = 1;
    try out.print("{s:<60} {s:>11} {s:>9} {s:>10} {s:>10} {s:>6}\n", .{ "file", "size", "fmt", "ours MB/s", "stb MB/s", "match" });
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--iters")) {
            i += 1;
            fixed_iters = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--fuzz")) {
            i += 1;
            fuzz_iters = try std.fmt.parseInt(usize, args[i], 10);
            continue;
        }
        if (std.mem.eql(u8, args[i], "--no-verify")) {
            opts.verify_checksums = false;
            continue;
        }
        const path = args[i];
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20)) catch |err| {
            try out.print("{s}: read error {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(bytes);

        if (fuzz_iters > 0) {
            // Mutation fuzzing on a real file (build with ReleaseSafe to catch safety traps).
            const rand = prng.random();
            const buf = try gpa.dupe(u8, bytes);
            defer gpa.free(buf);
            var ok: usize = 0;
            for (0..fuzz_iters) |_| {
                @memcpy(buf, bytes);
                for (0..rand.intRangeAtMost(usize, 1, 16)) |_| {
                    const at = rand.intRangeLessThan(usize, 8, buf.len);
                    buf[at] = if (rand.boolean()) rand.int(u8) else buf[at] ^ (@as(u8, 1) << rand.int(u3));
                }
                const cut = if (rand.int(u3) == 0) rand.intRangeAtMost(usize, 0, buf.len) else buf.len;
                if (png.decode(gpa, buf[0..cut], .{ .verify_checksums = rand.boolean() })) |img| {
                    ok += 1;
                    img.deinit(gpa);
                } else |_| {}
            }
            try out.print("fuzz {s}: {d} mutations, {d} still decoded, no crash\n", .{ path, fuzz_iters, ok });
            try out.flush();
            continue;
        }

        const ours = png.decode(gpa, bytes, opts) catch |err| {
            var w: c_int = 0;
            var h: c_int = 0;
            var c: c_int = 0;
            const sp = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &c, 4);
            defer stbi_image_free(sp);
            try out.print("{s}: ours error {s} (stb {s})\n", .{ path, @errorName(err), if (sp != null) "ok" else "also fails" });
            if (sp != null) mismatches += 1;
            continue;
        };
        defer ours.deinit(gpa);
        const info = try png.decodeInfo(bytes);

        var w: c_int = 0;
        var h: c_int = 0;
        var c: c_int = 0;
        const sp = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &c, 4) orelse {
            try out.print("{s}: stb error {s}\n", .{ path, stbi_failure_reason() orelse "?" });
            continue;
        };
        const stb_px = sp[0..ours.pixels.len];
        const same = w == ours.width and h == ours.height and std.mem.eql(u8, stb_px, ours.pixels);
        if (!same) {
            mismatches += 1;
            var first: usize = 0;
            while (first < ours.pixels.len and stb_px[first] == ours.pixels[first]) first += 1;
            try out.print("  MISMATCH at byte {d} (px {d}): ours {any} stb {any}\n", .{ first, first / 4, ours.pixels[first / 4 * 4 ..][0..4], stb_px[first / 4 * 4 ..][0..4] });
        }
        stbi_image_free(sp);

        const px_bytes: f64 = @floatFromInt(ours.pixels.len);
        const iters = fixed_iters orelse @max(3, @min(2000, @as(usize, @intFromFloat(300e6 / @max(px_bytes, 1.0) / 2.0))));

        var t0 = nowNs(io);
        for (0..iters) |_| {
            const img = try png.decode(gpa, bytes, opts);
            std.mem.doNotOptimizeAway(img.pixels.ptr);
            img.deinit(gpa);
        }
        const ours_s = @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e9;
        t0 = nowNs(io);
        for (0..iters) |_| {
            const p = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &c, 4);
            std.mem.doNotOptimizeAway(p);
            stbi_image_free(p);
        }
        const stb_s = @as(f64, @floatFromInt(nowNs(io) - t0)) / 1e9;
        const n: f64 = @floatFromInt(iters);
        total_px_bytes += px_bytes * n;
        total_ours_s += ours_s;
        total_stb_s += stb_s;
        files += 1;
        var fmt_buf: [16]u8 = undefined;
        const fmt = try std.fmt.bufPrint(&fmt_buf, "{s}{d}{s}", .{ switch (info.color_type) {
            .gray => "g",
            .gray_alpha => "ga",
            .rgb => "rgb",
            .rgba => "rgba",
            .indexed => "p",
        }, info.bit_depth, if (info.interlaced) "i" else "" });
        var size_buf: [24]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ info.width, info.height });
        const shown = if (path.len > 60) path[path.len - 60 ..] else path;
        try out.print("{s:<60} {s:>11} {s:>9} {d:>10.1} {d:>10.1} {s:>6}\n", .{ shown, size, fmt, px_bytes * n / ours_s / 1e6, px_bytes * n / stb_s / 1e6, if (same) "yes" else "NO" });
    }
    try out.print("\n{d} files, {d} mismatches. Aggregate RGBA output throughput: ours {d:.1} MB/s, stb {d:.1} MB/s (ratio {d:.2}x)\n", .{
        files,                               mismatches,
        total_px_bytes / total_ours_s / 1e6, total_px_bytes / total_stb_s / 1e6,
        total_stb_s / total_ours_s,
    });
    try out.flush();
    if (mismatches != 0) std.process.exit(1);
}
