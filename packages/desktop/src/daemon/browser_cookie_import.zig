//! GUI-free reader for importing cookies from other installed browsers into
//! Verde's browser store. Discovers Firefox-family (`cookies.sqlite`,
//! plaintext) and Chromium-family (`Cookies` SQLite with AES-encrypted
//! `encrypted_value`) profiles, decrypts Chromium values (Linux `v10`/`v11`
//! via libsecret through `secret-tool`), and aggregates cookies by domain so
//! the GUI can present a per-site import picker.
//!
//! Security: cookie names/values are never logged. Source DBs are copied to a
//! temporary directory (with their `-wal`/`-shm` companions) before opening
//! read-only, and the copies are removed on completion. This module links no
//! GUI code and lives in the daemon artifact (SQLite via zqlite).

const std = @import("std");

const zqlite = @import("zqlite");
const process_env = @import("../platform/env.zig");
const platform_runtime = @import("platform_runtime");

const log = std.log.scoped(.browser_cookie_import);

/// Chromium epoch offset: microseconds between 1601-01-01 and 1970-01-01.
const CHROMIUM_EPOCH_OFFSET_SECONDS: i64 = 11_644_473_600;

pub const SameSite = enum(i8) {
    unspecified = -1,
    none = 0,
    lax = 1,
    strict = 2,
};

pub const Family = enum { firefox, chromium };

/// A discovered source profile the user can import from.
pub const Source = struct {
    /// Stable identifier: `<browser_id>:<profile_dir_realpath>`.
    id: []const u8,
    /// Human label, e.g. "Chrome — Default" or "Zen — Default (release)".
    label: []const u8,
    family: Family,
    /// Browser identifier used for keyring lookup, e.g. "chrome", "brave".
    browser_id: []const u8,
    /// Absolute path to the cookie database file.
    db_path: []const u8,
};

pub const Cookie = struct {
    host: []const u8,
    name: []const u8,
    value: []const u8,
    path: []const u8,
    /// Unix seconds; 0 means a session cookie (no expiry).
    expires_unix: i64,
    secure: bool,
    http_only: bool,
    same_site: SameSite,
};

/// Per-domain aggregation for the import picker.
pub const DomainSummary = struct {
    domain: []const u8,
    count: usize,
};

pub const ReadError = error{
    KeyringUnavailable,
    UnsupportedPlatform,
    DecryptFailed,
} || std.mem.Allocator.Error;

// ------------------------------------------------------------------
// Source discovery
// ------------------------------------------------------------------

const FirefoxBrowser = struct {
    browser_id: []const u8,
    label: []const u8,
    /// Directory (under $HOME) holding `profiles.ini`.
    home_subpath: []const u8,
};

const ChromiumBrowser = struct {
    browser_id: []const u8,
    label: []const u8,
    /// Directory (under $HOME) holding profile subdirectories.
    home_subpath: []const u8,
    /// libsecret label prefix, e.g. "Chrome" in "Chrome Safe Storage".
    keyring_product: []const u8,
};

const FIREFOX_BROWSERS = [_]FirefoxBrowser{
    .{ .browser_id = "firefox", .label = "Firefox", .home_subpath = ".mozilla/firefox" },
    .{ .browser_id = "zen", .label = "Zen", .home_subpath = ".zen" },
    .{ .browser_id = "librewolf", .label = "LibreWolf", .home_subpath = ".librewolf" },
};

const CHROMIUM_BROWSERS = [_]ChromiumBrowser{
    .{ .browser_id = "chrome", .label = "Chrome", .home_subpath = ".config/google-chrome", .keyring_product = "Chrome" },
    .{ .browser_id = "chromium", .label = "Chromium", .home_subpath = ".config/chromium", .keyring_product = "Chromium" },
    .{ .browser_id = "brave", .label = "Brave", .home_subpath = ".config/BraveSoftware/Brave-Browser", .keyring_product = "Brave" },
    .{ .browser_id = "edge", .label = "Edge", .home_subpath = ".config/microsoft-edge", .keyring_product = "Microsoft Edge" },
    .{ .browser_id = "helium", .label = "Helium", .home_subpath = ".config/net.imput.helium", .keyring_product = "Helium" },
    .{ .browser_id = "vivaldi", .label = "Vivaldi", .home_subpath = ".config/vivaldi", .keyring_product = "Vivaldi" },
};

