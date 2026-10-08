//! Daemon side of `workspace.files.list` / `workspace.files.read` (see
//! headless workspace_files_protocol.zig). Clients address `(root id,
//! root-relative path)`; everything is opened beneath the root's descriptor
//! (openat2 RESOLVE_BENEATH on Linux, a no-follow component walk elsewhere),
//! so client paths and symlinks never escape. All returned strings belong to
//! the caller's arena.

const std = @import("std");
const builtin = @import("builtin");
const headless = @import("headless");
const directory_browser = @import("directory_browser.zig");
const git_changes = @import("git_changes.zig");
const workspace_folders = @import("../workspace/folders.zig");

const proto = headless.workspace_files_protocol;

pub const Error = std.mem.Allocator.Error || error{ InvalidPath, RootNotFound, PathOutsideRoots, FileNotFound, NotDir, NotFile };

/// Workspace home first (id `home`), then enabled `verde.toml` folders (id =
/// folder name). A broken config still yields the home so the explorer never
/// goes blank.
pub fn rootsFor(arena: std.mem.Allocator, io: std.Io, home: []const u8) ![]const proto.Root {
    var roots: std.ArrayList(proto.Root) = .empty;
    if (workspace_folders.resolve(arena, home)) |resolved| {
        try roots.append(arena, .{ .id = proto.HOME_ROOT_ID, .name = std.fs.path.basename(resolved.home), .path = resolved.home });
        for (resolved.folders) |folder| {
            const duplicate = for (roots.items) |existing| {
                if (std.mem.eql(u8, existing.path, folder.path) or std.mem.eql(u8, existing.id, folder.name)) break true;
            } else false;
            if (!duplicate) try roots.append(arena, .{ .id = folder.name, .name = folder.name, .path = folder.path });
        }
    } else |_| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.realPathFileAbsolute(io, home, &buffer) catch return roots.items;
        const real = try arena.dupe(u8, buffer[0..len]);
        try roots.append(arena, .{ .id = proto.HOME_ROOT_ID, .name = std.fs.path.basename(real), .path = real });
    }
    return roots.items;
}

const Located = struct {
    root: proto.Root,
    base: std.Io.Dir,
    /// Normalised root-relative path ("" for the root itself).
    path: []const u8,

    /// Path for openat-style calls ("." for the root).
    fn relative(self: Located) []const u8 {
        return if (self.path.len == 0) "." else self.path;
    }
};

fn locate(arena: std.mem.Allocator, io: std.Io, roots: []const proto.Root, root_id: []const u8, requested: []const u8) Error!Located {
    const path = (try proto.normalizeRelative(arena, requested)) orelse return error.InvalidPath;
    const root = for (roots) |root| {
        if (std.mem.eql(u8, root.id, root_id)) break root;
    } else return error.RootNotFound;
    const base = directory_browser.openRoot(io, root.path) catch return error.RootNotFound;
    return .{ .root = root, .base = base, .path = path };
}

/// Opens `relative` beneath `root`. `directory` selects O_DIRECTORY; files
/// open non-blocking so a FIFO never stalls a worker.
fn openBeneath(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, relative: []const u8, directory: bool) Error!std.posix.fd_t {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const path_z = try allocator.dupeZ(u8, relative);
        defer allocator.free(path_z);
        const How = extern struct { flags: u64, mode: u64 = 0, resolve: u64 = 0x08 | 0x02 };
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true, .DIRECTORY = directory };
        const how: How = .{ .flags = @as(u32, @bitCast(flags)) };
        while (true) {
            const rc = linux.syscall4(.openat2, @bitCast(@as(isize, root.handle)), @intFromPtr(path_z.ptr), @intFromPtr(&how), @sizeOf(How));
            switch (linux.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .NOSYS => break,
                else => return error.PathOutsideRoots,
            }
        }
    }
    var dir = root;
    defer if (dir.handle != root.handle) dir.close(io);
    var parts = std.mem.tokenizeScalar(u8, relative, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathOutsideRoots;
        if (std.mem.eql(u8, part, ".")) continue;
        const last = parts.peek() == null;
        if (last and !directory) {
            const file = dir.openFile(io, part, .{ .follow_symlinks = false }) catch |err| return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.PathOutsideRoots,
            };
            return file.handle;
        }
        const next = dir.openDir(io, part, .{ .iterate = true, .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => error.FileNotFound,
            error.NotDir => error.NotDir,
            else => error.PathOutsideRoots,
        };
        if (dir.handle != root.handle) dir.close(io);
        dir = next;
    }
    if (!directory) return error.NotFile;
    if (dir.handle == root.handle) {
        const again = root.openDir(io, ".", .{ .iterate = true }) catch return error.PathOutsideRoots;
        return again.handle;
    }
    const result = dir.handle;
    dir = root;
    return result;
}

