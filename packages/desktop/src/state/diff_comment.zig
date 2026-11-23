//! Composer drafts that comment on a diff ("About your edit to @path …").
//! Two entry points share one format:
//! - a whole file (transcript diff cards): `+A/-D` plus the edited line
//!   ranges taken from the patch's hunk headers, then the cursor;
//! - picked lines (the side panel's Changes view): `+A/-D`, the exact line
//!   range, and the picked diff lines quoted in a fenced `diff` block,
//!   capped so a large selection cannot bury the note.
//! Pure string building; `AppState.beginDiffCommentDraft` and
//! `beginDiffLinesCommentDraft` apply the result to the composer.

const std = @import("std");

/// Quoted diff lines beyond these limits are dropped (whole lines) and
/// summarized as "… N more lines"; the agent can open the file for more.
pub const MAX_SNIPPET_LINES: usize = 40;
pub const MAX_SNIPPET_BYTES: usize = 4 * 1024;

pub const Side = enum { new, old };

/// 1-based inclusive line range on one side of a diff.
pub const LineRange = struct { side: Side, first: usize, last: usize };

pub const Counts = struct { additions: i64 = 0, deletions: i64 = 0 };

pub const Request = struct {
    /// Mention path (already relativized; see `mentionPath`).
    path: []const u8,
    additions: i64,
    deletions: i64,
    /// Whole-file form: "lines 12-18, 40" from `lineSummary`.
    line_summary: ?[]const u8 = null,
    /// Picked-lines form: the exact range and the `-`/`+`/` ` lines.
    lines: ?LineRange = null,
    snippet: ?[]const u8 = null,
};

/// Project-relative path for an @-mention when `path` lies inside
/// `project_path`, else `path` unchanged (absolute paths stay exact).
pub fn mentionPath(path: []const u8, project_path: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, project_path, "/");
    if (base.len == 0 or !std.fs.path.isAbsolute(path) or !std.mem.startsWith(u8, path, base)) return path;
    const rest = path[base.len..];
    if (rest.len > 1 and rest[0] == '/') return rest[1..];
    return path;
}

/// `+`/`-` line counts of a quoted diff snippet.
pub fn snippetCounts(snippet: []const u8) Counts {
    var counts: Counts = .{};
    var lines = std.mem.splitScalar(u8, snippet, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        switch (line[0]) {
            '+' => counts.additions += 1,
            '-' => counts.deletions += 1,
            else => {},
        }
    }
    return counts;
}

/// Returns `draft` with the comment prefix appended (on a new line when the
/// draft already has text), owned by `allocator`. Ends where the user types.
pub fn formatDraft(allocator: std.mem.Allocator, draft: []const u8, request: Request) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, draft);
    if (draft.len > 0 and !std.mem.endsWith(u8, draft, "\n")) try out.append(allocator, '\n');
    try out.print(allocator, "About your edit to @{s} (", .{request.path});
    if (request.additions > 0 or request.deletions > 0 or request.lines == null) {
        try out.print(allocator, "+{d}/-{d}", .{ request.additions, request.deletions });
        if (request.lines != null or request.line_summary != null) try out.appendSlice(allocator, ", ");
    }
    if (request.lines) |range| {
        try appendRange(&out, allocator, range);
    } else if (request.line_summary) |summary| {
        try out.appendSlice(allocator, summary);
    }
    const snippet = request.snippet orelse "";
    if (request.lines == null or std.mem.trim(u8, snippet, "\r\n").len == 0) {
        try out.appendSlice(allocator, "): ");
        return out.toOwnedSlice(allocator);
    }
    try out.appendSlice(allocator, "):\n");
    try appendQuotedSnippet(&out, allocator, snippet);
    return out.toOwnedSlice(allocator);
}

