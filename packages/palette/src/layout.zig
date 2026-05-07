//! Runtime layout helpers for retained Palette components.

const std = @import("std");
const draw = @import("draw.zig");

pub const Edges = extern struct {
    top: f32 = 0.0,
    right: f32 = 0.0,
    bottom: f32 = 0.0,
    left: f32 = 0.0,

    pub fn all(value: f32) Edges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn xy(x: f32, y: f32) Edges {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }

    pub fn axis(horizontal: f32, vertical: f32) Edges {
        return xy(horizontal, vertical);
    }
};

pub const Box = struct {
    rect: draw.Rect = .{},
    padding: Edges = .{},
    margin: Edges = .{},

    pub fn bounds(self: Box) draw.Rect {
        return shrink(self.rect, self.margin);
    }

    pub fn contentRect(self: Box) draw.Rect {
        return shrink(self.bounds(), self.padding);
    }
};

pub const FlexDirection = enum {
    row,
    column,
};

pub const Align = enum {
    start,
    center,
    end,
    stretch,
};

pub const Justify = enum {
    start,
    center,
    end,
    space_between,
};

pub const FlexConfig = struct {
    direction: FlexDirection = .row,
    wrap: bool = false,
    gap: f32 = 0.0,
    row_gap: ?f32 = null,
    column_gap: ?f32 = null,
    padding: Edges = .{},
    align_items: Align = .stretch,
    justify_content: Justify = .start,
};

pub const FlexItem = struct {
    basis_w: f32 = 0.0,
    basis_h: f32 = 0.0,
    grow: f32 = 0.0,
    min_w: f32 = 0.0,
    min_h: f32 = 0.0,
    max_w: f32 = std.math.inf(f32),
    max_h: f32 = std.math.inf(f32),
    margin: Edges = .{},

    pub fn fixed(w: f32, h: f32) FlexItem {
        return .{ .basis_w = w, .basis_h = h };
    }

    pub fn fill(h: f32, grow: f32) FlexItem {
        return .{ .basis_h = h, .grow = grow };
    }
};

pub const Track = union(enum) {
    px: f32,
    fr: f32,
};

pub const GridConfig = struct {
    columns: []const Track = &.{},
    rows: []const Track = &.{},
    gap_x: f32 = 0.0,
    gap_y: f32 = 0.0,
    padding: Edges = .{},
};

pub const GridItem = struct {
    column: usize = 0,
    row: usize = 0,
    column_span: usize = 1,
    row_span: usize = 1,
    margin: Edges = .{},
};

pub fn inset(rect: draw.Rect, edges: Edges) draw.Rect {
    return shrink(rect, edges);
}

pub fn flex(container: draw.Rect, config: FlexConfig, items: []const FlexItem, out: []draw.Rect) void {
    std.debug.assert(out.len >= items.len);
    if (items.len == 0) return;

    const content = shrink(container, config.padding);
    switch (config.direction) {
        .row => flexRow(content, config, items, out[0..items.len]),
        .column => flexColumn(content, config, items, out[0..items.len]),
    }
}

pub fn grid(allocator: std.mem.Allocator, container: draw.Rect, config: GridConfig, items: []const GridItem, out: []draw.Rect) !void {
    std.debug.assert(out.len >= items.len);
    if (items.len == 0) return;

    const content = shrink(container, config.padding);
    const column_count = @max(config.columns.len, 1);
    const row_count = @max(config.rows.len, 1);
    const columns = try allocator.alloc(f32, column_count);
    defer allocator.free(columns);
    const rows = try allocator.alloc(f32, row_count);
    defer allocator.free(rows);

    resolveTracks(config.columns, content.w, config.gap_x, columns);
    resolveTracks(config.rows, content.h, config.gap_y, rows);

    for (items, out[0..items.len]) |item, *rect| {
        const column = @min(item.column, column_count - 1);
        const row = @min(item.row, row_count - 1);
        const column_span = @max(@min(item.column_span, column_count - column), 1);
        const row_span = @max(@min(item.row_span, row_count - row), 1);
        rect.* = shrink(.{
            .x = content.x + trackOffset(columns, config.gap_x, column),
            .y = content.y + trackOffset(rows, config.gap_y, row),
            .w = trackSpan(columns, config.gap_x, column, column_span),
            .h = trackSpan(rows, config.gap_y, row, row_span),
        }, item.margin);
    }
}