fn lessThan(_: void, a: proto.Entry, b: proto.Entry) bool {
    if (a.kind != b.kind) return a.kind == .directory;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Lists one directory beneath a root (at most `limit` entries, clamped).
/// Symlinks appear only when they resolve beneath the same root; special
/// files are skipped.
pub fn list(arena: std.mem.Allocator, io: std.Io, roots: []const proto.Root, root_id: []const u8, requested: []const u8, limit: ?u32) Error!proto.ListResult {
    const located = try locate(arena, io, roots, root_id, requested);
    defer located.base.close(io);
    const cap: usize = @min(@max(limit orelse proto.DEFAULT_LIST_ENTRIES, 1), proto.MAX_LIST_ENTRIES);
    const dir: std.Io.Dir = .{ .handle = try openBeneath(arena, io, located.base, located.relative(), true) };
    defer dir.close(io);

    var entries: std.ArrayList(proto.Entry) = .empty;
    var truncated = false;
    var iterator = dir.iterate();
    while (iterator.next(io) catch return error.PathOutsideRoots) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        if (!std.unicode.utf8ValidateSlice(entry.name)) continue;
        if (entries.items.len >= cap) {
            truncated = true;
            break;
        }
        var item: proto.Entry = .{ .name = "", .path = "", .kind = .file };
        switch (entry.kind) {
            .directory => item.kind = .directory,
            .file => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                item.size = stat.size;
            },
            .sym_link => {
                item.symlink = true;
                const child_relative = try std.fs.path.join(arena, &.{ located.relative(), entry.name });
                if (openBeneath(arena, io, located.base, child_relative, true)) |fd| {
                    (std.Io.Dir{ .handle = fd }).close(io);
                    item.kind = .directory;
                } else |dir_err| {
                    if (dir_err == error.OutOfMemory) return error.OutOfMemory;
                    const fd = openBeneath(arena, io, located.base, child_relative, false) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
                    defer file.close(io);
                    const stat = file.stat(io) catch continue;
                    if (stat.kind != .file) continue;
                    item.size = stat.size;
                }
            },
            else => continue,
        }
        item.name = try arena.dupe(u8, entry.name);
        item.path = if (located.path.len == 0) item.name else try std.fs.path.join(arena, &.{ located.path, entry.name });
        try entries.append(arena, item);
    }
    std.mem.sort(proto.Entry, entries.items, {}, lessThan);
    const absolute = if (located.path.len == 0) located.root.path else try std.fs.path.join(arena, &.{ located.root.path, located.path });
    try markIgnored(arena, absolute, entries.items);
    return .{ .roots = roots, .root = located.root.id, .path = located.path, .entries = entries.items, .truncated = truncated };
}

