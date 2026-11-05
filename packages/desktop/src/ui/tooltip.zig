//! Shared delayed icon tooltips, using the Companion's chrome and typography.
const std = @import("std");
const palette = @import("palette");
const runtime = @import("runtime.zig");
const theme = @import("theme.zig");
const host = @import("host.zig");
const text_measure = @import("text_measure.zig");
const profiler = @import("../runtime/profiler.zig");
const loop_wakeup = @import("loop_wakeup");
const context_menu = @import("context_menu.zig");

const Point = struct { x: f32, y: f32 };
const HoverState = struct {
    hovered: ?palette.Rect = null,
    suppressed: ?palette.Rect = null,
    press_point: ?Point = null,
    started_ms: i64 = 0,

    fn move(self: *HoverState, x: f32, y: f32) void {
        if (self.suppressed) |target| {
            if (!contains(target, x, y)) self.suppressed = null;
        }
        if (self.hovered) |target| {
            if (!contains(target, x, y)) self.hovered = null;
        }
    }

    fn press(self: *HoverState, x: f32, y: f32) void {
        self.move(x, y);
        self.suppressed = self.hovered;
        self.press_point = if (self.hovered == null) .{ .x = x, .y = y } else null;
        self.hovered = null;
    }

    fn resetDelay(self: *HoverState) void {
        // Preserve press suppression until the pointer actually leaves.
        self.hovered = null;
        self.started_ms = 0;
    }

    const Result = enum { idle, pending, ready };
    fn offer(self: *HoverState, target: palette.Rect, x: f32, y: f32, now: i64) Result {
        self.move(x, y);
        if (!contains(target, x, y)) return .idle;
        if (self.press_point) |point| {
            self.press_point = null;
            if (contains(target, point.x, point.y)) self.suppressed = target;
        }
        if (self.suppressed) |blocked| {
            if (std.meta.eql(blocked, target)) return .idle;
        }
        if (self.hovered == null or !std.meta.eql(self.hovered.?, target)) {
            self.hovered = target;
            self.started_ms = now;
        }
        return if (now - self.started_ms < 500) .pending else .ready;
    }
};

const MAX_WIDTH_UI: f32 = 320.0;

var hover: HoverState = .{};

/// Dismiss on press and suppress that control until the pointer leaves it.
pub fn notePress(x: f32, y: f32) void {
    hover.press(x, y);
}

/// Track pointer exits even while a menu hides the underlying control.
pub fn notePointer(x: f32, y: f32) void {
    hover.move(x, y);
}

/// Restart the delay after overlay transitions without undoing press suppression.
pub fn resetDelay() void {
    hover.resetDelay();
}

/// Queue a tooltip after 500ms over `target`. Call alongside its hit region.
/// Non-hovered controls do not interrupt another control's pending tooltip.
pub fn queue(state: *runtime.AppState, target: palette.Rect, label: []const u8) void {
    queueAvoiding(state, target, label, &.{});
}

/// Keep a tooltip outside its containing control row and nearby pane titles.
/// Pass those rectangles in `avoid`; the target itself is always protected.
/// A short tooltip may share the anchor row beside its control.
pub fn queueAvoiding(state: *runtime.AppState, target: palette.Rect, label: []const u8, avoid: []const palette.Rect) void {
    queuePlaced(state, target, label, avoid, null);
}

/// Like `queueAvoiding`, but first tries the tooltip at `beside_x` (its left
/// edge), vertically centred on `target`: e.g. just right of the sidebar for
/// a control in a dense list, so it covers no neighbouring row. Falls back to
/// ordinary placement when that slot does not fit or hits `avoid`.
pub fn queueBeside(state: *runtime.AppState, target: palette.Rect, label: []const u8, avoid: []const palette.Rect, beside_x: f32) void {
    queuePlaced(state, target, label, avoid, beside_x);
}

fn queuePlaced(state: *runtime.AppState, target: palette.Rect, label: []const u8, avoid: []const palette.Rect, beside_x: ?f32) void {
    if (!state.transcript_controller.palette_mouse_in_workspace) {
        hover.move(-1, -1);
        return;
    }
    const now: i64 = @intCast(@divTrunc(profiler.nowNs(), std.time.ns_per_ms));
    switch (hover.offer(target, state.transcript_controller.palette_mouse_x, state.transcript_controller.palette_mouse_y, now)) {
        .idle => return,
        .pending => {
            // A hover timer requests frames without mutating persisted state.
            loop_wakeup.notify();
            return;
        },
        .ready => {},
    }
    const window = host.window() orelse return;
    const size = window.pixelSize();
    renderPlaced(state, .{ .x = 0, .y = 0, .w = @floatFromInt(size.width), .h = @floatFromInt(size.height) }, target, label, avoid, beside_x);
}

