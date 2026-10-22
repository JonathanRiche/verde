//! Selectable content text inside Settings (Remote access status, errors, and
//! phone pairing notices). Drag, double-click word, triple-click block,
//! primary+C, primary+A after the text was clicked, right-click Copy / Select
//! all, Escape to clear. Every drawn line is recorded with its position during
//! the draw pass, so hit-testing, highlight, and copy read one layout.
const std = @import("std");
const palette = @import("palette");

const context_menu = @import("context_menu.zig");
const runtime = @import("runtime.zig");
const text_measure = @import("text_measure.zig");
const theme = @import("theme.zig");

const MAX_LINES: usize = 64;
const MAX_LINE_BYTES: usize = 256;
const ROLE: palette.FontRole = .ui;
/// Pixels scrolled per pixel the pointer is dragged past the body edge.
const DRAG_SCROLL_RATE: f32 = 0.5;

const Line = struct {
    /// `block << 8 | line number`; stable across frames.
    id: u32,
    block: u32,
    x: f32,
    y: f32,
    h: f32,
    font: f32,
    clip: palette.Rect,
    len: usize,
    bytes: [MAX_LINE_BYTES]u8,

    fn text(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Where glyphs are drawn (the I-beam region), clipped.
    fn box(self: *const Line) palette.Rect {
        const w = text_measure.textWidth(ROLE, self.font, self.text());
        return intersect(.{ .x = self.x, .y = self.y, .w = w + self.font * 0.35, .h = self.h }, self.clip);
    }
};

const Point = struct { id: u32, offset: usize };
const Range = struct { start_line: usize, start: usize, end_line: usize, end: usize };

var lines: [MAX_LINES]Line = undefined;
var line_count: usize = 0;
var anchor: ?Point = null;
var focus: ?Point = null;
var dragging: bool = false;
var surface_clicked: bool = false;
var menu: ?palette.draw.Vec2 = null;
var frame_w: f32 = 0.0;
var frame_h: f32 = 0.0;

/// Starts a draw pass; lines from the previous frame are dropped.
pub fn beginFrame(width: f32, height: f32) void {
    line_count = 0;
    frame_w = width;
    frame_h = height;
}

/// Forget selection and menu, e.g. when Settings closes.
pub fn reset() void {
    anchor = null;
    focus = null;
    dragging = false;
    surface_clicked = false;
    menu = null;
}

/// Records one drawn line and paints its selection highlight. Call right
/// before queuing the line's text so the highlight sits beneath it.
pub fn recordLine(state: *runtime.AppState, block: u32, index: usize, rect: palette.Rect, value: []const u8, font: f32, clip: palette.Rect) void {
    if (line_count >= MAX_LINES) return;
    const entry = &lines[line_count];
    entry.* = .{
        .id = (block << 8) | @as(u32, @intCast(index & 0xff)),
        .block = block,
        .x = rect.x,
        .y = rect.y,
        .h = rect.h,
        .font = font,
        .clip = intersect(rect, clip),
        .len = utf8Floor(value, MAX_LINE_BYTES),
        .bytes = undefined,
    };
    @memcpy(entry.bytes[0..entry.len], value[0..entry.len]);
    line_count += 1;
    drawHighlight(state, line_count - 1);
}

pub fn hasSelection() bool {
    return range() != null;
}

/// Pointer buttons ahead of the shared modal hits. Returns false when the
/// press belongs to a control or empty chrome.
pub fn handleMouseButton(state: *runtime.AppState, x: f32, y: f32, button: u8, down: bool, clicks: u8) bool {
    if (menu) |origin| {
        if (!down) return true;
        const layout = menuLayout(origin);
        menu = null;
        if (button == 1 and contains(layout.menu, x, y)) {
            if (contains(layout.rows[0], x, y)) copySelection(state) else if (contains(layout.rows[1], x, y)) selectAll(state);
        }
        state.markDirty();
        return true;
    }
    switch (button) {
        1 => {
            if (!down) {
                if (!dragging) return false;
                dragging = false;
                if (pointNear(x, y)) |point| focus = point;
                state.markDirty();
                return true;
            }
            const index = lineAt(x, y) orelse {
                surface_clicked = false;
                if (range() != null) {
                    anchor = null;
                    focus = null;
                    state.markDirty();
                }
                return false;
            };
            surface_clicked = true;
            begin(index, x, clicks);
            state.markDirty();
            return true;
        },
        3 => {
            if (!down or lineAt(x, y) == null) return false;
            menu = .{ .x = x, .y = y };
            state.markDirty();
            return true;
        },
        else => return false,
    }
}

/// Extends a drag selection; scrolls the Settings body when the pointer
/// leaves the text's visible band.
pub fn handleMouseMotion(state: *runtime.AppState, x: f32, y: f32) bool {
    if (!dragging) return false;
    if (visibleBand()) |band| {
        if (y < band.y) {
            state.settings_controller.scroll_y = @max(state.settings_controller.scroll_y - (band.y - y) * DRAG_SCROLL_RATE, 0.0);
        } else if (y > band.y + band.h) {
            // Settings layout clamps the upper bound on the next pass.
            state.settings_controller.scroll_y += (y - band.y - band.h) * DRAG_SCROLL_RATE;
        }
    }
    if (pointNear(x, y)) |point| focus = point;
    state.markDirty();
    return true;
}

/// Copy / select-all / Escape. Returns true when the key was consumed.
pub fn handleKey(state: *runtime.AppState, event: *const palette.event.KeyEvent) bool {
    if (event.mod.primary()) {
        if (event.key == .c and range() != null) {
            copySelection(state);
            return true;
        }
        if (event.key == .a and surface_clicked and line_count > 0) {
            selectAll(state);
            return true;
        }
        return false;
    }
    if (event.key != .escape) return false;
    if (menu != null) {
        menu = null;
    } else if (range() != null) {
        anchor = null;
        focus = null;
    } else return false;
    state.markDirty();
    return true;
}

/// I-beam over recorded text (and for the whole drag), pointer over the menu.
pub fn systemCursorAt(x: f32, y: f32) ?palette.platform.CursorShape {
    if (menu) |origin| {
        const layout = menuLayout(origin);
        if (contains(layout.menu, x, y)) return if (contains(layout.rows[0], x, y) and range() == null) .default else .pointer;
    }
    if (dragging or lineAt(x, y) != null) return .text;
    return null;
}

/// Draws the right-click menu above everything else in Settings.
pub fn drawMenu(state: *runtime.AppState) void {
    const origin = menu orelse return;
    const layout = menuLayout(origin);
    const panel = context_menu.queuePanel(state, layout.menu);
    const selected = range() != null;
    const mx = state.transcript_controller.palette_mouse_x;
    const my = state.transcript_controller.palette_mouse_y;
    for (MENU_ROWS, layout.rows, 0..) |label, rect, index| {
        const enabled = index != 0 or selected;
        const hovered = enabled and contains(rect, mx, my);
        if (hovered) context_menu.queueRowHighlight(state, rect);
        context_menu.queueLabel(state, rect, label, context_menu.labelColor(enabled, hovered), 0.0, 0.0, panel);
    }
}

// ---- helpers ------------------------------------------------------------------

fn utf8Floor(value: []const u8, limit: usize) usize {
    var n = @min(value.len, limit);
    while (n > 0 and n < value.len and value[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

fn lineIndexFor(id: u32) ?usize {
    for (lines[0..line_count], 0..) |*line, index| if (line.id == id) return index;
    return null;
}

fn range() ?Range {
    const a_point = anchor orelse return null;
    const f_point = focus orelse return null;
    const a = lineIndexFor(a_point.id) orelse return null;
    const f = lineIndexFor(f_point.id) orelse return null;
    const a_off = @min(a_point.offset, lines[a].len);
    const f_off = @min(f_point.offset, lines[f].len);
    if (a == f and a_off == f_off) return null;
    if (a < f or (a == f and a_off < f_off)) return .{ .start_line = a, .start = a_off, .end_line = f, .end = f_off };
    return .{ .start_line = f, .start = f_off, .end_line = a, .end = a_off };
}

fn byteAtX(line: *const Line, x: f32) usize {
    const value = line.text();
    if (x <= line.x) return 0;
    var previous_boundary: usize = 0;
    var previous_w: f32 = 0.0;
    var index: usize = 0;
    while (index < value.len) {
        const step = std.unicode.utf8ByteSequenceLength(value[index]) catch 1;
        index = @min(index + step, value.len);
        const w = text_measure.textPrefixWidth(ROLE, value, line.font, index);
        if (line.x + (previous_w + w) * 0.5 >= x) return previous_boundary;
        previous_boundary = index;
        previous_w = w;
    }
    return value.len;
}

fn lineAt(x: f32, y: f32) ?usize {
    for (lines[0..line_count], 0..) |*line, index| if (contains(line.box(), x, y)) return index;
    return null;
}

/// Caret under the pointer, clamped to the nearest visible line while
/// dragging; above the first line selects from its start, below the last to
/// its end.
fn pointNear(x: f32, y: f32) ?Point {
    var best: ?usize = null;
    var best_distance: f32 = std.math.inf(f32);
    for (lines[0..line_count], 0..) |*line, index| {
        if (line.clip.h <= 0.0 or line.clip.w <= 0.0) continue;
        const top = line.clip.y;
        const bottom = line.clip.y + line.clip.h;
        const distance = if (y < top) top - y else if (y >= bottom) y - bottom else 0.0;
        if (distance < best_distance) {
            best_distance = distance;
            best = index;
        }
    }
    const index = best orelse return null;
    const line = &lines[index];
    const offset = if (best_distance > 0.0 and y < line.clip.y)
        0
    else if (best_distance > 0.0)
        line.len
    else
        byteAtX(line, x);
    return .{ .id = line.id, .offset = offset };
}

fn visibleBand() ?palette.Rect {
    if (line_count == 0) return null;
    return lines[0].clip;
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-' or byte >= 0x80;
}

fn begin(index: usize, x: f32, clicks: u8) void {
    const line = &lines[index];
    const offset = byteAtX(line, x);
    if (clicks >= 3) {
        var first = index;
        while (first > 0 and lines[first - 1].block == line.block) first -= 1;
        var last = index;
        while (last + 1 < line_count and lines[last + 1].block == line.block) last += 1;
        anchor = .{ .id = lines[first].id, .offset = 0 };
        focus = .{ .id = lines[last].id, .offset = lines[last].len };
        dragging = false;
    } else if (clicks == 2) {
        const value = line.text();
        var start = @min(offset, value.len);
        var end = start;
        while (start > 0 and isWordByte(value[start - 1])) start -= 1;
        while (end < value.len and isWordByte(value[end])) end += 1;
        anchor = .{ .id = line.id, .offset = start };
        focus = .{ .id = line.id, .offset = end };
        dragging = false;
    } else {
        anchor = .{ .id = line.id, .offset = offset };
        focus = anchor;
        dragging = true;
    }
}

fn selectAll(state: *runtime.AppState) void {
    if (line_count == 0) return;
    const last = &lines[line_count - 1];
    anchor = .{ .id = lines[0].id, .offset = 0 };
    focus = .{ .id = last.id, .offset = last.len };
    dragging = false;
    state.markDirty();
}

/// Wrapped lines of one block join with the space the wrap consumed;
/// separate blocks join with a newline.
fn selectedTextAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const selected = range() orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index = selected.start_line;
    while (index <= selected.end_line) : (index += 1) {
        const line = &lines[index];
        const from = if (index == selected.start_line) selected.start else 0;
        const to = if (index == selected.end_line) selected.end else line.len;
        if (index > selected.start_line) try out.append(allocator, if (line.block != lines[index - 1].block) '\n' else ' ');
        if (to > from) try out.appendSlice(allocator, line.text()[from..to]);
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn copySelection(state: *runtime.AppState) void {
    const text = (selectedTextAlloc(state.allocator) catch {
        state.setSidebarNotice("Failed to copy selection.");
        return;
    }) orelse return;
    defer state.allocator.free(text);
    state.setSidebarNotice(if (state.setClipboardText(text)) "Copied selection." else "Failed to copy selection.");
    state.markDirty();
}

fn drawHighlight(state: *runtime.AppState, index: usize) void {
    const selected = range() orelse return;
    if (index < selected.start_line or index > selected.end_line) return;
    const line = &lines[index];
    const from = if (index == selected.start_line) selected.start else 0;
    const to = if (index == selected.end_line) selected.end else line.len;
    const x0 = line.x + text_measure.textPrefixWidth(ROLE, line.text(), line.font, from);
    var x1 = line.x + text_measure.textPrefixWidth(ROLE, line.text(), line.font, to);
    // A selection running past this line also covers its line break.
    if (index < selected.end_line) x1 += line.font * 0.35;
    if (x1 <= x0) return;
    const color = theme.withAlpha(theme.selection(), 90);
    state.palette_overlay_batch.roundedRectClipped(state.allocator, .{ .x = x0, .y = line.y, .w = x1 - x0, .h = line.h }, .{ .r = color[0], .g = color[1], .b = color[2], .a = color[3] }, theme.scaledUi(2.0), line.clip) catch {};
}

const MENU_ROWS = [_][]const u8{ "Copy", "Select all" };
const MenuLayout = struct { menu: palette.Rect, rows: [MENU_ROWS.len]palette.Rect };

fn menuLayout(origin: palette.draw.Vec2) MenuLayout {
    const pad = theme.scaledUi(context_menu.PAD_UI);
    const row_h = theme.scaledUi(context_menu.ROW_HEIGHT_UI);
    const w = theme.scaledUi(150.0);
    const h = pad * 2.0 + row_h * @as(f32, @floatFromInt(MENU_ROWS.len));
    const x = theme.clampf(origin.x, 0.0, @max(frame_w - w, 0.0));
    const y = theme.clampf(origin.y, 0.0, @max(frame_h - h, 0.0));
    var layout: MenuLayout = .{ .menu = .{ .x = x, .y = y, .w = w, .h = h }, .rows = undefined };
    for (&layout.rows, 0..) |*row, index| row.* = .{ .x = x + pad, .y = y + pad + row_h * @as(f32, @floatFromInt(index)), .w = w - pad * 2.0, .h = row_h };
    return layout;
}

fn intersect(a: palette.Rect, b: palette.Rect) palette.Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(x1 - x0, 0.0), .h = @max(y1 - y0, 0.0) };
}

fn contains(rect: palette.Rect, x: f32, y: f32) bool {
    return x >= rect.x and y >= rect.y and x < rect.x + rect.w and y < rect.y + rect.h;
}

fn recordForTest(block: u32, index: usize, y: f32, value: []const u8) void {
    const entry = &lines[line_count];
    entry.* = .{ .id = (block << 8) | @as(u32, @intCast(index)), .block = block, .x = 0.0, .y = y, .h = 16.0, .font = 13.0, .clip = .{ .x = 0.0, .y = y, .w = 1000.0, .h = 16.0 }, .len = value.len, .bytes = undefined };
    @memcpy(entry.bytes[0..value.len], value);
    line_count += 1;
}

test "settings selection copies wrapped lines with spaces and blocks with newlines" {
    beginFrame(800.0, 600.0);
    defer reset();
    recordForTest(1, 0, 0.0, "Reachable at");
    recordForTest(1, 1, 16.0, "https://box.ts.net");
    recordForTest(2, 0, 32.0, "Tailscale isn't signed in.");
    anchor = .{ .id = lines[0].id, .offset = 0 };
    focus = .{ .id = lines[2].id, .offset = lines[2].len };
    const copied = (try selectedTextAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("Reachable at https://box.ts.net\nTailscale isn't signed in.", copied);
    // Triple-click selects only its own block.
    begin(1, 0.0, 3);
    const block = (try selectedTextAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(block);
    try std.testing.expectEqualStrings("Reachable at https://box.ts.net", block);
    // A collapsed caret is not a selection.
    anchor = .{ .id = lines[0].id, .offset = 3 };
    focus = anchor;
    try std.testing.expect(!hasSelection());
}
