//! Per-user application directories.
//!
//! `prefPath` reproduces SDL3's `SDL_GetPrefPath` on Linux/Unix byte for byte (verified
//! against libSDL3 3.4.16), so a host migrating from SDL keeps its existing data directory:
//!
//! * base = `$XDG_DATA_HOME` when the variable is set (even if empty), else `$HOME` followed
//!   by `/.local/share/`; error when neither is set;
//! * one separator is dropped when the base already ends in `/` (only one: `x//` stays);
//! * then `org/app/` when `org` is non-empty, else `app/` (no sanitising, `/` in a name
//!   makes subdirectories, an empty app gives `org//`);
//! * every component after the first byte is created with mode 0700 (EEXIST is fine).
//!
//! Example: org "verde", app "Native" -> `~/.local/share/verde/Native/`.
//!
//! On macOS it follows SDL3's Cocoa rule instead: base = the first entry of
//! `NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)`
//! (`~/Library/Application Support`, or the container path for sandboxed apps), then
//! `/org/app/` (or `/app/` for an empty org); every component is mkdir'ed 0700 and, like SDL,
//! mkdir failures are ignored there. The environment is not consulted.
//!
//! On Windows it reproduces SDL3's `SDL_GetPrefPath` (src/filesystem/windows):
//!
//! * base = `SHGetFolderPathW(CSIDL_APPDATA | CSIDL_FLAG_CREATE)` (the roaming AppData
//!   folder, e.g. `C:\Users\u\AppData\Roaming`);
//! * error when `len(base) + len(org) + len(app) + 4 > MAX_PATH` (UTF-16 units);
//! * `\org` is appended and created when `org` is non-empty, then `\app` (always created),
//!   then a trailing `\`; ERROR_ALREADY_EXISTS is fine;
//! * the result is UTF-8.
//!
//! Example: org "verde", app "Native" -> `C:\Users\u\AppData\Roaming\verde\Native\`.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const is_windows = builtin.os.tag == .windows;

/// Environment lookup for `prefPath` (and the Wayland connection).
pub const Env = struct {
    environ: std.process.Environ = .empty,

    /// POSIX only. On Windows `prefPath` asks the shell instead and this returns null.
    pub fn get(e: Env, key: []const u8) ?[]const u8 {
        if (is_windows) return null;
        if (e.environ.block.slice.len > 0) return e.environ.getPosix(key);
        if (builtin.link_libc) {
            var kbuf: [128]u8 = undefined;
            if (key.len >= kbuf.len) return null;
            @memcpy(kbuf[0..key.len], key);
            kbuf[key.len] = 0;
            const v = std.c.getenv(@ptrCast(&kbuf)) orelse return null;
            return std.mem.sliceTo(v, 0);
        }
        return null;
    }
};

pub const PrefPathError = error{
    /// Neither XDG_DATA_HOME nor HOME is set.
    NoHomeDirectory,
    /// mkdir failed with something other than EEXIST.
    CreateDirectoryFailed,
    /// Windows: the path would exceed MAX_PATH (SDL's "Path too long." error).
    PathTooLong,
    OutOfMemory,
};

/// Returns the NUL-terminated directory path (with a trailing `/`, `\` on Windows) and creates it. The
/// caller frees the result with `gpa`. `org` null behaves like "" (SDL semantics).
pub fn prefPath(gpa: std.mem.Allocator, env: Env, org: ?[]const u8, app: []const u8) PrefPathError![:0]u8 {
    switch (builtin.os.tag) {
        .windows => return windowsPrefPath(gpa, org, app),
        .macos => {
            const path = try composeMacPrefPath(gpa, try macApplicationSupport(), org, app);
            makeDirs(path) catch {};
            return path;
        },
        else => return prefPathFrom(gpa, env.get("XDG_DATA_HOME"), env.get("HOME"), org, app),
    }
}

/// `prefPath` with explicit environment values (testable without touching the process
/// environment).
pub fn prefPathFrom(gpa: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8, org: ?[]const u8, app: []const u8) PrefPathError![:0]u8 {
    const path = try composePrefPath(gpa, xdg_data_home, home, org, app);
    errdefer gpa.free(path);
    try makeDirs(path);
    return path;
}

