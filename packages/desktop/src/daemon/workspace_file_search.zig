//! Bounded, repository-relative file search for composer `@` mentions served
//! by the daemon to detached clients (web). The desktop GUI keeps its fff-c
//! index; the daemon must not link that runtime library, so this lists files
//! with `git ls-files` (honoring .gitignore) and falls back to a bounded walk
//! that skips heavy build/dependency directories.

const std = @import("std");

const process_env = @import("../platform/env.zig");

pub const MAX_QUERY_BYTES: usize = 256;
pub const DEFAULT_LIMIT: usize = 20;
pub const MAX_LIMIT: usize = 100;
/// Hard cap on candidates considered per search so huge trees stay bounded.
const MAX_CANDIDATES: usize = 200_000;
/// Walk budget (directory entries visited) for non-git roots.
const MAX_WALK_ENTRIES: usize = 60_000;
const MAX_WALK_DEPTH: usize = 16;
const GIT_TIMEOUT_MS: i64 = 3000;
const GIT_STDOUT_LIMIT: usize = 48 * 1024 * 1024;

const SKIPPED_DIRECTORIES = [_][]const u8{
    ".git",    ".hg",    ".svn", "node_modules", ".zig-cache",  "zig-cache",     "zig-out",
    "zig-pkg", "target", "dist", "build",        ".next",       ".nuxt",         ".turbo",
    ".cache",  ".venv",  "venv", "__pycache__",  ".mypy_cache", ".pytest_cache", ".gradle",
    ".idea",   "vendor", "Pods", ".direnv",      "coverage",
};

pub const Source = enum { git, walk };

pub const Match = struct {
    /// Slash-separated path relative to the search root.
    path: []const u8,
    file_name: []const u8,
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    files: []Match,
    total_files: usize,
    truncated: bool,
    source: Source,

    pub fn deinit(self: *Results) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SearchError = error{ SearchUnavailable, OutOfMemory };

/// Search `root` (an absolute directory already resolved from a trusted
/// repository binding) for files matching `query`. Returned paths are always
/// relative to `root`, never absolute and never contain `..` segments.
pub fn search(
    allocator: std.mem.Allocator,
    root: []const u8,
    query: []const u8,
    limit: usize,
) SearchError!Results {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var candidates: std.ArrayList([]const u8) = .empty;
    var truncated = false;
    var source: Source = .git;
    const listed = gitListFiles(arena, root, &candidates, &truncated) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    if (!listed) {
        source = .walk;
        candidates.clearRetainingCapacity();
        truncated = false;
        walkListFiles(arena, root, &candidates, &truncated) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SearchUnavailable,
        };
    }

    const bounded_limit = @max(@as(usize, 1), @min(limit, MAX_LIMIT));
    const files = try rank(arena, candidates.items, query, bounded_limit);
    return .{
        .arena = arena_state,
        .files = files,
        .total_files = candidates.items.len,
        .truncated = truncated,
        .source = source,
    };
}

/// Returns false when `root` is not inside a usable git work tree.
fn gitListFiles(
    arena: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayList([]const u8),
    truncated: *bool,
) !bool {
    var env_map = try process_env.buildAugmentedEnvMap(arena);
    defer env_map.deinit();
    // Never take index.lock for a read-only listing.
    try env_map.put("GIT_OPTIONAL_LOCKS", "0");
    const git = process_env.resolveExecutableInEnvMapAlloc(arena, &env_map, "git") catch return false;

    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const result = std.process.run(arena, threaded.io(), .{
        // Running inside `root` scopes output to that subtree with paths
        // relative to it, which is exactly the mention namespace.
        .argv = &.{ git, "-c", "core.quotepath=off", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--deduplicate" },
        .cwd = .{ .path = root },
        .environ_map = &env_map,
        .stdout_limit = .limited(GIT_STDOUT_LIMIT),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(GIT_TIMEOUT_MS), .clock = .awake } },
    }) catch return false;
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    var entries = std.mem.splitScalar(u8, result.stdout, 0);
    while (entries.next()) |entry| {
        if (!safeRelativePath(entry)) continue;
        if (out.items.len >= MAX_CANDIDATES) {
            truncated.* = true;
            break;
        }
        try out.append(arena, entry);
    }
    // An empty listing usually means `root` sits in an ignored directory of
    // an enclosing repository (or is an empty repo); walk it instead.
    return out.items.len != 0;
}

fn walkListFiles(
    arena: std.mem.Allocator,
    root: []const u8,
    out: *std.ArrayList([]const u8),
    truncated: *bool,
) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var visited: usize = 0;
    while (walker.next(io) catch null) |entry| {
        visited += 1;
        if (visited > MAX_WALK_ENTRIES or out.items.len >= MAX_CANDIDATES) {
            truncated.* = true;
            break;
        }
        switch (entry.kind) {
            .directory => if (entry.depth() >= MAX_WALK_DEPTH or skippedDirectory(entry.basename)) walker.leave(io),
            .file => {
                const path = std.mem.sliceTo(entry.path, 0);
                if (!safeRelativePath(path)) continue;
                try out.append(arena, try arena.dupe(u8, path));
            },
            else => {},
        }
    }
}

