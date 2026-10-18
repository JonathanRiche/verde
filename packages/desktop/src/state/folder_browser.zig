//! In-app folder browser model. Replaces the external OS folder dialog for
//! every "pick a directory" flow (Add Workspace, chat working directory,
//! workspace folders): the GUI lists local directories itself, the user
//! filters or types a path, and the choice is handed back through the same
//! `PickerState` result the old dialog worker produced.

const std = @import("std");

const log = std.log.scoped(.folder_browser);

pub const MAX_ENTRIES: usize = 4096;
pub const QUERY_CAPACITY: usize = 1024;

pub const Entry = struct {
    name: []u8,
    is_git: bool,
    hidden: bool,
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

    pub fn deinit(self: *FolderBrowser, allocator: std.mem.Allocator) void {
        self.clearEntries(allocator);
        self.entries.deinit(allocator);
        self.dir.deinit(allocator);
        self.home.deinit(allocator);
        self.* = .{};
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