/// Builds the path without creating anything.
pub fn composePrefPath(gpa: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8, org: ?[]const u8, app: []const u8) PrefPathError![:0]u8 {
    var base: []const u8 = undefined;
    var append: []const u8 = undefined;
    if (xdg_data_home) |x| {
        base = x;
        append = "/";
    } else if (home) |h| {
        base = h;
        append = "/.local/share/";
    } else return error.NoHomeDirectory;
    // SDL reads envr[len - 1] unconditionally; for an empty base that byte is not '/', so the
    // separator stays (an empty XDG_DATA_HOME yields "/org/app/").
    if (base.len > 0 and base[base.len - 1] == '/') append = append[1..];
    const o = org orelse "";
    return if (o.len > 0)
        std.fmt.allocPrintSentinel(gpa, "{s}{s}{s}/{s}/", .{ base, append, o, app }, 0)
    else
        std.fmt.allocPrintSentinel(gpa, "{s}{s}{s}/", .{ base, append, app }, 0);
}

/// SDL3 macOS composition: `base/org/app/` or `base/app/` (no separator dropping).
pub fn composeMacPrefPath(gpa: std.mem.Allocator, base: []const u8, org: ?[]const u8, app: []const u8) PrefPathError![:0]u8 {
    const o = org orelse "";
    return if (o.len > 0)
        std.fmt.allocPrintSentinel(gpa, "{s}/{s}/{s}/", .{ base, o, app }, 0)
    else
        std.fmt.allocPrintSentinel(gpa, "{s}/{s}/", .{ base, app }, 0);
}

/// `~/Library/Application Support` from Foundation (valid until the process exits: the
/// string is copied into a static buffer).
fn macApplicationSupport() PrefPathError![]const u8 {
    const objc = @import("macos/objc.zig");
    const S = struct {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
    };
    objc.load() catch return error.NoHomeDirectory;
    const pool = objc.Pool.push();
    defer pool.pop();
    const search = objc.cSymbol(*const fn (objc.NSUInteger, objc.NSUInteger, objc.BOOL) callconv(.c) ?objc.Id, "NSSearchPathForDirectoriesInDomains") orelse return error.NoHomeDirectory;
    const array = search(14, 1, objc.YES) orelse return error.NoHomeDirectory; // NSApplicationSupportDirectory, NSUserDomainMask
    if (objc.send(objc.NSUInteger, array, "count", .{}) == 0) return error.NoHomeDirectory;
    const str = objc.send(objc.Id, array, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const fsr = objc.send(?[*:0]const u8, str, "fileSystemRepresentation", .{}) orelse return error.NoHomeDirectory;
    const base = std.mem.span(fsr);
    if (base.len > S.buf.len) return error.NoHomeDirectory;
    @memcpy(S.buf[0..base.len], base);
    return S.buf[0..base.len];
}

fn makeDirs(path: [:0]u8) PrefPathError!void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        path[i] = 0;
        defer path[i] = '/';
        try mkdir0700(path.ptr);
    }
    try mkdir0700(path.ptr);
}

