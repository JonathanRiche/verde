//! Backend-neutral text metrics and layout owned by Palette components.

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
    font_role: ?draw.FontRole = null,
    font_id: ?u32 = null,
    wrap: bool = true,
    scroll: draw.Vec2 = .{},
    clip: ?draw.Rect = null,
    /// Pre-wrapped rows for exactly `text`/`metrics`/`rect.w`/`wrap` (e.g. from a `LineCache`).
    /// When set, layout functions use them instead of re-wrapping; results are identical.
    lines: ?[]const Line = null,
};

pub const VisualCell = struct {
    row: usize = 0,
    x: f32 = 0.0,
};

pub fn appendRuns(allocator: std.mem.Allocator, options: Options, out: *std.ArrayList(draw.TextRun)) !void {
    var rows = Rows.init(options);
    if (options.lines != null and options.clip != null) {
        // Rows are evenly spaced: start just above the clip instead of walking from row 0.
        const lh = @max(options.metrics.line_height, 1e-3);
        const first = @floor((options.clip.?.y - options.rect.y + options.scroll.y) / lh) - 1.0;
        if (first > 0) rows.skip(@intFromFloat(@min(first, 1e9)));
    }
    while (rows.next()) |line| {
        const y = options.rect.y + @as(f32, @floatFromInt(line.row)) * options.metrics.line_height - options.scroll.y;
        if (options.clip != null and !rectIntersectsY(options.clip.?, y, options.metrics.line_height)) {
            if (options.lines != null and y >= options.clip.?.y + options.clip.?.h) break;
            continue;
        }
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
            .font_role = options.font_role,
            .font_id = options.font_id,
        });
    }
}

pub fn positionForOffset(options: Options, offset: usize) draw.Vec2 {
    const cell = if (options.lines) |lines|
        visualCellForOffsetLines(options.text, lines, @min(offset, options.text.len), options.metrics)
    else
        visualCellForOffset(options.text, @min(offset, options.text.len), options.metrics, options.rect.w, options.wrap);
    return .{
        .x = options.rect.x + cell.x - options.scroll.x,
        .y = options.rect.y + @as(f32, @floatFromInt(cell.row)) * options.metrics.line_height - options.scroll.y,
    };
}

