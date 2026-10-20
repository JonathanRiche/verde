//! Repository identity: normalizes a raw git `origin` URL to a stable,
//! versioned key so checkouts on different machines can be grouped
//! (docs/multi-machine-workspaces.md, "Repository identity"). Pure and
//! allocation-bounded; shared by desktop, web and mobile.
const std = @import("std");

/// Prefix of every key. Changing any normalization rule bumps it, so clients
/// on different rule sets never silently disagree.
pub const VERSION_PREFIX = "v1:";
/// Longest raw remote URL accepted, after trimming surrounding whitespace.
pub const MAX_URL_LEN: usize = 2048;
/// Upper bound of a normalized key; size buffers passed to `normalize` with it.
pub const MAX_KEY_LEN: usize = VERSION_PREFIX.len + MAX_URL_LEN;

/// Writes the normalized key for `raw` into `out` and returns it, or null for
/// local paths, `file://` URLs, unknown schemes, and anything malformed.
///
/// `git@host:owner/repo`, `ssh://[user@]host[:port]/owner/repo`,
/// `git://…`, `http://…` and `https://[user@]host/owner/repo(.git)` all map to
/// `v1:host/owner/repo`. User, port, trailing `/` and one `.git` suffix are
/// dropped and the host is lowercased; the path is lowercased for
/// `github.com` only and kept exact for every other host.
pub fn normalize(out: *[MAX_KEY_LEN]u8, raw: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, raw, " \t\r\n");
    if (url.len == 0 or url.len > MAX_URL_LEN) return null;
    for (url) |c| if (c < 0x20 or c == 0x7f) return null;

    var authority: []const u8 = undefined;
    var path: []const u8 = undefined;
    var scp_like = false;
    if (std.mem.indexOf(u8, url, "://")) |scheme_end| {
        if (!knownScheme(url[0..scheme_end])) return null;
        const rest = url[scheme_end + 3 ..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        authority = rest[0..slash];
        path = rest[slash + 1 ..];
    } else {
        // scp-like `[user@]host:path`. No colon, or a `/` before the first
        // colon, means a local path (the same rule git uses).
        const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
        if (std.mem.indexOfScalar(u8, url[0..colon], '/') != null) return null;
        authority = url[0..colon];
        path = url[colon + 1 ..];
        scp_like = true;
    }

    const host = hostOf(authority, scp_like) orelse return null;
    const repo_path = repoPath(path) orelse return null;
    const fold_path = std.ascii.eqlIgnoreCase(host, "github.com");

    var len: usize = 0;
    @memcpy(out[len..][0..VERSION_PREFIX.len], VERSION_PREFIX);
    len += VERSION_PREFIX.len;
    for (host) |c| {
        out[len] = std.ascii.toLower(c);
        len += 1;
    }
    out[len] = '/';
    len += 1;
    for (repo_path) |c| {
        out[len] = if (fold_path) std.ascii.toLower(c) else c;
        len += 1;
    }
    return out[0..len];
}

/// Allocating form of `normalize`; the caller owns the returned key.
pub fn normalizeAlloc(allocator: std.mem.Allocator, raw: []const u8) error{OutOfMemory}!?[]u8 {
    var buffer: [MAX_KEY_LEN]u8 = undefined;
    const key = normalize(&buffer, raw) orelse return null;
    return try allocator.dupe(u8, key);
}

/// True when both remotes normalize to the same key. Unmappable remotes never
/// match anything, including themselves.
pub fn sameRepository(a: []const u8, b: []const u8) bool {
    var left: [MAX_KEY_LEN]u8 = undefined;
    var right: [MAX_KEY_LEN]u8 = undefined;
    const x = normalize(&left, a) orelse return false;
    const y = normalize(&right, b) orelse return false;
    return std.mem.eql(u8, x, y);
}

fn knownScheme(scheme: []const u8) bool {
    for ([_][]const u8{ "https", "http", "ssh", "git", "git+ssh", "ssh+git" }) |known| {
        if (std.ascii.eqlIgnoreCase(scheme, known)) return true;
    }
    return false;
}

/// Host without user or port, or null when it is not a plausible host name.
fn hostOf(authority: []const u8, scp_like: bool) ?[]const u8 {
    var host = authority;
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    if (!scp_like) {
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
            for (host[colon + 1 ..]) |c| if (!std.ascii.isDigit(c)) return null;
            host = host[0..colon];
        }
    }
    // A one-letter "host" is a Windows drive (`C:/repo`), not a remote.
    if (host.len < 2) return null;
    if (host[0] == '.' or host[0] == '-' or host[host.len - 1] == '-') return null;
    for (host) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return null;
    }
    return host;
}

/// Repository path with surrounding `/` and one `.git` suffix removed, or null
/// when it is empty or has empty, `.`/`..`, query, fragment or blank parts.
fn repoPath(raw: []const u8) ?[]const u8 {
    var path = std.mem.trim(u8, raw, "/");
    if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - ".git".len];
    path = std.mem.trimEnd(u8, path, "/");
    if (path.len == 0) return null;
    for (path) |c| {
        if (c <= ' ' or c == '?' or c == '#' or c == '\\') return null;
    }
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return null;
    }
    return path;
}

fn expectKey(expected: ?[]const u8, raw: []const u8) !void {
    var buffer: [MAX_KEY_LEN]u8 = undefined;
    const actual = normalize(&buffer, raw);
    if (expected) |key| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(key, actual.?);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), actual);
    }
}

