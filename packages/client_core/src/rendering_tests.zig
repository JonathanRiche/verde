//! Golden projections and cases ported from web markdown_security/highlight tests.
const std = @import("std");
const rendering = @import("rendering.zig");
const host = @import("host.zig");
const abi = @import("root.zig");
const Node = rendering.markdown.Node;
const expect = std.testing.expect;
const eql = std.testing.expectEqualStrings;
const config =
    \\{"api_version":1,"host_id":"render-test","label":"Render","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"0123456789abcdef0123456789abcdef","jitter_seed":7}
;

fn golden(a: std.mem.Allocator, expected: []const u8, value: anytype) !void {
    const actual = try std.json.Stringify.valueAlloc(a, value, .{});
    try eql(std.mem.trim(u8, expected, "\n"), actual);
}

fn find(nodes: []const Node, kind: []const u8) ?Node {
    for (nodes) |node| {
        if (rendering.eq(node.kind, kind)) return node;
        if (find(node.children, kind)) |child| return child;
    }
    return null;
}

// Mobile app tests decode verbatim copies of this golden (see mobile_android d07 fixtures).
test "diff golden matches web changed-middle emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try golden(a, @embedFile("fixtures/render-diff.json"), try rendering.diff.render(a, "--- a/x.ts\n+++ b/x.ts\n@@ -1 +1 @@\n-const a = 1;\n+const a = 2;\n"));
}

test "web raw HTML and javascript security fixtures stay inert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "<script>globalThis.pwned = true</script>\n<img src=\"/safe.png\" onerror=\"globalThis.pwned = true\">\n<svg onload=\"globalThis.pwned = true\"><circle /></svg>";
    const result = try rendering.markdown.render(a, source);
    try expect(find(result.nodes, "image") == null);
    try expect(find(result.nodes, "link") == null);
    try eql("<script>globalThis.pwned = true</script>", find(result.nodes, "text").?.text.?);
    const unsafe_link = try rendering.markdown.render(a, "<a href=\"javascript:alert(1)\">raw</a> [markdown](javascript:alert(2))");
    try expect(find(unsafe_link.nodes, "link").?.url == null);
    const inert = try rendering.markdown.render(a, "<img src=x onerror=alert(1)>");
    try eql("<img src=x onerror=alert(1)>", find(inert.nodes, "text").?.text.?);
    for ([_][]const u8{ "JAVASCRIPT:alert", "data:text/html,hi", "//evil.example", "java\nscript:hi" }) |url| {
        const input = try std.fmt.allocPrint(a, "[x]({s})", .{url});
        const parsed = try rendering.markdown.render(a, input);
        if (find(parsed.nodes, "link")) |link| try expect(link.url == null);
    }
}

fn framed(a: std.mem.Allocator, path: []const u8, patch: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "FILE\t{d}\t1\t1\t{d}\n{s}{s}", .{ path.len, patch.len, path, patch });
}

test "web V2 byte framing Unicode tabs newlines multiple files and empty patches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch = "@@ -1 +1 @@\n-say \"hello\" 😀 there friend\n+say \"hello\" 😁 there friend\n";
    const path = "dir/é\t😀\n.ts";
    const text = try std.fmt.allocPrint(a, "VERDE_DIFF_V2\n{s}{s}", .{ try framed(a, path, patch), try framed(a, "empty.ts", "") });
    const diff = try rendering.diff.render(a, text);
    try expect(diff.files.len == 2);
    try eql(path, diff.files[0].new_path.?);
    const lines = diff.files[0].hunks[0].lines;
    try expect(lines[0].old_line == 1 and lines[0].new_line == null);
    try expect(lines[1].old_line == null and lines[1].new_line == 1);
    try eql("😀", lines[0].text[lines[0].spans[0].start..lines[0].spans[0].end]);
    try eql("😁", lines[1].text[lines[1].spans[0].start..lines[1].spans[0].end]);
    try expect(diff.files[1].hunks.len == 0);
    try expect((try rendering.diff.render(a, "VERDE_DIFF_V2\n")).files.len == 0);
    const numeric = try rendering.diff.render(a, "VERDE_DIFF_V2\nFILE\t1e0\t-0\t0x0\t \nx");
    try eql("x", numeric.files[0].new_path.?);
}

