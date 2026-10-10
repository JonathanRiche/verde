//! Tests that need a GPU device: Vulkan on Linux/BSD, Metal on macOS, Direct3D 11 on Windows
//! (skipped when none is available). The goldens are shared by all backends.

const std = @import("std");
const draw = @import("../draw.zig");
const gpu = @import("root.zig");
const scene = @import("scene.zig");
const present = @import("../platform/present.zig");

const Fixture = struct {
    ctx: *gpu.Context,
    renderer: *gpu.Renderer,
    stub: *gpu.StubGlyphSource,

    fn init(gpa: std.mem.Allocator) !Fixture {
        const ctx = gpu.Context.init(gpa, .{}) catch |err| switch (@as(anyerror, err)) {
            error.VulkanLoaderNotFound, error.MetalUnavailable, error.NoSuitableGpu => return error.SkipZigTest,
            else => return err,
        };
        errdefer ctx.deinit();
        const stub = try gpa.create(gpu.StubGlyphSource);
        errdefer gpa.destroy(stub);
        stub.* = .{};
        const r = try gpu.Renderer.init(gpa, ctx, .{ .glyph_source = stub.source() });
        var px: [scene.image_size * scene.image_size * 4]u8 = undefined;
        scene.checkerPixels(&px);
        try r.uploadTexture(scene.image_texture_id, scene.image_size, scene.image_size, .rgba8, &px);
        return .{ .ctx = ctx, .renderer = r, .stub = stub };
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.renderer.deinit();
        self.ctx.deinit();
        gpa.destroy(self.stub);
    }
};

fn renderScene(gpa: std.mem.Allocator, f: *Fixture, scale: f32, out: []u8) !void {
    const w: u32 = @intFromFloat(@round(@as(f32, scene.width) * scale));
    const h: u32 = @intFromFloat(@round(@as(f32, scene.height) * scale));
    var target = try gpu.Offscreen.init(f.renderer, w, h);
    defer target.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try scene.build(gpa, &batch, scale);
    _ = try target.render(&batch, .{ .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 } });
    try target.readRgba(out);
}

fn pixel(buf: []const u8, w: u32, x: u32, y: u32) [4]u8 {
    const i = (y * w + x) * 4;
    return buf[i..][0..4].*;
}

/// Exact on Vulkan (the values were taken from it); Metal's rasteriser/ALU rounds a few AA
/// ramp pixels one LSB differently (see metal/README.md), so it gets +-1.
fn expectPixel(expected: [4]u8, actual: [4]u8) !void {
    const tol: i16 = if (gpu.backend_kind == .metal) 1 else 0;
    for (expected, actual) |e, a| {
        if (@abs(@as(i16, e) - @as(i16, a)) > tol) {
            std.debug.print("pixel: expected {any}, found {any}\n", .{ expected, actual });
            return error.TestExpectedEqual;
        }
    }
}

test "offscreen scene renders expected pixels" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const buf = try gpa.alloc(u8, scene.width * scene.height * 4);
    defer gpa.free(buf);
    try renderScene(gpa, &f, 1.0, buf);
    // Background 0.08/0.085/0.1.
    try expectPixel([4]u8{ 20, 22, 26, 255 }, pixel(buf, scene.width, 2, 2));
    // Panel border (1px at x=8, ~0.85 coverage under the 0.75px AA ramp, legacy blend) and
    // the first interior pixel (fill plus the ramp's tail).
    try expectPixel([4]u8{ 67, 73, 88, 255 }, pixel(buf, scene.width, 8, 100));
    try expectPixel([4]u8{ 35, 38, 46, 255 }, pixel(buf, scene.width, 9, 100));
    try expectPixel([4]u8{ 33, 36, 43, 255 }, pixel(buf, scene.width, 40, 280));
    // Filled accent button centre.
    try expectPixel([4]u8{ 64, 140, 242, 255 }, pixel(buf, scene.width, 224, 61));
    // Z-order: the popover (z=5) covers the later purple rect.
    const pop = pixel(buf, scene.width, 100, 200);
    try std.testing.expect(pop[0] < 80 and pop[2] < 80);
    try expectPixel([4]u8{ 153, 51, 153, 255 }, pixel(buf, scene.width, 25, 225));
    // Image: dark checker cell at (186, 162); the transparent hole shows the background.
    try expectPixel([4]u8{ 30, 90, 200, 255 }, pixel(buf, scene.width, 186, 162));
    try expectPixel([4]u8{ 20, 22, 26, 255 }, pixel(buf, scene.width, 216, 192));
    // Clipped image: right of the clip (x >= 368.5) shows the background.
    try expectPixel([4]u8{ 20, 22, 26, 255 }, pixel(buf, scene.width, 380, 190));
    // Clipped rounded rect: inside the clip is green, outside (x>=440) is not.
    try expectPixel([4]u8{ 102, 204, 128, 255 }, pixel(buf, scene.width, 430, 190));
    try expectPixel([4]u8{ 20, 22, 26, 255 }, pixel(buf, scene.width, 445, 190));
}

