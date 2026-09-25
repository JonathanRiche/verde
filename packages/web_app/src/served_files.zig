//! Confines `/api/file` and `/api/preview` to registered workspace roots.
//!
//! A chat citation can name any absolute path, and a paired phone only needs
//! `repository:read` to follow it. Before the gateway reads a document it
//! opens the request beneath a held directory descriptor for a
//! workspace path or repository binding root reported by the daemon. Roots are
//! cached briefly so a burst of citation clicks does not page `workspace.list`
//! on every request.

const std = @import("std");
const builtin = @import("builtin");
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

    /// Open beneath a registered root. The kernel resolves relative symlinks
    /// while enforcing confinement; the returned descriptor is the authority.
    pub fn open(self: Roots, allocator: std.mem.Allocator, io: std.Io, requested: []const u8) ConfineError!std.Io.File {
        if (requested.len == 0 or !std.fs.path.isAbsolute(requested) or
            std.mem.indexOfScalar(u8, requested, 0) != null) return error.PathOutsideWorkspace;
        for (self.paths) |root| {
            if (!pathWithinRoot(requested, root)) continue;
            // Cached roots are canonical absolute paths. Refuse symlink swaps
            // in any component of the root itself as well as its final name.
            const base = try openRoot(io, root);
            defer base.close(io);
            const relative = std.mem.trimStart(u8, requested[root.len..], "/");
            const file = try openBeneath(allocator, io, base, if (relative.len == 0) "." else relative);
            errdefer file.close(io);
            const stat = file.stat(io) catch return error.PathOutsideWorkspace;
            if (stat.kind != .file) return error.PathOutsideWorkspace;
            return file;
        }
        return error.PathOutsideWorkspace;
    }

    /// Compatibility helper for path-only callers. Reading must use `open`
    /// and retain its descriptor, never reopen this diagnostic path.
    pub fn confine(self: Roots, allocator: std.mem.Allocator, io: std.Io, requested: []const u8) ConfineError![]u8 {
        const file = try self.open(allocator, io, requested);
        defer file.close(io);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = file.realPath(io, &buffer) catch return error.PathOutsideWorkspace;
        if (!self.containsLexically(buffer[0..len])) return error.PathOutsideWorkspace;
        return allocator.dupe(u8, buffer[0..len]);
    }

    fn containsLexically(self: Roots, path: []const u8) bool {
        for (self.paths) |root| {
            if (pathWithinRoot(path, root)) return true;
        }
        return false;
    }
};

fn openRoot(io: std.Io, path: []const u8) ConfineError!std.Io.Dir {
    var dir = std.Io.Dir.openDirAbsolute(io, "/", .{}) catch return error.PathOutsideWorkspace;
    errdefer dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathOutsideWorkspace;
        const next = dir.openDir(io, part, .{ .follow_symlinks = false }) catch return error.PathOutsideWorkspace;
        dir.close(io);
        dir = next;
    }
    return dir;
}

fn openBeneath(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, relative: []const u8) ConfineError!std.Io.File {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const path_z = try allocator.dupeZ(u8, relative);
        defer allocator.free(path_z);
        // Linux open_how ABI. std has no openat2 wrapper yet.
        const RESOLVE_BENEATH: u64 = 0x08;
        const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
        const How = extern struct { flags: u64, mode: u64 = 0, resolve: u64 = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS };
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true };
        const how: How = .{ .flags = @as(u32, @bitCast(flags)) };
        while (true) {
            const rc = linux.syscall4(.openat2, @bitCast(@as(isize, root.handle)), @intFromPtr(path_z.ptr), @intFromPtr(&how), @sizeOf(How));
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .handle = @intCast(rc), .flags = .{ .nonblocking = true } },
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .NOSYS => break, // Old kernels use the conservative walk below.
                else => return error.PathOutsideWorkspace,
            }
        }
    }
    return openNoFollow(io, root, relative);
}

// Portable POSIX fallback: each component is opened relative to the previous
// descriptor. Symlinks and parent traversal are conservatively rejected.
fn openNoFollow(io: std.Io, root: std.Io.Dir, relative: []const u8) ConfineError!std.Io.File {
    var dir = root;
    defer if (dir.handle != root.handle) dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathOutsideWorkspace;
        const last = parts.peek() == null;
        const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true, .NOFOLLOW = true, .DIRECTORY = !last };
        const fd = std.posix.openat(dir.handle, part, flags, 0) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.PathOutsideWorkspace,
        };
        if (last) return .{ .handle = fd, .flags = .{ .nonblocking = true } };
        if (dir.handle != root.handle) dir.close(io);
        dir = .{ .handle = fd };
    }
    return error.PathOutsideWorkspace;
}

/// Read only the already-authorized descriptor, with a hard allocation limit.
pub fn readAlloc(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, limit: usize) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

