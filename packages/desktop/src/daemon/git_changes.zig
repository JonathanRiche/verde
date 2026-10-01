//! Per-chat git change attribution and user-initiated commits.
//!
//! The daemon snapshots every git repository a chat turn can reach when the
//! turn starts and when it ends. Files whose content changed inside that
//! window are claimed by the turn's chat. When two turns touching the same
//! repository overlap in time, a changed file is only claimed confidently if
//! the provider itself reported editing it; otherwise the claim is marked
//! unclear so the user decides. Files no chat claimed are "unassigned".
//!
//! Commits are always user-initiated. A review freezes each file's patch
//! against HEAD; committing applies the selected hunks of that frozen patch to
//! a private temporary index (`GIT_INDEX_FILE`), writes a commit with
//! plumbing, and compare-and-swaps HEAD. The user's real index keeps whatever
//! else was staged there.
//!
//! This module owns no locks. The daemon serializes all `Ledger` and `Reviews`
//! access behind its own mutex and runs git with no daemon lock held.

const std = @import("std");

const process_env = @import("../platform/env.zig");

const log = std.log.scoped(.git_changes);

/// Repositories with more dirty paths than this are not attributed; the
/// snapshot would be too slow and the claims meaningless.
pub const MAX_TRACKED_PATHS: usize = 4000;
/// Files larger than this hash by size + a bounded prefix instead of content.
const HASH_READ_LIMIT: usize = 16 * 1024 * 1024;
const GIT_TIMEOUT_MS: i64 = 15_000;
const PUSH_TIMEOUT_MS: i64 = 90_000;
const GIT_STDOUT_LIMIT: usize = 64 * 1024 * 1024;
/// Files beyond this in one review are listed without a frozen patch.
const MAX_REVIEW_PATCH_FILES: usize = 300;
/// Frozen per-file patch cap; larger files commit by path instead.
const MAX_FROZEN_PATCH_BYTES: usize = 8 * 1024 * 1024;
/// Hunk text returned to clients per file; beyond it only whole-file selection.
const MAX_PREVIEW_BYTES_PER_FILE: usize = 256 * 1024;
/// Hunk text returned to clients per review.
const MAX_PREVIEW_BYTES_TOTAL: usize = 3 * 1024 * 1024;
pub const MAX_REVIEWS: usize = 16;
pub const REVIEW_TTL_MS: i64 = 60 * 60 * 1000;
const DELETED_HASH: u64 = 1;
pub const LEDGER_FILE_NAME = "git-change-claims.json";
const LEDGER_VERSION: i64 = 1;

pub const Error = error{
    OutOfMemory,
    GitUnavailable,
    NotARepository,
    ReviewNotFound,
    NothingSelected,
    NothingToCommit,
    InvalidSelection,
    ChangedSinceReview,
    HeadMoved,
    CommitFailed,
    MissingIdentity,
    TurnsRunning,
    BranchCreateFailed,
};

// ---------------------------------------------------------------------------
// Git process helper

pub const Git = struct {
    arena: std.mem.Allocator,
    env: std.process.Environ.Map,
    executable: []const u8,

    pub fn init(arena: std.mem.Allocator) Error!Git {
        var env = process_env.buildAugmentedEnvMap(arena) catch return error.GitUnavailable;
        errdefer env.deinit();
        env.put("GIT_TERMINAL_PROMPT", "0") catch return error.OutOfMemory;
        env.put("GIT_LITERAL_PATHSPECS", "1") catch return error.OutOfMemory;
        env.put("LC_ALL", "C") catch return error.OutOfMemory;
        env.put("GIT_PAGER", "cat") catch return error.OutOfMemory;
        const executable = process_env.resolveExecutableInEnvMapAlloc(arena, &env, "git") catch return error.GitUnavailable;
        return .{ .arena = arena, .env = env, .executable = executable };
    }

    pub fn deinit(self: *Git) void {
        self.env.deinit();
    }

    pub const RunOptions = struct {
        index_file: ?[]const u8 = null,
        /// Read-only commands never take index.lock.
        read_only: bool = true,
        timeout_ms: i64 = GIT_TIMEOUT_MS,
    };

    pub const Result = struct {
        exit_code: ?u8,
        stdout: []const u8,
        stderr: []const u8,

        pub fn ok(self: Result) bool {
            return self.exit_code != null and self.exit_code.? == 0;
        }
    };

    pub fn run(self: *Git, cwd: []const u8, args: []const []const u8, options: RunOptions) Error!Result {
        const argv = self.arena.alloc([]const u8, args.len + 3) catch return error.OutOfMemory;
        argv[0] = self.executable;
        argv[1] = "-c";
        argv[2] = "core.quotepath=off";
        @memcpy(argv[3..], args);

        // Per-call env deltas without disturbing the shared map.
        if (options.read_only) {
            self.env.put("GIT_OPTIONAL_LOCKS", "0") catch return error.OutOfMemory;
        } else {
            _ = self.env.swapRemove("GIT_OPTIONAL_LOCKS");
        }
        if (options.index_file) |index_file| {
            self.env.put("GIT_INDEX_FILE", index_file) catch return error.OutOfMemory;
        } else {
            _ = self.env.swapRemove("GIT_INDEX_FILE");
        }

        var threaded: std.Io.Threaded = .init(self.arena, .{});
        defer threaded.deinit();
        const result = std.process.run(self.arena, threaded.io(), .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &self.env,
            .stdout_limit = .limited(GIT_STDOUT_LIMIT),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(options.timeout_ms), .clock = .awake } },
        }) catch |err| {
            log.warn("git {s} failed to run err={s}", .{ args[0], @errorName(err) });
            return error.GitUnavailable;
        };
        const exit_code: ?u8 = switch (result.term) {
            .exited => |code| code,
            else => null,
        };
        return .{ .exit_code = exit_code, .stdout = result.stdout, .stderr = result.stderr };
    }

    /// Trimmed stdout of a command that must succeed.
    pub fn output(self: *Git, cwd: []const u8, args: []const []const u8, options: RunOptions) Error![]const u8 {
        const result = try self.run(cwd, args, options);
        if (!result.ok()) return error.GitUnavailable;
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }
};

pub fn repoToplevel(git: *Git, path: []const u8) Error!?[]const u8 {
    const result = git.run(path, &.{ "rev-parse", "--show-toplevel" }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!result.ok()) return null;
    const top = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (top.len == 0) return null;
    return top;
}

/// HEAD commit id, or null for an unborn branch.
pub fn headOid(git: *Git, repo: []const u8) Error!?[]const u8 {
    const result = try git.run(repo, &.{ "rev-parse", "-q", "--verify", "HEAD^{commit}" }, .{});
    if (!result.ok()) return null;
    const oid = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (oid.len == 0) null else oid;
}

pub fn currentBranch(git: *Git, repo: []const u8) Error!?[]const u8 {
    const result = try git.run(repo, &.{ "symbolic-ref", "--short", "-q", "HEAD" }, .{});
    if (!result.ok()) return null;
    const name = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (name.len == 0) null else name;
}

/// Branch facts for button labels. Read-only and never fetches, so
/// ahead/behind compare against the last fetched upstream.
pub const RepoStatus = struct {
    /// Null when HEAD is detached.
    branch: ?[]const u8 = null,
    default_branch: ?[]const u8 = null,
    is_default_branch: bool = false,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    has_remote: bool = false,
};

pub fn repoStatus(git: *Git, root: []const u8) Error!RepoStatus {
    var status: RepoStatus = .{ .branch = try currentBranch(git, root) };
    status.has_remote = (try publishRemote(git, root)) != null;
    status.default_branch = try defaultBranch(git, root);
    if (status.branch) |branch| if (status.default_branch) |default| {
        status.is_default_branch = std.mem.eql(u8, branch, default);
    };
    if (status.branch != null) status.upstream = try upstreamName(git, root);
    if (status.upstream != null) {
        const counts = try git.run(root, &.{ "rev-list", "--left-right", "--count", "@{u}...HEAD" }, .{});
        if (counts.ok()) {
            // Left side is the upstream (behind), right side is HEAD (ahead).
            var fields = std.mem.tokenizeAny(u8, counts.stdout, " \t\r\n");
            status.behind = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
            status.ahead = std.fmt.parseInt(u32, fields.next() orelse "0", 10) catch 0;
        }
    } else if (status.branch != null and status.has_remote) {
        // Unpublished branch: count commits no remote-tracking ref has yet, so
        // a freshly created feature branch still offers Push.
        const counts = try git.run(root, &.{ "rev-list", "--count", "HEAD", "--not", "--remotes" }, .{});
        if (counts.ok()) status.ahead = std.fmt.parseInt(u32, std.mem.trim(u8, counts.stdout, " \t\r\n"), 10) catch 0;
    }
    return status;
}

/// `origin/HEAD`'s target, else `main` or `master` when present locally.
fn defaultBranch(git: *Git, root: []const u8) Error!?[]const u8 {
    const remote_head = try git.run(root, &.{ "symbolic-ref", "-q", "refs/remotes/origin/HEAD" }, .{});
    if (remote_head.ok()) {
        const target = std.mem.trim(u8, remote_head.stdout, " \t\r\n");
        const prefix = "refs/remotes/origin/";
        if (std.mem.startsWith(u8, target, prefix) and target.len > prefix.len) return target[prefix.len..];
    }
    for ([_][]const u8{ "main", "master" }) |candidate| {
        const ref = std.fmt.allocPrint(git.arena, "refs/heads/{s}", .{candidate}) catch return error.OutOfMemory;
        const found = try git.run(root, &.{ "rev-parse", "-q", "--verify", ref }, .{});
        if (found.ok()) return candidate;
    }
    return null;
}

pub const StatusEntry = struct {
    path: []const u8,
    /// Porcelain XY code.
    x: u8,
    y: u8,

    pub fn untracked(self: StatusEntry) bool {
        return self.x == '?' and self.y == '?';
    }
};

/// Dirty paths relative to HEAD (staged, unstaged and untracked). Returns null
/// when the repository has more dirty paths than attribution can track.
pub fn dirtyPaths(git: *Git, repo: []const u8) Error!?[]StatusEntry {
    const result = try git.run(repo, &.{ "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=dirty" }, .{});
    if (!result.ok()) return error.GitUnavailable;
    var entries: std.ArrayList(StatusEntry) = .empty;
    var it = std.mem.splitScalar(u8, result.stdout, 0);
    while (it.next()) |record| {
        if (record.len < 4 or record[2] != ' ') continue;
        const path = record[3..];
        if (path.len == 0 or path[path.len - 1] == '/') continue;
        if (entries.items.len >= MAX_TRACKED_PATHS) return null;
        entries.append(git.arena, .{ .path = path, .x = record[0], .y = record[1] }) catch return error.OutOfMemory;
    }
    return entries.items;
}

/// Total bytes one snapshot reads for content hashes; later files hash by
/// size + mtime so a repository full of large dirty files cannot stall a turn.
const SNAPSHOT_READ_BUDGET: usize = 128 * 1024 * 1024;

const HashContext = struct {
    /// Scratch for file contents; freed per file, never the snapshot arena.
    scratch: std.mem.Allocator,
    io: std.Io,
    budget: usize = SNAPSHOT_READ_BUDGET,
};

fn hashWorkingFile(ctx: *HashContext, arena: std.mem.Allocator, repo: []const u8, path: []const u8) u64 {
    const absolute = std.fs.path.join(arena, &.{ repo, path }) catch return DELETED_HASH + 1;
    const stat = std.Io.Dir.cwd().statFile(ctx.io, absolute, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return DELETED_HASH,
        else => return DELETED_HASH + 1,
    };
    const size: usize = @intCast(@min(stat.size, std.math.maxInt(usize)));
    if (size > HASH_READ_LIMIT or size > ctx.budget) {
        var hasher = std.hash.Wyhash.init(0x5eed);
        hasher.update(std.mem.asBytes(&stat.size));
        hasher.update(std.mem.asBytes(&stat.mtime));
        return normalizeHash(hasher.final());
    }
    ctx.budget -= size;
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, absolute, ctx.scratch, .limited(HASH_READ_LIMIT + 1)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return DELETED_HASH,
        else => return DELETED_HASH + 1,
    };
    defer ctx.scratch.free(bytes);
    return normalizeHash(std.hash.Wyhash.hash(0, bytes));
}

fn normalizeHash(value: u64) u64 {
    return if (value <= DELETED_HASH + 1) value + 2 else value;
}

// ---------------------------------------------------------------------------
// Snapshots

pub const RepoSnapshot = struct {
    root: []const u8,
    /// Dirty path -> content hash (DELETED_HASH for deleted files).
    files: std.StringArrayHashMapUnmanaged(u64) = .empty,
    /// False when the repository was too dirty to track.
    complete: bool = true,
};

pub const TurnSnapshot = struct {
    arena_state: std.heap.ArenaAllocator,
    repos: []RepoSnapshot,

    pub fn deinit(self: *TurnSnapshot) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn find(self: *const TurnSnapshot, root: []const u8) ?*const RepoSnapshot {
        for (self.repos) |*repo| if (std.mem.eql(u8, repo.root, root)) return repo;
        return null;
    }
};

/// Snapshot every distinct git repository that contains one of `paths`.
/// Non-repository paths are skipped silently.
pub fn captureSnapshot(gpa: std.mem.Allocator, paths: []const []const u8) Error!TurnSnapshot {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var git = try Git.init(arena);
    defer git.deinit();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var hash_ctx: HashContext = .{ .scratch = gpa, .io = threaded.io() };

    var repos: std.ArrayList(RepoSnapshot) = .empty;
    for (paths) |path| {
        const top = (try repoToplevel(&git, path)) orelse continue;
        var seen = false;
        for (repos.items) |repo| if (std.mem.eql(u8, repo.root, top)) {
            seen = true;
        };
        if (seen) continue;
        var repo: RepoSnapshot = .{ .root = arena.dupe(u8, top) catch return error.OutOfMemory };
        const entries = dirtyPaths(&git, top) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (entries) |list| {
            for (list) |entry| {
                const hash = hashWorkingFile(&hash_ctx, arena, top, entry.path);
                repo.files.put(arena, entry.path, hash) catch return error.OutOfMemory;
            }
        } else {
            repo.complete = false;
        }
        repos.append(arena, repo) catch return error.OutOfMemory;
    }
    return .{ .arena_state = arena_state, .repos = repos.items };
}

// ---------------------------------------------------------------------------
// Claims ledger

pub const Claim = struct {
    repo: []u8,
    path: []u8,
    workspace_id: []u8,
    thread_id: []u8,
    /// Content hash when claimed.
    hash: u64,
    unclear: bool,
    at_ms: i64,

    fn deinit(self: *Claim, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.path);
        allocator.free(self.workspace_id);
        allocator.free(self.thread_id);
    }
};

/// A turn the ledger tracks for overlap: running, or recently ended and kept
/// so a later-ending overlapping turn can still read its edit evidence.
const TrackedTurn = struct {
    turn_id: []u8,
    repos: [][]u8,
    overlapped: bool,
    workspace_id: []u8,
    thread_id: []u8,
    /// Directory relative hints resolve against.
    cwd: []u8,
    /// Paths the provider reported editing (absolute or cwd-relative).
    hints: std.ArrayList([]u8) = .empty,
    /// Turns that ran at the same time in a shared repository.
    peers: std.ArrayList([]u8) = .empty,
    /// Set once the turn ended (retired records only).
    ended_ms: ?i64 = null,

    fn deinit(self: *TrackedTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.turn_id);
        for (self.repos) |repo| allocator.free(repo);
        allocator.free(self.repos);
        allocator.free(self.workspace_id);
        allocator.free(self.thread_id);
        allocator.free(self.cwd);
        for (self.hints.items) |hint| allocator.free(hint);
        self.hints.deinit(allocator);
        for (self.peers.items) |peer| allocator.free(peer);
        self.peers.deinit(allocator);
    }

    fn touches(self: TrackedTurn, root: []const u8) bool {
        for (self.repos) |repo| if (std.mem.eql(u8, repo, root)) return true;
        return false;
    }

    fn hasPeer(self: TrackedTurn, turn_id: []const u8) bool {
        for (self.peers.items) |peer| if (std.mem.eql(u8, peer, turn_id)) return true;
        return false;
    }

    fn addPeer(self: *TrackedTurn, allocator: std.mem.Allocator, turn_id: []const u8) Error!void {
        if (self.hasPeer(turn_id)) return;
        const owned = allocator.dupe(u8, turn_id) catch return error.OutOfMemory;
        self.peers.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    fn hinted(self: TrackedTurn, root: []const u8, repo_path: []const u8) bool {
        return hintMatches(self.hints.items, self.cwd, root, repo_path);
    }
};

/// Evidence kept per turn is bounded; later hints are dropped.
pub const MAX_TURN_HINTS: usize = 512;
/// Ended turns kept for overlapping peers; the oldest is dropped beyond this.
const MAX_RETIRED_TURNS: usize = 64;

