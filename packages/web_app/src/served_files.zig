//! Confines `/api/file` and `/api/preview` to registered workspace roots.
//!
//! A chat citation can name any absolute path, and a paired phone only needs
//! `repository:read` to follow it. Before the gateway reads a document it
//! resolves the request with realpath and requires the result to sit inside a
//! workspace path or repository binding root reported by the daemon. Roots are
//! cached briefly so a burst of citation clicks does not page `workspace.list`
//! on every request.

const std = @import("std");
const headless = @import("headless");

const log = std.log.scoped(.web_served_files);

/// Roots change only when the user edits workspaces; a few seconds of staleness
/// is fine and keeps clicked citations from hammering the daemon.
pub const ROOTS_TTL_MS: i64 = 5_000;
/// Page size used while walking `workspace.list`.
pub const LIST_PAGE_LIMIT: u32 = 200;
/// Hard stop for a daemon that keeps handing back cursors.
const MAX_LIST_PAGES: usize = 64;

pub const ConfineError = error{
    /// The resolved path lies outside every registered root.
    PathOutsideWorkspace,
    /// The path is lexically inside a root but does not resolve on disk.
    FileNotFound,
    OutOfMemory,
    Canceled,
};

/// Registered roots snapshot owned by the caller.
pub const Roots = struct {
    paths: [][]u8,

    pub fn deinit(self: Roots, allocator: std.mem.Allocator) void {
        for (self.paths) |path| allocator.free(path);
        allocator.free(self.paths);
    }

    /// Resolve `requested` with realpath and keep it only when it sits inside a
    /// root. Comparison is component-aware so `/a/bc` never matches root `/a/b`.
    pub fn confine(self: Roots, allocator: std.mem.Allocator, io: std.Io, requested: []const u8) ConfineError![]u8 {
        if (requested.len == 0 or !std.fs.path.isAbsolute(requested)) return error.PathOutsideWorkspace;
        const resolved = realPathAlloc(allocator, io, requested) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            // Only paths already under a root may learn whether they exist.
            else => return if (self.containsLexically(requested)) error.FileNotFound else error.PathOutsideWorkspace,
        };
        errdefer allocator.free(resolved);
        if (!self.containsLexically(resolved)) return error.PathOutsideWorkspace;
        return resolved;
    }

    fn containsLexically(self: Roots, path: []const u8) bool {
        for (self.paths) |root| {
            if (pathWithinRoot(path, root)) return true;
        }
        return false;
    }
};

/// Owned realpath of an absolute path. The std `*Alloc` variants return a
/// sentinel-terminated slice, which the caller could not free as `[]u8`.
fn realPathAlloc(allocator: std.mem.Allocator, io: std.Io, absolute_path: []const u8) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFileAbsolute(io, absolute_path, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn pathWithinRoot(path: []const u8, root: []const u8) bool {
    if (root.len == 0) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    if (root[root.len - 1] == '/') return true;
    return path[root.len] == '/';
}

/// Short-TTL cache of realpath-resolved workspace and repository roots.
pub const RootCache = struct {
    mutex: std.Io.Mutex = .init,
    roots: std.ArrayList([]u8) = .empty,
    fetched_at_ms: ?i64 = null,
    ttl_ms: i64 = ROOTS_TTL_MS,

    pub fn deinit(self: *RootCache, allocator: std.mem.Allocator) void {
        for (self.roots.items) |root| allocator.free(root);
        self.roots.deinit(allocator);
        self.* = undefined;
    }

    /// Returns an owned copy of the roots, refreshing through `lister` when the
    /// cached set is older than the TTL. `lister.list(cursor)` must return one
    /// owned `workspace.list` response envelope. A failed refresh keeps nothing:
    /// without a live daemon there is no authority for what may be served.
    pub fn snapshot(
        self: *RootCache,
        allocator: std.mem.Allocator,
        io: std.Io,
        now_ms: i64,
        lister: anytype,
    ) ![][]u8 {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const stale = if (self.fetched_at_ms) |at| now_ms - at >= self.ttl_ms or now_ms < at else true;
        if (stale) {
            var fresh = try fetchRoots(allocator, io, lister);
            defer {
                for (fresh.items) |root| allocator.free(root);
                fresh.deinit(allocator);
            }
            std.mem.swap(std.ArrayList([]u8), &self.roots, &fresh);
            self.fetched_at_ms = now_ms;
        }
        return try copyRoots(allocator, self.roots.items);
    }
};

fn copyRoots(allocator: std.mem.Allocator, roots: []const []u8) ![][]u8 {
    const copy = try allocator.alloc([]u8, roots.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |root| allocator.free(root);
        allocator.free(copy);
    }
    for (roots) |root| {
        copy[filled] = try allocator.dupe(u8, root);
        filled += 1;
    }
    return copy;
}

fn fetchRoots(allocator: std.mem.Allocator, io: std.Io, lister: anytype) !std.ArrayList([]u8) {
    var roots: std.ArrayList([]u8) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root);
        roots.deinit(allocator);
    }
    var cursor: ?[]u8 = null;
    defer if (cursor) |owned| allocator.free(owned);
    var pages: usize = 0;
    while (pages < MAX_LIST_PAGES) : (pages += 1) {
        const json = try lister.list(if (cursor) |owned| owned else null);
        defer allocator.free(json);
        const next = try collectRootsFromResponse(allocator, io, json, &roots);
        if (cursor) |owned| allocator.free(owned);
        cursor = next;
        if (cursor == null) return roots;
    }
    return error.WorkspaceListTooLong;
}