fn homeDir(arena: std.mem.Allocator) !?[]const u8 {
    if (std.c.getenv("HOME")) |h| {
        const slice = std.mem.sliceTo(h, 0);
        if (slice.len != 0) return try arena.dupe(u8, slice);
    }
    return null;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(io, path, .{}) catch return false;
    return true;
}

/// Discover all readable source profiles on this machine. Never fails on a
/// missing browser; only OOM propagates. Returned slices are arena-owned.
pub fn discoverSources(arena: std.mem.Allocator, io: std.Io) ![]Source {
    const home = (try homeDir(arena)) orelse return &.{};
    var out: std.ArrayList(Source) = .empty;

    for (FIREFOX_BROWSERS) |browser| {
        const base = try std.fs.path.join(arena, &.{ home, browser.home_subpath });
        if (!pathExists(io, base)) continue;
        try discoverFirefoxProfiles(arena, io, browser, base, &out);
    }
    for (CHROMIUM_BROWSERS) |browser| {
        const base = try std.fs.path.join(arena, &.{ home, browser.home_subpath });
        if (!pathExists(io, base)) continue;
        try discoverChromiumProfiles(arena, io, browser, base, &out);
    }
    return out.toOwnedSlice(arena);
}

fn discoverFirefoxProfiles(
    arena: std.mem.Allocator,
    io: std.Io,
    browser: FirefoxBrowser,
    base: []const u8,
    out: *std.ArrayList(Source),
) !void {
    const ini_path = try std.fs.path.join(arena, &.{ base, "profiles.ini" });
    const cwd = std.Io.Dir.cwd();
    const ini = cwd.readFileAlloc(io, ini_path, arena, .limited(256 * 1024)) catch {
        // No profiles.ini: fall back to scanning for a single cookies.sqlite.
        return;
    };
    // Parse `Path=` (relative to base unless IsRelative=0) and `Name=` fields
    // grouped by `[Profile N]` sections.
    var current_path: ?[]const u8 = null;
    var current_name: ?[]const u8 = null;
    var is_relative = true;

    var lines = std.mem.splitScalar(u8, ini, '\n');
    const Flush = struct {
        fn run(
            a: std.mem.Allocator,
            io2: std.Io,
            b: FirefoxBrowser,
            base2: []const u8,
            p: ?[]const u8,
            n: ?[]const u8,
            rel: bool,
            o: *std.ArrayList(Source),
        ) !void {
            const path_val = p orelse return;
            const profile_dir = if (rel)
                try std.fs.path.join(a, &.{ base2, path_val })
            else
                try a.dupe(u8, path_val);
            const db_path = try std.fs.path.join(a, &.{ profile_dir, "cookies.sqlite" });
            if (!pathExists(io2, db_path)) return;
            const real = std.Io.Dir.realPathFileAbsoluteAlloc(io2, profile_dir, a) catch profile_dir;
            const id = try std.fmt.allocPrint(a, "{s}:{s}", .{ b.browser_id, real });
            const label = try std.fmt.allocPrint(a, "{s} — {s}", .{ b.label, n orelse std.fs.path.basename(path_val) });
            try o.append(a, .{
                .id = id,
                .label = label,
                .family = .firefox,
                .browser_id = b.browser_id,
                .db_path = db_path,
            });
        }
    };
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            try Flush.run(arena, io, browser, base, current_path, current_name, is_relative, out);
            current_path = null;
            current_name = null;
            is_relative = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "Path=")) {
            current_path = try arena.dupe(u8, line["Path=".len..]);
        } else if (std.mem.startsWith(u8, line, "Name=")) {
            current_name = try arena.dupe(u8, line["Name=".len..]);
        } else if (std.mem.startsWith(u8, line, "IsRelative=")) {
            is_relative = !std.mem.eql(u8, line["IsRelative=".len..], "0");
        }
    }
    try Flush.run(arena, io, browser, base, current_path, current_name, is_relative, out);
}