/// Who a turn belongs to, for evidence shared with overlapping turns.
pub const TurnOwner = struct {
    workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    cwd: []const u8 = "",
};

pub const EndTurn = struct {
    turn_id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    /// Directory relative hints resolve against.
    cwd: []const u8,
    /// Extra paths the provider reported editing (absolute or cwd-relative),
    /// merged with those recorded through `recordHints`.
    hints: []const []const u8,
    now_ms: i64,
};

pub const Ledger = struct {
    allocator: std.mem.Allocator,
    claims: std.ArrayList(Claim) = .empty,
    active: std.ArrayList(TrackedTurn) = .empty,
    /// Ended turns whose evidence an overlapping, still running turn may need.
    retired: std.ArrayList(TrackedTurn) = .empty,
    /// Bumped whenever claims change; clients use it to skip redundant reads.
    revision: u64 = 0,
    /// Durable claims file; null keeps the ledger in memory (tests, store-disabled).
    persist_path: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Ledger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Ledger) void {
        for (self.claims.items) |*claim| claim.deinit(self.allocator);
        self.claims.deinit(self.allocator);
        for (self.active.items) |*turn| turn.deinit(self.allocator);
        self.active.deinit(self.allocator);
        for (self.retired.items) |*turn| turn.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        if (self.persist_path) |path| self.allocator.free(path);
        self.* = undefined;
    }

    /// Register a running turn over the repositories in `snapshot`. Any other
    /// running turn sharing a repository marks both as overlapped peers.
    pub fn beginTurn(self: *Ledger, turn_id: []const u8, snapshot: *const TurnSnapshot, owner: TurnOwner) Error!void {
        const a = self.allocator;
        var turn: TrackedTurn = .{
            .turn_id = a.dupe(u8, turn_id) catch return error.OutOfMemory,
            .repos = &.{},
            .overlapped = false,
            .workspace_id = &.{},
            .thread_id = &.{},
            .cwd = &.{},
        };
        errdefer turn.deinit(a);
        turn.workspace_id = a.dupe(u8, owner.workspace_id) catch return error.OutOfMemory;
        turn.thread_id = a.dupe(u8, owner.thread_id) catch return error.OutOfMemory;
        turn.cwd = a.dupe(u8, owner.cwd) catch return error.OutOfMemory;
        var repo_list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (repo_list.items) |repo| a.free(repo);
            repo_list.deinit(a);
        }
        for (snapshot.repos) |repo| {
            const owned = a.dupe(u8, repo.root) catch return error.OutOfMemory;
            repo_list.append(a, owned) catch {
                a.free(owned);
                return error.OutOfMemory;
            };
        }
        turn.repos = repo_list.toOwnedSlice(a) catch return error.OutOfMemory;
        for (self.active.items) |*other| {
            const shares = for (turn.repos) |repo| {
                if (other.touches(repo)) break true;
            } else false;
            if (!shares) continue;
            other.overlapped = true;
            turn.overlapped = true;
            try other.addPeer(a, turn_id);
            try turn.addPeer(a, other.turn_id);
        }
        self.active.append(a, turn) catch return error.OutOfMemory;
    }

    /// Record paths a running turn's provider reported editing.
    pub fn recordHints(self: *Ledger, turn_id: []const u8, paths: []const []const u8) void {
        const turn = self.findActive(turn_id) orelse return;
        for (paths) |raw| {
            const path = std.mem.trim(u8, raw, " \t\r\n");
            if (path.len == 0 or turn.hints.items.len >= MAX_TURN_HINTS) continue;
            const seen = for (turn.hints.items) |existing| {
                if (std.mem.eql(u8, existing, path)) break true;
            } else false;
            if (seen) continue;
            const owned = self.allocator.dupe(u8, path) catch return;
            turn.hints.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return;
            };
        }
    }

    /// Forget a running turn without claiming anything.
    pub fn abandonTurn(self: *Ledger, turn_id: []const u8) void {
        for (self.active.items, 0..) |*turn, i| {
            if (!std.mem.eql(u8, turn.turn_id, turn_id)) continue;
            turn.deinit(self.allocator);
            _ = self.active.orderedRemove(i);
            break;
        }
        self.pruneRetired();
    }

    pub fn repoHasActiveTurn(self: *const Ledger, root: []const u8) bool {
        for (self.active.items) |turn| if (turn.touches(root)) return true;
        return false;
    }

    /// Claim files whose content changed between `start` and `end`.
    ///
    /// A turn that ran alone claims every changed file. A turn that overlapped
    /// another in the same repository decides per file from edit evidence:
    /// hinted by this turn -> its claim (both turns hinting makes it shared);
    /// hinted only by an overlapping turn -> not claimed; hinted by nobody ->
    /// an unclear claim. Returns true when claims changed.
    pub fn endTurn(self: *Ledger, info: EndTurn, start: *const TurnSnapshot, end: *const TurnSnapshot) Error!bool {
        var turn: ?TrackedTurn = null;
        for (self.active.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.turn_id, info.turn_id)) continue;
            turn = self.active.orderedRemove(i);
            break;
        }
        var keep_turn = false;
        defer if (turn) |*value| {
            if (!keep_turn) value.deinit(self.allocator);
        };
        const overlapped = if (turn) |value| value.overlapped else false;

        var changed = false;
        for (end.repos) |*end_repo| {
            if (!end_repo.complete) continue;
            const start_repo = start.find(end_repo.root) orelse continue;
            if (!start_repo.complete) continue;
            const root = end_repo.root;

            // Claims for paths that are clean again are stale.
            if (self.pruneRepo(root, end_repo)) changed = true;

            var files = end_repo.files.iterator();
            while (files.next()) |entry| {
                const path = entry.key_ptr.*;
                const end_hash = entry.value_ptr.*;
                const start_hash = start_repo.files.get(path);
                if (start_hash != null and start_hash.? == end_hash) continue;
                if (!overlapped) {
                    if (try self.upsertClaim(root, path, info.workspace_id, info.thread_id, end_hash, false, info.now_ms)) changed = true;
                    continue;
                }
                const mine = hintMatches(info.hints, info.cwd, root, path) or
                    (if (turn) |value| value.hinted(root, path) else false);
                if (mine) {
                    if (try self.upsertClaim(root, path, info.workspace_id, info.thread_id, end_hash, false, info.now_ms)) changed = true;
                    if (turn) |value| if (self.dropPeerGuesses(value, root, path)) {
                        changed = true;
                    };
                    continue;
                }
                const theirs = if (turn) |value| self.peerHinted(value, root, path) else false;
                if (theirs) continue;
                if (try self.upsertClaim(root, path, info.workspace_id, info.thread_id, end_hash, true, info.now_ms)) changed = true;
            }
        }

        // Keep this turn's evidence while an overlapping peer still runs.
        if (turn) |*value| {
            const needed = for (self.active.items) |other| {
                if (other.hasPeer(value.turn_id)) break true;
            } else false;
            if (needed) {
                value.ended_ms = info.now_ms;
                if (self.retired.items.len >= MAX_RETIRED_TURNS) {
                    var oldest = self.retired.orderedRemove(0);
                    oldest.deinit(self.allocator);
                }
                if (self.retired.append(self.allocator, value.*)) |_| {
                    keep_turn = true;
                } else |_| {}
            }
        }
        self.pruneRetired();
        if (changed) self.revision += 1;
        return changed;
    }

    fn findActive(self: *Ledger, turn_id: []const u8) ?*TrackedTurn {
        for (self.active.items) |*turn| if (std.mem.eql(u8, turn.turn_id, turn_id)) return turn;
        return null;
    }

    /// True when a turn that overlapped `turn` reported editing the file.
    fn peerHinted(self: *const Ledger, turn: TrackedTurn, root: []const u8, path: []const u8) bool {
        for (turn.peers.items) |peer_id| {
            for (self.active.items) |peer| {
                if (std.mem.eql(u8, peer.turn_id, peer_id) and peer.touches(root) and peer.hinted(root, path)) return true;
            }
            for (self.retired.items) |peer| {
                if (std.mem.eql(u8, peer.turn_id, peer_id) and peer.touches(root) and peer.hinted(root, path)) return true;
            }
        }
        return false;
    }

    /// `turn` has evidence for the file: drop the unclear claims that
    /// already-ended overlapping peers made on it without evidence.
    fn dropPeerGuesses(self: *Ledger, turn: TrackedTurn, root: []const u8, path: []const u8) bool {
        var removed = false;
        for (self.retired.items) |peer| {
            if (!turn.hasPeer(peer.turn_id) or !peer.touches(root)) continue;
            if (std.mem.eql(u8, peer.thread_id, turn.thread_id) and std.mem.eql(u8, peer.workspace_id, turn.workspace_id)) continue;
            if (peer.hinted(root, path)) continue;
            const ended = peer.ended_ms orelse continue;
            var i: usize = 0;
            while (i < self.claims.items.len) {
                const claim = self.claims.items[i];
                const guess = claim.unclear and claim.at_ms == ended and
                    std.mem.eql(u8, claim.repo, root) and std.mem.eql(u8, claim.path, path) and
                    std.mem.eql(u8, claim.thread_id, peer.thread_id) and std.mem.eql(u8, claim.workspace_id, peer.workspace_id);
                if (guess) {
                    self.claims.items[i].deinit(self.allocator);
                    _ = self.claims.orderedRemove(i);
                    removed = true;
                    continue;
                }
                i += 1;
            }
        }
        return removed;
    }

    /// Drop ended turns no running turn overlaps any more.
    fn pruneRetired(self: *Ledger) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const id = self.retired.items[i].turn_id;
            const needed = for (self.active.items) |other| {
                if (other.hasPeer(id)) break true;
            } else false;
            if (needed) {
                i += 1;
                continue;
            }
            self.retired.items[i].deinit(self.allocator);
            _ = self.retired.orderedRemove(i);
        }
    }

    /// Drop claims for files in `root` that are no longer dirty. Returns true
    /// when anything was removed.
    pub fn pruneRepo(self: *Ledger, root: []const u8, snapshot: *const RepoSnapshot) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.claims.items.len) {
            const claim = self.claims.items[i];
            if (std.mem.eql(u8, claim.repo, root) and !snapshot.files.contains(claim.path)) {
                self.claims.items[i].deinit(self.allocator);
                _ = self.claims.orderedRemove(i);
                removed = true;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    /// Prune against a plain dirty-path set (used after commits and reviews).
    pub fn pruneRepoPaths(self: *Ledger, root: []const u8, dirty: []const StatusEntry) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.claims.items.len) {
            const claim = self.claims.items[i];
            if (std.mem.eql(u8, claim.repo, root) and !statusContains(dirty, claim.path)) {
                self.claims.items[i].deinit(self.allocator);
                _ = self.claims.orderedRemove(i);
                removed = true;
                continue;
            }
            i += 1;
        }
        if (removed) self.revision += 1;
        return removed;
    }

    fn upsertClaim(
        self: *Ledger,
        root: []const u8,
        path: []const u8,
        workspace_id: []const u8,
        thread_id: []const u8,
        hash: u64,
        unclear: bool,
        now_ms: i64,
    ) Error!bool {
        for (self.claims.items) |*claim| {
            if (!std.mem.eql(u8, claim.repo, root) or !std.mem.eql(u8, claim.path, path)) continue;
            if (!std.mem.eql(u8, claim.thread_id, thread_id) or !std.mem.eql(u8, claim.workspace_id, workspace_id)) continue;
            const was_unclear = claim.unclear;
            claim.hash = hash;
            claim.at_ms = now_ms;
            // A later confident edit settles an earlier unclear claim.
            claim.unclear = claim.unclear and unclear;
            return was_unclear != claim.unclear or true;
        }
        var claim: Claim = .{
            .repo = self.allocator.dupe(u8, root) catch return error.OutOfMemory,
            .path = undefined,
            .workspace_id = undefined,
            .thread_id = undefined,
            .hash = hash,
            .unclear = unclear,
            .at_ms = now_ms,
        };
        errdefer self.allocator.free(claim.repo);
        claim.path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer self.allocator.free(claim.path);
        claim.workspace_id = self.allocator.dupe(u8, workspace_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(claim.workspace_id);
        claim.thread_id = self.allocator.dupe(u8, thread_id) catch return error.OutOfMemory;
        errdefer self.allocator.free(claim.thread_id);
        self.claims.append(self.allocator, claim) catch return error.OutOfMemory;
        return true;
    }

    /// Settle unclear claims from stored transcript evidence (claims made
    /// before live tool hints existed): a chat whose transcript edited the
    /// file keeps it confidently; a claim is dropped when only another chat
    /// claiming the same file edited it. Returns true when claims changed.
    pub fn repairUnclear(self: *Ledger, evidence: []const ThreadEvidence) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.claims.items.len) {
            const claim = self.claims.items[i];
            if (!claim.unclear) {
                i += 1;
                continue;
            }
            const own = evidenceFor(evidence, claim.workspace_id, claim.thread_id);
            if (own) |item| if (hintMatches(item.hints, claim.repo, claim.repo, claim.path)) {
                self.claims.items[i].unclear = false;
                changed = true;
                i += 1;
                continue;
            };
            const theirs = for (self.claims.items) |other| {
                if (!std.mem.eql(u8, other.repo, claim.repo) or !std.mem.eql(u8, other.path, claim.path)) continue;
                if (!std.mem.eql(u8, other.workspace_id, claim.workspace_id)) continue;
                if (std.mem.eql(u8, other.thread_id, claim.thread_id)) continue;
                const item = evidenceFor(evidence, other.workspace_id, other.thread_id) orelse continue;
                if (hintMatches(item.hints, other.repo, other.repo, other.path)) break true;
            } else false;
            if (theirs) {
                self.claims.items[i].deinit(self.allocator);
                _ = self.claims.orderedRemove(i);
                changed = true;
                continue;
            }
            i += 1;
        }
        if (changed) self.revision += 1;
        return changed;
    }

    /// Chats with unclear claims, and every chat claiming a file one of them
    /// claims unclearly: the transcripts `repairUnclear` needs.
    pub fn repairCandidates(self: *const Ledger, arena: std.mem.Allocator) Error![]const ClaimView {
        var out: std.ArrayList(ClaimView) = .empty;
        for (self.claims.items) |claim| {
            const involved = claim.unclear or for (self.claims.items) |other| {
                if (other.unclear and std.mem.eql(u8, other.repo, claim.repo) and std.mem.eql(u8, other.path, claim.path)) break true;
            } else false;
            if (!involved) continue;
            const seen = for (out.items) |item| {
                if (std.mem.eql(u8, item.workspace_id, claim.workspace_id) and std.mem.eql(u8, item.thread_id, claim.thread_id)) break true;
            } else false;
            if (seen) continue;
            out.append(arena, .{
                .path = "",
                .workspace_id = arena.dupe(u8, claim.workspace_id) catch return error.OutOfMemory,
                .thread_id = arena.dupe(u8, claim.thread_id) catch return error.OutOfMemory,
                .unclear = claim.unclear,
            }) catch return error.OutOfMemory;
        }
        return out.items;
    }

    /// Distinct repository roots with claims in `workspace_id`.
    pub fn workspaceRepos(self: *const Ledger, arena: std.mem.Allocator, workspace_id: []const u8) Error![]const []const u8 {
        var roots: std.ArrayList([]const u8) = .empty;
        for (self.claims.items) |claim| {
            if (!std.mem.eql(u8, claim.workspace_id, workspace_id)) continue;
            var seen = false;
            for (roots.items) |root| if (std.mem.eql(u8, root, claim.repo)) {
                seen = true;
            };
            if (!seen) roots.append(arena, arena.dupe(u8, claim.repo) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
        return roots.items;
    }

    /// Distinct repository roots with claims by one chat.
    pub fn threadRepos(self: *const Ledger, arena: std.mem.Allocator, workspace_id: []const u8, thread_id: []const u8) Error![]const []const u8 {
        var roots: std.ArrayList([]const u8) = .empty;
        for (self.claims.items) |claim| {
            if (!std.mem.eql(u8, claim.workspace_id, workspace_id) or !std.mem.eql(u8, claim.thread_id, thread_id)) continue;
            var seen = false;
            for (roots.items) |root| if (std.mem.eql(u8, root, claim.repo)) {
                seen = true;
            };
            if (!seen) roots.append(arena, arena.dupe(u8, claim.repo) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
        return roots.items;
    }

    /// Copy of every claim on `root`, for lock-free review assembly.
    pub fn claimsForRepo(self: *const Ledger, arena: std.mem.Allocator, root: []const u8) Error![]ClaimView {
        var out: std.ArrayList(ClaimView) = .empty;
        for (self.claims.items) |claim| {
            if (!std.mem.eql(u8, claim.repo, root)) continue;
            out.append(arena, .{
                .path = arena.dupe(u8, claim.path) catch return error.OutOfMemory,
                .workspace_id = arena.dupe(u8, claim.workspace_id) catch return error.OutOfMemory,
                .thread_id = arena.dupe(u8, claim.thread_id) catch return error.OutOfMemory,
                .unclear = claim.unclear,
            }) catch return error.OutOfMemory;
        }
        return out.items;
    }

    // -- persistence -------------------------------------------------------

    const PersistedClaim = struct {
        repo: []const u8,
        path: []const u8,
        workspace_id: []const u8,
        thread_id: []const u8,
        hash: u64,
        unclear: bool,
        at_ms: i64,
    };
    const Persisted = struct {
        version: i64,
        claims: []const PersistedClaim,
    };

    /// Load claims from `path` and remember it for `save`. A missing or
    /// unreadable file starts empty; attribution is advisory state.
    pub fn load(self: *Ledger, path: []const u8) Error!void {
        if (self.persist_path) |old| self.allocator.free(old);
        self.persist_path = self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, self.allocator, .limited(32 * 1024 * 1024)) catch return;
        defer self.allocator.free(bytes);
        const parsed = std.json.parseFromSlice(Persisted, self.allocator, bytes, .{ .ignore_unknown_fields = true }) catch {
            log.warn("ignoring unreadable git change claims file", .{});
            return;
        };
        defer parsed.deinit();
        if (parsed.value.version != LEDGER_VERSION) return;
        for (parsed.value.claims) |claim| {
            _ = try self.upsertClaim(claim.repo, claim.path, claim.workspace_id, claim.thread_id, claim.hash, claim.unclear, claim.at_ms);
        }
    }

    /// Serialize claims; the caller writes the bytes with `writePersisted`
    /// outside its lock.
    pub fn encode(self: *const Ledger, allocator: std.mem.Allocator) Error![]u8 {
        const views = allocator.alloc(PersistedClaim, self.claims.items.len) catch return error.OutOfMemory;
        defer allocator.free(views);
        for (self.claims.items, views) |claim, *view| view.* = .{
            .repo = claim.repo,
            .path = claim.path,
            .workspace_id = claim.workspace_id,
            .thread_id = claim.thread_id,
            .hash = claim.hash,
            .unclear = claim.unclear,
            .at_ms = claim.at_ms,
        };
        return std.json.Stringify.valueAlloc(allocator, Persisted{ .version = LEDGER_VERSION, .claims = views }, .{}) catch error.OutOfMemory;
    }
};

pub const ClaimView = struct {
    path: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    unclear: bool,
};

/// Atomically replace the claims file with `bytes`.
pub fn writePersisted(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const temp = std.fmt.allocPrint(allocator, "{s}.tmp", .{path}) catch return;
    defer allocator.free(temp);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes }) catch |err| {
        log.warn("git change claims write failed err={s}", .{@errorName(err)});
        return;
    };
    std.Io.Dir.rename(std.Io.Dir.cwd(), temp, std.Io.Dir.cwd(), path, io) catch |err| {
        log.warn("git change claims replace failed err={s}", .{@errorName(err)});
        std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    };
}

