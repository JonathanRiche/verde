//! Compact zig_markdown projection with source-byte ranges and inert citations.
const std = @import("std");
const md = @import("zig_markdown");
const rendering = @import("rendering.zig");
const A = std.mem.Allocator;
const Error = rendering.Error;
const eq = rendering.eq;

/// `end_line` is set only for a range (`#L10-L20`, `:10-20`) and is never before `line`.
pub const Citation = struct { path: []const u8, line: ?usize = null, end_line: ?usize = null };
pub const Node = struct {
    kind: []const u8,
    start: usize,
    end: usize,
    text: ?[]const u8 = null,
    level: ?u8 = null,
    ordered: ?bool = null,
    url: ?[]const u8 = null,
    language: ?[]const u8 = null,
    children: []const Node = &.{},
    citation: ?Citation = null,
};
pub const Markdown = struct { nodes: []const Node };

pub fn render(a: A, source: []const u8) Error!Markdown {
    // Bound recursive work before entering the shared parser (which has no
    // configurable nesting limit). Long prose/code lines remain unrestricted.
    var paragraph_markers: usize = 0;
    var fence: ?u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t>");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            if (fence == null) {
                fence = trimmed[0];
            } else if (fence.? == trimmed[0]) {
                fence = null;
            }
            paragraph_markers = 0;
            continue;
        }
        if (fence != null) continue;
        if (trimmed.len == 0) paragraph_markers = 0;
        var markers: usize = 0;
        for (line) |c| if (std.mem.indexOfScalar(u8, "*>[_~", c) != null) {
            markers += 1;
        };
        paragraph_markers += markers;
        if (markers > 64 or paragraph_markers > 512) return error.ResourceLimit;
    }
    // Protect directive attributes from markdown emphasis (filenames may contain
    // underscores, brackets, or stars). Equal-length masking preserves offsets;
    // code and text leaves are restored from the original source below.
    const masked = try a.dupe(u8, source);
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, source, search, ":codex-file-citation{")) |pos| {
        const end = std.mem.indexOfScalarPos(u8, source, pos, '}') orelse break;
        if (std.mem.indexOfScalar(u8, source[pos..end], '\n') == null) @memset(masked[pos .. end + 1], 'X');
        search = end + 1;
    }
    var document = try md.parse(a, masked);
    defer document.deinit(a);
    var builder: Builder = .{ .a = a, .source = source, .masked = masked };
    const children = try builder.blocks(document.blocks, 0);
    const nodes = try a.alloc(Node, 1);
    nodes[0] = .{ .kind = "document", .start = 0, .end = source.len, .children = children };
    return .{ .nodes = nodes };
}

