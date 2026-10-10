//! Palette's Metal renderer (macOS): `draw.RenderBatch` -> one instanced pipeline, the same
//! uber-shader as Vulkan (ported to MSL in `shader.metal`, compiled at runtime).
//!
//! The backend-neutral work (instances, texture runs, glyph layout + atlas packing, damage,
//! the skip/full/partial plan, stream-region merging) is `../core.zig`; this file owns the
//! Metal objects, records and commits.
//!
//! * Instances live in a per-frame shared (unified memory) buffer ring, read by the vertex
//!   shader through `[[instance_id]]`; one `drawPrimitives(strip, 4, n, base)` per run.
//! * Glyph atlases are private R8 / RGBA8 textures, grown by GPU copy; textures are private
//!   and filled by blit copies from shared staging (mip chain by `generateMipmaps`).
//! * Streamed textures reuse a per-texture ring of shared staging buffers (no steady-state
//!   allocation) and copy only the dirty rectangles.
//! * Completion is tracked with frame serials: each frame slot keeps its retained command
//!   buffer; `status` is polled, `waitUntilCompleted` blocks. Command buffers retain every
//!   resource they reference, so objects are released immediately (no retire queue).
//! * Partial redraws keep the target texture (load action `load`) and scissor each damage
//!   rect: a no-blend clear quad, then the runs.

const std = @import("std");
const draw = @import("../../draw.zig");
const core = @import("../core.zig");
const text = @import("../text.zig");
const damage = @import("../damage.zig");
const clock = @import("../../clock.zig");
const mtl = @import("mtl.zig");

const objc = mtl.objc;
const Id = mtl.Id;
const NSUInteger = mtl.NSUInteger;
const send = mtl.send;

const log = std.log.scoped(.metal);

pub const Instance = core.Instance;
pub const Options = core.Options;
pub const TextureFormat = core.TextureFormat;
pub const FrameStats = core.FrameStats;
pub const FrameOptions = core.FrameOptions;
pub const FrameResult = core.FrameResult;
pub const MemoryStats = core.MemoryStats;
pub const TextureRect = core.TextureRect;
pub const StreamOptions = core.StreamOptions;
pub const max_stream_regions = core.max_stream_regions;
const max_stream_slots = core.max_stream_slots;

/// The only colour attachment format (CAMetalLayer's default).
pub const target_format = mtl.PixelFormat.bgra8_unorm;

const shader_source = @embedFile("shader.metal");

// ---- Context ------------------------------------------------------------------------------

pub const ContextOptions = struct {
    app_name: [:0]const u8 = "palette",
};

pub const Error = error{ MetalUnavailable, NoSuitableGpu, MetalOutOfMemory, MetalShaderCompileFailed, MetalPipelineFailed, MetalCommandFailed };

pub const Context = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    /// Bytes / objects currently allocated (textures count as device-local, buffers as
    /// host-visible: Apple GPUs have unified memory, so this is a split by storage mode).
    memory: MemoryStats = .{},
    submit_serial: u64 = 0,
    completed_serial: u64 = 0,
    device_name: [64]u8 = @splat(0),
    unified_memory: bool = true,

    pub fn init(gpa: std.mem.Allocator, options: ContextOptions) !*Context {
        _ = options;
        objc.load() catch return error.MetalUnavailable;
        if (objc.frameworks.metal == null) return error.MetalUnavailable;
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = mtl.createSystemDefaultDevice() orelse return error.NoSuitableGpu;
        errdefer objc.release(device);
        const queue = send(?Id, device, "newCommandQueue", .{}) orelse return error.NoSuitableGpu;
        const self = try gpa.create(Context);
        self.* = .{ .gpa = gpa, .device = device, .queue = queue };
        const name = objc.utf8(send(?Id, device, "name", .{}));
        const n = @min(name.len, self.device_name.len - 1);
        @memcpy(self.device_name[0..n], name[0..n]);
        self.unified_memory = send(objc.BOOL, device, "hasUnifiedMemory", .{}) != 0;
        log.debug("metal device {s}", .{self.deviceName()});
        return self;
    }

    pub fn deinit(self: *Context) void {
        objc.release(self.queue);
        objc.release(self.device);
        self.gpa.destroy(self);
    }

    pub fn deviceName(self: *const Context) []const u8 {
        return std.mem.sliceTo(&self.device_name, 0);
    }

    pub fn nextSerial(self: *Context) u64 {
        self.submit_serial += 1;
        return self.submit_serial;
    }

    pub fn markCompleted(self: *Context, serial: u64) void {
        if (serial > self.completed_serial) self.completed_serial = serial;
    }

    pub fn createBuffer(self: *Context, size: usize, options: NSUInteger) !Buffer {
        const obj = mtl.newBuffer(self.device, size, options) orelse return error.MetalOutOfMemory;
        const len = mtl.bufferLength(obj);
        self.memory.host_visible_bytes += len;
        self.memory.allocation_count += 1;
        return .{ .obj = obj, .size = len };
    }

    pub fn destroyBuffer(self: *Context, b: *Buffer) void {
        const obj = b.obj orelse return;
        objc.release(obj);
        self.memory.host_visible_bytes -|= b.size;
        self.memory.allocation_count -|= 1;
        b.* = .{};
    }

    fn createTexture(self: *Context, format: NSUInteger, width: u32, height: u32, mipmapped: bool, usage: NSUInteger) !Id {
        const t = mtl.newTexture(self.device, format, width, height, mipmapped, usage, mtl.StorageMode.private) orelse return error.MetalOutOfMemory;
        self.memory.device_local_bytes += textureBytes(t);
        self.memory.allocation_count += 1;
        return t;
    }

    fn destroyTexture(self: *Context, t: Id) void {
        self.memory.device_local_bytes -|= textureBytes(t);
        self.memory.allocation_count -|= 1;
        objc.release(t);
    }

    pub fn createTargetTexture(self: *Context, width: u32, height: u32) !Id {
        return self.createTexture(target_format, width, height, false, mtl.TextureUsage.render_target | mtl.TextureUsage.shader_read);
    }

    pub fn destroyTargetTexture(self: *Context, t: Id) void {
        self.destroyTexture(t);
    }
};

