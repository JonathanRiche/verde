//! Raw `origin` fetch URL capture for repository identity.
//!
//! The daemon stores the RAW value (`git remote get-url origin`, so
//! `insteadOf` rewrites apply). Normalization is client-side, one copy in
//! `client_core/src/shared/repo_identity.zig`. `upstream` is never read, so a
//! fork never groups with its parent. Every git call is bounded; a missing
//! git, a non-repository, no `origin`, a timeout, or a credential-bearing URL
//! all yield null instead of an error.

const std = @import("std");

const directory_browser = @import("directory_browser.zig");
const git_changes = @import("git_changes.zig");
const platform_runtime = @import("platform_runtime");
const store = @import("store.zig");

/// Per-call bound for workspace create / bind / manifest refresh.
pub const ORIGIN_TIMEOUT_MS: i64 = 1_000;
/// Total git time one workspace's origin capture may spend.
pub const CAPTURE_BUDGET_MS: i64 = 2_000;
/// Per-call bound while annotating a directory listing.
pub const LISTING_TIMEOUT_MS: i64 = 500;
/// Total git time one directory listing may spend on identities.
pub const LISTING_BUDGET_MS: i64 = 1_500;
/// Most entries one directory listing annotates.
pub const MAX_LISTING_IDENTITIES: usize = 64;

/// Read `root_path`'s raw origin URL. The slice lives in `git.arena`.
pub fn read(git: *git_changes.Git, root_path: []const u8, timeout_ms: i64) ?[]const u8 {
    const result = git.run(root_path, &.{ "remote", "get-url", "origin" }, .{ .timeout_ms = timeout_ms }) catch return null;
    if (!result.ok()) return null;
    const url = std.mem.trim(u8, result.stdout, " \t\r\n");
    // The store rejects userinfo passwords, query tokens and the like; never
    // surface what it would refuse to persist.
    if (!store.validVcsIdentity(url)) return null;
    return url;
}

/// Fill `git_identity` for listing entries that hold a `.git`, within
/// `MAX_LISTING_IDENTITIES` calls and `LISTING_BUDGET_MS` of git time.
/// Identities are duplicated into `allocator` (the listing arena).
pub fn annotateEntries(allocator: std.mem.Allocator, entries: []directory_browser.Entry) void {
    var candidates: usize = 0;
    for (entries) |entry| {
        if (entry.has_git) candidates += 1;
    }
    if (candidates == 0) return;
    var git_arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer git_arena_state.deinit();
    var git = git_changes.Git.init(git_arena_state.allocator()) catch return;
    defer git.deinit();
    const started_ns = monotonicNs();
    var calls: usize = 0;
    for (entries) |*entry| {
        if (!entry.has_git) continue;
        if (calls >= MAX_LISTING_IDENTITIES) return;
        const elapsed_ms: i64 = @intCast((monotonicNs() -| started_ns) / std.time.ns_per_ms);
        if (elapsed_ms >= LISTING_BUDGET_MS) return;
        calls += 1;
        const identity = read(&git, entry.path, @min(LISTING_TIMEOUT_MS, LISTING_BUDGET_MS - elapsed_ms)) orelse continue;
        entry.git_identity = allocator.dupe(u8, identity) catch return;
    }
}

fn monotonicNs() u64 {
    return platform_runtime.monotonicTimestampNs();
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Temporary repository with `origin` set; null when git is unavailable.
pub const TestOriginRepo = struct {
    tmp: testing.TmpDir,
    root: []u8,

    pub fn init(origin: ?[]const u8) !?TestOriginRepo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "repo");
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(base);
        const root = try std.fs.path.join(testing.allocator, &.{ base, "repo" });
        errdefer testing.allocator.free(root);
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var git = git_changes.Git.init(arena_state.allocator()) catch return null;
        defer git.deinit();
        const initialized = git.run(root, &.{ "init", "-q" }, .{ .read_only = false }) catch return null;
        if (!initialized.ok()) return null;
        if (origin) |url| {
            const added = try git.run(root, &.{ "remote", "add", "origin", url }, .{ .read_only = false });
            if (!added.ok()) return error.TestGitFailed;
        }
        return .{ .tmp = tmp, .root = root };
    }

    pub fn deinit(self: *TestOriginRepo) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

test "origin read returns the raw origin URL and ignores upstream" {
    var repo = (try TestOriginRepo.init("git@github.com:Owner/Repo.git")) orelse return error.SkipZigTest;
    defer repo.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var git = try git_changes.Git.init(arena_state.allocator());
    defer git.deinit();
    const added = try git.run(repo.root, &.{ "remote", "add", "upstream", "https://github.com/other/repo.git" }, .{ .read_only = false });
    try testing.expect(added.ok());
    try testing.expectEqualStrings("git@github.com:Owner/Repo.git", read(&git, repo.root, ORIGIN_TIMEOUT_MS).?);
}

test "origin read is null without origin or for credential-bearing URLs" {
    var bare = (try TestOriginRepo.init(null)) orelse return error.SkipZigTest;
    defer bare.deinit();
    var secret = (try TestOriginRepo.init("https://user:token@github.com/owner/repo.git")) orelse return error.SkipZigTest;
    defer secret.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var git = try git_changes.Git.init(arena_state.allocator());
    defer git.deinit();
    try testing.expect(read(&git, bare.root, ORIGIN_TIMEOUT_MS) == null);
    try testing.expect(read(&git, secret.root, ORIGIN_TIMEOUT_MS) == null);
}

test "directory listing carries git_identity only for entries holding .git" {
    var repo = (try TestOriginRepo.init("https://github.com/owner/repo.git")) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.tmp.dir.createDirPath(testing.io, "plain");
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = std.fs.path.dirname(repo.root).?;
    const listing = try directory_browser.list(arena, testing.io, &.{base}, base);
    const entries = @constCast(listing.directories);
    annotateEntries(arena, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("plain", entries[0].name);
    try testing.expect(entries[0].git_identity == null);
    try testing.expectEqualStrings("repo", entries[1].name);
    try testing.expectEqualStrings("https://github.com/owner/repo.git", entries[1].git_identity.?);

    const json = try std.json.Stringify.valueAlloc(arena, listing, .{});
    try testing.expect(std.mem.indexOf(u8, json, "\"git_identity\":\"https://github.com/owner/repo.git\"") != null);
    // Absent identities are omitted, and the internal flag never reaches the wire.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "git_identity"));
    try testing.expect(std.mem.indexOf(u8, json, "has_git") == null);
}