pub fn offsetForPoint(options: Options, point: draw.Vec2) usize {
    const target_row: usize = @intFromFloat(@max(@floor((point.y - options.rect.y + options.scroll.y) / @max(options.metrics.line_height, 1.0)), 0.0));
    const target_x = @max(point.x - options.rect.x + options.scroll.x, 0.0);
    if (options.lines) |lines| return offsetAtVisualCellLines(options.text, lines, target_row, target_x, options.metrics);
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

/// `offsetAtVisualCell` over pre-wrapped `lines` (O(1) row lookup).
pub fn offsetAtVisualCellLines(text: []const u8, lines: []const Line, target_row: usize, target_x: f32, metrics: FontMetrics) usize {
    if (lines.len == 0) return text.len;
    if (target_row >= lines.len) return lines[lines.len - 1].end;
    const line = lines[target_row];
    return offsetInLine(text, line.start, line.end, target_x, metrics);
}

/// `visualCellForOffset` over pre-wrapped `lines` (binary search, measures one row).
pub fn visualCellForOffsetLines(text: []const u8, lines: []const Line, offset: usize, metrics: FontMetrics) VisualCell {
    if (lines.len == 0) return .{};
    // First row whose end >= offset (rows are contiguous and ordered).
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid].end < offset) lo = mid + 1 else hi = mid;
    }
    if (lo < lines.len and offset >= lines[lo].start) {
        const line = lines[lo];
        return .{ .row = line.row, .x = metrics.measureSlice(text[line.start..offset]) };
    }
    const last = lines[lines.len - 1];
    return .{ .row = last.row, .x = metrics.measureSlice(text[last.start..last.end]) };
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
    var rows = Rows.init(options);
    while (rows.next()) |line| {
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

/// One visual row: bytes `start..end` of the text (excluding the newline), row index `row`.
pub const Line = struct {
    row: usize,
    start: usize,
    end: usize,
    x: f32 = 0.0,
};

const Rows = struct {
    lines: ?[]const Line,
    i: usize = 0,
    iter: LineIterator,

    fn init(options: Options) Rows {
        return .{ .lines = options.lines, .iter = LineIterator.init(options.text, options.metrics, options.rect.w, options.wrap) };
    }

    fn skip(self: *Rows, n: usize) void {
        if (self.lines) |l| self.i = @min(n, l.len);
    }

    fn next(self: *Rows) ?Line {
        if (self.lines) |l| {
            if (self.i >= l.len) return null;
            defer self.i += 1;
            return l[self.i];
        }
        return self.iter.next();
    }
};

/// Retained wrap result for one text widget, updated incrementally.
///
/// `sync` compares the text with a snapshot of the previous one, finds the edited byte range
/// (common prefix/suffix, a memcmp) and re-wraps only the paragraphs (newline-delimited) it
/// touches; rows after it are shifted. Wrapping, metrics or width changes rebuild everything.
/// Assumes advances never depend on text past the next newline (true for `font.Collection`).
/// Call `invalidate` when the advance callback's results change without the `FontMetrics`
/// value changing (e.g. a device-scale change behind the same context pointer).
pub const LineCache = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    scratch: std.ArrayList(Line) = .empty,
    snapshot: std.ArrayList(u8) = .empty,
    key: ?Key = null,
    stats: Stats = .{},

    pub const Stats = struct { hits: u64 = 0, partial: u64 = 0, full: u64 = 0 };
    const probe_text = "Hamburgefonstiv WAVE 0123";

    const Key = struct {
        width: f32,
        wrap: bool,
        font_size: f32,
        line_height: f32,
        fixed_advance: ?f32,
        context: ?*anyopaque,
        advance: ?AdvanceFn,
        /// Width of `probe_text`: catches advance changes behind the same callback/context
        /// (device-scale switch) without an explicit `invalidate`.
        probe: f32,

        fn eql(a: Key, b: Key) bool {
            return a.width == b.width and a.wrap == b.wrap and a.font_size == b.font_size and a.probe == b.probe and
                a.line_height == b.line_height and std.meta.eql(a.fixed_advance, b.fixed_advance) and
                a.context == b.context and a.advance == b.advance;
        }
    };

    pub fn init(gpa: std.mem.Allocator) LineCache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *LineCache) void {
        self.lines.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.snapshot.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn invalidate(self: *LineCache) void {
        self.key = null;
    }

    /// Rows for `text`, equal to what the uncached functions compute. Null on allocation failure
    /// (callers fall back to uncached layout; the cache is invalidated).
    pub fn sync(self: *LineCache, text: []const u8, metrics: FontMetrics, width: f32, wrap: bool) ?[]const Line {
        return self.syncInner(text, metrics, width, wrap) catch {
            self.key = null;
            return null;
        };
    }

    fn syncInner(self: *LineCache, text: []const u8, metrics: FontMetrics, width: f32, wrap: bool) ![]const Line {
        const key: Key = .{
            .width = @max(width, 1.0),
            .wrap = wrap,
            .font_size = metrics.font_size,
            .line_height = metrics.line_height,
            .fixed_advance = metrics.fixed_advance,
            .context = metrics.context,
            .advance = metrics.advance,
            .probe = if (metrics.advance != null) metrics.measureSlice(probe_text) else 0,
        };
        if (self.key == null or !self.key.?.eql(key)) {
            self.key = null;
            self.lines.clearRetainingCapacity();
            var iter = LineIterator.init(text, metrics, width, wrap);
            while (iter.next()) |line| try self.lines.append(self.gpa, line);
            try self.storeSnapshot(text);
            self.key = key;
            self.stats.full += 1;
            return self.lines.items;
        }
        const old = self.snapshot.items;
        const min_len = @min(old.len, text.len);
        const p = std.mem.indexOfDiff(u8, old, text) orelse {
            self.stats.hits += 1;
            return self.lines.items;
        };
        var q: usize = 0;
        while (q < min_len - p and old[old.len - 1 - q] == text[text.len - 1 - q]) q += 1;

        const para_start = if (std.mem.lastIndexOfScalar(u8, old[0..p], '\n')) |i| i + 1 else 0;
        const old_para_end = std.mem.indexOfScalarPos(u8, old, old.len - q, '\n');
        const delta: isize = @as(isize, @intCast(text.len)) - @as(isize, @intCast(old.len));
        const new_para_end: ?usize = if (old_para_end) |e| @intCast(@as(isize, @intCast(e)) + delta) else null;

        const lines = self.lines.items;
        const r0 = firstRowStartingAtOrAfter(lines, para_start);
        const r1 = if (old_para_end) |e| firstRowStartingAtOrAfter(lines, e + 1) else lines.len;
        // Paragraph boundaries must be row boundaries (not so if malformed UTF-8 swallowed a
        // newline); otherwise rebuild.
        const bounded = r0 < lines.len and lines[r0].start == para_start and
            (old_para_end == null or (r1 < lines.len and lines[r1].start == old_para_end.? + 1));
        if (!bounded) {
            self.key = null;
            return self.syncInner(text, metrics, width, wrap);
        }

        self.scratch.clearRetainingCapacity();
        var iter = LineIterator.init(text, metrics, width, wrap);
        iter.index = para_start;
        iter.row = r0;
        var closed = new_para_end == null;
        while (iter.next()) |line| {
            try self.scratch.append(self.gpa, line);
            if (new_para_end) |e| if (iter.index > e) {
                closed = iter.index == e + 1 and line.end == e;
                break;
            };
        }
        if (!closed) {
            self.key = null;
            return self.syncInner(text, metrics, width, wrap);
        }
        const row_delta: isize = @as(isize, @intCast(self.scratch.items.len)) - @as(isize, @intCast(r1 - r0));
        for (lines[r1..]) |*line| {
            line.start = @intCast(@as(isize, @intCast(line.start)) + delta);
            line.end = @intCast(@as(isize, @intCast(line.end)) + delta);
            line.row = @intCast(@as(isize, @intCast(line.row)) + row_delta);
        }
        try self.lines.replaceRange(self.gpa, r0, r1 - r0, self.scratch.items);
        try self.storeSnapshot(text);
        self.stats.partial += 1;
        return self.lines.items;
    }

    fn storeSnapshot(self: *LineCache, text: []const u8) !void {
        self.snapshot.clearRetainingCapacity();
        try self.snapshot.appendSlice(self.gpa, text);
    }

    fn firstRowStartingAtOrAfter(lines: []const Line, pos: usize) usize {
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (lines[mid].start < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
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

fn testKernAdvance(_: ?*anyopaque, text: []const u8, byte_offset: usize, font_size: f32) Advance {
    const len = utf8Len(text, byte_offset);
    var w: f32 = if (text[byte_offset] == ' ') font_size * 0.3 else font_size * 0.5 + @as(f32, @floatFromInt(text[byte_offset] % 3));
    const next = byte_offset + len;
    if (next < text.len and text[next] != '\n' and text[next] == 'a') w -= 0.75; // "kerning"
    return .{ .byte_len = @min(len, text.len - byte_offset), .width = w };
}

fn expectSameLines(text: []const u8, metrics: FontMetrics, width: f32, wrap: bool, got: []const Line) !void {
    var iter = LineIterator.init(text, metrics, width, wrap);
    var i: usize = 0;
    while (iter.next()) |want| : (i += 1) {
        try std.testing.expect(i < got.len);
        try std.testing.expectEqual(want.row, got[i].row);
        try std.testing.expectEqual(want.start, got[i].start);
        try std.testing.expectEqual(want.end, got[i].end);
    }
    try std.testing.expectEqual(i, got.len);
}

test "line cache: incremental sync equals a full re-wrap under random edits" {
    const gpa = std.testing.allocator;
    const metrics: FontMetrics = .{ .font_size = 10, .line_height = 12, .advance = testKernAdvance };
    var cache = LineCache.init(gpa);
    defer cache.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const alphabet = "aab cd efg\n\n  é";
    for (0..3000) |step| {
        const op = r.uintLessThan(u8, 10);
        if (op < 6 or text.items.len == 0) {
            const at = r.uintAtMost(usize, text.items.len);
            var ins: [8]u8 = undefined;
            const n = r.uintAtMost(usize, ins.len - 1) + 1;
            for (ins[0..n]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len - 2)];
            if (r.uintLessThan(u8, 8) == 0) {
                ins[0] = 0xC3;
                if (n > 1) ins[1] = 0xA9; // 'é' (keep valid UTF-8 when it fits)
            }
            try text.insertSlice(gpa, at, ins[0..n]);
        } else if (op < 9) {
            const at = r.uintLessThan(usize, text.items.len);
            const n = @min(r.uintAtMost(usize, 6) + 1, text.items.len - at);
            text.replaceRangeAssumeCapacity(at, n, &.{});
        } else {
            const at = r.uintLessThan(usize, text.items.len);
            text.items[at] = alphabet[r.uintLessThan(usize, alphabet.len - 2)];
        }
        const width: f32 = if (step % 500 == 499) 40 else 60;
        const wrap = step % 700 != 699;
        const got = cache.sync(text.items, metrics, width, wrap).?;
        try expectSameLines(text.items, metrics, width, wrap, got);
    }
    try std.testing.expect(cache.stats.partial > cache.stats.full);
}

test "line cache: cached options give identical runs, positions and offsets" {
    const gpa = std.testing.allocator;
    const metrics: FontMetrics = .{ .font_size = 10, .line_height = 12, .advance = testKernAdvance };
    var cache = LineCache.init(gpa);
    defer cache.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..60) |i| try text.print(gpa, "{d}: a quick brown fox aaa jumps\n", .{i});
    const base: Options = .{
        .rect = .{ .x = 5, .y = 7, .w = 90, .h = 100 },
        .text = text.items,
        .color = draw.Color.white,
        .metrics = metrics,
        .scroll = .{ .y = 130 },
        .clip = .{ .x = 5, .y = 7, .w = 90, .h = 100 },
    };
    var cached = base;
    cached.lines = cache.sync(text.items, metrics, base.rect.w, true).?;

    var a: std.ArrayList(draw.TextRun) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(draw.TextRun) = .empty;
    defer b.deinit(gpa);
    try appendRuns(gpa, base, &a);
    try appendRuns(gpa, cached, &b);
    try std.testing.expect(a.items.len > 0);
    try std.testing.expectEqual(a.items.len, b.items.len);
    for (a.items, b.items) |x, y| {
        try std.testing.expectEqual(x.byte_start, y.byte_start);
        try std.testing.expectEqual(x.byte_end, y.byte_end);
        try std.testing.expectEqual(x.y, y.y);
    }
    var off: usize = 0;
    while (off <= text.items.len) : (off += 7) {
        try std.testing.expectEqual(positionForOffset(base, off), positionForOffset(cached, off));
    }
    var py: f32 = 0;
    while (py < 300) : (py += 5) {
        const pt: draw.Vec2 = .{ .x = 40, .y = py };
        try std.testing.expectEqual(offsetForPoint(base, pt), offsetForPoint(cached, pt));
    }
    for (0..200) |row| {
        try std.testing.expectEqual(
            offsetAtVisualCell(text.items, row, 33, metrics, base.rect.w, true),
            offsetAtVisualCellLines(text.items, cached.lines.?, row, 33, metrics),
        );
    }
    var ra: std.ArrayList(draw.Rect) = .empty;
    defer ra.deinit(gpa);
    var rb: std.ArrayList(draw.Rect) = .empty;
    defer rb.deinit(gpa);
    try appendSelectionRects(gpa, base, .{ .start = 30, .end = 400 }, &ra);
    try appendSelectionRects(gpa, cached, .{ .start = 30, .end = 400 }, &rb);
    try std.testing.expectEqualSlices(draw.Rect, ra.items, rb.items);
}
