//! Address-bar suggestion rows and the visit-recording gate for the browser
//! pane. Pure data so the ranking/plumbing can be tested without a runtime;
//! `browser_history_controller.zig` wires it to the daemon and the UI.
const std = @import("std");

pub const MAX_HISTORY_ROWS: u32 = 8;
pub const SEARCH_URL_PREFIX: []const u8 = "https://duckduckgo.com/?q=";

pub const Kind = enum { history, go_to, search };

pub const Suggestion = struct {
    kind: Kind,
    url: []const u8,
    /// Page title for history rows; the action label ("Go to …") otherwise.
    title: []const u8,
};

/// History entry shape the daemon returns; mirrored here so tests and the
/// row builder stay independent of the wire structs.
pub const HistoryEntry = struct {
    url: []const u8,
    title: []const u8,
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Suggestion = &.{},
    selected: ?usize = null,
    visible: bool = false,
    /// Ghost text to draw after the caret when the top history row completes
    /// the typed host; empty when there is no completion.
    completion: []const u8 = "",
    /// Visit-recording gate. Automation (MCP/live commands), restores, and
    /// tab switches set `pending_suppress` before navigating; the next
    /// `.navigated` event consumes it so redirects of that load stay
    /// unrecorded until the document loads or fails.
    pending_suppress: bool = false,
    in_flight_suppressed: bool = false,
    load_in_progress: bool = false,
    /// URL whose visit was already counted for the current page, so title
    /// updates only refresh the row instead of counting again.
    visit_recorded_url: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.visit_recorded_url) |url| allocator.free(url);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hide(self: *State) void {
        self.visible = false;
        self.selected = null;
        self.items = &.{};
        self.completion = "";
        _ = self.arena.reset(.retain_capacity);
    }

    /// Rebuilds the dropdown for `query` from ranked history entries; the
    /// arena is reset so previous rows are released in one step.
    pub fn setResults(self: *State, query: []const u8, entries: []const HistoryEntry) !void {
        self.items = &.{};
        self.completion = "";
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.items = try buildRows(a, query, entries);
        if (self.items.len > 0 and self.items[0].kind == .history) {
            self.completion = inlineCompletion(query, self.items[0].url) orelse "";
        }
        self.selected = if (self.items.len > 0) 0 else null;
        self.visible = true;
    }

    pub fn moveSelection(self: *State, delta: i32) void {
        if (!self.visible or self.items.len == 0) return;
        const count: i64 = @intCast(self.items.len);
        const current: i64 = if (self.selected) |index| @intCast(index) else -1;
        const next = @mod(current + delta, count);
        self.selected = @intCast(next);
    }

    pub fn selectedSuggestion(self: *const State) ?Suggestion {
        if (!self.visible) return null;
        const index = self.selected orelse return null;
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    pub fn setVisitRecordedUrl(self: *State, allocator: std.mem.Allocator, url: ?[]const u8) !void {
        const owned = if (url) |value| try allocator.dupe(u8, value) else null;
        if (self.visit_recorded_url) |old| allocator.free(old);
        self.visit_recorded_url = owned;
    }

    pub fn visitRecordedFor(self: *const State, url: []const u8) bool {
        const recorded = self.visit_recorded_url orelse return false;
        return std.mem.eql(u8, recorded, url);
    }

    /// `.navigated`: starts a load; returns whether the load should be recorded.
    pub fn noteNavigated(self: *State) void {
        if (self.pending_suppress) {
            self.in_flight_suppressed = true;
            self.pending_suppress = false;
        } else if (!self.load_in_progress) {
            self.in_flight_suppressed = false;
        }
        self.load_in_progress = true;
    }

    pub fn noteLoadFinished(self: *State) void {
        self.load_in_progress = false;
        self.in_flight_suppressed = false;
    }

    pub fn shouldRecordCurrentLoad(self: *const State) bool {
        return !self.in_flight_suppressed;
    }
};

/// Rows in display order: the top history row leads when it autocompletes
/// the typed host (Enter keeps the user on the page they were retyping);
/// otherwise the "Go to"/"Search" action row leads.
pub fn buildRows(allocator: std.mem.Allocator, query: []const u8, entries: []const HistoryEntry) ![]Suggestion {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    var rows: std.ArrayList(Suggestion) = .empty;
    if (trimmed.len == 0) return rows.toOwnedSlice(allocator);

    const history_count = @min(entries.len, @as(usize, MAX_HISTORY_ROWS));
    const primary: Suggestion = if (looksLikeUrl(trimmed)) .{
        .kind = .go_to,
        .url = try normalizeUrlAlloc(allocator, trimmed),
        .title = try std.fmt.allocPrint(allocator, "Go to {s}", .{trimmed}),
    } else .{
        .kind = .search,
        .url = try searchUrlAlloc(allocator, trimmed),
        .title = try std.fmt.allocPrint(allocator, "Search DuckDuckGo for \u{201C}{s}\u{201D}", .{trimmed}),
    };
    const lead_with_history = history_count > 0 and inlineCompletion(trimmed, entries[0].url) != null;

    var next_history: usize = 0;
    if (lead_with_history) {
        try rows.append(allocator, try historyRow(allocator, entries[0]));
        next_history = 1;
    }
    try rows.append(allocator, primary);
    while (next_history < history_count) : (next_history += 1) {
        try rows.append(allocator, try historyRow(allocator, entries[next_history]));
    }
    return rows.toOwnedSlice(allocator);
}

