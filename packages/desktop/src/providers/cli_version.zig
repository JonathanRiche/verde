//! Bounded `--version` probe for a provider CLI on the daemon's PATH.
//!
//! The deadline keeps a wedged binary from stalling `providers.status` or
//! provider auth. Output is the first non-empty line, capped to the caller's
//! buffer, so the UI can show what this daemon actually has installed.

const builtin = @import("builtin");
const std = @import("std");
const process_env = @import("../platform/env.zig");

const PROBE_DEADLINE_MS: i64 = 800;
const OUTPUT_LIMIT: usize = 512;

/// Executable the daemon and desktop use for this provider's `--version` probe.
/// Cursor is `cursor-agent`, falling back to `agent`: Grok also ships an
/// `agent` binary that can come first on PATH.
pub fn executableForProvider(provider_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_name, "cursor")) {
        if (process_env.commandExists("cursor-agent")) return "cursor-agent";
        if (process_env.commandExists("agent")) return "agent";
        return null;
    }
    const executable: ?[]const u8 = if (std.mem.eql(u8, provider_name, "codex"))
        "codex"
    else if (std.mem.eql(u8, provider_name, "claude"))
        "claude"
    else if (std.mem.eql(u8, provider_name, "opencode"))
        "opencode"
    else if (std.mem.eql(u8, provider_name, "pi"))
        "pi"
    else if (std.mem.eql(u8, provider_name, "fx"))
        "fx"
    else if (std.mem.eql(u8, provider_name, "grok"))
        "grok"
    else if (std.mem.eql(u8, provider_name, "muse"))
        "muse"
    else
        null;
    const name = executable orelse return null;
    return if (process_env.commandExists(name)) name else null;
}

/// Prefers a version-shaped token (`0.154.0`, `v0.0.0-beta-18414`) over the
/// whole `--version` line (`codex-cli 0.154.0`).
pub fn shortVersion(line: []const u8) []const u8 {
    var rest = std.mem.trim(u8, line, &std.ascii.whitespace);
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const token = std.mem.trim(u8, rest[0..end], "()[],");
        if (isVersionToken(token)) return token;
        rest = std.mem.trimStart(u8, rest[end..], " \t");
    }
    return std.mem.trim(u8, line, &std.ascii.whitespace);
}

fn isVersionToken(token: []const u8) bool {
    if (token.len == 0) return false;
    const body = if (token[0] == 'v' or token[0] == 'V') token[1..] else token;
    if (body.len == 0 or !std.ascii.isDigit(body[0])) return false;
    return std.mem.indexOfScalar(u8, body, '.') != null;
}

/// Copies the first non-empty line of `raw` into `out`. Returns null when the
/// text has no visible line or `out` is empty.
pub fn copyFirstLine(raw: []const u8, out: []u8) ?[]const u8 {
    if (out.len == 0) return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], &std.ascii.whitespace);
    if (line.len == 0) return null;
    const n = @min(line.len, out.len);
    @memcpy(out[0..n], line[0..n]);
    return out[0..n];
}

/// Whether `installed_line` is older than the published `latest_token`.
/// `null` means the two strings cannot be ordered. A newer local build is `.gt`.
pub fn compareInstalled(installed_line: []const u8, latest_token: []const u8) ?std.math.Order {
    const installed = comparableVersion(installed_line);
    const latest = stripVersionPrefix(std.mem.trim(u8, latest_token, &std.ascii.whitespace));
    const left = stripVersionPrefix(installed);
    if (isCursorBuild(left) and isCursorBuild(latest)) return cursorOrder(left, latest);
    const installed_core = parseCore(left) orelse return null;
    const latest_core = parseCore(latest) orelse return null;
    if (installed_core.major != latest_core.major) return std.math.order(installed_core.major, latest_core.major);
    if (installed_core.minor != latest_core.minor) return std.math.order(installed_core.minor, latest_core.minor);
    if (installed_core.patch != latest_core.patch) return std.math.order(installed_core.patch, latest_core.patch);
    return suffixOrder(installed_core.rest, latest_core.rest);
}

const LatestKind = enum {
    plain,
    json_version,
    json_tag,
    cursor_script,
    github_tag,
};