/// Marks entries matched by the repository's ignore rules with one
/// `git check-ignore` per batch. Not a repository / no git: nothing ignored.
/// Output is newline-separated (`-z` needs `--stdin`); names git must quote
/// (tabs, quotes, newlines) simply stay undimmed.
fn markIgnored(arena: std.mem.Allocator, directory: []const u8, entries: []proto.Entry) !void {
    if (entries.len == 0) return;
    var git = git_changes.Git.init(arena) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer git.deinit();
    // check-ignore rejects the `literal` pathspec magic; arguments are plain
    // child names and the output echoes them, so matching stays exact.
    _ = git.env.swapRemove("GIT_LITERAL_PATHSPECS");
    const BATCH: usize = 256;
    var start: usize = 0;
    while (start < entries.len) : (start += BATCH) {
        const batch = entries[start..@min(start + BATCH, entries.len)];
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(arena, &.{ "check-ignore", "--" });
        // Directory-only patterns (`build/`) need the trailing slash.
        // Symlinks must stay slash-free: git refuses `link/` as "beyond a
        // symbolic link" and fails the whole batch.
        for (batch) |entry| try args.append(arena, if (entry.kind == .directory and !entry.symlink) try std.mem.concat(arena, u8, &.{ entry.name, "/" }) else entry.name);
        const result = git.run(directory, args.items, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        // 0: some ignored, 1: none, 128: not a repository or fatal.
        if (result.exit_code == null or result.exit_code.? != 0) {
            if (result.exit_code != null and result.exit_code.? == 1) continue;
            return;
        }
        var names = std.mem.splitScalar(u8, result.stdout, '\n');
        while (names.next()) |raw| {
            const name = std.mem.trimEnd(u8, raw, "/");
            if (name.len == 0) continue;
            for (batch) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) entry.ignored = true;
            }
        }
    }
}

pub const ReadLimits = struct {
    max_bytes: ?u64 = null,
    max_image_bytes: ?u64 = null,
};

/// Reads a regular file beneath a root for preview. Text is capped at
/// `max_bytes` on a codepoint boundary; images up to `max_image_bytes` are
/// base64; other kinds carry metadata only.
pub fn read(arena: std.mem.Allocator, io: std.Io, roots: []const proto.Root, root_id: []const u8, requested: []const u8, limits: ReadLimits) Error!proto.ReadResult {
    const located = try locate(arena, io, roots, root_id, requested);
    defer located.base.close(io);
    if (located.path.len == 0) return error.NotFile;
    const fd = openBeneath(arena, io, located.base, located.path, false) catch |err| return switch (err) {
        error.NotDir => error.FileNotFound,
        else => err,
    };
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = file.stat(io) catch return error.FileNotFound;
    if (stat.kind != .file) return error.NotFile;

    var result: proto.ReadResult = .{
        .root = located.root.id,
        .path = located.path,
        .name = std.fs.path.basename(located.path),
        .size = stat.size,
        .kind = proto.kindForPath(located.path),
        .mime = proto.mimeForPath(located.path),
    };
    switch (result.kind) {
        .external, .binary, .too_large => return result,
        .image => {
            if (stat.size > @min(limits.max_image_bytes orelse proto.DEFAULT_IMAGE_BYTES, proto.MAX_IMAGE_BYTES)) {
                result.kind = .too_large;
                return result;
            }
            const bytes = try readPrefix(arena, io, file, stat.size);
            const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            result.content = std.base64.standard.Encoder.encode(encoded, bytes);
            result.encoding = .base64;
            return result;
        },
        .text, .markdown => {
            const cap = @min(limits.max_bytes orelse proto.DEFAULT_TEXT_BYTES, proto.MAX_TEXT_BYTES);
            const bytes = try readPrefix(arena, io, file, @min(stat.size, cap));
            result.truncated = stat.size > bytes.len;
            const text = if (result.truncated) proto.utf8Prefix(bytes) else bytes;
            if (!proto.looksTextual(text) or !std.unicode.utf8ValidateSlice(text)) {
                result.kind = .binary;
                result.mime = null;
                result.truncated = false;
                return result;
            }
            result.content = text;
            result.encoding = .utf8;
            if (result.mime == null) result.mime = "text/plain";
            return result;
        },
    }
}

fn readPrefix(arena: std.mem.Allocator, io: std.Io, file: std.Io.File, len: u64) Error![]const u8 {
    const buffer = try arena.alloc(u8, @intCast(len));
    const got = file.readPositionalAll(io, buffer, 0) catch return error.FileNotFound;
    return buffer[0..got];
}