fn statusContains(entries: []const StatusEntry, path: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return true;
    return false;
}

/// True when a provider-reported path names `repo_path` inside `root`.
fn hintMatches(hints: []const []const u8, cwd: []const u8, root: []const u8, repo_path: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (hints) |raw| {
        const hint = std.mem.trim(u8, raw, " \t\r\n");
        if (hint.len == 0) continue;
        const absolute = if (std.fs.path.isAbsolute(hint)) hint else blk: {
            var fba = std.heap.FixedBufferAllocator.init(&buffer);
            break :blk std.fs.path.resolve(fba.allocator(), &.{ cwd, hint }) catch continue;
        };
        if (absolute.len != root.len + 1 + repo_path.len) {
            // Allow hints already relative to the repository root.
            if (std.mem.eql(u8, hint, repo_path)) return true;
            continue;
        }
        if (!std.mem.startsWith(u8, absolute, root)) continue;
        if (absolute[root.len] != '/') continue;
        if (std.mem.eql(u8, absolute[root.len + 1 ..], repo_path)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Edit evidence from provider tool events

/// The parts of a provider tool-call event that can name edited files.
/// `kind` is the provider-neutral tool kind tag (`edit`, `subagent`, ...).
pub const ToolEvidence = struct {
    kind: ?[]const u8 = null,
    input: ?[]const u8 = null,
    locations: ?[]const u8 = null,
    /// Child-agent JSON lines (`{"type":"tool_use","kind":"edit","input":...}`).
    transcript: ?[]const u8 = null,
};

/// Input keys that name the file a file-editing tool writes.
const PATH_KEYS = [_][]const u8{ "file_path", "filePath", "notebook_path", "notebookPath", "path", "target_file", "targetFile", "filename" };
/// Input keys holding patch text (apply_patch style or unified diff).
const PATCH_KEYS = [_][]const u8{ "patchText", "patch", "patch_text", "input", "diff" };
const HINT_JSON_DEPTH: usize = 5;

fn isEditKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "edit") or std.mem.eql(u8, kind, "delete") or std.mem.eql(u8, kind, "move");
}

/// Append the file paths a tool event says it edits. Shell commands and
/// other tools yield nothing: their effects cannot be attributed. Paths are
/// absolute or relative to the turn's cwd, as the provider reported them.
pub fn collectToolHints(arena: std.mem.Allocator, evidence: ToolEvidence, out: *std.ArrayList([]const u8)) Error!void {
    const editing = if (evidence.kind) |kind| isEditKind(kind) else false;
    if (editing) {
        if (evidence.input) |input| try collectInputHints(arena, input, out);
        if (evidence.locations) |locations| {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, locations, .{}) catch null;
            if (parsed) |value| try collectJsonPaths(arena, value, &.{"path"}, &.{}, out, 0);
        }
    }
    if (evidence.transcript) |transcript| try collectTranscriptHints(arena, transcript, out);
}

/// Edited paths from child-agent transcript lines (Claude Task, OpenCode task).
pub fn collectTranscriptHints(arena: std.mem.Allocator, transcript: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    if (std.mem.indexOf(u8, transcript, "\"tool_use\"") == null) return;
    var lines = std.mem.splitScalar(u8, transcript, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] != '{' or std.mem.indexOf(u8, line, "\"tool_use\"") == null) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (value != .object) continue;
        const object = value.object;
        const entry_type = jsonText(object.get("type")) orelse continue;
        if (!std.mem.eql(u8, entry_type, "tool_use")) continue;
        const kind = jsonText(object.get("kind")) orelse continue;
        if (!isEditKind(kind)) continue;
        const input = jsonText(object.get("input")) orelse continue;
        try collectInputHints(arena, input, out);
    }
}

/// A tool's input: JSON arguments, raw apply_patch text, or Codex's
/// `path  +N / -M` file-change summary lines.
fn collectInputHints(arena: std.mem.Allocator, input: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return;
    if (trimmed[0] == '{' or trimmed[0] == '[') {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{})) |value| {
            try collectJsonPaths(arena, value, &PATH_KEYS, &PATCH_KEYS, out, 0);
            return;
        } else |_| {}
    }
    if (try collectPatchHints(arena, trimmed, out)) return;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (summaryLinePath(line)) |path| try appendHint(arena, out, path);
    }
}

/// `path  +12 / -3` -> `path`; null for any other line.
fn summaryLinePath(line: []const u8) ?[]const u8 {
    const marker = std.mem.lastIndexOf(u8, line, "  +") orelse return null;
    const counts = line[marker + 3 ..];
    const slash = std.mem.indexOf(u8, counts, " / -") orelse return null;
    for (counts[0..slash]) |c| if (!std.ascii.isDigit(c)) return null;
    for (counts[slash + 4 ..]) |c| if (!std.ascii.isDigit(c)) return null;
    if (slash == 0 or counts.len == slash + 4) return null;
    const path = std.mem.trim(u8, line[0..marker], " \t");
    return if (path.len == 0) null else path;
}

/// apply_patch (`*** Update File: p`) and unified-diff (`+++ b/p`) headers.
/// Returns true when the text looked like a patch.
fn collectPatchHints(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList([]const u8)) Error!bool {
    const prefixes = [_][]const u8{ "*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: ", "+++ b/", "--- a/" };
    var found = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        for (prefixes) |prefix| {
            if (!std.mem.startsWith(u8, line, prefix)) continue;
            found = true;
            try appendHint(arena, out, line[prefix.len..]);
            break;
        }
    }
    return found;
}

