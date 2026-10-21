//! Account status probes for remote runtimes whose daemon reports provider
//! authentication as "unknown" (every release through v0.1.127).
//!
//! A probe runs the provider's own non-interactive status command on the
//! runtime over the terminal RPC lane (`remote_setup_terminal.Pump` with
//! output capture) and maps its output to signed in / signed out. Probe
//! output can contain account emails: it is parsed in memory, wiped, and
//! never logged or shown.

const std = @import("std");
const provider_models = @import("provider_models.zig");

const Provider = provider_models.Provider;

/// One probe at most this often per provider and runtime profile.
pub const PROBE_INTERVAL_MS: i64 = 60_000;
/// A probe still running after this is stopped and reads as unknown.
pub const PROBE_DEADLINE_MS: i64 = 15_000;
/// Claude Code starts a Node runtime first and can be slow on a cold host.
pub const CLAUDE_PROBE_DEADLINE_MS: i64 = 25_000;

pub fn deadlineMs(provider: Provider) i64 {
    return if (provider == .claude) CLAUDE_PROBE_DEADLINE_MS else PROBE_DEADLINE_MS;
}

pub const Result = enum { unknown, signed_in, signed_out };

/// The status command for `provider`, or null when Verde has no reliable
/// non-interactive probe for it.
pub fn command(provider: Provider) ?[]const u8 {
    return switch (provider) {
        .codex => "codex login status",
        .claude => "claude auth status",
        .cursor => "cursor-agent status",
        .opencode, .pi, .fx, .grok, .muse, .custom_acp => null,
    };
}

/// Shell for `bash -lc` on the runtime: from the runtime user's home, with
/// no terminal input so a probe can never wait on a prompt.
pub fn shellAlloc(allocator: std.mem.Allocator, provider: Provider) !?[]u8 {
    const probe = command(provider) orelse return null;
    return try std.fmt.allocPrint(allocator, "cd \"$HOME\" 2>/dev/null; {s} </dev/null", .{probe});
}

/// Maps a finished probe. `exit_code` is null when the exit was not a
/// normal one (signal) or unknown.
pub fn parse(provider: Provider, output: []const u8, exit_code: ?u32) Result {
    return switch (provider) {
        .codex, .cursor => blk: {
            if (std.mem.indexOf(u8, output, "Not logged in") != null or std.mem.indexOf(u8, output, "not logged in") != null) break :blk .signed_out;
            if (std.mem.indexOf(u8, output, "Logged in") != null and (provider == .cursor or exit_code == @as(?u32, 0))) break :blk .signed_in;
            break :blk .unknown;
        },
        .claude => claudeLoggedIn(output),
        .opencode, .pi, .fx, .grok, .muse, .custom_acp => .unknown,
    };
}

/// `claude auth status` prints a (pretty-printed) JSON object with
/// `"loggedIn": true|false`. PTY output may carry CRLF, colour escapes, and
/// lines before the JSON, so escapes are stripped and the outermost object
/// is parsed; a whitespace-tolerant match is the fallback.
fn claudeLoggedIn(output: []const u8) Result {
    var buffer: [16 * 1024]u8 = undefined;
    const clean = stripEscapes(output, &buffer);
    if (std.mem.indexOfScalar(u8, clean, '{')) |open| if (std.mem.lastIndexOfScalar(u8, clean, '}')) |close| if (close > open) {
        var arena_buffer: [32 * 1024]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&arena_buffer);
        if (std.json.parseFromSliceLeaky(std.json.Value, fixed.allocator(), clean[open .. close + 1], .{})) |value| {
            if (value == .object) if (value.object.get("loggedIn")) |logged_in| if (logged_in == .bool) {
                return if (logged_in.bool) .signed_in else .signed_out;
            };
        } else |_| {}
    };
    const key = "\"loggedIn\"";
    const at = std.mem.indexOf(u8, clean, key) orelse return .unknown;
    var rest = clean[at + key.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return .unknown;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (std.mem.startsWith(u8, rest, "true")) return .signed_in;
    if (std.mem.startsWith(u8, rest, "false")) return .signed_out;
    return .unknown;
}

