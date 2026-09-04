const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version embedded in the desktop binaries") orelse
        b.graph.environ_map.get("VERDE_VERSION") orelse
        "0.0.0";
    if (!isValidVersion(version)) {
        @panic("version must start with an ASCII letter or digit and contain only letters, digits, dot, underscore, plus, and dash");
    }
    const version_z: [:0]const u8 = b.allocator.dupeSentinel(u8, version, 0) catch @panic("OOM");
    const ui_debug = b.option(bool, "ui-debug", "Show the desktop UI debug window") orelse false;
    const palette_renderer = b.option(PaletteRendererBackend, "palette-renderer", "Palette frame renderer backend: sdl_gpu") orelse .sdl_gpu;
    const browser_backend = b.option(BrowserBackendKind, "browser-backend", "Browser backend: native_webview or stub") orelse .native_webview;
    const terminal_backend = b.option(bool, "terminal_backend", "Enable the native terminal backend") orelse true;
    const local_ipc = b.option(bool, "local_ipc", "Enable the local live-control IPC backend") orelse true;
    const windows_integrations = b.option(bool, "windows_integrations", "Enable native Windows shell/clipboard/application integrations") orelse
        (target.result.os.tag == .windows);
    const build_fff_enabled = b.option(bool, "build-fff", "Build the vendored fff-c library with Cargo") orelse true;
    const fff_cargo_target = b.option([]const u8, "fff-cargo-target", "Rust target triple used to build fff-c") orelse
        b.graph.environ_map.get("VERDE_FFF_CARGO_TARGET") orelse
        windowsRustTarget(target.result);
    const fff_target_dir = if (fff_cargo_target) |cargo_target|
        b.pathJoin(&.{ "../../vendor/fff/target", cargo_target, "release" })
    else
        b.pathJoin(&.{ "../../vendor/fff/target", "release" });
    const fff_lib_dir = b.option([]const u8, "fff-lib-dir", "Directory containing the fff-c link library") orelse
        b.graph.environ_map.get("VERDE_FFF_LIB_DIR") orelse
        fff_target_dir;
    const fff_import_lib = b.option([]const u8, "fff-import-lib", "Exact fff-c import library for Windows builds") orelse
        b.graph.environ_map.get("VERDE_FFF_IMPORT_LIB") orelse
        defaultWindowsFffImportLibrary(b, target.result, fff_lib_dir);
    const fff_runtime_lib = b.option([]const u8, "fff-runtime-lib", "Path to the fff-c runtime library to install") orelse
        b.graph.environ_map.get("VERDE_FFF_RUNTIME_LIB") orelse
        b.pathJoin(&.{ fff_lib_dir, fffRuntimeName(target.result.os.tag) });
    const sdl3_include_dir = b.option([]const u8, "sdl3-include-dir", "Directory containing SDL3 headers") orelse
        b.graph.environ_map.get("VERDE_SDL3_INCLUDE_DIR");
    const sdl3_lib_dir = b.option([]const u8, "sdl3-lib-dir", "Directory containing the SDL3 link library") orelse
        b.graph.environ_map.get("VERDE_SDL3_LIB_DIR");
    const sdl3_runtime_lib = b.option([]const u8, "sdl3-runtime-lib", "Path to the SDL3 runtime library to install beside the executable") orelse
        b.graph.environ_map.get("VERDE_SDL3_RUNTIME_LIB") orelse
        defaultSystemSdl3Runtime(b, target.result.os.tag);
    const sdl3_ttf_include_dir = b.option([]const u8, "sdl3-ttf-include-dir", "Directory containing SDL3_ttf headers") orelse
        b.graph.environ_map.get("VERDE_SDL3_TTF_INCLUDE_DIR");
    const sdl3_ttf_lib_dir = b.option([]const u8, "sdl3-ttf-lib-dir", "Directory containing the SDL3_ttf link library") orelse
        b.graph.environ_map.get("VERDE_SDL3_TTF_LIB_DIR");
    const sdl3_ttf_runtime_lib = b.option([]const u8, "sdl3-ttf-runtime-lib", "Path to the SDL3_ttf runtime library to install beside the executable") orelse
        b.graph.environ_map.get("VERDE_SDL3_TTF_RUNTIME_LIB");
    const webview2_include_dir = b.option([]const u8, "webview2-include-dir", "Directory containing WebView2.h") orelse
        b.graph.environ_map.get("WEBVIEW2_INCLUDE_DIR");
    const webview2_loader_lib = b.option([]const u8, "webview2-loader-lib", "Exact WebView2 loader import library") orelse
        b.graph.environ_map.get("WEBVIEW2_LOADER_LIB");
    const webview2_loader_dll = b.option([]const u8, "webview2-loader-dll", "Path to WebView2Loader.dll to install beside the executable") orelse
        b.graph.environ_map.get("WEBVIEW2_LOADER_DLL");
    const fff_root = b.path("../../vendor/fff");

    if (target.result.os.tag == .windows and (!terminal_backend or !local_ipc or !windows_integrations)) {
        @panic("installable Windows builds require -Dterminal_backend=true -Dlocal_ipc=true -Dwindows_integrations=true");
    }

    const zig_dif = b.dependency("zig_dif", .{
        .target = target,
        .optimize = optimize,
    });
    const zig_markdown = b.dependency("zig_markdown", .{
        .target = target,
        .optimize = optimize,
    });
    const palette = b.dependency("palette", .{
        .target = target,
        .optimize = optimize,
    });
    const zsdl = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
        .@"use-prebuilt" = false,
    });
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
    });
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const palette_module = palette.module("palette");
    // GUI-free protocol core. Linked into the session daemon for core.* methods;
    // headless-test runs this package alone with no SDL/Palette/Ghostty deps.
    const headless_module = b.createModule(.{
        .root_source_file = b.path("../headless/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Browser contract tests use a narrower module root than the full app, so
    // portable platform helpers must be explicit imports instead of escaping it.
    const platform_runtime_module = b.createModule(.{
        .root_source_file = b.path("src/platform/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_windows_known_folders_module = b.createModule(.{
        .root_source_file = b.path("src/platform/windows/known_folders.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_paths_module = b.createModule(.{
        .root_source_file = b.path("src/platform/paths.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
        },
    });
    const loop_wakeup_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/loop_wakeup.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
        },
    });
    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "version", version_z);
    build_options.addOption(bool, "ui_debug", ui_debug);
    build_options.addOption(PaletteRendererBackend, "palette_renderer", palette_renderer);
    build_options.addOption(BrowserBackendKind, "browser_backend", browser_backend);
    build_options.addOption(bool, "terminal_backend", terminal_backend);
    build_options.addOption(bool, "local_ipc", local_ipc);
    build_options.addOption(bool, "windows_integrations", windows_integrations);
    const build_options_module = build_options.createModule();
    // The standalone daemon only needs build metadata along the daemon and
    // daemon-owned MCP paths. Unreached CLI declarations stay lazy.
    const daemon_build_options = b.addOptions();
    daemon_build_options.addOption([:0]const u8, "version", version_z);
    const daemon_build_options_module = daemon_build_options.createModule();
    const version_stamp = b.addWriteFiles().add("BUILD_VERSION", b.fmt("{s}\n", .{version}));
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        version_stamp,
        .{ .custom = "share/verde" },
        "BUILD_VERSION",
    ).step);
    // Invoke Bun directly so native Windows builds do not require Git Bash.
    const build_inspector_bundle = b.addSystemCommand(&.{
        "bun",
        "build",
        "src/entry-embed.ts",
        "--target=browser",
        "--format=iife",
        "--outfile",
    });
    build_inspector_bundle.setCwd(b.path("../browser_extensions/inspector"));
    build_inspector_bundle.addFileInput(b.path("../browser_extensions/inspector/src/entry-embed.ts"));
    build_inspector_bundle.addFileInput(b.path("../browser_extensions/inspector/src/inspector.ts"));
    build_inspector_bundle.addFileInput(b.path("../browser_extensions/inspector/src/types.ts"));
    const inspector_bundle_output = build_inspector_bundle.addOutputFileArg("inspector.js");
    // ZLS captures its build runner's stdout as JSON, so keep Bun's status
    // output from contaminating the build configuration stream.
    _ = build_inspector_bundle.captureStdOut(.{});

    const inspector_bundle_files = b.addWriteFiles();
    _ = inspector_bundle_files.addCopyFile(
        inspector_bundle_output,
        "inspector.js",
    );
    const inspector_bundle_module = b.createModule(.{
        .root_source_file = inspector_bundle_files.add("inspector_bundle.zig",
            \\pub const bundle = @embedFile("inspector.js");
            \\
        ),
    });

    const build_provider_bridge = b.addSystemCommand(&.{
        "bun",
        "build",
        "src/providers/provider_bridge.ts",
        "--target=node",
        "--outfile",
    });
    const provider_bridge_output = build_provider_bridge.addOutputFileArg("provider_bridge.mjs");
    build_provider_bridge.setCwd(b.path("."));
    build_provider_bridge.addFileInput(b.path("src/providers/provider_bridge.ts"));
    const install_provider_bridge = b.addInstallFileWithDir(
        provider_bridge_output,
        .{ .custom = "share/verde" },
        "provider_bridge.mjs",
    );
    b.getInstallStep().dependOn(&install_provider_bridge.step);

    const daemon_exe = b.addExecutable(.{
        .name = "verde-daemon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = daemon_build_options_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "headless", .module = headless_module },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    daemon_exe.build_id = .sha1;
    daemon_exe.each_lib_rpath = false;
    daemon_exe.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        // forkpty(3), used by daemon-owned PTY sessions, lives in libutil on
        // Linux. No SDL, Palette, browser helper, fonts, or desktop entrypoint
        // participates in this executable.
        daemon_exe.root_module.linkSystemLibrary("util", .{});
    } else if (target.result.os.tag == .windows) {
        daemon_exe.subsystem = .console;
        addWindowsApplicationResources(b, daemon_exe, version, "verde-daemon.exe", "verde-daemon-version.rc");
        addWindowsSystemLibraries(daemon_exe);
    }
    const install_daemon = b.addInstallArtifact(daemon_exe, .{});
    b.getInstallStep().dependOn(&install_daemon.step);

    const gui_exe = b.addExecutable(.{
        .name = "verde-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "headless", .module = headless_module },
                .{ .name = "loop_wakeup", .module = loop_wakeup_module },
                .{ .name = "palette", .module = palette_module },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    gui_exe.build_id = .sha1;
    gui_exe.each_lib_rpath = false;
    if (target.result.os.tag == .macos) {
        gui_exe.headerpad_max_install_names = true;
    }
    const build_fff = if (build_fff_enabled) addFffBuild(b, fff_root, target, fff_cargo_target) else null;
    if (build_fff) |build_step| gui_exe.step.dependOn(&build_step.step);
    gui_exe.root_module.link_libc = true;
    gui_exe.root_module.addIncludePath(b.path("../../vendor"));
    gui_exe.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    addFffLink(gui_exe, target.result.os.tag, fff_lib_dir, fff_import_lib);
    gui_exe.root_module.addCSourceFile(.{
        .file = b.path("../../vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    switch (target.result.os.tag) {
        .linux => {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
                gui_exe.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
            }
            gui_exe.root_module.addCSourceFile(.{
                .file = b.path("src/browser/platform/linux_wayland_subsurface.c"),
                .flags = &.{},
            });
            gui_exe.root_module.linkSystemLibrary("SDL3", .{});
            gui_exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
            gui_exe.root_module.linkSystemLibrary("util", .{});
            gui_exe.root_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
        },
        .windows => {
            gui_exe.subsystem = .windows;
            if (target.result.abi == .msvc) {
                // The MSVC GUI subsystem otherwise selects WinMainCRTStartup,
                // while Zig's libc startup exports main for this root module.
                gui_exe.entry = .{ .symbol_name = "mainCRTStartup" };
            }
            addWindowsApplicationResources(b, gui_exe, version, "Verde.exe", "verde-gui-version.rc");
            addWindowsIntegrations(b, gui_exe);
            addWindowsWebView2(b, gui_exe, .{
                .real_webview = browser_backend == .native_webview,
                .include_dir = webview2_include_dir,
                .loader_import_lib = webview2_loader_lib,
            });
            addWindowsSdlPaths(gui_exe, .{
                .sdl3_include_dir = sdl3_include_dir,
                .sdl3_lib_dir = sdl3_lib_dir,
                .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
                .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
            });
            addWindowsSdlIncludes(palette_module, sdl3_include_dir, sdl3_ttf_include_dir);
            gui_exe.root_module.linkSystemLibrary("SDL3", .{});
            gui_exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
            addWindowsSystemLibraries(gui_exe);
        },
        .macos => {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
                gui_exe.root_module.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
            }
            if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
                gui_exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "System", "Library", "Frameworks" }) });
                gui_exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "usr", "include" }) });
            }
            gui_exe.root_module.addCSourceFile(.{
                .file = b.path("src/platform/macos_clipboard.m"),
                .flags = &.{},
            });
            addMacOSSwiftWebView(b, gui_exe, target.result.cpu.arch);
            if (macOSHomebrewPrefix(b)) |prefix| {
                gui_exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
                gui_exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
                palette_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
            }
            gui_exe.root_module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .yes });
            gui_exe.root_module.linkSystemLibrary("sdl3-ttf", .{ .use_pkg_config = .yes });
            gui_exe.root_module.linkFramework("AppKit", .{});
            gui_exe.root_module.linkFramework("WebKit", .{});
        },
        else => {},
    }
    switch (target.result.os.tag) {
        .linux => gui_exe.root_module.addRPathSpecial("$ORIGIN"),
        .macos => gui_exe.root_module.addRPathSpecial("@executable_path"),
        else => {},
    }

    // The stable public command is intentionally a separate compilation
    // boundary. It dispatches CLI commands and launches the sibling private
    // GUI without pulling SDL, Palette, rendering, or GUI state into its root.
    const cli_exe = b.addExecutable(.{
        .name = "verde",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "headless", .module = headless_module },
                .{ .name = "loop_wakeup", .module = loop_wakeup_module },
                .{ .name = "palette", .module = palette_module },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    cli_exe.build_id = .sha1;
    cli_exe.each_lib_rpath = false;
    cli_exe.root_module.link_libc = true;
    switch (target.result.os.tag) {
        .linux => cli_exe.root_module.linkSystemLibrary("util", .{}),
        .windows => {
            cli_exe.subsystem = .console;
            addWindowsApplicationResources(b, cli_exe, version, "verde.exe", "verde-cli-version.rc");
            addWindowsIntegrations(b, cli_exe);
            addWindowsSystemLibraries(cli_exe);
        },
        else => {},
    }

    const install_gui = b.addInstallArtifact(gui_exe, .{});
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    // Normal Linux builds give the Rust cdylib a stable SONAME, so the
    // executable's $ORIGIN runpath can resolve the installed sibling library.
    // Keep patchelf only for caller-supplied libraries that may lack one.
    if (target.result.os.tag == .linux and !build_fff_enabled) {
        if (b.findProgram(&.{"patchelf"}, &.{})) |patchelf_path| {
            const normalize_fff_needed = b.addSystemCommand(&.{
                patchelf_path,
                "--replace-needed",
                fff_runtime_lib,
                fffRuntimeName(.linux),
            });
            normalize_fff_needed.addArtifactArg(gui_exe);
            install_gui.step.dependOn(&normalize_fff_needed.step);
        } else |_| {}
    }
    const dev_build_step = b.step("dev-build", "Build and install only the private desktop GUI executable");
    dev_build_step.dependOn(&install_gui.step);
    b.getInstallStep().dependOn(&install_gui.step);
    b.getInstallStep().dependOn(&install_cli.step);
    if (target.result.os.tag == .linux and browser_backend == .native_webview) {
        const browser_helper = b.addExecutable(.{
            .name = "verde-browser-linux",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/browser/platform/linux_helper_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        browser_helper.build_id = .sha1;
        browser_helper.root_module.link_libc = true;
        browser_helper.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/linux_wpe.c"),
            .flags = &.{},
        });
        browser_helper.root_module.linkSystemLibrary("wpe-webkit-2.0", .{ .use_pkg_config = .force });
        browser_helper.root_module.linkSystemLibrary("wpebackend-fdo-1.0", .{ .use_pkg_config = .force });
        browser_helper.root_module.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
        browser_helper.root_module.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
        browser_helper.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{ .use_pkg_config = .force });
        b.installArtifact(browser_helper);
    }
    const install_fff = b.addInstallBinFile(.{ .cwd_relative = fff_runtime_lib }, fffRuntimeName(target.result.os.tag));
    if (build_fff) |build_step| install_fff.step.dependOn(&build_step.step);
    b.getInstallStep().dependOn(&install_fff.step);
    if (target.result.os.tag == .linux) {
        if (sdl3_runtime_lib) |path| {
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                .{ .cwd_relative = path },
                .bin,
                "libSDL3.so",
            ).step);
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                .{ .cwd_relative = path },
                .bin,
                "libSDL3.so.0",
            ).step);
        } else if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
            inline for (.{ "libSDL3.so", "libSDL3.so.0" }) |name| {
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    sdl3_prebuilt.path("lib/libSDL3.so"),
                    .bin,
                    name,
                ).step);
            }
        }
    }
    if (target.result.os.tag == .windows) {
        installWindowsRuntime(b, sdl3_runtime_lib, "SDL3.dll");
        installWindowsRuntime(b, sdl3_ttf_runtime_lib, "SDL3_ttf.dll");
        if (browser_backend == .native_webview) {
            installWindowsRuntime(b, webview2_loader_dll, "WebView2Loader.dll");
        }
    }
    if (target.result.os.tag == .linux) {
        const desktop_entry = b.addWriteFiles();
        const desktop_entry_path = desktop_entry.add("verde.desktop", b.fmt(
            \\[Desktop Entry]
            \\Version=1.0
            \\Type=Application
            \\Name=Verde
            \\Comment=Desktop chat app for Codex and OpenCode
            \\Exec={s}
            \\Icon={s}
            \\Terminal=false
            \\Categories=Development;
            \\StartupNotify=true
            \\StartupWMClass=com.verde.native
            \\
        , .{
            b.getInstallPath(.bin, "verde"),
            b.getInstallPath(.{ .custom = "share/pixmaps" }, "verde.png"),
        }));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            desktop_entry_path,
            .{ .custom = "share/applications" },
            "verde.desktop",
        ).step);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            b.path("src/assets/verde_logo.png"),
            .{ .custom = "share/pixmaps" },
            "verde.png",
        ).step);
    }
    if (target.result.os.tag == .macos) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = sdl3_prebuilt.path("Frameworks/SDL3.framework"),
                .install_dir = .bin,
                .install_subdir = "SDL3.framework",
            }).step);
        }
    }

    // Run through the installed public launcher so sibling discovery exercises
    // the same layout used by desktop entries and packaged applications.
    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(
        .bin,
        if (target.result.os.tag == .windows) "verde.exe" else "verde",
    )});
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_compile_step = b.step("test-compile", "Compile unit tests without running them");
    // Headless package tests are hermetic (std only) and intentionally avoid
    // SDL/Palette/Ghostty/zqlite so they stay a fast focused gate for core.* work.
    const headless_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("../headless/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const headless_test_step = b.step("headless-test", "Run headless package unit tests (no GUI deps)");
    addTestArtifact(b, headless_test_step, headless_tests, target);
    // The full desktop runner below already includes the headless module. Keep
    // this artifact on its focused step instead of compiling or running the
    // same tests twice in either aggregate step.
    // Remote-runtime infrastructure has its own GUI-free gate so process,
    // transport, profile, and route tests do not depend on the SDL app graph.
    const runtime_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "headless", .module = headless_module },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    runtime_tests.root_module.link_libc = true;
    const runtime_test_step = b.step("runtime-test", "Run remote-runtime infrastructure tests (no GUI deps)");
    addTestArtifact(b, runtime_test_step, runtime_tests, target);
    // main.zig registers these modules in the full desktop runner. Running the
    // focused runner here as well duplicated the database-heavy tests, while
    // compiling it here made test-compile rebuild the same graph twice.
    if (target.result.os.tag == .linux and browser_backend == .native_webview) {
        const linux_browser_helper_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/browser/platform/linux_helper_main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        linux_browser_helper_tests.root_module.link_libc = true;
        linux_browser_helper_tests.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/linux_wpe.c"),
            .flags = &.{"-DVERDE_BROWSER_LINUX_TESTING=1"},
        });
        linux_browser_helper_tests.root_module.linkSystemLibrary("wpe-webkit-2.0", .{ .use_pkg_config = .force });
        linux_browser_helper_tests.root_module.linkSystemLibrary("wpebackend-fdo-1.0", .{ .use_pkg_config = .force });
        linux_browser_helper_tests.root_module.linkSystemLibrary("egl", .{ .use_pkg_config = .force });
        linux_browser_helper_tests.root_module.linkSystemLibrary("glesv2", .{ .use_pkg_config = .force });
        linux_browser_helper_tests.root_module.linkSystemLibrary("javascriptcoregtk-6.0", .{ .use_pkg_config = .force });
        addTestArtifact(b, test_step, linux_browser_helper_tests, target);
        test_compile_step.dependOn(&linux_browser_helper_tests.step);
    }
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/desktop_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "headless", .module = headless_module },
                .{ .name = "loop_wakeup", .module = loop_wakeup_module },
                .{ .name = "palette", .module = palette.module("palette") },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    exe_tests.build_id = .sha1;
    if (build_fff) |build_step| exe_tests.step.dependOn(&build_step.step);
    exe_tests.root_module.addIncludePath(b.path("../../vendor"));
    exe_tests.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    addFffLink(exe_tests, target.result.os.tag, fff_lib_dir, fff_import_lib);
    exe_tests.root_module.addCSourceFile(.{
        .file = b.path("../../vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    exe_tests.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
            exe_tests.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
        }
        exe_tests.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/linux_wayland_subsurface.c"),
            .flags = &.{},
        });
        exe_tests.root_module.linkSystemLibrary("SDL3", .{});
        exe_tests.root_module.linkSystemLibrary("SDL3_ttf", .{});
        exe_tests.root_module.linkSystemLibrary("util", .{});
        exe_tests.root_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
    } else if (target.result.os.tag == .macos) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
            exe_tests.root_module.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
        }
        exe_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos_clipboard.m"),
            .flags = &.{},
        });
        if (browser_backend == .native_webview) {
            addMacOSSwiftWebView(b, exe_tests, target.result.cpu.arch);
        } else {
            addMacOSWebViewTestStub(b, exe_tests);
        }
        exe_tests.root_module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .yes });
        exe_tests.root_module.linkSystemLibrary("sdl3-ttf", .{ .use_pkg_config = .yes });
        exe_tests.root_module.linkFramework("AppKit", .{});
        exe_tests.root_module.linkFramework("WebKit", .{});
    } else if (target.result.os.tag == .windows) {
        addWindowsIntegrations(b, exe_tests);
        addWindowsWebView2(b, exe_tests, .{
            .real_webview = browser_backend == .native_webview,
            .include_dir = webview2_include_dir,
            .loader_import_lib = webview2_loader_lib,
        });
        addWindowsSdlPaths(exe_tests, .{
            .sdl3_include_dir = sdl3_include_dir,
            .sdl3_lib_dir = sdl3_lib_dir,
            .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
            .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        });
        exe_tests.root_module.linkSystemLibrary("SDL3", .{});
        exe_tests.root_module.linkSystemLibrary("SDL3_ttf", .{});
        addWindowsSystemLibraries(exe_tests);
    }
    addTestArtifact(b, test_step, exe_tests, target);
    test_compile_step.dependOn(&exe_tests.step);

    // Hermetic headless client ↔ real session-daemon subprocess (tmp pref only).
    // Dedicated binary so the daemon's idle process.exit cannot kill the unit-test runner.
    const headless_daemon_it_exe = b.addExecutable(.{
        .name = "headless-daemon-it",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless_daemon_it_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_module },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "headless", .module = headless_module },
                .{ .name = "loop_wakeup", .module = loop_wakeup_module },
                .{ .name = "palette", .module = palette.module("palette") },
                .{ .name = "platform_paths", .module = platform_paths_module },
                .{ .name = "platform_runtime", .module = platform_runtime_module },
                .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    headless_daemon_it_exe.build_id = .sha1;
    if (build_fff) |build_step| headless_daemon_it_exe.step.dependOn(&build_step.step);
    headless_daemon_it_exe.root_module.addIncludePath(b.path("../../vendor"));
    headless_daemon_it_exe.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    addFffLink(headless_daemon_it_exe, target.result.os.tag, fff_lib_dir, fff_import_lib);
    headless_daemon_it_exe.root_module.addCSourceFile(.{
        .file = b.path("../../vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    headless_daemon_it_exe.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
            headless_daemon_it_exe.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
        }
        headless_daemon_it_exe.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/linux_wayland_subsurface.c"),
            .flags = &.{},
        });
        headless_daemon_it_exe.root_module.linkSystemLibrary("SDL3", .{});
        headless_daemon_it_exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
        headless_daemon_it_exe.root_module.linkSystemLibrary("util", .{});
        headless_daemon_it_exe.root_module.linkSystemLibrary("wayland-client", .{ .use_pkg_config = .force });
    } else if (target.result.os.tag == .macos) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
            headless_daemon_it_exe.root_module.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
        }
        headless_daemon_it_exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos_clipboard.m"),
            .flags = &.{},
        });
        if (browser_backend == .native_webview) {
            addMacOSSwiftWebView(b, headless_daemon_it_exe, target.result.cpu.arch);
        } else {
            addMacOSWebViewTestStub(b, headless_daemon_it_exe);
        }
        headless_daemon_it_exe.root_module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .yes });
        headless_daemon_it_exe.root_module.linkSystemLibrary("sdl3-ttf", .{ .use_pkg_config = .yes });
        headless_daemon_it_exe.root_module.linkFramework("AppKit", .{});
        headless_daemon_it_exe.root_module.linkFramework("WebKit", .{});
    } else if (target.result.os.tag == .windows) {
        addWindowsIntegrations(b, headless_daemon_it_exe);
        addWindowsWebView2(b, headless_daemon_it_exe, .{
            .real_webview = browser_backend == .native_webview,
            .include_dir = webview2_include_dir,
            .loader_import_lib = webview2_loader_lib,
        });
        addWindowsSdlPaths(headless_daemon_it_exe, .{
            .sdl3_include_dir = sdl3_include_dir,
            .sdl3_lib_dir = sdl3_lib_dir,
            .sdl3_ttf_include_dir = sdl3_ttf_include_dir,
            .sdl3_ttf_lib_dir = sdl3_ttf_lib_dir,
        });
        headless_daemon_it_exe.root_module.linkSystemLibrary("SDL3", .{});
        headless_daemon_it_exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
        addWindowsSystemLibraries(headless_daemon_it_exe);
    }
    const headless_daemon_it_step = b.step("headless-daemon-it", "Hermetic headless client/session-daemon integration test");
    const host = b.graph.host.result;
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        const run_it = b.addRunArtifact(headless_daemon_it_exe);
        headless_daemon_it_step.dependOn(&run_it.step);
    } else {
        // Foreign targets: compile-only; never spawn Wine/binfmt.
        headless_daemon_it_step.dependOn(&headless_daemon_it_exe.step);
    }

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
    test_compile_step.dependOn(&fmt_check.step);
}

