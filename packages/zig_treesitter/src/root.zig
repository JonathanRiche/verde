//! Typed Zig wrappers around the Tree-sitter C API.

const std = @import("std");

pub const c = @import("c.zig").bindings;
pub const grammars = struct {
    pub const javascript = @import("grammars/javascript.zig");
    pub const json = @import("grammars/json.zig");
    pub const typescript = @import("grammars/typescript.zig");
};

pub const Point = extern struct {
    row: u32,
    column: u32,

    pub fn toC(self: Point) c.TSPoint {
        return .{
            .row = self.row,
            .column = self.column,
        };
    }

    pub fn fromC(value: c.TSPoint) Point {
        return .{
            .row = value.row,
            .column = value.column,
        };
    }
};

pub const Range = extern struct {
    start_point: Point,
    end_point: Point,
    start_byte: u32,
    end_byte: u32,

    pub fn fromC(value: c.TSRange) Range {
        return .{
            .start_point = Point.fromC(value.start_point),
            .end_point = Point.fromC(value.end_point),
            .start_byte = value.start_byte,
            .end_byte = value.end_byte,
        };
    }
};

pub const InputEdit = extern struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_point: Point,
    old_end_point: Point,
    new_end_point: Point,

    pub fn toC(self: InputEdit) c.TSInputEdit {
        return .{
            .start_byte = self.start_byte,
            .old_end_byte = self.old_end_byte,
            .new_end_byte = self.new_end_byte,
            .start_point = self.start_point.toC(),
            .old_end_point = self.old_end_point.toC(),
            .new_end_point = self.new_end_point.toC(),
        };
    }
};

pub const Language = struct {
    raw: *const c.TSLanguage,

    pub fn fromRaw(raw: *const c.TSLanguage) Language {
        return .{ .raw = raw };
    }

    pub fn name(self: Language) []const u8 {
        return std.mem.span(c.ts_language_name(self.raw));
    }

    pub fn abiVersion(self: Language) u32 {
        return c.ts_language_abi_version(self.raw);
    }

    pub fn symbolCount(self: Language) u32 {
        return c.ts_language_symbol_count(self.raw);
    }

    pub fn fieldCount(self: Language) u32 {
        return c.ts_language_field_count(self.raw);
    }
};

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init() error{OutOfMemory}!Parser {
        const raw = c.ts_parser_new() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Parser) void {
        c.ts_parser_delete(self.raw);
        self.* = undefined;
    }

    pub fn setLanguage(self: *Parser, language: Language) bool {
        return c.ts_parser_set_language(self.raw, language.raw);
    }

    pub fn parseString(self: *Parser, source: []const u8, old_tree: ?Tree) ?Tree {
        const raw_tree = c.ts_parser_parse_string(
            self.raw,
            if (old_tree) |tree| tree.raw else null,
            source.ptr,
            @intCast(source.len),
        ) orelse return null;
        return .{ .raw = raw_tree };
    }

    pub fn reset(self: *Parser) void {
        c.ts_parser_reset(self.raw);
    }
};

pub const Tree = struct {
    raw: *c.TSTree,

    pub fn deinit(self: *Tree) void {
        c.ts_tree_delete(self.raw);
        self.* = undefined;
    }

    pub fn copy(self: Tree) error{OutOfMemory}!Tree {
        const raw = c.ts_tree_copy(self.raw) orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn rootNode(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw) };
    }

    pub fn edit(self: *Tree, input_edit: InputEdit) void {
        var c_edit = input_edit.toC();
        c.ts_tree_edit(self.raw, &c_edit);
    }
};