pub fn applyFlex(container: draw.Rect, config: FlexConfig, specs: anytype, components: anytype) void {
    const len = tupleLen(@TypeOf(components));
    comptime {
        if (tupleLen(@TypeOf(specs)) != len) {
            @compileError("layout.applyFlex requires one FlexItem per component");
        }
    }
    var items: [len]FlexItem = undefined;
    var rects: [len]draw.Rect = undefined;
    inline for (0..len) |index| {
        items[index] = specs[index];
    }
    flex(container, config, &items, &rects);
    inline for (0..len) |index| {
        components[index].setBounds(rects[index]);
    }
}

pub fn applyGrid(allocator: std.mem.Allocator, container: draw.Rect, config: GridConfig, specs: anytype, components: anytype) !void {
    const len = tupleLen(@TypeOf(components));
    comptime {
        if (tupleLen(@TypeOf(specs)) != len) {
            @compileError("layout.applyGrid requires one GridItem per component");
        }
    }
    var items: [len]GridItem = undefined;
    var rects: [len]draw.Rect = undefined;
    inline for (0..len) |index| {
        items[index] = specs[index];
    }
    try grid(allocator, container, config, &items, &rects);
    inline for (0..len) |index| {
        components[index].setBounds(rects[index]);
    }
}

fn flexRow(content: draw.Rect, config: FlexConfig, items: []const FlexItem, out: []draw.Rect) void {
    const main_gap = config.column_gap orelse config.gap;
    const cross_gap = config.row_gap orelse config.gap;
    var start: usize = 0;
    var line_y = content.y;
    while (start < items.len) {
        var end = start;
        var used: f32 = 0.0;
        var grow: f32 = 0.0;
        var line_h: f32 = 0.0;
        while (end < items.len) : (end += 1) {
            const outer_w = itemMain(items[end], .row);
            const next_used = used + outer_w + if (end == start) 0.0 else main_gap;
            if (config.wrap and end > start and next_used > content.w) break;
            used = next_used;
            grow += @max(items[end].grow, 0.0);
            line_h = @max(line_h, itemCross(items[end], .row));
        }
        if (!config.wrap) line_h = content.h;
        layoutRowLine(content, config, items[start..end], out[start..end], line_y, line_h, used, grow, main_gap);
        line_y += line_h + cross_gap;
        start = end;
    }
}

fn flexColumn(content: draw.Rect, config: FlexConfig, items: []const FlexItem, out: []draw.Rect) void {
    const main_gap = config.row_gap orelse config.gap;
    const cross_gap = config.column_gap orelse config.gap;
    var start: usize = 0;
    var line_x = content.x;
    while (start < items.len) {
        var end = start;
        var used: f32 = 0.0;
        var grow: f32 = 0.0;
        var line_w: f32 = 0.0;
        while (end < items.len) : (end += 1) {
            const outer_h = itemMain(items[end], .column);
            const next_used = used + outer_h + if (end == start) 0.0 else main_gap;
            if (config.wrap and end > start and next_used > content.h) break;
            used = next_used;
            grow += @max(items[end].grow, 0.0);
            line_w = @max(line_w, itemCross(items[end], .column));
        }
        if (!config.wrap) line_w = content.w;
        layoutColumnLine(content, config, items[start..end], out[start..end], line_x, line_w, used, grow, main_gap);
        line_x += line_w + cross_gap;
        start = end;
    }
}

fn layoutRowLine(content: draw.Rect, config: FlexConfig, items: []const FlexItem, out: []draw.Rect, line_y: f32, line_h: f32, used: f32, grow: f32, gap: f32) void {
    const remaining = @max(content.w - used, 0.0);
    const justify = justifyOffset(config.justify_content, remaining, items.len);
    const distributed_gap = gap + justify.extra_gap;
    var x = content.x + justify.offset;
    for (items, out) |item, *rect| {
        const extra = if (grow > 0.0) remaining * (@max(item.grow, 0.0) / grow) else 0.0;
        const outer_w = item.basis_w + item.margin.left + item.margin.right + extra;
        var child_h = item.basis_h;
        var y = line_y + item.margin.top;
        switch (config.align_items) {
            .start => {},
            .center => y = line_y + (line_h - itemCross(item, .row)) * 0.5 + item.margin.top,
            .end => y = line_y + line_h - itemCross(item, .row) + item.margin.top,
            .stretch => child_h = @max(line_h - item.margin.top - item.margin.bottom, item.min_h),
        }
        rect.* = .{
            .x = x + item.margin.left,
            .y = y,
            .w = clamp(outer_w - item.margin.left - item.margin.right, item.min_w, item.max_w),
            .h = clamp(child_h, item.min_h, item.max_h),
        };
        x += outer_w + distributed_gap;
    }
}