const PaletteRendererBackend = enum {
    sdl_gpu,
};

const BrowserBackendKind = enum {
    native_webview,
    stub,
};

const WindowsSdlPathOptions = struct {
    sdl3_include_dir: ?[]const u8 = null,
    sdl3_lib_dir: ?[]const u8 = null,
    sdl3_ttf_include_dir: ?[]const u8 = null,
    sdl3_ttf_lib_dir: ?[]const u8 = null,
};

fn addWindowsSdlPaths(compile: *std.Build.Step.Compile, options: WindowsSdlPathOptions) void {
    if (options.sdl3_include_dir) |path| compile.root_module.addIncludePath(.{ .cwd_relative = path });
    if (options.sdl3_lib_dir) |path| compile.root_module.addLibraryPath(.{ .cwd_relative = path });
    if (options.sdl3_ttf_include_dir) |path| compile.root_module.addIncludePath(.{ .cwd_relative = path });
    if (options.sdl3_ttf_lib_dir) |path| compile.root_module.addLibraryPath(.{ .cwd_relative = path });
}

fn addWindowsSdlIncludes(
    module: *std.Build.Module,
    sdl3_include_dir: ?[]const u8,
    sdl3_ttf_include_dir: ?[]const u8,
) void {
    if (sdl3_include_dir) |path| module.addIncludePath(.{ .cwd_relative = path });
    if (sdl3_ttf_include_dir) |path| module.addIncludePath(.{ .cwd_relative = path });
}

