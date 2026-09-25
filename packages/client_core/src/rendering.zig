//! Pure, bounded rendering queries. All returned values belong to the call arena.
const std = @import("std");
const host = @import("host.zig");
pub const markdown = @import("render_markdown.zig");
pub const diff = @import("render_diff.zig");
const syntax = @import("zig_dif").syntax;
const A = std.mem.Allocator;
const V = std.json.Value;

pub const MAX_TEXT = 64 * 1024;
pub const MAX_OUTPUT = 1024 * 1024;
pub const Span = struct { start: usize, end: usize, kind: []const u8 };
pub const Highlight = struct { spans: []const Span };
pub const Result = struct { data: V = .null, failure: ?host.LocalError = null };
pub const Error = error{ OutOfMemory, InvalidInput, ResourceLimit };

pub fn query(a: A, request: V) host.ApiError!Result {
    return queryInner(a, request) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimit => .{ .failure = .{ .code = "resource_limit", .message = "Rendering budget exceeded." } },
        error.InvalidInput => .{ .failure = .{ .code = "invalid_input", .message = "Malformed rendering input." } },
    };
}

fn queryInner(a: A, request: V) Error!Result {
    const utility = try string(request, "utility");
    if (!eq(utility, "markdown") and !eq(utility, "highlight") and !eq(utility, "diff"))
        return .{ .failure = .{ .code = "unsupported", .message = "Unknown rendering utility." } };
    const text = try string(request, "text");
    if (text.len > MAX_TEXT) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidInput;
    const bytes = if (eq(utility, "markdown"))
        try encode(a, try markdown.render(a, text))
    else if (eq(utility, "diff"))
        try encode(a, try diff.render(a, text))
    else
        try encode(a, try highlight(a, text, try string(request, "language")));
    return .{ .data = std.json.parseFromSliceLeaky(V, a, bytes, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    } };
}

fn encode(a: A, value: anytype) Error![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    if (bytes.len > MAX_OUTPUT) return error.ResourceLimit;
    return bytes;
}

pub fn highlight(a: A, text: []const u8, language: []const u8) Error!Highlight {
    const lang: syntax.Language = if (eq(language, "js") or eq(language, "javascript")) .javascript else if (eq(language, "ts") or eq(language, "typescript")) .typescript else if (eq(language, "jsx")) .jsx else if (eq(language, "tsx")) .tsx else if (eq(language, "json")) .json else return .{ .spans = &.{} };
    // Parse the entire code block so multiline comments and strings keep context.
    const tokens = try syntax.tokenizeLine(a, lang, text);
    var spans: std.ArrayList(Span) = .empty;
    var offset: usize = 0;
    for (tokens) |token| {
        const end = offset + token.text.len;
        if (token.kind != .plain and boundary(text, offset) and boundary(text, end))
            try spans.append(a, .{ .start = offset, .end = end, .kind = @tagName(token.kind) });
        offset = end;
    }
    return .{ .spans = try spans.toOwnedSlice(a) };
}

pub fn boundary(text: []const u8, offset: usize) bool {
    return offset <= text.len and (offset == text.len or text[offset] & 0xc0 != 0x80);
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn string(v: V, key: []const u8) Error![]const u8 {
    if (v != .object) return error.InvalidInput;
    const value = v.object.get(key) orelse return error.InvalidInput;
    if (value != .string) return error.InvalidInput;
    return value.string;
}

test {
    _ = @import("rendering_tests.zig");
}