fn skippedDirectory(name: []const u8) bool {
    for (SKIPPED_DIRECTORIES) |skipped| if (std.mem.eql(u8, name, skipped)) return true;
    return false;
}

/// Defense in depth: only emit plain relative slash paths.
fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path.len > 4096) return false;
    for (path) |byte| if (byte < 0x20 or byte == '\\' or byte == 0x7f) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) return false;
    }
    return true;
}

const Scored = struct { path: []const u8, score: i32 };

fn rank(arena: std.mem.Allocator, candidates: []const []const u8, query: []const u8, limit: usize) ![]Match {
    var scored: std.ArrayList(Scored) = .empty;
    for (candidates) |path| {
        const value = score(path, query) orelse continue;
        try scored.append(arena, .{ .path = path, .score = value });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.path.len != b.path.len) return a.path.len < b.path.len;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    const count = @min(limit, scored.items.len);
    const matches = try arena.alloc(Match, count);
    for (scored.items[0..count], matches) |item, *match| {
        match.* = .{ .path = item.path, .file_name = std.fs.path.basenamePosix(item.path) };
    }
    return matches;
}

fn isBoundary(path: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = path[index - 1];
    if (previous == '/' or previous == '_' or previous == '-' or previous == '.' or previous == ' ') return true;
    return std.ascii.isLower(previous) and std.ascii.isUpper(path[index]);
}

/// Case-insensitive subsequence score favoring basename, prefix, contiguous
/// and word-boundary matches; null when `query` is not a subsequence.
pub fn score(path: []const u8, query: []const u8) ?i32 {
    const name_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| slash + 1 else 0;
    const name = path[name_start..];
    // Shorter, shallower paths win ties naturally.
    var total: i32 = -@as(i32, @intCast(@min(path.len, 200)));
    if (query.len == 0) return total;

    if (std.ascii.eqlIgnoreCase(name, query)) total += 1000;
    if (std.ascii.startsWithIgnoreCase(name, query)) total += 400;
    if (std.ascii.indexOfIgnoreCase(name, query) != null) total += 250;
    if (std.ascii.indexOfIgnoreCase(path, query) != null) total += 120;

    // Prefer matching entirely inside the basename when the query has no '/'.
    const has_slash = std.mem.indexOfScalar(u8, query, '/') != null;
    const in_name = if (!has_slash) subsequenceScore(path, name_start, query) else null;
    if (in_name) |value| return total + value + 80;
    const anywhere = subsequenceScore(path, 0, query) orelse return null;
    return total + anywhere;
}

fn subsequenceScore(path: []const u8, start: usize, query: []const u8) ?i32 {
    var total: i32 = 0;
    var qi: usize = 0;
    var run: i32 = 0;
    var last: ?usize = null;
    var index = start;
    while (index < path.len and qi < query.len) : (index += 1) {
        if (std.ascii.toLower(path[index]) != std.ascii.toLower(query[qi])) {
            continue;
        }
        total += 16;
        if (last) |previous| {
            if (previous + 1 == index) {
                run += 1;
                total += 8 * run;
            } else {
                run = 0;
                total -= @intCast(@min(index - previous - 1, 12));
            }
        }
        if (isBoundary(path, index)) total += 12;
        last = index;
        qi += 1;
    }
    return if (qi == query.len) total else null;
}

test "score prefers exact basename, prefix and contiguous matches" {
    try std.testing.expect(score("src/main.zig", "xyz") == null);
    try std.testing.expect(score("src/main.zig", "main.zig").? > score("src/domain/amain.zig", "main.zig").?);
    try std.testing.expect(score("src/state.zig", "state").? > score("src/sidebar/tabs_ate.zig", "state").?);
    try std.testing.expect(score("a/b/composer_commands.ts", "cmpcmd") != null);
    try std.testing.expect(score("web/src/lib/store.ts", "lib/store").? > score("web/src/lib/other_store.ts", "lib/store").?);
}

test "unsafe relative paths are never emitted" {
    for ([_][]const u8{ "", "/etc/passwd", "../x", "a/../b", "a//b", "a\\b", "a\nb", "./a" }) |path| {
        try std.testing.expect(!safeRelativePath(path));
    }
    try std.testing.expect(safeRelativePath("dir/my file.ts"));
}

test "walk fallback lists relative files and skips heavy directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/nested");
    try tmp.dir.createDirPath(io, "node_modules/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/nested/needle_file.ts", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/pkg/needle_file.ts", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    var truncated = false;
    try walkListFiles(arena_state.allocator(), root, &files, &truncated);
    try std.testing.expect(!truncated);
    try std.testing.expectEqual(@as(usize, 2), files.items.len);

    const ranked = try rank(arena_state.allocator(), files.items, "needle", 10);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqualStrings("src/nested/needle_file.ts", ranked[0].path);
    try std.testing.expectEqualStrings("needle_file.ts", ranked[0].file_name);
}