/// Copies `input` into `buffer` without ANSI escape sequences (CSI and OSC)
/// or carriage returns; truncates at the buffer's size.
fn stripEscapes(input: []const u8, buffer: []u8) []const u8 {
    var out: usize = 0;
    var index: usize = 0;
    while (index < input.len and out < buffer.len) {
        const byte = input[index];
        if (byte == 0x1b and index + 1 < input.len) {
            index += 1;
            switch (input[index]) {
                '[' => {
                    index += 1;
                    while (index < input.len and (input[index] < 0x40 or input[index] > 0x7e)) index += 1;
                    index += 1;
                },
                ']' => {
                    while (index < input.len and input[index] != 0x07 and !(input[index] == 0x1b and index + 1 < input.len and input[index + 1] == '\\')) index += 1;
                    index += if (index < input.len and input[index] == 0x07) 1 else 2;
                },
                else => index += 1,
            }
            continue;
        }
        index += 1;
        if (byte == '\r') continue;
        buffer[out] = byte;
        out += 1;
    }
    return buffer[0..out];
}

/// Exit code of a raw wait status, or null for a signal.
pub fn exitCode(raw_status: ?u32) ?u32 {
    const status = raw_status orelse return null;
    if (status & 0x7f != 0) return null;
    return (status >> 8) & 0xff;
}

/// Latest probe outcome for one provider on one runtime profile.
pub const Entry = struct {
    profile_id: []u8,
    provider: Provider,
    /// When the last probe finished; 0 means due now.
    probed_at_ms: i64 = 0,
    result: Result = .unknown,
};

test "probe output maps to account state" {
    try std.testing.expectEqual(Result.signed_in, parse(.codex, "Logged in using ChatGPT\r\n", 0));
    try std.testing.expectEqual(Result.unknown, parse(.codex, "Logged in using ChatGPT\r\n", 1));
    try std.testing.expectEqual(Result.signed_out, parse(.codex, "Not logged in\r\n", 1));
    try std.testing.expectEqual(Result.signed_in, parse(.claude, "{\r\n  \"loggedIn\": true,\r\n  \"authMethod\": \"claude.ai\"\r\n}", 0));
    try std.testing.expectEqual(Result.signed_out, parse(.claude, "{\"loggedIn\":false}", 1));
    try std.testing.expectEqual(Result.unknown, parse(.claude, "command not found", 127));
    // The real pretty-printed shape, through a PTY (CRLF), after a banner line.
    const pretty = "Checking auth...\r\n{\r\n  \"loggedIn\": true,\r\n  \"authMethod\": \"claude.ai\",\r\n  \"apiProvider\": \"firstParty\",\r\n  \"subscriptionType\": \"max\"\r\n}\r\n";
    try std.testing.expectEqual(Result.signed_in, parse(.claude, pretty, 0));
    // Colourised JSON (escapes around keys and values).
    try std.testing.expectEqual(Result.signed_in, parse(.claude, "{\r\n  \x1b[34m\"loggedIn\"\x1b[0m: \x1b[33mtrue\x1b[0m,\r\n  \"authMethod\": \"claude.ai\"\r\n}", 0));
    try std.testing.expectEqual(Result.signed_out, parse(.claude, "\x1b]0;claude\x07{\r\n  \"loggedIn\": false\r\n}\r\n", 1));
    // Truncated JSON still matches by key.
    try std.testing.expectEqual(Result.signed_in, parse(.claude, "{\r\n  \"loggedIn\":   true,\r\n  \"authMe", 0));
    try std.testing.expectEqual(Result.signed_in, parse(.cursor, "\x1b[32m✓ Logged in as someone\x1b[0m\r\n", 0));
    try std.testing.expectEqual(Result.signed_out, parse(.cursor, "Not logged in\r\n", 0));
    try std.testing.expectEqual(Result.unknown, parse(.grok, "Logged in", 0));
    try std.testing.expect(command(.opencode) == null);
    try std.testing.expectEqual(@as(?u32, 0), exitCode(0));
    try std.testing.expectEqual(@as(?u32, 1), exitCode(256));
    try std.testing.expectEqual(@as(?u32, null), exitCode(9));
}
