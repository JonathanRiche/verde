const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ui_debug = b.option(bool, "ui-debug", "Show the desktop UI debug window") orelse false;
    const palette_renderer = b.option(PaletteRendererBackend, "palette-renderer", "Palette frame renderer backend: sdl_gpu") orelse .sdl_gpu;
    const cef_sdk_path = b.option([]const u8, "cef-sdk-path", "Path to a CEF binary distribution for the embedded browser pane");
    const sdl3_runtime_lib = b.option([]const u8, "sdl3-runtime-lib", "Path to the SDL3 runtime library to install beside the executable") orelse
        b.graph.environ_map.get("VERDE_SDL3_RUNTIME_LIB") orelse
        defaultSystemSdl3Runtime(b);
    const sdl3_msvc_root = b.option([]const u8, "sdl3-msvc-root", "Path to extracted SDL3-devel-VC archive (Windows MSVC builds)") orelse
        b.graph.environ_map.get("VERDE_SDL3_MSVC_ROOT");
    const sdl3_ttf_msvc_root = b.option([]const u8, "sdl3-ttf-msvc-root", "Path to extracted SDL3_ttf-devel-VC archive (Windows MSVC builds)") orelse
        b.graph.environ_map.get("VERDE_SDL3_TTF_MSVC_ROOT");
    const cef_stub_preview = b.option(bool, "cef-stub-preview", "Use the in-app CEF pane scaffold without a real CEF SDK") orelse false;
    const cef_supported = target.result.os.tag == .linux or target.result.os.tag == .macos;
    const cef_sdk_configured = cef_sdk_path != null and cef_supported;
    const fff_root = b.path("../../vendor/fff");
    const fff_lib_name = switch (target.result.os.tag) {
        .windows => "fff_c.dll",
        .macos => "libfff_c.dylib",
        else => "libfff_c.so",
    };
    const fff_lib_path = b.path(b.pathJoin(&.{ "../../vendor/fff/target/release", fff_lib_name }));

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
    const zsdl = b.dependency("zsdl", .{});
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
    const chat_markdown = b.createModule(.{
        .root_source_file = b.path("src/ui/chat_markdown.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "palette", .module = palette_module },
            .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
            .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
        },
    });
    const build_options = b.addOptions();
    build_options.addOption(bool, "ui_debug", ui_debug);
    build_options.addOption(PaletteRendererBackend, "palette_renderer", palette_renderer);
    build_options.addOption(bool, "cef_sdk_configured", cef_sdk_configured);
    build_options.addOption(bool, "cef_stub_preview", cef_stub_preview);

    const build_inspector_bundle = b.addSystemCommand(&.{
        "bun",
        "run",
        "build",
    });
    build_inspector_bundle.setCwd(b.path("../browser_extensions/inspector"));

    const inspector_bundle_files = b.addWriteFiles();
    _ = inspector_bundle_files.addCopyFile(
        b.path("../browser_extensions/inspector/dist/inspector.js"),
        "inspector.js",
    );
    inspector_bundle_files.step.dependOn(&build_inspector_bundle.step);
    const inspector_bundle_module = b.createModule(.{
        .root_source_file = inspector_bundle_files.add("inspector_bundle.zig",
            \\pub const bundle = @embedFile("inspector.js");
            \\
        ),
    });

    const exe = b.addExecutable(.{
        .name = "verde",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "palette", .module = palette_module },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    exe.build_id = .sha1;
    exe.each_lib_rpath = false;
    const build_fff = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--quiet",
        "--release",
        "--package",
        "fff-c",
        "--features",
        "zlob",
    });
    build_fff.setCwd(fff_root);
    exe.step.dependOn(&build_fff.step);
    exe.root_module.link_libc = true;
    exe.root_module.addIncludePath(b.path("../../vendor"));
    exe.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    exe.root_module.addLibraryPath(b.path("../../vendor/fff/target/release"));
    exe.root_module.linkSystemLibrary("fff_c", .{});
    exe.root_module.addCSourceFile(.{
        .file = b.path("../../vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    switch (target.result.os.tag) {
        .linux => {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
                exe.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
            }
            exe.root_module.linkSystemLibrary("SDL3", .{});
            exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
            exe.root_module.linkSystemLibrary("util", .{});
        },
        .windows => {
            // Phase 1 wiring: -Dsdl3-msvc-root and -Dsdl3-ttf-msvc-root point at
            // extracted SDL3-devel-*-VC.zip / SDL3_ttf-devel-*-VC.zip releases
            // from libsdl-org. Each archive lays out:
            //   <root>/include/...
            //   <root>/lib/x64/{SDL3,SDL3_ttf}.{dll,lib}
            // Phase 2 will move the download into scripts/windows/setup.ps1.
            if (sdl3_msvc_root) |root| {
                exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
                exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib", "x64" }) });
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    .{ .cwd_relative = b.pathJoin(&.{ root, "lib", "x64", "SDL3.dll" }) },
                    .bin,
                    "SDL3.dll",
                ).step);
            } else if (sdl3_runtime_lib) |path| {
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    .{ .cwd_relative = path },
                    .bin,
                    "SDL3.dll",
                ).step);
            }
            if (sdl3_ttf_msvc_root) |root| {
                exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "include" }) });
                exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "lib", "x64" }) });
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(
                    .{ .cwd_relative = b.pathJoin(&.{ root, "lib", "x64", "SDL3_ttf.dll" }) },
                    .bin,
                    "SDL3_ttf.dll",
                ).step);
            }
            exe.root_module.linkSystemLibrary("SDL3", .{});
            exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
        },
        .macos => {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
                exe.root_module.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
            }
            if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
                exe.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "System", "Library", "Frameworks" }) });
                exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdkroot, "usr", "include" }) });
            }
            exe.root_module.addCSourceFile(.{
                .file = b.path("src/platform/macos_clipboard.m"),
                .flags = &.{},
            });
            if (b.graph.environ_map.get("HOMEBREW_PREFIX")) |prefix| {
                exe.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
                exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
                palette_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
            }
            exe.root_module.linkFramework("SDL3", .{});
            exe.root_module.linkSystemLibrary("SDL3_ttf", .{});
            exe.root_module.linkFramework("AppKit", .{});
        },
        else => {},
    }
    switch (target.result.os.tag) {
        .linux => exe.root_module.addRPathSpecial("$ORIGIN"),
        .macos => exe.root_module.addRPathSpecial("@executable_path"),
        else => {},
    }

    const install_exe = b.addInstallArtifact(exe, .{});
    if (target.result.os.tag == .linux) {
        if (b.findProgram(&.{"patchelf"}, &.{})) |patchelf_path| {
            const normalize_fff_needed = b.addSystemCommand(&.{
                patchelf_path,
                "--replace-needed",
                b.pathResolve(&.{ "../../vendor/fff/target/release", fff_lib_name }),
                fff_lib_name,
            });
            normalize_fff_needed.addArtifactArg(exe);
            install_exe.step.dependOn(&normalize_fff_needed.step);
        } else |_| {}
    }
    b.getInstallStep().dependOn(&install_exe.step);
    if (target.result.os.tag == .linux and !cef_sdk_configured) {
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
            .file = b.path("src/browser/platform/linux_webkitgtk.c"),
            .flags = &.{},
        });
        browser_helper.root_module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
        browser_helper.root_module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
        b.installArtifact(browser_helper);
    }
    if (cef_sdk_configured) {
        const build_cef_helper = b.addSystemCommand(&.{
            "bash",
            "-lc",
            b.fmt(
                "cmake -S src/browser/cef/c -B .zig-cache/verde-cef-helper -DCMAKE_BUILD_TYPE=Release -DCEF_ROOT={s} -DVERDE_OUTPUT_DIR=$PWD/zig-out/bin && cmake --build .zig-cache/verde-cef-helper --target verde-browser-cef verde-browser-cef-process --parallel \"${{VERDE_CEF_BUILD_JOBS:-2}}\"",
                .{cef_sdk_path.?},
            ),
        });
        build_cef_helper.setCwd(b.path("."));
        b.getInstallStep().dependOn(&build_cef_helper.step);
        const install_cef_helper = b.addInstallBinFile(
            .{ .cwd_relative = "zig-out/bin/verde-browser-cef" },
            "verde-browser-cef",
        );
        install_cef_helper.step.dependOn(&build_cef_helper.step);
        b.getInstallStep().dependOn(&install_cef_helper.step);
        const install_cef_process_helper = b.addInstallBinFile(
            .{ .cwd_relative = "zig-out/bin/verde-browser-cef-process" },
            "verde-browser-cef-process",
        );
        install_cef_process_helper.step.dependOn(&build_cef_helper.step);
        b.getInstallStep().dependOn(&install_cef_process_helper.step);
        switch (target.result.os.tag) {
            .linux => installLinuxCefRuntime(b, cef_sdk_path.?),
            .macos => installMacOSCefRuntime(b, cef_sdk_path.?),
            else => {},
        }
    }
    const install_fff = b.addInstallBinFile(fff_lib_path, fff_lib_name);
    install_fff.step.dependOn(&build_fff.step);
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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const chat_markdown_tests = b.addTest(.{
        .root_module = chat_markdown,
    });
    chat_markdown_tests.root_module.link_libc = true;
    chat_markdown_tests.root_module.addIncludePath(b.path("../../vendor"));
    if (target.result.os.tag == .linux) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
            chat_markdown_tests.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
        }
        chat_markdown_tests.root_module.linkSystemLibrary("SDL3", .{});
        chat_markdown_tests.root_module.linkSystemLibrary("util", .{});
    }
    test_step.dependOn(&b.addRunArtifact(chat_markdown_tests).step);
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "browser_inspector_bundle", .module = inspector_bundle_module },
                .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
                .{ .name = "palette", .module = palette.module("palette") },
                .{ .name = "zig_dif", .module = zig_dif.module("zig_dif") },
                .{ .name = "zig_markdown", .module = zig_markdown.module("zig_markdown") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
            },
        }),
    });
    exe_tests.build_id = .sha1;
    exe_tests.step.dependOn(&build_fff.step);
    exe_tests.root_module.addIncludePath(b.path("../../vendor"));
    exe_tests.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    exe_tests.root_module.addLibraryPath(b.path("../../vendor/fff/target/release"));
    exe_tests.root_module.linkSystemLibrary("fff_c", .{});
    exe_tests.root_module.addCSourceFile(.{
        .file = b.path("../../vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    exe_tests.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_x86_64_linux_gnu", .{})) |sdl3_prebuilt| {
            exe_tests.root_module.addLibraryPath(sdl3_prebuilt.path("lib"));
        }
        exe_tests.root_module.linkSystemLibrary("SDL3", .{});
        exe_tests.root_module.linkSystemLibrary("util", .{});
    } else if (target.result.os.tag == .macos) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
            exe_tests.root_module.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
        }
        exe_tests.root_module.addCSourceFile(.{
            .file = b.path("src/platform/macos_clipboard.m"),
            .flags = &.{},
        });
        exe_tests.root_module.linkFramework("SDL3", .{});
        exe_tests.root_module.linkFramework("AppKit", .{});
    }
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}