/// Appends every workspace `path` and repository binding `root_path` from one
/// `workspace.list` envelope, resolved with realpath. Roots that do not exist
/// on this host are skipped: nothing beneath them can be read anyway. Returns
/// the owned next cursor when the daemon has more pages.
fn collectRootsFromResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    json: []const u8,
    roots: *std.ArrayList([]u8),
) !?[]u8 {
    var parsed = try headless.parseResponse(allocator, json);
    defer parsed.deinit();
    if (!parsed.response.isOk()) return error.WorkspaceListFailed;
    const result = parsed.response.result orelse return error.WorkspaceListFailed;
    if (result != .object) return error.WorkspaceListFailed;
    const workspaces = result.object.get("workspaces") orelse return error.WorkspaceListFailed;
    if (workspaces != .array) return error.WorkspaceListFailed;
    for (workspaces.array.items) |workspace| {
        if (workspace != .object) continue;
        if (workspace.object.get("path")) |path| try appendRoot(allocator, io, roots, path);
        const repositories = workspace.object.get("repositories") orelse continue;
        if (repositories != .array) continue;
        for (repositories.array.items) |repository| {
            if (repository != .object) continue;
            const bindings = repository.object.get("bindings") orelse continue;
            if (bindings != .array) continue;
            for (bindings.array.items) |binding| {
                if (binding != .object) continue;
                if (binding.object.get("root_path")) |path| try appendRoot(allocator, io, roots, path);
            }
        }
    }
    const next_cursor = result.object.get("next_cursor") orelse return null;
    return switch (next_cursor) {
        .string => |cursor| if (cursor.len == 0) null else try allocator.dupe(u8, cursor),
        else => null,
    };
}

fn appendRoot(allocator: std.mem.Allocator, io: std.Io, roots: *std.ArrayList([]u8), value: std.json.Value) !void {
    if (value != .string) return;
    const path = value.string;
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return;
    const resolved = realPathAlloc(allocator, io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return,
    };
    errdefer allocator.free(resolved);
    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing, resolved)) {
            allocator.free(resolved);
            return;
        }
    }
    try roots.append(allocator, resolved);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestTree = struct {
    tmp: std.testing.TmpDir,
    base: []u8,

    fn init(allocator: std.mem.Allocator, io: std.Io) !TestTree {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(io, &buffer);
        return .{ .tmp = tmp, .base = try allocator.dupe(u8, buffer[0..len]) };
    }

    fn deinit(self: *TestTree, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        self.tmp.cleanup();
    }

    fn path(self: TestTree, allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.base, relative });
    }

    fn writeFile(self: TestTree, io: std.Io, relative: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = relative, .data = "%PDF-1.4\n" });
    }
};

