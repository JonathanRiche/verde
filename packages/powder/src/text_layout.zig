//! Backend-neutral text metrics and layout owned by Powder components.

const std = @import("std");

const draw = @import("draw.zig");
const selection_input = @import("input/selection.zig");

pub const Advance = struct {
    byte_len: usize,
    width: f32,
};

pub const AdvanceFn = *const fn (context: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) Advance;

pub const FontMetrics = struct {
    font_size: f32 = 16.0,
    line_height: f32 = 20.0,
    fixed_advance: ?f32 = null,
    ascent: ?f32 = null,
    descent: ?f32 = null,
    baseline: ?f32 = null,
    context: ?*anyopaque = null,
    advance: ?AdvanceFn = null,

    pub fn fallback(font_size: f32) FontMetrics {
        return .{
            .font_size = font_size,
            .line_height = font_size * 1.25,
            .fixed_advance = font_size * 0.55,
        };
    }

    pub fn fixed(font_size: f32, advance_width: f32, line_height: f32) FontMetrics {
        return .{
            .font_size = font_size,
            .line_height = line_height,
            .fixed_advance = advance_width,
        };
    }

    pub fn nextAdvance(self: FontMetrics, text: []const u8, byte_offset: usize) Advance {
        if (byte_offset >= text.len) return .{ .byte_len = 0, .width = 0.0 };
        if (self.advance) |callback| {
            const measured = callback(self.context, text, byte_offset, self.font_size);
            if (measured.byte_len > 0) return measured;
        }
        const len = utf8Len(text, byte_offset);
        return .{ .byte_len = len, .width = self.fixedAdvance() };
    }

    pub fn fixedAdvance(self: FontMetrics) f32 {
        return self.fixed_advance orelse self.font_size * 0.55;
    }

    pub fn measureSlice(self: FontMetrics, text: []const u8) f32 {
        var width: f32 = 0.0;
        var index: usize = 0;
        while (index < text.len) {
            if (text[index] == '\n') break;
            const advance_value = self.nextAdvance(text, index);
            width += advance_value.width;
            index += advance_value.byte_len;
        }
        return width;
    }
};

pub const Options = struct {
    rect: draw.Rect,
    text: []const u8,
    color: draw.Color,
    metrics: FontMetrics,
    wrap: bool = true,
    scroll: draw.Vec2 = .{},
    clip: ?draw.Rect = null,
};

pub const VisualCell = struct {
    row: usize = 0,
    x: f32 = 0.0,
};

pub fn appendRuns(allocator: std.mem.Allocator, options: Options, out: *std.ArrayList(draw.TextRun)) !void {
    var iter = LineIterator.init(options.text, options.metrics, options.rect.w, options.wrap);
    while (iter.next()) |line| {
        const y = options.rect.y + @as(f32, @floatFromInt(line.row)) * options.metrics.line_height - options.scroll.y;
        if (options.clip != null and !rectIntersectsY(options.clip.?, y, options.metrics.line_height)) continue;
        try out.append(allocator, .{
            .text = options.text[line.start..line.end],
            .byte_start = line.start,
            .byte_end = line.end,
            .x = options.rect.x + line.x - options.scroll.x,
            .y = y,
            .font_size = options.metrics.font_size,
            .line_height = options.metrics.line_height,
            .color = options.color,
            .clip = options.clip,
        });
    }
}

pub fn positionForOffset(options: Options, offset: usize) draw.Vec2 {
    const cell = visualCellForOffset(options.text, @min(offset, options.text.len), options.metrics, options.rect.w, options.wrap);
    return .{
        .x = options.rect.x + cell.x - options.scroll.x,
        .y = options.rect.y + @as(f32, @floatFromInt(cell.row)) * options.metrics.line_height - options.scroll.y,
    };
}

pub fn offsetForPoint(options: Options, point: draw.Vec2) usize {
    const target_row: usize = @intFromFloat(@max(@floor((point.y - options.rect.y + options.scroll.y) / @max(options.metrics.line_height, 1.0)), 0.0));
    const target_x = @max(point.x - options.rect.x + options.scroll.x, 0.0);
    var iter = LineIterator.init(options.text, options.metrics, options.rect.w, options.wrap);
    var last_end: usize = options.text.len;
    while (iter.next()) |line| {
        last_end = line.end;
        if (line.row < target_row) continue;
        if (line.row > target_row) return line.start;
        return offsetInLine(options.text, line.start, line.end, target_x, options.metrics);
    }
    return last_end;
}

pub fn offsetAtVisualCell(text: []const u8, target_row: usize, target_x: f32, metrics: FontMetrics, width: f32, wrap: bool) usize {
    var iter = LineIterator.init(text, metrics, width, wrap);
    var last_end: usize = text.len;
    while (iter.next()) |line| {
        last_end = line.end;
        if (line.row < target_row) continue;
        if (line.row > target_row) return line.start;
        return offsetInLine(text, line.start, line.end, target_x, metrics);
    }
    return last_end;
}

pub fn visualCellForOffset(text: []const u8, offset: usize, metrics: FontMetrics, width: f32, wrap: bool) VisualCell {
    var iter = LineIterator.init(text, metrics, width, wrap);
    var last: VisualCell = .{};
    while (iter.next()) |line| {
        if (offset >= line.start and offset <= line.end) {
            return .{ .row = line.row, .x = metrics.measureSlice(text[line.start..offset]) };
        }
        last = .{ .row = line.row, .x = metrics.measureSlice(text[line.start..line.end]) };
    }
    return last;
}

