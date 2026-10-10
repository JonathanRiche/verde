//! Backend-neutral renderer core shared by every GPU backend (Vulkan, Metal, D3D11).
//!
//! A backend owns device objects (pipeline, atlas images, textures, targets) and records
//! commands; everything that decides *what* to draw lives here:
//!
//! * `Instance`: the 64-byte per-quad record every backend's uber-shader consumes
//!   (layout documented in src/shaders/ui.vert.glsl; the MSL/HLSL ports read the same bytes).
//! * `Encoder`: `draw.RenderBatch` -> instances + texture runs (`DrawRun`), glyph layout and
//!   the CPU side of both glyph atlases (`text.GlyphCache`), per-command semantic hashing and
//!   damage diffing (`damage.Tracker`), and the full / partial / skip decision (`Encoder.plan`).
//! * Streamed-texture bookkeeping: dirty-region clamping and merging (`mergeStreamRegions`) and
//!   tight row packing (`copyRows`).
//! * Public option/result types (`Options`, `FrameOptions`, `FrameResult`, `FrameStats`, ...).
//!
//! ## Backend interface
//!
//! `src/gpu/root.zig` re-exports one backend chosen at comptime. `app.zig` (`Graphics`), the
//! examples and the tests only use this surface (`checkBackend` enforces it):
//!
//!     Context.init(gpa, ContextOptions) !*Context        Context.deinit()
//!     Renderer.init(gpa, *Context, Options) !*Renderer   Renderer.deinit()
//!     Renderer.setGlyphSource(GlyphSource)               Renderer.lastFrameStats() FrameStats
//!     Renderer.uploadTexture(id, w, h, TextureFormat, pixels) !void
//!     Renderer.streamTexture(id, w, h, TextureFormat, pixels, StreamOptions) !void
//!     Renderer.releaseTexture(id)                        Renderer.waitSerial(serial) !void
//!     Offscreen.init(*Renderer, w, h) !Offscreen         Offscreen.deinit()
//!     Offscreen.render(*const RenderBatch, FrameOptions) !FrameResult
//!     Offscreen.readRgba(out []u8) !void                 Offscreen.target.invalidate()
//!
//! Window presentation is backend + platform specific (dma-buf targets on Wayland,
//! CAMetalLayer drawables on macOS) and lives behind `app.WindowRenderer`.

const std = @import("std");
const draw = @import("../draw.zig");
const text = @import("text.zig");
const damage = @import("damage.zig");

pub const Instance = extern struct {
    /// x, y, w, h (triangle: p0.xy, p1.xy)
    rect: [4]f32,
    /// x0, y0, x1, y1
    clip: [4]f32,
    /// u0, v0, u1, v1 (triangle: p2.xy; glyphs: atlas texels)
    uv: [4]f32,
    /// fill rgba8, border rgba8, radius f32 bits, kind | border_px << 8
    misc: [4]u32,
};

comptime {
    std.debug.assert(@sizeOf(Instance) == 64);
}

pub const Kind = enum(u8) { quad = 0, sdf = 1, triangle = 2, glyph = 3, color_glyph = 4, image = 5 };

pub const flag_legacy_border_blend: u32 = 1;
pub const flag_triangle_aa: u32 = 2;
pub const sdf_halo: f32 = 1.0;
const no_clip: [4]f32 = .{ -1e7, -1e7, 1e7, 1e7 };

pub const Options = struct {
    /// 2 or 3.
    frames_in_flight: u8 = 2,
    /// Reproduce the old renderer's border/fill mix (default) instead of "border over fill".
    legacy_border_blend: bool = true,
    /// Analytic AA on triangles (the old renderer had none).
    triangle_aa: bool = false,
    glyph_source: ?text.GlyphSource = null,
    text_scale: f32 = text.default_text_scale,
    /// Font role for text commands with `font_role == null` (old renderer: its default font,
    /// the prose-bold face).
    default_font_role: text.Role = .prose_bold,
    glyph_cache: text.CacheOptions = .{},
    damage_tracking: bool = true,
};

pub const TextureFormat = enum { rgba8, bgra8 };

pub const MemoryStats = struct {
    device_local_bytes: u64 = 0,
    host_visible_bytes: u64 = 0,
    allocation_count: u32 = 0,
};

