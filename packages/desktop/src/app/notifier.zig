//! Cross-platform agent-status desktop notifications.
//!
//! Fires a best-effort OS notification when an agent surface transitions to
//! `.done`, `.waiting`, or `.error`. The toast is native (`notify-send`,
//! `terminal-notifier`/`osascript`, WinRT) and the matching chime is the same
//! embedded WAV on every platform. OS toast sounds are silenced so the Verde
//! chime is the only audio.
//!
//! Everything here is best-effort and side-effect only: a missing
//! `notify-send`/`osascript`/`afplay`/`paplay`, an unresolved PATH, or a spawn
//! failure is swallowed so a finished agent turn can never disrupt the app.

const std = @import("std");
const builtin = @import("builtin");

const platform_paths = @import("platform_paths");
const process_env = @import("../platform/env.zig");

const log = std.log.scoped(.native_notifier);

// Status chimes are WAV so afplay, paplay/pw-play, and Windows MediaPlayer can
// all decode them without extra codecs. Materialized to cache because the
// players need a filesystem path.
// done: bright E5→B5 perfect fifth. waiting: lower F4→C5. error: D5+D♯5 cluster.
const AGENT_DONE_SOUND = @embedFile("../assets/sounds/agent-done.wav");
const AGENT_DONE_SOUND_NAME = "agent-done.wav";
const AGENT_WAITING_SOUND = @embedFile("../assets/sounds/agent-waiting.wav");
const AGENT_WAITING_SOUND_NAME = "agent-waiting.wav";
const AGENT_ERROR_SOUND = @embedFile("../assets/sounds/agent-error.wav");
const AGENT_ERROR_SOUND_NAME = "agent-error.wav";
const WINDOWS_SOUND_PATH_ENV = "VERDE_NOTIFICATION_SOUND";

/// Which status chime to play with the toast.
pub const Chime = enum { done, waiting, @"error" };

const SoundAsset = struct { name: []const u8, bytes: []const u8 };

fn soundForChime(chime: Chime) SoundAsset {
    return switch (chime) {
        .done => .{ .name = AGENT_DONE_SOUND_NAME, .bytes = AGENT_DONE_SOUND },
        .waiting => .{ .name = AGENT_WAITING_SOUND_NAME, .bytes = AGENT_WAITING_SOUND },
        .@"error" => .{ .name = AGENT_ERROR_SOUND_NAME, .bytes = AGENT_ERROR_SOUND },
    };
}

// WinRT toast is silent; the same PowerShell host then plays AGENT_DONE_SOUND
// so Windows does not emit Notification.Default on top of the Verde chime.
const WINDOWS_NOTIFICATION_SCRIPT =
    \\$ErrorActionPreference = 'Stop'
    \\try {
    \\  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    \\  [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    \\  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null
    \\  $title = [Environment]::GetEnvironmentVariable('VERDE_NOTIFICATION_TITLE')
    \\  $body = [Environment]::GetEnvironmentVariable('VERDE_NOTIFICATION_BODY')
    \\  $escapedTitle = [Security.SecurityElement]::Escape($title)
    \\  $escapedBody = [Security.SecurityElement]::Escape($body)
    \\  $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    \\  $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$escapedTitle</text><text>$escapedBody</text></binding></visual><audio silent='true'/></toast>")
    \\  $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    \\  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Verde.Desktop').Show($toast)
    \\} catch {}
    \\$Path = [Environment]::GetEnvironmentVariable('VERDE_NOTIFICATION_SOUND')
    \\if ([string]::IsNullOrWhiteSpace($Path)) { exit 0 }
    \\try {
    \\  Add-Type -AssemblyName PresentationCore
    \\  Add-Type -AssemblyName WindowsBase
    \\  $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
    \\  $script:player = [System.Windows.Media.MediaPlayer]::new()
    \\  $script:frame = [System.Windows.Threading.DispatcherFrame]::new()
    \\  $script:timer = [System.Windows.Threading.DispatcherTimer]::new()
    \\  $script:timer.Interval = [TimeSpan]::FromSeconds(5)
    \\  $script:player.add_MediaOpened({ $script:player.Play() })
    \\  $script:player.add_MediaEnded({ $script:frame.Continue = $false })
    \\  $script:player.add_MediaFailed({ $script:frame.Continue = $false })
    \\  $script:timer.add_Tick({ $script:frame.Continue = $false })
    \\  try {
    \\    $script:player.Open([Uri]::new($resolved))
    \\    $script:timer.Start()
    \\    [System.Windows.Threading.Dispatcher]::PushFrame($script:frame)
    \\  } finally {
    \\    $script:timer.Stop()
    \\    $script:player.Close()
    \\  }
    \\} catch {}
;

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
    notifyAgent(allocator, title, body, icon, .done);
}

