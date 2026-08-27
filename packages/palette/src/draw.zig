//! CPU-side render commands shared by components and the SDL_GPU renderer.

const Self = @This();
const std = @import("std");

pub const GpuRenderPass = anyopaque;

pub const Color = extern struct {
    r: f32 = 1.0,
    g: f32 = 1.0,
    b: f32 = 1.0,
    a: f32 = 1.0,

    pub const white: Color = .{};
    pub const transparent: Color = .{ .a = 0.0 };
    pub const black: Color = .{ .r = 0.0, .g = 0.0, .b = 0.0 };
};

pub const Vec2 = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub const Rect = extern struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    pub fn contains(self: Rect, point: Vec2) bool {
        return point.x >= self.x and point.x < self.x + self.w and
            point.y >= self.y and point.y < self.y + self.h;
    }
};

pub const TextureId = extern struct {
    value: u32 = 0,

    pub const invalid: TextureId = .{};

    pub fn init(value: u32) TextureId {
        return .{ .value = value };
    }

    pub fn valid(self: TextureId) bool {
        return self.value != 0;
    }
};

pub const Vertex = extern struct {
    pos: Vec2,
    uv: Vec2,
    color: Color,
    /// Top-left corner of the SDF rounded-rect, in framebuffer pixels. Used by
    /// the solid pipeline's fragment shader to apply analytic anti-aliasing.
    /// All four vertices of a quad share the same SDF parameters.
    sdf_min: Vec2 = .{},
    /// Size of the SDF rect in pixels. Zero size signals "no SDF AA" — the
    /// fragment shader falls back to the flat-color path used for triangles
    /// and plain (non-rounded, non-bordered) rects.
    sdf_size: Vec2 = .{},
    /// Corner radius and border thickness (in pixels), packed into a vec2
    /// attribute on the GPU. Border thickness 0 means "fill only".
    sdf_radius: f32 = 0.0,
    sdf_border_width: f32 = 0.0,
    /// Border color (alpha 0 disables border drawing). The fill color uses the
    /// existing `color` field.
    sdf_border: Color = .{ .a = 0.0 },
};

pub const CommandKind = enum {
    rect,
    triangle,
    text,
    image,
    cursor,
    selection,
    scrollbar,
};

pub const FontRole = enum {
    ui,
    ui_bold,
    icon,
    mono,
    // Coverage-fallback face for `mono`. The user's configured terminal font
    // (read from Ghostty config) may have sparse Dingbats/Arrows coverage
    // (e.g. CaskaydiaMono covers 4% of the Dingbats block). When the primary
    // mono face lacks a glyph, the renderer's per-glyph fallback consults
    // `mono_symbols` before icon/prose so common TUI glyphs (Vite's ➜,
    // Claude Code's ✻/✽ spinner frames, ●, □, etc.) still render instead
    // of tofu. Verde wires this to its embedded JetBrainsMonoNerdFont.
    mono_symbols,
    // Dedicated symbols face (Noto Sans Symbols 2) covering most of the
    // Dingbats block (U+2700-U+27BF) and broader Misc Symbols. Consulted
    // after mono_symbols/icon so things JetBrains Mono also lacks — Claude
    // Code's ✻/✽/✶ spinner frames, ➤, ✷, etc. — still render. Glyphs are
    // proportional rather than mono, but cell advance is forced by the
    // caller so layout is unaffected.
    symbols,
    // Complement to `symbols` (Noto Sans Symbols 2) — the original Noto Sans
    // Symbols covers blocks Symbols 2 omits: numbered dingbats (❶❷..❿ and
    // ➀➁..➓ at U+2776..2793), several Letterlike Symbols, parts of
    // Mathematical Operators, etc. Consulted between `symbols` and `emoji`.
    symbols_alt,
    // System math face for Mathematical Alphanumeric Symbols such as FX's
    // stylized `𝒇` (U+1D487). These live outside the bundled mono/symbol faces.
    math,
    // Monochrome emoji face (Noto Emoji) for the *emoji-styled* Dingbats and
    // Misc Symbols that Noto Sans Symbols 2 deliberately excludes — Vite's
    // ✨ (U+2728), check/cross emoji (✅❌), ➕➖, ℹ, ⚡, etc., plus 4-byte
    // emoji like 🔥/📦. Consulted after `symbols`/`symbols_alt` so the
    // simpler vector glyphs win when faces overlap.
    emoji,
    // Chat-transcript prose faces. Kept distinct from `ui` so the chrome face
    // (display sans) can differ from the body face (humanist sans regular).
    prose,
    prose_bold,
    prose_italic,
    prose_bold_italic,
};