fn layoutColumnLine(content: draw.Rect, config: FlexConfig, items: []const FlexItem, out: []draw.Rect, line_x: f32, line_w: f32, used: f32, grow: f32, gap: f32) void {
    const remaining = @max(content.h - used, 0.0);
    const justify = justifyOffset(config.justify_content, remaining, items.len);
    const distributed_gap = gap + justify.extra_gap;
    var y = content.y + justify.offset;
    for (items, out) |item, *rect| {
        const extra = if (grow > 0.0) remaining * (@max(item.grow, 0.0) / grow) else 0.0;
        const outer_h = item.basis_h + item.margin.top + item.margin.bottom + extra;
        var child_w = item.basis_w;
        var x = line_x + item.margin.left;
        switch (config.align_items) {
            .start => {},
            .center => x = line_x + (line_w - itemCross(item, .column)) * 0.5 + item.margin.left,
            .end => x = line_x + line_w - itemCross(item, .column) + item.margin.left,
            .stretch => child_w = @max(line_w - item.margin.left - item.margin.right, item.min_w),
        }
        rect.* = .{
            .x = x,
            .y = y + item.margin.top,
            .w = clamp(child_w, item.min_w, item.max_w),
            .h = clamp(outer_h - item.margin.top - item.margin.bottom, item.min_h, item.max_h),
        };
        y += outer_h + distributed_gap;
    }
}

const JustifyOffset = struct {
    offset: f32,
    extra_gap: f32,
};

fn justifyOffset(justify_content: Justify, remaining: f32, item_count: usize) JustifyOffset {
    return switch (justify_content) {
        .start => .{ .offset = 0.0, .extra_gap = 0.0 },
        .center => .{ .offset = remaining * 0.5, .extra_gap = 0.0 },
        .end => .{ .offset = remaining, .extra_gap = 0.0 },
        .space_between => .{ .offset = 0.0, .extra_gap = if (item_count > 1) remaining / @as(f32, @floatFromInt(item_count - 1)) else 0.0 },
    };
}

fn itemMain(item: FlexItem, direction: FlexDirection) f32 {
    return switch (direction) {
        .row => item.basis_w + item.margin.left + item.margin.right,
        .column => item.basis_h + item.margin.top + item.margin.bottom,
    };
}

fn itemCross(item: FlexItem, direction: FlexDirection) f32 {
    return switch (direction) {
        .row => item.basis_h + item.margin.top + item.margin.bottom,
        .column => item.basis_w + item.margin.left + item.margin.right,
    };
}

fn resolveTracks(tracks: []const Track, available: f32, gap: f32, out: []f32) void {
    if (out.len == 0) return;
    if (tracks.len == 0) {
        out[0] = available;
        return;
    }

    const gap_total = gap * @as(f32, @floatFromInt(out.len - 1));
    var fixed: f32 = 0.0;
    var fraction: f32 = 0.0;
    for (out, 0..) |*size, index| {
        const track = tracks[@min(index, tracks.len - 1)];
        switch (track) {
            .px => |value| {
                size.* = @max(value, 0.0);
                fixed += size.*;
            },
            .fr => |value| {
                size.* = 0.0;
                fraction += @max(value, 0.0);
            },
        }
    }

    const remaining = @max(available - fixed - gap_total, 0.0);
    if (fraction <= 0.0) return;
    for (out, 0..) |*size, index| {
        const track = tracks[@min(index, tracks.len - 1)];
        if (track == .fr) size.* = remaining * (@max(track.fr, 0.0) / fraction);
    }
}

fn trackOffset(tracks: []const f32, gap: f32, index: usize) f32 {
    var offset: f32 = 0.0;
    for (tracks[0..index]) |track| {
        offset += track + gap;
    }
    return offset;
}