fn mkdir0700(p: [*:0]const u8) PrefPathError!void {
    if (builtin.os.tag == .linux) {
        switch (linux.errno(linux.mkdir(p, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.CreateDirectoryFailed,
        }
    } else {
        switch (std.c.errno(std.c.mkdir(p, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.CreateDirectoryFailed,
        }
    }
}

// -- Windows -------------------------------------------------------------------------------------

const max_path = 260;

/// The SDL3 Windows composition on UTF-16 (testable anywhere): `base\org\app\` and the
/// lengths of the prefixes to create (`base\org` when org is non-empty, `base\org\app`).
pub const WindowsPrefPath = struct {
    buf: [max_path + 2]u16 = undefined,
    len: usize = 0,
    /// Prefix lengths (in units) of the directories to create, in order.
    dirs: [2]usize = .{ 0, 0 },
    dir_count: usize = 0,

    pub fn compose(base: []const u16, org: []const u16, app: []const u16) error{PathTooLong}!WindowsPrefPath {
        // SDL: if (SDL_wcslen(org) + SDL_wcslen(app) + SDL_wcslen(path) + 3 + 1 > MAX_PATH)
        if (org.len + app.len + base.len + 3 + 1 > max_path) return error.PathTooLong;
        var p: WindowsPrefPath = .{};
        p.append(base);
        if (org.len > 0) {
            p.append(&.{'\\'});
            p.append(org);
            p.dirs[p.dir_count] = p.len;
            p.dir_count += 1;
        }
        p.append(&.{'\\'});
        p.append(app);
        p.dirs[p.dir_count] = p.len;
        p.dir_count += 1;
        p.append(&.{'\\'});
        return p;
    }

    fn append(p: *WindowsPrefPath, s: []const u16) void {
        @memcpy(p.buf[p.len..][0..s.len], s);
        p.len += s.len;
    }

    pub fn slice(p: *const WindowsPrefPath) []const u16 {
        return p.buf[0..p.len];
    }

    pub fn toUtf8(p: *const WindowsPrefPath, gpa: std.mem.Allocator) error{OutOfMemory}![:0]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(gpa);
        var it = std.unicode.Utf16LeIterator.init(p.slice());
        while (true) {
            const next: ?u21 = it.nextCodepoint() catch 0xFFFD;
            const cp = next orelse break;
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &b) catch 3;
            try list.appendSlice(gpa, b[0..n]);
        }
        return list.toOwnedSliceSentinel(gpa, 0);
    }
};

fn utf8ToUtf16Alloc(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u16 {
    return std.unicode.wtf8ToWtf16LeAlloc(gpa, s) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // Invalid UTF-8: lossy, one unit per byte.
            const out = try gpa.alloc(u16, s.len);
            for (s, out) |c, *o| o.* = if (c < 0x80) c else 0xFFFD;
            return out;
        },
    };
}

const win = struct {
    extern "shell32" fn SHGetFolderPathW(?*anyopaque, i32, ?*anyopaque, u32, [*]u16) callconv(.winapi) i32;
    extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    const CSIDL_APPDATA = 0x001a;
    const CSIDL_FLAG_CREATE = 0x8000;
    const ERROR_ALREADY_EXISTS = 183;
};

fn windowsPrefPath(gpa: std.mem.Allocator, org: ?[]const u8, app: []const u8) PrefPathError![:0]u8 {
    if (!is_windows) unreachable;
    var base: [max_path]u16 = undefined;
    if (win.SHGetFolderPathW(null, win.CSIDL_APPDATA | win.CSIDL_FLAG_CREATE, null, 0, &base) < 0)
        return error.NoHomeDirectory;
    const base_len = std.mem.indexOfScalar(u16, &base, 0) orelse return error.NoHomeDirectory;
    const org16 = try utf8ToUtf16Alloc(gpa, org orelse "");
    defer gpa.free(org16);
    const app16 = try utf8ToUtf16Alloc(gpa, app);
    defer gpa.free(app16);
    var p = try WindowsPrefPath.compose(base[0..base_len], org16, app16);
    for (p.dirs[0..p.dir_count]) |end| {
        const saved = p.buf[end];
        p.buf[end] = 0;
        defer p.buf[end] = saved;
        if (win.CreateDirectoryW(@ptrCast(&p.buf), null) == 0 and win.GetLastError() != win.ERROR_ALREADY_EXISTS)
            return error.CreateDirectoryFailed;
    }
    return p.toUtf8(gpa);
}

const testing = std.testing;

test "windows pref path composition matches SDL3" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const a = testing.allocator;
    const cases = [_]struct { org: []const u16, app: []const u16, want: []const u8, dirs: usize }{
        .{ .org = L("verde"), .app = L("Native"), .want = "C:\\Users\\u\\AppData\\Roaming\\verde\\Native\\", .dirs = 2 },
        .{ .org = L(""), .app = L("App"), .want = "C:\\Users\\u\\AppData\\Roaming\\App\\", .dirs = 1 },
        .{ .org = L("org"), .app = L(""), .want = "C:\\Users\\u\\AppData\\Roaming\\org\\\\", .dirs = 2 },
        .{ .org = L("\u{e9}t\u{e9}"), .app = L("\u{1F600}"), .want = "C:\\Users\\u\\AppData\\Roaming\\\u{e9}t\u{e9}\\\u{1F600}\\", .dirs = 2 },
    };
    for (cases) |cs| {
        const p = try WindowsPrefPath.compose(L("C:\\Users\\u\\AppData\\Roaming"), cs.org, cs.app);
        const got = try p.toUtf8(a);
        defer a.free(got);
        try testing.expectEqualStrings(cs.want, got);
        try testing.expectEqual(cs.dirs, p.dir_count);
    }
    // MAX_PATH check: base + org + app + 4 > 260 fails, == 260 passes.
    const long: [200]u16 = @splat('x');
    _ = try WindowsPrefPath.compose(&long, &(@as([28]u16, @splat('o'))), &(@as([28]u16, @splat('a'))));
    try testing.expectError(error.PathTooLong, WindowsPrefPath.compose(&long, &(@as([29]u16, @splat('o'))), &(@as([28]u16, @splat('a')))));
}