/// Allocated size of a texture (driver-reported; includes mips and alignment).
fn textureBytes(t: Id) u64 {
    return send(NSUInteger, t, "allocatedSize", .{});
}

pub const Buffer = struct {
    obj: ?Id = null,
    size: usize = 0,

    pub fn bytes(self: Buffer) []u8 {
        return mtl.contents(self.obj.?)[0..self.size];
    }
};

// ---- Targets --------------------------------------------------------------------------------

/// A BGRA8 render-target texture the renderer draws into (owned by `targets.zig` wrappers).
pub const Target = struct {
    texture: ?Id = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Damage-history frame index of the last render into this target (0 = never/undefined).
    last_frame: u64 = 0,
    last_serial: u64 = 0,

    pub fn invalidate(self: *Target) void {
        self.last_frame = 0;
    }
};

/// Work appended to a frame's command buffer after the render pass (window presentation:
/// blit the retained backbuffer into a drawable and present it).
pub const PostPass = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, cmd: Id, target: *Target) void,
};

// ---- Renderer ---------------------------------------------------------------------------

const Texture = struct {
    tex: Id,
    width: u32,
    height: u32,
    format: NSUInteger,
    mipmapped: bool,
    generation: u32,
    ready: bool = false,
    stream: ?*Stream = null,
};

const Stream = struct {
    slots: [max_stream_slots]Slot = @splat(.{}),
    count: u8 = 0,

    const Slot = struct {
        buffer: Buffer = .{},
        serial: u64 = 0,
        pending: bool = false,
    };
};

const PendingUpload = struct {
    id: u32,
    staging: Buffer,
    slot: ?u8 = null,
    region_count: u8 = 0,
    regions: [max_stream_regions]TextureRect = undefined,
};

const Atlas = struct {
    tex: ?Id = null,
    size: u32 = 0,
    /// Holds defined contents (first upload recorded).
    initialized: bool = false,
};

const Frame = struct {
    cmd: ?Id = null,
    serial: u64 = 0,
    instances: Buffer = .{},
    staging: Buffer = .{},
};

