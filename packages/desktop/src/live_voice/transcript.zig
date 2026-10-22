//! The text record of a live voice session, saved into the Companion's chat.
//! A port of the phone recorder (`LiveTranscript.kt`): one line per user turn
//! (everything said between replies or system lines, merged by
//! `mergeSpeechPieces`) and per spoken reply (streaming pieces merged), plus
//! short system lines for tool hand-offs. Never audio. Pure and unit tested.

const std = @import("std");

const Self = @This();

pub const USER_AUTHOR = "You (voice)";
pub const SYSTEM_AUTHOR = "Live";
pub const SAVE_INTERVAL_MS: i64 = 120_000;
/// No transcript update for this long ends the user's utterance.
pub const USER_LINE_IDLE_MS: i64 = 3_000;

pub const Role = enum { user, assistant, system };

/// A user or companion line. User lines are `open` while being spoken, then
/// closed; only `committed` lines are saved.
pub const Line = struct {
    key: u32,
    role: Role,
    body: []u8,
    created_at_ms: i64,
    open: bool,
    committed: bool,
};

pub const Caption = struct { user: bool, text: []const u8, open: bool };

allocator: std.mem.Allocator,
/// Stable per session: saved message ids are `live:<session_id>:<key>`.
session_id: [16]u8,
assistant_author: []u8,
lines: std.ArrayList(Line) = .empty,
/// The utterances merged into a user turn line, by line key.
pieces: std.AutoHashMapUnmanaged(u32, std.ArrayList([]u8)) = .empty,
next: u32 = 0,
open_user: ?u32 = null,
open_item: ?[]u8 = null,
last_user_update: i64 = 0,
open_assistant: ?u32 = null,
/// Closed by a pause or a new item, not yet committed: a longer snapshot of
/// the same words replaces it.
tentative: ?u32 = null,
tentative_item: ?[]u8 = null,
/// Committed by the reply starting; a late final transcript (OpenAI) may still correct it.
unconfirmed_user: ?u32 = null,
/// xAI-style cumulative transcripts keep growing across utterances.
cumulative_stream: bool = false,
stream_norm: std.ArrayList(u8) = .empty,
last_committed_norm: std.ArrayList(u8) = .empty,
last_closed_user_norm: std.ArrayList(u8) = .empty,
/// Lines before this index are saved (or were blank).
saved: usize = 0,

pub fn init(allocator: std.mem.Allocator, companion_name: []const u8, session_id: [16]u8) !Self {
    const name = std.mem.trim(u8, companion_name, &std.ascii.whitespace);
    return .{
        .allocator = allocator,
        .session_id = session_id,
        .assistant_author = try std.fmt.allocPrint(allocator, "{s} (voice)", .{if (name.len > 0) name else "Companion"}),
    };
}

pub fn deinit(self: *Self) void {
    const a = self.allocator;
    for (self.lines.items) |line| a.free(line.body);
    self.lines.deinit(a);
    var it = self.pieces.valueIterator();
    while (it.next()) |list| freePieces(a, list);
    self.pieces.deinit(a);
    if (self.open_item) |item| a.free(item);
    if (self.tentative_item) |item| a.free(item);
    self.stream_norm.deinit(a);
    self.last_committed_norm.deinit(a);
    self.last_closed_user_norm.deinit(a);
    a.free(self.assistant_author);
    self.* = undefined;
}

pub fn authorOf(self: *const Self, role: Role) []const u8 {
    return switch (role) {
        .user => USER_AUTHOR,
        .assistant => self.assistant_author,
        .system => SYSTEM_AUTHOR,
    };
}

/// Content worth saving: anything the user or the companion actually said.
pub fn hasContent(self: *const Self) bool {
    for (self.lines.items) |line| if (line.role != .system and !isBlank(line.body)) return true;
    return false;
}

pub fn header(self: *Self, text: []const u8, now: i64) !void {
    if (self.lines.items.len == 0) _ = try self.add(.system, text, now, false, true);
}

pub fn system(self: *Self, text: []const u8, now: i64) !void {
    _ = try self.add(.system, text, now, false, true);
}