fn contains(target: palette.Rect, x: f32, y: f32) bool {
    return target.contains(.{ .x = x, .y = y });
}

/// Draw an immediate tooltip; callers with their own hover timing may reuse it.
pub fn render(state: *runtime.AppState, window: palette.Rect, target: palette.Rect, label: []const u8) void {
    renderAvoiding(state, window, target, label, &.{});
}

/// Immediate variant for surfaces that maintain their own hover timing.
pub fn renderAvoiding(state: *runtime.AppState, window: palette.Rect, target: palette.Rect, label: []const u8, avoid: []const palette.Rect) void {
    renderPlaced(state, window, target, label, avoid, null);
}

fn renderPlaced(state: *runtime.AppState, window: palette.Rect, target: palette.Rect, label: []const u8, avoid: []const palette.Rect, beside_x: ?f32) void {
    const chrome = theme.companionChrome();
    const font = theme.scaledUi(12.0);
    const pad = theme.scaledUi(8.0);
    const margin = theme.scaledUi(4.0);
    const available = @max(@floor(window.x + window.w - margin) - @ceil(window.x + margin), 0);
    const max_w = @min(theme.scaledUi(MAX_WIDTH_UI), available);
    if (max_w <= pad * 2 or label.len == 0) return;
    const arena = state.palette_frame_text_arena.allocator();
    const stable = arena.dupe(u8, label) catch return;
    const wrapped = wrapLabel(arena, stable, font, max_w - pad * 2) catch return;
    if (wrapped.lines.len == 0) return;
    const line_h = font * 1.3;
    const w = @min(wrapped.width + pad * 2, max_w);
    const h = line_h * @as(f32, @floatFromInt(wrapped.lines.len)) + theme.scaledUi(12.0);
    const placed = if (beside_x) |x| placeBeside(window, target, w, h, margin, avoid, x) orelse place(window, target, w, h, margin, theme.scaledUi(6.0), avoid) else place(window, target, w, h, margin, theme.scaledUi(6.0), avoid);
    const rect = context_menu.snap(placed orelse return);
    const previous_z = state.palette_overlay_batch.setZIndex(250);
    defer state.palette_overlay_batch.restoreZIndex(previous_z);
    state.palette_overlay_batch.panel(state.allocator, rect, color(chrome.surface_deep), color(theme.borderMuted()), theme.scaledUi(6.0), @max(@round(theme.scaledUi(1.0)), 1.0)) catch {};
    const text_y = rect.y + (rect.h - line_h * @as(f32, @floatFromInt(wrapped.lines.len))) * 0.5;
    for (wrapped.lines, 0..) |line, index| {
        state.palette_overlay_batch.roleText(state.allocator, .{ .x = rect.x + pad, .y = text_y + @as(f32, @floatFromInt(index)) * line_h, .w = @max(rect.w - pad * 2, 1), .h = line_h }, line, color(theme.legibleOn(chrome.text, chrome.surface_deep)), font, .ui, null, rect) catch {};
    }
}