pub const Node = struct {
    raw: c.TSNode,

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }

    pub fn isNamed(self: Node) bool {
        return c.ts_node_is_named(self.raw);
    }

    pub fn isMissing(self: Node) bool {
        return c.ts_node_is_missing(self.raw);
    }

    pub fn isExtra(self: Node) bool {
        return c.ts_node_is_extra(self.raw);
    }

    pub fn hasError(self: Node) bool {
        return c.ts_node_has_error(self.raw);
    }

    pub fn kind(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }

    pub fn grammarKind(self: Node) []const u8 {
        return std.mem.span(c.ts_node_grammar_type(self.raw));
    }

    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.raw);
    }

    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.raw);
    }

    pub fn startPoint(self: Node) Point {
        return Point.fromC(c.ts_node_start_point(self.raw));
    }

    pub fn endPoint(self: Node) Point {
        return Point.fromC(c.ts_node_end_point(self.raw));
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn child(self: Node, index: u32) Node {
        return .{ .raw = c.ts_node_child(self.raw, index) };
    }

    pub fn namedChild(self: Node, index: u32) Node {
        return .{ .raw = c.ts_node_named_child(self.raw, index) };
    }

    pub fn parent(self: Node) Node {
        return .{ .raw = c.ts_node_parent(self.raw) };
    }

    pub fn nextSibling(self: Node) Node {
        return .{ .raw = c.ts_node_next_sibling(self.raw) };
    }

    pub fn nextNamedSibling(self: Node) Node {
        return .{ .raw = c.ts_node_next_named_sibling(self.raw) };
    }

    pub fn descendantForByteRange(self: Node, start: u32, end: u32) Node {
        return .{ .raw = c.ts_node_descendant_for_byte_range(self.raw, start, end) };
    }

    pub fn namedDescendantForByteRange(self: Node, start: u32, end: u32) Node {
        return .{ .raw = c.ts_node_named_descendant_for_byte_range(self.raw, start, end) };
    }

    pub fn utf8Text(self: Node, source: []const u8) []const u8 {
        const start: usize = @intCast(@min(self.startByte(), @as(u32, @intCast(source.len))));
        const end: usize = @intCast(@min(self.endByte(), @as(u32, @intCast(source.len))));
        if (end < start) return "";
        return source[start..end];
    }
};

pub const TreeCursor = struct {
    raw: c.TSTreeCursor,

    pub fn init(node: Node) TreeCursor {
        return .{ .raw = c.ts_tree_cursor_new(node.raw) };
    }

    pub fn deinit(self: *TreeCursor) void {
        c.ts_tree_cursor_delete(&self.raw);
        self.* = undefined;
    }

    pub fn currentNode(self: *const TreeCursor) Node {
        return .{ .raw = c.ts_tree_cursor_current_node(&self.raw) };
    }

    pub fn gotoParent(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_parent(&self.raw);
    }

    pub fn gotoNextSibling(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_next_sibling(&self.raw);
    }

    pub fn gotoFirstChild(self: *TreeCursor) bool {
        return c.ts_tree_cursor_goto_first_child(&self.raw);
    }
};

pub const QueryError = error{
    Syntax,
    NodeType,
    Field,
    Capture,
    Structure,
    Language,
    OutOfMemory,
};

pub const Query = struct {
    raw: *c.TSQuery,

    pub fn init(language: Language, source: []const u8) QueryError!Query {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = c.TSQueryErrorNone;
        const raw = c.ts_query_new(
            language.raw,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        ) orelse {
            return switch (error_type) {
                c.TSQueryErrorSyntax => error.Syntax,
                c.TSQueryErrorNodeType => error.NodeType,
                c.TSQueryErrorField => error.Field,
                c.TSQueryErrorCapture => error.Capture,
                c.TSQueryErrorStructure => error.Structure,
                c.TSQueryErrorLanguage => error.Language,
                else => error.OutOfMemory,
            };
        };
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Query) void {
        c.ts_query_delete(self.raw);
        self.* = undefined;
    }

    pub fn patternCount(self: Query) u32 {
        return c.ts_query_pattern_count(self.raw);
    }

    pub fn captureCount(self: Query) u32 {
        return c.ts_query_capture_count(self.raw);
    }

    pub fn captureName(self: Query, index: u32) ?[]const u8 {
        var length: u32 = 0;
        const raw = c.ts_query_capture_name_for_id(self.raw, index, &length) orelse return null;
        return raw[0..length];
    }
};

