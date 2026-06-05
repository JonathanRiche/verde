//! Cross-platform "agent finished" desktop notifications.
//!
//! Fires a best-effort OS notification when an agent surface transitions to
//! `.done`. This is the native, in-app equivalent of the user's external Codex
//! Stop hook (`notify-send` + completion chime on Linux); on macOS it routes
//! through `terminal-notifier` (when present, so the provider logo shows) or
//! AppleScript via `osascript`.
//!
//! Everything here is best-effort and side-effect only: a missing
//! `notify-send`/`osascript`, an unresolved PATH, or a spawn failure is
//! swallowed so a finished agent turn can never disrupt the app.

const std = @import("std");
const builtin = @import("builtin");

const process_env = @import("process_env.zig");

const log = std.log.scoped(.native_notifier);

// Freedesktop completion chime, mirroring the user's Codex hook default. Played
// best-effort: skipped when `paplay` or the file is unavailable.
const LINUX_SOUND_PATH = "/usr/share/sounds/freedesktop/stereo/dialog-information.oga";

// macOS system sound name passed to `display notification ... sound name`.
const MACOS_SOUND_NAME = "Glass";

/// Provider logo to show on the notification. The bytes are embedded in the
/// binary, so we materialize them to a cache file on disk (notifiers want a
/// filesystem path, not raw bytes). `key` is the stable cache filename stem.
pub const Icon = struct {
    key: []const u8,
    png_bytes: []const u8,
};

/// Fires a desktop notification announcing that an agent finished. `title`,
/// `body`, and `icon` are borrowed for the duration of the call only.
pub fn notifyAgentDone(allocator: std.mem.Allocator, title: []const u8, body: []const u8, icon: ?Icon) void {
    // Resolve the provider logo to a path once; null means "no icon".
    const icon_path: ?[]u8 = if (icon) |ic| materializeIcon(allocator, ic) else null;
    defer if (icon_path) |p| allocator.free(p);

    switch (builtin.os.tag) {
        .macos => notifyMacos(allocator, title, body, icon_path),
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => notifyLinux(allocator, title, body, icon_path),
        else => {},
    }
}

// Linux/BSD path: `notify-send` for the toast plus an optional `paplay` chime.
fn notifyLinux(allocator: std.mem.Allocator, title: []const u8, body: []const u8, icon_path: ?[]const u8) void {
    if (!process_env.commandExists("notify-send")) return;

    // `-a Verde` sets the application name; `-i` sets the provider logo.
    if (icon_path) |path| {
        spawnDetached(allocator, &.{ "notify-send", "-a", "Verde", "-u", "normal", "-i", path, title, body });
    } else {
        spawnDetached(allocator, &.{ "notify-send", "-a", "Verde", "-u", "normal", title, body });
    }

    if (process_env.commandExists("paplay")) {
        spawnDetached(allocator, &.{ "paplay", LINUX_SOUND_PATH });
    }
}

// macOS path: prefer `terminal-notifier` so the provider logo can be shown via
// `-appIcon`; fall back to AppleScript `display notification` (no custom icon).
fn notifyMacos(allocator: std.mem.Allocator, title: []const u8, body: []const u8, icon_path: ?[]const u8) void {
    if (process_env.commandExists("terminal-notifier")) {
        if (icon_path) |path| {
            spawnDetached(allocator, &.{ "terminal-notifier", "-title", title, "-message", body, "-appIcon", path, "-sound", "default" });
        } else {
            spawnDetached(allocator, &.{ "terminal-notifier", "-title", title, "-message", body, "-sound", "default" });
        }
        return;
    }

    const esc_title = appleScriptEscape(allocator, title) catch return;
    defer allocator.free(esc_title);
    const esc_body = appleScriptEscape(allocator, body) catch return;
    defer allocator.free(esc_body);

    const script = std.fmt.allocPrint(
        allocator,
        "display notification \"{s}\" with title \"{s}\" sound name \"{s}\"",
        .{ esc_body, esc_title, MACOS_SOUND_NAME },
    ) catch return;
    defer allocator.free(script);

    spawnDetached(allocator, &.{ "osascript", "-e", script });
}

// Writes the embedded provider logo to a per-user cache file and returns its
// path (caller owns). Best-effort: returns null on any failure so the
// notification still fires without an icon.
fn materializeIcon(allocator: std.mem.Allocator, icon: Icon) ?[]u8 {
    const dir = iconCacheDir(allocator) orelse return null;
    defer allocator.free(dir);

    const path = std.fmt.allocPrint(allocator, "{s}/{s}.png", .{ dir, icon.key }) catch return null;
    errdefer allocator.free(path);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, dir) catch return null;

    // Skip rewriting when an up-to-date copy (same byte length) already exists,
    // so repeated notifications don't churn the disk.
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |existing| {
        var f = existing;
        const stat = f.stat(io) catch null;
        f.close(io);
        if (stat) |s| if (s.size == icon.png_bytes.len) return path;
    } else |_| {}

    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    writer.interface.writeAll(icon.png_bytes) catch return null;
    writer.interface.flush() catch return null;

    return path;
}

// Resolves the icon cache directory (`$XDG_CACHE_HOME/verde/icons` or
// `$HOME/.cache/verde/icons`). Caller owns the returned slice.
fn iconCacheDir(allocator: std.mem.Allocator) ?[]u8 {
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(xdg, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) {
            return std.fs.path.join(allocator, &.{ trimmed, "verde", "icons" }) catch null;
        }
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".cache", "verde", "icons" }) catch null;
}

// Escapes backslashes and double quotes so a string is safe inside an
// AppleScript double-quoted literal.
fn appleScriptEscape(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |c| {
        if (c == '\\' or c == '"') try out.append(allocator, '\\');
        try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// Spawns argv detached, resolving argv[0] against the augmented PATH (GUI
// launches often inherit a minimal PATH, and Zig resolves argv[0] only against
// the parent environment). All failures are logged-and-ignored.
fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;

    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return;
    defer env_map.deinit();

    const resolved = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, argv[0]) catch null;
    defer if (resolved) |p| allocator.free(p);

    var argv_storage: std.ArrayList([]const u8) = .empty;
    defer argv_storage.deinit(allocator);
    argv_storage.append(allocator, resolved orelse argv[0]) catch return;
    argv_storage.appendSlice(allocator, argv[1..]) catch return;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    _ = std.process.spawn(threaded.io(), .{
        .argv = argv_storage.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
    }) catch |err| {
        log.debug("notification spawn failed: {s}", .{@errorName(err)});
    };
}