const LatestSource = struct {
    url: []const u8,
    kind: LatestKind,
};

/// Official channel the provider's installer reads. These are small public
/// documents, not the installers themselves.
fn latestSource(provider_name: []const u8) ?LatestSource {
    if (std.mem.eql(u8, provider_name, "codex")) {
        return .{ .url = "https://releases.openai.com/codex/channels/latest", .kind = .json_tag };
    }
    if (std.mem.eql(u8, provider_name, "claude")) {
        return .{ .url = "https://downloads.claude.ai/claude-code-releases/latest", .kind = .plain };
    }
    if (std.mem.eql(u8, provider_name, "cursor")) {
        return .{ .url = "https://cursor.com/install", .kind = .cursor_script };
    }
    if (std.mem.eql(u8, provider_name, "opencode")) {
        return .{ .url = "https://opencode.ai/update/api/latest/cli/npm", .kind = .json_version };
    }
    if (std.mem.eql(u8, provider_name, "pi")) {
        return .{ .url = "https://api.github.com/repos/earendil-works/pi/releases/latest", .kind = .github_tag };
    }
    if (std.mem.eql(u8, provider_name, "fx")) {
        return .{ .url = "https://releases.fx.sh/latest.txt", .kind = .plain };
    }
    if (std.mem.eql(u8, provider_name, "grok")) {
        return .{ .url = "https://x.ai/cli/stable", .kind = .plain };
    }
    if (std.mem.eql(u8, provider_name, "muse")) {
        return .{ .url = "https://api.meta.ai/muse-code/channels/muse-stable", .kind = .json_version };
    }
    return null;
}

/// Copies the published version for `provider_name` into `out`.
/// Returns null when the channel is unknown, the request fails, or the body has no version.
pub fn fetchLatest(allocator: std.mem.Allocator, provider_name: []const u8, out: []u8) ?[]const u8 {
    const source = latestSource(provider_name) orelse return null;
    const body = httpGetLimited(allocator, source.url) orelse return null;
    defer allocator.free(body);
    return parseLatestToken(source.kind, body, out);
}

fn parseLatestToken(kind: LatestKind, body: []const u8, out: []u8) ?[]const u8 {
    const raw = switch (kind) {
        .plain => firstTokenLine(body),
        .json_version => jsonStringField(body, "version"),
        .json_tag => jsonStringField(body, "tag_name"),
        .cursor_script => sliceBetween(body, "downloads.cursor.com/lab/", "/"),
        .github_tag => sliceBetween(body, "/releases/tag/", "\""),
    } orelse return null;
    return copyVersionToken(raw, out);
}

/// Runs `<executable> --version` with the daemon's augmented environment.
/// Returns a slice of `out`, or null when the binary is missing, exits
/// non-zero, times out, or prints nothing.
pub fn probe(allocator: std.mem.Allocator, executable_name: []const u8, out: []u8) ?[]const u8 {
    if (out.len == 0) return null;
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return null;
    defer env_map.deinit();
    const executable = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, executable_name) catch return null;
    defer allocator.free(executable);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const result = std.process.run(allocator, threaded.io(), .{
        .argv = &.{ executable, "--version" },
        .environ_map = &env_map,
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(PROBE_DEADLINE_MS),
            .clock = .awake,
        } },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const stdout = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const source = if (stdout.len > 0) result.stdout else result.stderr;
    return copyFirstLine(source, out);
}

test "version probe keeps the first line and drops a blank lead-in" {
    var out: [48]u8 = undefined;
    const line = copyFirstLine("\n  claude 2.1.89\nrest\n", &out).?;
    try std.testing.expectEqualStrings("claude 2.1.89", line);
    try std.testing.expect(copyFirstLine(" \n\t", &out) == null);
}

test "short version prefers the version token" {
    try std.testing.expectEqualStrings("0.154.0", shortVersion("codex-cli 0.154.0"));
    try std.testing.expectEqualStrings("2.1.273", shortVersion("2.1.273 (Claude Code)"));
    try std.testing.expectEqualStrings("v0.0.0-beta-18414", shortVersion("opencode v0.0.0-beta-18414"));
    try std.testing.expectEqualStrings("1.0.40", shortVersion("grok 1.0.40 (eb1a2256660d) [stable]"));
}