/// Top-left strip controls prefer the right-hand slot in their chrome row.
/// Other controls prefer below/above, then beside, before crossing a title band.
/// Never clamp a tooltip back across its anchor or a protected surface. Hide it
/// when a tiny window cannot fit it without covering one of those surfaces.
fn place(window: palette.Rect, target: palette.Rect, width: f32, height: f32, margin: f32, gap: f32, avoid: []const palette.Rect) ?palette.Rect {
    // Inward pixel snapping keeps fractional UI scales inside the safe margin.
    const left = @ceil(window.x + margin);
    const top = @ceil(window.y + margin);
    const bounds: palette.Rect = .{ .x = left, .y = top, .w = @max(@floor(window.x + window.w - margin) - left, 0), .h = @max(@floor(window.y + window.h - margin) - top, 0) };
    if (width > bounds.w or height > bounds.h or width <= 0 or height <= 0) return null;
    // Keep a short label beside the leading strip control even if callers
    // stop listing the strip as an exclusion. The ordinary top margin can
    // waste the row's last fraction of a pixel at font/display zoom, so this
    // inline candidate uses the window edge and centers on the control.
    // validPlacement still enforces any supplied row and adjacent title band.
    const at_top_left = target.x >= window.x and target.x <= window.x + target.w + gap and
        target.y >= window.y and target.y <= window.y + target.h + gap;
    if (at_top_left and height <= target.h + gap * 2) {
        var inline_bounds = bounds;
        inline_bounds.y = @ceil(window.y);
        inline_bounds.h = bounds.y + bounds.h - inline_bounds.y;
        const beside: palette.Rect = .{
            .x = target.x + target.w + gap,
            .y = std.math.clamp(target.y + (target.h - height) * 0.5, inline_bounds.y, inline_bounds.y + inline_bounds.h - height),
            .w = width,
            .h = height,
        };
        if (validPlacement(beside, inline_bounds, target, avoid, gap)) return beside;
    }
    const x = std.math.clamp(target.x + (target.w - width) * 0.5, bounds.x, bounds.x + bounds.w - width);
    const base: palette.Rect = .{ .x = x, .y = target.y + target.h + gap, .w = width, .h = height };
    if (validPlacement(base, bounds, target, avoid, 0)) return base;
    var candidate = base;
    candidate.y = target.y - height - gap;
    if (validPlacement(candidate, bounds, target, avoid, 0)) return candidate;
    // A single-line label can fit beside a strip-edge control, within its
    // chrome row, instead of hiding the first lines of pane content.
    candidate.y = std.math.clamp(target.y + (target.h - height) * 0.5, bounds.y, bounds.y + bounds.h - height);
    candidate.x = target.x + target.w + gap;
    if (validPlacement(candidate, bounds, target, avoid, gap)) return candidate;
    candidate.x = target.x - width - gap;
    if (validPlacement(candidate, bounds, target, avoid, gap)) return candidate;
    candidate.x = x;
    for (avoid) |obstacle| {
        candidate.y = obstacle.y + obstacle.h + gap;
        if (validPlacement(candidate, bounds, target, avoid, 0)) return candidate;
        candidate.y = obstacle.y - height - gap;
        if (validPlacement(candidate, bounds, target, avoid, 0)) return candidate;
    }
    return null;
}

/// The `queueBeside` slot: left edge at `x`, centred on `target`'s row,
/// inside the window margin and clear of `target` and `avoid`; null when it
/// does not fit.
fn placeBeside(window: palette.Rect, target: palette.Rect, width: f32, height: f32, margin: f32, avoid: []const palette.Rect, x: f32) ?palette.Rect {
    const left = @ceil(window.x + margin);
    const top = @ceil(window.y + margin);
    const bounds: palette.Rect = .{ .x = left, .y = top, .w = @max(@floor(window.x + window.w - margin) - left, 0), .h = @max(@floor(window.y + window.h - margin) - top, 0) };
    if (width > bounds.w or height > bounds.h or width <= 0 or height <= 0) return null;
    const rect: palette.Rect = .{
        .x = x,
        .y = std.math.clamp(target.y + (target.h - height) * 0.5, bounds.y, bounds.y + bounds.h - height),
        .w = width,
        .h = height,
    };
    return if (validPlacement(rect, bounds, target, avoid, 0)) rect else null;
}

test "beside placement uses the given column and falls back when it does not fit" {
    const window: palette.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 600 };
    const badge: palette.Rect = .{ .x = 280, .y = 200, .w = 24, .h = 16 };
    const slot = placeBeside(window, badge, 300, 28, 4, &.{}, 380).?;
    try std.testing.expectEqual(@as(f32, 380), slot.x);
    try std.testing.expectApproxEqAbs(badge.y + badge.h * 0.5, slot.y + slot.h * 0.5, 0.01);
    // Past the window's right edge: no slot, so the caller falls back.
    try std.testing.expect(placeBeside(window, badge, 300, 28, 4, &.{}, 700) == null);
}

