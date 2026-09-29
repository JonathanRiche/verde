//! Typo-tolerant, multi-word fuzzy scoring for the command palette.
//!
//! A query is scored as a whole phrase first, then word by word: every query
//! word must match some field, in any order. Each word tries three tiers,
//! strongest first: case-insensitive substring (bonus at word starts),
//! in-order subsequence (bonus for word starts and consecutive runs), and a
//! bounded edit distance against word prefixes (one typo from 4 bytes, two
//! from 8; adjacent transpositions count as one edit). Scores keep the
//! palette's historical scale: substring 600..1000, subsequence <= 580,
//! typo <= 300. ASCII case folding only; other bytes compare exactly.

const std = @import("std");

/// One searchable string. `penalty` is subtracted from its scores so weaker
/// fields (keywords, descriptions) rank below equal title hits.
pub const Field = struct {
    text: []const u8,
    penalty: i32 = 0,
    /// Subsequence matching suits short labels; on long prose nearly any
    /// short word is a subsequence, so descriptions disable it.
    subsequence: bool = true,
};

pub const MAX_TOKENS = 8;
/// Multi-word matches rank below the same words found as one phrase.
const MULTI_TOKEN_PENALTY: i32 = 40;
const MAX_TYPO_TOKEN = 32;
const MAX_TYPO_WORD = 64;

/// Best score of `query` over `fields`, or null when some query word matches
/// no field.
pub fn score(fields: []const Field, query: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, query, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;

    var best: ?i32 = null;
    for (fields) |field| best = maxOptional(best, penalized(tokenScore(field.text, trimmed, field.subsequence), field.penalty));

    var token_buf: [MAX_TOKENS][]const u8 = undefined;
    const tokens = tokenize(trimmed, &token_buf);
    if (tokens.len <= 1) return best;

    var total: i32 = 0;
    for (tokens) |token| {
        var token_best: ?i32 = null;
        for (fields) |field| token_best = maxOptional(token_best, penalized(tokenScore(field.text, token, field.subsequence), field.penalty));
        total += token_best orelse return best;
    }
    const multi = @divTrunc(total, @as(i32, @intCast(tokens.len))) - MULTI_TOKEN_PENALTY;
    return maxOptional(best, multi);
}

/// Single-field convenience wrapper for `score`.
pub fn scoreText(text: []const u8, query: []const u8) ?i32 {
    return score(&.{.{ .text = text }}, query);
}

/// Splits on ASCII whitespace; words past `MAX_TOKENS` are ignored.
pub fn tokenize(query: []const u8, buf: *[MAX_TOKENS][]const u8) []const []const u8 {
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, &std.ascii.whitespace);
    while (it.next()) |token| {
        if (count == buf.len) break;
        buf[count] = token;
        count += 1;
    }
    return buf[0..count];
}

pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    const end = haystack.len - needle.len;
    outer: while (i <= end) : (i += 1) {
        for (needle, 0..) |nb, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nb)) continue :outer;
        }
        return i;
    }
    return null;
}

fn tokenScore(haystack: []const u8, token: []const u8, allow_subsequence: bool) ?i32 {
    if (token.len == 0 or haystack.len == 0) return null;
    if (indexOfIgnoreCase(haystack, token)) |pos| {
        const boundary_bonus: i32 = if (isWordStart(haystack, pos)) 0 else -40;
        return 1000 - @as(i32, @intCast(@min(pos, 400))) + boundary_bonus;
    }
    if (allow_subsequence) {
        if (subsequenceScore(haystack, token)) |value| return value;
    }
    return typoScore(haystack, token);
}

/// Greedy leftmost in-order match. Gaps cost; word-start and consecutive
/// hits earn a capped bonus so acronyms like "cp" favor "Command Palette".
fn subsequenceScore(haystack: []const u8, needle: []const u8) ?i32 {
    var hi: usize = 0;
    var gaps: i32 = 0;
    var bonus: i32 = 0;
    var last_hit: ?usize = null;
    for (needle) |nb| {
        const nl = std.ascii.toLower(nb);
        while (hi < haystack.len and std.ascii.toLower(haystack[hi]) != nl) : (hi += 1) {}
        if (hi == haystack.len) return null;
        if (last_hit) |last| {
            const gap = hi - last - 1;
            gaps += @intCast(@min(gap, 20));
            if (gap == 0) bonus += 8;
        }
        if (isWordStart(haystack, hi)) bonus += 12;
        last_hit = hi;
        hi += 1;
    }
    return 500 - gaps + @min(bonus, 80);
}

/// Best bounded-edit match of `token` against a prefix of any haystack word.
fn typoScore(haystack: []const u8, token: []const u8) ?i32 {
    if (token.len < 4 or token.len > MAX_TYPO_TOKEN) return null;
    for (token) |char| if (!std.ascii.isAlphanumeric(char)) return null;
    const max_edits: usize = if (token.len >= 8) 2 else 1;

    var best: ?i32 = null;
    var word_index: usize = 0;
    var i: usize = 0;
    while (i < haystack.len) {
        while (i < haystack.len and !std.ascii.isAlphanumeric(haystack[i])) : (i += 1) {}
        const start = i;
        while (i < haystack.len and std.ascii.isAlphanumeric(haystack[i])) : (i += 1) {}
        if (i == start) break;
        const word = haystack[start..@min(i, start + MAX_TYPO_WORD)];
        if (word.len + max_edits >= token.len) {
            if (prefixEditDistance(token, word, max_edits)) |edits| {
                const value = 300 - 80 * @as(i32, @intCast(edits)) - @as(i32, @intCast(@min(word_index, 20)));
                best = maxOptional(best, value);
            }
        }
        word_index += 1;
    }
    return best;
}

