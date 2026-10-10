//! Deterministic scenes for the offscreen example, golden-image tests and the benchmark.

const std = @import("std");
const draw = @import("../draw.zig");

pub const image_texture_id: u32 = 7;
pub const image_size: u32 = 32;

/// 32x32 straight-alpha RGBA checker with a transparent hole, for image tests.
pub fn checkerPixels(out: *[image_size * image_size * 4]u8) void {
    for (0..image_size) |y| for (0..image_size) |x| {
        const i = (y * image_size + x) * 4;
        const dark = ((x / 8) + (y / 8)) % 2 == 0;
        const hole = x >= 12 and x < 20 and y >= 12 and y < 20;
        out[i + 0] = if (dark) 30 else 240;
        out[i + 1] = if (dark) 90 else 200;
        out[i + 2] = if (dark) 200 else 40;
        out[i + 3] = if (hole) 0 else 255;
    };
}

pub const width: u32 = 480;
pub const height: u32 = 320;

fn s(v: f32, scale: f32) f32 {
    return v * scale;
}

fn r(x: f32, y: f32, w: f32, h: f32, scale: f32) draw.Rect {
    return .{ .x = x * scale, .y = y * scale, .w = w * scale, .h = h * scale };
}

const panel_bg: draw.Color = .{ .r = 0.13, .g = 0.14, .b = 0.17, .a = 1 };
const border: draw.Color = .{ .r = 0.32, .g = 0.35, .b = 0.42, .a = 1 };
const accent: draw.Color = .{ .r = 0.25, .g = 0.55, .b = 0.95, .a = 1 };
const text_color: draw.Color = .{ .r = 0.92, .g = 0.93, .b = 0.95, .a = 1 };

/// The reference scene at a device scale (1.0 and 1.25 are checked in as goldens). Logical
/// size 480x320 at scale 1.
pub fn build(gpa: std.mem.Allocator, batch: *draw.RenderBatch, scale: f32) !void {
    batch.clear();
    // Window background + sidebar.
    try batch.rect(gpa, r(0, 0, 480, 320, scale), .{ .r = 0.08, .g = 0.085, .b = 0.1, .a = 1 });
    try batch.panel(gpa, r(8, 8, 150, 304, scale), panel_bg, border, s(8, scale), s(1, scale));

    // Sidebar rows: selection + text.
    try batch.selection(gpa, r(14, 40, 138, 22, scale), .{ .r = 0.25, .g = 0.55, .b = 0.95, .a = 0.35 });
    const rows = [_][]const u8{ "Inbox", "Drafts", "Archive", "Settings" };
    for (rows, 0..) |label, i| {
        const y: f32 = 16 + @as(f32, @floatFromInt(i)) * 24;
        try batch.roleText(gpa, r(22, y + 1, 120, 20, scale), label, text_color, s(14, scale), .ui, null, null);
        // Chevron triangle.
        const cx = s(140, scale);
        const cy = s(y + 11, scale);
        try batch.triangle(gpa, .{ .x = cx - s(3, scale), .y = cy - s(4, scale) }, .{ .x = cx + s(3, scale), .y = cy }, .{ .x = cx - s(3, scale), .y = cy + s(4, scale) }, border);
    }

    // Main card with rounded border, fractional position.
    try batch.panel(gpa, .{ .x = s(170.4, scale), .y = s(8.6, scale), .w = s(300.3, scale), .h = s(140.2, scale) }, panel_bg, border, s(10, scale), s(1, scale));
    try batch.roleText(gpa, r(184, 18, 280, 20, scale), "Rounded panels, 1px borders", text_color, s(15, scale), .ui_bold, null, null);
    // Buttons: filled rounded, border-only, 2px border.
    try batch.roundedRect(gpa, r(184, 48, 80, 26, scale), accent, s(6, scale));
    try batch.rectBorder(gpa, r(272, 48, 80, 26, scale), accent, s(6, scale), s(1, scale));
    try batch.panel(gpa, r(360, 48, 96, 26, scale), .{ .r = 0.2, .g = 0.2, .b = 0.22, .a = 1 }, .{ .r = 0.9, .g = 0.4, .b = 0.3, .a = 1 }, s(13, scale), s(2, scale));
    try batch.roleText(gpa, r(196, 53, 60, 20, scale), "OK", .{ .r = 1, .g = 1, .b = 1, .a = 1 }, s(13, scale), .ui, null, null);
    // Wrapped text inside the card.
    var wrapped = draw.Command{
        .kind = .text,
        .rect = r(184, 84, 270, 60, scale),
        .color = text_color,
        .text = "Word wrapped text flows onto multiple lines inside the card.",
        .font_size = s(13, scale),
        .font_role = .ui,
        .wrap = true,
    };
    wrapped.clip = r(184, 84, 270, 56, scale);
    try appendCommand(gpa, batch, wrapped);

    // Images: full, sub-rect UV with tint, and clipped.
    try batch.image(gpa, r(184, 160, 64, 64, scale), draw.TextureId.init(image_texture_id), .{ .x = 0, .y = 0, .w = 1, .h = 1 }, draw.Color.white, null);
    try batch.image(gpa, r(256, 160, 64, 64, scale), draw.TextureId.init(image_texture_id), .{ .x = 0.25, .y = 0.25, .w = 0.5, .h = 0.5 }, .{ .r = 1, .g = 0.6, .b = 0.6, .a = 0.8 }, null);
    try batch.image(gpa, r(328, 160, 64, 64, scale), draw.TextureId.init(image_texture_id), .{ .x = 0, .y = 0, .w = 1, .h = 1 }, draw.Color.white, r(328, 176, 40.5, 32.5, scale));

    // Clipped rounded rect (clip cuts through the corner).
    try batch.roundedRectClipped(gpa, r(400, 160, 64, 64, scale), .{ .r = 0.4, .g = 0.8, .b = 0.5, .a = 1 }, s(16, scale), r(400, 160, 40, 40, scale));

    // Mono fixed-cell text (editor) with a cursor and a scrollbar.
    try batch.panel(gpa, r(170, 236, 300, 76, scale), .{ .r = 0.05, .g = 0.05, .b = 0.06, .a = 1 }, border, s(4, scale), s(1, scale));
    try batch.fixedRoleText(gpa, r(178, 242, 270, 64, scale), "fn main() {\n\treturn 42;\n}", text_color, s(13, scale), .mono, null, r(170, 236, 300, 76, scale), .{}, s(7.8, scale), s(17, scale), false);
    try batch.cursor(gpa, r(178 + 7.8 * 11, 242, 2, 17, scale), accent);
    try batch.scrollbar(gpa, r(460, 240, 6, 30, scale), .{ .r = 1, .g = 1, .b = 1, .a = 0.3 });

    // Text runs + a colour glyph.
    const runs = [_]draw.TextRun{
        .{ .text = "runs:", .x = s(22, scale), .y = s(130, scale), .font_size = s(13, scale), .color = text_color, .font_role = .ui },
        .{ .text = "red", .x = s(64, scale), .y = s(130, scale), .font_size = s(13, scale), .color = .{ .r = 1, .g = 0.3, .b = 0.3, .a = 1 }, .font_role = .ui_bold },
        .{ .text = "\u{1F600}", .x = s(100, scale), .y = s(128, scale), .font_size = s(16, scale), .color = draw.Color.white, .font_role = .emoji },
    };
    try batch.textRuns(gpa, r(22, 130, 120, 20, scale), "runs: red", &runs, text_color, s(13, scale), null, s(16, scale), s(7, scale));

    // Z-order: a popover added early but at higher z covers the sidebar rows.
    const prev = batch.setZIndex(5);
    try batch.panel(gpa, r(60, 150, 90, 60, scale), .{ .r = 0.18, .g = 0.19, .b = 0.23, .a = 0.96 }, border, s(8, scale), s(1, scale));
    try batch.roleText(gpa, r(70, 160, 70, 20, scale), "popover", text_color, s(13, scale), .ui, null, null);
    batch.restoreZIndex(prev);
    // Lower-z content added after the popover; must render beneath it.
    try batch.rect(gpa, r(20, 170, 110, 60, scale), .{ .r = 0.6, .g = 0.2, .b = 0.6, .a = 1 });
}