test "published version tokens parse from each channel document" {
    var out: [48]u8 = undefined;
    try std.testing.expectEqualStrings("2.1.278", parseLatestToken(.plain, "2.1.278\n", &out).?);
    try std.testing.expectEqualStrings("0.0.10", parseLatestToken(.plain, "v0.0.10\n", &out).?);
    try std.testing.expectEqualStrings("2.0.12", parseLatestToken(.json_version, "{\"version\":\"2.0.12\",\"channel\":\"latest\"}", &out).?);
    try std.testing.expectEqualStrings("1.3.0-R3401.1", parseLatestToken(.json_version, "{\"channel\":\"muse-stable\",\"version\":\"1.3.0-R3401.1\"}", &out).?);
    try std.testing.expectEqualStrings("0.155.1", parseLatestToken(.json_tag, "{\"assets\":[],\"tag_name\":\"rust-v0.155.1\"}", &out).?);
    try std.testing.expectEqualStrings("2026.09.18-9a7762b", parseLatestToken(.cursor_script, "DOWNLOAD_URL=\"https://downloads.cursor.com/lab/2026.09.18-9a7762b/${OS}/agent.tar.gz\"", &out).?);
    try std.testing.expectEqualStrings("0.87.0", parseLatestToken(.github_tag, "\"html_url\":\"https://github.com/earendil-works/pi/releases/tag/v0.87.0\"", &out).?);
}

test "install path picks the package manager that owns the binary" {
    try expectPlan("/home/rtg/.local/share/mise/installs/codex/0.154.0/bin/codex", .{ .managed = true, .shell = "mise upgrade codex", .latest = .mise, .arg = "codex" });
    try expectPlan("/home/rtg/.local/share/mise/shims/claude", .{ .managed = true, .shell = "mise upgrade claude", .latest = .mise, .arg = "claude" });
    try expectPlan("/opt/homebrew/Cellar/codex/0.154.0/bin/codex", .{ .managed = true, .shell = "brew upgrade codex", .latest = .official, .arg = "codex" });
    try expectPlan("/home/rtg/.local/share/mise/installs/node/24.21.0/lib/node_modules/@xai-official/grok/bin/grok", .{
        .managed = true,
        .shell = "'/home/rtg/.local/share/mise/installs/node/24.21.0/bin/npm' update -g @xai-official/grok",
        .latest = .npm,
        .arg = "@xai-official/grok",
    });
    try expectPlan("/home/rtg/.local/bin/fx", .{ .managed = false, .shell = "", .latest = .official, .arg = "" });
    try expectPlan("/home/rtg/.local/share/cursor-agent/versions/2026.09.18-9a7762b/cursor-agent", .{ .managed = false, .shell = "", .latest = .official, .arg = "" });
    try expectPlan("/home/rtg/.local/share/mise/installs/node/lts/bin/grok", .{ .managed = true, .shell = "", .latest = .official, .arg = "" });
}

const ExpectedPlan = struct {
    managed: bool,
    shell: []const u8,
    latest: UpdatePlan.Latest,
    arg: []const u8,
};

fn expectPlan(path: []const u8, expected: ExpectedPlan) !void {
    var plan: UpdatePlan = .{};
    applyInstallPath(path, &plan);
    try std.testing.expectEqual(expected.managed, plan.managed);
    try std.testing.expectEqualStrings(expected.shell, plan.shellSlice());
    try std.testing.expectEqual(expected.latest, plan.latest);
    try std.testing.expectEqualStrings(expected.arg, plan.argSlice());
}

