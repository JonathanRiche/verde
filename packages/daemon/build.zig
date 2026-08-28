const std = @import("std");

/// Dependency-isolated build for the standalone Verde daemon.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version embedded in verde-daemon") orelse
        b.graph.environ_map.get("VERDE_VERSION") orelse
        "0.0.0";
    const version_z: [:0]const u8 = b.allocator.dupeSentinel(u8, version, 0) catch @panic("OOM");

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const headless_module = b.createModule(.{
        .root_source_file = b.path("../headless/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_runtime_module = b.createModule(.{
        .root_source_file = b.path("../desktop/src/platform/runtime.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_windows_known_folders_module = b.createModule(.{
        .root_source_file = b.path("../desktop/src/platform/windows/known_folders.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform_paths_module = b.createModule(.{
        .root_source_file = b.path("../desktop/src/platform/paths.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
        },
    });
    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "version", version_z);
    const build_options_module = build_options.createModule();
    const daemon_imports = [_]std.Build.Module.Import{
        .{ .name = "build_options", .module = build_options_module },
        .{ .name = "headless", .module = headless_module },
        .{ .name = "platform_paths", .module = platform_paths_module },
        .{ .name = "platform_runtime", .module = platform_runtime_module },
        .{ .name = "platform_windows_known_folders", .module = platform_windows_known_folders_module },
        .{ .name = "zqlite", .module = zqlite.module("zqlite") },
    };

    const daemon_exe = b.addExecutable(.{
        .name = "verde-daemon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("../desktop/src/daemon_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &daemon_imports,
        }),
    });
    configureDaemonArtifact(daemon_exe, target.result.os.tag);

    const install_daemon = b.addInstallArtifact(daemon_exe, .{});
    const build_provider_bridge = b.addSystemCommand(&.{
        "bun",
        "build",
        "src/providers/provider_bridge.ts",
        "--target=node",
        "--outfile",
    });
    build_provider_bridge.setCwd(b.path("../desktop"));
    build_provider_bridge.addFileInput(b.path("../desktop/src/providers/provider_bridge.ts"));
    const provider_bridge_output = build_provider_bridge.addOutputFileArg("provider_bridge.mjs");
    const install_provider_bridge = b.addInstallFileWithDir(
        provider_bridge_output,
        .{ .custom = "share/verde" },
        "provider_bridge.mjs",
    );

    b.getInstallStep().dependOn(&install_daemon.step);
    b.getInstallStep().dependOn(&install_provider_bridge.step);
    const daemon_step = b.step("daemon", "Build and install the GUI-free Verde daemon");
    daemon_step.dependOn(&install_daemon.step);
    daemon_step.dependOn(&install_provider_bridge.step);

    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("../desktop/src/daemon_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &daemon_imports,
        }),
    });
    configureDaemonArtifact(daemon_tests, target.result.os.tag);
    const daemon_test_step = b.step("daemon-test", "Run GUI-free Verde daemon tests");
    addTestArtifact(b, daemon_test_step, daemon_tests, target);
}

fn configureDaemonArtifact(compile: *std.Build.Step.Compile, os_tag: std.Target.Os.Tag) void {
    compile.build_id = .sha1;
    compile.each_lib_rpath = false;
    compile.root_module.link_libc = true;
    if (os_tag == .linux) compile.root_module.linkSystemLibrary("util", .{});
}

fn addTestArtifact(
    b: *std.Build,
    step: *std.Build.Step,
    tests: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    _ = tests.getEmittedBin();
    const host = b.graph.host.result;
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        step.dependOn(&b.addRunArtifact(tests).step);
    } else {
        step.dependOn(&tests.step);
    }
}