const WindowsWebView2Options = struct {
    real_webview: bool,
    include_dir: ?[]const u8 = null,
    loader_import_lib: ?[]const u8 = null,
};

fn addWindowsIntegrations(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().abi != .msvc) compile.root_module.link_libcpp = true;
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/platform/windows/integrations.cpp"),
        .flags = windowsCppFlags(compile),
    });
}

fn addWindowsWebView2(b: *std.Build, compile: *std.Build.Step.Compile, options: WindowsWebView2Options) void {
    if (options.real_webview) {
        if (compile.rootModuleTarget().abi != .msvc) compile.root_module.link_libcpp = true;
        addMsvcSystemIncludePaths(b, compile);
        if (options.include_dir) |path| compile.root_module.addIncludePath(.{ .cwd_relative = path });
        if (options.loader_import_lib) |path| {
            compile.root_module.addObjectFile(.{ .cwd_relative = path });
        } else {
            compile.root_module.linkSystemLibrary("WebView2Loader", .{});
        }
        compile.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/windows_webview2.cpp"),
            .flags = windowsCppFlags(compile),
        });
    } else {
        compile.root_module.addCSourceFile(.{
            .file = b.path("src/browser/platform/windows_webview2_test_stub.c"),
            .flags = &.{},
        });
    }
}

