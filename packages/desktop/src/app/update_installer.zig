//! Launches the documented platform installer without blocking the caller.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");
const process_env = @import("../platform/env.zig");

// Waits for the exiting app (format arg: pid), bounded so a stalled quit
// cannot leave the detached installer looping forever.
const WAIT_FOR_PID_TEMPLATE =
    "i=0; while kill -0 {d} 2>/dev/null && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done; ";

pub const Launch = enum {
    started,
    started_and_exit_required,
    aur_yay,
    aur_paru,
    aur_helper_missing,
};

pub fn aurCommand(launch_result: Launch) ?[]const []const u8 {
    return switch (launch_result) {
        .aur_yay => &.{ "yay", "-S", "verde-bin" },
        .aur_paru => &.{ "paru", "-S", "verde-bin" },
        else => null,
    };
}

/// Starts the official Verde installer. Every scripted path (Windows, macOS,
/// non-AUR Linux) waits for the caller to exit before replacing the in-use
/// binary/bundle, then relaunches the updated app, so they report
/// `.started_and_exit_required`. AUR installs run interactively in a
/// terminal pane instead, so the app must stay alive for those.
pub fn launch(allocator: std.mem.Allocator) !Launch {
    return switch (builtin.os.tag) {
        .linux => {
            if (try detectLinuxAurLaunch(allocator)) |launch_result| return launch_result;
            // Quit before installing so the relaunch actually runs the new
            // binary; install.sh puts it at $VERDE_INSTALL_PREFIX/bin/verde
            // (default ~/.local). The helper inherits our env, so Wayland
            // session variables survive into the relaunched app.
            const command = try std.fmt.allocPrint(
                allocator,
                WAIT_FOR_PID_TEMPLATE ++
                    "curl -fsSL https://verdeai.dev/install.sh | sh || exit 1; " ++
                    "exec \"${{VERDE_INSTALL_PREFIX:-$HOME/.local}}/bin/verde\"",
                .{platform_runtime.processId()},
            );
            defer allocator.free(command);
            try spawnDetached(allocator, &.{ "sh", "-c", command });
            return .started_and_exit_required;
        },
        .macos => {
            // install.sh replaces Verde.app in place, so the running bundle must
            // quit first; the helper waits for this pid (bounded, in case quit
            // stalls), installs, then relaunches from the same directory-preference
            // order install.sh uses to pick MACOS_APP_DIR.
            const command = try std.fmt.allocPrint(
                allocator,
                WAIT_FOR_PID_TEMPLATE ++
                    "curl -fsSL https://verdeai.dev/install.sh | sh || exit 1; " ++
                    "if [ -d \"$HOME/Applications/Verde.app\" ]; then exec open \"$HOME/Applications/Verde.app\"; fi; " ++
                    "if [ -d /Applications/Verde.app ]; then exec open /Applications/Verde.app; fi; " ++
                    "exec open -a Verde",
                .{platform_runtime.processId()},
            );
            defer allocator.free(command);
            try spawnDetached(allocator, &.{ "sh", "-c", command });
            return .started_and_exit_required;
        },
        .windows => {
            const command = try std.fmt.allocPrint(
                allocator,
                "$env:VERDE_INSTALL_NO_LAUNCH='0'; Wait-Process -Id {d} -ErrorAction SilentlyContinue; irm https://verdeai.dev/install.ps1 | iex",
                .{platform_runtime.processId()},
            );
            defer allocator.free(command);
            try spawnDetached(allocator, &.{
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                command,
            });
            return .started_and_exit_required;
        },
        else => error.UnsupportedOperatingSystem,
    };
}

fn detectLinuxAurLaunch(allocator: std.mem.Allocator) !?Launch {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    const pacman = process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, "pacman") catch return null;
    defer allocator.free(pacman);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const executable_path = try std.process.executablePathAlloc(threaded.io(), allocator);
    defer allocator.free(executable_path);
    const owner_result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ pacman, "-Qoq", executable_path },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
        .environ_map = &env_map,
    });
    defer allocator.free(owner_result.stdout);
    defer allocator.free(owner_result.stderr);
    switch (owner_result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    if (!isVerdeBinPackage(owner_result.stdout)) return null;

    if (resolveAndFree(allocator, &env_map, "yay")) return .aur_yay;
    if (resolveAndFree(allocator, &env_map, "paru")) return .aur_paru;
    return .aur_helper_missing;
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

fn isVerdeBinPackage(output: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, output, &std.ascii.whitespace), "verde-bin");
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

test "AUR ownership detection accepts only verde-bin" {
    try std.testing.expect(isVerdeBinPackage("verde-bin\n"));
    try std.testing.expect(!isVerdeBinPackage("verde\n"));
    try std.testing.expect(!isVerdeBinPackage("other-package\n"));
}

test "AUR launch results expose the package helper command" {
    try std.testing.expectEqualStrings("yay", aurCommand(.aur_yay).?[0]);
    try std.testing.expectEqualStrings("paru", aurCommand(.aur_paru).?[0]);
    try std.testing.expect(aurCommand(.started) == null);
}