/// Cache files must be regular and must not follow symlinks, even on Linux.
pub fn openCacheFile(io: std.Io, path: []const u8) ConfineError!std.Io.File {
    const parent = try openRoot(io, std.fs.path.dirname(path) orelse return error.PathOutsideWorkspace);
    defer parent.close(io);
    const file = try openNoFollow(io, parent, std.fs.path.basename(path));
    errdefer file.close(io);
    const stat = file.stat(io) catch return error.PathOutsideWorkspace;
    if (stat.kind != .file) return error.PathOutsideWorkspace;
    return file;
}

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

/// Appends workspace `path` and available, serving-runtime binding `root_path` from one
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
    const runtime_id = result.object.get("runtime_id") orelse .null;
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
                const binding_runtime = binding.object.get("runtime_id") orelse continue;
                const availability = binding.object.get("availability") orelse continue;
                if (runtime_id != .string or runtime_id.string.len == 0 or binding_runtime != .string) continue;
                if (!std.mem.eql(u8, runtime_id.string, binding_runtime.string)) continue;
                if (availability != .string or !std.mem.eql(u8, availability.string, "available")) continue;
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
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"runtime_id\":\"r\",\"workspaces\":[{{\"workspace_id\":\"w1\",\"label\":\"one\",\"path\":\"{s}\",\"repositories\":[{{\"repository_id\":\"primary\",\"label\":\"one\",\"bindings\":[{{\"runtime_id\":\"r\",\"availability\":\"available\",\"root_path\":\"{s}\"}},{{\"runtime_id\":\"r\",\"availability\":\"available\",\"root_path\":\"{s}\"}}]}}]}}],\"next_cursor\":\"1\",\"store_revision\":3}}}}",
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

test "descriptor confinement survives file and ancestor swaps and rejects dangling escapes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "root/docs");
    try tree.tmp.dir.createDirPath(io, "outside");
    try tree.writeFile(io, "root/docs/report.pdf");
    try tree.tmp.dir.writeFile(io, .{ .sub_path = "outside/report.pdf", .data = "secret" });
    const roots = try testRoots(allocator, tree, &.{"root"});
    defer roots.deinit(allocator);
    const requested = try tree.path(allocator, "root/docs/report.pdf");
    defer allocator.free(requested);
    const checked = try roots.confine(allocator, io, requested);
    defer allocator.free(checked);
    const held = try roots.open(allocator, io, requested);
    defer held.close(io);
    try tree.tmp.dir.deleteFile(io, "root/docs/report.pdf");
    try tree.tmp.dir.symLink(io, "../../outside/report.pdf", "root/docs/report.pdf", .{});
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, checked));
    const bytes = try readAlloc(allocator, io, held, 100);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("%PDF-1.4\n", bytes);

    // A relative escaping link must be forbidden even if its target is absent.
    try tree.tmp.dir.deleteFile(io, "outside/report.pdf");
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, requested));
    try tree.tmp.dir.deleteTree(io, "root/docs");
    try tree.tmp.dir.symLink(io, "../outside", "root/docs", .{});
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, requested));
    try tree.tmp.dir.deleteTree(io, "outside");
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, requested));

    // Root components themselves may not be replaced by symlinks either.
    try tree.tmp.dir.deleteTree(io, "root");
    try tree.tmp.dir.symLink(io, "outside", "root", .{});
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, requested));
}

test "in-root relative symlinks remain readable on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "root/docs");
    try tree.writeFile(io, "root/docs/report.pdf");
    try tree.tmp.dir.symLink(io, "docs/report.pdf", "root/link.pdf", .{});
    const roots = try testRoots(allocator, tree, &.{"root"});
    defer roots.deinit(allocator);
    const requested = try tree.path(allocator, "root/link.pdf");
    defer allocator.free(requested);
    const file = try roots.open(allocator, io, requested);
    defer file.close(io);
    const bytes = try readAlloc(allocator, io, file, 100);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("%PDF-1.4\n", bytes);
}