fn windowsCppFlags(compile: *std.Build.Step.Compile) []const []const u8 {
    if (compile.rootModuleTarget().abi == .msvc) {
        // Zig passes -nostdinc++ for MSVC C++ sources even without link_libcpp;
        // Clang otherwise promotes the unused driver argument to an error.
        return &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-Wno-unused-command-line-argument" };
    }
    return &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE" };
}

fn addMsvcSystemIncludePaths(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().abi != .msvc) return;
    const include_paths = b.graph.environ_map.get("INCLUDE") orelse return;
    var paths = std.mem.splitScalar(u8, include_paths, ';');
    while (paths.next()) |path| {
        if (!std.ascii.endsWithIgnoreCase(path, "\\winrt") and
            !std.ascii.endsWithIgnoreCase(path, "/winrt")) continue;
        // Zig discovers the core MSVC headers but not the SDK's WinRT path,
        // where WebView2's WRL dependency is installed.
        compile.root_module.addSystemIncludePath(.{ .cwd_relative = path });
    }
}

fn addWindowsSystemLibraries(compile: *std.Build.Step.Compile) void {
    compile.root_module.linkSystemLibrary("advapi32", .{});
    compile.root_module.linkSystemLibrary("ole32", .{});
    compile.root_module.linkSystemLibrary("propsys", .{});
    compile.root_module.linkSystemLibrary("shell32", .{});
    compile.root_module.linkSystemLibrary("shlwapi", .{});
    compile.root_module.linkSystemLibrary("user32", .{});
    compile.root_module.linkSystemLibrary("version", .{});
}

