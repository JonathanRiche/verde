//! Font setup for Palette apps: builds a `font.Collection` with Verde's role chains and adapts
//! it to `text_layout.FontMetrics` so components measure with the same engine that draws.
//!
//! ## Role → font mapping (matches `palette/src/renderer.zig` `configureGpuTextWithAllRoleFonts`
//! as configured by Verde and the baseline harness)
//!
//! | role | primary | fallback chain (in order) |
//! |---|---|---|
//! | ui | CalSans-Regular | mono_symbols, symbols, symbols_alt, math, emoji |
//! | ui_bold, prose_bold | NotoSans-Bold | same as ui |
//! | prose | NotoSans-Regular | same as ui |
//! | prose_italic | NotoSans-Italic | same as ui |
//! | prose_bold_italic | NotoSans-BoldItalic | same as ui |
//! | mono | JetBrainsMonoNerdFont-Regular | icon, icon_fallback, mono_symbols, symbols, symbols_alt, math, emoji, prose |
//! | icon | Codicon | icon_fallback, mono_symbols |
//! | mono_symbols | SymbolsNerdFontMono-Regular | (none) |
//! | symbols / symbols_alt / math / emoji | NotoSansSymbols2 / NotoSansSymbols / – / NotoEmoji | (none) |
//!
//! Icon fonts are partial: Codicon has the newest codicons (e.g. U+EC5E `file-text`) but no
//! devicons, while Symbols Nerd Font carries devicons/Material Design but only the codicons up to
//! its release. Apps that pick one as `icon` set the other as `icon_fallback` so every icon
//! codepoint resolves; `mono_symbols` follows as a last resort before tofu.
//!
//! The old renderer registered the symbol faces as SDL_ttf fallbacks for ui/prose and used a
//! per-glyph fallback for mono; here both become ordinary role chains.
//!
//! ## The 0.86 text scale (`GPU_TEXT_FONT_SCALE`)
//!
//! The SDL renderer rasterized *and measured* every text command at `font_size * 0.86`. So in
//! Palette `font_size` (in draw commands and `FontMetrics`) is a nominal size, and the real pixel
//! size is `font_size * text_scale`. To keep existing component code producing the same text
//! as before, both halves of the pipeline use the same factor:
//!
//! * the GPU renderer (`gpu.RendererOptions.text_scale`, default 0.86), and
//! * the metrics adapter here (`Fonts.text_scale`, default 0.86): advances, line height, ascent
//!   and descent are evaluated at `font_size * text_scale`.
//!
//! `Graphics` passes one value to both. Apps that want true pixel sizes set it to 1.0.
//!
//! ## Device scale
//!
//! Components lay out in logical units, but glyphs are shaped at the device size
//! (`font_size * window_scale * text_scale`) and hinted advances do not scale linearly
//! (integer-ppem fonts snap 12.9 px to ppem 12 but 16.1 px to ppem 16). So the adapter
//! measures at the device size and divides by the scale: `setDeviceScale(window.scale())`
//! keeps measured widths equal to drawn widths at any HiDPI scale. Re-layout after changing it.
const std = @import("std");
const font = @import("font/root.zig");
const text_layout = @import("text_layout.zig");
const draw = @import("draw.zig");

pub const Role = draw.FontRole;
pub const default_text_scale: f32 = 0.86;

/// Where one face comes from. `.memory` (e.g. `@embedFile`) must outlive the collection.
pub const FaceSource = union(enum) {
    none,
    memory: []const u8,
    path: []const u8,
};

/// The face set Verde ships. Any entry may be `.none` (that role then uses the ui chain, and
/// fallbacks skip it).
pub const FaceSet = struct {
    ui: FaceSource = .none,
    bold: FaceSource = .none,
    prose: FaceSource = .none,
    italic: FaceSource = .none,
    bold_italic: FaceSource = .none,
    mono: FaceSource = .none,
    icon: FaceSource = .none,
    /// Second icon face, consulted when `icon` lacks a codepoint (see "Icon fonts" above).
    icon_fallback: FaceSource = .none,
    mono_symbols: FaceSource = .none,
    symbols: FaceSource = .none,
    symbols_alt: FaceSource = .none,
    math: FaceSource = .none,
    emoji: FaceSource = .none,

    /// File names of the bundled fonts (`assets/fonts`).
    pub const file_names = .{
        .ui = "CalSans-Regular.ttf",
        .bold = "NotoSans-Bold.ttf",
        .prose = "NotoSans-Regular.ttf",
        .italic = "NotoSans-Italic.ttf",
        .bold_italic = "NotoSans-BoldItalic.ttf",
        .mono = "JetBrainsMonoNerdFont-Regular.ttf",
        .icon = "Codicon.ttf",
        .mono_symbols = "SymbolsNerdFontMono-Regular.ttf",
        .symbols = "NotoSansSymbols2-Regular.ttf",
        .symbols_alt = "NotoSansSymbols-Regular.ttf",
    };

    /// Path-loads the bundled set from `dir` (paths are formatted into `buf`, which must stay
    /// alive until `Fonts.init` returns; faces are mmapped, so it can be freed afterwards).
    pub fn fromDir(dir: []const u8, buf: []u8) !FaceSet {
        var set: FaceSet = .{};
        var used: usize = 0;
        inline for (std.meta.fields(@TypeOf(file_names))) |f| {
            const name = @field(file_names, f.name);
            const p = try std.fmt.bufPrint(buf[used..], "{s}/{s}", .{ dir, name });
            used += p.len;
            @field(set, f.name) = .{ .path = p };
        }
        set.emoji = blk: {
            const p = try std.fmt.bufPrint(buf[used..], "{s}/NotoEmoji-Regular.ttf", .{dir});
            used += p.len;
            break :blk .{ .path = p };
        };
        return set;
    }
};