test "partial redraw matches full redraw, unchanged frames are skipped" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    var a = try gpu.Offscreen.init(f.renderer, scene.width, scene.height);
    defer a.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try scene.build(gpa, &batch, 1.0);
    const r1 = try a.render(&batch, .{});
    try std.testing.expect(r1.stats.full_redraw);
    const r2 = try a.render(&batch, .{});
    try std.testing.expect(r2.stats.skipped);

    // Change one button colour and move a label.
    for (batch.commands.items) |*c| {
        if (c.kind == .text and std.mem.eql(u8, c.text, "OK")) c.rect.x += 3;
        if (c.kind == .rect and c.radius == 6 and c.border_color == null) c.color = .{ .r = 0.9, .g = 0.2, .b = 0.2, .a = 1 };
    }
    const r3 = try a.render(&batch, .{});
    try std.testing.expect(!r3.stats.full_redraw);
    try std.testing.expect(r3.damage.len >= 1);
    try std.testing.expect(r3.stats.damaged_pixels < scene.width * scene.height / 4);
    const partial = try gpa.alloc(u8, scene.width * scene.height * 4);
    defer gpa.free(partial);
    try a.readRgba(partial);

    const full = try gpa.alloc(u8, scene.width * scene.height * 4);
    defer gpa.free(full);
    var b = try gpu.Offscreen.init(f.renderer, scene.width, scene.height);
    defer b.deinit();
    const r4 = try b.render(&batch, .{ .force_full = true });
    try std.testing.expect(r4.stats.full_redraw);
    try b.readRgba(full);
    const diff = gpu.png.compare(partial, full, 0);
    try std.testing.expectEqual(@as(usize, 0), diff.mismatched);
}

fn checkGolden(gpa: std.mem.Allocator, f: *Fixture, scale: f32, golden: []const u8) !void {
    const ref = try gpu.png.decode(gpa, golden);
    defer ref.deinit(gpa);
    const buf = try gpa.alloc(u8, ref.pixels.len);
    defer gpa.free(buf);
    try renderScene(gpa, f, scale, buf);
    // Tolerance: driver rounding differences in AA ramps (a few LSB); no pixel may be far off.
    const diff = gpu.png.compare(buf, ref.pixels, 3);
    if (diff.mismatched > ref.pixels.len / 4 / 1000) {
        std.debug.print("golden {d}x: {d} pixels differ (max delta {d})\n", .{ scale, diff.mismatched, diff.max_channel_delta });
        return error.GoldenMismatch;
    }
}

test "golden images (1x, 1.25x)" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    try checkGolden(gpa, &f, 1.0, @embedFile("testdata/scene_1x.png"));
    try checkGolden(gpa, &f, 1.25, @embedFile("testdata/scene_1.25x.png"));
}