fn discoverChromiumProfiles(
    arena: std.mem.Allocator,
    io: std.Io,
    browser: ChromiumBrowser,
    base: []const u8,
    out: *std.ArrayList(Source),
) !void {
    // Chromium profile dirs: "Default", "Profile 1", "Profile 2", ...
    var dir = std.Io.Dir.openDirAbsolute(io, base, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const is_profile = std.mem.eql(u8, entry.name, "Default") or
            std.mem.startsWith(u8, entry.name, "Profile ");
        if (!is_profile) continue;
        const profile_dir = try std.fs.path.join(arena, &.{ base, entry.name });
        // Chromium keeps cookies in `<profile>/Cookies` or `<profile>/Network/Cookies`.
        const candidates = [_][]const u8{ "Network/Cookies", "Cookies" };
        for (candidates) |cand| {
            const db_path = try std.fs.path.join(arena, &.{ profile_dir, cand });
            if (!pathExists(io, db_path)) continue;
            const real = std.Io.Dir.realPathFileAbsoluteAlloc(io, profile_dir, arena) catch profile_dir;
            const id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ browser.browser_id, real });
            const label = try std.fmt.allocPrint(arena, "{s} — {s}", .{ browser.label, entry.name });
            try out.append(arena, .{
                .id = id,
                .label = label,
                .family = .chromium,
                .browser_id = browser.browser_id,
                .db_path = db_path,
            });
            break;
        }
    }
}

fn chromiumBrowserById(browser_id: []const u8) ?ChromiumBrowser {
    for (CHROMIUM_BROWSERS) |b| {
        if (std.mem.eql(u8, b.browser_id, browser_id)) return b;
    }
    return null;
}

// ------------------------------------------------------------------
// Temp-copy helpers
// ------------------------------------------------------------------

const DbCopy = struct {
    dir_path: []const u8,
    db_path: []const u8,

    fn cleanup(self: DbCopy, io: std.Io) void {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, self.dir_path) catch {};
    }
};

/// Copy the DB plus `-wal`/`-shm` sidecars into a fresh temp dir so we never
/// touch the live browser store. Caller must `cleanup`.
fn copyDatabase(arena: std.mem.Allocator, io: std.Io, db_path: []const u8) !DbCopy {
    const cwd = std.Io.Dir.cwd();
    const ts: u64 = platform_runtime.monotonicTimestampNs();
    const nonce: u64 = ts ^ (@as(u64, std.Thread.getCurrentId()) << 40);
    const tmp_root = tmpBase(arena) catch "/tmp";
    const dir_path = try std.fmt.allocPrint(arena, "{s}/verde-cookie-import-{x}", .{ tmp_root, nonce });
    try cwd.createDirPath(io, dir_path);

    const base_name = std.fs.path.basename(db_path);
    const dest_db = try std.fs.path.join(arena, &.{ dir_path, base_name });
    var src_dir = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(db_path) orelse "/", .{});
    defer src_dir.close(io);
    var dst_dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dst_dir.close(io);

    try std.Io.Dir.copyFile(src_dir, base_name, dst_dir, base_name, io, .{});
    inline for (.{ "-wal", "-shm" }) |suffix| {
        const src_side = try std.fmt.allocPrint(arena, "{s}{s}", .{ base_name, suffix });
        const dst_side = src_side;
        std.Io.Dir.copyFile(src_dir, src_side, dst_dir, dst_side, io, .{}) catch {};
    }
    return .{ .dir_path = dir_path, .db_path = dest_db };
}

