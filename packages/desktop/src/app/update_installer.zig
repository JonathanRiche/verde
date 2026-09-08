//! Shared update execution and package-manager detection for Settings and the CLI.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");

pub const Launch = enum {
    started_and_exit_required,
};

/// Windows replaces in-use executables after the caller exits.
/// Unix callers use run() and report the installer's actual result.
pub fn launch(allocator: std.mem.Allocator) !Launch {
    if (builtin.os.tag != .windows) return error.UnsupportedOperatingSystem;
    const command = try std.fmt.allocPrint(
        allocator,
        "$env:VERDE_INSTALL_NO_LAUNCH='0'; Wait-Process -Id {d} -ErrorAction SilentlyContinue; irm https://verdeai.dev/install.ps1 | iex",
        .{platform_runtime.processId()},
    );
    defer allocator.free(command);
    try spawnDetached(allocator, &.{
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command,
    });
    return .started_and_exit_required;
}

/// Runs the public installer in the foreground and preserves its exit status.
/// JSON callers keep stdout exclusively for the final structured result.
pub fn run(allocator: std.mem.Allocator, json: bool) !u8 {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedOperatingSystem;
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    const shell = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "sh");
    defer allocator.free(shell);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const executable = try std.process.executablePathAlloc(threaded.io(), allocator);
    defer allocator.free(executable);
    var child = try std.process.spawn(threaded.io(), .{
        .argv = &.{ shell, "-c", TERMINAL_INSTALL_SCRIPT, "verde-update", executable },
        .environ_map = &env_map,
        .stdout = if (json) .{ .file = .stderr() } else .inherit,
    });
    return switch (try child.wait(threaded.io())) {
        .exited => |code| code,
        else => error.InstallerTerminated,
    };
}

/// Settings invokes the sibling public CLI so both entry points share the updater.
pub fn launcherPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const directory = try std.process.executableDirPathAlloc(threaded.io(), allocator);
    defer allocator.free(directory);
    return std.fs.path.join(allocator, &.{ directory, if (builtin.os.tag == .windows) "verde.exe" else "verde" });
}

/// Runs the same public installer as a manual install, with visible terminal output.
/// Download separately so curl failures cannot be mistaken for a successful install.
pub const TERMINAL_INSTALL_SCRIPT =
    \\set -eu
    \\case "$(uname -s)" in
    \\  Darwin)
    \\    case "$1" in
    \\      */Verde.app/Contents/MacOS/*) export VERDE_MACOS_APP_DIR="$(dirname "$(dirname "$(dirname "$(dirname "$1")")")")" ;;
    \\    esac
    \\    ;;
    \\  Linux) export VERDE_INSTALL_PREFIX="$(dirname "$(dirname "$1")")" ;;
    \\esac
    \\installer=$(mktemp)
    \\trap 'rm -f "$installer"' EXIT HUP INT TERM
    \\curl -fSL --retry 3 https://verdeai.dev/install.sh -o "$installer"
    \\sh "$installer"
    \\printf '\nUpdate complete. Restart Verde to use the installed version.\n'
;

/// A package-owned executable must be updated through its package manager.
/// Foreign (AUR) packages need an AUR helper, including when none is installed yet.
pub fn packageUpdateCommand(allocator: std.mem.Allocator) !?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    const pacman = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "pacman") catch return null;
    defer allocator.free(pacman);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const path = try std.process.executablePathAlloc(threaded.io(), allocator);
    defer allocator.free(path);
    const owner = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ pacman, "-Qoq", path },
        .environ_map = &env_map,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(owner.stdout);
    defer allocator.free(owner.stderr);
    switch (owner.term) {
        .exited => |code| if (code != 0) return null,
        else => return error.PackageOwnershipCheckFailed,
    }
    const package = std.mem.trim(u8, owner.stdout, &std.ascii.whitespace);
    if (package.len == 0) return error.PackageOwnershipCheckFailed;
    if (resolveAndFree(allocator, &env_map, "yay")) return "yay -Syu";
    if (resolveAndFree(allocator, &env_map, "paru")) return "paru -Syu";
    const foreign = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ pacman, "-Qm", package },
        .environ_map = &env_map,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(foreign.stdout);
    defer allocator.free(foreign.stderr);
    return switch (foreign.term) {
        .exited => |code| if (code == 0) "yay -Syu" else "sudo pacman -Syu",
        else => error.PackageOwnershipCheckFailed,
    };
}

fn resolveAndFree(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    executable: []const u8,
) bool {
    const path = process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, executable) catch return false;
    allocator.free(path);
    return true;
}

fn spawnDetached(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, argv[0]);
    defer allocator.free(executable);
    const resolved_argv = try allocator.alloc([]const u8, argv.len);
    defer allocator.free(resolved_argv);
    @memcpy(resolved_argv, argv);
    resolved_argv[0] = executable;

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var child = try std.process.spawn(threaded.io(), .{
        .argv = resolved_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .environ_map = &env_map,
        .create_no_window = builtin.os.tag == .windows,
    });
    if (builtin.os.tag == .windows) {
        std.os.windows.CloseHandle(child.thread_handle);
        if (child.id) |process| std.os.windows.CloseHandle(process);
        child.id = null;
    }
}