fn trackSpan(tracks: []const f32, gap: f32, start: usize, span: usize) f32 {
    var size: f32 = 0.0;
    for (tracks[start .. start + span], 0..) |track, index| {
        size += track;
        if (index + 1 < span) size += gap;
    }
    return size;
}

fn shrink(rect: draw.Rect, edges: Edges) draw.Rect {
    const x = rect.x + edges.left;
    const y = rect.y + edges.top;
    return .{
        .x = x,
        .y = y,
        .w = @max(rect.w - edges.left - edges.right, 0.0),
        .h = @max(rect.h - edges.top - edges.bottom, 0.0),
    };
}

fn clamp(value: f32, min: f32, max: f32) f32 {
    return @min(@max(value, min), max);
}

fn tupleLen(comptime T: type) comptime_int {
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple) {
        @compileError("expected a tuple");
    }
    return info.@"struct".fields.len;
}

test "box exposes padded content rect" {
    const box: Box = .{
        .rect = .{ .x = 10, .y = 20, .w = 100, .h = 80 },
        .margin = Edges.xy(4, 2),
        .padding = Edges.all(8),
    };
    try std.testing.expectEqual(draw.Rect{ .x = 14, .y = 22, .w = 92, .h = 76 }, box.bounds());
    try std.testing.expectEqual(draw.Rect{ .x = 22, .y = 30, .w = 76, .h = 60 }, box.contentRect());
}

test "flex row grows and honors margins gaps and padding" {
    const items = [_]FlexItem{
        .{ .basis_w = 50, .basis_h = 20, .margin = Edges.xy(5, 0) },
        .{ .basis_w = 10, .basis_h = 20, .grow = 1 },
    };
    var rects: [2]draw.Rect = undefined;
    flex(.{ .x = 0, .y = 0, .w = 200, .h = 50 }, .{ .gap = 10, .padding = Edges.all(5), .align_items = .stretch }, &items, &rects);
    try std.testing.expectEqual(draw.Rect{ .x = 10, .y = 5, .w = 50, .h = 40 }, rects[0]);
    try std.testing.expectEqual(draw.Rect{ .x = 75, .y = 5, .w = 120, .h = 40 }, rects[1]);
}

test "flex row wraps onto new lines" {
    const items = [_]FlexItem{
        FlexItem.fixed(60, 20),
        FlexItem.fixed(60, 20),
        FlexItem.fixed(60, 20),
    };
    var rects: [3]draw.Rect = undefined;
    flex(.{ .w = 130, .h = 80 }, .{ .wrap = true, .gap = 10, .align_items = .start }, &items, &rects);
    try std.testing.expectEqual(@as(f32, 0), rects[0].y);
    try std.testing.expectEqual(@as(f32, 0), rects[1].y);
    try std.testing.expectEqual(@as(f32, 30), rects[2].y);
}

test "grid resolves fixed and fractional tracks with spans" {
    const columns = [_]Track{ .{ .px = 50 }, .{ .fr = 1 }, .{ .fr = 2 } };
    const rows = [_]Track{ .{ .px = 20 }, .{ .fr = 1 } };
    const items = [_]GridItem{
        .{ .column = 1, .row = 0, .column_span = 2, .row_span = 2, .margin = Edges.all(2) },
    };
    var rects: [1]draw.Rect = undefined;
    try grid(std.testing.allocator, .{ .w = 260, .h = 100 }, .{ .columns = &columns, .rows = &rows, .gap_x = 10, .gap_y = 5 }, &items, &rects);
    try std.testing.expectEqual(draw.Rect{ .x = 62, .y = 2, .w = 196, .h = 96 }, rects[0]);
}

test "apply flex sets component bounds" {
    const Component = struct {
        rect: draw.Rect = .{},

        fn setBounds(self: *@This(), rect: draw.Rect) void {
            self.rect = rect;
        }
    };
    var first: Component = .{};
    var second: Component = .{};
    applyFlex(
        .{ .w = 100, .h = 30 },
        .{ .gap = 4, .align_items = .stretch },
        .{ FlexItem.fixed(20, 10), FlexItem{ .basis_w = 10, .basis_h = 10, .grow = 1 } },
        .{ &first, &second },
    );
    try std.testing.expectEqual(draw.Rect{ .x = 0, .y = 0, .w = 20, .h = 30 }, first.rect);
    try std.testing.expectEqual(draw.Rect{ .x = 24, .y = 0, .w = 76, .h = 30 }, second.rect);
}