pub const TextRun = struct {
    /// Slice into the command text. Frame-lifetime with the owning command text.
    text: []const u8 = "",
    byte_start: usize = 0,
    byte_end: usize = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    font_size: f32 = 16.0,
    line_height: f32 = 20.0,
    color: Color = Color.white,
    clip: ?Rect = null,
    /// Renderer-neutral font role. Host renderers map this to their own font atlas.
    font_role: ?FontRole = null,
    /// Optional host-defined font id for apps that prefer numeric atlas handles.
    font_id: ?u32 = null,
};

pub const Command = struct {
    kind: CommandKind,
    rect: Rect,
    p0: Vec2 = .{},
    p1: Vec2 = .{},
    p2: Vec2 = .{},
    uv: Rect = .{},
    color: Color,
    texture: TextureId = .invalid,
    /// Frame-lifetime text slice. Callers must keep it alive until the batch is consumed.
    text: []const u8 = "",
    /// Laid-out text runs generated by Palette. When non-empty, host renderers
    /// should draw these runs directly instead of re-wrapping `text`.
    text_runs: []const TextRun = &.{},
    text_run_start: usize = 0,
    text_run_count: usize = 0,
    font_size: f32 = 16.0,
    font_role: ?FontRole = null,
    font_id: ?u32 = null,
    clip: ?Rect = null,
    scroll: Vec2 = .{},
    glyph_width: f32 = 8.8,
    line_height: f32 = 20.0,
    wrap: bool = false,
    radius: f32 = 0.0,
    border_width: f32 = 0.0,
    border_color: ?Color = null,
    /// Higher z-index commands draw later. Equal z-index preserves insertion order.
    z_index: i32 = 0,
};