test "Metal: precompiled metallib and runtime-compiled MSL render identically" {
    if (comptime gpu.backend_kind != .metal) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const metal_renderer = gpu.metal.renderer;
    var bufs: [2][2][]u8 = undefined; // [path][scale]
    for (0..2) |path| {
        metal_renderer.force_source_shader = path == 1;
        defer metal_renderer.force_source_shader = false;
        var f = try Fixture.init(gpa);
        defer f.deinit(gpa);
        const expected: gpu.metal.ShaderLibrary = if (path == 0) .metallib else .source;
        try std.testing.expectEqual(expected, f.renderer.shader_library);
        for ([_]f32{ 1.0, 1.25 }, 0..) |scale, si| {
            const w: usize = @intFromFloat(@round(@as(f32, scene.width) * scale));
            const h: usize = @intFromFloat(@round(@as(f32, scene.height) * scale));
            bufs[path][si] = try gpa.alloc(u8, w * h * 4);
            try renderScene(gpa, &f, scale, bufs[path][si]);
        }
    }
    defer for (bufs) |p| for (p) |b| gpa.free(b);
    for (0..2) |si| {
        const diff = gpu.png.compare(bufs[0][si], bufs[1][si], 0);
        try std.testing.expectEqual(@as(usize, 0), diff.mismatched);
    }
}

extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;

test "dma-buf targets export, sync and hold the rendered pixels" {
    if (comptime gpu.backend_kind != .vulkan) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    if (!f.ctx.caps.dmabuf_export) return error.SkipZigTest;

    // LINEAR (no compositor feedback): map the buffer and check the pixels.
    {
        var bufs = try gpu.DmabufTargets.init(f.renderer, 64, 48, .{});
        defer bufs.deinit();
        try std.testing.expectEqual(present.modifier_linear, bufs.modifier);
        var batch: draw.RenderBatch = .{};
        defer batch.deinit(gpa);
        try batch.rect(gpa, .{ .x = 0, .y = 0, .w = 32, .h = 48 }, .{ .r = 1, .g = 0, .b = 0, .a = 1 });
        const t = bufs.acquire().?;
        const res = try bufs.render(t, &batch, .{ .clear = .{ .r = 0, .g = 0, .b = 1, .a = 1 } });
        try std.testing.expect(!res.stats.skipped);
        try std.testing.expect(t.busy);
        try std.testing.expect(bufs.acquire() != t);
        const img = bufs.exported(t);
        try std.testing.expectEqual(present.Fourcc.xrgb8888, img.format);
        try std.testing.expectEqual(@as(u8, 1), img.plane_count);
        try std.testing.expect(img.planes[0].stride >= 64 * 4);
        // Wait for the attached fence the way a compositor would (implicit sync), via poll on
        // the dma-buf: simplest is the DMA_BUF_IOCTL_SYNC start which waits for writers.
        const size = img.planes[0].offset + img.planes[0].stride * 48;
        const map = mmap(null, size, 1, 1, img.planes[0].fd, 0) orelse return error.MmapFailed;
        defer _ = munmap(map, size);
        var sync_start = [_]u64{1 | 0}; // DMA_BUF_SYNC_READ | START
        _ = ioctl(img.planes[0].fd, 0x40086200, &sync_start);
        const bytes: [*]const u8 = @ptrCast(map);
        const row = bytes + img.planes[0].offset;
        // BGRX: red on the left, blue on the right.
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, row[4 * 4 ..][0..3]);
        try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, row[40 * 4 ..][0..3]);
        var sync_end = [_]u64{1 | 4}; // READ | END
        _ = ioctl(img.planes[0].fd, 0x40086200, &sync_end);
        bufs.release(t);
        try std.testing.expect(!t.busy);
    }

    // Tiled modifiers: pretend the compositor accepts everything the driver offers.
    if (f.ctx.caps.drm_format_modifier) {
        const formats = [_]present.FormatModifier{
            .{ .format = .xrgb8888, .modifier = 0x0100000000000001 }, // I915_FORMAT_MOD_X_TILED
            .{ .format = .xrgb8888, .modifier = 0x0100000000000002 }, // Y_TILED
            .{ .format = .xrgb8888, .modifier = present.modifier_linear },
        };
        var bufs = try gpu.DmabufTargets.init(f.renderer, 640, 480, .{ .count = 3, .feedback = .{ .formats = &formats } });
        defer bufs.deinit();
        try std.testing.expect(bufs.modifiers.items.len >= 1);
        var batch: draw.RenderBatch = .{};
        defer batch.deinit(gpa);
        try scene.build(gpa, &batch, 1.0);
        var frames: usize = 0;
        while (frames < 6) : (frames += 1) {
            const t = bufs.acquire().?;
            batch.commands.items[1].rect.x = @floatFromInt(8 + frames);
            const res = try bufs.render(t, &batch, .{});
            try std.testing.expect(!res.stats.skipped);
            // Age > 0 after the first round: partial redraws.
            if (frames >= 3) try std.testing.expect(!res.stats.full_redraw);
            for (bufs.exported(t).planes[0..bufs.exported(t).plane_count]) |p| try std.testing.expect(fcntl(p.fd, 1) >= 0);
            bufs.release(t);
        }
        std.log.info("dmabuf modifier 0x{x} planes {d} sync {s}", .{ bufs.modifier, bufs.targets[0].image.plane_count, @tagName(bufs.sync) });
    }
}

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