test "installed version is behind only when the published release is newer" {
    try std.testing.expectEqual(std.math.Order.lt, compareInstalled("codex-cli 0.154.0", "0.155.1").?);
    try std.testing.expectEqual(std.math.Order.lt, compareInstalled("2.1.273 (Claude Code)", "2.1.278").?);
    try std.testing.expectEqual(std.math.Order.eq, compareInstalled("grok 1.0.40 (eb1a2256660d) [stable]", "1.0.40").?);
    try std.testing.expectEqual(std.math.Order.eq, compareInstalled("2026.09.18-9a7762b", "2026.09.18-9a7762b").?);
    try std.testing.expectEqual(std.math.Order.lt, compareInstalled("2026.09.17-aaaaaaa", "2026.09.18-bbbbbbb").?);
    try std.testing.expectEqual(std.math.Order.lt, compareInstalled("Muse Code 1.0.3 (1.0.3-R2198.1)", "1.3.0-R3401.1").?);
    try std.testing.expectEqual(std.math.Order.gt, compareInstalled("1.0.3-R1000.1", "1.0.3-R999.1").?);
    try std.testing.expectEqual(std.math.Order.lt, compareInstalled("opencode v0.0.0-beta-18414", "2.0.12").?);
    try std.testing.expectEqual(std.math.Order.eq, compareInstalled("opencode v2.0.12", "2.0.12").?);
    try std.testing.expectEqual(std.math.Order.gt, compareInstalled("0.87.0", "0.85.1").?);
    try std.testing.expect(compareInstalled("not a version", "1.2.3") == null);
}

const VersionCore = struct {
    major: u32,
    minor: u32,
    patch: u32,
    rest: []const u8,
};

fn comparableVersion(line: []const u8) []const u8 {
    var best: []const u8 = "";
    var rest = std.mem.trim(u8, line, &std.ascii.whitespace);
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const token = std.mem.trim(u8, rest[0..end], "()[],");
        if (isVersionToken(token) and token.len > best.len) best = token;
        rest = std.mem.trimStart(u8, rest[end..], " \t");
    }
    if (best.len == 0) return std.mem.trim(u8, line, &std.ascii.whitespace);
    return best;
}

fn stripVersionPrefix(version: []const u8) []const u8 {
    if (std.mem.startsWith(u8, version, "rust-v")) return version["rust-v".len..];
    if (version.len > 1 and (version[0] == 'v' or version[0] == 'V') and std.ascii.isDigit(version[1])) return version[1..];
    return version;
}

fn parseCore(text: []const u8) ?VersionCore {
    const major = takeInt(text) orelse return null;
    if (major.end >= text.len or text[major.end] != '.') return null;
    const minor = takeInt(text[major.end + 1 ..]) orelse return null;
    const minor_at = major.end + 1 + minor.end;
    if (minor_at >= text.len or text[minor_at] != '.') return null;
    const patch = takeInt(text[minor_at + 1 ..]) orelse return null;
    return .{
        .major = major.value,
        .minor = minor.value,
        .patch = patch.value,
        .rest = text[minor_at + 1 + patch.end ..],
    };
}

const IntScan = struct { value: u32, end: usize };

fn takeInt(text: []const u8) ?IntScan {
    if (text.len == 0 or !std.ascii.isDigit(text[0])) return null;
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const value = std.fmt.parseInt(u32, text[0..end], 10) catch return null;
    return .{ .value = value, .end = end };
}