const Builder = struct {
    a: A,
    source: []const u8,
    masked: []const u8,
    cursor: usize = 0,
    count: usize = 0,
    context: ?struct { text: []const u8, offsets: []const usize } = null,

    fn mapText(self: *Builder, text: []const u8) Error!void {
        const offsets = try self.a.alloc(usize, text.len + 1);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var index: usize = 0;
        var cursor = self.cursor;
        while (lines.next()) |line| {
            const pos = std.mem.indexOfPos(u8, self.masked, cursor, line) orelse return error.InvalidInput;
            for (0..line.len) |i| offsets[index + i] = pos + i;
            index += line.len;
            cursor = pos + line.len;
            if (lines.peek() != null) {
                cursor = std.mem.indexOfScalarPos(u8, self.masked, cursor, '\n') orelse return error.InvalidInput;
                offsets[index] = cursor;
                index += 1;
                cursor += 1;
            }
        }
        offsets[text.len] = cursor;
        self.context = .{ .text = text, .offsets = offsets };
    }

    fn mappedIndex(self: *Builder, text: []const u8) ?usize {
        const context = self.context orelse return null;
        const ptr = @intFromPtr(text.ptr);
        const base = @intFromPtr(context.text.ptr);
        if (ptr < base or ptr - base > context.text.len or text.len > context.text.len - (ptr - base)) return null;
        return ptr - base;
    }

    fn locate(self: *Builder, text: []const u8) Error!usize {
        if (self.mappedIndex(text)) |index| return self.context.?.offsets[index];
        return std.mem.indexOfPos(u8, self.masked, self.cursor, text) orelse error.InvalidInput;
    }

    fn add(self: *Builder, list: *std.ArrayList(Node), node: Node) Error!void {
        self.count += 1;
        if (self.count > 4096) return error.ResourceLimit;
        try list.append(self.a, node);
    }

    fn blocks(self: *Builder, values: []const md.Block, depth: usize) Error![]const Node {
        if (depth > 32) return error.ResourceLimit;
        var out: std.ArrayList(Node) = .empty;
        for (values) |block| {
            if (block == .blank) continue;
            const top = depth == 0;
            if (top) self.cursor = block.span().start_byte;
            const start = self.cursor;
            var node: Node = .{ .kind = "paragraph", .start = start, .end = start };
            switch (block) {
                .paragraph => |p| {
                    try self.mapText(p.text);
                    node.children = try self.inlines(p.inlines, depth + 1);
                    self.context = null;
                },
                .heading => |h| {
                    node.kind = "heading";
                    node.level = h.level;
                    try self.mapText(h.text);
                    node.children = try self.inlines(h.inlines, depth + 1);
                    self.context = null;
                },
                .fenced_code => |code| {
                    node.kind = "code_block";
                    // Start after the opening fence: code may repeat its
                    // language name or a shorter backtick run verbatim.
                    self.cursor = if (std.mem.indexOfScalarPos(u8, self.source, self.cursor, '\n')) |nl| nl + 1 else self.source.len;
                    node.text = try self.restoreCode(code.code);
                    node.language = if (code.language) |lang| try self.a.dupe(u8, lang) else null;
                },
                .block_quote => |q| {
                    node.kind = "quote";
                    node.children = try self.blocks(q.blocks, depth + 1);
                },
                .list => |list| {
                    node.kind = "list";
                    node.ordered = list.kind == .ordered;
                    var items: std.ArrayList(Node) = .empty;
                    for (list.items) |item| {
                        const item_start = self.cursor;
                        const children = try self.blocks(item.blocks, depth + 1);
                        try self.add(&items, .{ .kind = "item", .start = item_start, .end = self.cursor, .children = children });
                    }
                    node.children = try items.toOwnedSlice(self.a);
                },
                .table => |table| {
                    node.kind = "table";
                    var rows: std.ArrayList(Node) = .empty;
                    try self.add(&rows, try self.row(table.header, depth + 1));
                    for (table.rows) |table_row| try self.add(&rows, try self.row(table_row, depth + 1));
                    node.children = try rows.toOwnedSlice(self.a);
                },
                .thematic_break => {
                    node.kind = "thematic_break";
                    self.cursor = std.mem.indexOfScalarPos(u8, self.source, self.cursor, '\n') orelse self.source.len;
                },
                .blank => unreachable,
            }
            node.end = self.cursor;
            if (top) {
                node.end = block.span().end_byte;
                self.cursor = node.end;
            }
            try self.add(&out, node);
        }
        return out.toOwnedSlice(self.a);
    }

    fn row(self: *Builder, value: md.TableRow, depth: usize) Error!Node {
        const start = self.cursor;
        var cells: std.ArrayList(Node) = .empty;
        for (value.cells) |cell| {
            const lo = self.cursor;
            const children = try self.inlines(cell.inlines, depth + 1);
            try self.add(&cells, .{ .kind = "table_cell", .start = lo, .end = self.cursor, .children = children });
        }
        return .{ .kind = "table_row", .start = start, .end = self.cursor, .children = try cells.toOwnedSlice(self.a) };
    }

    fn restoreCode(self: *Builder, code: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, code, '\n');
        var cursor = self.cursor;
        while (lines.next()) |line| {
            if (line.len > 0) {
                const pos = std.mem.indexOfPos(u8, self.masked, cursor, line) orelse return error.InvalidInput;
                try out.appendSlice(self.a, self.source[pos..][0..line.len]);
                cursor = pos + line.len;
            }
            if (lines.peek() != null) try out.append(self.a, '\n');
        }
        self.cursor = cursor;
        return out.toOwnedSlice(self.a);
    }

    fn leaf(self: *Builder, kind: []const u8, text: []const u8) Error!Node {
        const pos = std.mem.indexOfPos(u8, self.source, self.cursor, text) orelse return error.InvalidInput;
        self.cursor = pos + text.len;
        return .{ .kind = kind, .start = pos, .end = self.cursor, .text = try self.a.dupe(u8, text) };
    }

    fn inlines(self: *Builder, values: []const md.Inline, depth: usize) Error![]const Node {
        if (depth > 32) return error.ResourceLimit;
        var out: std.ArrayList(Node) = .empty;
        for (values) |value| {
            var node: Node = .{ .kind = "text", .start = self.cursor, .end = self.cursor };
            switch (value) {
                .text => |t| {
                    try self.textNodes(&out, t.text);
                    continue;
                },
                .code => |c| {
                    const pos = try self.locate(c.text);
                    const restored = try self.a.dupe(u8, c.text);
                    if (self.mappedIndex(c.text)) |index| {
                        for (restored, 0..) |*byte, i| byte.* = self.source[self.context.?.offsets[index + i]];
                        self.cursor = if (c.text.len == 0) pos else self.context.?.offsets[index + c.text.len - 1] + 1;
                    } else {
                        @memcpy(restored, self.source[pos..][0..c.text.len]);
                        self.cursor = pos + c.text.len;
                    }
                    node = .{ .kind = "code", .start = pos, .end = self.cursor, .text = restored };
                    // Skip closing delimiter so repeated text cannot bind to it.
                    while (self.cursor < self.source.len and self.source[self.cursor] == '`') self.cursor += 1;
                },
                .line_break => node = try self.leaf("line_break", "\n"),
                .emphasis, .strong, .strikethrough => |container| {
                    node.kind = switch (value) {
                        .emphasis => "emphasis",
                        .strong => "strong",
                        else => "strike",
                    };
                    node.children = try self.inlines(container.children, depth + 1);
                    node.end = self.cursor;
                    // Content ranges exclude syntax, matching inline leaf ranges.
                    if (node.children.len > 0) node.start = node.children[0].start;
                },
                .link => |link| {
                    node.kind = "link";
                    if (out.items.len > 0) {
                        const previous = &out.items[out.items.len - 1];
                        if (previous.text) |text| {
                            if (text.len > 0 and text[text.len - 1] == '!') {
                                node.kind = "image";
                                previous.text = text[0 .. text.len - 1];
                                previous.end -= 1;
                                if (text.len == 1) _ = out.pop();
                            }
                        }
                    }
                    node.children = try self.inlines(link.children, depth + 1);
                    if (node.children.len > 0) node.start = node.children[0].start;
                    node.end = self.cursor;
                    node.url = if (safeUrl(link.destination)) try self.a.dupe(u8, link.destination) else null;
                    node.citation = try citation(self.a, link.destination);
                    if (!eq(link.label, link.destination)) {
                        if (std.mem.indexOfPos(u8, self.source, self.cursor, link.destination)) |pos| {
                            self.cursor = pos + link.destination.len;
                            if (self.cursor < self.source.len and self.source[self.cursor] == ')') self.cursor += 1;
                        }
                    }
                },
            }
            try self.add(&out, node);
        }
        return out.toOwnedSlice(self.a);
    }

    fn textNodes(self: *Builder, out: *std.ArrayList(Node), text: []const u8) Error!void {
        const marker = ":codex-file-citation{";
        const mapped = try self.locate(text);
        self.cursor = mapped;
        var rest = self.source[mapped..][0..text.len];
        while (std.mem.indexOf(u8, rest, marker)) |pos| {
            const close = std.mem.indexOfScalarPos(u8, rest, pos + marker.len, '}') orelse break;
            const attrs = rest[pos + marker.len .. close];
            const path_marker = std.mem.indexOf(u8, attrs, "path=\"") orelse break;
            const path_start = path_marker + 6;
            const path_end = std.mem.indexOfScalarPos(u8, attrs, path_start, '"') orelse break;
            const path = attrs[path_start..path_end];
            if (path.len == 0) break;
            if (pos > 0) try self.add(out, try self.leaf("text", rest[0..pos]));
            var node = try self.leaf("link", rest[pos .. close + 1]);
            node.text = try self.a.dupe(u8, std.fs.path.basename(path));
            node.citation = .{ .path = try self.a.dupe(u8, path) };
            try self.add(out, node);
            rest = rest[close + 1 ..];
        }
        if (rest.len > 0) try self.add(out, try self.leaf("text", rest));
    }
};