pub const FrameStats = struct {
    build_ns: u64 = 0,
    upload_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_ns: u64 = 0,
    /// Time blocked waiting for the frame slot's previous submission.
    wait_ns: u64 = 0,
    total_ns: u64 = 0,
    commands: u32 = 0,
    instances: u32 = 0,
    draws: u32 = 0,
    glyphs_rasterized: u32 = 0,
    glyph_uploads: u32 = 0,
    texture_uploads: u32 = 0,
    /// Bytes copied from staging into textures this frame.
    texture_upload_bytes: u64 = 0,
    damage_rects: u32 = 0,
    damaged_pixels: u64 = 0,
    full_redraw: bool = true,
    /// Nothing changed and the target already held the frame: no GPU work was submitted.
    skipped: bool = false,
    atlas_size: u32 = 0,
    atlas_usage: f32 = 0,
    color_atlas_size: u32 = 0,
    glyph_count: u32 = 0,
    gpu_memory: MemoryStats = .{},
    /// CPU memory retained by renderer-owned scratch (instances, glyph cache, damage grid).
    host_bytes: usize = 0,
};

pub const FrameOptions = struct {
    clear: draw.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    /// Ignore buffer age / damage and repaint everything.
    force_full: bool = false,
};

pub const FrameResult = struct {
    /// Regions of the target that changed (device px). The whole target on full redraws.
    /// Valid until the next render call.
    damage: []const damage.Rect,
    stats: FrameStats,
    /// Submission serial (0 when skipped); `Renderer.waitSerial` blocks until it completed.
    serial: u64,
};

pub const max_stream_regions = 16;
/// Staging buffers per streamed texture (ring).
pub const max_stream_slots = 4;

/// Sub-rectangle of a texture, in texels.
pub const TextureRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const StreamOptions = struct {
    /// Bytes per row of `pixels` (0 = width * 4).
    stride: u32 = 0,
    /// Regions that changed since the previous update (empty = the whole texture). Only
    /// these rows/columns are copied to the staging buffer and to the image. The first
    /// update of a texture (or after a resize) is always full.
    dirty: []const TextureRect = &.{},
};

/// A run of consecutive instances sampling the same image texture (`texture` = draw.TextureId
/// value; 0 = the backend's 1x1 white dummy). Backends issue one instanced draw per run.
pub const DrawRun = struct {
    first: u32,
    count: u32,
    texture: u32,
};

/// What the backend has to do with the target this frame.
pub const Plan = enum {
    /// Nothing changed and the target already shows this batch: submit nothing.
    skip,
    /// Clear + redraw the whole target.
    full,
    /// Keep the target's contents; clear and redraw only `Encoder.damage_out` (scissored).
    partial,
};