test "directories and FIFO documents are rejected within a finite deadline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.tmp.dir.createDirPath(io, "root/directory.pdf");
    const roots = try testRoots(allocator, tree, &.{"root"});
    defer roots.deinit(allocator);
    const directory = try tree.path(allocator, "root/directory.pdf");
    defer allocator.free(directory);
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, directory));
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknodat(tree.tmp.dir.handle, "root/fifo.pdf", 0o010600, 0)));
    const fifo = try tree.path(allocator, "root/fifo.pdf");
    defer allocator.free(fifo);

    // If NONBLOCK regresses, supply a writer after the deadline to unblock
    // open, fail the test, and join deterministically rather than hanging CI.
    const Watchdog = struct {
        io: std.Io,
        dir: std.Io.Dir,
        done: std.atomic.Value(u32) = .init(0),
        expired: std.atomic.Value(bool) = .init(false),
        writer: ?std.Io.File = null,
        fn run(self: *@This()) void {
            const deadline = std.Io.Clock.awake.now(self.io).toMilliseconds() + 1000;
            while (self.done.load(.acquire) == 0) {
                if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= deadline) {
                    self.expired.store(true, .release);
                    const fd = std.posix.openat(self.dir.handle, "root/fifo.pdf", .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0) catch return;
                    self.writer = .{ .handle = fd, .flags = .{ .nonblocking = true } };
                    return;
                }
                self.io.futexWaitTimeout(u32, &self.done.raw, 0, .{ .duration = .{ .raw = .fromMilliseconds(20), .clock = .awake } }) catch return;
            }
        }
    };
    var watchdog: Watchdog = .{ .io = io, .dir = tree.tmp.dir };
    const thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.done.store(1, .release);
        io.futexWake(u32, &watchdog.done.raw, 1);
        thread.join();
        if (watchdog.writer) |writer| writer.close(io);
    }
    try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, fifo));
    try std.testing.expect(!watchdog.expired.load(.acquire));
}

test "preview cache opens reject symlinks and directories" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    try tree.writeFile(io, "regular.pdf");
    try tree.tmp.dir.symLink(io, "regular.pdf", "link.pdf", .{});
    try tree.tmp.dir.createDir(io, "directory.pdf", .default_dir);
    const regular = try tree.path(allocator, "regular.pdf");
    defer allocator.free(regular);
    const file = try openCacheFile(io, regular);
    file.close(io);
    for ([_][]const u8{ "link.pdf", "directory.pdf" }) |name| {
        const path = try tree.path(allocator, name);
        defer allocator.free(path);
        try std.testing.expectError(error.PathOutsideWorkspace, openCacheFile(io, path));
    }
}

test "root cache serves secondary checkout from workspace list DTO and rejects foreign bindings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tree = try TestTree.init(allocator, io);
    defer tree.deinit(allocator);
    var paths: [5][]u8 = undefined;
    var filled: usize = 0;
    defer for (paths[0..filled]) |path| allocator.free(path);
    for ([_][]const u8{ "primary", "secondary", "remote", "missing", "outside" }, 0..) |name, i| {
        try tree.tmp.dir.createDirPath(io, name);
        paths[i] = try tree.path(allocator, name);
        filled += 1;
        const document = try std.fs.path.join(allocator, &.{ name, "report.pdf" });
        defer allocator.free(document);
        try tree.writeFile(io, document);
    }
    // Serialize the same typed result as the daemon's workspace.list handler.
    const result: headless.store_protocol.WorkspaceListResult = .{
        .runtime_id = "0123456789abcdef0123456789abcdef",
        .workspaces = &.{.{
            .workspace_id = "two-repos",
            .label = "Two repositories",
            .path = paths[0],
            .default_repository_id = "secondary",
            .repositories = &.{
                .{ .repository_id = "primary", .label = "Primary", .bindings = &.{
                    .{ .runtime_id = "0123456789abcdef0123456789abcdef", .root_path = paths[0] },
                } },
                .{ .repository_id = "secondary", .label = "Secondary", .bindings = &.{
                    .{ .runtime_id = "0123456789abcdef0123456789abcdef", .root_path = paths[1] },
                    .{ .runtime_id = "fedcba9876543210fedcba9876543210", .root_path = paths[2] },
                } },
                .{ .repository_id = "unavailable", .label = "Unavailable", .bindings = &.{
                    .{ .runtime_id = "0123456789abcdef0123456789abcdef", .root_path = paths[3], .availability = "missing" },
                } },
            },
        }},
    };
    const response = try headless.protocol.encodeOkResponse(allocator, 1, result);
    defer allocator.free(response);
    var lister: FixtureLister = .{ .allocator = allocator, .pages = &.{response} };
    var cache: RootCache = .{};
    defer cache.deinit(allocator);
    const roots: Roots = .{ .paths = try cache.snapshot(allocator, io, 0, &lister) };
    defer roots.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), roots.paths.len);
    for (paths, 0..) |path, i| {
        const document = try std.fs.path.join(allocator, &.{ path, "report.pdf" });
        defer allocator.free(document);
        if (i < 2) {
            const file = try roots.open(allocator, io, document);
            defer file.close(io);
            const bytes = try readAlloc(allocator, io, file, 100);
            defer allocator.free(bytes);
            try std.testing.expectEqualStrings("%PDF-1.4\n", bytes);
        } else {
            // handleWorkspaceFile maps this confinement error to HTTP 403.
            try std.testing.expectError(error.PathOutsideWorkspace, roots.open(allocator, io, document));
        }
    }
}