fn tmpBase(arena: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |d| {
        const slice = std.mem.sliceTo(d, 0);
        if (slice.len != 0) return try arena.dupe(u8, slice);
    }
    if (std.c.getenv("TMPDIR")) |d| {
        const slice = std.mem.sliceTo(d, 0);
        if (slice.len != 0) return try arena.dupe(u8, slice);
    }
    return "/tmp";
}

// ------------------------------------------------------------------
// Firefox reader
// ------------------------------------------------------------------

fn readFirefoxCookies(arena: std.mem.Allocator, io: std.Io, db_path: []const u8) ![]Cookie {
    const copy = try copyDatabase(arena, io, db_path);
    defer copy.cleanup(io);
    return readFirefoxFrom(arena, copy.db_path);
}

fn readFirefoxFrom(arena: std.mem.Allocator, db_path: []const u8) ![]Cookie {
    const path_z = try arena.dupeZ(u8, db_path);
    const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(path_z, flags);
    defer conn.close();

    var out: std.ArrayList(Cookie) = .empty;
    var rows = try conn.rows(
        "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try out.append(arena, .{
            .host = try arena.dupe(u8, row.text(0)),
            .name = try arena.dupe(u8, row.text(1)),
            .value = try arena.dupe(u8, row.text(2)),
            .path = try arena.dupe(u8, row.text(3)),
            .expires_unix = row.int(4),
            .secure = row.int(5) != 0,
            .http_only = row.int(6) != 0,
            .same_site = sameSiteFromInt(row.int(7)),
        });
    }
    if (rows.err) |err| return err;
    return out.toOwnedSlice(arena);
}

// ------------------------------------------------------------------
// Chromium reader + decrypt
// ------------------------------------------------------------------

fn readChromiumCookies(
    arena: std.mem.Allocator,
    io: std.Io,
    browser_id: []const u8,
    db_path: []const u8,
) ![]Cookie {
    const browser = chromiumBrowserById(browser_id) orelse return error.UnsupportedPlatform;
    // Resolve the v11 password (from the keyring); fall back to the v10 default.
    const key_v10 = deriveKey("peanuts");
    const key_v11: ?[16]u8 = blk: {
        const pw = keyringPassword(arena, io, browser.keyring_product) catch break :blk null;
        if (pw) |password| break :blk deriveKey(password);
        break :blk null;
    };

    const copy = try copyDatabase(arena, io, db_path);
    defer copy.cleanup(io);

    const path_z = try arena.dupeZ(u8, copy.db_path);
    const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.EXResCode;
    var conn = try zqlite.open(path_z, flags);
    defer conn.close();

    const meta_version = chromiumMetaVersion(conn);
    const strip_domain_prefix = meta_version >= 24;

    var out: std.ArrayList(Cookie) = .empty;
    var rows = try conn.rows(
        "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        const host = row.text(0);
        const plain = row.text(2);
        const enc = row.blob(3);
        const value: []const u8 = if (plain.len != 0)
            try arena.dupe(u8, plain)
        else
            decryptChromiumValue(arena, enc, key_v10, key_v11, strip_domain_prefix) catch
                continue; // Skip cookies we cannot decrypt rather than abort.

        try out.append(arena, .{
            .host = try arena.dupe(u8, host),
            .name = try arena.dupe(u8, row.text(1)),
            .value = value,
            .path = try arena.dupe(u8, row.text(4)),
            .expires_unix = chromiumTimeToUnix(row.int(5)),
            .secure = row.int(6) != 0,
            .http_only = row.int(7) != 0,
            .same_site = sameSiteFromInt(row.int(8)),
        });
    }
    if (rows.err) |err| return err;
    return out.toOwnedSlice(arena);
}

fn chromiumMetaVersion(conn: zqlite.Conn) i64 {
    const row = conn.row("SELECT value FROM meta WHERE key = 'version'", .{}) catch return 0;
    if (row) |r| {
        defer r.deinit();
        return std.fmt.parseInt(i64, r.text(0), 10) catch 0;
    }
    return 0;
}