test "diff_index locates V2 records that render alone like the whole body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const patch = "@@ -1 +1 @@\n-say \"hello\" 😀 there friend\n+say \"hello\" 😁 there friend\n";
    const path = "dir/é\t😀\n.ts";
    const text = try std.fmt.allocPrint(a, "VERDE_DIFF_V2\n{s}{s}{s}", .{ try framed(a, path, patch), try framed(a, "empty.ts", ""), try framed(a, "b.json", "@@ -1 +1 @@\n-1\n+2\n") });
    const whole = try rendering.diff.render(a, text);
    const index = try rendering.diff.index(a, text);
    try expect(index.files.len == 3 and whole.files.len == 3);
    try eql(path, index.files[0].path);
    try expect(index.files[0].additions == 1 and index.files[0].deletions == 1 and index.files[0].start == "VERDE_DIFF_V2\n".len);
    try eql(patch, text[index.files[0].patch_start..index.files[0].end]);
    try expect(index.files[1].patch_start == index.files[1].end and index.files[2].end == text.len);
    for (index.files, whole.files) |entry, file| {
        try expect(entry.start < entry.patch_start and entry.patch_start <= entry.end);
        const alone = try rendering.diff.render(a, try std.fmt.allocPrint(a, "VERDE_DIFF_V2\n{s}", .{text[entry.start..entry.end]}));
        try golden(a, try std.json.Stringify.valueAlloc(a, file, .{}), alone.files[0]);
    }
    try expect((try rendering.diff.index(a, "VERDE_DIFF_V2\n")).files.len == 0);
    for ([_][]const u8{ "@@ -1 +1 @@\n-a\n+b\n", "VERDE_DIFF_V2\nFILE\t1\t0\t0\t1\nx", "VERDE_DIFF_V2\nFILE\t1\t0\t0\t0\né" }) |bad|
        try std.testing.expectError(error.InvalidInput, rendering.diff.index(a, bad));
}

test "malformed V2 and diff counters fail instead of returning partial data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "VERDE_DIFF_V2\nFILE\t1\t0\t0\t1\nx",        "VERDE_DIFF_V2\nFILE\t1\t-1\t0\t0\nx",
        "VERDE_DIFF_V2\nFILE\t1\t0\t0\t0\textra\nx", "VERDE_DIFF_V2\nFILE\t9007199254740992\t0\t0\t0\n",
        "VERDE_DIFF_V2\nFILE\t1\t0\t0\t0\né",
        "VERDE_DIFF_V2\nFILE",                       "not a diff",
        "@@ -1,2 +1 @@\n-a\n+b\n",                   "@@ -0 +1 @@\n-a\n+b\n",
        "@@ broken @@\n",
    }) |text| try std.testing.expectError(error.InvalidInput, rendering.diff.render(a, text));
    try std.testing.expectError(error.ResourceLimit, rendering.diff.render(a, "@@ -18446744073709551615 +1 @@\n-a\n+b\n"));
}

test "query errors budgets purity and ABI ownership" {
    var h = try host.Host.init(std.testing.allocator, config);
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const revision = h.state.revision;
    for ([_][]const u8{
        "{\"utility\":\"diff\",\"text\":\"bad\"}",
        "{\"utility\":\"highlight\",\"text\":\"x\"}",
    }) |selector| {
        const reply = try host.parse(a, try h.query(selector, a));
        try eql("invalid_input", reply.object.get("error").?.object.get("code").?.string);
        try expect(reply.object.get("data").? == .null);
    }
    const long = try a.alloc(u8, rendering.MAX_TEXT + 1);
    @memset(long, 'x');
    const request = try std.json.Stringify.valueAlloc(a, .{ .utility = "markdown", .text = long }, .{});
    const limited = try host.parse(a, try h.query(request, a));
    try eql("resource_limit", limited.object.get("error").?.object.get("code").?.string);
    var buf: abi.Buf = .{};
    const selector = "{\"utility\":\"markdown\",\"text\":\"# hello\"}";
    try expect(abi.vcHostQuery(&h, selector.ptr, selector.len, &buf) == 0);
    defer abi.vcBufFree(buf);
    try expect(buf.len > 0 and buf.ptr.?[0] == '{');
    try expect(h.state.revision == revision and h.state.pending.len == 0);
}
