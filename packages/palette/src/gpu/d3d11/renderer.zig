//! Palette's Direct3D 11 renderer: `draw.RenderBatch` -> one instanced draw per texture run.
//!
//! Mirrors `../vulkan/renderer.zig` on top of the shared `../core.zig` encoder (instances,
//! runs, glyph atlas packing, damage, full/partial/skip plan, stream-region merging):
//!
//! * pipeline: `shaders/ui.hlsl` (precompiled DXBC), 4-vertex strip per instance, blend
//!   ONE / INV_SRC_ALPHA (premultiplied), scissor for damage-limited redraws
//! * instances: one dynamic vertex buffer used as a ring (WRITE_NO_OVERWRITE appends,
//!   WRITE_DISCARD when it wraps), so steady-state frames allocate nothing
//! * glyph atlases: R8 coverage + RGBA8 colour, `UpdateSubresource` per new glyph, grown by
//!   copying the old contents (texel coordinates stay valid)
//! * images: RGBA8/BGRA8 with a full mip chain (`GenerateMips`), trilinear + clamp
//! * streamed textures (`streamTexture`): no mips; dirty rectangles are written into a small
//!   ring of persistent STAGING textures and copied with `CopySubresourceRegion` when the
//!   next frame is recorded (no per-frame allocation)
//! * serials: an event query per submitted frame (`Context.submit`)
const std = @import("std");
const draw = @import("../../draw.zig");
const com = @import("com.zig");
const context = @import("context.zig");
const core = @import("../core.zig");
const text = @import("../text.zig");
const damage = @import("../damage.zig");
const clock = @import("../../clock.zig");

const Context = context.Context;

pub const Instance = core.Instance;
pub const Options = core.Options;
pub const TextureFormat = core.TextureFormat;
pub const FrameStats = core.FrameStats;
pub const FrameOptions = core.FrameOptions;
pub const FrameResult = core.FrameResult;
pub const TextureRect = core.TextureRect;
pub const StreamOptions = core.StreamOptions;

/// Colour format of every render target (offscreen and swapchain).
pub const target_format: com.DXGI_FORMAT = .b8g8r8a8_unorm;

const vs_dxbc = @embedFile("shaders/ui_vs.dxbc");
const ps_dxbc = @embedFile("shaders/ui_ps.dxbc");

/// Something the renderer draws into (an offscreen texture or a swapchain back buffer).
pub const Target = struct {
    rtv: ?*com.RenderTargetView = null,
    width: u32 = 0,
    height: u32 = 0,
    /// Damage-history frame index of the last render into this target (0 = undefined).
    last_frame: u64 = 0,
    last_serial: u64 = 0,

    pub fn invalidate(self: *Target) void {
        self.last_frame = 0;
    }
};

const Texture = struct {
    tex: *com.Texture2D,
    srv: *com.ShaderResourceView,
    width: u32,
    height: u32,
    format: com.DXGI_FORMAT,
    generation: u32,
    ready: bool = false,
    stream: ?*Stream = null,
};

/// Persistent staging ring of one streamed texture. A slot is writable when it holds no
/// unrecorded update and the frame that last copied from it completed.
const Stream = struct {
    slots: [core.max_stream_slots]Slot = @splat(.{}),
    count: u8 = 0,
    /// Unrecorded update: slot + regions (count 0 = whole texture).
    pending: ?u8 = null,
    region_count: u8 = 0,
    regions: [core.max_stream_regions]TextureRect = undefined,

    const Slot = struct {
        tex: ?*com.Texture2D = null,
        serial: u64 = 0,
    };
};

const Atlas = struct {
    tex: ?*com.Texture2D = null,
    srv: ?*com.ShaderResourceView = null,
    size: u32 = 0,
    format: com.DXGI_FORMAT,
};