/// Batch -> instances, damage and the redraw plan. One per renderer (shared by its targets).
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    options: Options,
    glyph_cache: text.GlyphCache,
    layouter: ?text.Layouter = null,

    instances: std.ArrayList(Instance) = .empty,
    runs: std.ArrayList(DrawRun) = .empty,
    damage_tracker: damage.Tracker,
    /// Damage-history frame index; targets remember the value of their last render.
    damage_frame: u64 = 0,
    damage_out: std.ArrayList(damage.Rect) = .empty,

    // Per-command build state.
    cur_texture: u32 = 0,
    bbox: [4]f32 = undefined,

    pub fn init(gpa: std.mem.Allocator, options: Options) Encoder {
        return .{
            .gpa = gpa,
            .options = options,
            .glyph_cache = .init(gpa, options.glyph_cache),
            .damage_tracker = .init(gpa),
        };
    }

    pub fn deinit(self: *Encoder) void {
        if (self.layouter) |*l| l.deinit();
        self.glyph_cache.deinit();
        self.instances.deinit(self.gpa);
        self.runs.deinit(self.gpa);
        self.damage_tracker.deinit();
        self.damage_out.deinit(self.gpa);
    }

    /// Call through the owning renderer, which keeps its atlas images in step (glyph ids of a
    /// different source are meaningless: the cache starts over).
    pub fn setGlyphSource(self: *Encoder, source: text.GlyphSource) void {
        if (self.layouter) |*l| l.deinit();
        self.layouter = .{ .gpa = self.gpa, .source = source, .cache = &self.glyph_cache, .scale = self.options.text_scale, .default_role = self.options.default_font_role };
        self.glyph_cache.deinit();
        self.glyph_cache = .init(self.gpa, self.options.glyph_cache);
        self.layouter.?.cache = &self.glyph_cache;
        self.damage_tracker.has_previous = false;
    }

    /// Push-constant / uniform flags for the uber-shader.
    pub fn shaderFlags(self: *const Encoder) u32 {
        return (if (self.options.legacy_border_blend) flag_legacy_border_blend else 0) | (if (self.options.triangle_aa) flag_triangle_aa else 0);
    }

    /// Step 1 of a frame: builds `instances` + `runs` and the damage grid for a
    /// `width` x `height` target. `textures` is any value with
    /// `fn textureGeneration(self, id: u32) ?u32` (null = no such texture: the image is skipped).
    pub fn build(self: *Encoder, batch: *const draw.RenderBatch, width: u32, height: u32, clear: draw.Color, textures: anytype, stats: *FrameStats) !void {
        self.glyph_cache.beginFrame();
        const rasterized_before = self.glyph_cache.stats.rasterized;
        self.instances.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        try self.instances.ensureTotalCapacity(self.gpa, batch.commands.items.len + 16);
        self.cur_texture = 0;
        try self.runs.append(self.gpa, .{ .first = 0, .count = 0, .texture = 0 });
        const track = self.options.damage_tracking;
        if (track) try self.damage_tracker.begin(width, height, colorSeed(clear));
        for (batch.commands.items) |*command| {
            const first = self.instances.items.len;
            self.bbox = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
            try self.buildCommand(command, textures);
            if (track and self.instances.items.len > first) {
                self.damage_tracker.add(self.bbox[0], self.bbox[1], self.bbox[2], self.bbox[3], hashCommand(c_gen(textures, command), command));
            }
        }
        self.closeRun();
        if (self.runs.items.len > 0 and self.runs.items[self.runs.items.len - 1].count == 0) _ = self.runs.pop();
        stats.instances = @intCast(self.instances.items.len);
        stats.draws = @intCast(self.runs.items.len);
        stats.glyphs_rasterized = @intCast(self.glyph_cache.stats.rasterized - rasterized_before);
        if (track) {
            _ = self.damage_tracker.finish();
            self.damage_frame += 1;
        }
    }

    /// Step 2: what to repaint in a target whose last render was at damage frame
    /// `target_last_frame` (0 = contents undefined). `pending_textures`: the backend has
    /// texture uploads to record (they must be submitted even when nothing else changed).
    /// Fills `damage_out` (the whole target on `.full`) and the damage stats.
    pub fn plan(self: *Encoder, target_last_frame: u64, width: u32, height: u32, force_full: bool, pending_textures: bool, stats: *FrameStats) !Plan {
        self.damage_out.clearRetainingCapacity();
        var partial: ?[]const damage.Rect = null;
        if (self.options.damage_tracking and !force_full and target_last_frame != 0) {
            const age: u32 = @intCast(@min(self.damage_frame - target_last_frame, std.math.maxInt(u32)));
            partial = try self.damage_tracker.damageFor(age);
        }
        const pending_work = pending_textures or self.glyph_cache.uploads.items.len > 0;
        var result: Plan = .full;
        if (partial) |rects| {
            if (rects.len == 0 and !pending_work) {
                stats.skipped = true;
                stats.full_redraw = false;
                return .skip;
            }
            try self.damage_out.appendSlice(self.gpa, rects);
            stats.full_redraw = false;
            result = .partial;
        } else {
            try self.damage_out.append(self.gpa, .{ .x = 0, .y = 0, .w = @intCast(width), .h = @intCast(height) });
        }
        stats.damage_rects = @intCast(self.damage_out.items.len);
        for (self.damage_out.items) |r| stats.damaged_pixels += @as(u64, @intCast(r.w)) * @as(u64, @intCast(r.h));
        return result;
    }

    /// Glyph-cache sizes and the host scratch estimate (`backend_bytes`: the backend's own
    /// per-frame CPU scratch).
    pub fn fillStats(self: *const Encoder, stats: *FrameStats, backend_bytes: usize) void {
        stats.atlas_size = self.glyph_cache.atlasSize(.coverage);
        stats.color_atlas_size = self.glyph_cache.atlasSize(.color);
        stats.atlas_usage = self.glyph_cache.usage(.coverage);
        stats.glyph_count = @intCast(self.glyph_cache.glyphCount());
        const gc = &self.glyph_cache;
        stats.host_bytes = backend_bytes + self.instances.capacity * @sizeOf(Instance) +
            self.runs.capacity * @sizeOf(DrawRun) +
            gc.map.capacity() * (@sizeOf(text.GlyphKey) + @sizeOf(text.Entry) + 1) +
            gc.upload_bytes.capacity + gc.uploads.capacity * @sizeOf(text.Upload) +
            gc.scratch.queryCapacity() +
            (self.damage_tracker.current.len + self.damage_tracker.previous.len) * 8 +
            (damage.history_len + 1) * self.damage_tracker.merged.len * 8;
    }

    // ---- Instance building ----------------------------------------------------------------

    fn closeRun(self: *Encoder) void {
        const last = &self.runs.items[self.runs.items.len - 1];
        last.count = @as(u32, @intCast(self.instances.items.len)) - last.first;
    }

    fn useTexture(self: *Encoder, id: u32) !void {
        if (id == self.cur_texture) return;
        self.closeRun();
        const last = &self.runs.items[self.runs.items.len - 1];
        if (last.count == 0) {
            last.texture = id;
        } else {
            try self.runs.append(self.gpa, .{ .first = @intCast(self.instances.items.len), .count = 0, .texture = id });
        }
        self.cur_texture = id;
    }

    fn pushInstance(self: *Encoder, inst: Instance, bounds: [4]f32) !void {
        // Visible bounds = geometry ∩ clip; skip instances that cannot produce fragments.
        const x0 = @max(bounds[0], inst.clip[0]);
        const y0 = @max(bounds[1], inst.clip[1]);
        const x1 = @min(bounds[2], inst.clip[2]);
        const y1 = @min(bounds[3], inst.clip[3]);
        if (!(x1 > x0 and y1 > y0)) return;
        try self.instances.append(self.gpa, inst);
        self.bbox[0] = @min(self.bbox[0], x0);
        self.bbox[1] = @min(self.bbox[1], y0);
        self.bbox[2] = @max(self.bbox[2], x1);
        self.bbox[3] = @max(self.bbox[3], y1);
    }

    fn buildCommand(self: *Encoder, command: *const draw.Command, textures: anytype) !void {
        switch (command.kind) {
            .rect, .cursor, .selection, .scrollbar => try self.buildRect(command),
            .triangle => try self.buildTriangle(command),
            .image => try self.buildImage(command, textures),
            .text => if (self.layouter) |*lay| {
                var sink: GlyphSink = .{ .encoder = self };
                try lay.drawCommand(&sink, command);
            },
        }
    }

    fn buildRect(self: *Encoder, command: *const draw.Command) !void {
        if (command.rect.w <= 0 or command.rect.h <= 0) return;
        const border_color: draw.Color = if (command.border_color) |bc|
            (if (command.border_width > 0 and bc.a > 0) bc else .{ .a = 0 })
        else
            .{ .a = 0 };
        const stroked = border_color.a > 0;
        const rect = if (stroked) snapRectToPixelGrid(command.rect) else command.rect;
        if (rect.w <= 0 or rect.h <= 0) return;
        const border_px: f32 = if (stroked) strokePixelWidth(command.border_width) else 0;
        const fill: draw.Color = if (command.color.a > 0) command.color else .{ .a = 0 };
        if (fill.a <= 0 and border_color.a <= 0) return;
        const radius = clampedRadius(rect, command.radius);
        const needs_sdf = radius > 0.5 or stroked;
        const clip = clipArray(command.clip);
        if (!needs_sdf) {
            try self.pushInstance(.{
                .rect = .{ rect.x, rect.y, rect.w, rect.h },
                .clip = clip,
                .uv = .{ 0, 0, 0, 0 },
                .misc = .{ packColor(fill), 0, 0, @intFromEnum(Kind.quad) },
            }, .{ rect.x, rect.y, rect.x + rect.w, rect.y + rect.h });
            return;
        }
        const bw: u32 = @intFromFloat(@min(border_px, 255));
        try self.pushInstance(.{
            .rect = .{ rect.x, rect.y, rect.w, rect.h },
            .clip = clip,
            .uv = .{ 0, 0, 0, 0 },
            .misc = .{ packColor(fill), packColor(border_color), @bitCast(radius), @as(u32, @intFromEnum(Kind.sdf)) | (bw << 8) },
        }, .{ rect.x - sdf_halo, rect.y - sdf_halo, rect.x + rect.w + sdf_halo, rect.y + rect.h + sdf_halo });
    }

    fn buildTriangle(self: *Encoder, command: *const draw.Command) !void {
        if (command.color.a <= 0) return;
        const p0 = command.p0;
        const p1 = command.p1;
        const p2 = command.p2;
        if (command.clip) |c| {
            // Old renderer: cull only when every vertex is outside the clip.
            if (!c.contains(p0) and !c.contains(p1) and !c.contains(p2)) return;
        }
        try self.pushInstance(.{
            .rect = .{ p0.x, p0.y, p1.x, p1.y },
            .clip = clipArray(command.clip),
            .uv = .{ p2.x, p2.y, 0, 0 },
            .misc = .{ packColor(command.color), 0, 0, @intFromEnum(Kind.triangle) },
        }, .{
            @min(p0.x, p1.x, p2.x) - sdf_halo,
            @min(p0.y, p1.y, p2.y) - sdf_halo,
            @max(p0.x, p1.x, p2.x) + sdf_halo,
            @max(p0.y, p1.y, p2.y) + sdf_halo,
        });
    }

    fn buildImage(self: *Encoder, command: *const draw.Command, textures: anytype) !void {
        if (!command.texture.valid() or command.color.a <= 0) return;
        const r = command.rect;
        if (r.w <= 0 or r.h <= 0) return;
        _ = textures.textureGeneration(command.texture.value) orelse return;
        try self.useTexture(command.texture.value);
        const uv = command.uv;
        try self.pushInstance(.{
            .rect = .{ r.x, r.y, r.w, r.h },
            .clip = clipArray(text.snapClip(command.clip)),
            .uv = .{ uv.x, uv.y, uv.x + uv.w, uv.y + uv.h },
            .misc = .{ packColor(command.color), 0, 0, @intFromEnum(Kind.image) },
        }, .{ r.x, r.y, r.x + r.w, r.y + r.h });
    }

    const GlyphSink = struct {
        encoder: *Encoder,
        pub fn glyph(self: *GlyphSink, q: text.GlyphQuad) !void {
            const kind: Kind = if (q.kind == .color) .color_glyph else .glyph;
            try self.encoder.pushInstance(.{
                .rect = .{ q.x, q.y, q.w, q.h },
                .clip = clipArray(q.clip),
                .uv = .{ q.u, q.v, q.u + q.w, q.v + q.h },
                .misc = .{ packColor(q.color), 0, 0, @intFromEnum(kind) },
            }, .{ q.x, q.y, q.x + q.w, q.y + q.h });
        }
    };
};