/// Chromium `expires_utc` is microseconds since 1601-01-01. 0 = session cookie.
fn chromiumTimeToUnix(raw: i64) i64 {
    if (raw == 0) return 0;
    return @divTrunc(raw, 1_000_000) - CHROMIUM_EPOCH_OFFSET_SECONDS;
}

/// PBKDF2-SHA1(password, "saltysalt", 1 iteration) → 16-byte AES-128 key.
fn deriveKey(password: []const u8) [16]u8 {
    var key: [16]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        &key,
        password,
        "saltysalt",
        1,
        std.crypto.auth.hmac.HmacSha1,
    ) catch unreachable;
    return key;
}

/// Decrypt a Chromium `encrypted_value`. Handles `v10` (default password) and
/// `v11` (keyring password) prefixes, AES-128-CBC with a 16-space IV, PKCS#7
/// padding, and the SHA256(host_key) 32-byte prefix present at meta >= 24.
fn decryptChromiumValue(
    arena: std.mem.Allocator,
    enc: []const u8,
    key_v10: [16]u8,
    key_v11: ?[16]u8,
    strip_domain_prefix: bool,
) ![]const u8 {
    if (enc.len < 3) return error.DecryptFailed;
    const prefix = enc[0..3];
    const key = if (std.mem.eql(u8, prefix, "v11"))
        (key_v11 orelse return error.DecryptFailed)
    else if (std.mem.eql(u8, prefix, "v10"))
        key_v10
    else
        return error.DecryptFailed;

    const body = enc[3..];
    if (body.len == 0 or body.len % 16 != 0) return error.DecryptFailed;

    const buf = try arena.alloc(u8, body.len);
    errdefer arena.free(buf);

    const ctx = std.crypto.core.aes.Aes128.initDec(key);
    var iv = [_]u8{0x20} ** 16;
    var offset: usize = 0;
    while (offset < body.len) : (offset += 16) {
        var block: [16]u8 = undefined;
        ctx.decrypt(&block, body[offset..][0..16]);
        for (0..16) |i| block[i] ^= iv[i];
        @memcpy(buf[offset..][0..16], &block);
        @memcpy(&iv, body[offset..][0..16]);
    }

    // Strip PKCS#7 padding.
    const pad = buf[buf.len - 1];
    if (pad == 0 or pad > 16 or pad > buf.len) return error.DecryptFailed;
    var plain = buf[0 .. buf.len - pad];

    // Chromium >= v24 prepends a 32-byte SHA256(host_key) domain-bound prefix.
    if (strip_domain_prefix) {
        if (plain.len < 32) return error.DecryptFailed;
        plain = plain[32..];
    }
    return plain;
}

// ------------------------------------------------------------------
// Keyring (Linux, via secret-tool)
// ------------------------------------------------------------------

/// Look up the `<product> Safe Storage` password from the Secret Service.
/// Returns null when the keyring has no entry; errors only on tool failure.
fn keyringPassword(arena: std.mem.Allocator, io: std.Io, product: []const u8) !?[]const u8 {
    var env_map = try process_env.buildAugmentedEnvMap(arena);
    defer env_map.deinit();
    const secret_tool = process_env.resolveExecutableInEnvMapAlloc(arena, &env_map, "secret-tool") catch
        return error.KeyringUnavailable;

    const label = try std.fmt.allocPrint(arena, "{s} Safe Storage", .{product});

    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const result = std.process.run(arena, threaded.io(), .{
        .argv = &.{ secret_tool, "search", "--all", "xdg:schema", "chrome_libsecret_os_crypt_password_v2" },
        .environ_map = &env_map,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(4000), .clock = .awake } },
    }) catch return error.KeyringUnavailable;
    _ = io;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return parseSecretToolSearch(arena, result.stdout, label);
}

