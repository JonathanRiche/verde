//! Files explorer model for the side panel: a lazily listed tree over the
//! workspace roots (`workspace.files.list`), per workspace, plus the filter
//! results (`workspace.files.search`).
//!
//! Directory listings are cached by key (`root id` + 0 byte + relative
//! path; the root itself has an empty path). Expansion state is a set of
//! the same keys, so it survives refreshes and collapsed subtrees keep
//! their listings. `flatten` turns roots + expanded listings into visible
//! rows (roots, entries, and loading/error/truncated notes). IO lives in
//! `file_viewer_controller.zig`, which owns the worker calls.

const std = @import("std");
const headless = @import("headless");

const proto = headless.workspace_files_protocol;
const page = std.heap.page_allocator;

pub const Entry = proto.Entry;
pub const Root = proto.Root;

/// A listing's entries are re-fetched on expand when older than this.
pub const LISTING_STALE_MS: i64 = 3000;
/// Filter search request cap (daemon max is 100).
pub const SEARCH_LIMIT: u32 = 100;

pub const DirStatus = enum { loading, ready, failed };

pub const Dir = struct {
    key: []u8,
    status: DirStatus = .loading,
    /// True while a list call is in flight (also during refreshes of a
    /// ready listing, which stays on screen).
    loading: bool = false,
    arena: std.heap.ArenaAllocator = .init(page),
    entries: []const Entry = &.{},
    truncated: bool = false,
    message: []const u8 = "",
    fetched_ms: i64 = 0,

    fn destroy(self: *Dir) void {
        page.free(self.key);
        self.arena.deinit();
        page.destroy(self);
    }
};

pub const RowKind = enum { root, entry, loading, failed, truncated, empty, match };

pub const Row = struct {
    kind: RowKind,
    root_index: u32 = 0,
    depth: u16 = 0,
    /// `.entry` rows; points into a `Dir` arena (valid until rows rebuild).
    entry: ?*const Entry = null,
    /// `.failed` rows: message; `.match` rows: root-relative path.
    text: []const u8 = "",
};

pub const SearchStatus = enum { idle, waiting, loading, ready, failed };

pub const Search = struct {
    /// Query the results belong to (page-owned).
    query: []u8 = &.{},
    status: SearchStatus = .idle,
    arena: std.heap.ArenaAllocator = .init(page),
    /// Root-relative paths under the home root.
    paths: []const []const u8 = &.{},
    truncated: bool = false,
    message: []const u8 = "",
    generation: u32 = 0,
    /// Debounce deadline for `waiting`.
    due_ms: i64 = 0,
};