pub const QueryCapture = struct {
    node: Node,
    index: u32,
};

pub const QueryMatch = struct {
    id: u32,
    pattern_index: u16,
    captures: []const QueryCapture,

    pub fn deinit(self: QueryMatch, allocator: std.mem.Allocator) void {
        allocator.free(self.captures);
    }
};

pub const QueryCursor = struct {
    raw: *c.TSQueryCursor,

    pub fn init() error{OutOfMemory}!QueryCursor {
        const raw = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    pub fn deinit(self: *QueryCursor) void {
        c.ts_query_cursor_delete(self.raw);
        self.* = undefined;
    }

    pub fn exec(self: *QueryCursor, query: Query, node: Node) void {
        c.ts_query_cursor_exec(self.raw, query.raw, node.raw);
    }

    pub fn nextMatch(self: *QueryCursor, allocator: std.mem.Allocator) !?QueryMatch {
        var raw_match: c.TSQueryMatch = undefined;
        if (!c.ts_query_cursor_next_match(self.raw, &raw_match)) return null;

        const captures = try allocator.alloc(QueryCapture, raw_match.capture_count);
        for (captures, 0..) |*capture, index| {
            const raw_capture = raw_match.captures[index];
            capture.* = .{
                .node = .{ .raw = raw_capture.node },
                .index = raw_capture.index,
            };
        }

        return .{
            .id = raw_match.id,
            .pattern_index = raw_match.pattern_index,
            .captures = captures,
        };
    }
};

test "point converts to and from c value" {
    const point: Point = .{ .row = 3, .column = 9 };
    const c_point = point.toC();
    const roundtrip = Point.fromC(c_point);

    try std.testing.expectEqual(point.row, roundtrip.row);
    try std.testing.expectEqual(point.column, roundtrip.column);
}

test "typescript grammar parses a simple source file" {
    var parser = try Parser.init();
    defer parser.deinit();

    try std.testing.expect(parser.setLanguage(grammars.typescript.language()));
    var tree = parser.parseString("const value: string = \"verde\";\n", null) orelse return error.UnexpectedNull;
    defer tree.deinit();

    const root = tree.rootNode();
    try std.testing.expectEqualStrings("program", root.kind());
    try std.testing.expect(root.childCount() > 0);
}

test "typescript highlights query compiles" {
    var query = try Query.init(grammars.typescript.language(), grammars.typescript.highlights_query);
    defer query.deinit();

    try std.testing.expect(query.captureCount() > 0);
    try std.testing.expect(query.captureName(0) != null);
}

test "javascript grammar parses a simple source file" {
    var parser = try Parser.init();
    defer parser.deinit();

    try std.testing.expect(parser.setLanguage(grammars.javascript.language()));
    var tree = parser.parseString("const value = call(input);\n", null) orelse return error.UnexpectedNull;
    defer tree.deinit();

    try std.testing.expectEqualStrings("program", tree.rootNode().kind());
}

test "tsx grammar parses jsx syntax" {
    var parser = try Parser.init();
    defer parser.deinit();

    try std.testing.expect(parser.setLanguage(grammars.typescript.tsxLanguage()));
    var tree = parser.parseString("export const view = <Card title=\"verde\" />;\n", null) orelse return error.UnexpectedNull;
    defer tree.deinit();

    try std.testing.expectEqualStrings("program", tree.rootNode().kind());
}

test "json grammar parses a simple object" {
    var parser = try Parser.init();
    defer parser.deinit();

    try std.testing.expect(parser.setLanguage(grammars.json.language()));
    var tree = parser.parseString("{\"ready\":true,\"count\":2}\n", null) orelse return error.UnexpectedNull;
    defer tree.deinit();

    try std.testing.expectEqualStrings("document", tree.rootNode().kind());
}

test {
    _ = Parser;
    _ = Tree;
    _ = Node;
    _ = TreeCursor;
    _ = Query;
    _ = QueryCursor;
    _ = grammars;
}