fn testRoots(allocator: std.mem.Allocator, tree: TestTree, relatives: []const []const u8) !Roots {
    const paths = try allocator.alloc([]u8, relatives.len);
    var filled: usize = 0;
    errdefer {
        for (paths[0..filled]) |path| allocator.free(path);
        allocator.free(paths);
    }
    for (relatives) |relative| {
        paths[filled] = try tree.path(allocator, relative);
        filled += 1;
    }
    return .{ .paths = paths };
}

test "confinement accepts files inside a registered root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "a/b/docs");
    try tree.writeFile(io, "a/b/docs/report.pdf");

    const roots = try testRoots(allocator, tree, &.{"a/b"});
    defer roots.deinit(allocator);

    const inside = try tree.path(allocator, "a/b/docs/report.pdf");
    defer allocator.free(inside);
    const resolved = try roots.confine(allocator, io, inside);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(inside, resolved);

    const missing = try tree.path(allocator, "a/b/docs/absent.pdf");
    defer allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, roots.confine(allocator, io, missing));
}

test "confinement rejects dot-dot traversal that leaves the root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "a/b");
    try tree.writeFile(io, "a/secret.pdf");

    const roots = try testRoots(allocator, tree, &.{"a/b"});
    defer roots.deinit(allocator);

    const traversal = try tree.path(allocator, "a/b/../secret.pdf");
    defer allocator.free(traversal);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, traversal));
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, "a/b/relative.pdf"));
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, ""));
}

test "confinement rejects a symlink that escapes the root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "a/b");
    try tree.tmp.dir.createDirPath(io, "outside");
    try tree.writeFile(io, "outside/secret.pdf");
    const target = try tree.path(allocator, "outside/secret.pdf");
    defer allocator.free(target);
    try tree.tmp.dir.symLink(io, target, "a/b/escape.pdf", .{});
    const dir_target = try tree.path(allocator, "outside");
    defer allocator.free(dir_target);
    try tree.tmp.dir.symLink(io, dir_target, "a/b/escape-dir", .{});

    const roots = try testRoots(allocator, tree, &.{"a/b"});
    defer roots.deinit(allocator);

    const file_link = try tree.path(allocator, "a/b/escape.pdf");
    defer allocator.free(file_link);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, file_link));

    const dir_link = try tree.path(allocator, "a/b/escape-dir/secret.pdf");
    defer allocator.free(dir_link);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, dir_link));
}

test "confinement rejects sibling-prefix roots and unrelated paths" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "a/b");
    try tree.tmp.dir.createDirPath(io, "a/bc");
    try tree.tmp.dir.createDirPath(io, "elsewhere");
    try tree.writeFile(io, "a/bc/report.pdf");
    try tree.writeFile(io, "elsewhere/report.pdf");
    try tree.writeFile(io, "a/b.pdf");

    const roots = try testRoots(allocator, tree, &.{"a/b"});
    defer roots.deinit(allocator);

    const sibling = try tree.path(allocator, "a/bc/report.pdf");
    defer allocator.free(sibling);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, sibling));

    const sibling_file = try tree.path(allocator, "a/b.pdf");
    defer allocator.free(sibling_file);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, sibling_file));

    const outside = try tree.path(allocator, "elsewhere/report.pdf");
    defer allocator.free(outside);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, outside));

    // A missing file outside every root is indistinguishable from an existing one.
    const outside_missing = try tree.path(allocator, "elsewhere/absent.pdf");
    defer allocator.free(outside_missing);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.confine(allocator, io, outside_missing));

    try std.testing.expect(pathWithinRoot("/a/b/c", "/a/b"));
    try std.testing.expect(pathWithinRoot("/a/b", "/a/b"));
    try std.testing.expect(pathWithinRoot("/a/b", "/"));
    try std.testing.expect(!pathWithinRoot("/a/bc", "/a/b"));
    try std.testing.expect(!pathWithinRoot("/a", "/a/b"));
    try std.testing.expect(!pathWithinRoot("/a/b", ""));
}

