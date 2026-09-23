//! Narrow Zig wrapper around the vendored `fff-c` library.

const std = @import("std");

const c = @cImport({
    @cInclude("fff.h");
});

pub const SearchItem = struct {
    path: []u8,
    relative_path: []u8,
    file_name: []u8,

    fn deinit(self: SearchItem, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.file_name);
    }
};

pub const SearchResults = struct {
    items: []SearchItem,
    total_matched: usize,
    total_files: usize,

    pub fn deinit(self: *SearchResults, allocator: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = .{
            .items = &.{},
            .total_matched = 0,
            .total_files = 0,
        };
    }
};

pub const Finder = struct {
    handle: ?*anyopaque = null,

    pub fn init(
        allocator: std.mem.Allocator,
        storage_root: []const u8,
        project_path: []const u8,
    ) !Finder {
        const db_dir = try std.fs.path.join(allocator, &.{ storage_root, "fff" });
        defer allocator.free(db_dir);
        var threaded = std.Io.Threaded.init_single_threaded;
        std.Io.Dir.createDirAbsolute(threaded.io(), db_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var path_hasher = std.hash.Wyhash.init(0);
        path_hasher.update(project_path);
        const path_hash = path_hasher.final();

        const frecency_db = try std.fmt.allocPrint(allocator, "{s}/{x}-frecency.mdb", .{ db_dir, path_hash });
        defer allocator.free(frecency_db);
        const history_db = try std.fmt.allocPrint(allocator, "{s}/{x}-history.mdb", .{ db_dir, path_hash });
        defer allocator.free(history_db);

        const project_path_z = try allocator.dupeZ(u8, project_path);
        defer allocator.free(project_path_z);
        const frecency_db_z = try allocator.dupeZ(u8, frecency_db);
        defer allocator.free(frecency_db_z);
        const history_db_z = try allocator.dupeZ(u8, history_db);
        defer allocator.free(history_db_z);

        const result_ptr = c.fff_create_instance(
            project_path_z.ptr,
            frecency_db_z.ptr,
            history_db_z.ptr,
            false,
            false,
            true,
        ) orelse return error.FffUnavailable;
        defer c.fff_free_result(result_ptr);

        if (!result_ptr.*.success) {
            logFffError("fff_create_instance", result_ptr);
            return error.FffCreateFailed;
        }

        return .{
            .handle = result_ptr.*.handle,
        };
    }

    pub fn deinit(self: *Finder) void {
        if (self.handle) |handle| {
            c.fff_destroy(handle);
            self.handle = null;
        }
    }

    pub fn search(
        self: *Finder,
        allocator: std.mem.Allocator,
        query: []const u8,
        page_size: usize,
    ) !SearchResults {
        const handle = self.handle orelse return error.FffUnavailable;
        const query_z = try allocator.dupeZ(u8, query);
        defer allocator.free(query_z);

        const result_ptr = c.fff_search(
            handle,
            query_z.ptr,
            null,
            0,
            0,
            @intCast(page_size),
            0,
            0,
        ) orelse return error.FffUnavailable;
        defer c.fff_free_result(result_ptr);

        if (!result_ptr.*.success) {
            logFffError("fff_search", result_ptr);
            return error.FffSearchFailed;
        }

        const raw_result = castSearchResult(result_ptr.*.handle) orelse {
            return SearchResults{
                .items = &.{},
                .total_matched = 0,
                .total_files = 0,
            };
        };
        defer c.fff_free_search_result(raw_result);

        const count: usize = raw_result.*.count;
        var items = try allocator.alloc(SearchItem, count);
        var initialized_count: usize = 0;
        errdefer {
            for (items[0..initialized_count]) |item| item.deinit(allocator);
            allocator.free(items);
        }

        for (0..count) |index| {
            const item_ptr = c.fff_search_result_get_item(raw_result, @intCast(index)) orelse {
                return error.FffSearchDecodeFailed;
            };
            items[index] = .{
                .path = try allocator.dupe(u8, std.mem.span(item_ptr.*.path)),
                .relative_path = try allocator.dupe(u8, std.mem.span(item_ptr.*.relative_path)),
                .file_name = try allocator.dupe(u8, std.mem.span(item_ptr.*.file_name)),
            };
            initialized_count += 1;
        }

        return .{
            .items = items,
            .total_matched = raw_result.*.total_matched,
            .total_files = raw_result.*.total_files,
        };
    }

    pub fn trackQuery(self: *Finder, allocator: std.mem.Allocator, query: []const u8, file_path: []const u8) void {
        const handle = self.handle orelse return;
        const query_z = allocator.dupeZ(u8, query) catch return;
        defer allocator.free(query_z);
        const file_path_z = allocator.dupeZ(u8, file_path) catch return;
        defer allocator.free(file_path_z);

        const result_ptr = c.fff_track_query(handle, query_z.ptr, file_path_z.ptr) orelse return;
        defer c.fff_free_result(result_ptr);

        if (!result_ptr.*.success) {
            logFffError("fff_track_query", result_ptr);
        }
    }

    pub fn isScanning(self: *const Finder) bool {
        const handle = self.handle orelse return false;
        return c.fff_is_scanning(handle);
    }
};

fn castSearchResult(handle: ?*anyopaque) ?*c.FffSearchResult {
    const opaque_handle = handle orelse return null;
    return @ptrCast(@alignCast(opaque_handle));
}

fn logFffError(action: []const u8, result: *c.FffResult) void {
    const message = if (result.@"error" != null) std.mem.span(result.@"error") else "unknown error";
    std.log.scoped(.native_fff).err("{s} failed: {s}", .{ action, message });
}

/// Search each real workspace root explicitly; directory symlink traversal is
/// intentionally not relied upon by the file indexer.
pub const WorkspaceFinder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { finder: Finder, name: []u8 };

    pub fn init(allocator: std.mem.Allocator, storage_root: []const u8, project_path: []const u8) !WorkspaceFinder {
        const folders = @import("folders.zig");
        var roots = try folders.resolve(allocator, project_path);
        defer roots.deinit();
        var result: WorkspaceFinder = .{ .allocator = allocator };
        errdefer result.deinit();
        for (roots.roots, 0..) |root, index| {
            var finder = try Finder.init(allocator, storage_root, root);
            errdefer finder.deinit();
            const label = if (index == 0) "workspace" else for (roots.folders) |folder| {
                if (std.mem.eql(u8, folder.path, root)) break folder.name;
            } else "folder";
            const name = try allocator.dupe(u8, label);
            errdefer allocator.free(name);
            try result.entries.append(allocator, .{ .finder = finder, .name = name });
        }
        return result;
    }

    pub fn deinit(self: *WorkspaceFinder) void {
        for (self.entries.items) |*entry| {
            entry.finder.deinit();
            self.allocator.free(entry.name);
        }
        self.entries.deinit(self.allocator);
        self.entries = .empty;
    }

    pub fn search(self: *WorkspaceFinder, allocator: std.mem.Allocator, query: []const u8, page_size: usize) !SearchResults {
        var searches: std.ArrayList(SearchResults) = .empty;
        defer {
            for (searches.items) |*result| result.deinit(allocator);
            searches.deinit(allocator);
        }
        var total_files: usize = 0;
        var total_matched: usize = 0;
        for (self.entries.items) |*entry| {
            var result = try entry.finder.search(allocator, query, page_size);
            errdefer result.deinit(allocator);
            try searches.append(allocator, result);
            total_files += result.total_files;
            total_matched += result.total_matched;
        }
        var items: std.ArrayList(SearchItem) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(allocator);
            items.deinit(allocator);
        }
        // Interleave roots so a large primary repository cannot hide matches
        // in a smaller attached folder. Preserve each indexer's ranking.
        outer: for (0..page_size) |rank| {
            for (searches.items, 0..) |result, index| {
                if (rank >= result.items.len) continue;
                const item = result.items[rank];
                for (items.items) |existing| {
                    if (std.mem.eql(u8, existing.path, item.path)) break;
                } else {
                    const path = try allocator.dupe(u8, item.path);
                    errdefer allocator.free(path);
                    const relative = if (self.entries.items.len > 1)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.entries.items[index].name, item.relative_path })
                    else
                        try allocator.dupe(u8, item.relative_path);
                    errdefer allocator.free(relative);
                    const file_name = try allocator.dupe(u8, item.file_name);
                    errdefer allocator.free(file_name);
                    try items.append(allocator, .{ .path = path, .relative_path = relative, .file_name = file_name });
                    if (items.items.len == page_size) break :outer;
                }
            }
        }
        return .{ .items = try items.toOwnedSlice(allocator), .total_files = total_files, .total_matched = total_matched };
    }

    pub fn isScanning(self: *const WorkspaceFinder) bool {
        for (self.entries.items) |*entry| if (entry.finder.isScanning()) return true;
        return false;
    }

    pub fn trackQuery(self: *WorkspaceFinder, allocator: std.mem.Allocator, query: []const u8, path: []const u8) void {
        for (self.entries.items) |*entry| entry.finder.trackQuery(allocator, query, path);
    }
};

test "workspace search finds files in separate real roots without symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "api");
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "api/multifolder-needle.txt", .data = "api" });
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/multifolder-needle.txt", .data = "docs" });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/verde.toml", .data = "[folders.api]\npath='../api'\n[folders.docs]\npath='../docs'\n" });
    const home = try tmp.dir.realPathFileAlloc(io, "home", allocator);
    defer allocator.free(home);
    const storage = try tmp.dir.realPathFileAlloc(io, "state", allocator);
    defer allocator.free(storage);
    var finder = try WorkspaceFinder.init(allocator, storage, home);
    defer finder.deinit();
    for (0..200) |_| {
        if (!finder.isScanning()) break;
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    } else return error.WorkspaceSearchScanTimedOut;
    var result = try finder.search(allocator, "multifolder-needle", 8);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("api/multifolder-needle.txt", result.items[0].relative_path);
    try std.testing.expectEqualStrings("docs/multifolder-needle.txt", result.items[1].relative_path);
    try std.testing.expect(!std.mem.eql(u8, result.items[0].path, result.items[1].path));
}