/// Optimal-string-alignment distance between `token` and the closest prefix
/// of `word`, or null when it exceeds `max_edits`. The first byte must match
/// (or be the transposed pair), which keeps short-token noise down.
fn prefixEditDistance(token: []const u8, word: []const u8, max_edits: usize) ?usize {
    const m = token.len;
    const n = word.len;
    if (std.ascii.toLower(token[0]) != std.ascii.toLower(word[0])) {
        const transposed = m > 1 and n > 1 and
            std.ascii.toLower(token[0]) == std.ascii.toLower(word[1]) and
            std.ascii.toLower(token[1]) == std.ascii.toLower(word[0]);
        if (!transposed) return null;
    }
    var rows: [MAX_TYPO_TOKEN + 1][MAX_TYPO_WORD + 1]u8 = undefined;
    for (0..n + 1) |j| rows[0][j] = @intCast(j);
    for (1..m + 1) |a| {
        rows[a][0] = @intCast(a);
        const tc = std.ascii.toLower(token[a - 1]);
        for (1..n + 1) |b| {
            const wc = std.ascii.toLower(word[b - 1]);
            const cost: u8 = if (tc == wc) 0 else 1;
            var value = @min(rows[a - 1][b] + 1, rows[a][b - 1] + 1, rows[a - 1][b - 1] + cost);
            if (a > 1 and b > 1 and tc == std.ascii.toLower(word[b - 2]) and
                std.ascii.toLower(token[a - 2]) == wc)
            {
                value = @min(value, rows[a - 2][b - 2] + 1);
            }
            rows[a][b] = value;
        }
    }
    // Free suffix on the word: the token may match any prefix of it.
    var best: usize = std.math.maxInt(usize);
    const first = if (m > max_edits) m - max_edits else 0;
    var j = @min(first, n);
    while (j <= n) : (j += 1) best = @min(best, rows[m][j]);
    return if (best <= max_edits) best else null;
}

fn isWordStart(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    const prev = text[index - 1];
    const cur = text[index];
    if (!std.ascii.isAlphanumeric(prev)) return true;
    return std.ascii.isLower(prev) and std.ascii.isUpper(cur);
}

fn penalized(value: ?i32, penalty: i32) ?i32 {
    return if (value) |v| v - penalty else null;
}

fn maxOptional(a: ?i32, b: ?i32) ?i32 {
    if (a == null) return b;
    if (b == null) return a;
    return @max(a.?, b.?);
}

test "substring outranks subsequence and rejects non-matches" {
    const substring = scoreText("Split Chat Right", "chat").?;
    const subsequence = scoreText("Split Chat Right", "scr").?;
    try std.testing.expect(substring > subsequence);
    try std.testing.expect(scoreText("Split Chat Right", "browser") == null);
    try std.testing.expect(scoreText("chat about chat", "chat").? > scoreText("talk about chat", "chat").?);
    // Mid-word substrings rank below word-start ones.
    try std.testing.expect(scoreText("Palette search", "pal").? > scoreText("Opal search", "pal").?);
}

test "words match in any order across fields" {
    try std.testing.expect(scoreText("Fuzzy search in the command palette", "palette fuzzy") != null);
    const fields = [_]Field{ .{ .text = "Commit & push" }, .{ .text = "git changes stage", .penalty = 100 } };
    try std.testing.expect(score(&fields, "push git") != null);
    try std.testing.expect(score(&fields, "push browser") == null);
    // A contiguous phrase beats the same words scattered.
    try std.testing.expect(scoreText("open workspace settings", "workspace settings").? >
        scoreText("settings for the workspace", "workspace settings").?);
}

test "typos within the edit budget still match" {
    try std.testing.expect(scoreText("Fix OAuth refresh in auth.zig", "atuh") != null);
    try std.testing.expect(scoreText("Improve command palette search", "palete") != null);
    try std.testing.expect(scoreText("Improve command palette search", "serach") != null);
    try std.testing.expect(scoreText("Transcript scrolling", "trnascirpt") != null);
    try std.testing.expect(scoreText("Improve command palette search", "zzzz") == null);
    // Short tokens get no typo budget.
    try std.testing.expect(scoreText("Improve command palette search", "xyz") == null);
    // Exact beats typo.
    try std.testing.expect(scoreText("palette", "palette").? > scoreText("palette", "palete").?);
}

test "acronym subsequences prefer word starts" {
    const acronym = scoreText("Command Palette", "cp").?;
    const scattered = scoreText("scope", "cp").?;
    try std.testing.expect(acronym > scattered);
}

test "fields without subsequence only accept substrings and typos" {
    const fields = [_]Field{.{ .text = "a long description about many unrelated things", .subsequence = false }};
    try std.testing.expect(score(&fields, "lmn") == null);
    try std.testing.expect(score(&fields, "unrelatd") != null);
}
