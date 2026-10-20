//! In-app folder browser model. Replaces the external OS folder dialog for
//! every "pick a directory" flow (Add Workspace, chat working directory,
//! workspace folders): the GUI lists local directories itself, the user
//! filters or types a path, and the choice is handed back through the same
//! `PickerState` result the old dialog worker produced.

const std = @import("std");
const repo_identity = @import("verde_remote").repo_identity;

const log = std.log.scoped(.folder_browser);

pub const MAX_ENTRIES: usize = 4096;
pub const QUERY_CAPACITY: usize = 1024;

pub const Entry = struct {
    name: []u8,
    is_git: bool,
    hidden: bool,
    /// Raw `origin` a remote listing reported (`workspace.directory.list`).
    git_identity: ?[]u8 = null,
    /// The origin normalizes to the key the remote browser was opened for.
    same_origin: bool = false,
};

/// One folder from another machine's `workspace.directory.list`.
pub const RemoteEntry = struct {
    name: []const u8,
    git_identity: ?[]const u8 = null,
};

/// Browsing another machine: navigation becomes a listing request that the
/// owner sends with `workspace.directory.list` and answers with
/// `applyRemoteListing` / `failRemoteListing`.
pub const Remote = struct {
    /// Machine name shown in the title.
    machine_label: std.ArrayList(u8) = .empty,
    /// Normalized repository key a folder must match to read "same origin".
    same_origin_key: std.ArrayList(u8) = .empty,
    /// Path to list next; empty asks the machine for its first allowed root.
    pending: std.ArrayList(u8) = .empty,
    has_pending: bool = false,
    loading: bool = false,
    /// Parent the machine allows browsing to; null at an allowed root.
    parent: std.ArrayList(u8) = .empty,
    has_parent: bool = false,

    fn deinit(self: *Remote, allocator: std.mem.Allocator) void {
        self.machine_label.deinit(allocator);
        self.same_origin_key.deinit(allocator);
        self.pending.deinit(allocator);
        self.parent.deinit(allocator);
    }
};