/// Fires a desktop notification for an agent status edge. `title`, `body`, and
/// `icon` are borrowed for the duration of the call only.
pub fn notifyAgent(
    allocator: std.mem.Allocator,
    title: []const u8,
    body: []const u8,
    icon: ?Icon,
    chime: Chime,
) void {
    // Resolve the provider logo to a path once; null means "no icon".
    const icon_path: ?[]u8 = if (icon) |ic| materializeIcon(allocator, ic) else null;
    defer if (icon_path) |p| allocator.free(p);

    const asset = soundForChime(chime);
    const sound_path = materializeCachedBytes(allocator, "sounds", asset.name, asset.bytes);
    defer if (sound_path) |p| allocator.free(p);

    switch (builtin.os.tag) {
        .macos => {
            notifyMacos(allocator, title, body, icon_path);
            playFileChime(allocator, sound_path);
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            notifyLinux(allocator, title, body, icon_path, chime);
            playFileChime(allocator, sound_path);
        },
        .windows => notifyWindows(allocator, title, body, sound_path),
        else => {},
    }
}

// Windows path: invoke the in-box WinRT toast API through a hidden PowerShell
// host. Notification text travels through the child environment, never shell
// interpolation, so quotes and non-ASCII content remain data rather than code.
fn notifyWindows(allocator: std.mem.Allocator, title: []const u8, body: []const u8, sound_path: ?[]const u8) void {
    if (std.mem.indexOfScalar(u8, title, 0) != null or std.mem.indexOfScalar(u8, body, 0) != null) return;
    var env_map = process_env.buildAugmentedEnvMap(allocator) catch return;
    defer env_map.deinit();
    env_map.put("VERDE_NOTIFICATION_TITLE", title) catch return;
    env_map.put("VERDE_NOTIFICATION_BODY", body) catch return;
    if (sound_path) |path| {
        if (std.mem.indexOfScalar(u8, path, 0) == null) {
            env_map.put(WINDOWS_SOUND_PATH_ENV, path) catch {};
        }
    }

    const shell = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "pwsh") catch
        process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "powershell") catch return;
    defer allocator.free(shell);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var child = std.process.spawn(threaded.io(), .{
        .argv = &.{ shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", WINDOWS_NOTIFICATION_SCRIPT },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
        .create_no_window = true,
    }) catch |err| {
        log.debug("Windows notification spawn failed: {s}", .{@errorName(err)});
        return;
    };
    closeDetachedWindowsChild(&child);
}

// Linux/BSD path: `notify-send` for the toast. The Verde chime is played
// separately so we suppress the desktop's default notification sound.
fn notifyLinux(allocator: std.mem.Allocator, title: []const u8, body: []const u8, icon_path: ?[]const u8, chime: Chime) void {
    if (!process_env.commandExists("notify-send")) return;

    const urgency: []const u8 = if (chime == .@"error") "critical" else "normal";
    // `-a Verde` sets the application name; `-i` sets the provider logo.
    if (icon_path) |path| {
        spawnDetached(allocator, &.{ "notify-send", "-a", "Verde", "-u", urgency, "-h", "boolean:suppress-sound:true", "-i", path, title, body });
    } else {
        spawnDetached(allocator, &.{ "notify-send", "-a", "Verde", "-u", urgency, "-h", "boolean:suppress-sound:true", title, body });
    }
}

fn playFileChime(allocator: std.mem.Allocator, sound_path: ?[]const u8) void {
    const path = sound_path orelse return;
    switch (builtin.os.tag) {
        .macos => {
            if (process_env.commandExists("afplay")) {
                spawnDetached(allocator, &.{ "afplay", path });
            }
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            if (process_env.commandExists("paplay")) {
                spawnDetached(allocator, &.{ "paplay", path });
                return;
            }
            if (process_env.commandExists("pw-play")) {
                spawnDetached(allocator, &.{ "pw-play", path });
            }
        },
        else => {},
    }
}