fn isCursorBuild(text: []const u8) bool {
    const core = parseCore(text) orelse return false;
    if (core.major < 2000 or core.major > 2100) return false;
    if (core.minor > 12 or core.patch > 31) return false;
    if (core.rest.len < 7 or core.rest[0] != '-') return false;
    for (core.rest[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn cursorOrder(installed: []const u8, latest: []const u8) ?std.math.Order {
    const left = parseCore(installed) orelse return null;
    const right = parseCore(latest) orelse return null;
    if (left.major != right.major) return std.math.order(left.major, right.major);
    if (left.minor != right.minor) return std.math.order(left.minor, right.minor);
    if (left.patch != right.patch) return std.math.order(left.patch, right.patch);
    if (std.mem.eql(u8, left.rest, right.rest)) return .eq;
    return .lt;
}

fn suffixOrder(installed_rest: []const u8, latest_rest: []const u8) ?std.math.Order {
    if (installed_rest.len == 0 and latest_rest.len == 0) return .eq;
    if (installed_rest.len == 0) return .gt;
    if (latest_rest.len == 0) return .lt;
    if (museRevision(installed_rest)) |installed_rev| {
        if (museRevision(latest_rest)) |latest_rev| {
            if (installed_rev.revision != latest_rev.revision) return std.math.order(installed_rev.revision, latest_rev.revision);
            return std.math.order(installed_rev.tail, latest_rev.tail);
        }
    }
    if (std.mem.eql(u8, installed_rest, latest_rest)) return .eq;
    const installed_tail = trailingInt(installed_rest) orelse return null;
    const latest_tail = trailingInt(latest_rest) orelse return null;
    if (!std.mem.eql(u8, installed_tail.prefix, latest_tail.prefix)) return null;
    return std.math.order(installed_tail.value, latest_tail.value);
}

const MuseRevision = struct { revision: u32, tail: u32 };

fn museRevision(rest: []const u8) ?MuseRevision {
    if (!std.mem.startsWith(u8, rest, "-R")) return null;
    const rev = takeInt(rest["-R".len..]) orelse return null;
    var tail: u32 = 0;
    const after = rest["-R".len + rev.end ..];
    if (after.len > 0) {
        if (after[0] != '.') return null;
        const tail_scan = takeInt(after[1..]) orelse return null;
        if (1 + tail_scan.end != after.len) return null;
        tail = tail_scan.value;
    }
    return .{ .revision = rev.value, .tail = tail };
}

const TrailingInt = struct { prefix: []const u8, value: u32 };

fn trailingInt(text: []const u8) ?TrailingInt {
    if (text.len == 0 or !std.ascii.isDigit(text[text.len - 1])) return null;
    var start = text.len;
    while (start > 0 and std.ascii.isDigit(text[start - 1])) start -= 1;
    if (start == 0) return null;
    return .{
        .prefix = text[0..start],
        .value = std.fmt.parseInt(u32, text[start..], 10) catch return null,
    };
}

fn firstTokenLine(body: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const line_end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    const line = std.mem.trim(u8, trimmed[0..line_end], &std.ascii.whitespace);
    return if (line.len == 0) null else line;
}

fn jsonStringField(body: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 2 < body.len) : (i += 1) {
        if (body[i] != '"') continue;
        if (!std.mem.startsWith(u8, body[i + 1 ..], key)) continue;
        const after_key = i + 1 + key.len;
        if (after_key >= body.len or body[after_key] != '"') continue;
        var j = after_key + 1;
        while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
        if (j >= body.len or body[j] != ':') continue;
        j += 1;
        while (j < body.len and std.ascii.isWhitespace(body[j])) j += 1;
        if (j >= body.len or body[j] != '"') continue;
        const value_start = j + 1;
        const value_end = std.mem.indexOfScalar(u8, body[value_start..], '"') orelse return null;
        return body[value_start .. value_start + value_end];
    }
    return null;
}

fn sliceBetween(body: []const u8, start_mark: []const u8, end_mark: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, start_mark) orelse return null;
    const from = start + start_mark.len;
    const end = std.mem.indexOf(u8, body[from..], end_mark) orelse return null;
    if (end == 0) return null;
    return body[from .. from + end];
}

fn copyVersionToken(raw: []const u8, out: []u8) ?[]const u8 {
    const token = stripVersionPrefix(std.mem.trim(u8, raw, &std.ascii.whitespace));
    if (token.len == 0 or token.len > out.len) return null;
    if (!std.ascii.isDigit(token[0]) or std.mem.indexOfScalar(u8, token, '.') == null) return null;
    for (token) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '+')) return null;
    }
    @memcpy(out[0..token.len], token);
    return out[0..token.len];
}

const LATEST_BODY_LIMIT: usize = 64 * 1024;
const LATEST_TIMEOUT_SECONDS: i64 = 4;

