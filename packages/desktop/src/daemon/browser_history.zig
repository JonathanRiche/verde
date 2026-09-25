//! Durable browser history: visit recording plus frecency-ranked lookup for
//! address-bar suggestions. Daemon-only; the GUI reaches this through the
//! `browser.history.*` socket methods.
const std = @import("std");
const zqlite = @import("zqlite");

pub const MAX_URL_BYTES: usize = 2048;
pub const MAX_TITLE_BYTES: usize = 512;
pub const MAX_QUERY_BYTES: usize = 256;
pub const DEFAULT_LIMIT: usize = 8;
pub const MAX_LIMIT: usize = 50;
/// Most-recent rows considered per query; keeps per-keystroke ranking cheap
/// while covering everything a user is likely to retype.
const CANDIDATE_WINDOW: usize = 400;
const MAX_TERMS: usize = 6;

pub const Entry = struct {
    url: []const u8,
    title: []const u8,
    visit_count: u32,
    last_visit_ms: i64,
};

/// Only real page loads belong in history: internal, inline, and script
/// pseudo-URLs are rejected so they never surface as suggestions.
pub fn isRecordableUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > MAX_URL_BYTES) return false;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    if (scheme_end == 0) return false;
    const scheme = url[0..scheme_end];
    for (scheme) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    if (std.ascii.eqlIgnoreCase(scheme, "about") or std.ascii.eqlIgnoreCase(scheme, "data") or
        std.ascii.eqlIgnoreCase(scheme, "blob") or std.ascii.eqlIgnoreCase(scheme, "javascript") or
        std.ascii.eqlIgnoreCase(scheme, "file")) return false;
    return url.len > scheme_end + 3;
}

/// Counts one visit, refreshing recency; an empty title keeps the stored one
/// because navigation events arrive before the document title does.
pub fn recordVisit(conn: zqlite.Conn, url: []const u8, title: []const u8, now_ms: i64) !void {
    if (!isRecordableUrl(url)) return error.InvalidParams;
    const clipped_title = clipTitle(title);
    try conn.exec(
        \\insert into browser_history (url, title, visit_count, last_visit_ms) values (?, ?, 1, ?)
        \\on conflict(url) do update set
        \\  visit_count = visit_count + 1,
        \\  last_visit_ms = max(last_visit_ms, excluded.last_visit_ms),
        \\  title = case when excluded.title <> '' then excluded.title else browser_history.title end
    , .{ url, clipped_title, @max(now_ms, 0) });
}

/// Attaches a late-arriving document title to an already recorded visit.
pub fn updateTitle(conn: zqlite.Conn, url: []const u8, title: []const u8) !void {
    if (!isRecordableUrl(url)) return error.InvalidParams;
    const clipped_title = clipTitle(title);
    if (clipped_title.len == 0) return;
    try conn.exec("update browser_history set title = ? where url = ?", .{ clipped_title, url });
}

pub fn clear(conn: zqlite.Conn) !void {
    try conn.execNoArgs("delete from browser_history");
}

/// Returns up to `limit` entries matching every whitespace-separated term of
/// `query_text` (case-insensitive, against URL or title), best frecency first.
/// An empty query yields the most frecent pages. Results are arena-owned.
pub fn query(
    conn: zqlite.Conn,
    arena: std.mem.Allocator,
    query_text: []const u8,
    limit: usize,
    now_ms: i64,
) ![]Entry {
    const trimmed = std.mem.trim(u8, query_text, " \t\r\n");
    if (trimmed.len > MAX_QUERY_BYTES) return error.InvalidParams;
    const capped_limit = @min(@max(limit, 1), MAX_LIMIT);

    var terms_buf: [MAX_TERMS][]const u8 = undefined;
    var term_count: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    while (it.next()) |term| : (term_count += 1) {
        if (term_count == MAX_TERMS) break;
        terms_buf[term_count] = term;
    }
    const terms = terms_buf[0..term_count];

    const Scored = struct {
        entry: Entry,
        score: f64,

        fn better(_: void, a: @This(), b: @This()) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.entry.last_visit_ms > b.entry.last_visit_ms;
        }
    };
    var scored: std.ArrayList(Scored) = .empty;

    var rows = try conn.rows(
        "select url, title, visit_count, last_visit_ms from browser_history order by last_visit_ms desc, visit_count desc limit ?",
        .{@as(i64, @intCast(CANDIDATE_WINDOW))},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        const url = row.text(0);
        const title = row.text(1);
        const boost = matchBoost(url, title, terms) orelse continue;
        const visit_count: u32 = @intCast(@max(row.int(2), 1));
        const last_visit_ms = row.int(3);
        try scored.append(arena, .{
            .entry = .{
                .url = try arena.dupe(u8, url),
                .title = try arena.dupe(u8, title),
                .visit_count = visit_count,
                .last_visit_ms = last_visit_ms,
            },
            .score = frecencyScore(visit_count, last_visit_ms, now_ms) * boost,
        });
    }
    if (rows.err) |err| return err;

    std.mem.sort(Scored, scored.items, {}, Scored.better);
    const count = @min(scored.items.len, capped_limit);
    const entries = try arena.alloc(Entry, count);
    for (entries, scored.items[0..count]) |*entry, item| entry.* = item.entry;
    return entries;
}