const FixtureLister = struct {
    allocator: std.mem.Allocator,
    pages: []const []const u8,
    calls: usize = 0,

    fn list(self: *FixtureLister, cursor: ?[]const u8) ![]u8 {
        const index: usize = if (cursor) |value| try std.fmt.parseInt(usize, value, 10) else 0;
        self.calls += 1;
        return self.allocator.dupe(u8, self.pages[index]);
    }
};

test "root cache collects workspace paths and repository bindings across pages" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "ws-one");
    try tree.tmp.dir.createDirPath(io, "checkout");
    try tree.tmp.dir.createDirPath(io, "ws-two");
    try tree.tmp.dir.symLink(io, "ws-two", "ws-two-link", .{});

    const ws_one = try tree.path(allocator, "ws-one");
    defer allocator.free(ws_one);
    const checkout = try tree.path(allocator, "checkout");
    defer allocator.free(checkout);
    const ws_two = try tree.path(allocator, "ws-two");
    defer allocator.free(ws_two);
    const ws_two_link = try tree.path(allocator, "ws-two-link");
    defer allocator.free(ws_two_link);
    const missing = try tree.path(allocator, "missing");
    defer allocator.free(missing);

    const page_one = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"workspaces\":[{{\"workspace_id\":\"w1\",\"label\":\"one\",\"path\":\"{s}\",\"repositories\":[{{\"repository_id\":\"primary\",\"label\":\"one\",\"bindings\":[{{\"runtime_id\":\"r\",\"root_path\":\"{s}\"}},{{\"runtime_id\":\"r\",\"root_path\":\"{s}\"}}]}}]}}],\"next_cursor\":\"1\",\"store_revision\":3}}}}",
        .{ ws_one, checkout, missing },
    );
    defer allocator.free(page_one);
    const page_two = try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{\"workspaces\":[{{\"workspace_id\":\"w2\",\"label\":\"two\",\"path\":\"{s}\"}},{{\"workspace_id\":\"w3\",\"label\":\"dup\",\"path\":\"{s}\"}}],\"next_cursor\":null,\"store_revision\":3}}}}",
        .{ ws_two_link, ws_one },
    );
    defer allocator.free(page_two);

    var lister: FixtureLister = .{ .allocator = allocator, .pages = &.{ page_one, page_two } };
    var cache: RootCache = .{ .ttl_ms = 1_000 };
    defer cache.deinit(allocator);

    const first = try cache.snapshot(allocator, io, 10_000, &lister);
    defer {
        for (first) |root| allocator.free(root);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 2), lister.calls);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqualStrings(ws_one, first[0]);
    try std.testing.expectEqualStrings(checkout, first[1]);
    // A symlinked workspace path is stored resolved so files beneath it match.
    try std.testing.expectEqualStrings(ws_two, first[2]);

    const cached = try cache.snapshot(allocator, io, 10_999, &lister);
    defer {
        for (cached) |root| allocator.free(root);
        allocator.free(cached);
    }
    try std.testing.expectEqual(@as(usize, 2), lister.calls);
    try std.testing.expectEqual(@as(usize, 3), cached.len);

    const refreshed = try cache.snapshot(allocator, io, 11_000, &lister);
    defer {
        for (refreshed) |root| allocator.free(root);
        allocator.free(refreshed);
    }
    try std.testing.expectEqual(@as(usize, 4), lister.calls);
    try std.testing.expectEqual(@as(usize, 3), refreshed.len);
}

test "root cache refuses to serve when the daemon list fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const failure = try headless.protocol.encodeErrorResponse(allocator, 1, "unavailable", "daemon offline");
    defer allocator.free(failure);
    var lister: FixtureLister = .{ .allocator = allocator, .pages = &.{failure} };
    var cache: RootCache = .{};
    defer cache.deinit(allocator);
    try std.testing.expectError(error.WorkspaceListFailed, cache.snapshot(allocator, io, 0, &lister));
    try std.testing.expectEqual(@as(usize, 1), lister.calls);
}