const instance_ring_min: u32 = 256 * 1024;

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    ctx: *Context,
    options: Options,

    vs: ?*com.VertexShader = null,
    ps: ?*com.PixelShader = null,
    layout: ?*com.InputLayout = null,
    blend: ?*com.BlendState = null,
    no_blend: ?*com.BlendState = null,
    raster: ?*com.RasterizerState = null,
    sampler: ?*com.SamplerState = null,
    push: ?*com.Buffer = null,
    push_value: [4]u32 = .{ 0, 0, 0, 0xffff_ffff },

    ring: ?*com.Buffer = null,
    ring_desc: com.BUFFER_DESC = undefined,
    ring_cursor: u32 = 0,

    atlases: [2]Atlas = .{ .{ .format = .r8_unorm }, .{ .format = .r8g8b8a8_unorm } },

    textures: std.AutoHashMapUnmanaged(u32, Texture) = .empty,
    dummy: ?Texture = null,
    texture_generation: u32 = 0,
    /// Streamed textures with an unrecorded update.
    pending_streams: std.ArrayList(u32) = .empty,
    /// One-shot uploads issued since the last recorded frame (for stats).
    upload_count: u32 = 0,
    upload_bytes: u64 = 0,

    enc: core.Encoder,
    last_stats: FrameStats = .{},

    pub fn init(gpa: std.mem.Allocator, ctx: *Context, options: Options) !*Renderer {
        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .ctx = ctx, .options = options, .enc = .init(gpa, options) };
        errdefer self.deinit();
        try self.createPipeline();
        try self.createAtlas(.coverage, self.enc.glyph_cache.atlasSize(.coverage));
        try self.createAtlas(.color, self.enc.glyph_cache.atlasSize(.color));
        {
            const white = [4]u8{ 255, 255, 255, 255 };
            const data = [_]com.SUBRESOURCE_DATA{.{ .pSysMem = &white, .SysMemPitch = 4 }};
            const tex = try ctx.createTexture(.{ .Width = 1, .Height = 1, .Format = .r8g8b8a8_unorm, .Usage = com.USAGE_IMMUTABLE, .BindFlags = com.BIND_SHADER_RESOURCE }, &data);
            self.dummy = .{ .tex = tex, .srv = try ctx.srv(tex), .width = 1, .height = 1, .format = .r8g8b8a8_unorm, .generation = 0, .ready = true };
        }
        if (options.glyph_source) |source| self.setGlyphSource(source);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const ctx = self.ctx;
        ctx.dc.ClearState();
        var it = self.textures.valueIterator();
        while (it.next()) |t| self.destroyTexture(t.*);
        self.textures.deinit(self.gpa);
        if (self.dummy) |d| self.destroyTexture(d);
        self.pending_streams.deinit(self.gpa);
        for (&self.atlases) |*a| {
            com.clear(&a.srv);
            if (a.tex) |t| ctx.destroyTexture(t);
        }
        if (self.ring) |r| ctx.destroyBuffer(r, self.ring_desc);
        if (self.push) |p| ctx.destroyBuffer(p, pushDesc());
        com.clear(&self.vs);
        com.clear(&self.ps);
        com.clear(&self.layout);
        com.clear(&self.blend);
        com.clear(&self.no_blend);
        com.clear(&self.raster);
        com.clear(&self.sampler);
        self.enc.deinit();
        self.gpa.destroy(self);
    }

    pub fn setGlyphSource(self: *Renderer, source: text.GlyphSource) void {
        self.enc.setGlyphSource(source);
    }

    pub fn lastFrameStats(self: *const Renderer) FrameStats {
        return self.last_stats;
    }

    pub fn waitSerial(self: *Renderer, serial: u64) !void {
        self.ctx.waitSerial(serial);
    }

    // ---- Setup ------------------------------------------------------------------------------

    fn pushDesc() com.BUFFER_DESC {
        return .{ .ByteWidth = 16, .Usage = com.USAGE_DYNAMIC, .BindFlags = com.BIND_CONSTANT_BUFFER, .CPUAccessFlags = com.CPU_ACCESS_WRITE };
    }

    fn createPipeline(self: *Renderer) !void {
        const dev = self.ctx.device;
        try com.check(dev.CreateVertexShader(vs_dxbc, vs_dxbc.len, null, &self.vs));
        try com.check(dev.CreatePixelShader(ps_dxbc, ps_dxbc.len, null, &self.ps));
        const elems = [_]com.INPUT_ELEMENT_DESC{
            .{ .SemanticName = "RECT", .Format = .r32g32b32a32_float, .AlignedByteOffset = 0 },
            .{ .SemanticName = "CLIP", .Format = .r32g32b32a32_float, .AlignedByteOffset = 16 },
            .{ .SemanticName = "UV", .Format = .r32g32b32a32_float, .AlignedByteOffset = 32 },
            .{ .SemanticName = "MISC", .Format = .r32g32b32a32_uint, .AlignedByteOffset = 48 },
        };
        try com.check(dev.CreateInputLayout(&elems, elems.len, vs_dxbc, vs_dxbc.len, &self.layout));
        var blend: com.BLEND_DESC = .{};
        blend.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = com.BLEND_ONE,
            .DestBlend = com.BLEND_INV_SRC_ALPHA,
            .SrcBlendAlpha = com.BLEND_ONE,
            .DestBlendAlpha = com.BLEND_INV_SRC_ALPHA,
        };
        try com.check(dev.CreateBlendState(&blend, &self.blend));
        const opaque_blend: com.BLEND_DESC = .{};
        try com.check(dev.CreateBlendState(&opaque_blend, &self.no_blend));
        const raster: com.RASTERIZER_DESC = .{};
        try com.check(dev.CreateRasterizerState(&raster, &self.raster));
        // Images: trilinear (anisotropic like the Vulkan backend), clamp to edge.
        const sampler: com.SAMPLER_DESC = .{ .Filter = com.FILTER_ANISOTROPIC, .MaxAnisotropy = 8 };
        try com.check(dev.CreateSamplerState(&sampler, &self.sampler));
        self.push = try self.ctx.createBuffer(pushDesc());
    }

    fn createAtlas(self: *Renderer, kind: text.AtlasKind, size: u32) !void {
        const a = &self.atlases[@intFromEnum(kind)];
        const tex = try self.ctx.createTexture(.{ .Width = size, .Height = size, .Format = a.format, .BindFlags = com.BIND_SHADER_RESOURCE }, null);
        errdefer self.ctx.destroyTexture(tex);
        const view = try self.ctx.srv(tex);
        if (a.tex) |old| {
            // Growth keeps texel coordinates: copy the old atlas into the top-left corner.
            const box: com.BOX = .{ .left = 0, .top = 0, .right = a.size, .bottom = a.size };
            self.ctx.dc.CopySubresourceRegion(tex.resource(), 0, 0, 0, 0, old.resource(), 0, &box);
            com.clear(&a.srv);
            self.ctx.destroyTexture(old);
        }
        a.* = .{ .tex = tex, .srv = view, .size = size, .format = a.format };
    }

    fn destroyTexture(self: *Renderer, t: Texture) void {
        if (t.stream) |st| {
            for (st.slots[0..st.count]) |sl| if (sl.tex) |s| self.ctx.destroyTexture(s);
            self.gpa.destroy(st);
        }
        _ = t.srv.Release();
        self.ctx.destroyTexture(t.tex);
    }

    fn dxgiFormat(format: TextureFormat) com.DXGI_FORMAT {
        return switch (format) {
            .rgba8 => .r8g8b8a8_unorm,
            .bgra8 => .b8g8r8a8_unorm,
        };
    }

    // ---- Textures ---------------------------------------------------------------------------

    /// Uploads (or replaces) image `id` with a full mip chain. Straight-alpha RGBA8/BGRA8,
    /// tightly packed. The copy happens immediately (D3D11 queues it on the context).
    pub fn uploadTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8) !void {
        if (id == 0) return error.InvalidTextureId;
        if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height * 4) return error.InvalidTextureSize;
        const fmt = dxgiFormat(format);
        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.stream != null or old.width != width or old.height != height or old.format != fmt) {
                self.dropPendingStream(id);
                self.destroyTexture(old);
                gop.value_ptr.* = self.createImage(width, height, fmt, true) catch |err| {
                    _ = self.textures.remove(id);
                    return err;
                };
            }
        } else {
            gop.value_ptr.* = self.createImage(width, height, fmt, true) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
        }
        const t = gop.value_ptr;
        const dc = self.ctx.dc;
        dc.UpdateSubresource(t.tex.resource(), 0, null, pixels.ptr, width * 4, 0);
        dc.GenerateMips(t.srv);
        t.ready = true;
        self.texture_generation +%= 1;
        t.generation = self.texture_generation;
        self.upload_count += 1;
        self.upload_bytes += @as(u64, width) * height * 4;
    }

    fn createImage(self: *Renderer, width: u32, height: u32, fmt: com.DXGI_FORMAT, mips: bool) !Texture {
        const levels: u32 = if (mips) std.math.log2_int(u32, @max(width, height)) + 1 else 1;
        var desc: com.TEXTURE2D_DESC = .{ .Width = width, .Height = height, .MipLevels = levels, .Format = fmt, .BindFlags = com.BIND_SHADER_RESOURCE };
        if (levels > 1) {
            desc.BindFlags |= com.BIND_RENDER_TARGET;
            desc.MiscFlags = com.RESOURCE_MISC_GENERATE_MIPS;
        }
        const tex = try self.ctx.createTexture(desc, null);
        errdefer self.ctx.destroyTexture(tex);
        self.texture_generation +%= 1;
        return .{ .tex = tex, .srv = try self.ctx.srv(tex), .width = width, .height = height, .format = fmt, .generation = self.texture_generation };
    }

    fn dropPendingStream(self: *Renderer, id: u32) void {
        for (self.pending_streams.items, 0..) |p, i| if (p == id) {
            _ = self.pending_streams.swapRemove(i);
            return;
        };
    }

    /// Streams a frequently changing image into texture `id` (see the Vulkan backend for the
    /// contract): no mips, the texture and the staging ring are reused while the size and
    /// format stay the same, only `options.dirty` is copied, updates before the next frame
    /// merge (newest pixels win).
    pub fn streamTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8, options: StreamOptions) !void {
        const stride = try core.checkStream(id, width, height, pixels, options);
        const fmt = dxgiFormat(format);
        var fresh = false;
        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.stream == null or old.width != width or old.height != height or old.format != fmt) {
                self.dropPendingStream(id);
                self.destroyTexture(old);
                gop.value_ptr.* = self.createStreamTexture(width, height, fmt) catch |err| {
                    _ = self.textures.remove(id);
                    return err;
                };
                fresh = true;
            }
        } else {
            gop.value_ptr.* = self.createStreamTexture(width, height, fmt) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
            fresh = true;
        }
        const tex = gop.value_ptr;
        const st = tex.stream.?;

        const pending_regions: ?[]const TextureRect = if (st.pending != null) st.regions[0..st.region_count] else null;
        const merged = core.mergeStreamRegions(width, height, fresh or !tex.ready, pending_regions, options.dirty);
        if (merged.empty() and st.pending == null) return;

        const slot_index = st.pending orelse try self.acquireStreamSlot(st, width, height, fmt);
        const staging = st.slots[slot_index].tex.?;
        var mapped: com.MAPPED_SUBRESOURCE = .{};
        try com.check(self.ctx.dc.Map(staging.resource(), 0, com.MAP_WRITE, 0, &mapped));
        const dst = mapped.pData.?;
        const pitch: usize = mapped.RowPitch;
        // Regions land at their own coordinates (the staging texture is full size), so a
        // merged update only rewrites the new rectangles.
        const write_full = merged.full;
        const regs: []const TextureRect = if (write_full) &.{.{ .x = 0, .y = 0, .w = width, .h = height }} else options.dirty;
        for (regs) |r0| {
            const r = core.clampRect(r0, width, height) orelse continue;
            var y: usize = 0;
            while (y < r.h) : (y += 1) {
                const row = @as(usize, r.y) + y;
                const n = @as(usize, r.w) * 4;
                @memcpy(dst[row * pitch + @as(usize, r.x) * 4 ..][0..n], pixels[row * stride + @as(usize, r.x) * 4 ..][0..n]);
            }
        }
        self.ctx.dc.Unmap(staging.resource(), 0);

        if (st.pending == null) try self.pending_streams.append(self.gpa, id);
        st.pending = slot_index;
        st.region_count = @intCast(merged.count);
        @memcpy(st.regions[0..merged.count], merged.regions[0..merged.count]);
        self.texture_generation +%= 1;
        tex.generation = self.texture_generation;
    }

    fn createStreamTexture(self: *Renderer, width: u32, height: u32, fmt: com.DXGI_FORMAT) !Texture {
        var t = try self.createImage(width, height, fmt, false);
        errdefer self.destroyTexture(t);
        t.stream = try self.gpa.create(Stream);
        t.stream.?.* = .{};
        return t;
    }

    fn acquireStreamSlot(self: *Renderer, st: *Stream, width: u32, height: u32, fmt: com.DXGI_FORMAT) !u8 {
        self.ctx.pollCompleted();
        for (st.slots[0..st.count], 0..) |sl, i| {
            if (sl.serial <= self.ctx.completed_serial) return @intCast(i);
        }
        if (st.count < core.max_stream_slots) {
            const i = st.count;
            st.slots[i] = .{ .tex = try self.ctx.createTexture(.{ .Width = width, .Height = height, .Format = fmt, .Usage = com.USAGE_STAGING, .CPUAccessFlags = com.CPU_ACCESS_WRITE }, null) };
            st.count += 1;
            return i;
        }
        var oldest: u8 = 0;
        for (st.slots[0..st.count], 0..) |sl, i| {
            if (sl.serial < st.slots[oldest].serial) oldest = @intCast(i);
        }
        self.ctx.waitSerial(st.slots[oldest].serial);
        return oldest;
    }

    pub fn releaseTexture(self: *Renderer, id: u32) void {
        const kv = self.textures.fetchRemove(id) orelse return;
        self.dropPendingStream(id);
        self.destroyTexture(kv.value);
    }

    // ---- Frame ------------------------------------------------------------------------------

    const TextureGenerations = struct {
        renderer: *Renderer,
        pub fn textureGeneration(self: TextureGenerations, id: u32) ?u32 {
            const t = self.renderer.textures.getPtr(id) orelse return null;
            return t.generation;
        }
    };

    /// Renders `batch` into `target`; skips all GPU work when nothing changed and the target
    /// already shows the previous frame.
    pub fn render(self: *Renderer, target: *Target, batch: *const draw.RenderBatch, options: FrameOptions) !FrameResult {
        const t_start = clock.monotonicTimestampNs();
        var stats: FrameStats = .{ .commands = @intCast(batch.commands.items.len) };
        const width = target.width;
        const height = target.height;
        try self.enc.build(batch, width, height, options.clear, TextureGenerations{ .renderer = self }, &stats);
        const t_built = clock.monotonicTimestampNs();
        stats.build_ns = t_built - t_start;

        const plan = try self.enc.plan(target.last_frame, width, height, options.force_full, self.pending_streams.items.len > 0, &stats);
        if (plan == .skip) {
            target.last_frame = self.enc.damage_frame;
            stats.total_ns = clock.monotonicTimestampNs() - t_start;
            self.fillMemoryStats(&stats);
            self.last_stats = stats;
            return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = 0 };
        }

        // Uploads: streamed textures, glyphs, instances.
        const t_upload = clock.monotonicTimestampNs();
        self.recordStreams(&stats);
        stats.texture_uploads += self.upload_count;
        stats.texture_upload_bytes += self.upload_bytes;
        self.upload_count = 0;
        self.upload_bytes = 0;
        try self.uploadGlyphs(&stats);
        const n_clear: u32 = if (plan == .partial) @intCast(self.enc.damage_out.items.len) else 0;
        const base = try self.uploadInstances(options.clear, n_clear);
        const t_encode = clock.monotonicTimestampNs();
        stats.upload_ns = t_encode - t_upload;

        self.recordPass(target, base, plan == .partial, options.clear);
        const t_submit = clock.monotonicTimestampNs();
        stats.encode_ns = t_submit - t_encode;
        const serial = self.ctx.submit();
        target.last_frame = self.enc.damage_frame;
        target.last_serial = serial;
        const t_end = clock.monotonicTimestampNs();
        stats.submit_ns = t_end - t_submit;
        stats.total_ns = t_end - t_start;
        self.fillMemoryStats(&stats);
        self.last_stats = stats;
        return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = serial };
    }

    fn fillMemoryStats(self: *Renderer, stats: *FrameStats) void {
        self.enc.fillStats(stats, 0);
        stats.gpu_memory = self.ctx.memory;
    }

    fn recordStreams(self: *Renderer, stats: *FrameStats) void {
        const dc = self.ctx.dc;
        // The copies below belong to the submission `render` is about to end.
        const serial = self.ctx.submit_serial + 1;
        for (self.pending_streams.items) |id| {
            const tex = self.textures.getPtr(id) orelse continue;
            const st = tex.stream orelse continue;
            const si = st.pending orelse continue;
            const staging = st.slots[si].tex.?;
            if (st.region_count == 0) {
                dc.CopyResource(tex.tex.resource(), staging.resource());
                stats.texture_upload_bytes += @as(u64, tex.width) * tex.height * 4;
            } else for (st.regions[0..st.region_count]) |r| {
                const box: com.BOX = .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
                dc.CopySubresourceRegion(tex.tex.resource(), 0, r.x, r.y, 0, staging.resource(), 0, &box);
                stats.texture_upload_bytes += @as(u64, r.w) * r.h * 4;
            }
            st.slots[si].serial = serial;
            st.pending = null;
            st.region_count = 0;
            tex.ready = true;
            stats.texture_uploads += 1;
        }
        self.pending_streams.clearRetainingCapacity();
    }

    fn uploadGlyphs(self: *Renderer, stats: *FrameStats) !void {
        const cache = &self.enc.glyph_cache;
        for (&self.atlases, 0..) |*a, ki| {
            const kind: text.AtlasKind = @enumFromInt(ki);
            const want = cache.atlasSize(kind);
            if (want != a.size) try self.createAtlas(kind, want);
        }
        const dc = self.ctx.dc;
        for (cache.uploads.items) |u| {
            if (u.w == 0 or u.h == 0) continue;
            const a = &self.atlases[@intFromEnum(u.kind)];
            const bpp: u32 = if (u.kind == .coverage) 1 else 4;
            const box: com.BOX = .{ .left = u.x, .top = u.y, .right = u.x + u.w, .bottom = u.y + u.h };
            dc.UpdateSubresource(a.tex.?.resource(), 0, &box, cache.upload_bytes.items[u.offset..].ptr, u.w * bpp, 0);
        }
        stats.glyph_uploads = @intCast(cache.uploads.items.len);
        cache.clearUploads();
    }

    /// Copies this frame's instances (+ one clear quad per damage rect) into the ring.
    /// Returns the byte offset of the first instance.
    fn uploadInstances(self: *Renderer, clear: draw.Color, n_clear: u32) !u32 {
        const instances = self.enc.instances.items;
        const count: u32 = @intCast(instances.len + n_clear);
        const bytes: u32 = count * @sizeOf(Instance);
        if (bytes == 0) return 0;
        if (self.ring == null or bytes > self.ring_desc.ByteWidth) {
            var cap: u32 = if (self.ring) |_| self.ring_desc.ByteWidth else instance_ring_min;
            while (cap < bytes) cap *= 2;
            if (self.ring) |r| self.ctx.destroyBuffer(r, self.ring_desc);
            self.ring = null;
            self.ring_desc = .{ .ByteWidth = cap, .Usage = com.USAGE_DYNAMIC, .BindFlags = com.BIND_VERTEX_BUFFER, .CPUAccessFlags = com.CPU_ACCESS_WRITE };
            self.ring = try self.ctx.createBuffer(self.ring_desc);
            self.ring_cursor = self.ring_desc.ByteWidth; // force DISCARD on first use
        }
        const ring = self.ring.?;
        var map_type = com.MAP_WRITE_NO_OVERWRITE;
        if (self.ring_cursor + bytes > self.ring_desc.ByteWidth) {
            map_type = com.MAP_WRITE_DISCARD;
            self.ring_cursor = 0;
        }
        var mapped: com.MAPPED_SUBRESOURCE = .{};
        try com.check(self.ctx.dc.Map(ring.resource(), 0, map_type, 0, &mapped));
        const dst: [*]Instance = @ptrCast(@alignCast(mapped.pData.? + self.ring_cursor));
        @memcpy(dst[0..instances.len], instances);
        if (n_clear > 0) {
            const c = core.packColor(clear);
            for (self.enc.damage_out.items, 0..) |r, i| {
                const x: f32 = @floatFromInt(r.x);
                const y: f32 = @floatFromInt(r.y);
                dst[instances.len + i] = .{
                    .rect = .{ x, y, @floatFromInt(r.w), @floatFromInt(r.h) },
                    .clip = .{ -1e7, -1e7, 1e7, 1e7 },
                    .uv = .{ 0, 0, 0, 0 },
                    .misc = .{ c, 0, 0, @intFromEnum(core.Kind.quad) },
                };
            }
        }
        self.ctx.dc.Unmap(ring.resource(), 0);
        const base = self.ring_cursor;
        self.ring_cursor += bytes;
        return base;
    }

    fn setPush(self: *Renderer, width: u32, height: u32) void {
        const value = [4]u32{
            @bitCast(2.0 / @as(f32, @floatFromInt(width))),
            @bitCast(2.0 / @as(f32, @floatFromInt(height))),
            self.enc.shaderFlags(),
            0,
        };
        if (std.mem.eql(u32, &value, &self.push_value)) return;
        var mapped: com.MAPPED_SUBRESOURCE = .{};
        if (!com.succeeded(self.ctx.dc.Map(self.push.?.resource(), 0, com.MAP_WRITE_DISCARD, 0, &mapped))) return;
        @memcpy(mapped.pData.?[0..16], std.mem.asBytes(&value));
        self.ctx.dc.Unmap(self.push.?.resource(), 0);
        self.push_value = value;
    }

    fn recordPass(self: *Renderer, target: *Target, base: u32, partial: bool, clear: draw.Color) void {
        const dc = self.ctx.dc;
        const rtv = [_]?*com.RenderTargetView{target.rtv};
        dc.OMSetRenderTargets(1, &rtv, null);
        const vp = [_]com.VIEWPORT{.{ .Width = @floatFromInt(target.width), .Height = @floatFromInt(target.height) }};
        dc.RSSetViewports(1, &vp);
        dc.RSSetState(self.raster);
        self.setPush(target.width, target.height);
        dc.VSSetShader(self.vs);
        dc.PSSetShader(self.ps);
        const cb = [_]?*com.Buffer{self.push};
        dc.VSSetConstantBuffers(0, 1, &cb);
        dc.PSSetConstantBuffers(0, 1, &cb);
        dc.IASetInputLayout(self.layout);
        dc.IASetPrimitiveTopology(com.PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        const vbs = [_]?*com.Buffer{self.ring};
        const strides = [_]u32{@sizeOf(Instance)};
        const offsets = [_]u32{base};
        dc.IASetVertexBuffers(0, 1, &vbs, &strides, &offsets);
        const samplers = [_]?*com.SamplerState{self.sampler};
        dc.PSSetSamplers(0, 1, &samplers);
        const atlas_views = [_]?*com.ShaderResourceView{ self.atlases[0].srv, self.atlases[1].srv };
        dc.PSSetShaderResources(0, 2, &atlas_views);

        var scissors: [damage.max_rects]com.RECT = undefined;
        var n: usize = 0;
        const n_inst: u32 = @intCast(self.enc.instances.items.len);
        if (partial) {
            // Clear each damage rect with an unblended quad (the instances after the batch).
            dc.OMSetBlendState(self.no_blend, null, 0xffff_ffff);
            self.bindImage(0);
            for (self.enc.damage_out.items, 0..) |r, i| {
                if (r.w <= 0 or r.h <= 0) continue;
                scissors[n] = .{ .left = r.x, .top = r.y, .right = r.x + r.w, .bottom = r.y + r.h };
                dc.RSSetScissorRects(1, scissors[n..].ptr);
                dc.DrawInstanced(4, 1, 0, n_inst + @as(u32, @intCast(i)));
                n += 1;
            }
        } else {
            const full: com.RECT = .{ .left = 0, .top = 0, .right = @intCast(target.width), .bottom = @intCast(target.height) };
            scissors[0] = full;
            n = 1;
            if (target.rtv) |view| dc.ClearRenderTargetView(view, &core.premultipliedClear(clear));
        }
        dc.OMSetBlendState(self.blend, null, 0xffff_ffff);
        for (scissors[0..n]) |*sc| {
            dc.RSSetScissorRects(1, @ptrCast(sc));
            var bound: ?u32 = null;
            for (self.enc.runs.items) |d| {
                if (d.count == 0) continue;
                if (bound != d.texture) {
                    self.bindImage(d.texture);
                    bound = d.texture;
                }
                dc.DrawInstanced(4, d.count, 0, d.first);
            }
        }
        // Unbind the target so it can be copied / presented / resized.
        dc.OMSetRenderTargets(0, null, null);
    }

    fn bindImage(self: *Renderer, id: u32) void {
        var view: ?*com.ShaderResourceView = self.dummy.?.srv;
        if (id != 0) if (self.textures.getPtr(id)) |t| {
            view = t.srv;
        };
        const views = [_]?*com.ShaderResourceView{view};
        self.ctx.dc.PSSetShaderResources(2, 1, &views);
    }
};