fn httpGetLimited(allocator: std.mem.Allocator, url: []const u8) ?[]u8 {
    const response_buffer = allocator.alloc(u8, LATEST_BODY_LIMIT) catch return null;
    var release_buffer = true;
    defer if (release_buffer) allocator.free(response_buffer);
    var response_writer = std.Io.Writer.fixed(response_buffer);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    // Zig's default 8KB header buffer is smaller than Cursor's install
    // response, which carries a large content-security-policy. A too-small
    // buffer fails the check and the row cannot say Latest.
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = threaded.io(),
        .read_buffer_size = 64 * 1024,
    };
    defer client.deinit();

    const fetch_options: std.http.Client.FetchOptions = .{
        .location = .{ .url = url },
        .response_writer = &response_writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "verde-desktop" },
            .{ .name = "accept", .value = "*/*" },
        },
    };
    const SelectResult = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: std.Io.Cancelable!void,
    };
    var select_buffer: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(threaded.io(), &select_buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, fetch_options });
    select.async(.timeout, std.Io.sleep, .{ threaded.io(), std.Io.Duration.fromSeconds(LATEST_TIMEOUT_SECONDS), .awake });
    defer select.cancelDiscard();

    const selected = select.await() catch return null;
    switch (selected) {
        .timeout => return null,
        .fetch => |fetch_result| {
            const result = fetch_result catch return null;
            if (result.status != .ok) return null;
        },
    }
    if (response_writer.end == 0) return null;
    const owned = allocator.realloc(response_buffer, response_writer.end) catch return null;
    release_buffer = false;
    return owned;
}

/// How to update the binary Verde actually runs. The official curl installer
/// is a second copy when mise, Homebrew, or npm already owns that PATH entry.
pub const UpdatePlan = struct {
    pub const Latest = enum { official, mise, npm };

    managed: bool = false,
    latest: Latest = .official,
    shell: [192]u8 = .{0} ** 192,
    shell_len: u8 = 0,
    arg: [80]u8 = .{0} ** 80,
    arg_len: u8 = 0,
    npm: [160]u8 = .{0} ** 160,
    npm_len: u8 = 0,

    pub fn shellSlice(self: *const UpdatePlan) []const u8 {
        return self.shell[0..self.shell_len];
    }

    pub fn argSlice(self: *const UpdatePlan) []const u8 {
        return self.arg[0..self.arg_len];
    }

    pub fn npmSlice(self: *const UpdatePlan) []const u8 {
        return self.npm[0..self.npm_len];
    }
};

/// Classifies `executable_name` on the daemon PATH and fills `plan`.
pub fn planUpdate(allocator: std.mem.Allocator, executable_name: []const u8, plan: *UpdatePlan) void {
    plan.* = .{};
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return;
    defer env_map.deinit();
    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, executable_name) catch return;
    defer allocator.free(resolved);
    const canon = canonicalPathAlloc(allocator, resolved) orelse resolved;
    defer if (canon.ptr != resolved.ptr) allocator.free(canon);
    applyInstallPath(canon, plan);
}

/// Latest release for this plan's installer. Package-managed copies do not
/// fall back to the upstream curl channel, which can be a different build.
pub fn fetchPlanLatest(allocator: std.mem.Allocator, provider_name: []const u8, plan: *const UpdatePlan, out: []u8) ?[]const u8 {
    if (plan.managed and plan.shell_len == 0) return null;
    return switch (plan.latest) {
        .official => fetchLatest(allocator, provider_name, out),
        .mise => commandFirstLine(allocator, &.{ "mise", "latest", plan.argSlice() }, out),
        .npm => commandFirstLine(allocator, &.{ plan.npmSlice(), "view", plan.argSlice(), "version" }, out),
    };
}

fn applyInstallPath(path: []const u8, plan: *UpdatePlan) void {
    plan.* = .{};
    if (applyNpm(path, plan)) return;
    if (applyBrew(path, plan)) return;
    if (applyMise(path, plan)) return;
}