fn appendCommand(gpa: std.mem.Allocator, batch: *draw.RenderBatch, command: draw.Command) !void {
    var c = command;
    c.z_index = batch.current_z_index;
    try batch.commands.append(gpa, c);
}

/// A synthetic busy frame of roughly `count` commands (benchmark): rows of panels, labels,
/// icons and scrollbars like a long list view.
pub fn buildMany(gpa: std.mem.Allocator, batch: *draw.RenderBatch, count: usize, frame: u32, w: f32, h: f32) !void {
    batch.clear();
    try batch.rect(gpa, .{ .w = w, .h = h }, .{ .r = 0.08, .g = 0.085, .b = 0.1, .a = 1 });
    var i: usize = 0;
    const labels = [_][]const u8{ "alpha.zig", "renderer", "Vulkan 1.3", "dma-buf", "glyph atlas", "damage" };
    while (batch.commands.items.len < count) : (i += 1) {
        const row: f32 = @floatFromInt(i % 40);
        const col: f32 = @floatFromInt(i / 40 % 6);
        const x = col * (w / 6) + 4;
        const y = row * (h / 40) + 2;
        const cw = w / 6 - 8;
        const ch = h / 40 - 4;
        switch (i % 5) {
            0 => try batch.panel(gpa, .{ .x = x, .y = y, .w = cw, .h = ch }, panel_bg, border, 4, 1),
            1 => try batch.roleText(gpa, .{ .x = x + 6, .y = y + 2, .w = cw - 12, .h = ch }, labels[(i + frame) % labels.len], text_color, 12, .ui, null, null),
            2 => try batch.triangle(gpa, .{ .x = x + cw - 10, .y = y + 4 }, .{ .x = x + cw - 4, .y = y + ch / 2 }, .{ .x = x + cw - 10, .y = y + ch - 4 }, border),
            3 => try batch.roundedRect(gpa, .{ .x = x + 2, .y = y + 2, .w = 8, .h = 8 }, accent, 4),
            else => try batch.image(gpa, .{ .x = x + cw - 26, .y = y + 2, .w = 12, .h = 12 }, draw.TextureId.init(image_texture_id), .{ .w = 1, .h = 1 }, draw.Color.white, null),
        }
    }
}