pub const RenderBatch = struct {
    commands: std.ArrayList(Command) = .empty,
    text_runs: std.ArrayList(TextRun) = .empty,
    current_z_index: i32 = 0,

    pub fn deinit(self: *RenderBatch, allocator: std.mem.Allocator) void {
        self.commands.deinit(allocator);
        self.text_runs.deinit(allocator);
    }

    pub fn clear(self: *RenderBatch) void {
        self.commands.clearRetainingCapacity();
        self.text_runs.clearRetainingCapacity();
        self.current_z_index = 0;
    }

    pub fn appendStableBatch(self: *RenderBatch, allocator: std.mem.Allocator, text_allocator: std.mem.Allocator, source: *const RenderBatch) !void {
        for (source.commands.items) |command| {
            var next = command;
            if (next.text.len > 0) {
                next.text = try text_allocator.dupe(u8, next.text);
            }
            if (command.text_run_count > 0) {
                const start = self.text_runs.items.len;
                try self.text_runs.ensureUnusedCapacity(allocator, command.text_run_count);
                for (command.text_runs) |run| {
                    var stable_run = run;
                    if (next.text.len > 0 and run.byte_start <= run.byte_end and run.byte_end <= next.text.len) {
                        stable_run.text = next.text[run.byte_start..run.byte_end];
                    } else if (run.text.len > 0) {
                        stable_run.text = try text_allocator.dupe(u8, run.text);
                    }
                    self.text_runs.appendAssumeCapacity(stable_run);
                }
                next.text_run_start = start;
                next.text_run_count = command.text_run_count;
                next.text_runs = self.text_runs.items[start .. start + command.text_run_count];
            }
            try self.appendCommandPreservingZ(allocator, next);
        }
        self.refreshTextRunSlices();
    }

    /// Appends a translated batch while borrowing its stable text storage.
    /// The source must outlive consumption of this batch by the renderer.
    pub fn appendTranslatedBatch(
        self: *RenderBatch,
        allocator: std.mem.Allocator,
        source: *const RenderBatch,
        translation: Vec2,
        clip: ?Rect,
    ) !void {
        std.debug.assert(self != source);
        try self.commands.ensureUnusedCapacity(allocator, source.commands.items.len);
        try self.text_runs.ensureUnusedCapacity(allocator, source.text_runs.items.len);
        self.refreshTextRunSlices();

        for (source.commands.items) |command| {
            if (!translatedCommandVisible(command, translation, clip)) continue;
            var next = command;
            next.rect = translatedRect(next.rect, translation);
            next.p0 = translatedPoint(next.p0, translation);
            next.p1 = translatedPoint(next.p1, translation);
            next.p2 = translatedPoint(next.p2, translation);
            next.clip = translatedClip(next.clip, translation, clip);

            if (command.text_run_count > 0) {
                const start = self.text_runs.items.len;
                for (command.text_runs) |run| {
                    var next_run = run;
                    next_run.x += translation.x;
                    next_run.y += translation.y;
                    next_run.clip = translatedClip(next_run.clip, translation, clip);
                    self.text_runs.appendAssumeCapacity(next_run);
                }
                next.text_run_start = start;
                next.text_run_count = command.text_run_count;
                next.text_runs = self.text_runs.items[start .. start + command.text_run_count];
            }
            try self.appendCommandPreservingZ(allocator, next);
        }
        self.refreshTextRunSlices();
    }

    pub fn setZIndex(self: *RenderBatch, z_index: i32) i32 {
        const previous = self.current_z_index;
        self.current_z_index = z_index;
        return previous;
    }

    pub fn restoreZIndex(self: *RenderBatch, z_index: i32) void {
        self.current_z_index = z_index;
    }

    pub fn rect(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.appendCommand(allocator, .{ .kind = .rect, .rect = r, .color = color });
    }

    /// Solid rect clipped to `clip` (host renderers intersect geometry with this rect).
    pub fn rectClipped(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color, clip: Rect) !void {
        try self.appendCommand(allocator, .{ .kind = .rect, .rect = r, .color = color, .clip = clip });
    }

    pub fn triangle(self: *RenderBatch, allocator: std.mem.Allocator, p0: Vec2, p1: Vec2, p2: Vec2, color: Color) !void {
        try self.appendCommand(allocator, .{
            .kind = .triangle,
            .rect = .{},
            .p0 = p0,
            .p1 = p1,
            .p2 = p2,
            .color = color,
        });
    }

    pub fn triangleClipped(self: *RenderBatch, allocator: std.mem.Allocator, p0: Vec2, p1: Vec2, p2: Vec2, color: Color, clip: Rect) !void {
        try self.appendCommand(allocator, .{
            .kind = .triangle,
            .rect = .{},
            .p0 = p0,
            .p1 = p1,
            .p2 = p2,
            .color = color,
            .clip = clip,
        });
    }

    pub fn roundedRect(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color, radius: f32) !void {
        try self.appendCommand(allocator, .{ .kind = .rect, .rect = r, .color = color, .radius = radius });
    }

    pub fn roundedRectClipped(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color, radius: f32, clip: Rect) !void {
        try self.appendCommand(allocator, .{ .kind = .rect, .rect = r, .color = color, .radius = radius, .clip = clip });
    }

    pub fn rectBorder(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color, radius: f32, width: f32) !void {
        try self.appendCommand(allocator, .{
            .kind = .rect,
            .rect = r,
            .color = Color.transparent,
            .radius = radius,
            .border_width = width,
            .border_color = color,
        });
    }

    pub fn rectBorderClipped(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color, radius: f32, width: f32, clip: Rect) !void {
        try self.appendCommand(allocator, .{
            .kind = .rect,
            .rect = r,
            .color = Color.transparent,
            .radius = radius,
            .border_width = width,
            .border_color = color,
            .clip = clip,
        });
    }

    pub fn panel(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, background: Color, border: ?Color, radius: f32, border_width: f32) !void {
        try self.appendCommand(allocator, .{
            .kind = .rect,
            .rect = r,
            .color = background,
            .radius = radius,
            .border_width = border_width,
            .border_color = border,
        });
    }

    pub fn glyph(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, uv: Rect, color: Color) !void {
        try self.image(allocator, r, .invalid, uv, color, null);
    }

    pub fn image(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, texture: TextureId, uv: Rect, tint: Color, clip: ?Rect) !void {
        try self.appendCommand(allocator, .{
            .kind = .image,
            .rect = r,
            .uv = uv,
            .color = tint,
            .texture = texture,
            .clip = clip,
        });
    }

    /// Appends a text command. The `value` slice is frame-lifetime and must remain
    /// valid until the batch is consumed by a renderer.
    pub fn text(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, value: []const u8, color: Color, font_size: f32, clip: ?Rect) !void {
        try self.appendCommand(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .font_size = font_size,
            .clip = clip,
            .glyph_width = font_size * 0.55,
            .line_height = font_size * 1.25,
        });
    }

    pub fn roleText(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, value: []const u8, color: Color, font_size: f32, font_role: ?FontRole, font_id: ?u32, clip: ?Rect) !void {
        try self.appendCommand(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .font_size = font_size,
            .font_role = font_role,
            .font_id = font_id,
            .clip = clip,
            .glyph_width = font_size * 0.55,
            .line_height = font_size * 1.25,
        });
    }

    /// Appends a laid-out text command. The `value` slice is frame-lifetime; the
    /// run descriptors are copied into the batch and remain valid until `clear`
    /// or `deinit`.
    pub fn textRuns(
        self: *RenderBatch,
        allocator: std.mem.Allocator,
        r: Rect,
        value: []const u8,
        runs: []const TextRun,
        color: Color,
        font_size: f32,
        clip: ?Rect,
        line_height: f32,
        glyph_width: f32,
    ) !void {
        const start = self.text_runs.items.len;
        try self.text_runs.appendSlice(allocator, runs);
        const stored = self.text_runs.items[start .. start + runs.len];
        try self.appendCommand(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .text_runs = stored,
            .text_run_start = start,
            .text_run_count = runs.len,
            .font_size = font_size,
            .clip = clip,
            .line_height = line_height,
            .glyph_width = glyph_width,
        });
        self.refreshTextRunSlices();
    }

    /// Appends fixed-cell wrapped text. TextArea uses this so rendering, hit
    /// testing, cursor placement, selection, and scrolling share one layout model.
    pub fn fixedText(
        self: *RenderBatch,
        allocator: std.mem.Allocator,
        r: Rect,
        value: []const u8,
        color: Color,
        font_size: f32,
        clip: ?Rect,
        scroll_value: Vec2,
        glyph_width: f32,
        line_height: f32,
        wrap: bool,
    ) !void {
        try self.fixedRoleText(allocator, r, value, color, font_size, null, null, clip, scroll_value, glyph_width, line_height, wrap);
    }

    pub fn fixedRoleText(
        self: *RenderBatch,
        allocator: std.mem.Allocator,
        r: Rect,
        value: []const u8,
        color: Color,
        font_size: f32,
        font_role: ?FontRole,
        font_id: ?u32,
        clip: ?Rect,
        scroll_value: Vec2,
        glyph_width: f32,
        line_height: f32,
        wrap: bool,
    ) !void {
        try self.appendCommand(allocator, .{
            .kind = .text,
            .rect = r,
            .color = color,
            .text = value,
            .font_size = font_size,
            .font_role = font_role,
            .font_id = font_id,
            .clip = clip,
            .scroll = scroll_value,
            .glyph_width = glyph_width,
            .line_height = line_height,
            .wrap = wrap,
        });
    }

    pub fn cursor(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.appendCommand(allocator, .{ .kind = .cursor, .rect = r, .color = color });
    }

    pub fn selection(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.appendCommand(allocator, .{ .kind = .selection, .rect = r, .color = color });
    }

    pub fn scrollbar(self: *RenderBatch, allocator: std.mem.Allocator, r: Rect, color: Color) !void {
        try self.appendCommand(allocator, .{ .kind = .scrollbar, .rect = r, .color = color });
    }

    fn appendCommand(self: *RenderBatch, allocator: std.mem.Allocator, command: Command) !void {
        var next = command;
        next.z_index = self.current_z_index;
        try self.appendCommandPreservingZ(allocator, next);
    }

    fn appendCommandPreservingZ(self: *RenderBatch, allocator: std.mem.Allocator, command: Command) !void {
        const next = command;
        try self.commands.append(allocator, next);
        var index = self.commands.items.len - 1;
        while (index > 0 and self.commands.items[index - 1].z_index > next.z_index) : (index -= 1) {
            self.commands.items[index] = self.commands.items[index - 1];
        }
        self.commands.items[index] = next;
    }

    fn refreshTextRunSlices(self: *RenderBatch) void {
        for (self.commands.items) |*command| {
            if (command.text_run_count == 0) continue;
            command.text_runs = self.text_runs.items[command.text_run_start .. command.text_run_start + command.text_run_count];
        }
    }
};