fn addWindowsApplicationResources(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    version: []const u8,
    original_filename: []const u8,
    resource_name: []const u8,
) void {
    const manifest = addWindowsManifest(b, version);
    manifest.addStepDependencies(&compile.step);
    compile.win32_manifest = manifest;
    compile.root_module.addWin32ResourceFile(.{
        .file = b.path("src/platform/windows/verde.rc"),
        .flags = &.{},
        // Keep the native executable icon beside its resource script so a web
        // favicon change cannot silently replace the Windows application icon.
        .include_paths = &.{b.path("src/platform/windows")},
    });
    compile.root_module.addWin32ResourceFile(.{
        .file = addWindowsVersionResource(b, version, original_filename, resource_name),
        .flags = &.{},
        .include_paths = &.{},
    });
}

fn addWindowsVersionResource(
    b: *std.Build,
    version: []const u8,
    original_filename: []const u8,
    resource_name: []const u8,
) std.Build.LazyPath {
    const numeric = windowsNumericVersion(version);
    const source = b.fmt(
        \\1 VERSIONINFO
        \\FILEVERSION {d},{d},{d},{d}
        \\PRODUCTVERSION {d},{d},{d},{d}
        \\FILEFLAGSMASK 0x3fL
        \\FILEFLAGS 0x0L
        \\FILEOS 0x00040004L
        \\FILETYPE 0x00000001L
        \\FILESUBTYPE 0x00000000L
        \\BEGIN
        \\    BLOCK "StringFileInfo"
        \\    BEGIN
        \\        BLOCK "040904b0"
        \\        BEGIN
        \\            VALUE "CompanyName", "Verde contributors\0"
        \\            VALUE "FileDescription", "Verde native desktop workspace\0"
        \\            VALUE "FileVersion", "{s}\0"
        \\            VALUE "InternalName", "Verde\0"
        \\            VALUE "LegalCopyright", "Copyright (c) Verde contributors\0"
        \\            VALUE "OriginalFilename", "{s}\0"
        \\            VALUE "ProductName", "Verde\0"
        \\            VALUE "ProductVersion", "{s}\0"
        \\        END
        \\    END
        \\    BLOCK "VarFileInfo"
        \\    BEGIN
        \\        VALUE "Translation", 0x0409, 1200
        \\    END
        \\END
        \\
    , .{
        numeric[0], numeric[1],        numeric[2], numeric[3],
        numeric[0], numeric[1],        numeric[2], numeric[3],
        version,    original_filename, version,
    });
    return b.addWriteFiles().add(resource_name, source);
}