fn collectJsonPaths(
    arena: std.mem.Allocator,
    value: std.json.Value,
    path_keys: []const []const u8,
    patch_keys: []const []const u8,
    out: *std.ArrayList([]const u8),
    depth: usize,
) Error!void {
    if (depth > HINT_JSON_DEPTH) return;
    switch (value) {
        .array => |items| for (items.items) |item| try collectJsonPaths(arena, item, path_keys, patch_keys, out, depth + 1),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                switch (entry.value_ptr.*) {
                    .string => |text| {
                        if (keyIn(key, path_keys)) {
                            try appendHint(arena, out, text);
                        } else if (keyIn(key, patch_keys)) {
                            _ = try collectPatchHints(arena, text, out);
                        }
                    },
                    .array, .object => try collectJsonPaths(arena, entry.value_ptr.*, path_keys, patch_keys, out, depth + 1),
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn keyIn(key: []const u8, keys: []const []const u8) bool {
    for (keys) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn jsonText(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn appendHint(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) Error!void {
    const path = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (path.len == 0 or path.len > std.fs.max_path_bytes or std.mem.indexOfScalar(u8, path, '\n') != null) return;
    if (std.mem.eql(u8, path, "/dev/null")) return;
    for (out.items) |existing| if (std.mem.eql(u8, existing, path)) return;
    out.append(arena, path) catch return error.OutOfMemory;
}

const STORED_DIFF_MARKER = "VERDE_DIFF_V2\n";
const STORED_SECTIONS = [_][]const u8{ "Tool:\n", "Input:\n", "Output:\n", "Error:\n", "Locations:\n", "Transcript:\n" };

/// Edited paths a stored transcript row shows: diff rows (VERDE_DIFF_V2),
/// file-editing tool rows (`Input:` / `Locations:` sections) and subagent
/// rows (their `Transcript:` lines). `kind` is the stored tool kind tag.
pub fn collectStoredRowHints(arena: std.mem.Allocator, kind: ?[]const u8, body: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    if (std.mem.startsWith(u8, body, STORED_DIFF_MARKER)) return collectStoredDiffHints(arena, body[STORED_DIFF_MARKER.len..], out);
    const tag = kind orelse return;
    if (std.mem.eql(u8, tag, "subagent")) {
        return collectTranscriptHints(arena, storedSection(body, "Transcript:\n") orelse body, out);
    }
    if (!isEditKind(tag)) return;
    try collectToolHints(arena, .{
        .kind = tag,
        .input = storedSection(body, "Input:\n"),
        .locations = storedSection(body, "Locations:\n"),
    }, out);
}

/// `FILE\t<path len>\t<adds>\t<dels>\t<patch len>\n<path><patch>` records.
fn collectStoredDiffHints(arena: std.mem.Allocator, records: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    var pos: usize = 0;
    while (pos < records.len) {
        const nl = std.mem.indexOfScalarPos(u8, records, pos, '\n') orelse return;
        const header = records[pos..nl];
        if (!std.mem.startsWith(u8, header, "FILE\t")) return;
        var fields = std.mem.splitScalar(u8, header[5..], '\t');
        var sizes: [4]usize = undefined;
        for (&sizes) |*size| size.* = std.fmt.parseInt(usize, std.mem.trim(u8, fields.next() orelse return, " "), 10) catch return;
        var at = nl + 1;
        if (sizes[0] > records.len - at) return;
        try appendHint(arena, out, records[at..][0..sizes[0]]);
        at += sizes[0];
        if (sizes[3] > records.len - at) return;
        pos = at + sizes[3];
    }
}

/// Text of one `Name:\n...` section of a stored tool row, up to the next
/// known section.
fn storedSection(body: []const u8, name: []const u8) ?[]const u8 {
    const start = blk: {
        if (std.mem.startsWith(u8, body, name)) break :blk name.len;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, body, search, name)) |at| {
            if (at >= 2 and body[at - 1] == '\n' and body[at - 2] == '\n') break :blk at + name.len;
            search = at + 1;
        }
        return null;
    };
    var end = body.len;
    for (STORED_SECTIONS) |section| {
        if (std.mem.eql(u8, section, name)) continue;
        var search = start;
        while (std.mem.indexOfPos(u8, body, search, section)) |at| {
            if (at >= start + 2 and body[at - 1] == '\n' and body[at - 2] == '\n') {
                end = @min(end, at - 2);
                break;
            }
            search = at + 1;
        }
    }
    return body[start..end];
}

/// Edit evidence one chat's stored transcript holds, for `repairUnclear`.
pub const ThreadEvidence = struct {
    workspace_id: []const u8,
    thread_id: []const u8,
    hints: []const []const u8,
};

fn evidenceFor(evidence: []const ThreadEvidence, workspace_id: []const u8, thread_id: []const u8) ?ThreadEvidence {
    for (evidence) |item| {
        if (std.mem.eql(u8, item.workspace_id, workspace_id) and std.mem.eql(u8, item.thread_id, thread_id)) return item;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Reviews

pub const Ownership = enum { mine, shared, unclear, unassigned };

pub const FileStatus = enum { modified, added, deleted };

pub const Hunk = struct {
    /// Byte range of the hunk inside `ReviewFile.patch`.
    start: usize,
    end: usize,
};

pub const ReviewFile = struct {
    path: []const u8,
    status: FileStatus,
    ownership: Ownership,
    /// Other chats claiming this file (thread ids).
    other_threads: []const []const u8,
    additions: u32,
    deletions: u32,
    binary: bool,
    /// Frozen patch against HEAD; null when too large or beyond the file cap.
    patch: ?[]const u8,
    header_end: usize,
    hunks: []const Hunk,
};

pub const ReviewRepo = struct {
    root: []const u8,
    branch: ?[]const u8,
    head: ?[]const u8,
    status: RepoStatus = .{},
    files: []ReviewFile,
};

pub const Review = struct {
    arena_state: std.heap.ArenaAllocator,
    id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    created_ms: i64,
    repos: []ReviewRepo,
    /// Requests currently using this review without the daemon lock; the
    /// review is never evicted while non-zero.
    users: u32 = 0,
    /// A commit of this review is running.
    committing: bool = false,
    /// JSON of the successful commit result, replayed for repeated commits.
    /// Allocated from the review arena under the daemon's git mutex.
    committed_result: ?[]const u8 = null,

    pub fn deinit(self: *Review) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn findRepo(self: *const Review, root: []const u8) ?*const ReviewRepo {
        for (self.repos) |*repo| if (std.mem.eql(u8, repo.root, root)) return repo;
        return null;
    }
};

pub const ReviewInput = struct {
    id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    /// Repositories to inspect, each with a copy of its claims.
    repos: []const RepoClaims,
    now_ms: i64,
    /// Include files no chat claimed.
    include_unassigned: bool = true,
};

pub const RepoClaims = struct {
    root: []const u8,
    claims: []const ClaimView,
};

/// Build a review for `thread_id`: its own changed files plus unassigned ones,
/// each with a frozen patch against HEAD. Runs git; call with no locks held.
pub fn buildReview(gpa: std.mem.Allocator, input: ReviewInput) Error!Review {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();
    var git = try Git.init(arena);
    defer git.deinit();

    var repos: std.ArrayList(ReviewRepo) = .empty;
    for (input.repos) |repo_claims| {
        const root = repo_claims.root;
        const entries = (dirtyPaths(&git, root) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        }) orelse continue;
        const head = try headOid(&git, root);
        const status = try repoStatus(&git, root);
        const branch = status.branch;

        var files: std.ArrayList(ReviewFile) = .empty;
        for (entries) |entry| {
            var mine = false;
            var mine_unclear = false;
            var others: std.ArrayList([]const u8) = .empty;
            for (repo_claims.claims) |claim| {
                if (!std.mem.eql(u8, claim.path, entry.path)) continue;
                if (std.mem.eql(u8, claim.thread_id, input.thread_id) and std.mem.eql(u8, claim.workspace_id, input.workspace_id)) {
                    mine = true;
                    mine_unclear = claim.unclear;
                } else {
                    others.append(arena, claim.thread_id) catch return error.OutOfMemory;
                }
            }
            const ownership: Ownership = if (mine)
                (if (others.items.len > 0) .shared else if (mine_unclear) .unclear else .mine)
            else if (others.items.len == 0)
                .unassigned
            else
                continue;
            if (ownership == .unassigned and !input.include_unassigned) continue;
            files.append(arena, .{
                .path = entry.path,
                .status = fileStatus(entry),
                .ownership = ownership,
                .other_threads = others.items,
                .additions = 0,
                .deletions = 0,
                .binary = false,
                .patch = null,
                .header_end = 0,
                .hunks = &.{},
            }) catch return error.OutOfMemory;
        }
        if (files.items.len == 0) continue;
        try freezePatches(&git, arena, root, head, entries, files.items);
        repos.append(arena, .{
            .root = arena.dupe(u8, root) catch return error.OutOfMemory,
            .branch = branch,
            .head = head,
            .status = status,
            .files = files.items,
        }) catch return error.OutOfMemory;
    }
    return .{
        .arena_state = arena_state,
        .id = arena.dupe(u8, input.id) catch return error.OutOfMemory,
        .workspace_id = arena.dupe(u8, input.workspace_id) catch return error.OutOfMemory,
        .thread_id = arena.dupe(u8, input.thread_id) catch return error.OutOfMemory,
        .created_ms = input.now_ms,
        .repos = repos.items,
    };
}

fn fileStatus(entry: StatusEntry) FileStatus {
    if (entry.untracked() or entry.x == 'A') return .added;
    if (entry.x == 'D' or entry.y == 'D') return .deleted;
    return .modified;
}

/// Compute each file's patch against HEAD in a scratch index so the user's
/// real staging never changes what the review shows.
fn freezePatches(
    git: *Git,
    arena: std.mem.Allocator,
    root: []const u8,
    head: ?[]const u8,
    entries: []const StatusEntry,
    files: []ReviewFile,
) Error!void {
    const scratch = try scratchPath(git, arena, root, "review.index");
    defer deleteQuiet(arena, scratch);
    const read_tree = if (head) |oid|
        try git.run(root, &.{ "read-tree", oid }, .{ .index_file = scratch, .read_only = false })
    else
        try git.run(root, &.{ "read-tree", "--empty" }, .{ .index_file = scratch, .read_only = false });
    if (!read_tree.ok()) return error.GitUnavailable;

    // Intent-to-add untracked files so they diff as new files.
    var untracked: std.ArrayList([]const u8) = .empty;
    untracked.appendSlice(arena, &.{ "add", "-N", "--" }) catch return error.OutOfMemory;
    var untracked_count: usize = 0;
    for (files, 0..) |file, i| {
        if (i >= MAX_REVIEW_PATCH_FILES) break;
        for (entries) |entry| if (std.mem.eql(u8, entry.path, file.path) and entry.untracked()) {
            untracked.append(arena, file.path) catch return error.OutOfMemory;
            untracked_count += 1;
        };
    }
    if (untracked_count > 0) {
        _ = try git.run(root, untracked.items, .{ .index_file = scratch, .read_only = false });
    }

    var preview_budget: usize = MAX_PREVIEW_BYTES_TOTAL;
    for (files, 0..) |*file, i| {
        if (i >= MAX_REVIEW_PATCH_FILES) break;
        const result = try git.run(root, &.{ "diff", "--no-color", "--no-ext-diff", "--no-renames", "--binary", "--full-index", "--", file.path }, .{ .index_file = scratch });
        if (!result.ok()) continue;
        const patch = result.stdout;
        if (patch.len == 0 or patch.len > MAX_FROZEN_PATCH_BYTES) continue;
        file.patch = patch;
        parsePatch(arena, file) catch return error.OutOfMemory;
        if (patch.len > MAX_PREVIEW_BYTES_PER_FILE or patch.len > preview_budget) {
            // Too large to preview: keep the frozen patch for commit, no hunks.
            file.hunks = &.{};
        } else {
            preview_budget -= patch.len;
        }
    }
}

fn parsePatch(arena: std.mem.Allocator, file: *ReviewFile) !void {
    const patch = file.patch orelse return;
    if (std.mem.indexOf(u8, patch, "\nGIT binary patch\n") != null or std.mem.indexOf(u8, patch, "\nBinary files ") != null) {
        file.binary = true;
        file.header_end = patch.len;
        return;
    }
    var hunks: std.ArrayList(Hunk) = .empty;
    var header_end: ?usize = null;
    var line_start: usize = 0;
    var additions: u32 = 0;
    var deletions: u32 = 0;
    while (line_start < patch.len) {
        const newline = std.mem.indexOfScalarPos(u8, patch, line_start, '\n');
        const line_end = if (newline) |n| n + 1 else patch.len;
        const line = patch[line_start..line_end];
        if (std.mem.startsWith(u8, line, "@@ ")) {
            if (header_end == null) header_end = line_start;
            if (hunks.items.len > 0) hunks.items[hunks.items.len - 1].end = line_start;
            try hunks.append(arena, .{ .start = line_start, .end = patch.len });
        } else if (header_end != null) {
            if (line.len > 0 and line[0] == '+') additions += 1;
            if (line.len > 0 and line[0] == '-') deletions += 1;
        }
        line_start = line_end;
    }
    file.header_end = header_end orelse patch.len;
    file.hunks = hunks.items;
    file.additions = additions;
    file.deletions = deletions;
}

pub fn hunkHeader(file: *const ReviewFile, hunk: Hunk) []const u8 {
    const patch = file.patch orelse return "";
    const text = patch[hunk.start..hunk.end];
    const newline = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..newline];
}

pub fn hunkText(file: *const ReviewFile, hunk: Hunk) []const u8 {
    const patch = file.patch orelse return "";
    return patch[hunk.start..hunk.end];
}

pub fn fileHeaderText(file: *const ReviewFile) []const u8 {
    const patch = file.patch orelse return "";
    return patch[0..file.header_end];
}

/// Total hunk text a review response may carry. Files are admitted in
/// response order; the first file that does not fit exhausts the budget so
/// clients never see a gap followed by later previews.
pub const DEFAULT_REVIEW_HUNK_BUDGET: usize = 512 * 1024;
pub const MAX_REVIEW_HUNK_BUDGET: usize = MAX_PREVIEW_BYTES_TOTAL;

pub const PreviewBudget = struct {
    remaining: usize,
    exhausted: bool = false,

    pub fn init(requested: ?u64) PreviewBudget {
        const wanted = requested orelse DEFAULT_REVIEW_HUNK_BUDGET;
        return .{ .remaining = @intCast(@min(wanted, MAX_REVIEW_HUNK_BUDGET)) };
    }

    /// True when `file`'s hunks may be sent. Files without hunks cost nothing.
    pub fn admit(self: *PreviewBudget, file: *const ReviewFile) bool {
        if (file.hunks.len == 0) return false;
        if (self.exhausted) return false;
        var cost: usize = 0;
        for (file.hunks) |hunk| cost += hunk.end - hunk.start;
        if (cost > self.remaining) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= cost;
        return true;
    }
};

/// True when the file supports choosing individual hunks.
pub fn hunkSelectable(file: *const ReviewFile) bool {
    return file.patch != null and !file.binary and file.status == .modified and file.hunks.len > 1;
}

/// Bounded LRU of open reviews.
pub const Reviews = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*Review) = .empty,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Reviews {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Reviews) void {
        for (self.items.items) |review| {
            review.deinit();
            self.allocator.destroy(review);
        }
        self.items.deinit(self.allocator);
    }

    pub fn nextId(self: *Reviews, allocator: std.mem.Allocator, now_ms: i64) Error![]u8 {
        const id = std.fmt.allocPrint(allocator, "review-{d}-{d}", .{ now_ms, self.next_id }) catch return error.OutOfMemory;
        self.next_id += 1;
        return id;
    }

    /// Take ownership of `review`, evicting expired and oldest entries that
    /// no request is using.
    pub fn put(self: *Reviews, review: Review, now_ms: i64) Error!*Review {
        var i: usize = 0;
        while (i < self.items.items.len) {
            const existing = self.items.items[i];
            if (existing.users == 0 and (now_ms - existing.created_ms > REVIEW_TTL_MS or self.items.items.len >= MAX_REVIEWS)) {
                existing.deinit();
                self.allocator.destroy(existing);
                _ = self.items.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        const owned = self.allocator.create(Review) catch return error.OutOfMemory;
        owned.* = review;
        self.items.append(self.allocator, owned) catch {
            self.allocator.destroy(owned);
            return error.OutOfMemory;
        };
        return owned;
    }

    pub fn find(self: *Reviews, id: []const u8) ?*Review {
        for (self.items.items) |review| if (std.mem.eql(u8, review.id, id)) return review;
        return null;
    }

    /// Pin a review so it can be read without holding the lock. Reviews are
    /// immutable after `put` except for the commit bookkeeping fields, which
    /// only change under the caller's lock. Pair with `release`.
    pub fn acquire(self: *Reviews, id: []const u8) ?*Review {
        const review = self.find(id) orelse return null;
        review.users += 1;
        return review;
    }

    pub fn release(self: *Reviews, review: *Review) void {
        _ = self;
        std.debug.assert(review.users > 0);
        review.users -= 1;
    }
};

// ---------------------------------------------------------------------------
// Commit

pub const FileSelection = struct {
    path: []const u8,
    /// Null selects the whole file.
    hunks: ?[]const u32 = null,
};

pub const RepoSelection = struct {
    root: []const u8,
    files: []const FileSelection,
};

pub const PushStatus = enum { not_requested, pushed, rejected, failed };

pub const RepoCommitResult = struct {
    root: []const u8,
    commit: []const u8,
    subject: []const u8,
    files: usize,
    /// Real index could not be moved forward exactly; paths were reset.
    index_reset: bool = false,
    /// Branch the commit landed on; null for a detached HEAD.
    branch: ?[]const u8 = null,
    branch_created: bool = false,
    push: PushStatus = .not_requested,
    push_message: ?[]const u8 = null,
    committed_paths: []const []const u8,
};

/// Build the patch for one repository's selection from the frozen review.
/// Whole files without a frozen patch are returned in `add_paths`.
fn selectionPatch(
    arena: std.mem.Allocator,
    repo: *const ReviewRepo,
    selection: RepoSelection,
    add_paths: *std.ArrayList([]const u8),
    committed_paths: *std.ArrayList([]const u8),
) Error![]const u8 {
    var patch: std.ArrayList(u8) = .empty;
    for (selection.files) |chosen| {
        const file = findFile(repo, chosen.path) orelse return error.InvalidSelection;
        committed_paths.append(arena, file.path) catch return error.OutOfMemory;
        const frozen = file.patch orelse {
            if (chosen.hunks != null) return error.InvalidSelection;
            add_paths.append(arena, file.path) catch return error.OutOfMemory;
            continue;
        };
        const indices = chosen.hunks orelse {
            patch.appendSlice(arena, frozen) catch return error.OutOfMemory;
            continue;
        };
        if (indices.len == 0) return error.InvalidSelection;
        if (!hunkSelectable(file)) {
            if (indices.len != file.hunks.len) return error.InvalidSelection;
            patch.appendSlice(arena, frozen) catch return error.OutOfMemory;
            continue;
        }
        patch.appendSlice(arena, fileHeaderText(file)) catch return error.OutOfMemory;
        var previous: ?u32 = null;
        for (indices) |index| {
            if (index >= file.hunks.len) return error.InvalidSelection;
            if (previous) |prior| if (index <= prior) return error.InvalidSelection;
            previous = index;
            patch.appendSlice(arena, hunkText(file, file.hunks[index])) catch return error.OutOfMemory;
        }
    }
    return patch.items;
}

pub fn findFile(repo: *const ReviewRepo, path: []const u8) ?*const ReviewFile {
    for (repo.files) |*file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

pub const CommitInput = struct {
    review: *const Review,
    selection: RepoSelection,
    message: []const u8,
    push: bool,
    nonce: u64,
    /// Sanitized preferred name (see `sanitizeFeatureBranchName`); when set
    /// the commit lands on a new, uniquely named branch created at HEAD.
    new_branch: ?[]const u8 = null,
};

/// Commit the selected hunks of one repository. Runs git; call unlocked.
pub fn commitRepo(arena: std.mem.Allocator, input: CommitInput) Error!RepoCommitResult {
    const repo = input.review.findRepo(input.selection.root) orelse return error.InvalidSelection;
    if (input.selection.files.len == 0) return error.NothingSelected;
    const message = std.mem.trim(u8, input.message, " \t\r\n");
    if (message.len == 0) return error.InvalidSelection;
    var git = try Git.init(arena);
    defer git.deinit();
    const root = repo.root;

    var add_paths: std.ArrayList([]const u8) = .empty;
    var committed_paths: std.ArrayList([]const u8) = .empty;
    const patch = try selectionPatch(arena, repo, input.selection, &add_paths, &committed_paths);

    const head = try headOid(&git, root);
    // The frozen patches are against the review's HEAD; a moved HEAD is fine
    // only while the patch still applies, which `git apply` verifies below.

    const tag = std.fmt.allocPrint(arena, "{d}", .{input.nonce}) catch return error.OutOfMemory;
    const index_path = try scratchPath(&git, arena, root, std.fmt.allocPrint(arena, "commit-{s}.index", .{tag}) catch return error.OutOfMemory);
    defer deleteQuiet(arena, index_path);
    const patch_path = try scratchPath(&git, arena, root, std.fmt.allocPrint(arena, "commit-{s}.patch", .{tag}) catch return error.OutOfMemory);
    defer deleteQuiet(arena, patch_path);
    const message_path = try scratchPath(&git, arena, root, std.fmt.allocPrint(arena, "commit-{s}.msg", .{tag}) catch return error.OutOfMemory);
    defer deleteQuiet(arena, message_path);

    const scratch_index = Git.RunOptions{ .index_file = index_path, .read_only = false };
    const read_tree = if (head) |oid|
        try git.run(root, &.{ "read-tree", oid }, scratch_index)
    else
        try git.run(root, &.{ "read-tree", "--empty" }, scratch_index);
    if (!read_tree.ok()) return error.CommitFailed;

    if (patch.len > 0) {
        try writeScratch(arena, patch_path, patch);
        const applied = try git.run(root, &.{ "apply", "--cached", "--whitespace=nowarn", patch_path }, scratch_index);
        if (!applied.ok()) {
            log.warn("git apply --cached failed: {s}", .{firstLine(applied.stderr)});
            return error.ChangedSinceReview;
        }
    }
    if (add_paths.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(arena, &.{ "add", "-A", "--" }) catch return error.OutOfMemory;
        argv.appendSlice(arena, add_paths.items) catch return error.OutOfMemory;
        const added = try git.run(root, argv.items, scratch_index);
        if (!added.ok()) return error.CommitFailed;
    }

    const tree = git.output(root, &.{"write-tree"}, scratch_index) catch return error.CommitFailed;
    if (head) |oid| {
        const head_tree = git.output(root, &.{ "rev-parse", std.fmt.allocPrint(arena, "{s}^{{tree}}", .{oid}) catch return error.OutOfMemory }, .{}) catch return error.CommitFailed;
        if (std.mem.eql(u8, head_tree, tree)) return error.NothingToCommit;
    }

    var normalized_message = std.ArrayList(u8).empty;
    normalized_message.appendSlice(arena, message) catch return error.OutOfMemory;
    normalized_message.append(arena, '\n') catch return error.OutOfMemory;
    try writeScratch(arena, message_path, normalized_message.items);
    const commit_result = if (head) |oid|
        try git.run(root, &.{ "commit-tree", tree, "-p", oid, "-F", message_path }, .{ .read_only = false })
    else
        try git.run(root, &.{ "commit-tree", tree, "-F", message_path }, .{ .read_only = false });
    if (!commit_result.ok()) {
        if (std.mem.indexOf(u8, commit_result.stderr, "Please tell me who you are") != null or
            std.mem.indexOf(u8, commit_result.stderr, "user.email") != null)
        {
            return error.MissingIdentity;
        }
        log.warn("git commit-tree failed: {s}", .{firstLine(commit_result.stderr)});
        return error.CommitFailed;
    }
    const commit = std.mem.trim(u8, commit_result.stdout, " \t\r\n");
    const subject = firstLine(message);

    // The commit object exists but nothing references it yet. Only now switch
    // to the new branch, so every earlier failure leaves the repository as-is.
    const original_branch = try currentBranch(&git, root);
    var created_branch: ?[]const u8 = null;
    if (input.new_branch) |base| {
        created_branch = try createAndSwitchBranch(&git, arena, root, base, head);
    }

    const reflog = std.fmt.allocPrint(arena, "commit (verde): {s}", .{subject}) catch return error.OutOfMemory;
    const update = if (head) |oid|
        try git.run(root, &.{ "update-ref", "-m", reflog, "HEAD", commit, oid }, .{ .read_only = false })
    else
        try git.run(root, &.{ "update-ref", "-m", reflog, "HEAD", commit }, .{ .read_only = false });
    if (!update.ok()) {
        if (created_branch) |name| try restoreBranch(&git, arena, root, name, original_branch, head);
        return error.HeadMoved;
    }

    // Move the real index forward by exactly what was committed so anything
    // else staged there survives. Fall back to resetting just these paths.
    var index_reset = false;
    var index_ok = true;
    if (patch.len > 0) {
        const synced = try git.run(root, &.{ "apply", "--cached", "--whitespace=nowarn", patch_path }, .{ .read_only = false });
        index_ok = synced.ok();
    }
    if (index_ok and add_paths.items.len > 0) {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(arena, &.{ "reset", "-q", "--" }) catch return error.OutOfMemory;
        argv.appendSlice(arena, add_paths.items) catch return error.OutOfMemory;
        _ = try git.run(root, argv.items, .{ .read_only = false });
    }
    if (!index_ok) {
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(arena, &.{ "reset", "-q", "--" }) catch return error.OutOfMemory;
        argv.appendSlice(arena, committed_paths.items) catch return error.OutOfMemory;
        _ = try git.run(root, argv.items, .{ .read_only = false });
        index_reset = true;
    }

    var result: RepoCommitResult = .{
        .root = root,
        .commit = commit,
        .subject = subject,
        .files = committed_paths.items.len,
        .index_reset = index_reset,
        .branch = created_branch orelse original_branch,
        .branch_created = created_branch != null,
        .committed_paths = committed_paths.items,
    };
    if (input.push) {
        const pushed = try push(&git, root);
        result.push = pushed.status;
        result.push_message = pushed.message;
    }
    return result;
}

pub const PushOutcome = struct {
    status: PushStatus,
    message: ?[]const u8,
    /// Filled when `status` is `pushed`.
    pushed: ?PushedFacts = null,
};

/// What a successful push published, for result toasts.
pub const PushedFacts = struct {
    /// Commits the upstream (or, for a first publish, no remote) had not seen.
    commits: u32 = 0,
    /// Short sha and subject of the pushed HEAD.
    head: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    /// e.g. `origin/main`.
    upstream: ?[]const u8 = null,
    /// Web link to the pushed HEAD (`commitWebUrl`).
    remote_url: ?[]const u8 = null,
};

/// Commits a push of HEAD would publish: ahead of the upstream, or not on
/// any remote-tracking ref when there is no upstream yet.
fn unpushedCount(git: *Git, root: []const u8, has_upstream: bool) Error!u32 {
    const result = if (has_upstream)
        try git.run(root, &.{ "rev-list", "--count", "@{u}..HEAD" }, .{})
    else
        try git.run(root, &.{ "rev-list", "--count", "HEAD", "--not", "--remotes" }, .{});
    if (!result.ok()) return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, result.stdout, " \t\r\n"), 10) catch 0;
}

fn pushedFacts(git: *Git, root: []const u8, commits: u32) Error!PushedFacts {
    var facts: PushedFacts = .{ .commits = commits, .upstream = try upstreamName(git, root) };
    const oid = (try headOid(git, root)) orelse return facts;
    facts.head = oid[0..@min(oid.len, 7)];
    const subject = try git.run(root, &.{ "log", "-1", "--format=%s", oid }, .{});
    if (subject.ok()) {
        const line = firstLine(subject.stdout);
        if (line.len > 0) facts.subject = line;
    }
    facts.remote_url = try commitWebUrlFor(git, root, oid);
    return facts;
}

/// Create `refs/heads/<unique name>` at `head` and point HEAD at it without
/// touching the index or working tree (they already match `head`). Returns
/// the branch name. On failure nothing is left behind.
fn createAndSwitchBranch(git: *Git, arena: std.mem.Allocator, root: []const u8, base: []const u8, head: ?[]const u8) Error![]const u8 {
    const existing = try localBranches(git, root);
    const name = try resolveUniqueBranchName(arena, existing, base);
    const checked = try git.run(root, &.{ "check-ref-format", "--branch", name }, .{});
    if (!checked.ok()) return error.BranchCreateFailed;
    const ref = std.fmt.allocPrint(arena, "refs/heads/{s}", .{name}) catch return error.OutOfMemory;
    // The frozen patch was applied against `head`; refuse if HEAD moved since.
    const current = try headOid(git, root);
    if (!optionalEql(current, head)) return error.HeadMoved;
    if (head) |oid| {
        // Empty old value: create only if the ref does not exist yet.
        const created = try git.run(root, &.{ "update-ref", "-m", "branch: Created from HEAD (verde)", ref, oid, "" }, .{ .read_only = false });
        if (!created.ok()) {
            log.warn("git branch create failed: {s}", .{firstLine(created.stderr)});
            return error.BranchCreateFailed;
        }
    }
    const reason = std.fmt.allocPrint(arena, "checkout: moving to {s} (verde)", .{name}) catch return error.OutOfMemory;
    const switched = try git.run(root, &.{ "symbolic-ref", "-m", reason, "HEAD", ref }, .{ .read_only = false });
    if (!switched.ok()) {
        log.warn("git branch switch failed: {s}", .{firstLine(switched.stderr)});
        if (head) |oid| _ = try git.run(root, &.{ "update-ref", "-d", ref, oid }, .{ .read_only = false });
        return error.BranchCreateFailed;
    }
    return name;
}

/// Undo `createAndSwitchBranch` after the commit could not be recorded.
fn restoreBranch(git: *Git, arena: std.mem.Allocator, root: []const u8, created: []const u8, original_branch: ?[]const u8, head: ?[]const u8) Error!void {
    if (original_branch) |name| {
        const ref = std.fmt.allocPrint(arena, "refs/heads/{s}", .{name}) catch return error.OutOfMemory;
        _ = try git.run(root, &.{ "symbolic-ref", "HEAD", ref }, .{ .read_only = false });
    } else if (head) |oid| {
        _ = try git.run(root, &.{ "update-ref", "--no-deref", "HEAD", oid }, .{ .read_only = false });
    }
    const created_ref = std.fmt.allocPrint(arena, "refs/heads/{s}", .{created}) catch return error.OutOfMemory;
    if (head) |oid| _ = try git.run(root, &.{ "update-ref", "-d", created_ref, oid }, .{ .read_only = false });
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Local branch names (without `refs/heads/`).
pub fn localBranches(git: *Git, root: []const u8) Error![]const []const u8 {
    const result = try git.run(root, &.{ "for-each-ref", "--format=%(refname)", "refs/heads/" }, .{});
    if (!result.ok()) return error.GitUnavailable;
    var names: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "refs/heads/")) continue;
        names.append(git.arena, trimmed["refs/heads/".len..]) catch return error.OutOfMemory;
    }
    return names.items;
}