fn overlaps(a: palette.Rect, b: palette.Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

fn encloses(outer: palette.Rect, inner: palette.Rect) bool {
    return inner.x >= outer.x and inner.y >= outer.y and inner.x + inner.w <= outer.x + outer.w and inner.y + inner.h <= outer.y + outer.h;
}

fn validPlacement(rect: palette.Rect, bounds: palette.Rect, target: palette.Rect, avoid: []const palette.Rect, inline_gap: f32) bool {
    // Test the snapped box used for paint as well as the unsnapped candidate.
    const snapped = context_menu.snap(rect);
    for ([_]palette.Rect{ rect, snapped }) |box| {
        if (box.x < bounds.x or box.y < bounds.y or box.x + box.w > bounds.x + bounds.w or box.y + box.h > bounds.y + bounds.h or overlaps(box, target)) return false;
        for (avoid) |obstacle| {
            if (!overlaps(box, obstacle)) continue;
            // Relax only the anchor's containing chrome row for a side label
            // wholly inside it. Other title bands remain protected. Never
            // interpret a whole pane supplied by a caller as an inline row.
            if (inline_gap > 0 and obstacle.h <= target.h + inline_gap * 2 and encloses(obstacle, target) and encloses(obstacle, box)) continue;
            return false;
        }
    }
    return true;
}

test "tooltip placement avoids control rows and pane titles and flips within the window" {
    const window: palette.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 600 };
    const target: palette.Rect = .{ .x = 5, .y = 4, .w = 28, .h = 28 };
    const row: palette.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 38 };
    const title: palette.Rect = .{ .x = 0, .y = 38, .w = 900, .h = 40 };
    // A wrapped label cannot share the strip, so it clears the whole title.
    const below = place(window, target, 180, 60, 4, 6, &.{ row, title }).?;
    try std.testing.expect(below.y >= title.y + title.h + 6);
    try std.testing.expect(!overlaps(below, row) and !overlaps(below, title));
    try std.testing.expect(below.x >= 4);
    const bottom: palette.Rect = .{ .x = 870, .y = 560, .w = 28, .h = 28 };
    const above = place(window, bottom, 180, 28, 4, 6, &.{}).?;
    try std.testing.expect(above.y + above.h <= bottom.y - 6);
    try std.testing.expect(above.x + above.w <= window.w - 4);
    const fractional = place(window, target, 180.4, 60.6, 4.4, 6.6, &.{ row, title }).?;
    try std.testing.expect(validPlacement(fractional, .{ .x = 5, .y = 5, .w = 890, .h = 590 }, target, &.{ row, title }, 0));
    const tall: palette.Rect = .{ .x = 8, .y = 4, .w = 28, .h = 592 };
    const beside = place(window, tall, 180, 28, 4, 6, &.{}).?;
    try std.testing.expect(beside.x >= tall.x + tall.w + 6);
    try std.testing.expect(place(.{ .x = 0, .y = 0, .w = 100, .h = 40 }, .{ .x = 4, .y = 4, .w = 92, .h = 32 }, 90, 28, 4, 6, &.{}) == null);
}

const WrappedLabel = struct {
    lines: []const []const u8,
    width: f32,
};

/// Measure whole words with the same font role used for paint. Long paths and
/// other unbroken tokens break only at complete UTF-8 codepoints.
fn wrapLabel(allocator: std.mem.Allocator, label: []const u8, font: f32, max_w: f32) !WrappedLabel {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var width: f32 = 0;
    if (max_w > 0 and label.len > 0) {
        var paragraphs = std.mem.splitScalar(u8, label, '\n');
        while (paragraphs.next()) |paragraph| {
            var remaining = std.mem.trim(u8, paragraph, " \t\r");
            if (remaining.len == 0) try lines.append(allocator, "");
            while (remaining.len > 0) {
                const end = lineEnd(remaining, font, max_w);
                const line = std.mem.trimEnd(u8, remaining[0..end], " \t\r");
                try lines.append(allocator, line);
                width = @max(width, text_measure.textWidth(.ui, font, line));
                remaining = std.mem.trimStart(u8, remaining[end..], " \t\r");
            }
        }
    }
    return .{ .lines = try lines.toOwnedSlice(allocator), .width = width };
}

fn lineEnd(text: []const u8, font: f32, max_w: f32) usize {
    if (text_measure.textWidth(.ui, font, text) <= max_w) return text.len;
    var word_end: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != ' ' and byte != '\t') continue;
        if (text_measure.textWidth(.ui, font, text[0..index]) > max_w) break;
        word_end = index;
    }
    if (word_end > 0) return word_end;
    var end: usize = 0;
    while (end < text.len) {
        const next = @min(end + (std.unicode.utf8ByteSequenceLength(text[end]) catch 1), text.len);
        if (text_measure.textWidth(.ui, font, text[0..next]) > max_w) return if (end > 0) end else next;
        end = next;
    }
    return end;
}