// macOS path: prefer `terminal-notifier` so the provider logo can be shown via
// `-appIcon`; fall back to AppleScript `display notification` (no custom icon).
// `-sound none` / no `sound name` so afplay is the only chime.
fn notifyMacos(allocator: std.mem.Allocator, title: []const u8, body: []const u8, icon_path: ?[]const u8) void {
    if (process_env.commandExists("terminal-notifier")) {
        if (icon_path) |path| {
            spawnDetached(allocator, &.{ "terminal-notifier", "-title", title, "-message", body, "-appIcon", path, "-sound", "none" });
        } else {
            spawnDetached(allocator, &.{ "terminal-notifier", "-title", title, "-message", body, "-sound", "none" });
        }
        return;
    }

    const esc_title = appleScriptEscape(allocator, title) catch return;
    defer allocator.free(esc_title);
    const esc_body = appleScriptEscape(allocator, body) catch return;
    defer allocator.free(esc_body);

    const script = std.fmt.allocPrint(
        allocator,
        "display notification \"{s}\" with title \"{s}\"",
        .{ esc_body, esc_title },
    ) catch return;
    defer allocator.free(script);

    spawnDetached(allocator, &.{ "osascript", "-e", script });
}

// Writes the embedded provider logo to a per-user cache file and returns its
// path (caller owns). Best-effort: returns null on any failure so the
// notification still fires without an icon.
fn materializeIcon(allocator: std.mem.Allocator, icon: Icon) ?[]u8 {
    const filename = std.fmt.allocPrint(allocator, "{s}.png", .{icon.key}) catch return null;
    defer allocator.free(filename);
    return materializeCachedBytes(allocator, "icons", filename, icon.png_bytes);
}

// Writes embedded bytes to a per-user cache file and returns its path (caller
// owns). Best-effort: returns null on any failure so the notification still
// fires without the cached asset.
fn materializeCachedBytes(
    allocator: std.mem.Allocator,
    subdir: []const u8,
    filename: []const u8,
    bytes: []const u8,
) ?[]u8 {
    const dir = cacheSubdir(allocator, subdir) orelse return null;
    defer allocator.free(dir);

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename }) catch return null;
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
        if (stat) |s| if (s.size == bytes.len) return path;
    } else |_| {}

    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return null;
    defer file.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    writer.interface.writeAll(bytes) catch return null;
    writer.interface.flush() catch return null;

    return path;
}

// Resolves `$XDG_CACHE_HOME/verde/<subdir>` or `$HOME/.cache/verde/<subdir>`.
// Caller owns the returned slice.
fn cacheSubdir(allocator: std.mem.Allocator, subdir: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const base = platform_paths.localDataDir(allocator, "Verde", "Native") catch return null;
        defer allocator.free(base);
        return std.fs.path.join(allocator, &.{ base, subdir }) catch null;
    }
    if (std.c.getenv("XDG_CACHE_HOME")) |xdg| {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(xdg, 0), &std.ascii.whitespace);
        if (trimmed.len > 0) {
            return std.fs.path.join(allocator, &.{ trimmed, "verde", subdir }) catch null;
        }
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ std.mem.sliceTo(home, 0), ".cache", "verde", subdir }) catch null;
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
    var child = std.process.spawn(threaded.io(), .{
        .argv = argv_storage.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
        .create_no_window = builtin.os.tag == .windows,
    }) catch |err| {
        log.debug("notification spawn failed: {s}", .{@errorName(err)});
        return;
    };
    if (builtin.os.tag == .windows) closeDetachedWindowsChild(&child);
}

fn closeDetachedWindowsChild(child: *std.process.Child) void {
    if (builtin.os.tag != .windows) return;
    std.os.windows.CloseHandle(child.thread_handle);
    if (child.id) |process| std.os.windows.CloseHandle(process);
    child.id = null;
}

test "status chimes are embedded wav bitstreams" {
    const assets = [_][]const u8{ AGENT_DONE_SOUND, AGENT_WAITING_SOUND, AGENT_ERROR_SOUND };
    for (assets) |bytes| {
        try std.testing.expect(std.mem.startsWith(u8, bytes, "RIFF"));
        try std.testing.expect(std.mem.indexOf(u8, bytes[0..12], "WAVE") != null);
        try std.testing.expect(bytes.len > 1024);
    }
    try std.testing.expect(soundForChime(.done).bytes.ptr != soundForChime(.waiting).bytes.ptr);
    try std.testing.expect(soundForChime(.waiting).bytes.ptr != soundForChime(.@"error").bytes.ptr);
}

test "windows toast is silent and plays the Verde chime from the env path" {
    try std.testing.expect(std.mem.indexOf(u8, WINDOWS_NOTIFICATION_SCRIPT, "silent='true'") != null);
    try std.testing.expect(std.mem.indexOf(u8, WINDOWS_NOTIFICATION_SCRIPT, "Notification.Default") == null);
    try std.testing.expect(std.mem.indexOf(u8, WINDOWS_NOTIFICATION_SCRIPT, WINDOWS_SOUND_PATH_ENV) != null);
    try std.testing.expect(std.mem.indexOf(u8, WINDOWS_NOTIFICATION_SCRIPT, "MediaPlayer") != null);
}