fn fillBgra(buf: []u8, bgra: [4]u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4) buf[i..][0..4].* = bgra;
}

test "streamed BGRA texture: full, partial, merged and strided updates without reallocation" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    const w = 64;
    const h = 48;
    const id = 77;
    var target = try gpu.Offscreen.init(f.renderer, w, h);
    defer target.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try batch.image(gpa, .{ .w = w, .h = h }, draw.TextureId.init(id), .{ .w = 1, .h = 1 }, draw.Color.white, null);

    const src = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(src);
    const out = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(out);
    const red_bgra: [4]u8 = .{ 0, 0, 255, 255 };
    const green_bgra: [4]u8 = .{ 0, 255, 0, 255 };
    const blue_bgra: [4]u8 = .{ 255, 0, 0, 255 };
    const red: [4]u8 = .{ 255, 0, 0, 255 };
    const green: [4]u8 = .{ 0, 255, 0, 255 };
    const blue: [4]u8 = .{ 0, 0, 255, 255 };

    // Flush the fixture's own uploads first.
    _ = try target.render(&batch, .{});

    // 1. First update is full (dirty rects ignored on a fresh texture).
    fillBgra(src, red_bgra);
    try f.renderer.streamTexture(id, w, h, .bgra8, src, .{ .dirty = &.{.{ .x = 0, .y = 0, .w = 1, .h = 1 }} });
    var res = try target.render(&batch, .{});
    try std.testing.expectEqual(@as(u32, 1), res.stats.texture_uploads);
    try std.testing.expectEqual(@as(u64, w * h * 4), res.stats.texture_upload_bytes);
    try target.readRgba(out);
    try std.testing.expectEqual(red, pixel(out, w, 0, 0));
    try std.testing.expectEqual(red, pixel(out, w, w - 1, h - 1));

    // 2. Partial: the source is all green but only the dirty rect is copied.
    fillBgra(src, green_bgra);
    try f.renderer.streamTexture(id, w, h, .bgra8, src, .{ .dirty = &.{.{ .x = 8, .y = 4, .w = 16, .h = 8 }} });
    res = try target.render(&batch, .{});
    try std.testing.expect(!res.stats.skipped);
    try std.testing.expectEqual(@as(u64, 16 * 8 * 4), res.stats.texture_upload_bytes);
    try target.readRgba(out);
    try std.testing.expectEqual(green, pixel(out, w, 8, 4));
    try std.testing.expectEqual(green, pixel(out, w, 23, 11));
    try std.testing.expectEqual(red, pixel(out, w, 24, 11));
    try std.testing.expectEqual(red, pixel(out, w, 8, 12));
    const mem_after_first = f.ctx.memory.allocation_count;

    // 3. Two updates before one frame merge into a single upload; the newest pixels win.
    fillBgra(src, blue_bgra);
    try f.renderer.streamTexture(id, w, h, .bgra8, src, .{ .dirty = &.{.{ .x = 40, .y = 30, .w = 4, .h = 4 }} });
    try f.renderer.streamTexture(id, w, h, .bgra8, src, .{ .dirty = &.{.{ .x = 0, .y = 40, .w = 2, .h = 2 }} });
    res = try target.render(&batch, .{});
    try std.testing.expectEqual(@as(u32, 1), res.stats.texture_uploads);
    try target.readRgba(out);
    try std.testing.expectEqual(blue, pixel(out, w, 41, 31));
    try std.testing.expectEqual(blue, pixel(out, w, 1, 41));
    try std.testing.expectEqual(green, pixel(out, w, 10, 5));

    // 4. Strided source (row pitch > width * 4), clipped rect.
    const stride = (w + 8) * 4;
    const wide = try gpa.alloc(u8, stride * h);
    defer gpa.free(wide);
    fillBgra(wide, red_bgra);
    try f.renderer.streamTexture(id, w, h, .bgra8, wide, .{ .stride = stride, .dirty = &.{.{ .x = 60, .y = 0, .w = 100, .h = 2 }} });
    _ = try target.render(&batch, .{});
    try target.readRgba(out);
    try std.testing.expectEqual(red, pixel(out, w, 63, 1));
    try std.testing.expectEqual(blue, pixel(out, w, 41, 31));

    // 5. Steady state: many full updates reuse the image and the staging ring.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        fillBgra(src, if (i % 2 == 0) green_bgra else red_bgra);
        try f.renderer.streamTexture(id, w, h, .bgra8, src, .{});
        _ = try target.render(&batch, .{});
    }
    try target.readRgba(out);
    try std.testing.expectEqual(red, pixel(out, w, 30, 30));
    // At most max_stream_slots staging buffers exist; no per-frame allocations.
    try std.testing.expect(f.ctx.memory.allocation_count <= mem_after_first + 3);
    const before = f.ctx.memory.allocation_count;
    i = 0;
    while (i < 20) : (i += 1) {
        try f.renderer.streamTexture(id, w, h, .bgra8, src, .{});
        _ = try target.render(&batch, .{});
    }
    try std.testing.expectEqual(before, f.ctx.memory.allocation_count);

    // 6. A resize replaces the image; release frees everything.
    try f.renderer.streamTexture(id, 32, 32, .bgra8, src, .{});
    _ = try target.render(&batch, .{});
    f.renderer.releaseTexture(id);
}