/// Remote used to publish a branch with no upstream: `origin`, else the first.
fn publishRemote(git: *Git, root: []const u8) Error!?[]const u8 {
    const result = try git.run(root, &.{"remote"}, .{});
    if (!result.ok()) return null;
    var first: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const name = std.mem.trim(u8, line, " \t\r");
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, "origin")) return name;
        if (first == null) first = name;
    }
    return first;
}

fn upstreamName(git: *Git, root: []const u8) Error!?[]const u8 {
    const result = try git.run(root, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, .{});
    if (!result.ok()) return null;
    const name = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (name.len == 0) null else name;
}

/// Push the current branch, publishing it with `-u` when it has no upstream.
pub fn push(git: *Git, root: []const u8) Error!PushOutcome {
    var argv: []const []const u8 = &.{"push"};
    const has_upstream = try upstreamName(git, root) != null;
    const commits = try unpushedCount(git, root, has_upstream);
    if (!has_upstream) {
        if (try currentBranch(git, root) == null) return .{ .status = .failed, .message = "HEAD is detached; switch to a branch before pushing." };
        const remote = (try publishRemote(git, root)) orelse return .{ .status = .failed, .message = "This repository has no remote to push to." };
        const args = git.arena.alloc([]const u8, 4) catch return error.OutOfMemory;
        args[0] = "push";
        args[1] = "-u";
        args[2] = remote;
        args[3] = "HEAD";
        argv = args;
    }
    const result = git.run(root, argv, .{ .read_only = false, .timeout_ms = PUSH_TIMEOUT_MS }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = .failed, .message = "git push could not run" },
    };
    if (result.ok()) return .{ .status = .pushed, .message = null, .pushed = try pushedFacts(git, root, commits) };
    const stderr = result.stderr;
    if (std.mem.indexOf(u8, stderr, "[rejected]") != null or
        std.mem.indexOf(u8, stderr, "non-fast-forward") != null or
        std.mem.indexOf(u8, stderr, "fetch first") != null)
    {
        return .{ .status = .rejected, .message = "The remote has commits you don't have yet." };
    }
    if (std.mem.indexOf(u8, stderr, "has no upstream branch") != null) {
        return .{ .status = .failed, .message = "This branch has no upstream to push to." };
    }
    return .{ .status = .failed, .message = lastNonEmptyLine(stderr) orelse "git push failed" };
}

/// Push `root`'s current branch (see `push`). Never touches the working tree.
pub fn pushRepo(arena: std.mem.Allocator, root: []const u8) Error!PushOutcome {
    var git = try Git.init(arena);
    defer git.deinit();
    return push(&git, root);
}

/// `git pull --rebase --autostash` then push. Refused while chats are running
/// in the repository because autostash rewrites the shared working tree.
pub fn pullAndPush(arena: std.mem.Allocator, root: []const u8) Error!PushOutcome {
    var git = try Git.init(arena);
    defer git.deinit();
    const pulled = try git.run(root, &.{ "pull", "--rebase", "--autostash" }, .{ .read_only = false, .timeout_ms = PUSH_TIMEOUT_MS });
    if (!pulled.ok()) {
        return .{ .status = .failed, .message = lastNonEmptyLine(pulled.stderr) orelse "git pull --rebase failed" };
    }
    return push(&git, root);
}

pub const LineStat = struct {
    additions: u32 = 0,
    deletions: u32 = 0,
};

/// Added/deleted line counts per dirty path against HEAD. Untracked files
/// count their lines as additions (bounded read).
pub fn lineStats(git: *Git, root: []const u8, entries: []const StatusEntry) Error!std.StringHashMapUnmanaged(LineStat) {
    const arena = git.arena;
    var stats: std.StringHashMapUnmanaged(LineStat) = .empty;
    if (try headOid(git, root)) |_| {
        const result = try git.run(root, &.{ "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "HEAD" }, .{});
        if (result.ok()) {
            var records = std.mem.splitScalar(u8, result.stdout, 0);
            while (records.next()) |record| {
                var fields = std.mem.splitScalar(u8, record, '\t');
                const added = fields.next() orelse continue;
                const deleted = fields.next() orelse continue;
                const path = fields.rest();
                if (path.len == 0) continue;
                stats.put(arena, path, .{
                    .additions = std.fmt.parseInt(u32, added, 10) catch 0,
                    .deletions = std.fmt.parseInt(u32, deleted, 10) catch 0,
                }) catch return error.OutOfMemory;
            }
        }
    }
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    // Untracked line counts are cosmetic; bound the total bytes read.
    var budget: usize = 32 * 1024 * 1024;
    for (entries) |entry| {
        if (!entry.untracked() or stats.contains(entry.path)) continue;
        if (budget == 0) break;
        const absolute = std.fs.path.join(arena, &.{ root, entry.path }) catch return error.OutOfMemory;
        const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), absolute, arena, .limited(@min(budget, 1024 * 1024))) catch continue;
        budget -= bytes.len;
        var lines: u32 = @intCast(std.mem.count(u8, bytes, "\n"));
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') lines += 1;
        if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null) lines = 0;
        stats.put(arena, entry.path, .{ .additions = lines }) catch return error.OutOfMemory;
    }
    return stats;
}

/// Recent commit subjects so generated messages match the repository's style.
pub fn recentSubjects(arena: std.mem.Allocator, root: []const u8, count: usize) Error![]const u8 {
    var git = try Git.init(arena);
    defer git.deinit();
    const limit = std.fmt.allocPrint(arena, "-{d}", .{count}) catch return error.OutOfMemory;
    const result = git.run(root, &.{ "log", limit, "--format=%s" }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return "",
    };
    if (!result.ok()) return "";
    return result.stdout;
}

// ---------------------------------------------------------------------------
// Helpers

fn scratchPath(git: *Git, arena: std.mem.Allocator, root: []const u8, name: []const u8) Error![]const u8 {
    const git_dir = git.output(root, &.{ "rev-parse", "--absolute-git-dir" }, .{}) catch return error.NotARepository;
    return std.fmt.allocPrint(arena, "{s}/verde-{s}", .{ git_dir, name }) catch error.OutOfMemory;
}

fn writeScratch(arena: std.mem.Allocator, path: []const u8, bytes: []const u8) Error!void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = path, .data = bytes }) catch return error.CommitFailed;
}

fn deleteQuiet(arena: std.mem.Allocator, path: []const u8) void {
    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().deleteFile(threaded.io(), path) catch {};
}

pub fn firstLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t\r");
}

fn lastNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Remote commit links

/// Browser URL of `sha` on the remote at `remote_url`
/// (`https://host/owner/repo/commit/<sha>`; GitHub, GitLab and Gitea all
/// accept that path). Handles `git@host:owner/repo(.git)`,
/// `ssh://[user@]host[:port]/owner/repo` and `http(s)://[user@]host/owner/repo(.git)`.
/// Null for local paths or anything else it cannot map.
pub fn commitWebUrl(arena: std.mem.Allocator, remote_url: []const u8, sha: []const u8) Error!?[]const u8 {
    const url = std.mem.trim(u8, remote_url, " \t\r\n");
    if (url.len == 0 or sha.len == 0) return null;
    for (sha) |c| if (!std.ascii.isHex(c)) return null;
    var host: []const u8 = undefined;
    var path: []const u8 = undefined;
    var keep_port = false;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        const scheme = url[0..scheme_end];
        if (std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "http")) {
            keep_port = true;
        } else if (!std.ascii.eqlIgnoreCase(scheme, "ssh") and !std.ascii.eqlIgnoreCase(scheme, "git") and !std.ascii.eqlIgnoreCase(scheme, "git+ssh")) {
            return null;
        }
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        host = rest[0..slash];
        path = rest[slash + 1 ..];
    } else {
        // scp-like `[user@]host:owner/repo`; a `/` before the `:` means a path.
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        host = url[0..colon];
        path = url[colon + 1 ..];
    }
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (!keep_port) {
        if (std.mem.indexOfScalar(u8, host, ':')) |port| host = host[0..port];
    }
    if (host.len == 0) return null;
    for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == ':')) return null;
    path = std.mem.trim(u8, path, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    path = std.mem.trimEnd(u8, path, "/");
    // owner/repo at least (GitLab subgroups add more segments).
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0 or slash + 1 >= path.len) return null;
    for (path) |c| if (c <= ' ' or c == '?' or c == '#') return null;
    return std.fmt.allocPrint(arena, "https://{s}/{s}/commit/{s}", .{ host, path, sha }) catch return error.OutOfMemory;
}

/// Fetch URL of the remote a push from `root` goes to: the branch's
/// configured remote, else `origin`, else the first remote.
pub fn pushRemoteUrl(git: *Git, root: []const u8) Error!?[]const u8 {
    var remote: ?[]const u8 = null;
    if (try currentBranch(git, root)) |branch| {
        const key = std.fmt.allocPrint(git.arena, "branch.{s}.remote", .{branch}) catch return error.OutOfMemory;
        const configured = try git.run(root, &.{ "config", "--get", key }, .{});
        if (configured.ok()) {
            const name = std.mem.trim(u8, configured.stdout, " \t\r\n");
            if (name.len > 0 and !std.mem.eql(u8, name, ".")) remote = name;
        }
    }
    const name = remote orelse (try publishRemote(git, root)) orelse return null;
    const result = try git.run(root, &.{ "remote", "get-url", name }, .{});
    if (!result.ok()) return null;
    const url = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (url.len == 0) null else url;
}

/// Whether `root` has any remote configured (`local` commit rows when not).
pub fn hasRemote(git: *Git, root: []const u8) Error!bool {
    return (try publishRemote(git, root)) != null;
}

/// Web link for a commit in `root`, or null when the remote is not a
/// recognisable forge URL.
pub fn commitWebUrlFor(git: *Git, root: []const u8, sha: []const u8) Error!?[]const u8 {
    const remote = (try pushRemoteUrl(git, root)) orelse return null;
    return commitWebUrl(git.arena, remote, sha);
}

/// Full id of a (short) commit id, or null when `root` has no such commit.
pub fn resolveCommit(git: *Git, root: []const u8, short: []const u8) Error!?[]const u8 {
    for (short) |c| if (!std.ascii.isHex(c)) return null;
    const spec = std.fmt.allocPrint(git.arena, "{s}^{{commit}}", .{short}) catch return error.OutOfMemory;
    const result = try git.run(root, &.{ "rev-parse", "-q", "--verify", spec }, .{});
    if (!result.ok()) return null;
    const oid = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (oid.len == 0) null else oid;
}

/// `commit` is `ref` (e.g. `@{u}`) or one of its ancestors; false when
/// `ref` does not resolve.
pub fn isAncestorOf(git: *Git, root: []const u8, commit: []const u8, ref: []const u8) Error!bool {
    const result = try git.run(root, &.{ "merge-base", "--is-ancestor", commit, ref }, .{});
    return result.ok();
}

// ---------------------------------------------------------------------------
// Committed transcript row (format: git_changes_protocol.zig)

pub const ROW_AUTHOR = "git";