test "tooltip wrapping caps measured lines preserves words and unicode and uses multiline height" {
    const allocator = std.testing.allocator;
    const font: f32 = 12;
    const max_text_w = MAX_WIDTH_UI - 16;
    const label = "Commits the files this chat changed. Shared or unclear files are left out. The Changes panel lists every changed file in this workspace.";
    const wrapped = try wrapLabel(allocator, label, font, max_text_w);
    defer allocator.free(wrapped.lines);
    try std.testing.expect(wrapped.lines.len > 1);
    try std.testing.expect(wrapped.width <= max_text_w);
    const joined = try std.mem.join(allocator, " ", wrapped.lines);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings(label, joined);
    for (wrapped.lines) |line| try std.testing.expect(text_measure.textWidth(.ui, font, line) <= max_text_w);
    const height = @as(f32, @floatFromInt(wrapped.lines.len)) * font * 1.3 + 12;
    const target: palette.Rect = .{ .x = 850, .y = 550, .w = 28, .h = 28 };
    const placed = place(.{ .x = 0, .y = 0, .w = 900, .h = 600 }, target, wrapped.width + 16, height, 4, 6, &.{}).?;
    try std.testing.expectApproxEqAbs(height, placed.h, 0.001);
    try std.testing.expect(placed.y + placed.h <= target.y - 6);
    const unicode = "日本語のファイル名—変更.zig";
    const narrow = try wrapLabel(allocator, unicode, font, text_measure.textWidth(.ui, font, "日本語"));
    defer allocator.free(narrow.lines);
    try std.testing.expect(narrow.lines.len > 1);
    const restored = try std.mem.join(allocator, "", narrow.lines);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(unicode, restored);
    for (narrow.lines) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(text_measure.textWidth(.ui, font, line) <= text_measure.textWidth(.ui, font, "日本語"));
    }
    const paragraphs = try wrapLabel(allocator, "first\n\nsecond", font, 500);
    defer allocator.free(paragraphs.lines);
    try std.testing.expectEqual(@as(usize, 3), paragraphs.lines.len);
    try std.testing.expectEqualStrings("", paragraphs.lines[1]);
}

test "tooltip side placement stays beside the strip control before covering pane content" {
    const window: palette.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 600 };
    const target: palette.Rect = .{ .x = 8, .y = 4, .w = 28, .h = 28 };
    const row: palette.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 38 };
    const title: palette.Rect = .{ .x = 0, .y = 38, .w = 900, .h = 40 };
    const beside = place(window, target, 180, 28, 4, 6, &.{ row, title }).?;
    try std.testing.expect(beside.x >= target.x + target.w + 6);
    try std.testing.expect(encloses(row, beside));
    try std.testing.expect(!overlaps(beside, target) and !overlaps(beside, title));
    const right: palette.Rect = .{ .x = 864, .y = 4, .w = 28, .h = 28 };
    const left = place(window, right, 180, 28, 4, 6, &.{ row, title }).?;
    try std.testing.expect(left.x + left.w <= right.x - 6);
    try std.testing.expect(encloses(row, left));
    const narrow_window: palette.Rect = .{ .x = 0, .y = 0, .w = 220, .h = 600 };
    const fallback = place(narrow_window, target, 180, 28, 4, 6, &.{ row, title }).?;
    try std.testing.expect(fallback.y >= title.y + title.h + 6);
    const blocked: palette.Rect = .{ .x = 36, .y = 0, .w = 864, .h = 38 };
    const clear = place(window, target, 180, 28, 4, 6, &.{ row, title, blocked }).?;
    try std.testing.expect(clear.y >= title.y + title.h + 6);
    // Match the actual 32-UI strip with a 4-UI control inset at common scales.
    for ([_]f32{ 1, 1.25, 1.5 }) |scale| {
        const strip: palette.Rect = .{ .x = 0, .y = 0, .w = 900 * scale, .h = 32 * scale };
        const toggle: palette.Rect = .{ .x = 8 * scale, .y = 4 * scale, .w = 30 * scale, .h = 24 * scale };
        const pane_title: palette.Rect = .{ .x = 0, .y = strip.h, .w = strip.w, .h = 60 * scale };
        const width = text_measure.textWidth(.ui, 12 * scale, "Show sidebar · Ctrl+Shift+S") + 16 * scale;
        const height = (12 * 1.3 + 12) * scale;
        const actual = place(.{ .x = 0, .y = 0, .w = strip.w, .h = 600 * scale }, toggle, width, height, 4 * scale, 6 * scale, &.{ strip, pane_title }).?;
        try std.testing.expect(actual.x >= toggle.x + toggle.w + 6 * scale);
        try std.testing.expect(encloses(strip, context_menu.snap(actual)));
        try std.testing.expect(!overlaps(actual, pane_title));
    }
}