/// Renders the reference scene into an exported dma-buf (the producer), imports that buffer
/// as image `id`, draws it full-size into an offscreen target and checks the golden.
fn importRoundTrip(gpa: std.mem.Allocator, f: *Fixture, options: gpu.DmabufOptions, label: []const u8) !void {
    var bufs = try gpu.DmabufTargets.init(f.renderer, scene.width, scene.height, options);
    defer bufs.deinit();
    var producer: draw.RenderBatch = .{};
    defer producer.deinit(gpa);
    try scene.build(gpa, &producer, 1.0);
    const t = bufs.acquire().?;
    _ = try bufs.render(t, &producer, .{ .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 } });
    const img = bufs.exported(t);

    const id: u32 = 900;
    const key = gpu.Renderer.dmabufKey(img.planes[0].fd);
    try std.testing.expect(key != 0);
    // Same buffer through another fd -> same key.
    const other = dup(img.planes[0].fd);
    defer _ = close(other);
    try std.testing.expectEqual(key, gpu.Renderer.dmabufKey(other));
    try f.renderer.importDmabufTexture(id, img, .{});
    try std.testing.expect(f.renderer.hasDmabufImport(key));

    var target = try gpu.Offscreen.init(f.renderer, scene.width, scene.height);
    defer target.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    const full: draw.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(scene.width), .h = @floatFromInt(scene.height) };
    try batch.image(gpa, full, draw.TextureId.init(id), .{ .w = 1, .h = 1 }, draw.Color.white, null);
    const r1 = try target.render(&batch, .{ .clear = .{ .r = 1, .g = 0, .b = 1, .a = 1 } });
    try std.testing.expect(!r1.stats.skipped);
    const out = try gpa.alloc(u8, scene.width * scene.height * 4);
    defer gpa.free(out);
    try target.readRgba(out);
    const ref = try gpu.png.decode(gpa, @embedFile("testdata/scene_1x.png"));
    defer ref.deinit(gpa);
    const diff = gpu.png.compare(out, ref.pixels, 3);
    if (diff.mismatched > ref.pixels.len / 4 / 1000) {
        std.debug.print("dma-buf import ({s}, modifier 0x{x}): {d} pixels differ (max delta {d})\n", .{ label, img.modifier, diff.mismatched, diff.max_channel_delta });
        return error.GoldenMismatch;
    }

    // Same frame, nothing new: skipped. A new frame from the producer: the image is damaged
    // again, the import is reused (no re-import), overlays drawn later stay on top.
    const r2 = try target.render(&batch, .{ .clear = .{ .r = 1, .g = 0, .b = 1, .a = 1 } });
    try std.testing.expect(r2.stats.skipped);
    bufs.release(t);
    const fence = f.renderer.takeDmabufReleaseFence(key);
    if (fence >= 0) _ = close(fence);
    producer.commands.items[0].color = .{ .r = 0, .g = 1, .b = 0, .a = 1 };
    _ = try bufs.render(t, &producer, .{ .force_full = true });
    try f.renderer.importDmabufTexture(id, bufs.exported(t), .{});
    try batch.rect(gpa, .{ .x = 0, .y = 0, .w = 4, .h = 4 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    const r3 = try target.render(&batch, .{ .clear = .{ .r = 1, .g = 0, .b = 1, .a = 1 } });
    try std.testing.expect(!r3.stats.skipped);
    try target.readRgba(out);
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, pixel(out, scene.width, 1, 1));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(out, scene.width, 5, 100));

    // Producer drops the buffer: the id is unbound, nothing leaks.
    f.renderer.releaseDmabufImport(key);
    try std.testing.expect(!f.renderer.hasDmabufImport(key));
    _ = try target.render(&batch, .{ .clear = .{ .r = 1, .g = 0, .b = 1, .a = 1 } });
    bufs.release(t);
    std.log.info("dma-buf import {s}: modifier 0x{x}, {d} plane(s)", .{ label, img.modifier, img.plane_count });
}