pub fn contentHeight(text: []const u8, metrics: FontMetrics, width: f32, wrap: bool) f32 {
    return @as(f32, @floatFromInt(lineCount(text, metrics, width, wrap))) * metrics.line_height;
}

pub fn lineCount(text: []const u8, metrics: FontMetrics, width: f32, wrap: bool) usize {
    var count: usize = 0;
    var iter = LineIterator.init(text, metrics, width, wrap);
    while (iter.next()) |_| count += 1;
    return @max(count, 1);
}

pub fn appendSelectionRects(
    allocator: std.mem.Allocator,
    options: Options,
    range: selection_input.Range,
    out: *std.ArrayList(draw.Rect),
) !void {
    var iter = LineIterator.init(options.text, options.metrics, options.rect.w, options.wrap);
    while (iter.next()) |line| {
        const start = @max(range.start, line.start);
        const end = @min(range.end, line.end);
        if (start > end or (start == end and line.end != line.start)) continue;
        if (range.start == range.end) continue;
        if (line.end == line.start and !(range.start <= line.start and range.end >= line.end)) continue;

        const x0 = options.rect.x + metricsWidth(options.metrics, options.text[line.start..start]) - options.scroll.x;
        const x1 = if (end > start)
            options.rect.x + metricsWidth(options.metrics, options.text[line.start..end]) - options.scroll.x
        else
            options.rect.x + @max(options.rect.w, 2.0) - options.scroll.x;
        const y = options.rect.y + @as(f32, @floatFromInt(line.row)) * options.metrics.line_height - options.scroll.y;
        const rect: draw.Rect = .{ .x = x0, .y = y, .w = @max(x1 - x0, 2.0), .h = options.metrics.line_height };
        if (options.clip) |clip| {
            if (clippedRect(rect, clip)) |clipped| try out.append(allocator, clipped);
        } else {
            try out.append(allocator, rect);
        }
    }
}

const Line = struct {
    row: usize,
    start: usize,
    end: usize,
    x: f32 = 0.0,
};

const LineIterator = struct {
    text: []const u8,
    metrics: FontMetrics,
    max_width: f32,
    wrap: bool,
    row: usize = 0,
    index: usize = 0,
    finished: bool = false,

    fn init(text: []const u8, metrics: FontMetrics, width: f32, wrap: bool) LineIterator {
        return .{ .text = text, .metrics = metrics, .max_width = @max(width, 1.0), .wrap = wrap };
    }

    fn next(self: *LineIterator) ?Line {
        if (self.finished) return null;
        if (self.index >= self.text.len) {
            self.finished = true;
            const row = self.row;
            self.row += 1;
            return .{ .row = row, .start = self.text.len, .end = self.text.len };
        }

        const start = self.index;
        var end = start;
        var width: f32 = 0.0;
        while (end < self.text.len) {
            if (self.text[end] == '\n') {
                const row = self.row;
                self.row += 1;
                self.index = end + 1;
                return .{ .row = row, .start = start, .end = end };
            }
            const advance_value = self.metrics.nextAdvance(self.text, end);
            if (self.wrap and end > start and width + advance_value.width > self.max_width) {
                const row = self.row;
                self.row += 1;
                self.index = end;
                return .{ .row = row, .start = start, .end = end };
            }
            width += advance_value.width;
            end += advance_value.byte_len;
        }

        self.finished = true;
        const row = self.row;
        self.row += 1;
        self.index = end;
        return .{ .row = row, .start = start, .end = end };
    }
};

fn offsetInLine(text: []const u8, start: usize, end: usize, target_x: f32, metrics: FontMetrics) usize {
    var x: f32 = 0.0;
    var index = start;
    while (index < end) {
        const advance_value = metrics.nextAdvance(text, index);
        if (target_x < x + advance_value.width * 0.5) return index;
        x += advance_value.width;
        if (target_x < x) return index + advance_value.byte_len;
        index += advance_value.byte_len;
    }
    return end;
}

fn metricsWidth(metrics: FontMetrics, text: []const u8) f32 {
    return metrics.measureSlice(text);
}

fn utf8Len(text: []const u8, byte_offset: usize) usize {
    return std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch 1;
}

fn rectIntersectsY(rect: draw.Rect, y: f32, h: f32) bool {
    return y + h > rect.y and y < rect.y + rect.h;
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

test "monospace layout emits wrapped run positions" {
    const metrics = FontMetrics.fixed(10, 5, 12);
    var runs: std.ArrayList(draw.TextRun) = .empty;
    defer runs.deinit(std.testing.allocator);

    try appendRuns(std.testing.allocator, .{
        .rect = .{ .x = 2, .y = 3, .w = 10, .h = 48 },
        .text = "abcde",
        .color = draw.Color.white,
        .metrics = metrics,
        .wrap = true,
    }, &runs);

    try std.testing.expectEqual(@as(usize, 3), runs.items.len);
    try std.testing.expectEqualStrings("ab", runs.items[0].text);
    try std.testing.expectEqual(@as(f32, 2), runs.items[0].x);
    try std.testing.expectEqual(@as(f32, 3), runs.items[0].y);
    try std.testing.expectEqualStrings("cd", runs.items[1].text);
    try std.testing.expectEqual(@as(f32, 15), runs.items[1].y);
}