test "tooltip left edge strip prefers right with either caller exclusion set and fractional zoom" {
    const label = "Show sidebar · Ctrl+Shift+S";
    const text_width = text_measure.textWidth(.ui, 12, label) + 16;
    // Font zoom combines with display scale in real layouts: the old top
    // margin rejected this otherwise roomy strip at e.g. 1.805556x.
    for ([_]f32{ 0.75, 1, 1.1, 1.2, 1.25, 1.388889, 1.5, 1.805556, 2, 2.5 }) |scale| {
        const window: palette.Rect = .{ .x = 0, .y = 0, .w = 1200 * scale, .h = 700 * scale };
        const strip: palette.Rect = .{ .x = 0, .y = 0, .w = window.w, .h = 32 * scale };
        const toggle: palette.Rect = .{ .x = 8 * scale, .y = 4 * scale, .w = 30 * scale, .h = 24 * scale };
        const title: palette.Rect = .{ .x = 0, .y = strip.h, .w = window.w, .h = 60 * scale };
        const original = [_]palette.Rect{ strip, title };
        const revised = [_]palette.Rect{ toggle, title };
        const title_only = [_]palette.Rect{title};
        for ([_][]const palette.Rect{ &original, &revised, &title_only, &.{} }) |avoid| {
            const rect = context_menu.snap(place(window, toggle, text_width * scale, 27.6 * scale, 4 * scale, 6 * scale, avoid).?);
            try std.testing.expect(rect.x >= toggle.x + toggle.w);
            try std.testing.expect(encloses(strip, rect));
            try std.testing.expect(!overlaps(rect, toggle) and !overlaps(rect, title));
        }
        // If the row cannot fit the label horizontally, use the safe fallback.
        var narrow = window;
        narrow.w = text_width * scale + 12 * scale;
        const fallback = place(narrow, toggle, text_width * scale, 27.6 * scale, 4 * scale, 6 * scale, &original).?;
        try std.testing.expect(fallback.y >= title.y + title.h);
    }
    // A control below the window's leading strip retains normal placement.
    const ordinary: palette.Rect = .{ .x = 8, .y = 180, .w = 30, .h = 24 };
    const below = place(.{ .x = 0, .y = 0, .w = 1200, .h = 700 }, ordinary, text_width, 27.6, 4, 6, &.{}).?;
    try std.testing.expect(below.y >= ordinary.y + ordinary.h + 6);
}

fn color(value: [4]f32) palette.Color {
    return .{ .r = value[0], .g = value[1], .b = value[2], .a = value[3] };
}

test "tooltip hover suppresses presses until exit and restarts after overlays" {
    var timing: HoverState = .{};
    const target: palette.Rect = .{ .x = 10, .y = 10, .w = 30, .h = 30 };
    try std.testing.expectEqual(HoverState.Result.pending, timing.offer(target, 20, 20, 100));
    try std.testing.expectEqual(HoverState.Result.ready, timing.offer(target, 20, 20, 600));
    timing.press(20, 20);
    try std.testing.expectEqual(HoverState.Result.idle, timing.offer(target, 22, 22, 1200));
    timing.resetDelay();
    try std.testing.expectEqual(HoverState.Result.idle, timing.offer(target, 22, 22, 1800));
    timing.move(50, 50); // Exit while an overlay hides the target.
    try std.testing.expectEqual(HoverState.Result.pending, timing.offer(target, 20, 20, 2000));
    try std.testing.expectEqual(HoverState.Result.ready, timing.offer(target, 20, 20, 2500));
    timing.resetDelay(); // Keyboard/outside dismissal, with no pointer movement.
    try std.testing.expectEqual(HoverState.Result.pending, timing.offer(target, 20, 20, 3000));
    try std.testing.expectEqual(HoverState.Result.pending, timing.offer(target, 20, 20, 3499));
    try std.testing.expectEqual(HoverState.Result.ready, timing.offer(target, 20, 20, 3500));
    timing.hovered = null; // A press may arrive before the first hover frame.
    timing.press(20, 20);
    try std.testing.expectEqual(HoverState.Result.idle, timing.offer(target, 20, 20, 4000));
}