/// Generation of an image command's texture (0 for other commands or unknown textures).
fn c_gen(textures: anytype, c: *const draw.Command) u32 {
    if (c.kind != .image) return 0;
    return textures.textureGeneration(c.texture.value) orelse 0;
}

/// Semantic hash of everything that affects a command's pixels. Fixed-size fields are
/// packed into one key and hashed in a single pass (streaming many tiny updates costs
/// several times more); strings are chained in afterwards. `texture_generation` changes
/// whenever an image's pixels change.
pub fn hashCommand(texture_generation: u32, c: *const draw.Command) u64 {
    var key: HashKey = .{
        .kind = @intFromEnum(c.kind),
        .rect = c.rect,
        .color = c.color,
        .clip = c.clip orelse hash_no_clip,
    };
    switch (c.kind) {
        .rect, .cursor, .selection, .scrollbar => {
            key.a = .{ c.radius, c.border_width, 0, 0 };
            if (c.border_color) |bc| {
                key.b = .{ bc.r, bc.g, bc.b, bc.a };
                key.flags = 1;
            }
        },
        .triangle => {
            key.a = .{ c.p0.x, c.p0.y, c.p1.x, c.p1.y };
            key.b = .{ c.p2.x, c.p2.y, 0, 0 };
        },
        .image => {
            key.a = .{ c.uv.x, c.uv.y, c.uv.w, c.uv.h };
            key.flags = c.texture.value;
            key.extra = texture_generation;
        },
        .text => {
            key.a = .{ c.font_size, c.scroll.x, c.scroll.y, c.glyph_width };
            key.b = .{ c.line_height, 0, 0, 0 };
            key.flags = @as(u32, @intFromBool(c.wrap)) | @as(u32, if (c.font_role) |r| @intFromEnum(r) else 0xff) << 8;
            key.extra = @intCast(c.text_runs.len);
        },
    }
    var h = std.hash.Wyhash.hash(0x5eed, std.mem.asBytes(&key));
    if (c.kind == .text) {
        h = std.hash.Wyhash.hash(h, c.text);
        for (c.text_runs) |run| {
            const run_key: RunKey = .{
                .pos = .{ run.x, run.y, run.font_size, 0 },
                .color = run.color,
                .clip = run.clip orelse hash_no_clip,
                .role = if (run.font_role) |r| @intFromEnum(r) else 0xff,
            };
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&run_key));
            h = std.hash.Wyhash.hash(h, run.text);
        }
    }
    return h;
}