/// `secret-tool search` prints records as `attribute = value` lines with a
/// `secret = <password>` line per item and a `label = <label>` line. Return
/// the secret whose record carries the matching label.
fn parseSecretToolSearch(arena: std.mem.Allocator, output: []const u8, label: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var pending_secret: ?[]const u8 = null;
    var matched_label = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "label = ")) {
            const val = line["label = ".len..];
            matched_label = std.mem.eql(u8, val, label);
        } else if (std.mem.startsWith(u8, line, "secret = ")) {
            const val = line["secret = ".len..];
            if (matched_label) return try arena.dupe(u8, val);
            pending_secret = try arena.dupe(u8, val);
        }
    }
    // Fall back to the only secret found if no label matched exactly.
    return pending_secret;
}

// ------------------------------------------------------------------
// Public read API
// ------------------------------------------------------------------

/// Read every cookie from a discovered source.
pub fn readSourceCookies(arena: std.mem.Allocator, io: std.Io, source: Source) ![]Cookie {
    return switch (source.family) {
        .firefox => readFirefoxCookies(arena, io, source.db_path),
        .chromium => readChromiumCookies(arena, io, source.browser_id, source.db_path),
    };
}

/// Aggregate cookies by registrable-ish domain (leading dot stripped), sorted
/// by descending count then domain.
pub fn summarizeDomains(arena: std.mem.Allocator, cookies: []const Cookie) ![]DomainSummary {
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    defer map.deinit(arena);
    for (cookies) |cookie| {
        const domain = normalizeDomain(cookie.host);
        const gop = try map.getOrPut(arena, domain);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var out: std.ArrayList(DomainSummary) = .empty;
    var it = map.iterator();
    while (it.next()) |entry| {
        try out.append(arena, .{
            .domain = try arena.dupe(u8, entry.key_ptr.*),
            .count = entry.value_ptr.*,
        });
    }
    const slice = try out.toOwnedSlice(arena);
    std.mem.sort(DomainSummary, slice, {}, struct {
        fn lessThan(_: void, a: DomainSummary, b: DomainSummary) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.domain, b.domain);
        }
    }.lessThan);
    return slice;
}

fn normalizeDomain(host: []const u8) []const u8 {
    return if (host.len != 0 and host[0] == '.') host[1..] else host;
}

fn sameSiteFromInt(raw: i64) SameSite {
    return switch (raw) {
        0 => .none,
        1 => .lax,
        2 => .strict,
        else => .unspecified,
    };
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

const testing = std.testing;

test "chromium v10 decrypt known vector" {
    // Encrypt a known plaintext with the v10 scheme, then verify decrypt.
    const arena_alloc = testing.allocator;
    const key = deriveKey("peanuts");
    const plaintext = "session=abc123";

    // Build padded plaintext (PKCS#7), CBC-encrypt with 16-space IV.
    const block_count = (plaintext.len / 16) + 1;
    const padded_len = block_count * 16;
    const padded = try arena_alloc.alloc(u8, padded_len);
    defer arena_alloc.free(padded);
    @memcpy(padded[0..plaintext.len], plaintext);
    const pad: u8 = @intCast(padded_len - plaintext.len);
    @memset(padded[plaintext.len..], pad);

    const enc_ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var iv = [_]u8{0x20} ** 16;
    const cipher = try arena_alloc.alloc(u8, padded_len);
    defer arena_alloc.free(cipher);
    var off: usize = 0;
    while (off < padded_len) : (off += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |i| block[i] = padded[off + i] ^ iv[i];
        enc_ctx.encrypt(cipher[off..][0..16], &block);
        @memcpy(&iv, cipher[off..][0..16]);
    }

    const enc_value = try std.fmt.allocPrint(arena_alloc, "v10{s}", .{cipher});
    defer arena_alloc.free(enc_value);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try decryptChromiumValue(arena.allocator(), enc_value, key, null, false);
    try testing.expectEqualStrings(plaintext, got);
}

test "chromium v24 domain prefix stripped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = deriveKey("peanuts");

    var prefixed: [32 + 5]u8 = undefined;
    @memset(prefixed[0..32], 0xAB);
    @memcpy(prefixed[32..], "hello");
    const enc = try encryptV10(a, key, &prefixed);
    const got = try decryptChromiumValue(a, enc, key, null, true);
    try testing.expectEqualStrings("hello", got);
}

