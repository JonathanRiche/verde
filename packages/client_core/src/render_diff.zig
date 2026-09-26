//! VERDE_DIFF_V2 byte framing and shared zig_dif hunk/word-span projection.
const std = @import("std");
const dif = @import("zig_dif");
const rendering = @import("rendering.zig");
const A = std.mem.Allocator;
const Error = rendering.Error;
const Span = rendering.Span;
const eq = rendering.eq;

pub const Diff = struct { files: []const File };
pub const File = struct { old_path: ?[]const u8, new_path: ?[]const u8, binary: bool, hunks: []const Hunk };
pub const Hunk = struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize, lines: []const Line };
pub const Line = struct { kind: []const u8, text: []const u8, old_line: ?usize = null, new_line: ?usize = null, spans: []const Span = &.{} };
/// One VERDE_DIFF_V2 record located in the source: `start..end` spans the whole record (header,
/// path and patch) and `patch_start..end` the patch, as UTF-8 byte offsets. Counts are the
/// writer's header fields; the platform prefixes MARKER to a record to render just that file.
pub const IndexEntry = struct { path: []const u8, additions: usize, deletions: usize, start: usize, end: usize, patch_start: usize };
pub const Index = struct { files: []const IndexEntry };
const MARKER = "VERDE_DIFF_V2\n";
const MAX_LINES = 4096;

pub fn render(a: A, text: []const u8) Error!Diff {
    var files: std.ArrayList(File) = .empty;
    if (!std.mem.startsWith(u8, text, MARKER)) {
        try parsePatch(a, text, null, &files);
    } else {
        var pos: usize = MARKER.len;
        while (try nextRecord(text, &pos)) |record| try parsePatch(a, text[record.patch_start..record.end], record.path, &files);
    }
    return .{ .files = try files.toOwnedSlice(a) };
}

/// Locates every VERDE_DIFF_V2 record without parsing patches, so bodies beyond the per-patch
/// budgets can still list their files and be rendered one record at a time.
pub fn index(a: A, text: []const u8) Error!Index {
    if (!std.mem.startsWith(u8, text, MARKER)) return error.InvalidInput;
    var entries: std.ArrayList(IndexEntry) = .empty;
    var pos: usize = MARKER.len;
    while (try nextRecord(text, &pos)) |record| try entries.append(a, record);
    return .{ .files = try entries.toOwnedSlice(a) };
}

/// The one V2 framing reader shared by `render` and `index`.
fn nextRecord(text: []const u8, pos: *usize) Error!?IndexEntry {
    if (pos.* >= text.len) return null;
    const start = pos.*;
    const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return error.InvalidInput;
    const header = text[start..nl];
    if (!std.mem.startsWith(u8, header, "FILE\t")) return error.InvalidInput;
    var fields = std.mem.splitScalar(u8, header[5..], '\t');
    var sizes: [4]usize = undefined;
    for (&sizes) |*size| size.* = try number(fields.next() orelse return error.InvalidInput);
    if (fields.next() != null) return error.InvalidInput;
    var at = nl + 1;
    if (sizes[0] > text.len - at) return error.InvalidInput;
    const path = text[at..][0..sizes[0]];
    at += sizes[0];
    if (sizes[3] > text.len - at) return error.InvalidInput;
    const patch_start = at;
    at += sizes[3];
    if (!std.unicode.utf8ValidateSlice(path) or !std.unicode.utf8ValidateSlice(text[patch_start..at])) return error.InvalidInput;
    pos.* = at;
    return .{ .path = path, .additions = sizes[1], .deletions = sizes[2], .start = start, .end = at, .patch_start = patch_start };
}

fn number(bytes: []const u8) Error!usize {
    // Mirror JavaScript Number + Number.isSafeInteger used by parseDiffV2,
    // including whitespace, empty fields, -0 and integral exponent notation.
    const value = std.mem.trim(u8, bytes, " \t\r\n");
    if (value.len == 0) return 0;
    if (value.len > 2 and value[0] == '0') {
        const radix: u8 = switch (value[1]) {
            'x', 'X' => 16,
            'b', 'B' => 2,
            'o', 'O' => 8,
            else => 0,
        };
        if (radix != 0) {
            for (value[2..]) |c| if (!std.ascii.isHex(c)) return error.InvalidInput;
            const n = std.fmt.parseInt(usize, value[2..], radix) catch return error.InvalidInput;
            if (n > 9007199254740991) return error.InvalidInput;
            return n;
        }
    }
    for (value) |c| if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, "+-.eE", c) == null) return error.InvalidInput;
    const n = std.fmt.parseFloat(f64, value) catch return error.InvalidInput;
    if (!std.math.isFinite(n) or n < 0 or n > 9007199254740991 or @trunc(n) != n) return error.InvalidInput;
    return @intFromFloat(n);
}