/// Copies the entry into `allocator`: callers free the daemon's history
/// response right after `setResults`, so rows must not borrow its strings.
fn historyRow(allocator: std.mem.Allocator, entry: HistoryEntry) !Suggestion {
    const url = try allocator.dupe(u8, entry.url);
    const title = if (entry.title.len > 0) try allocator.dupe(u8, entry.title) else url;
    return .{ .kind = .history, .url = url, .title = title };
}

/// Heuristic mirroring what browsers treat as an address rather than a
/// search: no spaces and a scheme, a dot, a port, or a localhost name.
pub fn looksLikeUrl(input: []const u8) bool {
    if (input.len == 0 or std.mem.indexOfAny(u8, input, " \t\r\n") != null) return false;
    if (std.mem.indexOf(u8, input, "://") != null) return true;
    if (std.ascii.startsWithIgnoreCase(input, "localhost")) return true;
    const host_end = std.mem.indexOfAny(u8, input, "/?#") orelse input.len;
    const host = input[0..host_end];
    if (host.len == 0) return false;
    if (std.mem.indexOfScalar(u8, host, ':')) |port_start| {
        const port = host[port_start + 1 ..];
        if (port.len > 0 and port.len <= 5 and allDigits(port)) return true;
    }
    if (std.mem.startsWith(u8, host, ".") or std.mem.endsWith(u8, host, ".")) return false;
    return std.mem.indexOfScalar(u8, host, '.') != null;
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn normalizeUrlAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, input, "://") != null) return allocator.dupe(u8, input);
    return std.fmt.allocPrint(allocator, "https://{s}", .{input});
}

/// Search URL with the query percent-encoded as a form value.
pub fn searchUrlAlloc(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, SEARCH_URL_PREFIX);
    for (query) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            var hex: [3]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "%{X:0>2}", .{c});
            try out.appendSlice(allocator, &hex);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Text to append after the caret so `typed` becomes the host (or, once the
/// user types a path, the full address) of `url`. Null when `url` does not
/// continue what was typed.
pub fn inlineCompletion(typed: []const u8, url: []const u8) ?[]const u8 {
    if (typed.len == 0) return null;
    const has_scheme = std.mem.indexOf(u8, typed, "://") != null;
    const candidate = if (has_scheme) url else hostPart(url);
    if (!std.ascii.startsWithIgnoreCase(candidate, typed)) return null;
    var rest = candidate[typed.len..];
    const typed_after_scheme = if (has_scheme) typed[(std.mem.indexOf(u8, typed, "://").? + 3)..] else typed;
    if (std.mem.indexOfScalar(u8, typed_after_scheme, '/') == null) {
        // Complete only through the host; the path is for the dropdown row.
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    }
    if (rest.len == 0) return null;
    return rest;
}

/// Scheme and leading "www." removed, matching what a user types.
pub fn hostPart(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |scheme_end| rest = rest[scheme_end + 3 ..];
    if (std.ascii.startsWithIgnoreCase(rest, "www.")) rest = rest[4..];
    return rest;
}

// -- tests -----------------------------------------------------------------

test "looksLikeUrl separates addresses from search terms" {
    try std.testing.expect(looksLikeUrl("example.com"));
    try std.testing.expect(looksLikeUrl("https://example.com/path"));
    try std.testing.expect(looksLikeUrl("localhost:3000"));
    try std.testing.expect(looksLikeUrl("127.0.0.1:8080/app"));
    try std.testing.expect(looksLikeUrl("sub.example.co.uk/a?b=c"));
    try std.testing.expect(!looksLikeUrl("zig std io"));
    try std.testing.expect(!looksLikeUrl("hello"));
    try std.testing.expect(!looksLikeUrl(".hidden"));
    try std.testing.expect(!looksLikeUrl("what is 1.5 x 2"));
    try std.testing.expect(!looksLikeUrl(""));
}

test "inlineCompletion completes the host only until a path is typed" {
    try std.testing.expectEqualStrings("lang.org", inlineCompletion("zig", "https://ziglang.org/documentation/").?);
    try std.testing.expectEqualStrings("lang.org", inlineCompletion("ZIG", "https://www.ziglang.org/").?);
    try std.testing.expectEqualStrings("documentation/", inlineCompletion("ziglang.org/", "https://ziglang.org/documentation/").?);
    try std.testing.expectEqualStrings("lang.org", inlineCompletion("https://zig", "https://ziglang.org/docs").?);
    try std.testing.expect(inlineCompletion("lang", "https://ziglang.org/") == null);
    try std.testing.expect(inlineCompletion("ziglang.org", "https://ziglang.org") == null);
    try std.testing.expect(inlineCompletion("", "https://ziglang.org/") == null);
}

test "setResults rows outlive the caller's history entries" {
    var state = State.init(std.testing.allocator);
    defer state.deinit(std.testing.allocator);
    const url = try std.testing.allocator.dupe(u8, "https://ziglang.org/");
    const title = try std.testing.allocator.dupe(u8, "Zig");
    try state.setResults("zig", &.{.{ .url = url, .title = title }});
    @memset(url, 'x');
    @memset(title, 'x');
    std.testing.allocator.free(url);
    std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("https://ziglang.org/", state.items[0].url);
    try std.testing.expectEqualStrings("Zig", state.items[0].title);
    try std.testing.expectEqualStrings("lang.org", state.completion);
}