/// Firefox-style frecency: each visit is worth a recency-bucket weight, so a
/// page opened daily outranks one opened many times last year.
pub fn frecencyScore(visit_count: u32, last_visit_ms: i64, now_ms: i64) f64 {
    const age_ms: i64 = @max(now_ms - last_visit_ms, 0);
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const weight: f64 = if (age_ms <= 4 * day_ms)
        100.0
    else if (age_ms <= 14 * day_ms)
        70.0
    else if (age_ms <= 31 * day_ms)
        50.0
    else if (age_ms <= 90 * day_ms)
        30.0
    else if (age_ms <= 365 * day_ms)
        10.0
    else
        1.0;
    return weight * @as(f64, @floatFromInt(visit_count));
}

/// Null when any term misses both URL and title. Otherwise 2.0 for a typed
/// prefix of the host (what people retype most), 1.5 for a title word prefix,
/// 1.0 for a plain substring hit.
pub fn matchBoost(url: []const u8, title: []const u8, terms: []const []const u8) ?f64 {
    if (terms.len == 0) return 1.0;
    var boost: f64 = 1.0;
    for (terms, 0..) |term, index| {
        const in_url = containsIgnoreCase(url, term);
        const in_title = containsIgnoreCase(title, term);
        if (!in_url and !in_title) return null;
        if (index != 0) continue;
        if (in_url and startsWithIgnoreCase(hostPart(url), term)) {
            boost = 2.0;
        } else if (in_title and titleWordPrefix(title, term)) {
            boost = 1.5;
        }
    }
    return boost;
}

/// Host and path with the scheme and a leading "www." removed, matching what a
/// user types into the address bar.
pub fn hostPart(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |scheme_end| rest = rest[scheme_end + 3 ..];
    if (startsWithIgnoreCase(rest, "www.")) rest = rest[4..];
    return rest;
}

fn titleWordPrefix(title: []const u8, term: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, title, " \t-_/|:·—–,.()[]");
    while (words.next()) |word| {
        if (startsWithIgnoreCase(word, term)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(haystack, prefix);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn clipTitle(title: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n");
    if (trimmed.len <= MAX_TITLE_BYTES) return trimmed;
    // Cut on a UTF-8 boundary so the stored title stays valid text.
    var end = MAX_TITLE_BYTES;
    while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
    return trimmed[0..end];
}

// -- tests -----------------------------------------------------------------

const schema = @import("../db/schema.zig");

const TestDb = struct {
    tmp: std.testing.TmpDir,
    conn: zqlite.Conn,

    fn open() !TestDb {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
        const path = try std.fs.path.joinZ(std.testing.allocator, &.{ path_buf[0..path_len], "state.sqlite" });
        defer std.testing.allocator.free(path);
        const conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        errdefer conn.close();
        try schema.initializeToVersion(conn, schema.MAX_SUPPORTED_VERSION);
        return .{ .tmp = tmp, .conn = conn };
    }

    fn close(self: *TestDb) void {
        self.conn.close();
        self.tmp.cleanup();
    }
};

test "isRecordableUrl accepts web pages and rejects internal schemes" {
    try std.testing.expect(isRecordableUrl("https://example.com/"));
    try std.testing.expect(isRecordableUrl("http://localhost:3000/app"));
    try std.testing.expect(!isRecordableUrl(""));
    try std.testing.expect(!isRecordableUrl("about:blank"));
    try std.testing.expect(!isRecordableUrl("about://blank"));
    try std.testing.expect(!isRecordableUrl("data:text/html,<p>x</p>"));
    try std.testing.expect(!isRecordableUrl("blob://host/id"));
    try std.testing.expect(!isRecordableUrl("javascript://void(0)"));
    try std.testing.expect(!isRecordableUrl("example.com"));
    try std.testing.expect(!isRecordableUrl("https://"));
}

test "recordVisit upserts counts, refreshes recency, and keeps titles across untitled visits" {
    var db = try TestDb.open();
    defer db.close();

    try recordVisit(db.conn, "https://ziglang.org/", "", 1_000);
    try recordVisit(db.conn, "https://ziglang.org/", "Zig Programming Language", 2_000);
    try recordVisit(db.conn, "https://ziglang.org/", "", 3_000);
    try updateTitle(db.conn, "https://ziglang.org/", "");
    try std.testing.expectError(error.InvalidParams, recordVisit(db.conn, "about:blank", "", 4_000));

    var row = (try db.conn.row("select visit_count, last_visit_ms, title from browser_history where url = ?", .{"https://ziglang.org/"})).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 3), row.int(0));
    try std.testing.expectEqual(@as(i64, 3_000), row.int(1));
    try std.testing.expectEqualStrings("Zig Programming Language", row.text(2));

    try updateTitle(db.conn, "https://ziglang.org/", "Zig ⚡");
    var updated = (try db.conn.row("select title from browser_history where url = ?", .{"https://ziglang.org/"})).?;
    defer updated.deinit();
    try std.testing.expectEqualStrings("Zig ⚡", updated.text(0));
}