/// Formats the new-file line ranges touched by a unified-diff patch, e.g.
/// "lines 12-18, 40", so a diff comment names the exact edit. Lists at
/// most four hunks and rolls the rest up as "+N more". Returns null when
/// the patch has no parseable `@@` hunk headers.
pub fn lineSummary(allocator: std.mem.Allocator, patch: []const u8) ?[]u8 {
    // Beyond this many ranges the prefix stops reading as a pointer and
    // starts crowding out the user's actual comment.
    const max_listed_hunks: usize = 4;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var hunk_count: usize = 0;
    var lines_it = std.mem.splitScalar(u8, patch, '\n');
    while (lines_it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "@@")) continue;
        // The first '+' in a valid header starts the new-side "+start,count".
        const plus = std.mem.indexOfScalar(u8, line, '+') orelse continue;
        const rest = line[plus + 1 ..];
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 0) continue;
        const start = std.fmt.parseInt(u32, rest[0..digits], 10) catch continue;
        var count: u32 = 1;
        if (digits < rest.len and rest[digits] == ',') {
            var end = digits + 1;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            count = std.fmt.parseInt(u32, rest[digits + 1 .. end], 10) catch 1;
        }

        hunk_count += 1;
        if (hunk_count > max_listed_hunks) continue;

        var piece_buf: [48]u8 = undefined;
        const piece = if (count <= 1)
            std.fmt.bufPrint(&piece_buf, "{s}{d}", .{ if (hunk_count == 1) "lines " else ", ", start }) catch continue
        else
            std.fmt.bufPrint(&piece_buf, "{s}{d}-{d}", .{ if (hunk_count == 1) "lines " else ", ", start, start + count - 1 }) catch continue;
        out.appendSlice(allocator, piece) catch return null;
    }
    if (hunk_count == 0 or out.items.len == 0) return null;
    if (hunk_count > max_listed_hunks) {
        var more_buf: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, ", +{d} more", .{hunk_count - max_listed_hunks}) catch return null;
        out.appendSlice(allocator, more) catch return null;
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn appendRange(out: *std.ArrayList(u8), allocator: std.mem.Allocator, range: LineRange) !void {
    const side: []const u8 = if (range.side == .old) "old " else "";
    const last = @max(range.last, range.first);
    if (last == range.first) {
        try out.print(allocator, "{s}line {d}", .{ side, range.first });
    } else try out.print(allocator, "{s}lines {d}-{d}", .{ side, range.first, last });
}

/// The kept part of `snippet`: whole lines within both caps (a lone
/// oversized first line is cut at a UTF-8 boundary), plus the number of
/// lines dropped.
const Kept = struct { text: []const u8, omitted: usize };

fn capSnippet(snippet: []const u8) Kept {
    const body = std.mem.trimEnd(u8, snippet, "\r\n");
    var end: usize = 0;
    var kept: usize = 0;
    var total: usize = 0;
    var full = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        total += 1;
        if (full) continue;
        const next_end = if (kept == 0) line.len else end + 1 + line.len;
        if (kept == MAX_SNIPPET_LINES or next_end > MAX_SNIPPET_BYTES) {
            full = true;
            if (kept == 0) {
                // One huge line: keep a valid UTF-8 prefix of it.
                var cut = @min(line.len, MAX_SNIPPET_BYTES);
                while (cut > 0 and cut < line.len and (line[cut] & 0xC0) == 0x80) cut -= 1;
                end = cut;
                kept = 1;
            }
            continue;
        }
        end = next_end;
        kept += 1;
    }
    return .{ .text = body[0..end], .omitted = total - kept };
}

fn appendQuotedSnippet(out: *std.ArrayList(u8), allocator: std.mem.Allocator, snippet: []const u8) !void {
    const kept = capSnippet(snippet);
    // A quoted line containing a fence gets a longer one so it cannot close early.
    var ticks: usize = 3;
    var run: usize = 0;
    for (kept.text) |c| {
        run = if (c == '`') run + 1 else 0;
        ticks = @max(ticks, run + 1);
    }
    try out.appendNTimes(allocator, '`', ticks);
    try out.appendSlice(allocator, "diff\n");
    var lines = std.mem.splitScalar(u8, kept.text, '\n');
    while (lines.next()) |line| {
        try out.appendSlice(allocator, std.mem.trimEnd(u8, line, "\r"));
        try out.append(allocator, '\n');
    }
    try out.appendNTimes(allocator, '`', ticks);
    try out.append(allocator, '\n');
    if (kept.omitted > 0) try out.print(allocator, "(\u{2026} {d} more line{s} not shown)\n", .{ kept.omitted, if (kept.omitted == 1) "" else "s" });
}

test "diff comment whole-file draft keeps the transcript format and appends" {
    const allocator = std.testing.allocator;
    const summary = lineSummary(allocator, "@@ -10,2 +12,7 @@ fn a\n x\n@@ -40 +40 @@\n-y\n+z\n") orelse return error.TestExpectedEqual;
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("lines 12-18, 40", summary);
    const first = try formatDraft(allocator, "", .{ .path = "src/a.zig", .additions = 3, .deletions = 1, .line_summary = summary });
    defer allocator.free(first);
    try std.testing.expectEqualStrings("About your edit to @src/a.zig (+3/-1, lines 12-18, 40): ", first);
    const appended = try formatDraft(allocator, "Earlier note", .{ .path = "b.zig", .additions = 0, .deletions = 0 });
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("Earlier note\nAbout your edit to @b.zig (+0/-0): ", appended);
    try std.testing.expect(lineSummary(allocator, "no hunks here") == null);
    const many = lineSummary(allocator, "@@ -1 +1 @@\n@@ -2 +2 @@\n@@ -3 +3 @@\n@@ -4 +4 @@\n@@ -5 +5 @@\n@@ -6 +6 @@\n") orelse return error.TestExpectedEqual;
    defer allocator.free(many);
    try std.testing.expectEqualStrings("lines 1, 2, 3, 4, +2 more", many);
}