pub const Options = struct {
    text_scale: f32 = default_text_scale,
    /// Needed for `.path` sources (and system fallback).
    io: ?std.Io = null,
    /// Missing faces (file not found) are skipped instead of failing, like the old loader's
    /// optional fallbacks. The primary ui face is always required.
    optional_missing: bool = true,
    collection: font.collection.Options = .{},
};

/// A `font.Collection` with Verde's role chains, plus per-role `FontMetrics` adapters that apply
/// the text scale.
pub const Fonts = struct {
    gpa: std.mem.Allocator,
    collection: *font.Collection,
    text_scale: f32,
    /// Window scale the text will be drawn at (see "Device scale" above).
    device_scale: f32 = 1.0,
    contexts: [n_roles]MetricsContext = undefined,

    const n_roles = std.meta.fields(Role).len;

    const MetricsContext = struct {
        fonts: *Fonts,
        role: Role,
    };

    pub fn init(gpa: std.mem.Allocator, set: FaceSet, options: Options) !*Fonts {
        var copts = options.collection;
        if (copts.io == null) copts.io = options.io;
        const coll = try font.Collection.create(gpa, copts);
        errdefer coll.destroy();
        const self = try gpa.create(Fonts);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .collection = coll, .text_scale = options.text_scale };
        for (&self.contexts, 0..) |*c, i| c.* = .{ .fonts = self, .role = @enumFromInt(i) };
        try self.configure(set, options);
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        self.collection.destroy();
        self.gpa.destroy(self);
    }

    fn load(coll: *font.Collection, src: FaceSource, optional: bool) !?font.FaceId {
        const s: font.Source = switch (src) {
            .none => return null,
            .memory => |m| .{ .memory = m },
            .path => |p| .{ .path = p },
        };
        return coll.addFace(s) catch |err| {
            if (optional) {
                std.log.scoped(.palette_fonts).warn("font {s}: {s}", .{ if (src == .path) src.path else "<memory>", @errorName(err) });
                return null;
            }
            return err;
        };
    }

    fn configure(self: *Fonts, set: FaceSet, options: Options) !void {
        const coll = self.collection;
        const opt = options.optional_missing;
        const ui = (try load(coll, set.ui, false)) orelse return error.MissingUiFont;
        const bold = try load(coll, set.bold, opt);
        const prose = try load(coll, set.prose, opt);
        const italic = try load(coll, set.italic, opt);
        const bold_italic = try load(coll, set.bold_italic, opt);
        const mono = try load(coll, set.mono, opt);
        const icon = try load(coll, set.icon, opt);
        const icon_fallback = try load(coll, set.icon_fallback, opt);
        const mono_symbols = try load(coll, set.mono_symbols, opt);
        const symbols = try load(coll, set.symbols, opt);
        const symbols_alt = try load(coll, set.symbols_alt, opt);
        const math = try load(coll, set.math, opt);
        const emoji = try load(coll, set.emoji, opt);

        const text_fallbacks = [_]?font.FaceId{ mono_symbols, symbols, symbols_alt, math, emoji };
        try setChain(coll, .ui, ui, &text_fallbacks);
        // The old renderer's ui_bold/prose_bold both resolve to the bold (default) face.
        try setChain(coll, .ui_bold, bold orelse ui, &text_fallbacks);
        try setChain(coll, .prose_bold, bold orelse ui, &text_fallbacks);
        try setChain(coll, .prose, prose orelse ui, &text_fallbacks);
        try setChain(coll, .prose_italic, italic orelse prose orelse ui, &text_fallbacks);
        try setChain(coll, .prose_bold_italic, bold_italic orelse bold orelse ui, &text_fallbacks);
        if (mono) |m| try setChain(coll, .mono, m, &.{ icon, icon_fallback, mono_symbols, symbols, symbols_alt, math, emoji, prose });
        if (icon orelse icon_fallback) |f| try setChain(coll, .icon, f, &.{ icon_fallback, mono_symbols });
        if (mono_symbols) |f| try setChain(coll, .mono_symbols, f, &.{});
        if (symbols) |f| try setChain(coll, .symbols, f, &.{});
        if (symbols_alt) |f| try setChain(coll, .symbols_alt, f, &.{});
        if (math) |f| try setChain(coll, .math, f, &.{});
        if (emoji) |f| try setChain(coll, .emoji, f, &.{});
    }

    fn setChain(coll: *font.Collection, role: Role, primary: font.FaceId, rest: []const ?font.FaceId) !void {
        var chain: [font.collection.max_chain]font.FaceId = undefined;
        var n: usize = 0;
        chain[n] = primary;
        n += 1;
        for (rest) |f| if (f) |id| {
            if (std.mem.indexOfScalar(font.FaceId, chain[0..n], id) != null) continue;
            chain[n] = id;
            n += 1;
        };
        try coll.setRoleChain(role, chain[0..n]);
    }

    /// `FontMetrics` for components, at nominal `font_size` (the same number the component puts
    /// into draw commands). Advances, line height, ascent and descent are evaluated at
    /// `font_size * text_scale`, exactly what the GPU renderer draws. Pass `line_height` to
    /// override the font's line skip (components usually configure their own).
    pub fn metrics(self: *Fonts, role: Role, font_size: f32, line_height: ?f32) text_layout.FontMetrics {
        const ds = self.device_scale;
        const px = font_size * self.text_scale * ds;
        const lm = self.collection.lineMetrics(role, px);
        const base = self.collection.fontMetrics(role, px);
        return .{
            .font_size = font_size,
            .line_height = line_height orelse lm.lineHeight() / ds,
            .fixed_advance = if (base.fixed_advance) |a| a / ds else null,
            .ascent = lm.ascent / ds,
            .descent = lm.descent / ds,
            .baseline = lm.ascent / ds,
            .context = &self.contexts[@intFromEnum(role)],
            .advance = advanceCallback,
        };
    }

    /// Advance callback for `role` (context = `advanceContext(role)`), for hosts that assemble
    /// `FontMetrics` themselves.
    pub fn advanceContext(self: *Fonts, role: Role) *anyopaque {
        return &self.contexts[@intFromEnum(role)];
    }
    pub const advanceFn: text_layout.AdvanceFn = advanceCallback;

    fn advanceCallback(context: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) text_layout.Advance {
        const ctx: *MetricsContext = @ptrCast(@alignCast(context.?));
        const f = ctx.fonts;
        const ds = f.device_scale;
        var a = f.collection.advanceAt(ctx.role, font_size * f.text_scale * ds, text, byte_offset);
        if (ds != 1.0) a.width /= ds;
        return a;
    }

    /// Sets the window scale text is drawn at. Layout caches built with another scale are
    /// stale afterwards (re-layout / invalidate components).
    pub fn setDeviceScale(self: *Fonts, s: f32) void {
        self.device_scale = if (s > 0) s else 1.0;
    }

    /// Ink box of `cp` at nominal `font_size` in logical units: `{ min_x, max_x, min_y,
    /// max_y }` from the pen origin on the baseline, y up (SDL_ttf `TTF_GetGlyphMetrics`
    /// order, the `ttfGlyphInk` replacement). Evaluated at the size the GPU renderer draws
    /// (`font_size * text_scale * device_scale`), so the box is whole device pixels. Null for
    /// glyphs without ink.
    pub fn glyphInk(self: *Fonts, role: Role, font_size: f32, cp: u21) ?[4]f32 {
        const ds = self.device_scale;
        var ink = self.collection.glyphInk(role, font_size * self.text_scale * ds, cp) orelse return null;
        if (ds != 1.0) {
            for (&ink) |*v| v.* /= ds;
        }
        return ink;
    }

    /// Pen width of `text` at nominal `font_size` (shaped, cached), in logical units.
    pub fn measure(self: *Fonts, role: Role, font_size: f32, text: []const u8) !f32 {
        const ds = self.device_scale;
        return (try self.collection.measureText(role, font_size * self.text_scale * ds, text)) / ds;
    }
};

