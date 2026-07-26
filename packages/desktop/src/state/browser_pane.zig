//! Owned browser-tab and browser-pane persistence state.

const std = @import("std");

pub const BrowserTabRef = struct {
    url: ?[]u8 = null,
    title: ?[]u8 = null,
    history: std.ArrayList([]u8) = .empty,
    history_index: ?usize = null,
    pinned: bool = false,
    loading: bool = false,
    load_failed: bool = false,

    pub fn deinit(self: *BrowserTabRef, allocator: std.mem.Allocator) void {
        if (self.url) |url| allocator.free(url);
        if (self.title) |title| allocator.free(title);
        for (self.history.items) |entry| allocator.free(entry);
        self.history.deinit(allocator);
        self.* = .{};
    }

    pub fn setUrl(self: *BrowserTabRef, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.url) |url| allocator.free(url);
        self.url = if (value) |slice| try allocator.dupe(u8, slice) else null;
    }

    pub fn setTitle(self: *BrowserTabRef, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (self.title) |title| allocator.free(title);
        self.title = if (value) |slice| try allocator.dupe(u8, slice) else null;
    }

    pub fn recordNavigation(self: *BrowserTabRef, allocator: std.mem.Allocator, url: []const u8) !void {
        if (self.url) |current| {
            if (std.mem.eql(u8, current, url)) return;
        }

        if (self.history_index) |index| {
            if (index < self.history.items.len and std.mem.eql(u8, self.history.items[index], url)) {
                try self.setUrl(allocator, url);
                return;
            }
            const remove_index = index + 1;
            while (self.history.items.len > remove_index) {
                allocator.free(self.history.items[self.history.items.len - 1]);
                self.history.items.len -= 1;
            }
        } else if (self.history.items.len > 0) {
            for (self.history.items) |entry| allocator.free(entry);
            self.history.clearRetainingCapacity();
        }

        try self.appendHistoryEntry(allocator, url);
        self.history_index = self.history.items.len - 1;
        try self.setUrl(allocator, url);
    }

    pub fn appendHistoryEntry(self: *BrowserTabRef, allocator: std.mem.Allocator, url: []const u8) !void {
        const owned = try allocator.dupe(u8, url);
        errdefer allocator.free(owned);
        try self.history.append(allocator, owned);
    }

    pub fn clone(self: *const BrowserTabRef, allocator: std.mem.Allocator) !BrowserTabRef {
        var duplicate: BrowserTabRef = .{ .pinned = self.pinned };
        errdefer duplicate.deinit(allocator);
        try duplicate.setUrl(allocator, self.url);
        try duplicate.setTitle(allocator, self.title);
        for (self.history.items) |entry| try duplicate.appendHistoryEntry(allocator, entry);
        duplicate.history_index = self.history_index;
        return duplicate;
    }

    pub fn historyTarget(self: *const BrowserTabRef, delta: i32) ?struct { index: usize, url: []const u8 } {
        const index = self.history_index orelse return null;
        const target: isize = @as(isize, @intCast(index)) + @as(isize, @intCast(delta));
        if (target < 0) return null;
        const target_index: usize = @intCast(target);
        if (target_index >= self.history.items.len) return null;
        return .{ .index = target_index, .url = self.history.items[target_index] };
    }
};

pub const BrowserPaneRef = struct {
    tabs: std.ArrayList(BrowserTabRef) = .empty,
    active_tab_index: usize = 0,

    pub fn deinit(self: *BrowserPaneRef, allocator: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| tab.deinit(allocator);
        self.tabs.deinit(allocator);
        self.* = .{};
    }

    pub fn ensureTab(self: *BrowserPaneRef, allocator: std.mem.Allocator) !*BrowserTabRef {
        if (self.tabs.items.len == 0) try self.tabs.append(allocator, .{});
        self.active_tab_index = @min(self.active_tab_index, self.tabs.items.len - 1);
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activeTab(self: *BrowserPaneRef) ?*BrowserTabRef {
        if (self.tabs.items.len == 0) return null;
        self.active_tab_index = @min(self.active_tab_index, self.tabs.items.len - 1);
        return &self.tabs.items[self.active_tab_index];
    }

    pub fn activeTabConst(self: *const BrowserPaneRef) ?*const BrowserTabRef {
        if (self.tabs.items.len == 0) return null;
        return &self.tabs.items[@min(self.active_tab_index, self.tabs.items.len - 1)];
    }

    pub fn moveTab(self: *BrowserPaneRef, allocator: std.mem.Allocator, from: usize, to: usize) !void {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return;
        const active = self.active_tab_index;
        const moved = self.tabs.orderedRemove(from);
        try self.tabs.insert(allocator, to, moved);
        self.active_tab_index = if (active == from)
            to
        else if (from < active and active <= to)
            active - 1
        else if (to <= active and active < from)
            active + 1
        else
            active;
    }
};

test "browser pane tabs preserve independent navigation and active state" {
    const allocator = std.testing.allocator;
    var pane: BrowserPaneRef = .{};
    defer pane.deinit(allocator);

    const first = try pane.ensureTab(allocator);
    try first.recordNavigation(allocator, "https://one.example/");
    try first.setTitle(allocator, "One");
    try pane.tabs.append(allocator, .{});
    pane.active_tab_index = 1;
    const second = pane.activeTab().?;
    try second.recordNavigation(allocator, "https://two.example/a");
    try second.recordNavigation(allocator, "https://two.example/b");

    try std.testing.expectEqual(@as(usize, 2), pane.tabs.items.len);
    try std.testing.expectEqualStrings("One", pane.tabs.items[0].title.?);
    try std.testing.expectEqualStrings("https://two.example/b", pane.activeTabConst().?.url.?);
    try std.testing.expectEqualStrings("https://two.example/a", pane.activeTabConst().?.historyTarget(-1).?.url);
}

test "browser pane tab clone and reorder preserve ownership and active state" {
    const allocator = std.testing.allocator;
    var pane: BrowserPaneRef = .{};
    defer pane.deinit(allocator);

    const first = try pane.ensureTab(allocator);
    try first.recordNavigation(allocator, "https://one.example/");
    try first.setTitle(allocator, "One");
    var duplicate = try first.clone(allocator);
    duplicate.pinned = true;
    try pane.tabs.append(allocator, duplicate);
    pane.active_tab_index = 1;
    try pane.moveTab(allocator, 1, 0);

    try std.testing.expectEqual(@as(usize, 0), pane.active_tab_index);
    try std.testing.expect(pane.tabs.items[0].pinned);
    try std.testing.expectEqualStrings("One", pane.tabs.items[0].title.?);
    try std.testing.expectEqualStrings("https://one.example/", pane.tabs.items[0].history.items[0]);
}
