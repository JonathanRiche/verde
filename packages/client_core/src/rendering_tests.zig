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
fn ranges(nodes: []const Node, source: []const u8) !void {
    for (nodes) |node| {
        try expect(node.start <= node.end and node.end <= source.len);
        try expect(rendering.boundary(source, node.start) and rendering.boundary(source, node.end));
        try ranges(node.children, source);
    }
}

test "markdown golden uses UTF-8 content ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try golden(a, @embedFile("fixtures/render-markdown.json"), try rendering.markdown.render(a, "# Hé **世界**\n"));
}

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

test "web file citation and document links produce abstract targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "/tmp/report one.pdf", "/tmp/report_one_final.pdf", "/tmp/報告😀.pdf" }) |path| {
        const source = try std.fmt.allocPrint(a, ":codex-file-citation{{path=\"{s}\" purpose=\"output\"}}", .{path});
        const result = try rendering.markdown.render(a, source);
        const link = find(result.nodes, "link").?;
        try eql(path, link.citation.?.path);
        try expect(link.url == null);
        try ranges(result.nodes, source);
        const code = try rendering.markdown.render(a, try std.fmt.allocPrint(a, "`{s}`", .{source}));
        try expect(find(code.nodes, "link") == null);
        try eql(source, find(code.nodes, "code").?.text.?);
    }
    const docs = try rendering.markdown.render(a, "- [Business Plan — Word](/home/rtg/SJ-Co-Events-Business-Plan.docx)\n- [Pitch Deck — PDF](/home/rtg/SJ-Co-Events-Pitch-Deck.pdf)");
    const items = find(docs.nodes, "list").?.children;
    try eql("/home/rtg/SJ-Co-Events-Business-Plan.docx", find(items[0].children, "link").?.citation.?.path);
    try eql("/home/rtg/SJ-Co-Events-Pitch-Deck.pdf", find(items[1].children, "link").?.citation.?.path);
    for ([_][]const u8{ "/src/main.zig:42", "file:///src/main.zig#L42" }) |target| {
        const citation = (try rendering.markdown.citation(a, target)).?;
        try eql("/src/main.zig", citation.path);
        try expect(citation.line == 42);
    }
    for ([_][]const u8{ "/api/file?path=%2Fhome%2Frtg%2Fplan.docx", "/api/preview?path=%2Fhome%2Frtg%2Fplan.docx" }) |target|
        try eql("/home/rtg/plan.docx", (try rendering.markdown.citation(a, target)).?.path);
    for ([_][]const u8{ "/login", "/assets/index.js", "https://example.com/report.pdf" }) |target|
        try expect(try rendering.markdown.citation(a, target) == null);
}

test "markdown containers tables images code and nested UTF-8 ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "# Heading\n\n> quoted *é* and ~~gone~~\n> next **世界**\n\n1. one\n2. two\n\n---\n\n| a | b |\n| --- | --- |\n| é | 😀 |\n\n![alt](/tmp/image.png)\n\n```ts\nconst x = 1;\n```\n";
    const result = try rendering.markdown.render(a, source);
    for ([_][]const u8{ "heading", "quote", "emphasis", "strike", "strong", "list", "item", "thematic_break", "table", "table_row", "table_cell", "image", "code_block", "line_break" }) |kind|
        try expect(find(result.nodes, kind) != null);
    try expect(find(result.nodes, "list").?.ordered.?);
    try eql("const x = 1;\n", find(result.nodes, "code_block").?.text.?);
    try ranges(result.nodes, source);
    const nested = "> ```js\n> /* é\n> 😀 */\n> ```\n";
    const code = try rendering.markdown.render(a, nested);
    try eql("/* é\n😀 */\n", find(code.nodes, "code_block").?.text.?);
    try ranges(code.nodes, nested);
    const repeated = "> ```js\n> js\n> ```\n";
    const repeated_code = find((try rendering.markdown.render(a, repeated)).nodes, "code_block").?;
    try eql("js\n", repeated_code.text.?);
    try expect(repeated_code.end >= 12);
}

test "web highlight string comments multiline and UTF-8 cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "const a = \"// no /* no */\" // yes";
    const result = try rendering.highlight(a, source, "ts");
    var comments: usize = 0;
    for (result.spans) |span| if (rendering.eq(span.kind, "comment")) {
        comments += 1;
        try eql("// yes", source[span.start..span.end]);
    };
    try expect(comments == 1);
    for ([_][]const u8{ "js", "ts", "jsx", "tsx", "json" }) |language| {
        const text = if (rendering.eq(language, "json")) "{\"é😀\": true}" else "const x = \"<script>alert(1)</script>\";\n/* é\n😀 */";
        const spans = try rendering.highlight(a, text, language);
        try expect(spans.spans.len > 0);
        var end: usize = 0;
        for (spans.spans) |span| {
            try expect(span.start >= end and span.end > span.start);
            try expect(rendering.boundary(text, span.start) and rendering.boundary(text, span.end));
            end = span.end;
        }
    }
    for ([_][]const u8{ "sh", "rust", "go", "yaml", "unknown" }) |language|
        try expect((try rendering.highlight(a, "😀 /* plain */", language)).spans.len == 0);
    try expect((try rendering.highlight(a, "", "ts")).spans.len == 0);
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