fn encryptV10(a: std.mem.Allocator, key: [16]u8, plaintext: []const u8) ![]const u8 {
    const block_count = (plaintext.len / 16) + 1;
    const padded_len = block_count * 16;
    const padded = try a.alloc(u8, padded_len);
    @memcpy(padded[0..plaintext.len], plaintext);
    const pad: u8 = @intCast(padded_len - plaintext.len);
    @memset(padded[plaintext.len..], pad);
    const enc_ctx = std.crypto.core.aes.Aes128.initEnc(key);
    var iv = [_]u8{0x20} ** 16;
    const cipher = try a.alloc(u8, padded_len);
    var off: usize = 0;
    while (off < padded_len) : (off += 16) {
        var block: [16]u8 = undefined;
        for (0..16) |i| block[i] = padded[off + i] ^ iv[i];
        enc_ctx.encrypt(cipher[off..][0..16], &block);
        @memcpy(&iv, cipher[off..][0..16]);
    }
    return std.fmt.allocPrint(a, "v10{s}", .{cipher});
}

test "chromium time conversion" {
    try testing.expectEqual(@as(i64, 0), chromiumTimeToUnix(0));
    // 13332988800000000 µs since 1601 == 2023-07-05T00:00:00Z (1688515200 unix).
    try testing.expectEqual(@as(i64, 1688515200), chromiumTimeToUnix(13332988800000000));
}

test "domain summary aggregation and sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cookies = [_]Cookie{
        .{ .host = ".example.com", .name = "a", .value = "1", .path = "/", .expires_unix = 0, .secure = false, .http_only = false, .same_site = .lax },
        .{ .host = "example.com", .name = "b", .value = "2", .path = "/", .expires_unix = 0, .secure = false, .http_only = false, .same_site = .lax },
        .{ .host = "other.org", .name = "c", .value = "3", .path = "/", .expires_unix = 0, .secure = false, .http_only = false, .same_site = .lax },
    };
    const summary = try summarizeDomains(a, &cookies);
    try testing.expectEqual(@as(usize, 2), summary.len);
    try testing.expectEqualStrings("example.com", summary[0].domain);
    try testing.expectEqual(@as(usize, 2), summary[0].count);
    try testing.expectEqualStrings("other.org", summary[1].domain);
}

test "firefox reader over fixture db" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_rel = "cookies.sqlite";
    const abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const db_path = try std.fs.path.join(a, &.{ abs, db_rel });

    {
        const path_z = try a.dupeZ(u8, db_path);
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode;
        var conn = try zqlite.open(path_z, flags);
        defer conn.close();
        try conn.execNoArgs(
            "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)",
        );
        try conn.exec(
            "INSERT INTO moz_cookies VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            .{ ".example.com", "sid", "xyz", "/", @as(i64, 1700000000), @as(i64, 1), @as(i64, 1), @as(i64, 1) },
        );
    }

    const cookies = try readFirefoxFrom(a, db_path);
    try testing.expectEqual(@as(usize, 1), cookies.len);
    try testing.expectEqualStrings(".example.com", cookies[0].host);
    try testing.expectEqualStrings("sid", cookies[0].name);
    try testing.expectEqualStrings("xyz", cookies[0].value);
    try testing.expect(cookies[0].secure);
    try testing.expectEqual(SameSite.lax, cookies[0].same_site);
}

test "secret-tool search parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const output =
        \\[/org/freedesktop/secrets/collection/login/1]
        \\label = Chromium Safe Storage
        \\secret = wrongpw
        \\attribute.application = chromium
        \\
        \\[/org/freedesktop/secrets/collection/login/2]
        \\label = Chrome Safe Storage
        \\secret = correctpw
        \\attribute.application = chrome
        \\
    ;
    const pw = try parseSecretToolSearch(a, output, "Chrome Safe Storage");
    try testing.expect(pw != null);
    try testing.expectEqualStrings("correctpw", pw.?);
}