const hash_no_clip: draw.Rect = .{ .x = std.math.nan(f32), .y = 0, .w = 0, .h = 0 };

const HashKey = extern struct {
    kind: u32,
    flags: u32 = 0,
    extra: u32 = 0,
    _pad: u32 = 0,
    rect: draw.Rect,
    color: draw.Color,
    clip: draw.Rect,
    a: [4]f32 = .{ 0, 0, 0, 0 },
    b: [4]f32 = .{ 0, 0, 0, 0 },
};

const RunKey = extern struct {
    pos: [4]f32,
    color: draw.Color,
    clip: draw.Rect,
    role: u32,
    _pad: [3]u32 = .{ 0, 0, 0 },
};

fn colorSeed(c: draw.Color) u64 {
    return std.hash.Wyhash.hash(7, std.mem.asBytes(&c));
}

fn clipArray(clip: ?draw.Rect) [4]f32 {
    const c = clip orelse return no_clip;
    return .{ c.x, c.y, c.x + c.w, c.y + c.h };
}

pub fn packColor(c: draw.Color) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0, 1) * 255));
    const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0, 1) * 255));
    const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0, 1) * 255));
    const a: u32 = @intFromFloat(@round(std.math.clamp(c.a, 0, 1) * 255));
    return r | g << 8 | b << 16 | a << 24;
}