test "pref path composition matches SDL3" {
    const a = testing.allocator;
    const cases = [_]struct { xdg: ?[]const u8, home: ?[]const u8, org: ?[]const u8, app: []const u8, want: []const u8 }{
        .{ .xdg = null, .home = "/home/u", .org = "verde", .app = "Native", .want = "/home/u/.local/share/verde/Native/" },
        .{ .xdg = null, .home = "/home/u/", .org = "verde", .app = "Native", .want = "/home/u/.local/share/verde/Native/" },
        .{ .xdg = "/x", .home = "/home/u", .org = "verde", .app = "Native", .want = "/x/verde/Native/" },
        .{ .xdg = "/x/", .home = null, .org = "", .app = "App", .want = "/x/App/" },
        .{ .xdg = "/x", .home = null, .org = null, .app = "App", .want = "/x/App/" },
        .{ .xdg = "/x//", .home = null, .org = "o", .app = "a", .want = "/x//o/a/" },
        .{ .xdg = "", .home = "/home/u", .org = "org", .app = "app", .want = "/org/app/" },
        .{ .xdg = "/x", .home = null, .org = "a/b", .app = "c d", .want = "/x/a/b/c d/" },
        .{ .xdg = "/x", .home = null, .org = "org", .app = "", .want = "/x/org//" },
        .{ .xdg = "rel", .home = null, .org = "o", .app = "a", .want = "rel/o/a/" },
    };
    for (cases) |cs| {
        const got = try composePrefPath(a, cs.xdg, cs.home, cs.org, cs.app);
        defer a.free(got);
        try testing.expectEqualStrings(cs.want, got);
    }
    try testing.expectError(error.NoHomeDirectory, composePrefPath(a, null, null, "o", "a"));
}

test "pref path creates every component with mode 0700" {
    if (is_windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPathFile(testing.io, ".", &buf);
    const root = buf[0..n];
    const home = try std.fmt.allocPrint(a, "{s}/home", .{root});
    defer a.free(home);
    const p = try prefPathFrom(a, null, home, "verde", "Native");
    defer a.free(p);
    try testing.expect(std.mem.endsWith(u8, p, "/home/.local/share/verde/Native/"));
    // Second call: everything exists already.
    const again = try prefPathFrom(a, null, home, "verde", "Native");
    defer a.free(again);
    try testing.expectEqualStrings(p, again);
    if (builtin.os.tag == .linux) {
        var stx: linux.Statx = undefined;
        try testing.expectEqual(@as(usize, 0), linux.statx(linux.AT.FDCWD, p.ptr, 0, .{ .MODE = true, .TYPE = true }, &stx));
        try testing.expectEqual(@as(u16, 0o700), stx.mode & 0o777);
        try testing.expect(linux.S.ISDIR(stx.mode));
    } else {
        var st: std.c.Stat = undefined;
        try testing.expectEqual(@as(c_int, 0), std.c.fstatat(std.c.AT.FDCWD, p.ptr, &st, 0));
        try testing.expectEqual(@as(u32, 0o700), @as(u32, st.mode) & 0o777);
    }
}

test "macOS pref path composition matches SDL3 (Cocoa)" {
    const a = testing.allocator;
    const base = "/Users/u/Library/Application Support";
    const p1 = try composeMacPrefPath(a, base, "verde", "Native");
    defer a.free(p1);
    try testing.expectEqualStrings("/Users/u/Library/Application Support/verde/Native/", p1);
    const p2 = try composeMacPrefPath(a, base, null, "App");
    defer a.free(p2);
    try testing.expectEqualStrings("/Users/u/Library/Application Support/App/", p2);
}