pub fn userPartial(self: *Self, text: []const u8, cumulative: bool, now: i64, item_id: ?[]const u8) !void {
    if (cumulative) self.cumulative_stream = true;
    // A different transcription item is a different utterance.
    if (self.open_user != null and item_id != null and self.open_item != null and !std.mem.eql(u8, item_id.?, self.open_item.?)) _ = try self.closeUser(false);
    const body = if (cumulative) try self.strip(text) else text;
    if (self.open_user == null) {
        const start = std.mem.trimStart(u8, body, &std.ascii.whitespace);
        if (isBlank(start)) return;
        try self.settleTentative(start);
        self.unconfirmed_user = null;
        self.open_user = try self.add(.user, start, now, true, false);
        try self.setItem(&self.open_item, item_id);
    } else if (cumulative) {
        // Same item: the snapshot replaces the line; an empty remainder changes nothing.
        if (!isBlank(body)) try self.setBody(self.open_user, body);
    } else {
        try self.appendBody(self.open_user, text);
    }
    self.last_user_update = now;
}

pub fn userFinal(self: *Self, text: []const u8, now: i64, item_id: ?[]const u8) !void {
    const body = if (self.cumulative_stream) try self.strip(text) else std.mem.trim(u8, text, &std.ascii.whitespace);
    if (self.open_user != null and (item_id == null or self.open_item == null or std.mem.eql(u8, item_id.?, self.open_item.?))) {
        if (!isBlank(body)) try self.setBody(self.open_user, body);
        _ = try self.closeUser(true);
        return;
    }
    if (item_id != null and self.tentative != null and self.tentative_item != null and std.mem.eql(u8, item_id.?, self.tentative_item.?)) {
        if (!isBlank(body)) try self.setBody(self.tentative, body);
        _ = try self.commit(self.tentative, true);
        self.clearTentative();
        return;
    }
    const late = self.unconfirmed_user;
    self.unconfirmed_user = null;
    if (late) |key| if (self.index(key)) |i| if (i >= self.saved) {
        if (!isBlank(body)) try self.correctLastUtterance(key, body);
        return;
    };
    if (isBlank(body)) return;
    const norm = try normalizeAlloc(self.allocator, body);
    defer self.allocator.free(norm);
    if (std.mem.eql(u8, norm, self.last_closed_user_norm.items)) return;
    try self.settleTentative(body);
    const key = try self.add(.user, body, now, false, false);
    try setList(self.allocator, &self.last_closed_user_norm, norm);
    _ = try self.commit(key, true);
}

/// No transcript update for a while: the utterance is over (not yet committed).
pub fn tick(self: *Self, now: i64) !void {
    if (self.open_user != null and now - self.last_user_update >= USER_LINE_IDLE_MS) _ = try self.closeUser(false);
}

/// The model began answering: the user's utterance is done.
pub fn assistantStarted(self: *Self) !void {
    const user = try self.closeUser(true);
    if (user) |key| if (self.index(key) != null) {
        self.unconfirmed_user = key;
    };
    if (self.tentative) |key| _ = try self.commit(key, false);
    self.clearTentative();
}

pub fn assistantDelta(self: *Self, delta: []const u8, now: i64) !void {
    if (self.open_assistant == null) {
        if (isBlank(delta)) return;
        try self.assistantStarted();
        self.open_assistant = try self.add(.assistant, std.mem.trimStart(u8, delta, &std.ascii.whitespace), now, true, false);
    } else {
        try self.appendBody(self.open_assistant, delta);
    }
}

/// End of a response (or barge-in): the reply line is complete as heard.
pub fn assistantDone(self: *Self) !void {
    const key = self.open_assistant orelse return;
    self.open_assistant = null;
    const i = self.index(key) orelse return;
    const line = &self.lines.items[i];
    try self.replaceBody(line, std.mem.trim(u8, line.body, &std.ascii.whitespace));
    line.open = false;
    line.committed = true;
}