// ---------------------------------------------------------------------------
// Tests

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    base: []const u8,
    root: []const u8,

    fn init() !TestFixture {
        var fixture: TestFixture = .{ .tmp = std.testing.tmpDir(.{}), .arena_state = .init(std.testing.allocator), .base = "", .root = "" };
        errdefer fixture.deinit();
        const io = std.testing.io;
        const a = fixture.arena_state.allocator();
        try fixture.tmp.dir.createDirPath(io, "root/src/nested");
        try fixture.tmp.dir.createDirPath(io, "root/.git");
        try fixture.tmp.dir.createDirPath(io, "root/Zeta");
        try fixture.tmp.dir.createDirPath(io, "outside");
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "root/b.txt", .data = "hello\n" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "root/A.md", .data = "# Title\n" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "root/src/main.zig", .data = "const x = 1;\n" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "secret" });
        try fixture.tmp.dir.symLink(io, "src", "root/src-link", .{ .is_directory = true });
        try fixture.tmp.dir.symLink(io, "b.txt", "root/b-link.txt", .{});
        try fixture.tmp.dir.symLink(io, "../outside", "root/escape", .{ .is_directory = true });
        try fixture.tmp.dir.symLink(io, "../outside/secret.txt", "root/escape.txt", .{});
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try fixture.tmp.dir.realPath(io, &buffer);
        fixture.base = try a.dupe(u8, buffer[0..len]);
        fixture.root = try std.fs.path.join(a, &.{ fixture.base, "root" });
        return fixture;
    }

    fn deinit(self: *TestFixture) void {
        self.arena_state.deinit();
        self.tmp.cleanup();
    }

    fn roots(self: *TestFixture) []const proto.Root {
        const a = self.arena_state.allocator();
        const items = a.alloc(proto.Root, 1) catch unreachable;
        items[0] = .{ .id = "home", .name = "root", .path = self.root };
        return items;
    }
};

test "files list sorts folders first, hides .git and confines symlinks" {
    var f = try TestFixture.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const io = std.testing.io;
    const result = try list(a, io, f.roots(), "home", "", null);
    var names: std.ArrayList(u8) = .empty;
    for (result.entries) |entry| {
        try names.appendSlice(a, entry.name);
        if (entry.kind == .directory) try names.append(a, '/');
        try names.append(a, ' ');
    }
    try std.testing.expectEqualStrings("src/ src-link/ Zeta/ A.md b-link.txt b.txt ", names.items);
    try std.testing.expectEqualStrings("home", result.root.?);
    try std.testing.expectEqualStrings("", result.path.?);
    try std.testing.expectEqualStrings("src", result.entries[0].path);
    try std.testing.expect(result.entries[1].symlink);
    try std.testing.expectEqual(@as(u64, 6), result.entries[5].size);
    try std.testing.expectEqual(@as(u64, 6), result.entries[4].size);

    const nested = try list(a, io, f.roots(), "home", "./src-link/", null);
    try std.testing.expectEqual(@as(usize, 2), nested.entries.len);
    try std.testing.expectEqualStrings("src-link", nested.path.?);
    try std.testing.expectEqualStrings("src-link/nested", nested.entries[0].path);

    const capped = try list(a, io, f.roots(), "home", "", 2);
    try std.testing.expectEqual(@as(usize, 2), capped.entries.len);
    try std.testing.expect(capped.truncated);

    try std.testing.expectError(error.PathOutsideRoots, list(a, io, f.roots(), "home", "escape", null));
    try std.testing.expectError(error.InvalidPath, list(a, io, f.roots(), "home", "../outside", null));
    try std.testing.expectError(error.InvalidPath, list(a, io, f.roots(), "home", f.base, null));
    try std.testing.expectError(error.RootNotFound, list(a, io, f.roots(), "nope", "", null));
    try std.testing.expectError(error.FileNotFound, list(a, io, f.roots(), "home", "missing", null));
    try std.testing.expectError(error.NotDir, list(a, io, f.roots(), "home", "b.txt", null));
}