fn parsePatch(a: A, patch: []const u8, fallback: ?[]const u8, files: *std.ArrayList(File)) Error!void {
    if (std.mem.count(u8, patch, "\n") > MAX_LINES) return error.ResourceLimit;
    // Validate counters before the rendering engine increments line numbers.
    var parsed = dif.parseUnifiedDiff(a, patch) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
    defer parsed.deinit();
    var alignment_cells: usize = 0;
    for (parsed.files) |file| for (file.hunks) |hunk| {
        if (hunk.old_count > MAX_LINES or hunk.new_count > MAX_LINES or hunk.old_start > 9007199254740991 - MAX_LINES or hunk.new_start > 9007199254740991 - MAX_LINES) return error.ResourceLimit;
        var deleted: usize = 0;
        var added: usize = 0;
        for (hunk.lines) |line| {
            if (line.kind == .context or (line.kind == .deletion and added > 0)) {
                alignment_cells += (deleted + 1) * (added + 1);
                deleted = 0;
                added = 0;
            }
            if (line.kind == .deletion) deleted += 1;
            if (line.kind == .addition) added += 1;
        }
        alignment_cells += (deleted + 1) * (added + 1);
        if (alignment_cells > 65536) return error.ResourceLimit;
    };
    var view = dif.buildSideBySidePatchViewWithOptions(a, patch, .{ .context_lines = MAX_LINES }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidInput,
    };
    defer view.deinit();
    if (view.document.files.len == 0) {
        if (patch.len != 0 or fallback == null) return error.InvalidInput;
        try files.append(a, .{ .old_path = fallback, .new_path = fallback, .binary = false, .hunks = &.{} });
        return;
    }
    var row_index: usize = 0;
    for (view.document.files) |file| {
        var hunks: std.ArrayList(Hunk) = .empty;
        if (file.hunks.len == 0 and !file.is_binary and file.old_path == null and file.new_path == null) return error.InvalidInput;
        for (file.hunks) |hunk| {
            if (hunk.old_count > MAX_LINES or hunk.new_count > MAX_LINES or hunk.old_start > 9007199254740991 - MAX_LINES or hunk.new_start > 9007199254740991 - MAX_LINES) return error.ResourceLimit;
            while (row_index < view.rows.len and view.rows[row_index].kind != .hunk_header) : (row_index += 1) {}
            if (row_index < view.rows.len) row_index += 1;
            const old_spans = try a.alloc([]const Span, hunk.old_count);
            const new_spans = try a.alloc([]const Span, hunk.new_count);
            @memset(old_spans, &.{});
            @memset(new_spans, &.{});
            while (row_index < view.rows.len) : (row_index += 1) {
                const row = view.rows[row_index];
                if (row.kind == .hunk_header or row.kind == .file_header) break;
                if (row.left) |cell| try storeSpans(a, cell, hunk.old_start, old_spans, "delete");
                if (row.right) |cell| try storeSpans(a, cell, hunk.new_start, new_spans, "add");
            }
            var lines: std.ArrayList(Line) = .empty;
            var old: usize = 0;
            var new: usize = 0;
            for (hunk.lines) |line| {
                const has_old = line.kind != .addition;
                const has_new = line.kind != .deletion;
                if ((has_old and old >= hunk.old_count) or (has_new and new >= hunk.new_count)) return error.InvalidInput;
                try lines.append(a, .{
                    .kind = switch (line.kind) {
                        .context => "context",
                        .addition => "add",
                        .deletion => "delete",
                    },
                    .text = try a.dupe(u8, line.text),
                    .old_line = if (has_old) hunk.old_start + old else null,
                    .new_line = if (has_new) hunk.new_start + new else null,
                    .spans = switch (line.kind) {
                        .context => &.{},
                        .addition => new_spans[new],
                        .deletion => old_spans[old],
                    },
                });
                if (line.missing_newline) try lines.append(a, .{ .kind = "meta", .text = "\\ No newline at end of file" });
                if (has_old) old += 1;
                if (has_new) new += 1;
            }
            if (old != hunk.old_count or new != hunk.new_count or (old > 0 and hunk.old_start == 0) or (new > 0 and hunk.new_start == 0)) return error.InvalidInput;
            try hunks.append(a, .{ .old_start = hunk.old_start, .old_count = hunk.old_count, .new_start = hunk.new_start, .new_count = hunk.new_count, .lines = try lines.toOwnedSlice(a) });
        }
        try files.append(a, .{ .old_path = try pathCopy(a, file.old_path, fallback), .new_path = try pathCopy(a, file.new_path, fallback), .binary = file.is_binary, .hunks = try hunks.toOwnedSlice(a) });
    }
}

fn pathCopy(a: A, path: ?[]const u8, fallback: ?[]const u8) Error!?[]const u8 {
    const p = path orelse fallback orelse return null;
    if (eq(p, "/dev/null")) return null;
    return try a.dupe(u8, p);
}
fn storeSpans(a: A, cell: dif.SideBySideCell, start: usize, slots: [][]const Span, kind: []const u8) Error!void {
    const line = cell.line_number orelse return;
    if (line < start or line - start >= slots.len) return error.InvalidInput;
    var spans: std.ArrayList(Span) = .empty;
    for (cell.emphasis_ranges) |range| {
        // zig_dif can trim by byte. Expand to UTF-8 boundaries for native bridges.
        var lo = range.start;
        var hi = range.end;
        while (lo > 0 and !rendering.boundary(cell.text, lo)) lo -= 1;
        while (hi < cell.text.len and !rendering.boundary(cell.text, hi)) hi += 1;
        try spans.append(a, .{ .start = lo, .end = hi, .kind = kind });
    }
    slots[line - start] = try spans.toOwnedSlice(a);
}