fn translatedPoint(point: Vec2, translation: Vec2) Vec2 {
    return .{ .x = point.x + translation.x, .y = point.y + translation.y };
}

fn translatedRect(rect: Rect, translation: Vec2) Rect {
    return .{ .x = rect.x + translation.x, .y = rect.y + translation.y, .w = rect.w, .h = rect.h };
}

fn translatedClip(existing: ?Rect, translation: Vec2, bounds: ?Rect) ?Rect {
    const moved = if (existing) |rect| translatedRect(rect, translation) else null;
    const target = bounds orelse return moved;
    const rect = moved orelse return target;
    const x0 = @max(rect.x, target.x);
    const y0 = @max(rect.y, target.y);
    const x1 = @min(rect.x + rect.w, target.x + target.w);
    const y1 = @min(rect.y + rect.h, target.y + target.h);
    if (x1 <= x0 or y1 <= y0) return .{ .x = target.x, .y = target.y, .w = 0.0, .h = 0.0 };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

fn translatedCommandVisible(command: Command, translation: Vec2, clip: ?Rect) bool {
    const target = clip orelse return true;
    const local_bounds: Rect = if (command.kind == .triangle) blk: {
        const x0 = @min(command.p0.x, @min(command.p1.x, command.p2.x));
        const y0 = @min(command.p0.y, @min(command.p1.y, command.p2.y));
        const x1 = @max(command.p0.x, @max(command.p1.x, command.p2.x));
        const y1 = @max(command.p0.y, @max(command.p1.y, command.p2.y));
        break :blk .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    } else command.rect;
    const bounds = translatedRect(local_bounds, translation);
    return bounds.x + bounds.w > target.x and bounds.x < target.x + target.w and
        bounds.y + bounds.h > target.y and bounds.y < target.y + target.h;
}

test "rect contains points inside bounds" {
    const rect_value: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try std.testing.expect(rect_value.contains(.{ .x = 10, .y = 20 }));
    try std.testing.expect(!rect_value.contains(.{ .x = 40, .y = 20 }));
}

test "image command carries texture and uv" {
    var batch: RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try batch.image(std.testing.allocator, .{ .w = 24, .h = 16 }, TextureId.init(7), .{ .x = 0.25, .y = 0.5, .w = 0.5, .h = 0.25 }, Color.white, .{ .w = 10, .h = 10 });

    try std.testing.expectEqual(CommandKind.image, batch.commands.items[0].kind);
    try std.testing.expectEqual(@as(u32, 7), batch.commands.items[0].texture.value);
    try std.testing.expectEqual(@as(f32, 0.25), batch.commands.items[0].uv.x);
    try std.testing.expect(batch.commands.items[0].clip != null);
}

test "commands are stably sorted by z-index" {
    var batch: RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    _ = batch.setZIndex(10);
    try batch.rect(std.testing.allocator, .{ .x = 10 }, Color.white);
    _ = batch.setZIndex(0);
    try batch.rect(std.testing.allocator, .{ .x = 0 }, Color.white);
    try batch.rect(std.testing.allocator, .{ .x = 1 }, Color.white);
    _ = batch.setZIndex(5);
    try batch.rect(std.testing.allocator, .{ .x = 5 }, Color.white);

    try std.testing.expectEqual(@as(f32, 0), batch.commands.items[0].rect.x);
    try std.testing.expectEqual(@as(f32, 1), batch.commands.items[1].rect.x);
    try std.testing.expectEqual(@as(f32, 5), batch.commands.items[2].rect.x);
    try std.testing.expectEqual(@as(f32, 10), batch.commands.items[3].rect.x);
}

test "translated batch moves geometry and intersects clips without copying text" {
    var source: RenderBatch = .{};
    defer source.deinit(std.testing.allocator);
    const text = "stable";
    try source.textRuns(std.testing.allocator, .{ .x = 2, .y = 3, .w = 40, .h = 12 }, text, &.{.{
        .text = text,
        .byte_end = text.len,
        .x = 2,
        .y = 3,
        .clip = .{ .x = 0, .y = 0, .w = 50, .h = 30 },
    }}, Color.white, 12, .{ .x = 0, .y = 0, .w = 50, .h = 30 }, 15, 7);
    try source.rect(std.testing.allocator, .{ .x = 80, .y = 80, .w = 10, .h = 10 }, Color.black);

    var destination: RenderBatch = .{};
    defer destination.deinit(std.testing.allocator);
    try destination.appendTranslatedBatch(std.testing.allocator, &source, .{ .x = 100, .y = 20 }, .{ .x = 110, .y = 25, .w = 30, .h = 20 });

    const command = destination.commands.items[0];
    try std.testing.expectEqual(@as(usize, 1), destination.commands.items.len);
    try std.testing.expectEqual(@as(f32, 102), command.rect.x);
    try std.testing.expectEqual(@as(f32, 23), command.rect.y);
    try std.testing.expectEqualStrings(text, command.text);
    try std.testing.expectEqual(@intFromPtr(text.ptr), @intFromPtr(command.text.ptr));
    try std.testing.expectEqual(@as(f32, 102), command.text_runs[0].x);
    try std.testing.expectEqual(@as(f32, 23), command.text_runs[0].y);
    try std.testing.expectEqual(@as(f32, 110), command.clip.?.x);
    try std.testing.expectEqual(@as(f32, 25), command.clip.?.y);
    try std.testing.expectEqual(@as(f32, 30), command.clip.?.w);
    try std.testing.expectEqual(@as(f32, 20), command.clip.?.h);
}

test "panel command carries renderer-neutral shape style" {
    var batch: RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);

    try batch.panel(std.testing.allocator, .{ .w = 20, .h = 10 }, Color.black, Color.white, 6, 2);

    try std.testing.expectEqual(CommandKind.rect, batch.commands.items[0].kind);
    try std.testing.expectEqual(@as(f32, 6), batch.commands.items[0].radius);
    try std.testing.expectEqual(@as(f32, 2), batch.commands.items[0].border_width);
    try std.testing.expect(batch.commands.items[0].border_color != null);
}