fn addWindowsManifest(b: *std.Build, version: []const u8) std.Build.LazyPath {
    const numeric = windowsNumericVersion(version);
    const numeric_text = b.fmt("{d}.{d}.{d}.{d}", .{
        numeric[0], numeric[1], numeric[2], numeric[3],
    });
    const source = std.mem.replaceOwned(
        u8,
        b.allocator,
        @embedFile("src/platform/windows/verde.manifest"),
        "VERDE_NUMERIC_VERSION",
        numeric_text,
    ) catch @panic("OOM");
    defer b.allocator.free(source);
    return b.addWriteFiles().add("verde.manifest", source);
}

fn windowsNumericVersion(version: []const u8) [4]u16 {
    const zero = [_]u16{0} ** 4;
    const numeric_version = if (version.len > 1 and
        (version[0] == 'v' or version[0] == 'V') and
        version[1] >= '0' and version[1] <= '9')
        version[1..]
    else
        version;
    const core_end = std.mem.findAny(u8, numeric_version, "-+") orelse numeric_version.len;
    const core = numeric_version[0..core_end];
    if (core.len == 0) return zero;

    for (core) |character| {
        if ((character < '0' or character > '9') and character != '.') return zero;
    }

    var result = zero;
    var index: usize = 0;
    var parts = std.mem.splitScalar(u8, core, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return zero;
        if (index == result.len) {
            @panic("numeric version core may contain at most four components");
        }
        result[index] = std.fmt.parseUnsigned(u16, part, 10) catch
            @panic("numeric version components must fit in an unsigned 16-bit integer");
        index += 1;
    }
    return result;
}