test "ssh, scp-like and https remotes of one GitHub repository are equal" {
    const key = "v1:github.com/jonathanriche/verde";
    for ([_][]const u8{
        "git@github.com:JonathanRiche/verde.git",
        "git@github.com:JonathanRiche/verde",
        "github.com:JonathanRiche/verde",
        "ssh://git@github.com/JonathanRiche/verde.git",
        "ssh://github.com/JonathanRiche/verde",
        "ssh://git@github.com:22/JonathanRiche/verde.git",
        "git+ssh://git@github.com/JonathanRiche/verde.git",
        "https://github.com/JonathanRiche/verde.git",
        "https://github.com/JonathanRiche/verde",
        "https://github.com/JonathanRiche/verde/",
        "https://github.com/JonathanRiche/verde.git/",
        "https://user:token@github.com/JonathanRiche/verde.git",
        "https://github.com:443/JonathanRiche/verde",
        "http://github.com/JonathanRiche/verde",
        "git://github.com/JonathanRiche/verde.git",
        "HTTPS://GitHub.COM/jonathanriche/VERDE",
        "  git@github.com:JonathanRiche/verde.git\n",
    }) |raw| try expectKey(key, raw);
    try std.testing.expect(sameRepository("git@github.com:a/b.git", "https://github.com/A/B"));
}

test "non-GitHub hosts keep the path case and lowercase only the host" {
    try expectKey("v1:gitlab.com/Group/Repo", "git@GitLab.com:Group/Repo.git");
    try expectKey("v1:gitlab.com/Group/Repo", "https://gitlab.com/Group/Repo");
    try std.testing.expect(!sameRepository("https://gitlab.com/Group/Repo", "https://gitlab.com/group/repo"));
    try expectKey("v1:git.example.com/Team/Project", "ssh://git@git.example.com:2222/Team/Project.git");
    try expectKey("v1:git.example.com/Team/Project", "git@git.example.com:Team/Project");
}

test "GitLab subgroups keep the full path" {
    try expectKey("v1:gitlab.com/group/sub/repo", "git@gitlab.com:group/sub/repo.git");
    try expectKey("v1:gitlab.com/group/sub/repo", "https://gitlab.com/group/sub/repo/");
    try std.testing.expect(!sameRepository("https://gitlab.com/group/sub/repo", "https://gitlab.com/group/repo"));
}

test "different owners, hosts and forks stay apart" {
    try std.testing.expect(!sameRepository("git@github.com:alice/verde.git", "git@github.com:bob/verde.git"));
    try std.testing.expect(!sameRepository("git@github.com:alice/verde.git", "git@gitlab.com:alice/verde.git"));
    try std.testing.expect(!sameRepository("git@github.com:alice/verde.git", "git@github.com:alice/verde-fork.git"));
}

test "only one .git suffix is dropped and single-segment paths map" {
    try expectKey("v1:example.com/repo.git", "https://example.com/repo.git.git");
    try expectKey("v1:example.com/repo", "user@example.com:repo.git");
    try expectKey("v1:example.com/srv/git/repo", "ssh://example.com/srv/git/repo.git");
    try expectKey("v1:example.com/srv/git/repo", "example.com:/srv/git/repo.git");
}

test "local paths, file URLs and malformed remotes are rejected" {
    for ([_][]const u8{
        "",
        "   ",
        "/home/me/src/verde",
        "./verde",
        "../verde",
        "verde",
        "~/src/verde",
        "C:/src/verde",
        "C:\\src\\verde",
        "file:///home/me/src/verde",
        "file://localhost/srv/verde.git",
        "ftp://example.com/owner/repo",
        "https://github.com",
        "https://github.com/",
        "https://github.com/.git",
        "git@github.com:",
        "git@github.com:/",
        "https://github.com/owner//repo",
        "https://github.com/owner/../repo",
        "https://github.com/owner/./repo",
        "https://github.com/owner/repo?ref=main",
        "https://github.com/owner/repo#readme",
        "https://github.com:abc/owner/repo",
        "https://exa mple.com/owner/repo",
        "https://example.com/owner/my repo",
        "https://-bad.com/owner/repo",
        "https://@/owner/repo",
        "https://github.com/owner/repo\x00",
        "https://github.com/owner/\x1brepo",
        "git@github.com:owner/repo\x7f",
        "https://github.com/owner/re\npo",
    }) |raw| try expectKey(null, raw);
    try std.testing.expect(!sameRepository("/srv/repo", "/srv/repo"));
}

test "absurd lengths are rejected and the bound holds at the limit" {
    var long: [MAX_URL_LEN + 1]u8 = undefined;
    const prefix = "https://example.com/";
    @memcpy(long[0..prefix.len], prefix);
    @memset(long[prefix.len..], 'a');
    try expectKey(null, &long);
    var buffer: [MAX_KEY_LEN]u8 = undefined;
    const key = normalize(&buffer, long[0..MAX_URL_LEN]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(MAX_URL_LEN - "https://".len + VERSION_PREFIX.len, key.len);
}

test "normalizeAlloc returns an owned key or null" {
    const key = (try normalizeAlloc(std.testing.allocator, "git@github.com:Owner/Repo.git")).?;
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("v1:github.com/owner/repo", key);
    try std.testing.expectEqual(@as(?[]u8, null), try normalizeAlloc(std.testing.allocator, "/tmp/repo"));
}
