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
    appendInstallArgs(b, &argv);

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

fn appendInstallArgs(b: *std.Build, argv: *std.ArrayList([]const u8)) void {
    const default_install_prefix = if (b.dest_dir != null)
        "/usr"
    else
        b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    defer if (b.dest_dir == null) b.allocator.free(default_install_prefix);

    const default_install_path = if (b.dest_dir) |dest_dir|
        b.pathJoin(&.{ dest_dir, default_install_prefix })
    else
        default_install_prefix;
    defer if (b.dest_dir != null) b.allocator.free(default_install_path);

    const default_lib_dir = b.pathJoin(&.{ default_install_path, "lib" });
    defer b.allocator.free(default_lib_dir);

    const default_exe_dir = b.pathJoin(&.{ default_install_path, "bin" });
    defer b.allocator.free(default_exe_dir);

    const default_include_dir = b.pathJoin(&.{ default_install_path, "include" });
    defer b.allocator.free(default_include_dir);

    if (!std.mem.eql(u8, b.install_prefix, default_install_prefix)) {
        argv.appendSlice(b.allocator, &.{ "-p", b.install_prefix }) catch @panic("OOM");
    }
    if (!std.mem.eql(u8, b.lib_dir, default_lib_dir)) {
        argv.appendSlice(b.allocator, &.{ "--prefix-lib-dir", b.lib_dir }) catch @panic("OOM");
    }
    if (!std.mem.eql(u8, b.exe_dir, default_exe_dir)) {
        argv.appendSlice(b.allocator, &.{ "--prefix-exe-dir", b.exe_dir }) catch @panic("OOM");
    }
    if (!std.mem.eql(u8, b.h_dir, default_include_dir)) {
        argv.appendSlice(b.allocator, &.{ "--prefix-include-dir", b.h_dir }) catch @panic("OOM");
    }
}