fn isValidVersion(version: []const u8) bool {
    if (version.len == 0 or !isAsciiAlphaNumeric(version[0])) return false;
    for (version[1..]) |character| {
        if (!isAsciiAlphaNumeric(character) and
            character != '.' and character != '_' and character != '+' and character != '-')
        {
            return false;
        }
    }
    return true;
}

fn isAsciiAlphaNumeric(character: u8) bool {
    return (character >= '0' and character <= '9') or
        (character >= 'A' and character <= 'Z') or
        (character >= 'a' and character <= 'z');
}

test "Windows numeric version keeps the release core and drops prerelease metadata" {
    try std.testing.expectEqual([_]u16{ 0, 1, 27, 0 }, windowsNumericVersion("0.1.27-internal-20260710"));
    try std.testing.expectEqual([_]u16{ 0, 1, 27, 0 }, windowsNumericVersion("v0.1.27"));
    try std.testing.expectEqual([_]u16{ 1, 2, 3, 4 }, windowsNumericVersion("1.2.3.4+build.9"));
}

test "Windows numeric version uses zero for nonnumeric release labels" {
    try std.testing.expectEqual([_]u16{ 0, 0, 0, 0 }, windowsNumericVersion("ci-123"));
}

test "build version accepts only resource-safe ASCII" {
    try std.testing.expect(isValidVersion("0.1.27-internal-20260710"));
    try std.testing.expect(!isValidVersion("0.1.27 internal"));
    try std.testing.expect(!isValidVersion("-preview"));
}

fn addFffBuild(
    b: *std.Build,
    fff_root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    cargo_target: ?[]const u8,
) *std.Build.Step.Run {
    const build_fff = b.addSystemCommand(&.{"cargo"});
    const cross_compiling_windows = target.result.os.tag == .windows and
        b.graph.host.result.os.tag != .windows;
    // Cargo's rustc subcommand scopes the SONAME linker argument to fff-c;
    // dependency build scripts and the Windows/macOS link paths stay unchanged.
    const cargo_subcommand = if (target.result.os.tag == .linux)
        "rustc"
    else
        b.graph.environ_map.get("VERDE_FFF_CARGO_SUBCOMMAND") orelse
            if (cross_compiling_windows) "zigbuild" else "build";
    build_fff.addArg(cargo_subcommand);
    build_fff.addArgs(&.{
        "--quiet",
        "--release",
        "--package",
        "fff-c",
        "--features",
        "zlob",
    });
    if (cargo_target) |value| build_fff.addArgs(&.{ "--target", value });
    if (target.result.os.tag == .linux) {
        build_fff.addArgs(&.{ "--", "-C", "link-arg=-Wl,-soname,libfff_c.so" });
    }
    if (target.result.os.tag == .windows) {
        // The vendored crate tracks `stable`, which would otherwise move under
        // release builds. Pin the Windows ABI/toolchain lane explicitly while
        // retaining an escape hatch for deliberate toolchain upgrades.
        build_fff.setEnvironmentVariable(
            "RUSTUP_TOOLCHAIN",
            b.graph.environ_map.get("VERDE_FFF_RUST_TOOLCHAIN") orelse "1.95.0",
        );
    }
    if (cross_compiling_windows and target.result.abi == .gnu) {
        const toolchain_bin = b.build_root.join(
            b.allocator,
            &.{ "..", "..", "scripts", "dev", "windows-toolchain-bin" },
        ) catch @panic("OOM");
        build_fff.addPathDir(toolchain_bin);
        build_fff.setEnvironmentVariable(
            "ZIG",
            b.pathJoin(&.{ toolchain_bin, "verde-zig-windows-gnu" }),
        );
        build_fff.setEnvironmentVariable("VERDE_REAL_ZIG", b.graph.zig_exe);

        // Zig deliberately rejects time macros for cross-Windows C builds.
        // Mimalloc embeds them in a diagnostic string, so anchor their value to
        // SOURCE_DATE_EPOCH and permit that deterministic expansion.
        build_fff.setEnvironmentVariable(
            "SOURCE_DATE_EPOCH",
            b.graph.environ_map.get("SOURCE_DATE_EPOCH") orelse "0",
        );
        const reproducible_cflags = "-Wno-error=date-time";
        build_fff.setEnvironmentVariable(
            "CFLAGS_x86_64_pc_windows_gnu",
            if (b.graph.environ_map.get("CFLAGS_x86_64_pc_windows_gnu")) |value|
                b.fmt("{s} {s}", .{ value, reproducible_cflags })
            else
                reproducible_cflags,
        );
    }
    build_fff.setCwd(fff_root);
    return build_fff;
}

fn addFffLink(
    compile: *std.Build.Step.Compile,
    target_os: std.Target.Os.Tag,
    library_dir: []const u8,
    import_library: ?[]const u8,
) void {
    if (target_os == .windows) {
        if (import_library) |path| {
            compile.root_module.addObjectFile(.{ .cwd_relative = path });
            return;
        }
    }
    compile.root_module.addLibraryPath(.{ .cwd_relative = library_dir });
    compile.root_module.linkSystemLibrary("fff_c", .{});
}