fn safeUrl(url: []const u8) bool {
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    if (std.mem.startsWith(u8, url, "//")) return false;
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return true;
    const scheme = url[0..colon];
    return std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "mailto");
}

pub fn citation(a: A, destination: []const u8) Error!?Citation {
    var path = destination;
    if (std.mem.startsWith(u8, path, "/api/file?") or std.mem.startsWith(u8, path, "/api/preview?")) {
        var fields = std.mem.splitScalar(u8, path[std.mem.indexOfScalar(u8, path, '?').? + 1 ..], '&');
        var found: ?[]const u8 = null;
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "path=")) found = field[5..];
        }
        path = found orelse return null;
    }
    if (std.mem.startsWith(u8, path, "file://")) path = path[7..];
    path = std.Uri.percentDecodeInPlace(try a.dupe(u8, path));
    if (!std.unicode.utf8ValidateSlice(path)) return null;
    for (path) |c| if (c < 0x20 or c == 0x7f) return null;
    if (!std.mem.startsWith(u8, path, "/") or std.mem.startsWith(u8, path, "//") or std.mem.startsWith(u8, path, "/api/") or std.mem.startsWith(u8, path, "/assets/")) return null;
    var line: ?usize = null;
    var end_line: ?usize = null;
    var end = path.len;
    const marker = std.mem.lastIndexOf(u8, path, "#L") orelse std.mem.lastIndexOf(u8, path, ":");
    if (marker) |pos| {
        const start = pos + (if (path[pos] == '#') @as(usize, 2) else 1);
        const suffix = path[start..];
        const dash = std.mem.indexOfScalar(u8, suffix, '-');
        const n = lineNumber(suffix[0 .. dash orelse suffix.len]);
        if (n > 0) {
            if (dash) |d| {
                const last = lineNumber(std.mem.trimStart(u8, suffix[d + 1 ..], "L"));
                if (last >= n) {
                    line = n;
                    end_line = last;
                    end = pos;
                }
            } else {
                line = n;
                end = pos;
            }
        }
    }
    // Absolute paths must look like files; app routes such as /login are inert.
    if (line == null and std.fs.path.extension(path[0..end]).len == 0) return null;
    return .{ .path = try a.dupe(u8, path[0..end]), .line = line, .end_line = end_line };
}

/// Positive decimal line number within JS safe-integer range, or 0.
fn lineNumber(digits: []const u8) usize {
    for (digits) |c| if (!std.ascii.isDigit(c)) return 0;
    const n = std.fmt.parseInt(usize, digits, 10) catch return 0;
    return if (n <= 9007199254740991) n else 0;
}
