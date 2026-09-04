const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.option([]const u8, "target", "Target triple forwarded to packages/desktop");
    const cpu = b.option([]const u8, "cpu", "CPU model forwarded to standalone daemon and server builds");
    const version = b.option([]const u8, "version", "Version embedded in the desktop binaries") orelse
        b.graph.environ_map.get("VERDE_VERSION");
    const optimize = b.standardOptimizeOption(.{});
    const ui_debug = b.option(bool, "ui-debug", "Show the desktop UI debug window");
    const palette_renderer = b.option(PaletteRendererBackend, "palette-renderer", "Palette frame renderer backend: sdl_gpu");
    const browser_backend = b.option(BrowserBackendKind, "browser-backend", "Browser backend: native_webview or stub");
    const terminal_backend = b.option(bool, "terminal_backend", "Enable the native terminal backend");
    const local_ipc = b.option(bool, "local_ipc", "Enable the local live-control IPC backend");
    const windows_integrations = b.option(bool, "windows_integrations", "Enable native Windows integrations");
    const build_fff = b.option(bool, "build-fff", "Build the vendored fff-c library with Cargo");
    const fff_cargo_target = b.option([]const u8, "fff-cargo-target", "Rust target triple used to build fff-c");
    const fff_lib_dir = b.option([]const u8, "fff-lib-dir", "Directory containing the fff-c link library");
    const fff_import_lib = b.option([]const u8, "fff-import-lib", "Exact fff-c import library for Windows builds");
    const fff_runtime_lib = b.option([]const u8, "fff-runtime-lib", "Path to the fff-c runtime library to install");
    const sdl3_include_dir = b.option([]const u8, "sdl3-include-dir", "Directory containing SDL3 headers");
    const sdl3_lib_dir = b.option([]const u8, "sdl3-lib-dir", "Directory containing the SDL3 link library");
    const sdl3_runtime_lib = b.option([]const u8, "sdl3-runtime-lib", "Path to the SDL3 runtime library to install beside the desktop executable");
    const sdl3_ttf_include_dir = b.option([]const u8, "sdl3-ttf-include-dir", "Directory containing SDL3_ttf headers");
    const sdl3_ttf_lib_dir = b.option([]const u8, "sdl3-ttf-lib-dir", "Directory containing the SDL3_ttf link library");
    const sdl3_ttf_runtime_lib = b.option([]const u8, "sdl3-ttf-runtime-lib", "Path to the SDL3_ttf runtime library to install beside the desktop executable");
    const webview2_include_dir = b.option([]const u8, "webview2-include-dir", "Directory containing WebView2.h");
    const webview2_loader_lib = b.option([]const u8, "webview2-loader-lib", "Exact WebView2 loader import library");
    const webview2_loader_dll = b.option([]const u8, "webview2-loader-dll", "Path to WebView2Loader.dll to install beside the desktop executable");

    const build_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = null,
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    b.default_step.dependOn(&build_cmd.step);

    const dev_build_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = "dev-build",
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const dev_build_step = b.step("dev-build", "Build only the private desktop GUI executable");
    dev_build_step.dependOn(&dev_build_cmd.step);

    const daemon_cmd = addDaemonCommand(b, optimize, "daemon", target, cpu, version);
    const daemon_step = b.step("daemon", "Build and install the GUI-free Verde daemon");
    daemon_step.dependOn(&daemon_cmd.step);

    const daemon_test_cmd = addDaemonCommand(b, optimize, "daemon-test", target, cpu, version);
    const daemon_test_step = b.step("daemon-test", "Run GUI-free Verde daemon tests");
    daemon_test_step.dependOn(&daemon_test_cmd.step);

    const server_cmd = addServerCommand(b, optimize, "server", target, cpu, version);
    const server_step = b.step("server", "Build and install the account-free Verde server operator");
    server_step.dependOn(&server_cmd.step);

    const server_test_cmd = addServerCommand(b, optimize, "test", target, cpu, version);
    const server_test_step = b.step("server-test", "Run verde-server operator tests");
    server_test_step.dependOn(&server_test_cmd.step);

    const run_cmd = addDesktopCommand(b, optimize, .{
        .subcommand = "run",
        .forward_runtime_args = true,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const run_step = b.step("run", "Run the desktop app from the repo root");
    run_step.dependOn(&run_cmd.step);

    // Desktop Debug builds are not currently a valid smoke-test target on Linux
    // with Zig 0.16; use the same safe mode as the supported installable build.
    const test_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    const test_cmd = addDesktopCommand(b, test_optimize, .{
        .subcommand = "test",
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const test_step = b.step("test", "Run desktop tests from the repo root");
    test_step.dependOn(&test_cmd.step);

    const test_compile_cmd = addDesktopCommand(b, test_optimize, .{
        .subcommand = "test-compile",
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const test_compile_step = b.step("test-compile", "Compile desktop tests without running them");
    test_compile_step.dependOn(&test_compile_cmd.step);

    // Focused hermetic gate for packages/headless (std only; no desktop GUI deps).
    // Runs the standalone package build rather than the desktop graph so the
    // step stays free of SDL/Palette/Ghostty even when those deps are broken.
    var headless_argv: std.ArrayList([]const u8) = .empty;
    defer headless_argv.deinit(b.allocator);
    headless_argv.appendSlice(b.allocator, &.{ "zig", "build", "headless-test" }) catch @panic("OOM");
    if (test_optimize != .Debug) {
        headless_argv.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(test_optimize)})) catch @panic("OOM");
    }
    if (target) |value| {
        headless_argv.append(b.allocator, b.fmt("-Dtarget={s}", .{value})) catch @panic("OOM");
    }
    const headless_test_cmd = b.addSystemCommand(headless_argv.items);
    headless_test_cmd.setCwd(b.path("packages/headless"));
    const headless_test_step = b.step("headless-test", "Run headless package unit tests from the repo root");
    headless_test_step.dependOn(&headless_test_cmd.step);

    const runtime_test_cmd = addDesktopCommand(b, test_optimize, .{
        .subcommand = "runtime-test",
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const runtime_test_step = b.step("runtime-test", "Run remote-runtime infrastructure tests from the repo root");
    runtime_test_step.dependOn(&runtime_test_cmd.step);

    // Optional web client gateway. Not on the default desktop install path.
    const web_app_cmd = b.addSystemCommand(&.{ "zig", "build" });
    web_app_cmd.setCwd(b.path("packages/web_app"));
    const web_app_step = b.step("web-app", "Build the Verde web gateway (packages/web_app)");
    web_app_step.dependOn(&web_app_cmd.step);

    // Hermetic headless client ↔ forked session-daemon integration (desktop graph).
    const headless_daemon_it_cmd = addDesktopCommand(b, test_optimize, .{
        .subcommand = "headless-daemon-it",
        .forward_runtime_args = false,
        .target = target,
        .version = version,
        .ui_debug = ui_debug,
        .palette_renderer = palette_renderer,
        .browser_backend = browser_backend,
        .terminal_backend = terminal_backend,
        .local_ipc = local_ipc,
        .windows_integrations = windows_integrations,
        .build_fff = build_fff,
        .fff_cargo_target = fff_cargo_target,
        .fff_lib_dir = fff_lib_dir,
        .fff_import_lib = fff_import_lib,
        .fff_runtime_lib = fff_runtime_lib,
        .sdl3_include_dir = sdl3_include_dir,
        .sdl3_lib_dir = sdl3_lib_dir,
        .sdl3_runtime_lib = sdl3_runtime_lib,
        .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
        .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        .sdl3_ttf_runtime_lib = sdl3_ttf_runtime_lib,
        .webview2_include_dir = webview2_include_dir,
        .webview2_loader_lib = webview2_loader_lib,
        .webview2_loader_dll = webview2_loader_dll,
    });
    const headless_daemon_it_step = b.step("headless-daemon-it", "Hermetic headless client/session-daemon integration test");
    headless_daemon_it_step.dependOn(&headless_daemon_it_cmd.step);
}

const DesktopCommandOptions = struct {
    subcommand: ?[]const u8,
    forward_runtime_args: bool,
    target: ?[]const u8 = null,
    version: ?[]const u8 = null,
    ui_debug: ?bool = null,
    palette_renderer: ?PaletteRendererBackend = null,
    browser_backend: ?BrowserBackendKind = null,
    terminal_backend: ?bool = null,
    local_ipc: ?bool = null,
    windows_integrations: ?bool = null,
    build_fff: ?bool = null,
    fff_cargo_target: ?[]const u8 = null,
    fff_lib_dir: ?[]const u8 = null,
    fff_import_lib: ?[]const u8 = null,
    fff_runtime_lib: ?[]const u8 = null,
    sdl3_include_dir: ?[]const u8 = null,
    sdl3_lib_dir: ?[]const u8 = null,
    sdl3_runtime_lib: ?[]const u8 = null,
    sdl3_ttf_include_dir: ?[]const u8 = null,
    sdl3_ttf_lib_dir: ?[]const u8 = null,
    sdl3_ttf_runtime_lib: ?[]const u8 = null,
    webview2_include_dir: ?[]const u8 = null,
    webview2_loader_lib: ?[]const u8 = null,
    webview2_loader_dll: ?[]const u8 = null,
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
    appendStringOption(b, &argv, "version", options.version);
    if (options.ui_debug) |value| {
        argv.append(b.allocator, b.fmt("-Dui-debug={}", .{value})) catch @panic("OOM");
    }
    if (options.palette_renderer) |value| {
        argv.append(b.allocator, b.fmt("-Dpalette-renderer={s}", .{@tagName(value)})) catch @panic("OOM");
    }
    if (options.browser_backend) |value| {
        argv.append(b.allocator, b.fmt("-Dbrowser-backend={s}", .{@tagName(value)})) catch @panic("OOM");
    }
    appendBoolOption(b, &argv, "terminal_backend", options.terminal_backend);
    appendBoolOption(b, &argv, "local_ipc", options.local_ipc);
    appendBoolOption(b, &argv, "windows_integrations", options.windows_integrations);
    if (options.build_fff) |value| {
        argv.append(b.allocator, b.fmt("-Dbuild-fff={}", .{value})) catch @panic("OOM");
    }
    appendStringOption(b, &argv, "fff-cargo-target", options.fff_cargo_target);
    appendStringOption(b, &argv, "fff-lib-dir", options.fff_lib_dir);
    appendStringOption(b, &argv, "fff-import-lib", options.fff_import_lib);
    appendStringOption(b, &argv, "fff-runtime-lib", options.fff_runtime_lib);
    appendStringOption(b, &argv, "sdl3-include-dir", options.sdl3_include_dir);
    appendStringOption(b, &argv, "sdl3-lib-dir", options.sdl3_lib_dir);
    if (options.sdl3_runtime_lib) |value| {
        argv.append(b.allocator, b.fmt("-Dsdl3-runtime-lib={s}", .{value})) catch @panic("OOM");
    }
    appendStringOption(b, &argv, "sdl3-ttf-include-dir", options.sdl3_ttf_include_dir);
    appendStringOption(b, &argv, "sdl3-ttf-lib-dir", options.sdl3_ttf_lib_dir);
    appendStringOption(b, &argv, "sdl3-ttf-runtime-lib", options.sdl3_ttf_runtime_lib);
    appendStringOption(b, &argv, "webview2-include-dir", options.webview2_include_dir);
    appendStringOption(b, &argv, "webview2-loader-lib", options.webview2_loader_lib);
    appendStringOption(b, &argv, "webview2-loader-dll", options.webview2_loader_dll);
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

fn addDaemonCommand(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    target: ?[]const u8,
    cpu: ?[]const u8,
    version: ?[]const u8,
) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{ "zig", "build", step_name }) catch @panic("OOM");
    if (optimize != .Debug) {
        argv.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(optimize)})) catch @panic("OOM");
    }
    if (target) |value| {
        argv.append(b.allocator, b.fmt("-Dtarget={s}", .{value})) catch @panic("OOM");
    }
    appendStringOption(b, &argv, "cpu", cpu);
    appendStringOption(b, &argv, "version", version);
    appendInstallArgs(b, &argv);

    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path("packages/daemon"));
    return cmd;
}