test "fonts: chains and scaled metrics with the bundled faces" {
    const io = std.testing.io;
    var buf: [2048]u8 = undefined;
    const set = try FaceSet.fromDir("../assets/fonts", &buf);
    const f = Fonts.init(std.testing.allocator, set, .{ .io = io }) catch |err| switch (err) {
        error.MissingUiFont => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();
    try std.testing.expect(f.collection.roleChain(.ui).len >= 2);
    // Codicon, then Symbols Nerd Font Mono (the bundled set's mono_symbols).
    try std.testing.expectEqual(@as(usize, 2), f.collection.roleChain(.icon).len);
    const m = f.metrics(.ui, 16, null);
    try std.testing.expectEqual(@as(f32, 16), m.font_size);
    const w = m.measureSlice("Hello");
    const direct = try f.collection.measureText(.ui, 16 * 0.86, "Hello");
    try std.testing.expectApproxEqAbs(direct, w, 0.01);

    // glyphInk: evaluated at the drawn size, reported in logical units.
    const ink = f.glyphInk(.ui, 16, 'A').?;
    try std.testing.expectEqual(f.collection.glyphInk(.ui, 16 * 0.86, 'A').?, ink);
    f.setDeviceScale(2);
    defer f.setDeviceScale(1);
    const ink2 = f.glyphInk(.ui, 16, 'A').?;
    const dev = f.collection.glyphInk(.ui, 16 * 0.86 * 2, 'A').?;
    for (0..4) |k| try std.testing.expectEqual(dev[k] / 2, ink2[k]);
    try std.testing.expect(f.glyphInk(.ui, 16, ' ') == null);
}

test "fonts: icon chain falls back across icon faces (Codicon-only and Nerd-only glyphs)" {
    const io = std.testing.io;
    const dir = "../assets/fonts";
    var codicon_buf: [256]u8 = undefined;
    var nerd_buf: [256]u8 = undefined;
    var ui_buf: [256]u8 = undefined;
    const codicon_path = try std.fmt.bufPrint(&codicon_buf, "{s}/{s}", .{ dir, FaceSet.file_names.icon });
    const nerd_path = try std.fmt.bufPrint(&nerd_buf, "{s}/{s}", .{ dir, FaceSet.file_names.mono_symbols });
    const ui_path = try std.fmt.bufPrint(&ui_buf, "{s}/{s}", .{ dir, FaceSet.file_names.ui });
    // U+EC5E (codicon `file-text`) is newer than the codicons Symbols Nerd Font carries;
    // U+E6B2 (devicon toml) and U+F0615 (Material Design, plane 15, cmap format 12) are not in
    // Codicon at all.
    const codicon_only: u21 = 0xEC5E;
    const nerd_only = [_]u21{ 0xE6B2, 0xF0615 };

    // Verde's desktop layout: Nerd Symbols primary, Codicon as the icon fallback.
    const desktop = Fonts.init(std.testing.allocator, .{
        .ui = .{ .path = ui_path },
        .icon = .{ .path = nerd_path },
        .icon_fallback = .{ .path = codicon_path },
    }, .{ .io = io, .optional_missing = false }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer desktop.deinit();
    const chain = desktop.collection.roleChain(.icon);
    try std.testing.expectEqual(@as(usize, 2), chain.len);
    try std.testing.expectEqual(@as(u32, 0), desktop.collection.sfntFace(chain[0]).?.font.glyphIndex(codicon_only));
    const r = desktop.collection.resolve(.icon, codicon_only).?;
    try std.testing.expectEqual(chain[1], r.face);
    try std.testing.expect(r.glyph != 0);
    for (nerd_only) |cp| {
        const e = desktop.collection.resolve(.icon, cp).?;
        try std.testing.expectEqual(chain[0], e.face);
        try std.testing.expect(e.glyph != 0);
    }
    // Measurement (layout) sees the fallback glyph, not a zero-width miss.
    try std.testing.expect((try desktop.measure(.icon, 16, "\u{EC5E}")) > 0);

    // The bundled set the other way round (Codicon primary): mono_symbols covers devicons.
    var buf: [2048]u8 = undefined;
    const bundled = try Fonts.init(std.testing.allocator, try FaceSet.fromDir(dir, &buf), .{ .io = io });
    defer bundled.deinit();
    try std.testing.expect(bundled.collection.resolve(.icon, codicon_only).?.glyph != 0);
    for (nerd_only) |cp| try std.testing.expect(bundled.collection.resolve(.icon, cp).?.glyph != 0);
}

test "fonts: icon_fallback alone becomes the icon face; chains skip duplicate faces" {
    const io = std.testing.io;
    var ui_buf: [256]u8 = undefined;
    var codicon_buf: [256]u8 = undefined;
    const ui_path = try std.fmt.bufPrint(&ui_buf, "../assets/fonts/{s}", .{FaceSet.file_names.ui});
    const codicon_path = try std.fmt.bufPrint(&codicon_buf, "../assets/fonts/{s}", .{FaceSet.file_names.icon});
    const f = Fonts.init(std.testing.allocator, .{
        .ui = .{ .path = ui_path },
        .icon_fallback = .{ .path = codicon_path },
    }, .{ .io = io, .optional_missing = false }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.collection.roleChain(.icon).len);
    try std.testing.expect(f.collection.resolve(.icon, 0xEC5E).?.glyph != 0);
}