/// Rounds each edge (not origin + size) so neighbours sharing an edge stay gap-free at
/// fractional display scales. Identical to the old renderer.
pub fn snapRectToPixelGrid(rect: draw.Rect) draw.Rect {
    const x = @round(rect.x);
    const y = @round(rect.y);
    return .{ .x = x, .y = y, .w = @round(rect.x + rect.w) - x, .h = @round(rect.y + rect.h) - y };
}

/// Whole-pixel stroke width, never thinner than one device pixel.
pub fn strokePixelWidth(width: f32) f32 {
    return @max(@round(width), 1.0);
}

pub fn clampedRadius(rect: draw.Rect, radius: f32) f32 {
    return @min(@max(radius, 0.0), @min(rect.w, rect.h) * 0.5);
}

/// Premultiplied clear colour as the shaders/blend state expect it.
pub fn premultipliedClear(c: draw.Color) [4]f32 {
    return .{ c.r * c.a, c.g * c.a, c.b * c.a, c.a };
}

// ---- Streamed textures --------------------------------------------------------------------

pub fn clampRect(r: TextureRect, width: u32, height: u32) ?TextureRect {
    if (r.x >= width or r.y >= height or r.w == 0 or r.h == 0) return null;
    return .{ .x = r.x, .y = r.y, .w = @min(r.w, width - r.x), .h = @min(r.h, height - r.y) };
}

/// Copies rect `r` of a `stride`-pitched image into `dst`, tightly packed.
pub fn copyRows(dst: []u8, src: []const u8, stride: usize, r: TextureRect) void {
    const row_bytes = @as(usize, r.w) * 4;
    if (r.x == 0 and stride == row_bytes) {
        const start = @as(usize, r.y) * stride;
        const len = row_bytes * r.h;
        @memcpy(dst[0..len], src[start..][0..len]);
        return;
    }
    var y: usize = 0;
    while (y < r.h) : (y += 1) {
        const s = (@as(usize, r.y) + y) * stride + @as(usize, r.x) * 4;
        @memcpy(dst[y * row_bytes ..][0..row_bytes], src[s..][0..row_bytes]);
    }
}

/// Validates a `streamTexture` call. Returns the effective stride.
pub fn checkStream(id: u32, width: u32, height: u32, pixels: []const u8, options: StreamOptions) !usize {
    if (id == 0) return error.InvalidTextureId;
    const stride: usize = if (options.stride == 0) @as(usize, width) * 4 else options.stride;
    if (width == 0 or height == 0 or stride < @as(usize, width) * 4) return error.InvalidTextureSize;
    if (pixels.len < stride * (height - 1) + @as(usize, width) * 4) return error.InvalidTextureSize;
    return stride;
}