fn addServerCommand(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    step_name: []const u8,
    target: ?[]const u8,
    cpu: ?[]const u8,
    version: ?[]const u8,
) *std.Build.Step.Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{ "zig", "build", step_name }) catch @panic("OOM");
    if (optimize != .Debug) {
        argv.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(optimize)})) catch @panic("OOM");
    }
    if (target) |value| {
        argv.append(b.allocator, b.fmt("-Dtarget={s}", .{value})) catch @panic("OOM");
    }
    appendStringOption(b, &argv, "cpu", cpu);
    appendStringOption(b, &argv, "version", version);
    appendInstallArgs(b, &argv);

    const cmd = b.addSystemCommand(argv.items);
    cmd.setCwd(b.path("packages/server"));
    return cmd;
}

fn appendStringOption(
    b: *std.Build,
    argv: *std.ArrayList([]const u8),
    name: []const u8,
    value: ?[]const u8,
) void {
    if (value) |resolved| {
        argv.append(b.allocator, b.fmt("-D{s}={s}", .{ name, resolved })) catch @panic("OOM");
    }
}

fn appendBoolOption(
    b: *std.Build,
    argv: *std.ArrayList([]const u8),
    name: []const u8,
    value: ?bool,
) void {
    if (value) |resolved| {
        argv.append(b.allocator, b.fmt("-D{s}={}", .{ name, resolved })) catch @panic("OOM");
    }
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

    argv.appendSlice(b.allocator, &.{ "-p", b.install_prefix }) catch @panic("OOM");
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

const BrowserBackendKind = enum {
    native_webview,
    stub,
};