pub const RowEntry = struct {
    sha: []const u8,
    /// Repository name; only written for multi-repository commits.
    repo: ?[]const u8 = null,
    pushed: bool = false,
    /// Web link to the commit (`remote <url>` line); null when unknown. Only
    /// written once the commit is pushed, so it never points at a 404.
    remote: ?[]const u8 = null,
    /// The repository had no remote at all when committed (`local` line).
    local: bool = false,
};

pub const CommitRow = struct {
    /// `Committed <N> file<s>`.
    headline: []const u8,
    entries: []RowEntry,
    subject: []const u8 = "",
    branch: ?[]const u8 = null,
};

/// Line 1 `<headline>: <sha>[ (<repo>)][ · pushed], ...`; optional line 2
/// subject, line 3 `branch <name>`, then one line per entry: `remote <url>`,
/// `local` (no remote at all), or bare `remote` (no link yet); trailing bare
/// `remote` lines are omitted. Earlier optional lines are written empty
/// whenever a later one follows.
pub fn formatCommitRow(arena: std.mem.Allocator, row: CommitRow) Error![]const u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(arena);
    body.print(arena, "{s}: ", .{row.headline}) catch return error.OutOfMemory;
    for (row.entries, 0..) |entry, i| {
        if (i > 0) body.appendSlice(arena, ", ") catch return error.OutOfMemory;
        body.appendSlice(arena, entry.sha) catch return error.OutOfMemory;
        if (entry.repo) |repo| body.print(arena, " ({s})", .{repo}) catch return error.OutOfMemory;
        if (entry.pushed) body.appendSlice(arena, " \u{00B7} pushed") catch return error.OutOfMemory;
    }
    var remote_count: usize = 0;
    for (row.entries, 0..) |entry, i| {
        if (entry.remote != null or entry.local) remote_count = i + 1;
    }
    const subject = firstLine(row.subject);
    if (subject.len > 0 or row.branch != null or remote_count > 0) body.print(arena, "\n{s}", .{subject}) catch return error.OutOfMemory;
    if (row.branch != null or remote_count > 0) {
        if (row.branch) |branch| {
            body.print(arena, "\nbranch {s}", .{firstLine(branch)}) catch return error.OutOfMemory;
        } else {
            body.append(arena, '\n') catch return error.OutOfMemory;
        }
    }
    for (row.entries[0..remote_count]) |entry| {
        if (entry.remote) |url| {
            body.print(arena, "\nremote {s}", .{url}) catch return error.OutOfMemory;
        } else if (entry.local) {
            body.appendSlice(arena, "\nlocal") catch return error.OutOfMemory;
        } else {
            body.appendSlice(arena, "\nremote") catch return error.OutOfMemory;
        }
    }
    return body.toOwnedSlice(arena) catch return error.OutOfMemory;
}

/// Inverse of `formatCommitRow`; null when `body` is not a commit row.
pub fn parseCommitRow(arena: std.mem.Allocator, body_raw: []const u8) Error!?CommitRow {
    const body = std.mem.trim(u8, body_raw, "\n\r\t ");
    var lines = std.mem.splitScalar(u8, body, '\n');
    const first = std.mem.trim(u8, lines.first(), " \t\r");
    if (!std.mem.startsWith(u8, first, "Committed ")) return null;
    const colon = std.mem.indexOf(u8, first, ": ") orelse return null;
    var entries: std.ArrayList(RowEntry) = .empty;
    var parts = std.mem.splitSequence(u8, first[colon + 2 ..], ", ");
    while (parts.next()) |part| {
        var rest = std.mem.trim(u8, part, " \t\r");
        const sha_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const sha = rest[0..sha_end];
        if (sha.len == 0) return null;
        for (sha) |c| if (!std.ascii.isHex(c)) return null;
        var entry: RowEntry = .{ .sha = sha };
        rest = std.mem.trimStart(u8, rest[sha_end..], " ");
        if (rest.len > 0 and rest[0] == '(') {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
            entry.repo = rest[1..close];
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " ");
        }
        if (rest.len > 0) {
            if (!std.mem.eql(u8, rest, "\u{00B7} pushed")) return null;
            entry.pushed = true;
        }
        entries.append(arena, entry) catch return error.OutOfMemory;
    }
    if (entries.items.len == 0) return null;
    var row: CommitRow = .{ .headline = first[0..colon], .entries = entries.items };
    if (lines.next()) |line| row.subject = std.mem.trim(u8, line, " \t\r");
    if (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "branch ")) {
            const branch = std.mem.trim(u8, trimmed["branch ".len..], " \t");
            if (branch.len > 0) row.branch = branch;
        }
    }
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (index >= row.entries.len) break;
        if (std.mem.eql(u8, trimmed, "local")) {
            row.entries[index].local = true;
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, "remote")) break;
        const url = std.mem.trim(u8, trimmed["remote".len..], " \t");
        if (url.len > 0) row.entries[index].remote = url;
    }
    return row;
}

/// Marks the entries `pushed[i]` as pushed and fills missing links from
/// `remotes[i]` (either clears a stale `local` marker); returns the new body,
/// or null when nothing changed.
pub fn rewriteCommitRowPushed(arena: std.mem.Allocator, body: []const u8, pushed: []const bool, remotes: []const ?[]const u8) Error!?[]const u8 {
    const row = (try parseCommitRow(arena, body)) orelse return null;
    var changed = false;
    for (row.entries, 0..) |*entry, i| {
        if (i < pushed.len and pushed[i] and !entry.pushed) {
            entry.pushed = true;
            entry.local = false;
            changed = true;
        }
        if (entry.remote == null and i < remotes.len) {
            if (remotes[i]) |url| {
                entry.remote = url;
                entry.local = false;
                changed = true;
            }
        }
    }
    if (!changed) return null;
    return try formatCommitRow(arena, row);
}

// ---------------------------------------------------------------------------
// Branch names (mirrors T3 Code's sanitizeFeatureBranchName)

pub const BRANCH_PREFIX = "feature/";
pub const BRANCH_FALLBACK = "feature/update";
pub const MAX_BRANCH_SLUG: usize = 64;

/// Lowercase `[a-z0-9/-]` fragment: other bytes become `-`, dashes and
/// slashes collapse, each path segment is trimmed of `-`, and the result is
/// capped at MAX_BRANCH_SLUG bytes. Empty input yields `update`.
pub fn sanitizeBranchFragment(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var segments = std.mem.splitScalar(u8, raw, '/');
    while (segments.next()) |segment| {
        var piece: std.ArrayList(u8) = .empty;
        var pending_dash = false;
        for (segment) |byte| {
            if (byte == '\'' or byte == '"' or byte == '`') continue;
            if (std.ascii.isAlphanumeric(byte)) {
                if (pending_dash and piece.items.len > 0) piece.append(arena, '-') catch return error.OutOfMemory;
                pending_dash = false;
                piece.append(arena, std.ascii.toLower(byte)) catch return error.OutOfMemory;
            } else {
                pending_dash = true;
            }
        }
        if (piece.items.len == 0) continue;
        if (out.items.len > 0) out.append(arena, '/') catch return error.OutOfMemory;
        out.appendSlice(arena, piece.items) catch return error.OutOfMemory;
    }
    var text: []const u8 = out.items[0..@min(out.items.len, MAX_BRANCH_SLUG)];
    text = std.mem.trimEnd(u8, text, "-/");
    return if (text.len == 0) "update" else text;
}

/// `feature/<fragment>`; an existing `feature/` prefix is kept.
pub fn sanitizeFeatureBranchName(arena: std.mem.Allocator, raw: []const u8) Error![]const u8 {
    const fragment = try sanitizeBranchFragment(arena, raw);
    if (std.mem.startsWith(u8, fragment, BRANCH_PREFIX) and fragment.len > BRANCH_PREFIX.len) return fragment;
    return std.fmt.allocPrint(arena, BRANCH_PREFIX ++ "{s}", .{fragment}) catch error.OutOfMemory;
}

/// Branch name from a commit subject: drops a conventional `type(scope):`
/// prefix and keeps the first six words.
pub fn branchFromSubject(arena: std.mem.Allocator, subject: []const u8) Error![]const u8 {
    var text = firstLine(subject);
    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        const prefix = text[0..colon];
        const conventional = colon <= 24 and for (prefix) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "()!-_/ ", byte) == null) break false;
        } else true;
        if (conventional and colon + 1 < text.len) text = text[colon + 1 ..];
    }
    var words: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    var count: usize = 0;
    while (it.next()) |word| : (count += 1) {
        if (count == 6) break;
        if (words.items.len > 0) words.append(arena, '-') catch return error.OutOfMemory;
        words.appendSlice(arena, word) catch return error.OutOfMemory;
    }
    if (words.items.len == 0) return BRANCH_FALLBACK;
    return sanitizeFeatureBranchName(arena, words.items);
}

/// `base`, or `base-2`, `base-3`... avoiding existing local branches
/// (case-insensitive) and ref directory/file conflicts with them.
pub fn resolveUniqueBranchName(arena: std.mem.Allocator, existing: []const []const u8, base: []const u8) Error![]const u8 {
    if (!branchTaken(existing, base)) return base;
    var suffix: u32 = 2;
    while (suffix < 10_000) : (suffix += 1) {
        const candidate = std.fmt.allocPrint(arena, "{s}-{d}", .{ base, suffix }) catch return error.OutOfMemory;
        if (!branchTaken(existing, candidate)) return candidate;
    }
    return error.BranchCreateFailed;
}

fn branchTaken(existing: []const []const u8, candidate: []const u8) bool {
    for (existing) |name| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
        // `a/b` cannot coexist with a branch `a/b/c`.
        if (name.len > candidate.len and name[candidate.len] == '/' and std.ascii.eqlIgnoreCase(name[0..candidate.len], candidate)) return true;
    }
    return false;
}

pub const GeneratedMessage = struct {
    message: []const u8,
    /// Sanitized `feature/...` branch; from the model's `Branch:` line or the
    /// subject.
    branch: []const u8,
};

/// Normalize a model reply that ends with a `Branch: <slug>` line: the line
/// is removed from the message and sanitized into the branch suggestion.
pub fn splitGeneratedMessage(arena: std.mem.Allocator, raw: []const u8) Error!?GeneratedMessage {
    const normalized = (try normalizeGeneratedMessage(arena, raw)) orelse return null;
    var branch_slug: ?[]const u8 = null;
    var message: []const u8 = normalized;
    // Scan from the bottom for the last `Branch:` line.
    var end = normalized.len;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, normalized[0..end], '\n')) |n| n + 1 else 0;
        const line = std.mem.trim(u8, normalized[start..end], " \t\r*_`");
        if (line.len >= 7 and std.ascii.eqlIgnoreCase(line[0..7], "branch:")) {
            branch_slug = std.mem.trim(u8, line[7..], " \t`'\"");
            var rest: std.ArrayList(u8) = .empty;
            rest.appendSlice(arena, normalized[0..start]) catch return error.OutOfMemory;
            if (end < normalized.len) rest.appendSlice(arena, normalized[end + 1 ..]) catch return error.OutOfMemory;
            message = (try normalizeGeneratedMessage(arena, rest.items)) orelse return null;
            break;
        }
        if (start == 0) break;
        end = start - 1;
    }
    const branch = if (branch_slug) |slug| (if (slug.len > 0) try sanitizeFeatureBranchName(arena, slug) else try branchFromSubject(arena, message)) else try branchFromSubject(arena, message);
    return .{ .message = message, .branch = branch };
}

/// Strip fences/quotes/preamble a model may wrap around a commit message.
pub fn normalizeGeneratedMessage(arena: std.mem.Allocator, raw: []const u8) Error!?[]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, text, "```")) {
        const first_newline = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
        text = text[first_newline + 1 ..];
        if (std.mem.lastIndexOf(u8, text, "```")) |fence| text = text[0..fence];
        text = std.mem.trim(u8, text, " \t\r\n");
    }
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text = text[1 .. text.len - 1];
    text = std.mem.trim(u8, text, " \t\r\n");
    if (text.len == 0) return null;
    const bounded = if (text.len > 4000) text[0..4000] else text;
    return arena.dupe(u8, bounded) catch error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestRepo = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    arena_state: std.heap.ArenaAllocator,

    fn init() !?TestRepo {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init(arena, .{});
        defer threaded.deinit();
        const root = try tmp.dir.realPathFileAlloc(threaded.io(), ".", testing.allocator);
        errdefer testing.allocator.free(root);
        var git = Git.init(arena) catch return null;
        defer git.deinit();
        for ([_][]const []const u8{
            &.{ "init", "-q", "-b", "main" },
            &.{ "config", "user.email", "test@example.com" },
            &.{ "config", "user.name", "Test" },
            &.{ "config", "commit.gpgsign", "false" },
        }) |args| {
            const result = try git.run(root, args, .{ .read_only = false });
            if (!result.ok()) return null;
        }
        return .{ .tmp = tmp, .root = root, .arena_state = arena_state };
    }

    fn deinit(self: *TestRepo) void {
        testing.allocator.free(self.root);
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *TestRepo, path: []const u8, data: []const u8) !void {
        var threaded: std.Io.Threaded = .init(testing.allocator, .{});
        defer threaded.deinit();
        try self.tmp.dir.writeFile(threaded.io(), .{ .sub_path = path, .data = data });
    }

    fn runGit(self: *TestRepo, args: []const []const u8) ![]const u8 {
        var runner = try Git.init(self.arena_state.allocator());
        defer runner.deinit();
        const result = try runner.run(self.root, args, .{ .read_only = false });
        if (!result.ok()) return error.TestGitFailed;
        return std.mem.trim(u8, result.stdout, " \t\r\n");
    }

    fn commitAll(self: *TestRepo, message: []const u8) !void {
        _ = try self.runGit(&.{ "add", "-A" });
        _ = try self.runGit(&.{ "commit", "-q", "-m", message });
    }
};

fn testLedgerTurn(
    ledger: *Ledger,
    repo: *TestRepo,
    turn_id: []const u8,
    thread_id: []const u8,
    hints: []const []const u8,
    edit: anytype,
) !void {
    var start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer start.deinit();
    try ledger.beginTurn(turn_id, &start, .{ .workspace_id = "ws", .thread_id = thread_id, .cwd = repo.root });
    try edit.run(repo);
    var end = try captureSnapshot(testing.allocator, &.{repo.root});
    defer end.deinit();
    _ = try ledger.endTurn(.{
        .turn_id = turn_id,
        .workspace_id = "ws",
        .thread_id = thread_id,
        .cwd = repo.root,
        .hints = hints,
        .now_ms = 1,
    }, &start, &end);
}

test "turn snapshots claim only files changed inside the turn" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "one\n");
    try repo.write("b.txt", "two\n");
    try repo.commitAll("init");
    // Pre-existing dirt belongs to nobody.
    try repo.write("b.txt", "two changed by user\n");

    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    const Edit = struct {
        fn run(r: *TestRepo) !void {
            try r.write("a.txt", "one changed by chat\n");
            try r.write("c.txt", "new file\n");
        }
    };
    try testLedgerTurn(&ledger, &repo, "t1", "chat-1", &.{}, Edit);
    try testing.expectEqual(@as(usize, 2), ledger.claims.items.len);
    for (ledger.claims.items) |claim| {
        try testing.expectEqualStrings("chat-1", claim.thread_id);
        try testing.expect(!claim.unclear);
        try testing.expect(!std.mem.eql(u8, claim.path, "b.txt"));
    }
}

test "overlapping turns mark unhinted files unclear" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "one\n");
    try repo.write("b.txt", "two\n");
    try repo.commitAll("init");

    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    var other_start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer other_start.deinit();
    try ledger.beginTurn("other", &other_start, .{ .workspace_id = "ws", .thread_id = "chat-2", .cwd = repo.root });

    const Edit = struct {
        fn run(r: *TestRepo) !void {
            try r.write("a.txt", "chat edit\n");
            try r.write("b.txt", "unknown edit\n");
        }
    };
    try testLedgerTurn(&ledger, &repo, "t1", "chat-1", &.{"a.txt"}, Edit);
    var saw_a = false;
    var saw_b = false;
    for (ledger.claims.items) |claim| {
        if (std.mem.eql(u8, claim.path, "a.txt")) {
            saw_a = true;
            try testing.expect(!claim.unclear);
        }
        if (std.mem.eql(u8, claim.path, "b.txt")) {
            saw_b = true;
            try testing.expect(claim.unclear);
        }
    }
    try testing.expect(saw_a and saw_b);
    ledger.abandonTurn("other");
}

fn testClaim(ledger: *const Ledger, path: []const u8, thread_id: []const u8) ?Claim {
    for (ledger.claims.items) |claim| {
        if (std.mem.eql(u8, claim.path, path) and std.mem.eql(u8, claim.thread_id, thread_id)) return claim;
    }
    return null;
}

fn testEndTurn(ledger: *Ledger, repo: *TestRepo, turn_id: []const u8, thread_id: []const u8, start: *const TurnSnapshot, now_ms: i64) !void {
    var end = try captureSnapshot(testing.allocator, &.{repo.root});
    defer end.deinit();
    _ = try ledger.endTurn(.{
        .turn_id = turn_id,
        .workspace_id = "ws",
        .thread_id = thread_id,
        .cwd = repo.root,
        .hints = &.{},
        .now_ms = now_ms,
    }, start, &end);
}

