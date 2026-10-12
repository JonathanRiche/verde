//! First-run workspace suggestions: project folders the user already works in,
//! gathered from coding-agent history (Claude Code, Codex) and git checkouts in
//! common source directories. Scanning runs once on a background thread; the
//! welcome screen reads the finished snapshot and never blocks on disk I/O.

const std = @import("std");
const platform_paths = @import("platform_paths");
const loop_wakeup = @import("loop_wakeup");
const state_sync = @import("sync.zig");

pub const MAX_SUGGESTIONS: usize = 5;
const MAX_PATH_BYTES: usize = 1024;
const MAX_CONFIG_BYTES: usize = 32 * 1024 * 1024;
/// Bounds each source-directory walk so a huge home tree cannot stall the scan.
const MAX_ENTRIES_PER_ROOT: usize = 512;
/// Common parents of git checkouts, relative to the home directory.
const SOURCE_ROOTS = [_][]const u8{ "development", "Development", "dev", "Projects", "projects", "code", "Code", "src", "repos", "git", "Work", "work" };

pub const Source = enum {
    claude,
    codex,
    git,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .claude => "Claude Code",
            .codex => "Codex",
            .git => "Git repo",
        };
    }
};

pub const Suggestion = struct {
    path_buf: [MAX_PATH_BYTES]u8 = undefined,
    path_len: usize = 0,
    source: Source = .git,
    modified_ns: i128 = 0,
    /// Length of the home-directory prefix to show as `~`, or 0.
    home_prefix_len: usize = 0,

    pub fn path(self: *const Suggestion) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn name(self: *const Suggestion) []const u8 {
        return std.fs.path.basename(self.path());
    }

    /// Parent directory with the home prefix shortened to `~`.
    pub fn displayParent(self: *const Suggestion, buf: []u8) []const u8 {
        const parent = std.fs.path.dirname(self.path()) orelse return self.path();
        if (self.home_prefix_len == 0 or parent.len < self.home_prefix_len) return parent;
        return std.fmt.bufPrint(buf, "~{s}", .{parent[self.home_prefix_len..]}) catch parent;
    }
};

const Status = enum { idle, scanning, done };

var mutex: state_sync.Mutex = .{};
var status: Status = .idle;
var results: [MAX_SUGGESTIONS]Suggestion = undefined;
var result_count: usize = 0;

/// Starts the one-time background scan. Safe to call every frame.
pub fn ensureStarted() void {
    mutex.lock();
    defer mutex.unlock();
    if (status != .idle) return;
    status = .scanning;
    const thread = std.Thread.spawn(.{}, scanWorker, .{}) catch {
        status = .done;
        return;
    };
    thread.detach();
}

/// Copies the finished suggestions into `out`; empty while the scan runs.
pub fn snapshot(out: *[MAX_SUGGESTIONS]Suggestion) usize {
    mutex.lock();
    defer mutex.unlock();
    if (status != .done) return 0;
    @memcpy(out[0..result_count], results[0..result_count]);
    return result_count;
}

const Candidate = struct {
    path: []u8,
    source: Source,
    modified_ns: i128,
};

fn scanWorker() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var found: [MAX_SUGGESTIONS]Suggestion = undefined;
    const count = collect(arena, &found) catch 0;

    mutex.lock();
    @memcpy(results[0..count], found[0..count]);
    result_count = count;
    status = .done;
    mutex.unlock();
    loop_wakeup.notify();
}

fn collect(arena: std.mem.Allocator, out: *[MAX_SUGGESTIONS]Suggestion) !usize {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const home = try platform_paths.userHome(arena);

    var candidates: std.ArrayList(Candidate) = .empty;
    collectClaude(arena, io, home, &candidates) catch {};
    collectCodex(arena, io, home, &candidates) catch {};
    for (SOURCE_ROOTS) |root| collectGitRepos(arena, io, home, root, &candidates) catch {};

    // Most recently touched first; agent history wins ties over plain repos.
    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.modified_ns != b.modified_ns) return a.modified_ns > b.modified_ns;
            return @intFromEnum(a.source) < @intFromEnum(b.source);
        }
    }.lessThan);

    var count: usize = 0;
    for (candidates.items) |candidate| {
        if (count == MAX_SUGGESTIONS) break;
        if (candidate.path.len > MAX_PATH_BYTES) continue;
        var duplicate = false;
        for (out[0..count]) |*existing| {
            if (std.mem.eql(u8, existing.path(), candidate.path)) duplicate = true;
        }
        if (duplicate) continue;
        const home_root = std.mem.trimEnd(u8, home, "/");
        const under_home = home_root.len > 0 and std.mem.startsWith(u8, candidate.path, home_root) and
            candidate.path.len > home_root.len and candidate.path[home_root.len] == '/';
        out[count] = .{
            .source = candidate.source,
            .modified_ns = candidate.modified_ns,
            .path_len = candidate.path.len,
            .home_prefix_len = if (under_home) home_root.len else 0,
        };
        @memcpy(out[count].path_buf[0..candidate.path.len], candidate.path);
        count += 1;
    }
    return count;
}