pub const FolderBrowser = struct {
    open: bool = false,
    /// Absolute path of the directory being listed.
    dir: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Filter text, or a path when it starts with `/` or `~`.
    query_storage: [QUERY_CAPACITY + 1]u8 = [_]u8{0} ** (QUERY_CAPACITY + 1),
    cursor: usize = 0,
    /// Highlighted row in the filtered list; null means "this folder".
    highlighted: ?usize = null,
    show_hidden: bool = false,
    scroll_y: f32 = 0.0,
    /// Set when the last navigation failed; shown in the footer.
    notice: []const u8 = "",
    /// Home directory, used for `~` expansion and the Places column.
    home: std.ArrayList(u8) = .empty,
    /// Set while listing another machine's folders.
    remote: ?Remote = null,

    pub fn deinit(self: *FolderBrowser, allocator: std.mem.Allocator) void {
        self.clearEntries(allocator);
        self.entries.deinit(allocator);
        self.dir.deinit(allocator);
        self.home.deinit(allocator);
        if (self.remote) |*remote| remote.deinit(allocator);
        self.* = .{};
    }

    /// Opens the browser on another machine. Nothing is listed until the
    /// owner answers the first request (the machine's first allowed root).
    pub fn openRemote(self: *FolderBrowser, allocator: std.mem.Allocator, machine_label: []const u8, same_origin_key: ?[]const u8) void {
        self.close(allocator);
        self.dir.clearRetainingCapacity();
        self.home.clearRetainingCapacity();
        self.open = true;
        self.show_hidden = false;
        var remote: Remote = .{};
        remote.machine_label.appendSlice(allocator, machine_label) catch {};
        if (same_origin_key) |key| remote.same_origin_key.appendSlice(allocator, key) catch {};
        remote.has_pending = true;
        remote.loading = true;
        self.remote = remote;
        self.notice = "Loading folders…";
    }

    pub fn isRemote(self: *const FolderBrowser) bool {
        return self.remote != null;
    }

    /// The path a remote listing should fetch next (empty = first root), or
    /// null when nothing is waiting. Marks the request as sent.
    pub fn takeRemoteRequest(self: *FolderBrowser) ?[]const u8 {
        const remote = if (self.remote) |*value| value else return null;
        if (!remote.has_pending) return null;
        remote.has_pending = false;
        remote.loading = true;
        return remote.pending.items;
    }

    /// Replaces the listing with a remote answer for `path`.
    pub fn applyRemoteListing(self: *FolderBrowser, allocator: std.mem.Allocator, path: []const u8, parent: ?[]const u8, listed: []const RemoteEntry) void {
        const remote = if (self.remote) |*value| value else return;
        remote.loading = false;
        remote.parent.clearRetainingCapacity();
        remote.has_parent = parent != null;
        if (parent) |value| remote.parent.appendSlice(allocator, value) catch {
            remote.has_parent = false;
        };
        self.clearEntries(allocator);
        for (listed) |item| {
            if (self.entries.items.len == MAX_ENTRIES) break;
            if (item.name.len == 0 or !std.unicode.utf8ValidateSlice(item.name)) continue;
            const name = allocator.dupe(u8, item.name) catch break;
            const identity: ?[]u8 = if (item.git_identity) |value| allocator.dupe(u8, value) catch null else null;
            self.entries.append(allocator, .{
                .name = name,
                .is_git = item.git_identity != null,
                .hidden = item.name[0] == '.',
                .git_identity = identity,
                .same_origin = if (item.git_identity) |value| sameOriginKey(remote.same_origin_key.items, value) else false,
            }) catch {
                allocator.free(name);
                if (identity) |value| allocator.free(value);
                break;
            };
        }
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);
        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(allocator, path) catch {};
        // The first answer is the machine's default root: `~` and Home go there.
        if (self.home.items.len == 0) self.home.appendSlice(allocator, std.mem.trimEnd(u8, path, "/")) catch {};
        self.clearQuery();
        self.highlighted = null;
        self.scroll_y = 0.0;
        self.notice = "";
    }

    /// Keeps the current listing and explains why the request failed.
    pub fn failRemoteListing(self: *FolderBrowser, notice: []const u8) void {
        const remote = if (self.remote) |*value| value else return;
        remote.loading = false;
        self.notice = notice;
    }

    /// Puts back a listing request the owner could not send yet.
    pub fn rearmRemoteRequest(self: *FolderBrowser, allocator: std.mem.Allocator, path: []const u8) void {
        const remote = if (self.remote) |*value| value else return;
        remote.pending.clearRetainingCapacity();
        remote.pending.appendSlice(allocator, path) catch return;
        remote.has_pending = true;
    }

    pub fn remoteLoading(self: *const FolderBrowser) bool {
        const remote = self.remote orelse return false;
        return remote.loading or remote.has_pending;
    }

    pub fn remoteMachineLabel(self: *const FolderBrowser) []const u8 {
        const remote = self.remote orelse return "";
        return remote.machine_label.items;
    }

    fn requestRemote(self: *FolderBrowser, allocator: std.mem.Allocator, path: []const u8) bool {
        const remote = if (self.remote) |*value| value else return false;
        remote.pending.clearRetainingCapacity();
        remote.pending.appendSlice(allocator, path) catch return false;
        remote.has_pending = true;
        remote.loading = true;
        self.notice = "Loading folders…";
        // The listing moves when the machine answers.
        return false;
    }

    pub fn query(self: *const FolderBrowser) []const u8 {
        return std.mem.sliceTo(&self.query_storage, 0);
    }

    pub fn queryBuffer(self: *FolderBrowser) [:0]u8 {
        return self.query_storage[0..QUERY_CAPACITY :0];
    }

    pub fn clearQuery(self: *FolderBrowser) void {
        @memset(&self.query_storage, 0);
        self.cursor = 0;
    }

    pub fn currentDir(self: *const FolderBrowser) []const u8 {
        return self.dir.items;
    }

    /// Opens the browser listing `start_path`, falling back to home and then `/`.
    pub fn openAt(self: *FolderBrowser, allocator: std.mem.Allocator, start_path: []const u8, home: []const u8) void {
        self.home.clearRetainingCapacity();
        self.home.appendSlice(allocator, std.mem.trimEnd(u8, home, "/")) catch {};
        self.open = true;
        self.show_hidden = false;
        self.notice = "";
        if (self.navigate(allocator, start_path)) return;
        if (self.navigate(allocator, home)) return;
        _ = self.navigate(allocator, "/");
    }

    pub fn close(self: *FolderBrowser, allocator: std.mem.Allocator) void {
        self.open = false;
        if (self.remote) |*remote| remote.deinit(allocator);
        self.remote = null;
        self.clearEntries(allocator);
        self.clearQuery();
        self.highlighted = null;
        self.scroll_y = 0.0;
        self.notice = "";
    }

    /// Lists `raw_path` (absolute, or `~`-relative). On failure the current
    /// listing stays and `notice` explains why; returns whether it moved.
    pub fn navigate(self: *FolderBrowser, allocator: std.mem.Allocator, raw_path: []const u8) bool {
        const expanded = self.expandPath(allocator, raw_path) catch {
            self.notice = "That path could not be read.";
            return false;
        };
        defer allocator.free(expanded);
        if (self.remote != null) return self.requestRemote(allocator, expanded);
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, expanded, .{ .iterate = true }) catch |err| {
            self.notice = switch (err) {
                error.FileNotFound => "That directory does not exist.",
                error.NotDir => "That path is not a directory.",
                error.AccessDenied, error.PermissionDenied => "Verde cannot open that directory.",
                else => "That directory could not be opened.",
            };
            return false;
        };
        defer dir.close(io);

        self.clearEntries(allocator);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (self.entries.items.len == MAX_ENTRIES) break;
            const is_dir = switch (entry.kind) {
                .directory => true,
                // Follow links so a symlinked project folder still appears.
                .sym_link => isDirectoryAt(io, dir, entry.name),
                else => false,
            };
            if (!is_dir or !std.unicode.utf8ValidateSlice(entry.name)) continue;
            const name = allocator.dupe(u8, entry.name) catch break;
            self.entries.append(allocator, .{
                .name = name,
                .is_git = hasGitDir(io, dir, entry.name),
                .hidden = entry.name[0] == '.',
            }) catch {
                allocator.free(name);
                break;
            };
        }
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.lessThan);

        self.dir.clearRetainingCapacity();
        self.dir.appendSlice(allocator, expanded) catch {};
        self.clearQuery();
        self.highlighted = null;
        self.scroll_y = 0.0;
        self.notice = "";
        return true;
    }

    pub fn navigateUp(self: *FolderBrowser, allocator: std.mem.Allocator) bool {
        if (self.remote) |remote| {
            // Only the machine knows which parents it allows.
            if (!remote.has_parent) return false;
            const owned = allocator.dupe(u8, remote.parent.items) catch return false;
            defer allocator.free(owned);
            return self.requestRemote(allocator, owned);
        }
        const parent = std.fs.path.dirname(self.dir.items) orelse return false;
        const owned = allocator.dupe(u8, parent) catch return false;
        defer allocator.free(owned);
        return self.navigate(allocator, owned);
    }

    pub fn navigateInto(self: *FolderBrowser, allocator: std.mem.Allocator, name: []const u8) bool {
        const child = std.fs.path.join(allocator, &.{ self.dir.items, name }) catch return false;
        defer allocator.free(child);
        return self.navigate(allocator, child);
    }

    /// True when the query should be treated as a path rather than a filter.
    pub fn queryIsPath(self: *const FolderBrowser) bool {
        const text = self.query();
        return text.len > 0 and (text[0] == '/' or text[0] == '~');
    }

    /// Entry indices visible under the current filter and hidden-file setting.
    pub fn filtered(self: *const FolderBrowser, out: []usize) usize {
        const text = if (self.queryIsPath()) "" else std.mem.trim(u8, self.query(), " ");
        const want_hidden = self.show_hidden or (text.len > 0 and text[0] == '.');
        var count: usize = 0;
        for (self.entries.items, 0..) |entry, index| {
            if (count == out.len) break;
            if (entry.hidden and !want_hidden) continue;
            if (text.len > 0 and std.ascii.indexOfIgnoreCase(entry.name, text) == null) continue;
            out[count] = index;
            count += 1;
        }
        return count;
    }

    /// Name a "Create folder" row would use: the typed filter, when it is a
    /// plain single-segment name that no listed folder already has.
    pub fn creatableName(self: *const FolderBrowser) ?[]const u8 {
        // Folders on another machine are picked, never created from here.
        if (self.remote != null) return null;
        if (self.queryIsPath()) return null;
        const name = std.mem.trim(u8, self.query(), " \t");
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return null;
        if (std.mem.indexOfAny(u8, name, "/\\") != null) return null;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return null;
        }
        return name;
    }

    /// Creates `name` inside the listed folder and opens it.
    pub fn createFolder(self: *FolderBrowser, allocator: std.mem.Allocator, name: []const u8) bool {
        const path = std.fs.path.join(allocator, &.{ self.dir.items, name }) catch return false;
        defer allocator.free(path);
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.Dir.cwd().createDir(threaded.io(), path, .default_dir) catch |err| {
            self.notice = switch (err) {
                error.PathAlreadyExists => "A file or directory with that name already exists.",
                error.AccessDenied, error.PermissionDenied => "Verde cannot create a directory here.",
                else => "That directory could not be created.",
            };
            return false;
        };
        return self.navigate(allocator, path);
    }

    /// Absolute path the primary action would pick: the highlighted folder,
    /// otherwise the folder being listed. Caller frees.
    pub fn targetPathAlloc(self: *const FolderBrowser, allocator: std.mem.Allocator, visible: []const usize) ![]u8 {
        if (self.highlighted) |row| {
            if (row < visible.len) return std.fs.path.join(allocator, &.{ self.dir.items, self.entries.items[visible[row]].name });
        }
        return allocator.dupe(u8, self.dir.items);
    }

    fn expandPath(self: *const FolderBrowser, allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyPath;
        if (trimmed[0] == '~' and (trimmed.len == 1 or trimmed[1] == '/')) {
            if (self.home.items.len == 0) return error.NoHome;
            return std.fs.path.resolve(allocator, &.{ self.home.items, std.mem.trimStart(u8, trimmed[1..], "/") });
        }
        if (!std.fs.path.isAbsolute(trimmed)) {
            return std.fs.path.resolve(allocator, &.{ self.dir.items, trimmed });
        }
        return std.fs.path.resolve(allocator, &.{trimmed});
    }

    fn clearEntries(self: *FolderBrowser, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            if (entry.git_identity) |value| allocator.free(value);
        }
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.clearRetainingCapacity();
    }
};