/// Recent spoken lines for the live captions: the same merged, de-duplicated
/// lines that get saved. Fills `out` oldest first; returns the count.
pub fn captions(self: *const Self, out: []Caption) usize {
    var count: usize = 0;
    var i = self.lines.items.len;
    while (i > 0 and count < out.len) {
        i -= 1;
        const line = self.lines.items[i];
        if (line.role == .system or isBlank(line.body)) continue;
        count += 1;
        out[out.len - count] = .{ .user = line.role == .user, .text = line.body, .open = line.open };
    }
    std.mem.copyForwards(Caption, out[0..count], out[out.len - count ..]);
    return count;
}

/// Lines ready to save, as a count starting at `saved`: committed lines,
/// stopping at the first line still being spoken or not yet committed, or at
/// the current turn's user line (it may still absorb more speech until a
/// reply or system line follows). `final` closes and commits everything.
pub fn pending(self: *Self, final: bool) !usize {
    if (final) {
        try self.assistantDone();
        _ = try self.closeUser(true);
        if (self.tentative) |key| _ = try self.commit(key, false);
        self.clearTentative();
    }
    if (!self.hasContent()) return 0;
    var count: usize = 0;
    for (self.lines.items[self.saved..], self.saved..) |line, i| {
        if (line.open or !line.committed) break;
        if (!final and line.role == .user) {
            const rest_all_user = for (self.lines.items[i + 1 ..]) |later| {
                if (later.role != .user) break false;
            } else true;
            if (rest_all_user) break;
        }
        count += 1;
    }
    return count;
}

pub fn pendingLines(self: *const Self, count: usize) []const Line {
    return self.lines.items[self.saved..][0..count];
}

/// The first `count` pending lines are stored; later saves start after them.
pub fn markSaved(self: *Self, count: usize) void {
    self.saved = @min(self.saved + count, self.lines.items.len);
}

// ---- internals -------------------------------------------------------------------

fn index(self: *const Self, key: ?u32) ?usize {
    const wanted = key orelse return null;
    for (self.lines.items, 0..) |line, i| if (line.key == wanted) return i;
    return null;
}

fn add(self: *Self, role: Role, body: []const u8, now: i64, open: bool, committed: bool) !u32 {
    const key = self.next;
    self.next += 1;
    const owned = try self.allocator.dupe(u8, body);
    errdefer self.allocator.free(owned);
    try self.lines.append(self.allocator, .{ .key = key, .role = role, .body = owned, .created_at_ms = now, .open = open, .committed = committed });
    return key;
}

fn replaceBody(self: *Self, line: *Line, body: []const u8) !void {
    const owned = try self.allocator.dupe(u8, body);
    self.allocator.free(line.body);
    line.body = owned;
}

fn setBody(self: *Self, key: ?u32, body: []const u8) !void {
    const i = self.index(key) orelse return;
    try self.replaceBody(&self.lines.items[i], body);
}

fn appendBody(self: *Self, key: ?u32, text: []const u8) !void {
    const i = self.index(key) orelse return;
    const line = &self.lines.items[i];
    const joined = try std.mem.concat(self.allocator, u8, &.{ line.body, text });
    self.allocator.free(line.body);
    line.body = joined;
}

/// Removes an unsaved line (a superseded or repeated utterance).
fn drop(self: *Self, key: ?u32) void {
    const i = self.index(key) orelse return;
    if (i < self.saved) return;
    const line = self.lines.orderedRemove(i);
    self.allocator.free(line.body);
    if (self.pieces.fetchRemove(line.key)) |entry| {
        var list = entry.value;
        freePieces(self.allocator, &list);
    }
}

fn setItem(self: *Self, slot: *?[]u8, item: ?[]const u8) !void {
    if (slot.*) |old| self.allocator.free(old);
    slot.* = null;
    if (item) |value| slot.* = try self.allocator.dupe(u8, value);
}

fn clearTentative(self: *Self) void {
    self.tentative = null;
    if (self.tentative_item) |item| self.allocator.free(item);
    self.tentative_item = null;
}