/// Adds `raw_path` when it is an existing, non-hidden directory other than home.
fn addCandidate(
    arena: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    raw_path: []const u8,
    source: Source,
    recency_path: ?[]const u8,
    candidates: *std.ArrayList(Candidate),
) !void {
    const trimmed = std.mem.trimEnd(u8, raw_path, "/");
    if (trimmed.len == 0 or !std.fs.path.isAbsolute(trimmed)) return;
    if (std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, home, "/"))) return;
    const base = std.fs.path.basename(trimmed);
    if (base.len == 0 or base[0] == '.') return;
    const stat = std.Io.Dir.cwd().statFile(io, trimmed, .{}) catch return;
    if (stat.kind != .directory) return;
    var modified: i128 = stat.mtime.toNanoseconds();
    if (recency_path) |recency| {
        if (std.Io.Dir.cwd().statFile(io, recency, .{})) |recent| {
            modified = @max(modified, @as(i128, recent.mtime.toNanoseconds()));
        } else |_| {}
    }
    try candidates.append(arena, .{ .path = try arena.dupe(u8, trimmed), .source = source, .modified_ns = modified });
}

// Claude Code lists every project it has opened under `projects` in
// ~/.claude.json; its per-project session directory dates the last use.
fn collectClaude(arena: std.mem.Allocator, io: std.Io, home: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    const config_path = try std.fs.path.join(arena, &.{ home, ".claude.json" });
    const content = try std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(MAX_CONFIG_BYTES));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, content, .{});
    if (parsed != .object) return;
    const projects = parsed.object.get("projects") orelse return;
    if (projects != .object) return;
    var it = projects.object.iterator();
    while (it.next()) |entry| {
        const project_path = entry.key_ptr.*;
        const encoded = try arena.dupe(u8, project_path);
        for (encoded) |*byte| {
            if (!std.ascii.isAlphanumeric(byte.*)) byte.* = '-';
        }
        const session_dir = try std.fs.path.join(arena, &.{ home, ".claude", "projects", encoded });
        try addCandidate(arena, io, home, project_path, .claude, session_dir, candidates);
    }
}

// Codex records trusted projects as `[projects."<path>"]` tables.
fn collectCodex(arena: std.mem.Allocator, io: std.Io, home: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    const config_path = try std.fs.path.join(arena, &.{ home, ".codex", "config.toml" });
    const content = try std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(MAX_CONFIG_BYTES));
    var lines = std.mem.splitScalar(u8, content, '\n');
    const prefix = "[projects.\"";
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, "\"]")) continue;
        const project_path = line[prefix.len .. line.len - 2];
        if (std.mem.indexOfScalar(u8, project_path, '"') != null) continue;
        try addCandidate(arena, io, home, project_path, .codex, null, candidates);
    }
}

// Git checkouts one or two levels below a common source directory, dated by
// their index so recently committed or staged repos rank first.
fn collectGitRepos(arena: std.mem.Allocator, io: std.Io, home: []const u8, root_name: []const u8, candidates: *std.ArrayList(Candidate)) !void {
    const root = try std.fs.path.join(arena, &.{ home, root_name });
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var scanned: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (scanned == MAX_ENTRIES_PER_ROOT) return;
        scanned += 1;
        if (entry.kind != .directory or entry.name.len == 0 or entry.name[0] == '.') continue;
        const child = try std.fs.path.join(arena, &.{ root, entry.name });
        if (try addGitRepo(arena, io, home, child, candidates)) continue;
        var child_dir = std.Io.Dir.cwd().openDir(io, child, .{ .iterate = true }) catch continue;
        defer child_dir.close(io);
        var child_it = child_dir.iterate();
        while (child_it.next(io) catch null) |grandchild| {
            if (scanned == MAX_ENTRIES_PER_ROOT) return;
            scanned += 1;
            if (grandchild.kind != .directory or grandchild.name.len == 0 or grandchild.name[0] == '.') continue;
            const nested = try std.fs.path.join(arena, &.{ child, grandchild.name });
            _ = try addGitRepo(arena, io, home, nested, candidates);
        }
    }
}

fn addGitRepo(arena: std.mem.Allocator, io: std.Io, home: []const u8, path: []const u8, candidates: *std.ArrayList(Candidate)) !bool {
    const git_dir = try std.fs.path.join(arena, &.{ path, ".git" });
    std.Io.Dir.cwd().access(io, git_dir, .{}) catch return false;
    const index = try std.fs.path.join(arena, &.{ git_dir, "index" });
    try addCandidate(arena, io, home, path, .git, index, candidates);
    return true;
}