extern "c" fn dup(fd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

test "dma-buf import: own exported buffer (LINEAR and tiled) matches the golden" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    if (!f.renderer.canImportDmabuf() or !f.ctx.caps.dmabuf_export) return error.SkipZigTest;

    var formats: std.ArrayList(present.FormatModifier) = .empty;
    defer formats.deinit(gpa);
    try f.renderer.appendDmabufImportFormats(gpa, &formats);
    try std.testing.expect(formats.items.len > 0);

    try importRoundTrip(gpa, &f, .{}, "linear");
    if (f.ctx.caps.drm_format_modifier) {
        // Offer the producer everything we can import (as the browser handshake does).
        try importRoundTrip(gpa, &f, .{ .feedback = .{ .formats = formats.items } }, "modifiers");
    }
}

test "dma-buf import: producer damage repaints only the damaged texels, accumulated across undrawn frames" {
    const gpa = std.testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);
    if (!f.renderer.canImportDmabuf() or !f.ctx.caps.dmabuf_export) return error.SkipZigTest;
    const w: u32 = 256;
    const h: u32 = 128;
    // The producer gets its own renderer (its own damage history), like the browser process.
    const prod = try gpu.Renderer.init(gpa, f.ctx, .{ .glyph_source = f.stub.source() });
    defer prod.deinit();
    var bufs = try gpu.DmabufTargets.init(prod, w, h, .{});
    defer bufs.deinit();
    var producer: draw.RenderBatch = .{};
    defer producer.deinit(gpa);
    const Patch = struct { x: f32, y: f32, color: draw.Color };
    // Producer frame: black with two 8x8 patches.
    const frame = struct {
        fn draw_(b: *gpu.DmabufTargets, p: *draw.RenderBatch, a: std.mem.Allocator, t: anytype, patches: [2]Patch) !void {
            p.clear();
            for (patches) |q| try p.rect(a, .{ .x = q.x, .y = q.y, .w = 8, .h = 8 }, q.color);
            _ = try b.render(t, p, .{ .clear = .{ .r = 0, .g = 0, .b = 0, .a = 1 }, .force_full = true });
        }
    }.draw_;
    const red: draw.Color = .{ .r = 1, .g = 0, .b = 0, .a = 1 };
    const green: draw.Color = .{ .r = 0, .g = 1, .b = 0, .a = 1 };
    const blue: draw.Color = .{ .r = 0, .g = 0, .b = 1, .a = 1 };

    const id: u32 = 901;
    var target = try gpu.Offscreen.init(f.renderer, w, h);
    defer target.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try batch.image(gpa, .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) }, draw.TextureId.init(id), .{ .w = 1, .h = 1 }, draw.Color.white, null);
    const out = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(out);

    // 1. Buffer A, full frame.
    const ta = bufs.acquire().?;
    try frame(&bufs, &producer, gpa, ta, .{ .{ .x = 16, .y = 16, .color = red }, .{ .x = 200, .y = 96, .color = red } });
    try f.renderer.importDmabufTexture(id, bufs.exported(ta), .{});
    const r1 = try target.render(&batch, .{});
    try std.testing.expect(r1.stats.full_redraw);

    // 2. Buffer B: only the first patch changed (green), damage says so.
    const tb = bufs.acquire().?;
    try frame(&bufs, &producer, gpa, tb, .{ .{ .x = 16, .y = 16, .color = green }, .{ .x = 200, .y = 96, .color = red } });
    try f.renderer.importDmabufTexture(id, bufs.exported(tb), .{ .damage = &.{.{ .x = 16, .y = 16, .w = 8, .h = 8 }} });
    const r2 = try target.render(&batch, .{});
    try std.testing.expect(!r2.stats.full_redraw and !r2.stats.skipped);
    try std.testing.expect(r2.stats.damaged_pixels < w * h / 4);
    try target.readRgba(out);
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(out, w, 20, 20));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(out, w, 204, 100));

    // 3. Two frames before the next draw: A gets patch 2 blue (damage there), then B gets
    // patch 1 blue too (damage only at patch 1). Both regions must be repainted.
    bufs.release(ta);
    const fa = f.renderer.takeDmabufReleaseFence(gpu.Renderer.dmabufKey(bufs.exported(ta).planes[0].fd));
    if (fa >= 0) _ = close(fa);
    try frame(&bufs, &producer, gpa, ta, .{ .{ .x = 16, .y = 16, .color = green }, .{ .x = 200, .y = 96, .color = blue } });
    try f.renderer.importDmabufTexture(id, bufs.exported(ta), .{ .damage = &.{.{ .x = 200, .y = 96, .w = 8, .h = 8 }} });
    bufs.release(tb);
    try f.renderer.waitSerial(r2.serial);
    try frame(&bufs, &producer, gpa, tb, .{ .{ .x = 16, .y = 16, .color = blue }, .{ .x = 200, .y = 96, .color = blue } });
    try f.renderer.importDmabufTexture(id, bufs.exported(tb), .{ .damage = &.{.{ .x = 16, .y = 16, .w = 8, .h = 8 }} });
    const r3 = try target.render(&batch, .{});
    try std.testing.expect(!r3.stats.full_redraw);
    try target.readRgba(out);
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(out, w, 20, 20));
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(out, w, 204, 100));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, pixel(out, w, 100, 60));

    // 4. Nothing new: skipped.
    const r4 = try target.render(&batch, .{});
    try std.testing.expect(r4.stats.skipped);
    f.renderer.releaseTexture(id);
    bufs.release(ta);
    bufs.release(tb);
}