fn applyNpm(path: []const u8, plan: *UpdatePlan) bool {
    const lib_mark = "/lib/node_modules/";
    const bare_mark = "/node_modules/";
    const at, const mark_len = if (std.mem.indexOf(u8, path, lib_mark)) |found|
        .{ found, lib_mark.len }
    else if (std.mem.indexOf(u8, path, bare_mark)) |found|
        .{ found, bare_mark.len }
    else
        return false;
    const package = nodePackage(path[at + mark_len ..]) orelse return false;
    if (!isSafeToken(package)) return false;
    const prefix = path[0..at];
    var npm_buf: [160]u8 = undefined;
    const npm = std.fmt.bufPrint(&npm_buf, "{s}/bin/npm", .{prefix}) catch return false;
    if (std.mem.indexOfScalar(u8, npm, '\'') != null or npm.len > plan.npm.len) return false;
    const shell = std.fmt.bufPrint(&plan.shell, "'{s}' update -g {s}", .{ npm, package }) catch return false;
    plan.shell_len = @intCast(shell.len);
    setArg(plan, package);
    @memcpy(plan.npm[0..npm.len], npm);
    plan.npm_len = @intCast(npm.len);
    plan.managed = true;
    plan.latest = .npm;
    return true;
}

fn applyBrew(path: []const u8, plan: *UpdatePlan) bool {
    const mark = "/Cellar/";
    const at = std.mem.indexOf(u8, path, mark) orelse return false;
    const rest = path[at + mark.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const formula = rest[0..end];
    if (!isSafeToken(formula)) return false;
    const shell = std.fmt.bufPrint(&plan.shell, "brew upgrade {s}", .{formula}) catch return false;
    plan.shell_len = @intCast(shell.len);
    setArg(plan, formula);
    plan.managed = true;
    plan.latest = .official;
    return true;
}

fn applyMise(path: []const u8, plan: *UpdatePlan) bool {
    const tool = miseTool(path, "/mise/installs/") orelse miseTool(path, "/mise/shims/") orelse return false;
    plan.managed = true;
    if (std.mem.eql(u8, tool, "node") or std.mem.startsWith(u8, tool, "npm-") or !isSafeToken(tool)) return true;
    const shell = std.fmt.bufPrint(&plan.shell, "mise upgrade {s}", .{tool}) catch return true;
    plan.shell_len = @intCast(shell.len);
    setArg(plan, tool);
    plan.latest = .mise;
    return true;
}

fn miseTool(path: []const u8, mark: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, path, mark) orelse return null;
    const rest = path[at + mark.len ..];
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn nodePackage(rest: []const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    if (rest[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const after = rest[slash + 1 ..];
        const end = std.mem.indexOfScalar(u8, after, '/') orelse return null;
        if (end == 0) return null;
        return rest[0 .. slash + 1 + end];
    }
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (end == 0) return null;
    return rest[0..end];
}

fn setArg(plan: *UpdatePlan, text: []const u8) void {
    if (text.len > plan.arg.len) return;
    @memcpy(plan.arg[0..text.len], text);
    plan.arg_len = @intCast(text.len);
}

fn isSafeToken(text: []const u8) bool {
    if (text.len == 0 or text.len > 80) return false;
    for (text) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '@' or c == '/' or c == '.')) return false;
    }
    return true;
}

fn canonicalPathAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const use_realpath = builtin.link_libc and switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => true,
        else => false,
    };
    if (!use_realpath) return null;
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    var resolved_buf: [std.posix.PATH_MAX]u8 = undefined;
    const canon = std.c.realpath(path_z.ptr, resolved_buf[0..].ptr) orelse return null;
    return allocator.dupe(u8, std.mem.sliceTo(canon, 0)) catch null;
}

fn commandFirstLine(allocator: std.mem.Allocator, argv: []const []const u8, out: []u8) ?[]const u8 {
    if (out.len == 0 or argv.len == 0) return null;
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return null;
    defer env_map.deinit();
    const executable = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, argv[0]) catch return null;
    defer allocator.free(executable);
    var args: [6][]const u8 = undefined;
    if (argv.len > args.len) return null;
    args[0] = executable;
    for (argv[1..], 1..) |arg, index| args[index] = arg;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const result = std.process.run(allocator, threaded.io(), .{
        .argv = args[0..argv.len],
        .environ_map = &env_map,
        .stdout_limit = .limited(OUTPUT_LIMIT),
        .stderr_limit = .limited(OUTPUT_LIMIT),
        .timeout = .{ .duration = .{
            .raw = .fromMilliseconds(4000),
            .clock = .awake,
        } },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const stdout = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    const source = if (stdout.len > 0) result.stdout else result.stderr;
    return copyFirstLine(source, out);
}