test "overlapping turns attribute files by edit evidence" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }) |name| try repo.write(name, "base\n");
    try repo.commitAll("init");

    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    var one_start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer one_start.deinit();
    var two_start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer two_start.deinit();
    try ledger.beginTurn("t1", &one_start, .{ .workspace_id = "ws", .thread_id = "chat-1", .cwd = repo.root });
    try ledger.beginTurn("t2", &two_start, .{ .workspace_id = "ws", .thread_id = "chat-2", .cwd = repo.root });

    // chat-1 edits a (relative hint) and d; chat-2 edits b (absolute) and d.
    const abs_b = try std.fs.path.join(testing.allocator, &.{ repo.root, "b.txt" });
    defer testing.allocator.free(abs_b);
    ledger.recordHints("t1", &.{ "a.txt", "d.txt" });
    ledger.recordHints("t2", &.{ abs_b, "d.txt" });
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" }) |name| try repo.write(name, "changed\n");

    try testEndTurn(&ledger, &repo, "t1", "chat-1", &one_start, 10);
    // Mine: hinted by this chat. Theirs: hinted only by the peer -> no claim.
    // Nobody: unclear. Both: a confident claim each (shared in reviews).
    try testing.expect(!testClaim(&ledger, "a.txt", "chat-1").?.unclear);
    try testing.expect(testClaim(&ledger, "b.txt", "chat-1") == null);
    try testing.expect(testClaim(&ledger, "c.txt", "chat-1").?.unclear);
    try testing.expect(!testClaim(&ledger, "d.txt", "chat-1").?.unclear);
    // The ended turn's evidence is kept for its running peer.
    try testing.expectEqual(@as(usize, 1), ledger.retired.items.len);

    try testEndTurn(&ledger, &repo, "t2", "chat-2", &two_start, 20);
    try testing.expect(testClaim(&ledger, "a.txt", "chat-2") == null);
    try testing.expect(!testClaim(&ledger, "b.txt", "chat-2").?.unclear);
    try testing.expect(testClaim(&ledger, "c.txt", "chat-2").?.unclear);
    try testing.expect(!testClaim(&ledger, "d.txt", "chat-2").?.unclear);
    try testing.expectEqual(@as(usize, 0), ledger.retired.items.len);
    try testing.expectEqual(@as(usize, 0), ledger.active.items.len);
}

test "a peer's later evidence drops an ended turn's unclear guess" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "base\n");
    try repo.commitAll("init");

    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    var one_start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer one_start.deinit();
    var two_start = try captureSnapshot(testing.allocator, &.{repo.root});
    defer two_start.deinit();
    try ledger.beginTurn("t1", &one_start, .{ .workspace_id = "ws", .thread_id = "chat-1", .cwd = repo.root });
    try ledger.beginTurn("t2", &two_start, .{ .workspace_id = "ws", .thread_id = "chat-2", .cwd = repo.root });
    try repo.write("a.txt", "changed by chat-2\n");
    // chat-1 ends before chat-2 reported the edit: an unclear guess.
    try testEndTurn(&ledger, &repo, "t1", "chat-1", &one_start, 10);
    try testing.expect(testClaim(&ledger, "a.txt", "chat-1").?.unclear);

    ledger.recordHints("t2", &.{"a.txt"});
    try testEndTurn(&ledger, &repo, "t2", "chat-2", &two_start, 20);
    try testing.expect(!testClaim(&ledger, "a.txt", "chat-2").?.unclear);
    try testing.expect(testClaim(&ledger, "a.txt", "chat-1") == null);
}

fn expectHints(evidence: ToolEvidence, expected: []const []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try collectToolHints(arena_state.allocator(), evidence, &out);
    try testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "tool events name edited files per provider shape" {
    // Claude subagent transcript: Edit / MultiEdit / NotebookEdit / Write
    // entries count, reads do not.
    try expectHints(.{ .kind = "subagent", .transcript =
        \\{"type":"text","text":"working"}
        \\{"type":"tool_use","id":"u1","kind":"read","title":"Read /r/x.zig","input":"{\"file_path\":\"/r/x.zig\"}"}
        \\{"type":"tool_use","id":"u2","kind":"edit","title":"Edit /r/a.zig","input":"{\"file_path\":\"/r/a.zig\",\"old_string\":\"x\",\"new_string\":\"y\"}"}
        \\{"type":"tool_use","id":"u3","kind":"edit","title":"MultiEdit /r/m.zig","input":"{\"file_path\":\"/r/m.zig\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"}]}","parent":"u0"}
        \\{"type":"tool_use","id":"u4","kind":"edit","title":"NotebookEdit","input":"{\"notebook_path\":\"/r/n.ipynb\",\"new_source\":\"x\"}"}
        \\{"type":"tool_use","id":"u5","kind":"execute","title":"","input":"sed -i s/a/b/ /r/s.zig"}
        \\{"type":"tool_result","id":"u2","is_error":false,"output":"ok"}
    }, &.{ "/r/a.zig", "/r/m.zig", "/r/n.ipynb" });
    // Claude top-level tool input (MultiEdit via the bridge).
    try expectHints(.{ .kind = "edit", .input = "{\"file_path\":\"/r/w.md\",\"content\":\"hi\"}" }, &.{"/r/w.md"});
    // Codex fileChange summary lines.
    try expectHints(.{ .kind = "edit", .input = "/r/src/x.zig  +2 / -1\nrel/y.md  +0 / -3" }, &.{ "/r/src/x.zig", "rel/y.md" });
    // Codex / OpenCode apply_patch text, raw and as `patchText`.
    try expectHints(.{ .kind = "edit", .input = "*** Begin Patch\n*** Update File: src/a.rs\n@@\n-x\n+y\n*** Add File: b.rs\n+z\n*** End Patch" }, &.{ "src/a.rs", "b.rs" });
    try expectHints(.{ .kind = "edit", .input = "{\"patchText\":\"*** Begin Patch\\n*** Delete File: /r/gone.ts\\n*** End Patch\"}" }, &.{"/r/gone.ts"});
    // OpenCode edit / write arguments.
    try expectHints(.{ .kind = "edit", .input = "{\"filePath\":\"/r/o.ts\",\"oldString\":\"a\",\"newString\":\"b\"}" }, &.{"/r/o.ts"});
    // OpenCode subagent transcript entry.
    try expectHints(.{ .kind = "subagent", .transcript = "{\"type\":\"tool_use\",\"id\":\"c1\",\"kind\":\"edit\",\"title\":\"write\",\"input\":\"{\\\"filePath\\\":\\\"/r/child.ts\\\",\\\"content\\\":\\\"x\\\"}\"}\n" }, &.{"/r/child.ts"});
    // ACP locations.
    try expectHints(.{ .kind = "edit", .locations = "[{\"path\":\"/r/l.zig\",\"line\":3}]" }, &.{"/r/l.zig"});
    // Shell, reads and MCP calls are not evidence.
    try expectHints(.{ .kind = "execute", .input = "echo x > /r/e.txt" }, &.{});
    try expectHints(.{ .kind = "read", .input = "{\"file_path\":\"/r/read.zig\"}" }, &.{});
    try expectHints(.{ .kind = "mcp", .input = "{\"path\":\"/r/mcp.zig\"}" }, &.{});
    try expectHints(.{ .kind = null, .input = "{\"file_path\":\"/r/unknown.zig\"}" }, &.{});
}

test "stored transcript rows yield edit evidence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    try collectStoredRowHints(arena, "edit", "Input:\n/r/a.zig  +1 / -1\n/r/b.zig  +0 / -0\n\nOutput:\n/r/not-this.zig  +9 / -9", &out);
    try collectStoredRowHints(arena, null, "VERDE_DIFF_V2\nFILE\t8\t1\t1\t12\n/r/c.zig@@ -1 +1 @@\nFILE\t8\t0\t0\t0\n/r/d.zig", &out);
    try collectStoredRowHints(arena, "subagent", "Tool:\nWork\n\nInput:\n{\"prompt\":\"edit /r/p.zig\"}\n\nTranscript:\n{\"type\":\"tool_use\",\"id\":\"u\",\"kind\":\"edit\",\"title\":\"Edit /r/e.zig\",\"input\":\"{\\\"file_path\\\":\\\"/r/e.zig\\\"}\"}", &out);
    try collectStoredRowHints(arena, "execute", "Input:\ntouch /r/x.zig", &out);
    const expected = [_][]const u8{ "/r/a.zig", "/r/b.zig", "/r/c.zig", "/r/d.zig", "/r/e.zig" };
    try testing.expectEqual(expected.len, out.items.len);
    for (expected, out.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "stored evidence settles unclear claims" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    _ = try ledger.upsertClaim("/repo", "a.txt", "ws", "chat-1", 5, true, 1);
    _ = try ledger.upsertClaim("/repo", "a.txt", "ws", "chat-2", 5, true, 1);
    _ = try ledger.upsertClaim("/repo", "b.txt", "ws", "chat-1", 6, true, 1);
    _ = try ledger.upsertClaim("/repo", "c.txt", "ws", "chat-1", 7, true, 1);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const candidates = try ledger.repairCandidates(arena_state.allocator());
    try testing.expectEqual(@as(usize, 2), candidates.len);

    const evidence = [_]ThreadEvidence{
        .{ .workspace_id = "ws", .thread_id = "chat-1", .hints = &.{"/repo/b.txt"} },
        .{ .workspace_id = "ws", .thread_id = "chat-2", .hints = &.{"/repo/a.txt"} },
    };
    try testing.expect(ledger.repairUnclear(&evidence));
    // a: only chat-2's transcript edited it -> chat-1 loses its guess.
    try testing.expect(testClaim(&ledger, "a.txt", "chat-1") == null);
    try testing.expect(!testClaim(&ledger, "a.txt", "chat-2").?.unclear);
    // b: chat-1's own edit. c: no evidence either way, stays unclear.
    try testing.expect(!testClaim(&ledger, "b.txt", "chat-1").?.unclear);
    try testing.expect(testClaim(&ledger, "c.txt", "chat-1").?.unclear);
}

test "review and partial commit keep other hunks and the real index" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    var original: std.ArrayList(u8) = .empty;
    defer original.deinit(testing.allocator);
    for (0..40) |i| try original.print(testing.allocator, "line {d}\n", .{i});
    try repo.write("big.txt", original.items);
    try repo.write("staged.txt", "s\n");
    try repo.commitAll("init");

    // Two distant edits -> two hunks; plus a user-staged file elsewhere.
    var edited: std.ArrayList(u8) = .empty;
    defer edited.deinit(testing.allocator);
    for (0..40) |i| {
        if (i == 2) try edited.appendSlice(testing.allocator, "first edit\n") else if (i == 35) try edited.appendSlice(testing.allocator, "second edit\n") else try edited.print(testing.allocator, "line {d}\n", .{i});
    }
    try repo.write("big.txt", edited.items);
    try repo.write("staged.txt", "user staged\n");
    _ = try repo.runGit(&.{ "add", "staged.txt" });

    const claims = [_]ClaimView{.{ .path = "big.txt", .workspace_id = "ws", .thread_id = "chat-1", .unclear = false }};
    var review = try buildReview(testing.allocator, .{
        .id = "r1",
        .workspace_id = "ws",
        .thread_id = "chat-1",
        .repos = &.{.{ .root = repo.root, .claims = &claims }},
        .now_ms = 1,
    });
    defer review.deinit();
    try testing.expectEqual(@as(usize, 1), review.repos.len);
    const big = findFile(&review.repos[0], "big.txt").?;
    try testing.expectEqual(Ownership.mine, big.ownership);
    try testing.expectEqual(@as(usize, 2), big.hunks.len);
    const staged = findFile(&review.repos[0], "staged.txt").?;
    try testing.expectEqual(Ownership.unassigned, staged.ownership);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try commitRepo(arena_state.allocator(), .{
        .review = &review,
        .selection = .{ .root = repo.root, .files = &.{.{ .path = "big.txt", .hunks = &.{0} }} },
        .message = "test: first hunk only",
        .push = false,
        .nonce = 7,
    });
    try testing.expectEqual(@as(usize, 1), result.files);
    try testing.expect(!result.index_reset);

    const shown = try repo.runGit(&.{ "show", "HEAD:big.txt" });
    try testing.expect(std.mem.indexOf(u8, shown, "first edit") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "second edit") == null);
    // The user's staged file is still staged and was not committed.
    const cached = try repo.runGit(&.{ "diff", "--cached", "--name-only" });
    try testing.expectEqualStrings("staged.txt", cached);
    const committed_names = try repo.runGit(&.{ "show", "--name-only", "--format=", "HEAD" });
    try testing.expectEqualStrings("big.txt", committed_names);
    // The second hunk remains as an unstaged change.
    const unstaged = try repo.runGit(&.{ "diff", "--name-only" });
    try testing.expectEqualStrings("big.txt", unstaged);
}

test "commit of a new file from a frozen review" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "a\n");
    try repo.commitAll("init");
    try repo.write("new.txt", "brand new\n");

    const claims = [_]ClaimView{.{ .path = "new.txt", .workspace_id = "ws", .thread_id = "chat-1", .unclear = false }};
    var review = try buildReview(testing.allocator, .{
        .id = "r1",
        .workspace_id = "ws",
        .thread_id = "chat-1",
        .repos = &.{.{ .root = repo.root, .claims = &claims }},
        .now_ms = 1,
    });
    defer review.deinit();
    const file = findFile(&review.repos[0], "new.txt").?;
    try testing.expectEqual(FileStatus.added, file.status);
    try testing.expect(file.patch != null);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try commitRepo(arena_state.allocator(), .{
        .review = &review,
        .selection = .{ .root = repo.root, .files = &.{.{ .path = "new.txt" }} },
        .message = "add new file",
        .push = false,
        .nonce = 1,
    });
    const shown = try repo.runGit(&.{ "show", "HEAD:new.txt" });
    try testing.expectEqualStrings("brand new", shown);
    const status = try repo.runGit(&.{ "status", "--porcelain" });
    try testing.expectEqualStrings("", status);
}

test "ledger persistence round-trips claims" {
    var ledger = Ledger.init(testing.allocator);
    defer ledger.deinit();
    _ = try ledger.upsertClaim("/repo", "a.txt", "ws", "chat-1", 42, true, 9);
    const bytes = try ledger.encode(testing.allocator);
    defer testing.allocator.free(bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const dir_path = try tmp.dir.realPathFileAlloc(threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const path = try std.fs.path.join(testing.allocator, &.{ dir_path, LEDGER_FILE_NAME });
    defer testing.allocator.free(path);
    writePersisted(testing.allocator, path, bytes);

    var loaded = Ledger.init(testing.allocator);
    defer loaded.deinit();
    try loaded.load(path);
    try testing.expectEqual(@as(usize, 1), loaded.claims.items.len);
    try testing.expectEqualStrings("chat-1", loaded.claims.items[0].thread_id);
    try testing.expect(loaded.claims.items[0].unclear);
}

test "generated commit messages lose fences and quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("fix: thing", (try normalizeGeneratedMessage(arena, "```\nfix: thing\n```")).?);
    try testing.expectEqualStrings("fix: thing", (try normalizeGeneratedMessage(arena, "\"fix: thing\"")).?);
    try testing.expect((try normalizeGeneratedMessage(arena, "  \n ")) == null);
}

test "line stats count tracked diffs and untracked files" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "one\ntwo\n");
    try repo.commitAll("init");
    try repo.write("a.txt", "one\nchanged\nthree\n");
    try repo.write("new.txt", "x\ny\nz");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var git = try Git.init(arena_state.allocator());
    defer git.deinit();
    const entries = (try dirtyPaths(&git, repo.root)).?;
    const stats = try lineStats(&git, repo.root, entries);
    try testing.expectEqual(LineStat{ .additions = 2, .deletions = 1 }, stats.get("a.txt").?);
    try testing.expectEqual(LineStat{ .additions = 3, .deletions = 0 }, stats.get("new.txt").?);
}