test "diff comment picked lines name the range and quote the lines" {
    const allocator = std.testing.allocator;
    const snippet = " keep\n-old value\n+new value\n+more\n";
    const counts = snippetCounts(snippet);
    try std.testing.expectEqual(@as(i64, 2), counts.additions);
    try std.testing.expectEqual(@as(i64, 1), counts.deletions);
    const draft = try formatDraft(allocator, "Look at these.\n", .{
        .path = "src/a.zig",
        .additions = counts.additions,
        .deletions = counts.deletions,
        .lines = .{ .side = .new, .first = 12, .last = 14 },
        .snippet = snippet,
    });
    defer allocator.free(draft);
    try std.testing.expectEqualStrings(
        "Look at these.\nAbout your edit to @src/a.zig (+2/-1, lines 12-14):\n```diff\n keep\n-old value\n+new value\n+more\n```\n",
        draft,
    );
    // Deletion-only picks cite the old side; one line reads "line N".
    const old_only = try formatDraft(allocator, "", .{ .path = "a", .additions = 0, .deletions = 1, .lines = .{ .side = .old, .first = 7, .last = 7 }, .snippet = "-gone" });
    defer allocator.free(old_only);
    try std.testing.expectEqualStrings("About your edit to @a (+0/-1, old line 7):\n```diff\n-gone\n```\n", old_only);
    // Context-only picks carry no counts; a fence in the code lengthens ours.
    const fenced = try formatDraft(allocator, "", .{ .path = "a.md", .additions = 0, .deletions = 0, .lines = .{ .side = .new, .first = 1, .last = 2 }, .snippet = " ```zig\r\n ```\r\n" });
    defer allocator.free(fenced);
    try std.testing.expectEqualStrings("About your edit to @a.md (lines 1-2):\n````diff\n ```zig\n ```\n````\n", fenced);
}

test "diff comment caps quoted lines and bytes" {
    const allocator = std.testing.allocator;
    var snippet: std.ArrayList(u8) = .empty;
    defer snippet.deinit(allocator);
    for (0..MAX_SNIPPET_LINES + 5) |index| try snippet.print(allocator, "+line {d}\n", .{index});
    const kept = capSnippet(snippet.items);
    try std.testing.expectEqual(@as(usize, 5), kept.omitted);
    try std.testing.expect(std.mem.endsWith(u8, kept.text, "+line 39"));
    const draft = try formatDraft(allocator, "", .{ .path = "a", .additions = 45, .deletions = 0, .lines = .{ .side = .new, .first = 1, .last = 45 }, .snippet = snippet.items });
    defer allocator.free(draft);
    try std.testing.expect(std.mem.endsWith(u8, draft, "+line 39\n```\n(\u{2026} 5 more lines not shown)\n"));

    // Byte cap: whole lines only, and one huge line is cut on a UTF-8 boundary.
    const wide = "+" ++ "é" ** 2500 ++ "\n+short\n";
    const wide_kept = capSnippet(wide);
    try std.testing.expectEqual(@as(usize, 1), wide_kept.omitted);
    try std.testing.expect(wide_kept.text.len <= MAX_SNIPPET_BYTES);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_kept.text));
    const two = "+" ++ "a" ** 3000 ++ "\n+" ++ "b" ** 3000 ++ "\n";
    const two_kept = capSnippet(two);
    try std.testing.expectEqual(@as(usize, 1), two_kept.omitted);
    try std.testing.expectEqual(@as(usize, 3001), two_kept.text.len);
}

test "diff comment mention paths are project-relative when inside the project" {
    try std.testing.expectEqualStrings("src/a.zig", mentionPath("/w/proj/src/a.zig", "/w/proj"));
    try std.testing.expectEqualStrings("src/a.zig", mentionPath("/w/proj/src/a.zig", "/w/proj/"));
    try std.testing.expectEqualStrings("/w/project2/a.zig", mentionPath("/w/project2/a.zig", "/w/proj"));
    try std.testing.expectEqualStrings("/elsewhere/a.zig", mentionPath("/elsewhere/a.zig", "/w/proj"));
    try std.testing.expectEqualStrings("rel/a.zig", mentionPath("rel/a.zig", "/w/proj"));
    try std.testing.expectEqualStrings("/w/proj", mentionPath("/w/proj", "/w/proj"));
}
