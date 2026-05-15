const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.option([]const u8, "target", "Forwarded to the desktop build (e.g. x86_64-windows-msvc)");
    const ui_debug = b.option(bool, "ui-debug", "Show the desktop UI debug window");
    const palette_renderer = b.option(PaletteRendererBackend, "palette-renderer", "Palette frame renderer backend: sdl_gpu");
    const cef_sdk_path = b.option([]const u8, "cef-sdk-path", "Path to a CEF binary distribution for the embedded browser pane");
    const sdl3_runtime_lib = b.option([]const u8, "sdl3-runtime-lib", "Path to the SDL3 runtime library to install beside the desktop executable");
    const cef_stub_preview = b.option(bool, "cef-stub-preview", "Use the in-app CEF pane scaffold without a real CEF SDK");

    const build_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = null,
        .forward_runtime_args = false,
        .target = target,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .cef_sdk_path = cef_sdk_path,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .cef_stub_preview = cef_stub_preview,
    });
    b.default_step.dependOn(&build_cmd.step);

    const run_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = "run",
        .forward_runtime_args = true,
        .target = target,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .cef_sdk_path = cef_sdk_path,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .cef_stub_preview = cef_stub_preview,
    });
    const run_step = b.step("run", "Run the desktop app from the repo root");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = "test",
        .forward_runtime_args = false,
        .target = target,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .cef_sdk_path = cef_sdk_path,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .cef_stub_preview = cef_stub_preview,
    });
    const test_step = b.step("test", "Run desktop tests from the repo root");
    test_step.dependOn(&test_cmd.step);
}

const DesktopCommandOptions = struct {
    subcommand: ?[]const u8,
    forward_runtime_args: bool,
    target: ?[]const u8 = null,
    ui_debug: ?bool = null,
    palette_renderer: ?PaletteRendererBackend = null,
    cef_sdk_path: ?[]const u8 = null,
    sdl3_runtime_lib: ?[]const u8 = null,
    cef_stub_preview: ?bool = null,
};

fn addDesktopCommand(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    options: DesktopCommandOptions,
) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{ "zig", "build" }) catch @panic("OOM");
    if (options.subcommand) |step_name| {
        argv.append(b.allocator, step_name) catch @panic("OOM");
    }
    if (optimize != .Debug) {
        argv.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(optimize)})) catch @panic("OOM");
    }
    if (options.target) |value| {
        argv.append(b.allocator, b.fmt("-Dtarget={s}", .{value})) catch @panic("OOM");
    }
    if (options.ui_debug) |value| {
        argv.append(b.allocator, b.fmt("-Dui-debug={}", .{value})) catch @panic("OOM");
    }
    if (options.palette_renderer) |value| {
        argv.append(b.allocator, b.fmt("-Dpalette-renderer={s}", .{@tagName(value)})) catch @panic("OOM");
    }
    if (options.cef_sdk_path) |value| {
        argv.append(b.allocator, b.fmt("-Dcef-sdk-path={s}", .{value})) catch @panic("OOM");
    }
    if (options.sdl3_runtime_lib) |value| {
        argv.append(b.allocator, b.fmt("-Dsdl3-runtime-lib={s}", .{value})) catch @panic("OOM");
    }
    if (options.cef_stub_preview) |value| {
        argv.append(b.allocator, b.fmt("-Dcef-stub-preview={}", .{value})) catch @panic("OOM");
    }
    appendInstallArgs(b, &argv);

    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path("packages/desktop"));

    if (options.forward_runtime_args) {
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

const PaletteRendererBackend = enum {
    sdl_gpu,
};