test "query ranks by frecency and match quality, filters by every term, and clears" {
    var db = try TestDb.open();
    defer db.close();
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const now_ms: i64 = 400 * day_ms;

    // Visited often but long ago.
    var i: usize = 0;
    while (i < 20) : (i += 1) try recordVisit(db.conn, "https://old.example.com/docs", "Old Docs", 10 * day_ms);
    // Visited once, today.
    try recordVisit(db.conn, "https://fresh.example.com/", "Fresh Example", now_ms - day_ms);
    // Visited a few times recently: title match only.
    try recordVisit(db.conn, "https://ziglang.org/documentation/master/", "Zig Language Reference", now_ms - day_ms);
    try recordVisit(db.conn, "https://ziglang.org/documentation/master/", "Zig Language Reference", now_ms - day_ms);
    try recordVisit(db.conn, "https://news.example.org/", "Daily News", now_ms);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Title word prefix (1.5x) beats the bare URL substring hit on the news site
    // at equal recency; twenty stale visits trail both fresh ones.
    const example = try query(db.conn, arena, "example", 8, now_ms);
    try std.testing.expectEqual(@as(usize, 3), example.len);
    try std.testing.expectEqualStrings("https://fresh.example.com/", example[0].url);
    try std.testing.expectEqualStrings("https://news.example.org/", example[1].url);
    try std.testing.expectEqualStrings("https://old.example.com/docs", example[2].url);
    try std.testing.expectEqual(@as(u32, 20), example[2].visit_count);

    // Typing the host prefix outranks everything else matching the same term.
    const host = try query(db.conn, arena, "old.ex", 8, now_ms);
    try std.testing.expectEqual(@as(usize, 1), host.len);
    try std.testing.expectEqualStrings("Old Docs", host[0].title);

    // Multi-term: both terms must match somewhere in url/title, case-insensitively.
    const multi = try query(db.conn, arena, "ZIG reference", 8, now_ms);
    try std.testing.expectEqual(@as(usize, 1), multi.len);
    try std.testing.expectEqualStrings("Zig Language Reference", multi[0].title);
    try std.testing.expectEqual(@as(usize, 0), (try query(db.conn, arena, "zig missing", 8, now_ms)).len);

    // Empty query returns the most frecent entries, capped by limit; equal
    // scores tie-break on recency.
    const top = try query(db.conn, arena, "  ", 2, now_ms);
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqualStrings("https://ziglang.org/documentation/master/", top[0].url);
    try std.testing.expectEqualStrings("https://news.example.org/", top[1].url);

    try clear(db.conn);
    try std.testing.expectEqual(@as(usize, 0), (try query(db.conn, arena, "", 8, now_ms)).len);
}

test "frecency weights recent visits above stale visit counts" {
    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const now: i64 = 1000 * day_ms;
    try std.testing.expect(frecencyScore(1, now - day_ms, now) > frecencyScore(9, now - 400 * day_ms, now));
    try std.testing.expect(frecencyScore(3, now - 10 * day_ms, now) > frecencyScore(2, now - 10 * day_ms, now));
    try std.testing.expectEqual(@as(f64, 100.0), frecencyScore(1, now + day_ms, now));
}