fn isDirectoryAt(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    const stat = dir.statFile(io, name, .{}) catch return false;
    return stat.kind == .directory;
}

fn hasGitDir(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = std.fmt.bufPrint(&buf, "{s}/.git", .{name}) catch return false;
    dir.access(io, git_path, .{}) catch return false;
    return true;
}

/// True when `raw_origin` normalizes to `key` (a `repo_identity` key).
fn sameOriginKey(key: []const u8, raw_origin: []const u8) bool {
    if (key.len == 0) return false;
    var buffer: [repo_identity.MAX_KEY_LEN]u8 = undefined;
    const normalized = repo_identity.normalize(&buffer, raw_origin) orelse return false;
    return std.mem.eql(u8, normalized, key);
}

test "remote folder browser requests listings and marks same-origin folders" {
    const allocator = std.testing.allocator;
    var browser: FolderBrowser = .{};
    defer browser.deinit(allocator);
    browser.openRemote(allocator, "Lightning", "v1:github.com/jonathanriche/verde");
    try std.testing.expect(browser.isRemote());
    try std.testing.expectEqualStrings("", browser.takeRemoteRequest().?);
    try std.testing.expect(browser.takeRemoteRequest() == null);
    try std.testing.expect(browser.creatableName() == null);

    browser.applyRemoteListing(allocator, "/home/zod", null, &.{
        .{ .name = "verde", .git_identity = "git@github.com:JonathanRiche/verde.git" },
        .{ .name = "fork", .git_identity = "https://github.com/someone/verde" },
        .{ .name = "notes" },
    });
    try std.testing.expectEqualStrings("/home/zod", browser.currentDir());
    try std.testing.expectEqualStrings("/home/zod", browser.home.items);
    try std.testing.expectEqual(@as(usize, 3), browser.entries.items.len);
    try std.testing.expectEqualStrings("fork", browser.entries.items[0].name);
    try std.testing.expect(!browser.entries.items[0].same_origin);
    try std.testing.expect(!browser.entries.items[1].is_git);
    try std.testing.expect(browser.entries.items[2].same_origin);
    try std.testing.expect(!browser.remoteLoading());

    // At an allowed root there is no parent to go up to.
    try std.testing.expect(!browser.navigateUp(allocator));
    try std.testing.expect(!browser.navigateInto(allocator, "verde"));
    try std.testing.expect(browser.remoteLoading());
    try std.testing.expectEqualStrings("/home/zod/verde", browser.takeRemoteRequest().?);
    browser.failRemoteListing("That folder is outside the allowed roots.");
    try std.testing.expectEqualStrings("/home/zod", browser.currentDir());

    browser.close(allocator);
    try std.testing.expect(!browser.isRemote());
}
