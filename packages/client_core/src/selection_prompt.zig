//! "Ask agent about selected lines": builds the chat message shared by every
//! client (desktop, web, mobile), so phones and the desktop send the same text.
//!
//!     In `<root-relative path>` lines <A>–<B>:
//!     ```<lang>
//!     <selected text>
//!     ```
//!     <user instruction>
//!
//! A single line reads `line <A>`. Diff selections append `(diff, new side)`
//! or `(diff, old side)` after the range. Paths under a workspace folder other
//! than the home are prefixed with that folder's name (`verde-cloud/…`).
const std = @import("std");
const A = std.mem.Allocator;
const eq = std.mem.eql;

pub const MAX_SELECTION_BYTES = 256 * 1024;
pub const MAX_INSTRUCTION_BYTES = 64 * 1024;

pub const Root = struct {
    name: []const u8,
    path: []const u8,
    /// The workspace home: its paths carry no folder prefix.
    home: bool = false,
};

pub const Side = enum { new, old };

pub const Request = struct {
    /// Absolute path (for diffs: repository root joined with the file path).
    path: []const u8,
    roots: []const Root = &.{},
    start_line: u32,
    end_line: ?u32 = null,
    side: ?Side = null,
    text: []const u8,
    instruction: []const u8,
};

pub const Error = error{ OutOfMemory, InvalidInput };

/// Workspace-relative display path: home-relative, `<folder>/…` for another
/// root (the deepest root containing the path wins), else the path unchanged.
pub fn displayPath(a: A, path: []const u8, roots: []const Root) Error![]const u8 {
    var best: ?Root = null;
    for (roots) |root| {
        const base = std.mem.trimEnd(u8, root.path, "/");
        if (base.len == 0 or !std.mem.startsWith(u8, path, base)) continue;
        if (path.len > base.len and path[base.len] != '/') continue;
        if (best == null or base.len > std.mem.trimEnd(u8, best.?.path, "/").len) best = root;
    }
    const root = best orelse return path;
    const base = std.mem.trimEnd(u8, root.path, "/");
    const rest = std.mem.trimStart(u8, path[base.len..], "/");
    if (root.home) return if (rest.len == 0) "." else rest;
    if (rest.len == 0) return root.name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ root.name, rest });
}

/// Fence language from the file extension; empty when unknown.
pub fn language(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    const ext = name[dot + 1 ..];
    const table = [_]struct { []const u8, []const u8 }{
        .{ "zig", "zig" },        .{ "ts", "typescript" },  .{ "tsx", "tsx" },       .{ "js", "javascript" },
        .{ "mjs", "javascript" }, .{ "cjs", "javascript" }, .{ "jsx", "jsx" },       .{ "json", "json" },
        .{ "kt", "kotlin" },      .{ "kts", "kotlin" },     .{ "swift", "swift" },   .{ "py", "python" },
        .{ "rs", "rust" },        .{ "go", "go" },          .{ "c", "c" },           .{ "h", "c" },
        .{ "cc", "cpp" },         .{ "cpp", "cpp" },        .{ "hpp", "cpp" },       .{ "m", "objectivec" },
        .{ "java", "java" },      .{ "rb", "ruby" },        .{ "sh", "bash" },       .{ "bash", "bash" },
        .{ "zsh", "bash" },       .{ "fish", "fish" },      .{ "md", "markdown" },   .{ "markdown", "markdown" },
        .{ "toml", "toml" },      .{ "yaml", "yaml" },      .{ "yml", "yaml" },      .{ "html", "html" },
        .{ "css", "css" },        .{ "scss", "scss" },      .{ "sql", "sql" },       .{ "xml", "xml" },
        .{ "lua", "lua" },        .{ "php", "php" },        .{ "cs", "csharp" },     .{ "dart", "dart" },
        .{ "vue", "vue" },        .{ "svelte", "svelte" },  .{ "gradle", "groovy" }, .{ "nix", "nix" },
    };
    var lower: [16]u8 = undefined;
    if (ext.len > lower.len) return "";
    const key = std.ascii.lowerString(&lower, ext);
    for (table) |row| if (eq(u8, key, row[0])) return row[1];
    return "";
}