const Push = extern struct {
    ndc_scale: [2]f32,
    flags: u32,
    pad: u32 = 0,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    ctx: *Context,
    options: Options,
    enc: core.Encoder,
    pipeline: ?Id = null,
    clear_pipeline: ?Id = null,
    frames: [3]Frame = @splat(.{}),
    frame_count: u8 = 2,
    frame_cursor: u64 = 0,
    atlases: [2]Atlas = .{ .{}, .{} },
    dummy: ?Texture = null,
    textures: std.AutoHashMapUnmanaged(u32, Texture) = .empty,
    pending_uploads: std.ArrayList(PendingUpload) = .empty,
    texture_generation: u32 = 1,
    last_stats: FrameStats = .{},

    pub fn init(gpa: std.mem.Allocator, ctx: *Context, options: Options) !*Renderer {
        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .options = options,
            .frame_count = std.math.clamp(options.frames_in_flight, 2, 3),
            .enc = .init(gpa, options),
        };
        errdefer self.deinitInner();
        const pool = objc.Pool.push();
        defer pool.pop();
        try self.createPipelines();
        try self.createAtlas(.coverage, self.enc.glyph_cache.atlasSize(.coverage));
        try self.createAtlas(.color, self.enc.glyph_cache.atlasSize(.color));
        // 1x1 white for untextured runs (uploaded with the first frame).
        self.dummy = .{ .tex = try ctx.createTexture(mtl.PixelFormat.rgba8_unorm, 1, 1, false, mtl.TextureUsage.shader_read), .width = 1, .height = 1, .format = mtl.PixelFormat.rgba8_unorm, .mipmapped = false, .generation = 0 };
        {
            var staging = try ctx.createBuffer(4, mtl.ResourceOptions.shared_write_combined);
            errdefer ctx.destroyBuffer(&staging);
            @memset(staging.bytes()[0..4], 255);
            try self.pending_uploads.append(gpa, .{ .id = 0, .staging = staging });
        }
        if (options.glyph_source) |source| self.setGlyphSource(source);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.deinitInner();
        self.gpa.destroy(self);
    }

    fn deinitInner(self: *Renderer) void {
        const ctx = self.ctx;
        self.waitIdle();
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.cmd) |c| objc.release(c);
            f.cmd = null;
            ctx.destroyBuffer(&f.instances);
            ctx.destroyBuffer(&f.staging);
        }
        for (self.pending_uploads.items) |*p| {
            if (p.slot == null) ctx.destroyBuffer(&p.staging);
        }
        self.pending_uploads.deinit(self.gpa);
        var it = self.textures.valueIterator();
        while (it.next()) |t| self.destroyTexture(t.*);
        self.textures.deinit(self.gpa);
        if (self.dummy) |d| ctx.destroyTexture(d.tex);
        self.dummy = null;
        for (&self.atlases) |*a| {
            if (a.tex) |t| ctx.destroyTexture(t);
            a.* = .{};
        }
        if (self.pipeline) |p| objc.release(p);
        if (self.clear_pipeline) |p| objc.release(p);
        self.enc.deinit();
    }

    pub fn setGlyphSource(self: *Renderer, source: text.GlyphSource) void {
        self.enc.setGlyphSource(source);
    }

    pub fn lastFrameStats(self: *const Renderer) FrameStats {
        return self.last_stats;
    }

    // ---- Setup ----------------------------------------------------------------------------

    fn createPipelines(self: *Renderer) !void {
        const dev = self.ctx.device;
        const opts = objc.new(objc.class("MTLCompileOptions"));
        defer objc.release(opts);
        // Bit-for-bit parity with the SPIR-V path matters more than the last cycle.
        if (objc.respondsTo(opts, "setMathMode:")) {
            send(void, opts, "setMathMode:", .{@as(objc.NSInteger, 0)}); // MTLMathModeSafe
        } else {
            send(void, opts, "setFastMathEnabled:", .{objc.NO});
        }
        var err: ?Id = null;
        const lib = send(?Id, dev, "newLibraryWithSource:options:error:", .{ objc.nsString(shader_source), opts, &err }) orelse {
            log.err("MSL compile failed: {s}", .{mtl.errorText(err)});
            return error.MetalShaderCompileFailed;
        };
        defer objc.release(lib);
        self.pipeline = try makePipeline(dev, lib, "ui_vertex", "ui_fragment", true);
        self.clear_pipeline = try makePipeline(dev, lib, "clear_vertex", "clear_fragment", false);
    }

    fn makePipeline(dev: Id, lib: Id, vs_name: []const u8, fs_name: []const u8, blend: bool) !Id {
        const vs = send(?Id, lib, "newFunctionWithName:", .{objc.nsString(vs_name)}) orelse return error.MetalPipelineFailed;
        defer objc.release(vs);
        const fs = send(?Id, lib, "newFunctionWithName:", .{objc.nsString(fs_name)}) orelse return error.MetalPipelineFailed;
        defer objc.release(fs);
        const desc = objc.new(objc.class("MTLRenderPipelineDescriptor"));
        defer objc.release(desc);
        send(void, desc, "setVertexFunction:", .{vs});
        send(void, desc, "setFragmentFunction:", .{fs});
        const att = send(Id, send(Id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        send(void, att, "setPixelFormat:", .{target_format});
        if (blend) {
            // Premultiplied output: ONE, ONE_MINUS_SRC_ALPHA for colour and alpha.
            send(void, att, "setBlendingEnabled:", .{objc.YES});
            send(void, att, "setSourceRGBBlendFactor:", .{mtl.BlendFactor.one});
            send(void, att, "setDestinationRGBBlendFactor:", .{mtl.BlendFactor.one_minus_source_alpha});
            send(void, att, "setSourceAlphaBlendFactor:", .{mtl.BlendFactor.one});
            send(void, att, "setDestinationAlphaBlendFactor:", .{mtl.BlendFactor.one_minus_source_alpha});
        }
        var err: ?Id = null;
        return send(?Id, dev, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse {
            log.err("pipeline {s}: {s}", .{ vs_name, mtl.errorText(err) });
            return error.MetalPipelineFailed;
        };
    }

    fn createAtlas(self: *Renderer, kind: text.AtlasKind, size: u32) !void {
        const a = &self.atlases[@intFromEnum(kind)];
        const format = switch (kind) {
            .coverage => mtl.PixelFormat.r8_unorm,
            .color => mtl.PixelFormat.rgba8_unorm,
        };
        a.* = .{ .tex = try self.ctx.createTexture(format, size, size, false, mtl.TextureUsage.shader_read), .size = size };
    }

    fn destroyTexture(self: *Renderer, t: Texture) void {
        if (t.stream) |st| {
            for (st.slots[0..st.count]) |*sl| self.ctx.destroyBuffer(&sl.buffer);
            self.gpa.destroy(st);
        }
        self.ctx.destroyTexture(t.tex);
    }

    fn newTexture(self: *Renderer, width: u32, height: u32, format: TextureFormat, mipmapped: bool, stream: bool) !Texture {
        const f = pixelFormat(format);
        // generateMipmaps wants a colour-renderable format and usage.
        const usage = mtl.TextureUsage.shader_read | (if (mipmapped) mtl.TextureUsage.render_target else 0);
        const tex = try self.ctx.createTexture(f, width, height, mipmapped, usage);
        var t: Texture = .{ .tex = tex, .width = width, .height = height, .format = f, .mipmapped = mipmapped, .generation = self.bumpGeneration() };
        if (stream) {
            t.stream = self.gpa.create(Stream) catch |err| {
                self.ctx.destroyTexture(tex);
                return err;
            };
            t.stream.?.* = .{};
        }
        return t;
    }

    fn bumpGeneration(self: *Renderer) u32 {
        self.texture_generation +%= 1;
        return self.texture_generation;
    }

    fn pixelFormat(format: TextureFormat) NSUInteger {
        return switch (format) {
            .rgba8 => mtl.PixelFormat.rgba8_unorm,
            .bgra8 => mtl.PixelFormat.bgra8_unorm,
        };
    }

    // ---- Textures ---------------------------------------------------------------------------

    /// Uploads (or replaces) image `id` (== draw.TextureId.value). Pixels are straight-alpha
    /// RGBA8/BGRA8, tightly packed; copied now, the GPU copy (plus mips) goes into the next
    /// frame.
    pub fn uploadTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8) !void {
        if (id == 0) return error.InvalidTextureId;
        if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height * 4) return error.InvalidTextureSize;
        const pool = objc.Pool.push();
        defer pool.pop();
        const size = @as(usize, width) * height * 4;
        var staging = try self.ctx.createBuffer(size, mtl.ResourceOptions.shared_write_combined);
        errdefer self.ctx.destroyBuffer(&staging);
        @memcpy(staging.bytes()[0..size], pixels[0..size]);

        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.width == width and old.height == height and old.format == pixelFormat(format) and old.stream == null) {
                gop.value_ptr.generation = self.bumpGeneration();
            } else {
                self.dropPendingUpload(id);
                gop.value_ptr.* = self.newTexture(width, height, format, true, false) catch |err| {
                    _ = self.textures.remove(id);
                    self.destroyTexture(old);
                    return err;
                };
                self.destroyTexture(old);
            }
        } else {
            gop.value_ptr.* = self.newTexture(width, height, format, true, false) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
        }
        self.dropPendingUpload(id);
        try self.pending_uploads.append(self.gpa, .{ .id = id, .staging = staging });
    }

    fn dropPendingUpload(self: *Renderer, id: u32) void {
        var i: usize = 0;
        while (i < self.pending_uploads.items.len) {
            const p = &self.pending_uploads.items[i];
            if (p.id == id) {
                if (p.slot) |si| {
                    if (self.textures.get(id)) |t| if (t.stream) |st| {
                        st.slots[si].pending = false;
                    };
                } else self.ctx.destroyBuffer(&p.staging);
                _ = self.pending_uploads.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Streams a frequently changing image (browser frames, video) into texture `id`; see
    /// the Vulkan backend for the contract: no mips, the texture is kept while size and
    /// format match, staging comes from a per-texture ring, only `options.dirty` is copied
    /// and updates before the next frame merge.
    pub fn streamTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8, options: StreamOptions) !void {
        const stride = try core.checkStream(id, width, height, pixels, options);
        const pool = objc.Pool.push();
        defer pool.pop();

        var fresh = false;
        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.stream == null or old.width != width or old.height != height or old.format != pixelFormat(format)) {
                self.dropPendingUpload(id);
                self.destroyTexture(old);
                gop.value_ptr.* = self.newTexture(width, height, format, false, true) catch |err| {
                    _ = self.textures.remove(id);
                    return err;
                };
                fresh = true;
            }
        } else {
            gop.value_ptr.* = self.newTexture(width, height, format, false, true) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
            fresh = true;
        }
        const tex = gop.value_ptr;
        const st = tex.stream.?;

        var pending_index: ?usize = null;
        var pending_regions: ?[]const TextureRect = null;
        for (self.pending_uploads.items, 0..) |*p, i| if (p.id == id) {
            pending_index = i;
            pending_regions = p.regions[0..p.region_count];
        };
        const merged = core.mergeStreamRegions(width, height, fresh or !tex.ready, pending_regions, options.dirty);
        if (merged.empty() and pending_index == null) return;
        const full_bytes = @as(usize, width) * height * 4;

        var slot_index: u8 = undefined;
        if (pending_index) |pi| {
            slot_index = self.pending_uploads.items[pi].slot.?;
        } else {
            self.pollCompleted();
            slot_index = try self.acquireStreamSlot(st, full_bytes);
        }
        const slot = &st.slots[slot_index];
        merged.pack(slot.buffer.bytes(), pixels, stride, width, height);
        slot.pending = true;

        var up: PendingUpload = .{ .id = id, .staging = slot.buffer, .slot = slot_index, .region_count = @intCast(merged.count) };
        @memcpy(up.regions[0..merged.count], merged.regions[0..merged.count]);
        if (pending_index) |pi| {
            self.pending_uploads.items[pi] = up;
        } else {
            try self.pending_uploads.append(self.gpa, up);
        }
        tex.generation = self.bumpGeneration();
    }

    fn acquireStreamSlot(self: *Renderer, st: *Stream, size: usize) !u8 {
        for (st.slots[0..st.count], 0..) |*sl, i| {
            if (!sl.pending and sl.serial <= self.ctx.completed_serial) return @intCast(i);
        }
        if (st.count < max_stream_slots) {
            const i = st.count;
            st.slots[i] = .{ .buffer = try self.ctx.createBuffer(size, mtl.ResourceOptions.shared_write_combined) };
            st.count += 1;
            return i;
        }
        var oldest: u8 = 0;
        for (st.slots[0..st.count], 0..) |sl, i| {
            if (!sl.pending and sl.serial < st.slots[oldest].serial) oldest = @intCast(i);
        }
        try self.waitSerial(st.slots[oldest].serial);
        return oldest;
    }

    pub fn releaseTexture(self: *Renderer, id: u32) void {
        const kv = self.textures.fetchRemove(id) orelse return;
        self.dropPendingUpload(id);
        self.destroyTexture(kv.value);
    }

    // ---- Completion -------------------------------------------------------------------------

    /// Advances `completed_serial` for frames whose command buffer finished (non-blocking).
    fn pollCompleted(self: *Renderer) void {
        for (self.frames[0..self.frame_count]) |*f| {
            const cmd = f.cmd orelse continue;
            if (f.serial <= self.ctx.completed_serial) continue;
            if (send(NSUInteger, cmd, "status", .{}) >= mtl.CommandBufferStatus.completed) self.ctx.markCompleted(f.serial);
        }
    }

    /// Blocks until submission `serial` finished.
    pub fn waitSerial(self: *Renderer, serial: u64) !void {
        if (serial == 0 or serial <= self.ctx.completed_serial) return;
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.serial == serial) {
                if (f.cmd) |cmd| try waitCommandBuffer(cmd);
                self.ctx.markCompleted(serial);
                return;
            }
        }
        self.waitIdle();
    }

    fn waitIdle(self: *Renderer) void {
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.cmd) |cmd| waitCommandBuffer(cmd) catch {};
        }
        self.ctx.markCompleted(self.ctx.submit_serial);
    }

    fn waitCommandBuffer(cmd: Id) !void {
        send(void, cmd, "waitUntilCompleted", .{});
        if (send(NSUInteger, cmd, "status", .{}) == mtl.CommandBufferStatus.@"error") {
            log.err("command buffer failed: {s}", .{mtl.errorText(send(?Id, cmd, "error", .{}))});
            return error.MetalCommandFailed;
        }
    }

    /// Copies the last frame rendered into `target` to `buffer` (BGRA8, tightly packed) and
    /// waits. Synchronous; for tests, screenshots and tools.
    pub fn readback(self: *Renderer, target: *Target, buffer: Buffer) !void {
        try self.waitSerial(target.last_serial);
        const pool = objc.Pool.push();
        defer pool.pop();
        const cmd = send(?Id, self.ctx.queue, "commandBuffer", .{}) orelse return error.MetalCommandFailed;
        const blit = send(Id, cmd, "blitCommandEncoder", .{});
        mtl.copyTextureToBuffer(blit, target.texture.?, target.width, target.height, buffer.obj.?);
        send(void, blit, "endEncoding", .{});
        send(void, cmd, "commit", .{});
        try waitCommandBuffer(cmd);
    }

    // ---- Frame ------------------------------------------------------------------------------

    /// Renders `batch` into `target`. Skips all GPU work when nothing changed and the target
    /// already shows the previous frame (`stats.skipped`).
    pub fn render(self: *Renderer, target: *Target, batch: *const draw.RenderBatch, options: FrameOptions) !FrameResult {
        return self.renderWith(target, batch, options, null);
    }

    /// `render` plus `post` recorded after the pass in the same command buffer (not run
    /// when the frame is skipped).
    pub fn renderWith(self: *Renderer, target: *Target, batch: *const draw.RenderBatch, options: FrameOptions, post: ?PostPass) !FrameResult {
        const t_start = clock.monotonicTimestampNs();
        var stats: FrameStats = .{ .commands = @intCast(batch.commands.items.len) };
        const width = target.width;
        const height = target.height;

        try self.enc.build(batch, width, height, options.clear, TextureGenerations{ .renderer = self }, &stats);
        const t_built = clock.monotonicTimestampNs();
        stats.build_ns = t_built - t_start;

        const plan = try self.enc.plan(target.last_frame, width, height, options.force_full, self.pending_uploads.items.len > 0, &stats);
        if (plan == .skip) {
            target.last_frame = self.enc.damage_frame;
            stats.total_ns = clock.monotonicTimestampNs() - t_start;
            self.fillMemoryStats(&stats);
            self.last_stats = stats;
            return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = 0 };
        }
        const partial = plan == .partial;

        const pool = objc.Pool.push();
        defer pool.pop();

        // Frame slot: its previous command buffer must be done before reusing its buffers.
        const frame = &self.frames[self.frame_cursor % self.frame_count];
        self.frame_cursor += 1;
        if (frame.cmd) |prev| {
            const t_wait = clock.monotonicTimestampNs();
            waitCommandBuffer(prev) catch {};
            stats.wait_ns = clock.monotonicTimestampNs() - t_wait;
            self.ctx.markCompleted(frame.serial);
            objc.release(prev);
            frame.cmd = null;
        }
        frame.serial = self.ctx.nextSerial();

        const t_upload = clock.monotonicTimestampNs();
        try self.uploadFrameData(frame, &stats);
        const t_encode = clock.monotonicTimestampNs();
        stats.upload_ns = t_encode - t_upload;

        const cmd = objc.retain(send(?Id, self.ctx.queue, "commandBuffer", .{}) orelse return error.MetalCommandFailed);
        frame.cmd = cmd;
        try self.recordUploads(cmd, frame, &stats);
        self.recordPass(cmd, frame, target, options.clear, partial);
        if (post) |p| p.run(p.ctx, cmd, target);
        const t_submit = clock.monotonicTimestampNs();
        stats.encode_ns = t_submit - t_encode;

        send(void, cmd, "commit", .{});
        target.last_frame = self.enc.damage_frame;
        target.last_serial = frame.serial;
        const t_end = clock.monotonicTimestampNs();
        stats.submit_ns = t_end - t_submit;
        stats.total_ns = t_end - t_start;
        self.fillMemoryStats(&stats);
        self.last_stats = stats;
        return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = frame.serial };
    }

    const TextureGenerations = struct {
        renderer: *Renderer,
        pub fn textureGeneration(self: TextureGenerations, id: u32) ?u32 {
            const t = self.renderer.textures.getPtr(id) orelse return null;
            return t.generation;
        }
    };

    fn fillMemoryStats(self: *Renderer, stats: *FrameStats) void {
        self.enc.fillStats(stats, 0);
        stats.gpu_memory = self.ctx.memory;
    }

    fn ensureBuffer(self: *Renderer, b: *Buffer, need: usize) !void {
        if (b.obj != null and b.size >= need) return;
        var cap: usize = @max(b.size, 64 * 1024);
        while (cap < need) cap *= 2;
        self.ctx.destroyBuffer(b);
        b.* = try self.ctx.createBuffer(cap, mtl.ResourceOptions.shared_write_combined);
    }

    fn uploadFrameData(self: *Renderer, frame: *Frame, stats: *FrameStats) !void {
        const instances = self.enc.instances.items;
        const inst_bytes = instances.len * @sizeOf(Instance);
        try self.ensureBuffer(&frame.instances, inst_bytes);
        if (inst_bytes > 0) @memcpy(frame.instances.bytes()[0..inst_bytes], std.mem.sliceAsBytes(instances));
        const glyph_cache = &self.enc.glyph_cache;
        const glyph_bytes = glyph_cache.upload_bytes.items.len;
        if (glyph_bytes > 0) {
            try self.ensureBuffer(&frame.staging, glyph_bytes);
            @memcpy(frame.staging.bytes()[0..glyph_bytes], glyph_cache.upload_bytes.items);
        }
        stats.glyph_uploads = @intCast(glyph_cache.uploads.items.len);
    }

    fn recordUploads(self: *Renderer, cmd: Id, frame: *Frame, stats: *FrameStats) !void {
        const glyph_cache = &self.enc.glyph_cache;
        var grow = false;
        for (&self.atlases, 0..) |*a, ki| {
            if (glyph_cache.atlasSize(@enumFromInt(ki)) != a.size) grow = true;
        }
        if (self.pending_uploads.items.len == 0 and glyph_cache.uploads.items.len == 0 and !grow) return;

        const blit = send(Id, cmd, "blitCommandEncoder", .{});
        defer send(void, blit, "endEncoding", .{});

        // Textures.
        for (self.pending_uploads.items) |*p| {
            const tex: *Texture = if (p.id == 0) &self.dummy.? else self.textures.getPtr(p.id) orelse {
                if (p.slot == null) self.ctx.destroyBuffer(&p.staging);
                continue;
            };
            const staging = p.staging.obj.?;
            if (p.slot != null and p.region_count > 0) {
                var off: usize = 0;
                for (p.regions[0..p.region_count]) |r| {
                    mtl.copyBufferToTexture(blit, staging, off, @as(usize, r.w) * 4, r.w, r.h, tex.tex, r.x, r.y);
                    off += @as(usize, r.w) * r.h * 4;
                }
                stats.texture_upload_bytes += off;
            } else {
                mtl.copyBufferToTexture(blit, staging, 0, @as(usize, tex.width) * 4, tex.width, tex.height, tex.tex, 0, 0);
                stats.texture_upload_bytes += @as(u64, tex.width) * tex.height * 4;
                if (tex.mipmapped and mtl.mipLevels(tex.tex) > 1) send(void, blit, "generateMipmapsForTexture:", .{tex.tex});
            }
            tex.ready = true;
            if (p.slot) |si| {
                const st = tex.stream.?;
                st.slots[si].pending = false;
                st.slots[si].serial = frame.serial;
            } else self.ctx.destroyBuffer(&p.staging);
            if (p.id != 0) stats.texture_uploads += 1;
        }
        self.pending_uploads.clearRetainingCapacity();

        // Glyph atlases: grow by copy, then the new glyphs.
        for (&self.atlases, 0..) |*a, ki| {
            const kind: text.AtlasKind = @enumFromInt(ki);
            const want = glyph_cache.atlasSize(kind);
            if (want != a.size) {
                const old = a.*;
                try self.createAtlas(kind, want);
                if (old.initialized) {
                    const n = @min(old.size, want);
                    mtl.copyTextureRegion(blit, old.tex.?, a.tex.?, 0, 0, n, n);
                    a.initialized = true;
                }
                if (old.tex) |t| self.ctx.destroyTexture(t);
            }
            const bpp: usize = if (kind == .coverage) 1 else 4;
            for (glyph_cache.uploads.items) |u| {
                if (u.kind != kind or u.w == 0 or u.h == 0) continue;
                mtl.copyBufferToTexture(blit, frame.staging.obj.?, u.offset, u.w * bpp, u.w, u.h, a.tex.?, u.x, u.y);
                a.initialized = true;
            }
        }
        glyph_cache.clearUploads();
    }

    fn recordPass(self: *Renderer, cmd: Id, frame: *Frame, target: *Target, clear: draw.Color, partial: bool) void {
        const cc = core.premultipliedClear(clear);
        const rp = send(Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const att = send(Id, send(Id, rp, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(NSUInteger, 0)});
        send(void, att, "setTexture:", .{target.texture.?});
        send(void, att, "setLoadAction:", .{if (partial) mtl.LoadAction.load else mtl.LoadAction.clear});
        send(void, att, "setStoreAction:", .{mtl.store_action_store});
        send(void, att, "setClearColor:", .{mtl.ClearColor{ .red = cc[0], .green = cc[1], .blue = cc[2], .alpha = cc[3] }});
        const re = send(Id, cmd, "renderCommandEncoderWithDescriptor:", .{rp});
        defer send(void, re, "endEncoding", .{});

        send(void, re, "setViewport:", .{mtl.Viewport{ .originX = 0, .originY = 0, .width = @floatFromInt(target.width), .height = @floatFromInt(target.height), .znear = 0, .zfar = 1 }});
        const push: Push = .{
            .ndc_scale = .{ 2.0 / @as(f32, @floatFromInt(target.width)), 2.0 / @as(f32, @floatFromInt(target.height)) },
            .flags = self.enc.shaderFlags(),
        };
        const clear_color: [4]f32 = cc;

        var scissors: [damage.max_rects]mtl.ScissorRect = undefined;
        var n: usize = 0;
        if (partial) {
            for (self.enc.damage_out.items) |r| {
                const x0: u32 = @intCast(std.math.clamp(r.x, 0, @as(i32, @intCast(target.width))));
                const y0: u32 = @intCast(std.math.clamp(r.y, 0, @as(i32, @intCast(target.height))));
                const x1: u32 = @intCast(std.math.clamp(r.x + r.w, 0, @as(i32, @intCast(target.width))));
                const y1: u32 = @intCast(std.math.clamp(r.y + r.h, 0, @as(i32, @intCast(target.height))));
                if (x1 <= x0 or y1 <= y0) continue;
                scissors[n] = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
                n += 1;
            }
        } else {
            scissors[0] = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
            n = 1;
        }

        const have_instances = self.enc.instances.items.len > 0;
        for (scissors[0..n]) |sc| {
            send(void, re, "setScissorRect:", .{sc});
            if (partial) {
                send(void, re, "setRenderPipelineState:", .{self.clear_pipeline.?});
                send(void, re, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &clear_color), @as(NSUInteger, @sizeOf([4]f32)), @as(NSUInteger, 0) });
                send(void, re, "drawPrimitives:vertexStart:vertexCount:", .{ mtl.primitive_triangle_strip, @as(NSUInteger, 0), @as(NSUInteger, 4) });
            }
            if (!have_instances) continue;
            send(void, re, "setRenderPipelineState:", .{self.pipeline.?});
            send(void, re, "setVertexBuffer:offset:atIndex:", .{ frame.instances.obj.?, @as(NSUInteger, 0), @as(NSUInteger, 0) });
            send(void, re, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &push), @as(NSUInteger, @sizeOf(Push)), @as(NSUInteger, 1) });
            send(void, re, "setFragmentBytes:length:atIndex:", .{ @as(*const anyopaque, &push), @as(NSUInteger, @sizeOf(Push)), @as(NSUInteger, 1) });
            send(void, re, "setFragmentTexture:atIndex:", .{ self.atlases[0].tex.?, @as(NSUInteger, 0) });
            send(void, re, "setFragmentTexture:atIndex:", .{ self.atlases[1].tex.?, @as(NSUInteger, 1) });
            var bound: ?Id = null;
            for (self.enc.runs.items) |d| {
                if (d.count == 0) continue;
                const tex = self.runTexture(d.texture);
                if (bound == null or bound.? != tex) {
                    send(void, re, "setFragmentTexture:atIndex:", .{ tex, @as(NSUInteger, 2) });
                    bound = tex;
                }
                send(void, re, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
                    mtl.primitive_triangle_strip, @as(NSUInteger, 0),       @as(NSUInteger, 4),
                    @as(NSUInteger, d.count),     @as(NSUInteger, d.first),
                });
            }
        }
    }

    fn runTexture(self: *Renderer, id: u32) Id {
        if (id != 0) if (self.textures.getPtr(id)) |t| return t.tex;
        return self.dummy.?.tex;
    }
};

pub const packColor = core.packColor;
pub const snapRectToPixelGrid = core.snapRectToPixelGrid;
pub const strokePixelWidth = core.strokePixelWidth;
pub const clampedRadius = core.clampedRadius;
