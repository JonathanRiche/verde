//! Composer file-mention search state and ownership.

const std = @import("std");
const fff = @import("../workspace/file_search.zig");

pub const Token = struct {
    at_start: usize,
    query_start: usize,
    end: usize,
};

pub const Result = struct {
    path: []u8,
    relative_path: []u8,
    file_name: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.relative_path);
        allocator.free(self.file_name);
    }
};

pub const State = struct {
    finder: ?fff.Finder = null,
    project_path: ?[]u8 = null,
    last_query: ?[]u8 = null,
    token: ?Token = null,
    results: std.ArrayList(Result) = .empty,
    total_matched: usize = 0,
    total_files: usize = 0,
    visible: bool = false,
    selected_index: usize = 0,

    pub fn clearResults(self: *State, allocator: std.mem.Allocator) void {
        for (self.results.items) |item| item.deinit(allocator);
        self.results.clearRetainingCapacity();
        self.total_matched = 0;
        self.total_files = 0;
        self.selected_index = 0;
    }

    pub fn setResults(self: *State, allocator: std.mem.Allocator, search_results: *fff.SearchResults) !void {
        self.clearResults(allocator);
        try self.results.ensureTotalCapacity(allocator, search_results.items.len);
        var appended: usize = 0;
        errdefer {
            for (self.results.items[0..appended]) |item| item.deinit(allocator);
            self.results.clearRetainingCapacity();
        }
        for (search_results.items) |item| {
            self.results.appendAssumeCapacity(.{
                .path = try allocator.dupe(u8, item.path),
                .relative_path = try allocator.dupe(u8, item.relative_path),
                .file_name = try allocator.dupe(u8, item.file_name),
            });
            appended += 1;
        }
        self.total_matched = search_results.total_matched;
        self.total_files = search_results.total_files;
        self.selected_index = 0;
    }

    pub fn clearQuery(self: *State, allocator: std.mem.Allocator) void {
        if (self.last_query) |query| allocator.free(query);
        self.last_query = null;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearResults(allocator);
        self.results.deinit(allocator);
        self.clearQuery(allocator);
        if (self.project_path) |project_path| allocator.free(project_path);
        if (self.finder) |*finder| finder.deinit();
        self.* = .{};
    }
};

pub fn updateFileSearch(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) {
        self.clearFileSearch();
        return;
    }

    const draft = self.currentDraft();
    const token = trailingFileSearchToken(draft) orelse {
        self.clearFileSearch();
        return;
    };

    const project_path = self.currentProject().path;
    self.ensureFileSearchFinder(project_path) catch {
        self.clearFileSearch();
        self.setSidebarNotice("Failed to initialize file search.");
        return;
    };

    self.file_search_controller.visible = true;
    self.file_search_controller.token = token;

    const query = draft[token.query_start..token.end];
    const query_changed = self.file_search_controller.last_query == null or
        !std.mem.eql(u8, self.file_search_controller.last_query.?, query);
    if (!query_changed) return;

    self.file_search_controller.clearQuery(self.allocator);
    self.file_search_controller.last_query = self.allocator.dupe(u8, query) catch {
        self.clearFileSearch();
        return;
    };

    var search_results = self.file_search_controller.finder.?.search(self.allocator, query, 8) catch {
        self.file_search_controller.clearResults(self.allocator);
        self.setSidebarNotice("File search failed.");
        return;
    };
    defer search_results.deinit(self.allocator);

    self.file_search_controller.setResults(self.allocator, &search_results) catch {
        self.file_search_controller.clearResults(self.allocator);
        self.setSidebarNotice("Failed to update file search results.");
    };
}

pub fn hasActiveFileSearch(self: anytype) bool {
    return self.file_search_controller.visible;
}

pub fn fileSearchResults(self: anytype) []const Result {
    return self.file_search_controller.results.items;
}

pub fn fileSearchIsScanning(self: anytype) bool {
    if (self.file_search_controller.finder) |*finder| {
        return finder.isScanning();
    }
    return false;
}

pub fn fileSearchSelectedIndex(self: anytype) usize {
    if (self.file_search_controller.results.items.len == 0) return 0;
    return @min(self.file_search_controller.selected_index, self.file_search_controller.results.items.len - 1);
}

pub fn moveFileSearchSelection(self: anytype, delta: i32) bool {
    if (!self.file_search_controller.visible) return false;
    const count = self.file_search_controller.results.items.len;
    if (count == 0) return false;

    const current: i32 = @intCast(self.fileSearchSelectedIndex());
    const max_index: i32 = @intCast(count - 1);
    const next = std.math.clamp(current + delta, 0, max_index);
    if (next == current) return true;
    self.file_search_controller.selected_index = @intCast(next);
    return true;
}

pub fn acceptPrimaryFileSearchResult(self: anytype) bool {
    return self.selectFileSearchResult(self.fileSearchSelectedIndex());
}

pub fn selectFileSearchResult(self: anytype, index: usize) bool {
    if (!self.file_search_controller.visible) return false;
    const token = self.file_search_controller.token orelse return false;
    if (index >= self.file_search_controller.results.items.len) return false;

    const draft = self.currentDraft();
    const choice = self.file_search_controller.results.items[index];
    const replacement = std.fmt.allocPrint(self.allocator, "@{s} ", .{choice.relative_path}) catch return false;
    defer self.allocator.free(replacement);

    const next_draft = std.fmt.allocPrint(
        self.allocator,
        "{s}{s}{s}",
        .{
            draft[0..token.at_start],
            replacement,
            draft[token.end..],
        },
    ) catch return false;
    defer self.allocator.free(next_draft);

    self.setDraft(next_draft);
    if (self.file_search_controller.last_query) |query| {
        if (self.file_search_controller.finder) |*finder| {
            finder.trackQuery(self.allocator, query, choice.path);
        }
    }
    self.clearFileSearch();
    return true;
}

pub fn ensureFileSearchFinder(self: anytype, project_path: []const u8) !void {
    if (self.file_search_controller.project_path) |active_path| {
        if (std.mem.eql(u8, active_path, project_path)) return;

        self.allocator.free(active_path);
        self.file_search_controller.project_path = null;
    }

    if (self.file_search_controller.finder) |*finder| {
        finder.deinit();
        self.file_search_controller.finder = null;
    }

    self.file_search_controller.finder = try fff.Finder.init(self.allocator, self.storage.pref_path, project_path);
    self.file_search_controller.project_path = try self.allocator.dupe(u8, project_path);
    self.file_search_controller.clearQuery(self.allocator);
}

pub fn clearFileSearch(self: anytype) void {
    self.file_search_controller.visible = false;
    self.file_search_controller.token = null;
    self.file_search_controller.clearQuery(self.allocator);
    self.file_search_controller.clearResults(self.allocator);
}

pub fn trailingFileSearchToken(draft: []const u8) ?Token {
    if (draft.len == 0) return null;
    if (std.ascii.isWhitespace(draft[draft.len - 1])) return null;

    var token_start = draft.len;
    while (token_start > 0 and !std.ascii.isWhitespace(draft[token_start - 1])) {
        token_start -= 1;
    }

    if (draft[token_start] != '@') return null;
    return .{
        .at_start = token_start,
        .query_start = token_start + 1,
        .end = draft.len,
    };
}