const PaletteRendererBackend = enum {
    sdl_gpu,
};

fn defaultSystemSdl3Runtime(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .linux) return null;
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

fn configureLinuxCefBinary(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    sdk_path: []const u8,
) void {
    const sdk_root: std.Build.LazyPath = .{ .cwd_relative = sdk_path };
    const release_dir = b.pathJoin(&.{ sdk_path, "Release" });

    compile.root_module.link_libcpp = true;
    compile.root_module.addIncludePath(sdk_root);
    compile.root_module.addLibraryPath(.{ .cwd_relative = release_dir });
    compile.root_module.linkSystemLibrary("cef", .{});
    compile.root_module.addCSourceFile(.{
        .file = b.path("src/browser/cef/c/native_linux.cc"),
        .flags = &.{"-std=c++17"},
    });
}

fn installLinuxCefRuntime(b: *std.Build, sdk_path: []const u8) void {
    const release_files = [_][]const u8{
        "libcef.so",
        "libEGL.so",
        "libGLESv2.so",
        "libvk_swiftshader.so",
        "libvulkan.so.1",
        "v8_context_snapshot.bin",
        "vk_swiftshader_icd.json",
        "chrome-sandbox",
    };
    for (release_files) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathJoin(&.{ sdk_path, "Release", name }) },
            .bin,
            name,
        ).step);
    }

    const resource_files = [_][]const u8{
        "chrome_100_percent.pak",
        "chrome_200_percent.pak",
        "resources.pak",
        "icudtl.dat",
    };
    for (resource_files) |name| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            .{ .cwd_relative = b.pathJoin(&.{ sdk_path, "Resources", name }) },
            .bin,
            name,
        ).step);
    }

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = b.pathJoin(&.{ sdk_path, "Resources", "locales" }) },
        .install_dir = .bin,
        .install_subdir = "locales",
    }).step);
}

fn installMacOSCefRuntime(b: *std.Build, sdk_path: []const u8) void {
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = .{ .cwd_relative = b.pathJoin(&.{ sdk_path, "Release", "Chromium Embedded Framework.framework" }) },
        .install_dir = .bin,
        .install_subdir = "Chromium Embedded Framework.framework",
    }).step);
}