test "diff_index accepts bodies beyond the per-patch text budget" {
    var h = try host.Host.init(std.testing.allocator, config);
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(a, "VERDE_DIFF_V2\n");
    var count: usize = 0;
    while (body.items.len <= rendering.MAX_TEXT) : (count += 1)
        try body.appendSlice(a, try framed(a, try std.fmt.allocPrint(a, "f{d}.ts", .{count}), "@@ -1 +1 @@\n-const a = 1;\n+const a = 2;\n"));
    const whole = try host.parse(a, try h.query(try std.json.Stringify.valueAlloc(a, .{ .utility = "diff", .text = body.items }, .{}), a));
    try eql("resource_limit", whole.object.get("error").?.object.get("code").?.string);
    const listed = try host.parse(a, try h.query(try std.json.Stringify.valueAlloc(a, .{ .utility = "diff_index", .text = body.items }, .{}), a));
    try expect(listed.object.get("error").? == .null);
    try expect(listed.object.get("data").?.object.get("files").?.array.items.len == count);
    const plain = try host.parse(a, try h.query("{\"utility\":\"diff_index\",\"text\":\"@@ -1 +1 @@\\n-a\\n+b\\n\"}", a));
    try eql("invalid_input", plain.object.get("error").?.object.get("code").?.string);
}

test "diff binary new deleted no-newline and multiple hunks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const added = try rendering.diff.render(a, "--- /dev/null\n+++ b/new\n@@ -0,0 +1 @@\n+hello\n\\ No newline at end of file\n");
    try expect(added.files[0].old_path == null);
    try eql("meta", added.files[0].hunks[0].lines[1].kind);
    const deleted = try rendering.diff.render(a, "--- a/old\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n");
    try expect(deleted.files[0].new_path == null);
    const binary = try rendering.diff.render(a, "diff --git a/a.png b/a.png\nBinary files a/a.png and b/a.png differ\n");
    try expect(binary.files[0].binary);
    const multiple = try rendering.diff.render(a, "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n@@ -10,2 +10,2 @@\n context\n-foo\n+bar\n");
    try expect(multiple.files[0].hunks.len == 2);
    try expect(multiple.files[0].hunks[1].lines[1].old_line == 11);
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

fn allocationFixture(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try host.parse(a, "{\"utility\":\"markdown\",\"text\":\"# é **世界** [file](/tmp/x.zig:2)\"}");
    const result = try rendering.query(a, request);
    try expect(result.failure == null);
}
test "markdown utility allocation failures clean up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFixture, .{});
}

test "utility node depth output budgets and selector whitespace" {
    var h = try host.Host.init(std.testing.allocator, config);
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reply = try host.parse(a, try h.query(" \n{\"utility\":\"markdown\",\"text\":\"hello\"}", a));
    try expect(reply.object.get("error").? == .null);
    for ([_][]const u8{ "> " ** 65 ++ "x", "a\n\n" ** 2500 }) |source| {
        const selector = try std.json.Stringify.valueAlloc(a, .{ .utility = "markdown", .text = source }, .{});
        const limited = try host.parse(a, try h.query(selector, a));
        try eql("resource_limit", limited.object.get("error").?.object.get("code").?.string);
    }
    // Source is under the text budget, but thousands of spans exceed JSON budget.
    const selector = try std.json.Stringify.valueAlloc(a, .{ .utility = "highlight", .language = "json", .text = "[" ++ "1," ** 30000 ++ "1]" }, .{});
    const limited = try host.parse(a, try h.query(selector, a));
    try expect(limited.object.get("error").? == .object);
    try eql("resource_limit", limited.object.get("error").?.object.get("code").?.string);
}

test "registered query models decode real rendering replies" {
    var h = try host.Host.init(std.testing.allocator, config);
    defer h.deinit();
    const wire = @import("wire.zig");
    inline for (.{
        .{ "{\"utility\":\"markdown\",\"text\":\"# é **世界**\"}", rendering.markdown.Markdown },
        .{ "{\"utility\":\"highlight\",\"text\":\"const x = 1\",\"language\":\"ts\"}", rendering.Highlight },
        .{ "{\"utility\":\"diff\",\"text\":\"@@ -1 +1 @@\\n-old\\n+new\\n\"}", rendering.diff.Diff },
        .{ "{\"utility\":\"diff_index\",\"text\":\"VERDE_DIFF_V2\\nFILE\\t1\\t0\\t0\\t0\\nx\"}", rendering.diff.Index },
    }) |entry| {
        const output = try h.query(entry[0], std.testing.allocator);
        defer std.testing.allocator.free(output);
        const model = try std.json.parseFromSlice(wire.Query(entry[1]), std.testing.allocator, output, .{});
        defer model.deinit();
        try expect(model.value.data != null and model.value.@"error" == null);
    }
}