pub const Explorer = struct {
    workspace_id: []u8,
    dirs: std.ArrayList(*Dir) = .empty,
    expanded: std.ArrayList([]u8) = .empty,
    /// Key of the selected row (`.root`/`.entry`), or the match path.
    selected: ?[]u8 = null,
    scroll_y: f32 = 0.0,
    rows: std.ArrayList(Row) = .empty,
    rows_dirty: bool = true,
    /// Roots were seen and the default expansion applied.
    initialized: bool = false,
    last_render_ms: i64 = 0,
    search: Search = .{},

    pub fn create(workspace_id: []const u8) !*Explorer {
        const explorer = try page.create(Explorer);
        errdefer page.destroy(explorer);
        explorer.* = .{ .workspace_id = try page.dupe(u8, workspace_id) };
        return explorer;
    }

    pub fn destroy(self: *Explorer) void {
        for (self.dirs.items) |listing| listing.destroy();
        self.dirs.deinit(page);
        for (self.expanded.items) |key| page.free(key);
        self.expanded.deinit(page);
        if (self.selected) |key| page.free(key);
        self.rows.deinit(page);
        page.free(self.search.query);
        self.search.arena.deinit();
        page.free(self.workspace_id);
        page.destroy(self);
    }

    pub fn dir(self: *const Explorer, key: []const u8) ?*Dir {
        for (self.dirs.items) |candidate| {
            if (std.mem.eql(u8, candidate.key, key)) return candidate;
        }
        return null;
    }

    /// Listing slot for `key`, created in `loading` state when missing.
    pub fn ensureDir(self: *Explorer, key: []const u8) !*Dir {
        if (self.dir(key)) |existing| return existing;
        const created = try page.create(Dir);
        errdefer page.destroy(created);
        created.* = .{ .key = try page.dupe(u8, key) };
        errdefer page.free(created.key);
        try self.dirs.append(page, created);
        return created;
    }

    pub fn isExpanded(self: *const Explorer, key: []const u8) bool {
        for (self.expanded.items) |candidate| {
            if (std.mem.eql(u8, candidate, key)) return true;
        }
        return false;
    }

    pub fn setExpanded(self: *Explorer, key: []const u8, expanded: bool) !void {
        for (self.expanded.items, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate, key)) continue;
            if (!expanded) {
                page.free(self.expanded.swapRemove(index));
                self.rows_dirty = true;
            }
            return;
        }
        if (!expanded) return;
        try self.expanded.append(page, try page.dupe(u8, key));
        self.rows_dirty = true;
    }

    pub fn select(self: *Explorer, key: ?[]const u8) void {
        if (self.selected) |old| {
            if (key) |new| if (std.mem.eql(u8, old, new)) return;
            page.free(old);
        }
        self.selected = if (key) |new| page.dupe(u8, new) catch null else null;
    }

    /// Stores a finished listing (taking `arena`); returns the entry count.
    pub fn applyListing(self: *Explorer, key: []const u8, arena: *std.heap.ArenaAllocator, entries: []const Entry, truncated: bool, now_ms: i64) !void {
        const target = try self.ensureDir(key);
        target.arena.deinit();
        target.arena = arena.*;
        arena.* = .init(page);
        target.entries = entries;
        target.truncated = truncated;
        target.status = .ready;
        target.loading = false;
        target.message = "";
        target.fetched_ms = now_ms;
        self.rows_dirty = true;
    }

    pub fn failListing(self: *Explorer, key: []const u8, message: []const u8) !void {
        const target = try self.ensureDir(key);
        target.loading = false;
        // A refresh failure keeps the last good listing on screen.
        if (target.status == .ready) return;
        target.arena.deinit();
        target.arena = .init(page);
        target.entries = &.{};
        target.status = .failed;
        target.message = target.arena.allocator().dupe(u8, message) catch "";
        self.rows_dirty = true;
    }

    /// Rebuilds `rows` from roots and expanded listings.
    pub fn flatten(self: *Explorer, roots: []const Root) !void {
        self.rows.clearRetainingCapacity();
        var key_buf: std.ArrayList(u8) = .empty;
        defer key_buf.deinit(page);
        for (roots, 0..) |root, root_index| {
            try self.rows.append(page, .{ .kind = .root, .root_index = @intCast(root_index) });
            try makeKey(&key_buf, root.id, "");
            if (self.isExpanded(key_buf.items)) try self.appendChildren(&key_buf, root.id, @intCast(root_index), "", 1);
        }
        self.rows_dirty = false;
    }

    fn appendChildren(self: *Explorer, key_buf: *std.ArrayList(u8), root_id: []const u8, root_index: u32, path: []const u8, depth: u16) !void {
        try makeKey(key_buf, root_id, path);
        const listing = self.dir(key_buf.items) orelse {
            try self.rows.append(page, .{ .kind = .loading, .root_index = root_index, .depth = depth });
            return;
        };
        switch (listing.status) {
            .loading => {
                try self.rows.append(page, .{ .kind = .loading, .root_index = root_index, .depth = depth });
                return;
            },
            .failed => {
                try self.rows.append(page, .{ .kind = .failed, .root_index = root_index, .depth = depth, .text = listing.message });
                return;
            },
            .ready => {},
        }
        if (listing.entries.len == 0) {
            try self.rows.append(page, .{ .kind = .empty, .root_index = root_index, .depth = depth });
            return;
        }
        for (listing.entries) |*entry| {
            try self.rows.append(page, .{ .kind = .entry, .root_index = root_index, .depth = depth, .entry = entry });
            if (entry.kind != .directory) continue;
            try makeKey(key_buf, root_id, entry.path);
            if (self.isExpanded(key_buf.items)) try self.appendChildren(key_buf, root_id, root_index, entry.path, depth + 1);
        }
        if (listing.truncated) try self.rows.append(page, .{ .kind = .truncated, .root_index = root_index, .depth = depth });
    }

    /// Replaces rows with filter matches.
    pub fn flattenMatches(self: *Explorer) !void {
        self.rows.clearRetainingCapacity();
        for (self.search.paths) |path| try self.rows.append(page, .{ .kind = .match, .text = path });
        switch (self.search.status) {
            .waiting, .loading => if (self.search.paths.len == 0) try self.rows.append(page, .{ .kind = .loading }),
            .failed => try self.rows.append(page, .{ .kind = .failed, .text = self.search.message }),
            .ready => if (self.search.paths.len == 0) try self.rows.append(page, .{ .kind = .empty }) else if (self.search.truncated) try self.rows.append(page, .{ .kind = .truncated }),
            .idle => {},
        }
        self.rows_dirty = false;
    }
};

