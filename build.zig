const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const build_cmd = addDesktopCommand(b, optimize, null, false);
    b.default_step.dependOn(&build_cmd.step);

    const run_cmd = addDesktopCommand(b, optimize, "run", true);
    const run_step = b.step("run", "Run the desktop app from the repo root");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = addDesktopCommand(b, optimize, "test", false);
    const test_step = b.step("test", "Run desktop tests from the repo root");
    test_step.dependOn(&test_cmd.step);
}

fn addDesktopCommand(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    subcommand: ?[]const u8,
    forward_runtime_args: bool,
) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{ "zig", "build" }) catch @panic("OOM");
    if (subcommand) |step_name| {
        argv.append(b.allocator, step_name) catch @panic("OOM");
    }
    if (optimize != .Debug) {
        argv.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(optimize)})) catch @panic("OOM");
    }

    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path("packages/desktop"));

    if (forward_runtime_args) {
        if (b.args) |args| {
            cmd.addArg("--");
            cmd.addArgs(args);
        }
    }

    return cmd;
}