/// A cumulative snapshot without the words earlier committed lines already hold.
fn strip(self: *Self, text: []const u8) ![]const u8 {
    const words = try normalizeAlloc(self.allocator, text);
    defer self.allocator.free(words);
    const prefix_len = blk: {
        if (extendsSpeech(words, self.stream_norm.items)) break :blk self.stream_norm.items.len;
        if (extendsSpeech(words, self.last_committed_norm.items)) break :blk self.last_committed_norm.items.len;
        self.stream_norm.clearRetainingCapacity();
        break :blk 0;
    };
    return speechRemainder(text, prefix_len);
}

/// Closes the open utterance; when `commit`ted, returns the key of the line now holding it.
fn closeUser(self: *Self, commit_line: bool) !?u32 {
    const key = self.open_user orelse return null;
    const item = self.open_item;
    self.open_user = null;
    self.open_item = null;
    defer if (item) |value| self.allocator.free(value);
    const i = self.index(key) orelse return null;
    const line = &self.lines.items[i];
    try self.replaceBody(line, std.mem.trim(u8, line.body, &std.ascii.whitespace));
    const words = try normalizeAlloc(self.allocator, line.body);
    defer self.allocator.free(words);
    // An exact repeat of the previous utterance is the same utterance reported twice.
    if (words.len == 0 or std.mem.eql(u8, words, self.last_closed_user_norm.items)) {
        self.drop(key);
        return null;
    }
    line.open = false;
    line.committed = false;
    try setList(self.allocator, &self.last_closed_user_norm, words);
    if (commit_line) return try self.commit(key, true);
    if (self.tentative) |previous| _ = try self.commit(previous, false);
    self.clearTentative();
    self.tentative = key;
    try self.setItem(&self.tentative_item, item);
    return null;
}

/// A new utterance `start`s: a tentative line it merely extends is dropped, otherwise it is committed.
fn settleTentative(self: *Self, start: []const u8) !void {
    const key = self.tentative orelse return;
    self.clearTentative();
    const i = self.index(key) orelse return;
    const start_norm = try normalizeAlloc(self.allocator, start);
    defer self.allocator.free(start_norm);
    const line_norm = try normalizeAlloc(self.allocator, self.lines.items[i].body);
    defer self.allocator.free(line_norm);
    if (extendsSpeech(start_norm, line_norm) and i >= self.saved) {
        self.drop(key);
    } else {
        _ = try self.commit(key, false);
    }
}

/// Commits a line; a user utterance then joins its turn's line. Returns the key now holding it.
fn commit(self: *Self, key: ?u32, stream: bool) !?u32 {
    const i = self.index(key) orelse return null;
    const line = &self.lines.items[i];
    line.open = false;
    line.committed = true;
    if (line.role != .user) return line.key;
    if (stream and self.cumulative_stream) {
        const words = try normalizeAlloc(self.allocator, line.body);
        defer self.allocator.free(words);
        if (self.stream_norm.items.len > 0) try self.stream_norm.append(self.allocator, ' ');
        try self.stream_norm.appendSlice(self.allocator, words);
        try setList(self.allocator, &self.last_committed_norm, words);
    }
    return try self.joinTurn(line.key);
}

/// One line per user turn: a committed utterance directly after the turn's
/// committed, unsaved user line folds into it instead of standing alone.
fn joinTurn(self: *Self, key: u32) !u32 {
    const i = self.index(key) orelse return key;
    if (i == 0 or i - 1 < self.saved) return key;
    const prev = self.lines.items[i - 1];
    if (prev.role != .user or prev.open or !prev.committed) return key;
    const entry = try self.pieces.getOrPut(self.allocator, prev.key);
    if (!entry.found_existing) {
        entry.value_ptr.* = .empty;
        try entry.value_ptr.append(self.allocator, try self.allocator.dupe(u8, prev.body));
    }
    try mergeSpeechPieces(self.allocator, entry.value_ptr, self.lines.items[i].body);
    const joined = try joinPieces(self.allocator, entry.value_ptr.items);
    self.allocator.free(self.lines.items[i - 1].body);
    self.lines.items[i - 1].body = joined;
    const removed = self.lines.orderedRemove(i);
    self.allocator.free(removed.body);
    if (self.pieces.fetchRemove(key)) |old| {
        var list = old.value;
        freePieces(self.allocator, &list);
    }
    return prev.key;
}