test "files read classifies, caps and confines" {
    var f = try TestFixture.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const io = std.testing.io;
    const text = try read(a, io, f.roots(), "home", "src/main.zig", .{});
    try std.testing.expectEqual(proto.ContentKind.text, text.kind);
    try std.testing.expectEqualStrings("const x = 1;\n", text.content);
    try std.testing.expectEqualStrings("src/main.zig", text.path);
    try std.testing.expectEqualStrings("main.zig", text.name);
    try std.testing.expect(!text.truncated);

    const markdown = try read(a, io, f.roots(), "home", "A.md", .{});
    try std.testing.expectEqual(proto.ContentKind.markdown, markdown.kind);

    const capped = try read(a, io, f.roots(), "home", "b.txt", .{ .max_bytes = 3 });
    try std.testing.expectEqualStrings("hel", capped.content);
    try std.testing.expect(capped.truncated);
    try std.testing.expectEqual(@as(u64, 6), capped.size);

    const linked = try read(a, io, f.roots(), "home", "b-link.txt", .{});
    try std.testing.expectEqualStrings("hello\n", linked.content);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/blob.dat", .data = "ab\x00cd" });
    const blob = try read(a, io, f.roots(), "home", "blob.dat", .{});
    try std.testing.expectEqual(proto.ContentKind.binary, blob.kind);
    try std.testing.expectEqualStrings("", blob.content);

    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/pic.png", .data = "\x89PNG" });
    const image = try read(a, io, f.roots(), "home", "pic.png", .{});
    try std.testing.expectEqual(proto.ContentKind.image, image.kind);
    try std.testing.expectEqual(proto.Encoding.base64, image.encoding);
    try std.testing.expectEqualStrings("iVBORw==", image.content);
    const big_image = try read(a, io, f.roots(), "home", "pic.png", .{ .max_image_bytes = 2 });
    try std.testing.expectEqual(proto.ContentKind.too_large, big_image.kind);
    try std.testing.expectEqualStrings("", big_image.content);

    try std.testing.expectError(error.NotFile, read(a, io, f.roots(), "home", "src", .{}));
    try std.testing.expectError(error.NotFile, read(a, io, f.roots(), "home", "", .{}));
    try std.testing.expectError(error.PathOutsideRoots, read(a, io, f.roots(), "home", "escape.txt", .{}));
    try std.testing.expectError(error.InvalidPath, read(a, io, f.roots(), "home", "../outside/secret.txt", .{}));
    try std.testing.expectError(error.InvalidPath, read(a, io, f.roots(), "home", "/etc/passwd", .{}));
}

test "files list marks gitignored entries when git is available" {
    var f = try TestFixture.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const io = std.testing.io;
    var git = git_changes.Git.init(a) catch return error.SkipZigTest;
    defer git.deinit();
    // The fixture's empty `.git` is not a repository; make a real one.
    try f.tmp.dir.deleteTree(io, "root/.git");
    const init_result = git.run(f.root, &.{ "init", "-q" }, .{ .read_only = false }) catch return error.SkipZigTest;
    if (!init_result.ok()) return error.SkipZigTest;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "root/.gitignore", .data = "Zeta/\n*.md\n" });
    const result = try list(a, io, f.roots(), "home", "", null);
    for (result.entries) |entry| {
        const expected = std.mem.eql(u8, entry.name, "Zeta") or std.mem.eql(u8, entry.name, "A.md");
        try std.testing.expectEqual(expected, entry.ignored);
        try std.testing.expect(!std.mem.eql(u8, entry.name, ".git"));
    }
}

test "roots fall back to the home when verde.toml is absent" {
    var f = try TestFixture.init();
    defer f.deinit();
    const a = f.arena_state.allocator();
    const roots = try rootsFor(a, std.testing.io, f.root);
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqualStrings(f.root, roots[0].path);
    try std.testing.expectEqualStrings("root", roots[0].name);
    try std.testing.expectEqualStrings(proto.HOME_ROOT_ID, roots[0].id);
}