/// Regions of one streamed-texture update (merged with a not yet recorded one).
pub const StreamRegions = struct {
    /// Copy the whole texture (`count == 0`).
    full: bool,
    count: usize,
    regions: [max_stream_regions]TextureRect,
    /// Staging bytes used (tightly packed regions, or the whole texture).
    bytes: u64,

    /// Nothing to copy and nothing pending: the call is a no-op.
    pub fn empty(self: *const StreamRegions) bool {
        return !self.full and self.count == 0;
    }

    /// Packs the regions of `pixels` into `dst` (staging) in order.
    pub fn pack(self: *const StreamRegions, dst: []u8, pixels: []const u8, stride: usize, width: u32, height: u32) void {
        if (self.full) {
            copyRows(dst, pixels, stride, .{ .x = 0, .y = 0, .w = width, .h = height });
            return;
        }
        var off: usize = 0;
        for (self.regions[0..self.count]) |r| {
            copyRows(dst[off..], pixels, stride, r);
            off += @as(usize, r.w) * r.h * 4;
        }
    }
};

/// Merges `dirty` with a pending (unrecorded) update's regions. `pending`: null = none,
/// a slice of length 0 = the pending update is full. `force_full`: fresh texture or never
/// uploaded. Falls back to one full copy when regions overflow or exceed the texture size.
pub fn mergeStreamRegions(width: u32, height: u32, force_full: bool, pending: ?[]const TextureRect, dirty: []const TextureRect) StreamRegions {
    var out: StreamRegions = .{ .full = force_full or dirty.len == 0, .count = 0, .regions = undefined, .bytes = 0 };
    if (pending) |p| {
        if (p.len == 0) out.full = true else {
            @memcpy(out.regions[0..p.len], p);
            out.count = p.len;
        }
    }
    if (!out.full) for (dirty) |r| {
        const c = clampRect(r, width, height) orelse continue;
        if (out.count == max_stream_regions) {
            out.full = true;
            break;
        }
        out.regions[out.count] = c;
        out.count += 1;
    };
    for (out.regions[0..out.count]) |r| out.bytes += @as(u64, r.w) * r.h * 4;
    const full_bytes = @as(u64, width) * height * 4;
    if (out.full or out.bytes > full_bytes) {
        out.full = true;
        out.count = 0;
        out.bytes = full_bytes;
    }
    return out;
}

/// Compile-time check that a backend module offers the surface `app.zig` relies on.
pub fn checkBackend(comptime B: type) void {
    inline for (.{ "Context", "Renderer", "Offscreen" }) |name| {
        if (!@hasDecl(B, name)) @compileError("gpu backend lacks " ++ name);
    }
    inline for (.{ "init", "deinit", "setGlyphSource", "uploadTexture", "streamTexture", "releaseTexture", "lastFrameStats", "waitSerial" }) |f| {
        if (!@hasDecl(B.Renderer, f)) @compileError("gpu backend Renderer lacks " ++ f);
    }
    inline for (.{ "init", "deinit", "render", "readRgba" }) |f| {
        if (!@hasDecl(B.Offscreen, f)) @compileError("gpu backend Offscreen lacks " ++ f);
    }
    inline for (.{ "init", "deinit" }) |f| {
        if (!@hasDecl(B.Context, f)) @compileError("gpu backend Context lacks " ++ f);
    }
}

test "stroked rects snap to whole device pixels" {
    const snapped = snapRectToPixelGrid(.{ .x = 10.4, .y = 20.6, .w = 100.3, .h = 30.2 });
    try std.testing.expectEqual(@as(f32, 10.0), snapped.x);
    try std.testing.expectEqual(@as(f32, 21.0), snapped.y);
    try std.testing.expectEqual(@as(f32, 101.0), snapped.w);
    try std.testing.expectEqual(@as(f32, 30.0), snapped.h);
    try std.testing.expectEqual(@as(f32, 1.0), strokePixelWidth(1.25));
    try std.testing.expectEqual(@as(f32, 1.0), strokePixelWidth(0.5));
    try std.testing.expectEqual(@as(f32, 2.0), strokePixelWidth(1.75));
}

