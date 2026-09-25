//! Independent, bounded libghostty-vt handle. No OS effects or content logging.
const std = @import("std");
const vt = @import("ghostty-vt");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const A = std.mem.Allocator;
const Stream = @TypeOf((@as(*vt.Terminal, undefined)).vtStream());
const Handler = @FieldType(Stream, "handler");
pub const Config = struct { api_version: u32 = 1, cols: u16, rows: u16, scrollback_rows: u32 };
pub const CursorShape = enum { block, underline, bar };
pub const Cursor = struct { row: u16, col: u16, visible: bool, shape: CursorShape };
pub const Cell = struct { text: []const u8, width: u8, fg: []const u8, bg: []const u8, bold: bool, italic: bool, underline: bool, strikethrough: bool, inverse: bool };
pub const Snapshot = struct {
    api_version: u32 = 1,
    revision: []const u8,
    cols: u16,
    rows: u16,
    scroll_offset: u32,
    scrollback_rows: u32,
    reply_bytes_base64: []const u8,
    reverse_video: bool,
    vt_modes: @import("wire.zig").VtModes,
    cursor: Cursor,
    cells: []const Cell,
    title: []const u8,
};
pub fn dimensions(cols: u16, rows: u16) h.ApiError!void {
    if (cols == 0 or rows == 0) return error.InvalidArgument;
    if (cols > 512 or rows > 512 or @as(u32, cols) * rows > 65536) return error.ResourceLimit;
}
pub const Terminal = struct {
    allocator: A,
    terminal: vt.Terminal,
    stream: Stream,
    revision: u64 = 0,
    replies: std.ArrayList(u8) = .empty,
    reply_failed: bool = false,

    pub fn create(a: A, input: []const u8) h.ApiError!*Terminal {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const value = try h.parse(arena.allocator(), input);
        const config = try h.decode(Config, arena.allocator(), value);
        if (config.api_version != 1) return error.UnsupportedVersion;
        try dimensions(config.cols, config.rows);
        if (config.scrollback_rows > 10000) return error.ResourceLimit;
        const self = try a.create(Terminal);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .terminal = vt.Terminal.init((vt.TinyIo.init).io(), a, .{
            .cols = config.cols,
            .rows = config.rows,
            .max_scrollback_bytes = if (config.scrollback_rows == 0) 0 else 16 * 1024 * 1024,
            .max_scrollback_lines = config.scrollback_rows,
        }) catch |err| return h.mapError(err), .stream = undefined };
        self.stream = self.terminal.vtStream();
        self.stream.handler.effects.write_pty = reply;
        return self;
    }
    pub fn destroy(self: *Terminal) void {
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.replies.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn write(self: *Terminal, bytes: []const u8) h.ApiError!void {
        if (bytes.len > h.MAX_INPUT) return error.ResourceLimit;
        if (self.reply_failed or self.stream.handler.semantic_failure) return error.InvalidLifecycle;
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        self.stream.nextSlice(bytes);
        self.revision += 1;
        if (self.stream.handler.semantic_failure) return error.OutOfMemory;
        if (self.reply_failed) return error.ResourceLimit;
    }
    pub fn resize(self: *Terminal, cols: u16, rows: u16) h.ApiError!void {
        try dimensions(cols, rows);
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        self.terminal.resize(self.allocator, .{ .cols = cols, .rows = rows }) catch |err| return h.mapError(err);
        self.revision += 1;
    }
    pub fn scroll(self: *Terminal, delta: i32) h.ApiError!void {
        if (self.revision == std.math.maxInt(u64)) return error.ResourceLimit;
        self.terminal.scrollViewport(.{ .delta = -@as(isize, delta) });
        self.revision += 1;
    }
    /// Peek allows JNI to allocate its output before consuming device replies.
    pub fn snapshot(self: *Terminal, a: A) h.ApiError![]u8 {
        if (self.reply_failed or self.stream.handler.semantic_failure) return error.InvalidLifecycle;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp = arena.allocator();
        var render: vt.RenderState = .empty;
        defer render.deinit(self.allocator);
        render.update(self.allocator, &self.terminal) catch |err| return h.mapError(err);
        const cells = try temp.alloc(Cell, @as(usize, render.cols) * render.rows);
        var index: usize = 0;
        for (render.row_data.items(.cells)) |row| {
            const data = row.slice();
            for (data.items(.raw), 0..) |raw, col| {
                const style: vt.Style = if (raw.style_id == 0) .{} else data.items(.style)[col];
                var text: std.ArrayList(u8) = .empty;
                if (raw.hasText() and raw.wide != .spacer_tail) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(raw.codepoint(), &buf) catch return error.InvalidArgument;
                    try text.appendSlice(temp, buf[0..len]);
                    if (raw.hasGrapheme()) for (data.items(.grapheme)[col]) |cp| {
                        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidArgument;
                        try text.appendSlice(temp, buf[0..n]);
                    };
                }
                cells[index] = .{
                    .text = if (style.flags.invisible) "" else text.items,
                    .width = switch (raw.wide) {
                        .spacer_tail, .spacer_head => 0,
                        .wide => 2,
                        else => 1,
                    },
                    .fg = try color(temp, style.fg(.{ .default = render.colors.foreground, .palette = &render.colors.palette })),
                    .bg = try color(temp, style.bg(&raw, &render.colors.palette) orelse render.colors.background),
                    .bold = style.flags.bold,
                    .italic = style.flags.italic,
                    .underline = style.flags.underline != .none,
                    .strikethrough = style.flags.strikethrough,
                    .inverse = style.flags.inverse,
                };
                index += 1;
            }
        }
        const bar = self.terminal.screens.active.pages.scrollbar();
        const cursor = render.cursor;
        return h.encode(a, Snapshot{
            .revision = try std.fmt.allocPrint(temp, "{d}", .{self.revision}),
            .cols = render.cols,
            .rows = render.rows,
            .scroll_offset = @intCast(bar.total -| bar.len -| bar.offset),
            .scrollback_rows = @intCast(bar.total -| bar.len),
            .reply_bytes_base64 = try rpc.encodeBase64(temp, self.replies.items),
            .reverse_video = self.terminal.modes.get(.reverse_colors),
            .vt_modes = .{ .application_cursor = self.terminal.modes.get(.cursor_keys), .bracketed_paste = self.terminal.modes.get(.bracketed_paste) },
            .cursor = .{ .row = if (cursor.viewport) |v| v.y else @intCast(cursor.active.y), .col = if (cursor.viewport) |v| v.x else @intCast(cursor.active.x), .visible = cursor.visible and cursor.viewport != null, .shape = switch (cursor.visual_style) {
                .bar => .bar,
                .underline => .underline,
                else => .block,
            } },
            .cells = cells,
            .title = self.terminal.getTitle() orelse "",
        });
    }
    pub fn consumeReplies(self: *Terminal) void {
        self.replies.clearRetainingCapacity();
    }
    fn reply(handler: *Handler, bytes: [:0]const u8) void {
        const self: *Terminal = @fieldParentPtr("terminal", handler.terminal);
        if (self.replies.items.len + bytes.len > 65536) {
            self.reply_failed = true;
            return;
        }
        self.replies.appendSlice(self.allocator, bytes) catch {
            self.reply_failed = true;
        };
    }
};
fn color(a: A, rgb: vt.color.RGB) ![]const u8 {
    return std.fmt.allocPrint(a, "#{X:0>2}{X:0>2}{X:0>2}", .{ rgb.r, rgb.g, rgb.b });
}
