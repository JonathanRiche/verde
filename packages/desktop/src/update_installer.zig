//! Launches the documented platform installer without blocking the caller.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");
const process_env = @import("process_env.zig");

pub const Launch = enum {
    started,
    started_and_exit_required,
};

/// Starts the official Verde installer. Windows waits for the caller to exit
/// before replacing its locked executable, then launches the updated app.
pub fn launch(allocator: std.mem.Allocator) !Launch {
    return switch (builtin.os.tag) {
        .linux, .macos => {
            try spawnDetached(allocator, &.{
                "sh",
                "-c",
                "curl -fsSL https://verdeai.dev/install.sh | sh",
            });
            return .started;
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