fn addTestArtifact(
    b: *std.Build,
    test_step: *std.Build.Step,
    artifact: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    const host = b.graph.host.result;
    // Keep a real linked artifact in the cache. Without an emitted-bin
    // consumer Zig can reduce a compile-only test to `-fno-emit-bin`.
    _ = artifact.getEmittedBin();
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        test_step.dependOn(&b.addRunArtifact(artifact).step);
    } else {
        // Foreign test binaries are compile checks only; never invoke Wine/binfmt implicitly.
        test_step.dependOn(&artifact.step);
    }
}

fn installWindowsRuntime(b: *std.Build, source_path: ?[]const u8, name: []const u8) void {
    const path = source_path orelse return;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        .{ .cwd_relative = path },
        .bin,
        name,
    ).step);
}

fn windowsRustTarget(target: std.Target) ?[]const u8 {
    if (target.os.tag != .windows) return null;
    return switch (target.cpu.arch) {
        .x86_64 => switch (target.abi) {
            .gnu => "x86_64-pc-windows-gnu",
            .msvc => "x86_64-pc-windows-msvc",
            else => null,
        },
        .aarch64 => switch (target.abi) {
            .gnu => "aarch64-pc-windows-gnullvm",
            .msvc => "aarch64-pc-windows-msvc",
            else => null,
        },
        else => null,
    };
}

fn defaultWindowsFffImportLibrary(
    b: *std.Build,
    target: std.Target,
    library_dir: []const u8,
) ?[]const u8 {
    if (target.os.tag != .windows) return null;
    return b.pathJoin(&.{ library_dir, switch (target.abi) {
        .msvc => "fff_c.dll.lib",
        else => "libfff_c.dll.a",
    } });
}

fn fffRuntimeName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .windows => "fff_c.dll",
        .macos => "libfff_c.dylib",
        else => "libfff_c.so",
    };
}

fn addMacOSSwiftWebView(b: *std.Build, compile: *std.Build.Step.Compile, arch: std.Target.Cpu.Arch) void {
    const swift_target = switch (arch) {
        .aarch64 => "arm64-apple-macosx13.0",
        .x86_64 => "x86_64-apple-macosx13.0",
        else => @panic("unsupported macOS Swift architecture"),
    };
    const swift_obj = b.addSystemCommand(&.{
        "xcrun",
        "swiftc",
        "-parse-as-library",
        "-emit-object",
        "-O",
        "-sdk",
        macOSSDKRoot(b),
        "-target",
        swift_target,
        "-module-name",
        "VerdeMacWebView",
    });
    swift_obj.addFileArg(b.path("src/browser/platform/macos_wkwebview.swift"));
    swift_obj.addArg("-o");
    const object_path = swift_obj.addOutputFileArg(b.fmt("macos_wkwebview-{s}.o", .{@tagName(arch)}));
    compile.root_module.addObjectFile(object_path);
    compile.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ macOSSDKRoot(b), "usr", "lib", "swift" }) });
    compile.root_module.addLibraryPath(.{ .cwd_relative = "/Library/Developer/CommandLineTools/usr/lib/swift/macosx" });
    compile.root_module.addRPath(.{ .cwd_relative = "/Library/Developer/CommandLineTools/usr/lib/swift/macosx" });
    compile.root_module.linkSystemLibrary("swiftCore", .{});
    compile.root_module.linkSystemLibrary("swiftFoundation", .{});
    compile.root_module.linkSystemLibrary("swiftDispatch", .{});
    compile.root_module.linkSystemLibrary("swiftCoreFoundation", .{});
    compile.root_module.linkSystemLibrary("swiftCoreGraphics", .{});
    compile.root_module.linkSystemLibrary("swiftCoreImage", .{});
    compile.root_module.linkSystemLibrary("swiftDarwin", .{});
    compile.root_module.linkSystemLibrary("swiftIOKit", .{});
    compile.root_module.linkSystemLibrary("swiftMetal", .{});
    compile.root_module.linkSystemLibrary("swiftOSLog", .{});
    compile.root_module.linkSystemLibrary("swiftObjectiveC", .{});
    compile.root_module.linkSystemLibrary("swiftQuartzCore", .{});
    compile.root_module.linkSystemLibrary("swiftUniformTypeIdentifiers", .{});
    compile.root_module.linkSystemLibrary("swiftWebKit", .{});
    compile.root_module.linkSystemLibrary("swiftXPC", .{});
    compile.root_module.linkSystemLibrary("swiftos", .{});
    compile.step.dependOn(&swift_obj.step);
}

fn addMacOSWebViewTestStub(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/browser/platform/macos_wkwebview_test_stub.c"),
        .flags = &.{},
    });
}

fn macOSSDKRoot(b: *std.Build) []const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| return sdkroot;
    const candidates = [_][]const u8{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX14.sdk",
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    };
    for (candidates) |sdkroot| {
        std.Io.Dir.accessAbsolute(b.graph.io, b.pathJoin(&.{ sdkroot, "usr", "lib", "swift", "libswiftCore.tbd" }), .{}) catch continue;
        return sdkroot;
    }
    return "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
}

fn defaultSystemSdl3Runtime(b: *std.Build, target_os: std.Target.Os.Tag) ?[]const u8 {
    if (target_os != .linux or b.graph.host.result.os.tag != .linux) return null;
    const candidates = [_][]const u8{
        "/usr/lib/libSDL3.so.0",
        "/usr/lib/x86_64-linux-gnu/libSDL3.so.0",
    };
    for (candidates) |path| {
        std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

fn macOSHomebrewPrefix(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("HOMEBREW_PREFIX")) |prefix| return prefix;
    const candidates = [_][]const u8{ "/opt/homebrew", "/usr/local" };
    for (candidates) |prefix| {
        std.Io.Dir.accessAbsolute(b.graph.io, b.pathJoin(&.{ prefix, "include", "SDL3_ttf", "SDL_ttf.h" }), .{}) catch continue;
        return prefix;
    }
    return null;
}