/// A late final transcript corrects the turn line's latest utterance (the last merged piece).
fn correctLastUtterance(self: *Self, key: u32, body: []const u8) !void {
    const list = self.pieces.getPtr(key) orelse return self.setBody(key, body);
    if (list.pop()) |last| self.allocator.free(last);
    try mergeSpeechPieces(self.allocator, list, body);
    const joined = try joinPieces(self.allocator, list.items);
    defer self.allocator.free(joined);
    try self.setBody(key, joined);
}

fn freePieces(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |piece| allocator.free(piece);
    list.deinit(allocator);
}

fn setList(allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(allocator, value);
}

fn joinPieces(allocator: std.mem.Allocator, pieces: []const []u8) ![]u8 {
    return std.mem.join(allocator, " ", pieces);
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, &std.ascii.whitespace).len == 0;
}

// ---- speech text helpers ------------------------------------------------------------

/// Bytes of one UTF-8 sequence starting with `lead` (1 for stray bytes).
fn sequenceLen(lead: u8) usize {
    return std.unicode.utf8ByteSequenceLength(lead) catch 1;
}

/// Letters and digits; every non-ASCII character counts as a letter.
fn isWordStart(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte);
}

/// Lowercase words only: punctuation dropped, whitespace collapsed (for
/// comparing transcript snapshots).
pub fn normalizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var space = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (isWordStart(byte)) {
            const len = @min(sequenceLen(byte), text.len - i);
            if (space and out.items.len > 0) try out.append(allocator, ' ');
            space = false;
            if (len == 1) {
                try out.append(allocator, std.ascii.toLower(byte));
            } else if (len == 2 and byte == 0xC3 and text[i + 1] >= 0x80 and text[i + 1] <= 0x9E and text[i + 1] != 0x97) {
                // Latin-1 capitals (À..Þ, not ×) fold to lowercase in place.
                try out.appendSlice(allocator, &.{ byte, text[i + 1] + 0x20 });
            } else {
                try out.appendSlice(allocator, text[i..][0..len]);
            }
            i += len;
            continue;
        }
        if (std.ascii.isWhitespace(byte)) space = true;
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// `snapshot`'s words continue `prefix` (whole words; both normalized).
pub fn extendsSpeech(snapshot: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (std.mem.eql(u8, snapshot, prefix)) return true;
    return snapshot.len > prefix.len and std.mem.startsWith(u8, snapshot, prefix) and snapshot[prefix.len] == ' ';
}

/// The original text after the first `prefix_len` normalized bytes, leading
/// punctuation trimmed.
pub fn speechRemainder(text: []const u8, prefix_len: usize) []const u8 {
    if (prefix_len == 0) return std.mem.trim(u8, text, &std.ascii.whitespace);
    var length: usize = 0;
    var space = false;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (isWordStart(byte)) {
            const len = @min(sequenceLen(byte), text.len - i);
            if (space and length > 0) length += 1;
            space = false;
            length += len;
            i += len;
            if (length >= prefix_len) {
                var rest = text[i..];
                while (rest.len > 0 and !isWordStart(rest[0])) rest = rest[1..];
                return std.mem.trimEnd(u8, rest, &std.ascii.whitespace);
            }
            continue;
        }
        if (std.ascii.isWhitespace(byte)) space = true;
        i += 1;
    }
    return "";
}

fn wordCount(norm: []const u8) usize {
    if (norm.len == 0) return 0;
    return std.mem.count(u8, norm, " ") + 1;
}