test "branch names sanitize like feature slugs and avoid collisions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("feature/add-dark-mode", try sanitizeFeatureBranchName(arena, "  Add Dark_Mode!! "));
    try testing.expectEqualStrings("feature/ui/theme-fix", try sanitizeFeatureBranchName(arena, "UI//-theme--fix-/"));
    try testing.expectEqualStrings("feature/keep", try sanitizeFeatureBranchName(arena, "feature/keep"));
    try testing.expectEqualStrings("feature/fix/x", try sanitizeFeatureBranchName(arena, "fix/x"));
    try testing.expectEqualStrings(BRANCH_FALLBACK, try sanitizeFeatureBranchName(arena, " ..// "));
    try testing.expectEqualStrings("feature/caf", try sanitizeFeatureBranchName(arena, "`café`"));
    const long = try sanitizeFeatureBranchName(arena, "a" ** 63 ++ "-bbbb");
    try testing.expectEqual(BRANCH_PREFIX.len + 63, long.len);
    try testing.expect(!std.mem.endsWith(u8, long, "-"));

    try testing.expectEqualStrings("feature/add-branch-picker-to-commit-sheet", try branchFromSubject(arena, "feat(ui): Add branch picker to commit sheet\n\nbody"));
    try testing.expectEqualStrings(BRANCH_FALLBACK, try branchFromSubject(arena, "   "));

    const existing = [_][]const u8{ "main", "feature/x", "Feature/X-2", "feature/y/z" };
    try testing.expectEqualStrings("feature/x-3", try resolveUniqueBranchName(arena, &existing, "feature/x"));
    try testing.expectEqualStrings("feature/y-2", try resolveUniqueBranchName(arena, &existing, "feature/y"));
    try testing.expectEqualStrings("feature/new", try resolveUniqueBranchName(arena, &existing, "feature/new"));
}

test "generated messages split off a trailing branch line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const split = (try splitGeneratedMessage(arena, "```\nfix: handle empty repos\n\nExplain why.\nBranch: `Handle Empty Repos`\n```")).?;
    try testing.expectEqualStrings("fix: handle empty repos\n\nExplain why.", split.message);
    try testing.expectEqualStrings("feature/handle-empty-repos", split.branch);
    const plain = (try splitGeneratedMessage(arena, "Add status endpoint")).?;
    try testing.expectEqualStrings("Add status endpoint", plain.message);
    try testing.expectEqualStrings("feature/add-status-endpoint", plain.branch);
    const empty_branch = (try splitGeneratedMessage(arena, "docs: tweak\nbranch:")).?;
    try testing.expectEqualStrings("docs: tweak", empty_branch.message);
    try testing.expectEqualStrings("feature/tweak", empty_branch.branch);
    try testing.expect((try splitGeneratedMessage(arena, "Branch: only")) == null);
}

test "review preview budget stops at the first file that does not fit" {
    const hunks_small = [_]Hunk{.{ .start = 0, .end = 100 }};
    const hunks_big = [_]Hunk{ .{ .start = 0, .end = 400 }, .{ .start = 400, .end = 700 } };
    const base: ReviewFile = .{ .path = "a", .status = .modified, .ownership = .mine, .other_threads = &.{}, .additions = 0, .deletions = 0, .binary = false, .patch = "", .header_end = 0, .hunks = &hunks_small };
    var big = base;
    big.hunks = &hunks_big;
    var none = base;
    none.hunks = &.{};

    var budget: PreviewBudget = .{ .remaining = 750 };
    try testing.expect(budget.admit(&base));
    try testing.expect(!budget.admit(&none));
    try testing.expect(!budget.admit(&big));
    // A later small file still gets no preview once the budget is exhausted.
    try testing.expect(!budget.admit(&base));

    try testing.expectEqual(DEFAULT_REVIEW_HUNK_BUDGET, PreviewBudget.init(null).remaining);
    try testing.expectEqual(MAX_REVIEW_HUNK_BUDGET, PreviewBudget.init(std.math.maxInt(u64)).remaining);
    var zero = PreviewBudget.init(0);
    try testing.expect(!zero.admit(&base));
}

test "reviews in use are never evicted" {
    var reviews = Reviews.init(testing.allocator);
    defer reviews.deinit();
    const first = try reviews.put(.{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .id = "r0", .workspace_id = "ws", .thread_id = "t", .created_ms = 0, .repos = &.{} }, 0);
    const pinned = reviews.acquire("r0").?;
    try testing.expectEqual(first, pinned);
    // Expired by TTL but pinned: survives the next put.
    _ = try reviews.put(.{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .id = "r1", .workspace_id = "ws", .thread_id = "t", .created_ms = REVIEW_TTL_MS + 1, .repos = &.{} }, REVIEW_TTL_MS + 1);
    try testing.expect(reviews.find("r0") != null);
    reviews.release(pinned);
    _ = try reviews.put(.{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .id = "r2", .workspace_id = "ws", .thread_id = "t", .created_ms = REVIEW_TTL_MS + 2, .repos = &.{} }, REVIEW_TTL_MS + 2);
    try testing.expect(reviews.find("r0") == null);
    try testing.expect(reviews.find("r1") != null);
}

test "commit onto a new branch keeps the working tree and index" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    try repo.write("a.txt", "a\n");
    try repo.write("b.txt", "b\n");
    try repo.write("staged.txt", "s\n");
    try repo.commitAll("init");
    const base_commit = try repo.runGit(&.{ "rev-parse", "HEAD" });
    // The preferred name is taken, so the commit lands on `-2`.
    _ = try repo.runGit(&.{ "branch", "feature/add-thing" });

    try repo.write("a.txt", "a changed by chat\n");
    try repo.write("b.txt", "b changed, not selected\n");
    try repo.write("staged.txt", "user staged\n");
    _ = try repo.runGit(&.{ "add", "staged.txt" });

    const claims = [_]ClaimView{.{ .path = "a.txt", .workspace_id = "ws", .thread_id = "chat-1", .unclear = false }};
    var review = try buildReview(testing.allocator, .{
        .id = "r1",
        .workspace_id = "ws",
        .thread_id = "chat-1",
        .repos = &.{.{ .root = repo.root, .claims = &claims }},
        .now_ms = 1,
    });
    defer review.deinit();
    try testing.expectEqualStrings("main", review.repos[0].status.branch.?);
    try testing.expect(review.repos[0].status.is_default_branch);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try commitRepo(arena_state.allocator(), .{
        .review = &review,
        .selection = .{ .root = repo.root, .files = &.{.{ .path = "a.txt" }} },
        .message = "Add thing",
        .push = false,
        .nonce = 3,
        .new_branch = "feature/add-thing",
    });
    try testing.expect(result.branch_created);
    try testing.expectEqualStrings("feature/add-thing-2", result.branch.?);
    try testing.expectEqualStrings("refs/heads/feature/add-thing-2", try repo.runGit(&.{ "symbolic-ref", "HEAD" }));
    // The original branch did not move; the new one has the commit on top.
    try testing.expectEqualStrings(base_commit, try repo.runGit(&.{ "rev-parse", "main" }));
    try testing.expectEqualStrings(base_commit, try repo.runGit(&.{ "rev-parse", "HEAD~1" }));
    try testing.expectEqualStrings("a.txt", try repo.runGit(&.{ "show", "--name-only", "--format=", "HEAD" }));
    // Unselected edits stay in the working tree and the user's staging stays staged.
    try testing.expectEqualStrings("staged.txt", try repo.runGit(&.{ "diff", "--cached", "--name-only" }));
    try testing.expectEqualStrings("b.txt", try repo.runGit(&.{ "diff", "--name-only" }));
    try testing.expectEqualStrings("b", try repo.runGit(&.{ "cat-file", "-p", ":0:b.txt" }));
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const on_disk = try repo.tmp.dir.readFileAlloc(threaded.io(), "b.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("b changed, not selected\n", on_disk);
    const a_disk = try repo.tmp.dir.readFileAlloc(threaded.io(), "a.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(a_disk);
    try testing.expectEqualStrings("a changed by chat\n", a_disk);
}

test "push publishes a branch without upstream and status tracks it" {
    var repo = (try TestRepo.init()) orelse return error.SkipZigTest;
    defer repo.deinit();
    var remote_tmp = testing.tmpDir(.{});
    defer remote_tmp.cleanup();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const remote_path = try remote_tmp.dir.realPathFileAlloc(threaded.io(), ".", testing.allocator);
    defer testing.allocator.free(remote_path);
    const arena = repo.arena_state.allocator();
    var git = try Git.init(arena);
    defer git.deinit();
    if (!(try git.run(remote_path, &.{ "init", "--bare", "-q" }, .{ .read_only = false })).ok()) return error.SkipZigTest;

    try repo.write("a.txt", "a\n");
    try repo.commitAll("init");
    var status = try repoStatus(&git, repo.root);
    try testing.expect(!status.has_remote);
    try testing.expect(status.upstream == null);
    try testing.expectEqualStrings("main", status.default_branch.?);
    try testing.expect(status.is_default_branch);

    // No remote: a clear failure, nothing pushed.
    const no_remote = try push(&git, repo.root);
    try testing.expectEqual(PushStatus.failed, no_remote.status);
    try testing.expect(!(try hasRemote(&git, repo.root)));

    _ = try repo.runGit(&.{ "remote", "add", "origin", remote_path });
    try testing.expect(try hasRemote(&git, repo.root));
    const pushed = try pushRepo(arena, repo.root);
    try testing.expectEqual(PushStatus.pushed, pushed.status);
    // Push facts: the first publish counts commits on no remote.
    try testing.expectEqual(@as(u32, 1), pushed.pushed.?.commits);
    try testing.expectEqualStrings("init", pushed.pushed.?.subject.?);
    try testing.expectEqual(@as(usize, 7), pushed.pushed.?.head.?.len);
    try testing.expectEqualStrings("origin/main", pushed.pushed.?.upstream.?);
    // A local-path remote has no web page.
    try testing.expect(pushed.pushed.?.remote_url == null);
    status = try repoStatus(&git, repo.root);
    try testing.expect(status.has_remote);
    try testing.expectEqualStrings("origin/main", status.upstream.?);
    try testing.expectEqual(@as(u32, 0), status.ahead);

    try repo.write("a.txt", "a2\n");
    try repo.commitAll("second");
    status = try repoStatus(&git, repo.root);
    try testing.expectEqual(@as(u32, 1), status.ahead);
    try testing.expectEqual(@as(u32, 0), status.behind);
    const second = try pushRepo(arena, repo.root);
    try testing.expectEqual(PushStatus.pushed, second.status);
    try testing.expectEqual(@as(u32, 1), second.pushed.?.commits);
    try testing.expectEqualStrings("second", second.pushed.?.subject.?);
    // Move local main back one commit: now behind the upstream.
    _ = try repo.runGit(&.{ "update-ref", "refs/heads/main", "HEAD~1" });
    status = try repoStatus(&git, repo.root);
    try testing.expectEqual(@as(u32, 0), status.ahead);
    try testing.expectEqual(@as(u32, 1), status.behind);

    // origin/HEAD wins over local main/master; a feature branch is not default.
    _ = try repo.runGit(&.{ "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main" });
    _ = try repo.runGit(&.{ "switch", "-q", "-c", "feature/x" });
    status = try repoStatus(&git, repo.root);
    try testing.expectEqualStrings("feature/x", status.branch.?);
    try testing.expectEqualStrings("main", status.default_branch.?);
    try testing.expect(!status.is_default_branch);
    try testing.expect(status.upstream == null);
    try testing.expectEqual(@as(u32, 0), status.ahead);
    try repo.write("b.txt", "b\n");
    try repo.commitAll("feature work");
    // Unpublished branch: ahead counts commits not on any remote.
    try testing.expectEqual(@as(u32, 1), (try repoStatus(&git, repo.root)).ahead);
    try testing.expectEqual(PushStatus.pushed, (try pushRepo(arena, repo.root)).status);
    try testing.expectEqualStrings("origin/feature/x", (try repoStatus(&git, repo.root)).upstream.?);
    _ = try repo.runGit(&.{ "switch", "-q", "--detach" });
    try testing.expect((try repoStatus(&git, repo.root)).branch == null);
    try testing.expectEqual(PushStatus.failed, (try push(&git, repo.root)).status);
}

test "commit web urls from remote urls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sha = "e57cfce0123456789abcdef0123456789abcdef0";
    const expected = "https://github.com/acme/app/commit/" ++ sha;
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "git@github.com:acme/app.git", sha)).?);
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "git@github.com:acme/app", sha)).?);
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "ssh://git@github.com/acme/app.git", sha)).?);
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "ssh://git@github.com:22/acme/app/", sha)).?);
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "https://github.com/acme/app.git\n", sha)).?);
    try testing.expectEqualStrings(expected, (try commitWebUrl(arena, "https://token@github.com/acme/app", sha)).?);
    try testing.expectEqualStrings(
        "https://gitlab.example.com:8443/group/sub/app/commit/" ++ sha,
        (try commitWebUrl(arena, "https://gitlab.example.com:8443/group/sub/app.git", sha)).?,
    );
    try testing.expect((try commitWebUrl(arena, "/srv/git/app.git", sha)) == null);
    try testing.expect((try commitWebUrl(arena, "file:///srv/git/app.git", sha)) == null);
    try testing.expect((try commitWebUrl(arena, "../app", sha)) == null);
    try testing.expect((try commitWebUrl(arena, "git@github.com:app", sha)) == null);
    try testing.expect((try commitWebUrl(arena, "", sha)) == null);
    try testing.expect((try commitWebUrl(arena, "git@github.com:acme/app.git", "not-a-sha")) == null);
}

test "commit rows round-trip and gain pushed state and links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var single = [_]RowEntry{.{ .sha = "1a2b3c4" }};
    const plain = try formatCommitRow(arena, .{ .headline = "Committed 1 file", .entries = &single });
    try testing.expectEqualStrings("Committed 1 file: 1a2b3c4", plain);
    // Old rows without detail lines gain a positional subject/branch gap.
    const linked = (try rewriteCommitRowPushed(arena, plain, &.{true}, &.{"https://github.com/a/b/commit/1a2b3c4ff"})).?;
    try testing.expectEqualStrings("Committed 1 file: 1a2b3c4 \u{00B7} pushed\n\n\nremote https://github.com/a/b/commit/1a2b3c4ff", linked);
    try testing.expect((try rewriteCommitRowPushed(arena, linked, &.{true}, &.{"https://other"})) == null);

    const full = "Committed 3 files: 1a2b3c4\nfix login\nbranch main\nremote https://github.com/a/b/commit/1a2b3c4ff";
    const parsed = (try parseCommitRow(arena, full)).?;
    try testing.expectEqualStrings("fix login", parsed.subject);
    try testing.expectEqualStrings("main", parsed.branch.?);
    try testing.expectEqualStrings("https://github.com/a/b/commit/1a2b3c4ff", parsed.entries[0].remote.?);
    try testing.expectEqualStrings(full, try formatCommitRow(arena, parsed));
    try testing.expectEqualStrings(
        "Committed 3 files: 1a2b3c4 \u{00B7} pushed\nfix login\nbranch main\nremote https://github.com/a/b/commit/1a2b3c4ff",
        (try rewriteCommitRowPushed(arena, full, &.{true}, &.{null})).?,
    );

    // Multi-repo: only the pushed repository's entry changes; links stay positional.
    const multi = "Committed 5 files: 1a2b3c4 (app), abcdef0 (lib)\nfeat\nbranch main";
    try testing.expectEqualStrings(
        "Committed 5 files: 1a2b3c4 (app), abcdef0 (lib) \u{00B7} pushed\nfeat\nbranch main\nremote\nremote https://github.com/a/lib/commit/abcdef0ff",
        (try rewriteCommitRowPushed(arena, multi, &.{ false, true }, &.{ null, "https://github.com/a/lib/commit/abcdef0ff" })).?,
    );

    // No remote at all: a `local` line, kept even when trailing; a later
    // push that publishes the commit replaces it with the link.
    var local_entry = [_]RowEntry{.{ .sha = "1a2b3c4", .local = true }};
    const local = try formatCommitRow(arena, .{ .headline = "Committed 1 file", .entries = &local_entry, .subject = "wip", .branch = "main" });
    try testing.expectEqualStrings("Committed 1 file: 1a2b3c4\nwip\nbranch main\nlocal", local);
    const local_parsed = (try parseCommitRow(arena, local)).?;
    try testing.expect(local_parsed.entries[0].local and local_parsed.entries[0].remote == null);
    try testing.expectEqualStrings(local, try formatCommitRow(arena, local_parsed));
    try testing.expectEqualStrings(
        "Committed 1 file: 1a2b3c4 \u{00B7} pushed\nwip\nbranch main\nremote https://github.com/a/b/commit/1a2b3c4ff",
        (try rewriteCommitRowPushed(arena, local, &.{true}, &.{"https://github.com/a/b/commit/1a2b3c4ff"})).?,
    );
    // Mixed: an unpushed repo with a remote (bare line) before a local one.
    var mixed_entries = [_]RowEntry{ .{ .sha = "1a2b3c4", .repo = "app" }, .{ .sha = "abcdef0", .repo = "notes", .local = true } };
    const mixed = try formatCommitRow(arena, .{ .headline = "Committed 2 files", .entries = &mixed_entries });
    try testing.expectEqualStrings("Committed 2 files: 1a2b3c4 (app), abcdef0 (notes)\n\n\nremote\nlocal", mixed);
    const mixed_parsed = (try parseCommitRow(arena, mixed)).?;
    try testing.expect(!mixed_parsed.entries[0].local and mixed_parsed.entries[1].local);

    try testing.expect((try parseCommitRow(arena, "Push rejected: nope")) == null);
    try testing.expect((try parseCommitRow(arena, "Committed 1 file: zzz")) == null);
}