pub fn format(a: A, r: Request) Error![]const u8 {
    if (r.start_line == 0 or (r.end_line != null and r.end_line.? < r.start_line)) return error.InvalidInput;
    if (r.path.len == 0 or r.text.len > MAX_SELECTION_BYTES or r.instruction.len > MAX_INSTRUCTION_BYTES) return error.InvalidInput;
    if (!std.unicode.utf8ValidateSlice(r.path) or !std.unicode.utf8ValidateSlice(r.text) or !std.unicode.utf8ValidateSlice(r.instruction)) return error.InvalidInput;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "In `{s}` ", .{try displayPath(a, r.path, r.roots)});
    const end = r.end_line orelse r.start_line;
    if (end == r.start_line) {
        try out.print(a, "line {d}", .{r.start_line});
    } else try out.print(a, "lines {d}\u{2013}{d}", .{ r.start_line, end });
    if (r.side) |side| try out.print(a, " (diff, {s} side)", .{@tagName(side)});
    try out.appendSlice(a, ":\n");
    // A selection containing a fence gets a longer one so it cannot close early.
    var ticks: usize = 3;
    var run: usize = 0;
    for (r.text) |c| {
        run = if (c == '`') run + 1 else 0;
        ticks = @max(ticks, run + 1);
    }
    const body = std.mem.trimEnd(u8, r.text, "\r\n");
    try out.appendNTimes(a, '`', ticks);
    try out.print(a, "{s}\n{s}\n", .{ language(r.path), body });
    try out.appendNTimes(a, '`', ticks);
    try out.print(a, "\n{s}", .{std.mem.trim(u8, r.instruction, " \t\r\n")});
    return out.items;
}

test "single line in the workspace home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const roots = [_]Root{ .{ .name = "verde", .path = "/w/verde", .home = true }, .{ .name = "verde-cloud", .path = "/w/verde-cloud" } };
    const text = try format(arena.allocator(), .{ .path = "/w/verde/src/main.zig", .roots = &roots, .start_line = 12, .text = "const x = 1;\n", .instruction = " Rename x. " });
    try std.testing.expectEqualStrings("In `src/main.zig` line 12:\n```zig\nconst x = 1;\n```\nRename x.", text);
}

test "range in another folder uses an en dash and the folder prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const roots = [_]Root{ .{ .name = "verde", .path = "/w/verde", .home = true }, .{ .name = "verde-cloud", .path = "/w/verde-cloud/" } };
    const text = try format(arena.allocator(), .{ .path = "/w/verde-cloud/README", .roots = &roots, .start_line = 3, .end_line = 5, .text = "a\nb\nc", .instruction = "Why?" });
    try std.testing.expectEqualStrings("In `verde-cloud/README` lines 3\u{2013}5:\n```\na\nb\nc\n```\nWhy?", text);
}

test "diff side, nested roots and fences inside the selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const roots = [_]Root{ .{ .name = "home", .path = "/w", .home = true }, .{ .name = "lib", .path = "/w/lib" } };
    const text = try format(a, .{ .path = "/w/lib/doc.md", .roots = &roots, .start_line = 1, .end_line = 2, .side = .old, .text = "```zig\n```", .instruction = "Fix" });
    try std.testing.expectEqualStrings("In `lib/doc.md` lines 1\u{2013}2 (diff, old side):\n````markdown\n```zig\n```\n````\nFix", text);
    try std.testing.expectEqualStrings("/elsewhere/x", try displayPath(a, "/elsewhere/x", &roots));
    try std.testing.expectEqualStrings("/wx/y", try displayPath(a, "/wx/y", &roots));
    try std.testing.expectError(error.InvalidInput, format(a, .{ .path = "/w/a", .start_line = 4, .end_line = 2, .text = "", .instruction = "" }));
    try std.testing.expectError(error.InvalidInput, format(a, .{ .path = "/w/a", .start_line = 0, .text = "", .instruction = "" }));
}