/// Folds the utterance `next` into one user turn's `pieces` (oldest first).
/// `next` supersedes every earlier piece when its words contain or continue
/// all of their joined words, or continue the joined words of a leading run
/// of them holding more than half of their words (a re-transcription whose
/// tail the provider corrected). Otherwise it is appended. Blank text
/// changes nothing.
pub fn mergeSpeechPieces(allocator: std.mem.Allocator, pieces: *std.ArrayList([]u8), next: []const u8) !void {
    const text = std.mem.trim(u8, next, &std.ascii.whitespace);
    if (text.len == 0) return;
    const words = try normalizeAlloc(allocator, text);
    defer allocator.free(words);
    var norms: std.ArrayList([]u8) = .empty;
    defer {
        for (norms.items) |norm| allocator.free(norm);
        norms.deinit(allocator);
    }
    for (pieces.items) |piece| try norms.append(allocator, try normalizeAlloc(allocator, piece));
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(allocator);
    var total_words: usize = 0;
    for (norms.items) |norm| {
        if (norm.len == 0) continue;
        if (all.items.len > 0) try all.append(allocator, ' ');
        try all.appendSlice(allocator, norm);
        total_words += wordCount(norm);
    }
    const supersedes = blk: {
        if (words.len == 0 or all.items.len == 0) break :blk false;
        if (extendsSpeech(words, all.items) or containsWords(words, all.items)) break :blk true;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        var covered: usize = 0;
        for (norms.items) |norm| {
            if (norm.len == 0) continue;
            if (joined.items.len > 0) try joined.append(allocator, ' ');
            try joined.appendSlice(allocator, norm);
            if (!extendsSpeech(words, joined.items)) break;
            covered += wordCount(norm);
        }
        break :blk covered * 2 > total_words;
    };
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    if (supersedes) {
        for (pieces.items) |piece| allocator.free(piece);
        pieces.clearRetainingCapacity();
    }
    try pieces.append(allocator, owned);
}

/// `" words "` contains `" all "` (whole-word containment).
fn containsWords(words: []const u8, all: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, words, start, all)) |at| : (start = at + 1) {
        const before_ok = at == 0 or words[at - 1] == ' ';
        const end = at + all.len;
        const after_ok = end == words.len or words[end] == ' ';
        if (before_ok and after_ok) return true;
    }
    return false;
}

// ---- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn testTranscript() !Self {
    return Self.init(testing.allocator, "Moss", @splat('a'));
}

fn mergeAll(lines: []const []const u8) ![]u8 {
    var pieces: std.ArrayList([]u8) = .empty;
    defer freePieces(testing.allocator, &pieces);
    for (lines) |line| try mergeSpeechPieces(testing.allocator, &pieces, line);
    return joinPieces(testing.allocator, pieces.items);
}

fn expectMerged(expected: []const u8, lines: []const []const u8) !void {
    const merged = try mergeAll(lines);
    defer testing.allocator.free(merged);
    try testing.expectEqualStrings(expected, merged);
}