test "packColor puts red in the low byte" {
    try std.testing.expectEqual(@as(u32, 0xff0000ff), packColor(.{ .r = 1, .g = 0, .b = 0, .a = 1 }));
}

const NoTextures = struct {
    known: u32 = 0,
    generation: u32 = 1,
    pub fn textureGeneration(self: NoTextures, id: u32) ?u32 {
        return if (id == self.known) self.generation else null;
    }
};

test "encoder: runs split per texture, unknown images skipped, plan full/skip/partial" {
    const gpa = std.testing.allocator;
    var enc: Encoder = .init(gpa, .{});
    defer enc.deinit();
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(gpa);
    try batch.rect(gpa, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .{ .r = 1, .a = 1 });
    try batch.image(gpa, .{ .x = 10, .y = 0, .w = 10, .h = 10 }, draw.TextureId.init(3), .{ .w = 1, .h = 1 }, draw.Color.white, null);
    try batch.image(gpa, .{ .x = 20, .y = 0, .w = 10, .h = 10 }, draw.TextureId.init(4), .{ .w = 1, .h = 1 }, draw.Color.white, null);
    try batch.rect(gpa, .{ .x = 30, .y = 0, .w = 10, .h = 10 }, .{ .g = 1, .a = 1 });
    var tex: NoTextures = .{ .known = 3 };
    var stats: FrameStats = .{};
    try enc.build(&batch, 64, 32, .{ .a = 1 }, tex, &stats);
    // rect | image(3) + rect ; image(4) unknown -> skipped.
    try std.testing.expectEqual(@as(usize, 3), enc.instances.items.len);
    try std.testing.expectEqual(@as(usize, 2), enc.runs.items.len);
    try std.testing.expectEqual(@as(u32, 0), enc.runs.items[0].texture);
    try std.testing.expectEqual(@as(u32, 3), enc.runs.items[1].texture);
    try std.testing.expectEqual(@as(u32, 2), enc.runs.items[1].count);
    try std.testing.expectEqual(Plan.full, try enc.plan(0, 64, 32, false, false, &stats));
    const frame1 = enc.damage_frame;

    // Same batch again: skipped.
    stats = .{};
    try enc.build(&batch, 64, 32, .{ .a = 1 }, tex, &stats);
    try std.testing.expectEqual(Plan.skip, try enc.plan(frame1, 64, 32, false, false, &stats));
    try std.testing.expect(stats.skipped);
    const frame2 = enc.damage_frame;

    // New texture pixels (generation bump): partial damage around the image.
    tex.generation = 2;
    stats = .{};
    try enc.build(&batch, 64, 32, .{ .a = 1 }, tex, &stats);
    try std.testing.expectEqual(Plan.partial, try enc.plan(frame2, 64, 32, false, false, &stats));
    try std.testing.expect(enc.damage_out.items.len >= 1);
    try std.testing.expect(stats.damaged_pixels < 64 * 32);
}

test "stream regions: clamp, merge with pending, overflow to full" {
    const dirty = [_]TextureRect{ .{ .x = 60, .y = 0, .w = 100, .h = 2 }, .{ .x = 100, .y = 0, .w = 1, .h = 1 } };
    var m = mergeStreamRegions(64, 48, false, null, &dirty);
    try std.testing.expect(!m.full);
    try std.testing.expectEqual(@as(usize, 1), m.count);
    try std.testing.expectEqual(@as(u32, 4), m.regions[0].w);
    try std.testing.expectEqual(@as(u64, 4 * 2 * 4), m.bytes);
    const pend = [_]TextureRect{.{ .x = 0, .y = 0, .w = 2, .h = 2 }};
    m = mergeStreamRegions(64, 48, false, &pend, &dirty);
    try std.testing.expectEqual(@as(usize, 2), m.count);
    m = mergeStreamRegions(64, 48, false, &.{}, &dirty);
    try std.testing.expect(m.full);
    try std.testing.expectEqual(@as(u64, 64 * 48 * 4), m.bytes);
    var many: [max_stream_regions + 1]TextureRect = @splat(.{ .x = 0, .y = 0, .w = 1, .h = 1 });
    m = mergeStreamRegions(64, 48, false, null, &many);
    try std.testing.expect(m.full);
    m = mergeStreamRegions(64, 48, false, null, &.{.{ .x = 70, .y = 0, .w = 1, .h = 1 }});
    try std.testing.expect(m.empty());
}
