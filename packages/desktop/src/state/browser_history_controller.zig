//! Wires browser history to the app: records user-driven page loads through
//! the daemon, refreshes address-bar suggestions, and gates automation-driven
//! navigation out of history. Functions take `self: anytype` (the AppState)
//! like the other state controllers; the UI and browser_controller call them.
const std = @import("std");
const browser_suggestions = @import("browser_suggestions.zig");

const log = std.log.scoped(.native_shell);

/// Rebuilds the dropdown for the current address text. Called after every
/// edit while the field is focused; an empty field hides the dropdown.
pub fn refreshBrowserSuggestions(self: anytype) void {
    const suggestions = &self.browser_controller.suggestions;
    const query = std.mem.trim(u8, self.browser_controller.runtime.addressInput(), " \t\r\n");
    if (!self.browser_controller.address_focused or query.len == 0) {
        suggestions.hide();
        return;
    }
    var history_entries: [browser_suggestions.MAX_HISTORY_ROWS]browser_suggestions.HistoryEntry = undefined;
    var loaded = self.storage.queryBrowserHistory(self.allocator, query, browser_suggestions.MAX_HISTORY_ROWS) catch |err| {
        log.debug("browser history query unavailable: {s}", .{@errorName(err)});
        suggestions.setResults(query, &.{}) catch suggestions.hide();
        return;
    };
    defer loaded.deinit();
    var count: usize = 0;
    for (loaded.entries) |entry| {
        if (count == history_entries.len) break;
        history_entries[count] = .{ .url = entry.url, .title = entry.title };
        count += 1;
    }
    suggestions.setResults(query, history_entries[0..count]) catch suggestions.hide();
}

pub fn hideBrowserSuggestions(self: anytype) void {
    self.browser_controller.suggestions.hide();
}

pub fn browserSuggestionsVisible(self: anytype) bool {
    const suggestions = &self.browser_controller.suggestions;
    return suggestions.visible and suggestions.items.len > 0;
}

pub fn moveBrowserSuggestionSelection(self: anytype, delta: i32) void {
    self.browser_controller.suggestions.moveSelection(delta);
}

pub fn selectBrowserSuggestion(self: anytype, index: usize) void {
    const suggestions = &self.browser_controller.suggestions;
    if (index < suggestions.items.len) suggestions.selected = index;
}

/// Opens the highlighted row. Returns false when nothing is selected so the
/// caller falls back to navigating the typed address.
pub fn acceptBrowserSuggestion(self: anytype) bool {
    const suggestion = self.browser_controller.suggestions.selectedSuggestion() orelse return false;
    const url = self.allocator.dupe(u8, suggestion.url) catch return false;
    defer self.allocator.free(url);
    self.browser_controller.suggestions.hide();
    noteUserBrowserNavigation(self);
    self.navigateBrowserToUrl(url) catch |err| switch (err) {
        error.BrowserNavigationFailed => {},
        else => self.setSidebarNotice("Failed to open suggestion."),
    };
    return true;
}

/// Explicit user navigation: whatever loads next is browsing history.
pub fn noteUserBrowserNavigation(self: anytype) void {
    self.browser_controller.suggestions.pending_suppress = false;
}

/// Automation, restores, and tab switches call this before navigating so the
/// resulting load is not counted as a visit.
pub fn beginSuppressedBrowserNavigation(self: anytype) void {
    self.browser_controller.suggestions.pending_suppress = true;
}

pub fn noteBrowserNavigated(self: anytype, url: []const u8) void {
    const suggestions = &self.browser_controller.suggestions;
    suggestions.noteNavigated();
    if (!suggestions.visitRecordedFor(url)) {
        suggestions.setVisitRecordedUrl(self.allocator, null) catch {};
    }
}

pub fn noteBrowserDocumentLoaded(self: anytype) void {
    const suggestions = &self.browser_controller.suggestions;
    defer suggestions.noteLoadFinished();
    if (!suggestions.shouldRecordCurrentLoad()) return;
    recordCurrentPageVisit(self);
}

pub fn noteBrowserTitleChanged(self: anytype) void {
    const suggestions = &self.browser_controller.suggestions;
    const url = self.browser_controller.runtime.current_url orelse return;
    if (suggestions.visitRecordedFor(url)) {
        const title = self.browser_controller.runtime.current_title orelse return;
        self.storage.recordBrowserVisit(url, title, false) catch |err| {
            log.debug("browser history title update failed: {s}", .{@errorName(err)});
        };
        return;
    }
    // A title arriving after the load settled is an in-page (pushState)
    // navigation the load events never announced.
    if (suggestions.load_in_progress or !suggestions.shouldRecordCurrentLoad()) return;
    recordCurrentPageVisit(self);
}

pub fn noteBrowserLoadFailed(self: anytype) void {
    self.browser_controller.suggestions.noteLoadFinished();
}

fn recordCurrentPageVisit(self: anytype) void {
    const suggestions = &self.browser_controller.suggestions;
    const url = self.browser_controller.runtime.current_url orelse return;
    if (!isRecordableUrl(url) or suggestions.visitRecordedFor(url)) return;
    const title = self.browser_controller.runtime.current_title orelse "";
    self.storage.recordBrowserVisit(url, title, true) catch |err| {
        log.debug("browser history record failed: {s}", .{@errorName(err)});
        return;
    };
    suggestions.setVisitRecordedUrl(self.allocator, url) catch {};
}

/// Mirrors the daemon's acceptance rule so the GUI skips the round trip for
/// blank tabs, inline documents, and internal pages.
pub fn isRecordableUrl(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..scheme_end];
    if (scheme.len == 0 or url.len <= scheme_end + 3) return false;
    return std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
}

pub fn clearBrowserHistory(self: anytype) void {
    self.browser_controller.suggestions.hide();
    self.browser_controller.suggestions.setVisitRecordedUrl(self.allocator, null) catch {};
    self.storage.clearBrowserHistory() catch |err| {
        log.warn("failed to clear browser history: {s}", .{@errorName(err)});
        self.setSidebarNotice("Failed to clear browsing history.");
        return;
    };
    self.setSidebarNotice("Browsing history cleared.");
}

test "isRecordableUrl only admits http(s) pages" {
    try std.testing.expect(isRecordableUrl("https://example.com/"));
    try std.testing.expect(isRecordableUrl("http://localhost:3000"));
    try std.testing.expect(!isRecordableUrl("about:blank"));
    try std.testing.expect(!isRecordableUrl("data:text/html,hi"));
    try std.testing.expect(!isRecordableUrl("file:///tmp/x.html"));
    try std.testing.expect(!isRecordableUrl("https://"));
}