fn expectSaved(record: *Self, final: bool, expected: []const []const u8) !void {
    const count = try record.pending(final);
    const lines = record.pendingLines(count);
    var bodies: std.ArrayList([]const u8) = .empty;
    defer bodies.deinit(testing.allocator);
    for (lines) |line| if (!isBlank(line.body)) try bodies.append(testing.allocator, line.body);
    try testing.expectEqual(expected.len, bodies.items.len);
    for (expected, bodies.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "normalize keeps lowercase words and the remainder skips a prefix" {
    const norm = try normalizeAlloc(testing.allocator, "  Hello,   World! Ça va?");
    defer testing.allocator.free(norm);
    try testing.expectEqualStrings("hello world ça va", norm);
    try testing.expect(extendsSpeech("run the tests", "run the"));
    try testing.expect(!extendsSpeech("running", "run"));
    try testing.expect(!extendsSpeech("anything", ""));
    try testing.expectEqualStrings("then deploy.", speechRemainder("Run the tests, then deploy.", "run the tests".len));
    try testing.expectEqualStrings("", speechRemainder("Run", 3));
}

test "merge: superseding snapshots replace, new utterances append" {
    try expectMerged("Run the tests now", &.{ "Run the", "Run the tests now" });
    try expectMerged("Run the tests. Then deploy.", &.{ "Run the tests.", "Then deploy." });
    // A re-transcription that corrected its tail still supersedes.
    try expectMerged("Check the build and finish", &.{ "Check the build", "It finished", "Check the build and finish" });
    try expectMerged("hello", &.{ "hello", "   " });
    // Containing all earlier words supersedes too.
    try expectMerged("so run the tests please", &.{ "run the tests", "so run the tests please" });
}

test "delta transcripts make one user line per turn, then the reply" {
    var record = try testTranscript();
    defer record.deinit();
    try record.header("Live voice", 0);
    try record.userPartial("Check ", false, 1, null);
    try record.userPartial("the build", false, 2, null);
    try record.userFinal("Check the build.", 3, null);
    try record.userPartial("and the tests", false, 4, null);
    try record.userFinal("And the tests.", 5, null);
    // The current turn's user line waits for a reply before it saves.
    try expectSaved(&record, false, &.{"Live voice"});
    try record.assistantDelta("On ", 6);
    try record.assistantDelta("it.", 7);
    try record.assistantDone();
    try expectSaved(&record, false, &.{ "Live voice", "Check the build. And the tests.", "On it." });
    var caps: [4]Caption = undefined;
    const n = record.captions(&caps);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(caps[0].user);
    try testing.expectEqualStrings("On it.", caps[1].text);
}

test "cumulative transcripts (xAI) strip already committed words" {
    var record = try testTranscript();
    defer record.deinit();
    try record.userPartial("What is", true, 1, "a");
    try record.userPartial("What is running", true, 2, "a");
    try record.userFinal("What is running?", 3, "a");
    try record.assistantDelta("Two chats.", 4);
    try record.turnDoneForTest();
    try record.userPartial("What is running? Approve", true, 5, "b");
    try record.userPartial("What is running? Approve the deploy", true, 6, "b");
    try record.userFinal("What is running? Approve the deploy.", 7, "b");
    try record.assistantDelta("Approved.", 8);
    try expectSaved(&record, true, &.{ "What is running?", "Two chats.", "Approve the deploy.", "Approved." });
}

test "repeats are dropped and pauses close an utterance tentatively" {
    var record = try testTranscript();
    defer record.deinit();
    try record.userFinal("Hello there", 1, null);
    try record.userFinal("hello there!", 2, null);
    try record.userPartial("Status", false, 3, null);
    try record.tick(3 + USER_LINE_IDLE_MS);
    try testing.expect(record.open_user == null);
    try testing.expect(record.tentative != null);
    // A longer snapshot of the same words replaces the tentative line.
    try record.userPartial("Status of the crew", false, 4 + USER_LINE_IDLE_MS, null);
    try record.assistantDelta("Ok.", 5 + USER_LINE_IDLE_MS);
    try expectSaved(&record, true, &.{ "Hello there Status of the crew", "Ok." });
}

test "a late final transcript corrects the committed line" {
    var record = try testTranscript();
    defer record.deinit();
    try record.userPartial("deploy the ap", false, 1, "x");
    try record.assistantStarted();
    try record.userFinal("Deploy the app.", 2, "x");
    try record.assistantDelta("Deploying.", 3);
    try expectSaved(&record, true, &.{ "Deploy the app.", "Deploying." });
}

test "saving advances and empty sessions save nothing" {
    var record = try testTranscript();
    defer record.deinit();
    try record.header("Live voice", 0);
    try testing.expectEqual(@as(usize, 0), try record.pending(true));
    try record.userFinal("Hi", 1, null);
    try record.assistantDelta("Hello", 2);
    const count = try record.pending(true);
    try testing.expectEqual(@as(usize, 3), count);
    record.markSaved(count);
    try record.system("→ Asked Moss: build", 3);
    try expectSaved(&record, false, &.{"→ Asked Moss: build"});
    try testing.expectEqualStrings("Moss (voice)", record.authorOf(.assistant));
}

/// Test helper mirroring a provider `turn_done`.
fn turnDoneForTest(self: *Self) !void {
    try self.assistantDone();
}