/// Writes `root_id` + 0 + `path` into `out`.
pub fn makeKey(out: *std.ArrayList(u8), root_id: []const u8, path: []const u8) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(page, root_id);
    try out.append(page, 0);
    try out.appendSlice(page, path);
}

pub const KeyParts = struct { root_id: []const u8, path: []const u8 };

pub fn splitKey(key: []const u8) KeyParts {
    const zero = std.mem.indexOfScalar(u8, key, 0) orelse return .{ .root_id = key, .path = "" };
    return .{ .root_id = key[0..zero], .path = key[zero + 1 ..] };
}

/// Root-relative parent directory ("" for top-level entries).
pub fn parentPath(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..slash];
}

/// Absolute local path of `rel` under `root_path`.
pub fn joinAbsolute(allocator: std.mem.Allocator, root_path: []const u8, rel: []const u8) ![]u8 {
    if (rel.len == 0) return allocator.dupe(u8, root_path);
    const trimmed = std.mem.trimEnd(u8, root_path, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, rel });
}

const testing = std.testing;

fn testEntry(name: []const u8, path: []const u8, kind: proto.EntryKind) Entry {
    return .{ .name = name, .path = path, .kind = kind };
}

test "flatten nests expanded listings and notes loading and truncation" {
    const explorer = try Explorer.create("ws");
    defer explorer.destroy();
    const roots = [_]Root{
        .{ .id = "home", .name = "proj", .path = "/p" },
        .{ .id = "docs", .name = "docs", .path = "/d" },
    };
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(page);

    try makeKey(&key, "home", "");
    try explorer.setExpanded(key.items, true);
    var arena: std.heap.ArenaAllocator = .init(page);
    const top = try arena.allocator().dupe(Entry, &.{ testEntry("src", "src", .directory), testEntry("a.zig", "a.zig", .file) });
    try explorer.applyListing(key.items, &arena, top, true, 1);
    try makeKey(&key, "home", "src");
    try explorer.setExpanded(key.items, true);

    try explorer.flatten(&roots);
    const rows = explorer.rows.items;
    const kinds = [_]RowKind{ .root, .entry, .loading, .entry, .truncated, .root };
    try testing.expectEqual(kinds.len, rows.len);
    for (kinds, rows) |kind, row| try testing.expectEqual(kind, row.kind);
    try testing.expectEqual(@as(u16, 2), rows[2].depth);
    try testing.expectEqualStrings("src", rows[1].entry.?.name);
    try testing.expectEqual(@as(u32, 1), rows[5].root_index);

    // Collapsing keeps the listing but hides it.
    try makeKey(&key, "home", "");
    try explorer.setExpanded(key.items, false);
    try explorer.flatten(&roots);
    try testing.expectEqual(@as(usize, 2), explorer.rows.items.len);
    try testing.expect(explorer.dir(key.items) != null);
}

test "a failed refresh keeps the previous listing" {
    const explorer = try Explorer.create("ws");
    defer explorer.destroy();
    var arena: std.heap.ArenaAllocator = .init(page);
    const entries = try arena.allocator().dupe(Entry, &.{testEntry("a", "a", .file)});
    try explorer.applyListing("home\x00", &arena, entries, false, 1);
    try explorer.failListing("home\x00", "boom");
    try testing.expectEqual(DirStatus.ready, explorer.dir("home\x00").?.status);
    try explorer.failListing("home\x00x", "boom");
    try testing.expectEqual(DirStatus.failed, explorer.dir("home\x00x").?.status);
    try testing.expectEqualStrings("boom", explorer.dir("home\x00x").?.message);
}

test "key and path helpers" {
    const parts = splitKey("docs\x00guide/intro.md");
    try testing.expectEqualStrings("docs", parts.root_id);
    try testing.expectEqualStrings("guide/intro.md", parts.path);
    try testing.expectEqualStrings("guide", parentPath("guide/intro.md"));
    try testing.expectEqualStrings("", parentPath("intro.md"));
    const joined = try joinAbsolute(testing.allocator, "/home/u/p/", "src/a.zig");
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("/home/u/p/src/a.zig", joined);
}
