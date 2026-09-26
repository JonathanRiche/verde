const std = @import("std");
const fff = @import("fff_build");

/// Dependency-isolated build for the standalone Verde daemon.
pub fn build(b: *std.Build) void {
    // Standalone daemon artifacts deploy to other machines (VMs, containers),
    // so they must never inherit the build host's CPU features: a host with
    // AVX-512 would emit instructions that SIGILL on a lesser deployment CPU.
    // Default to the architecture baseline; opt back into host tuning with an
    // explicit `-Dcpu=native`.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const build_fff = b.option(bool, "build-fff", "Build fff-c with Cargo") orelse true;
    const cargo_target = b.option([]const u8, "fff-cargo-target", "Rust target for fff-c") orelse
        b.graph.environ_map.get("VERDE_FFF_CARGO_TARGET") orelse fff.windowsRustTarget(target.result);
    const lib_dir = b.option([]const u8, "fff-lib-dir", "Target-matched fff-c library directory") orelse
        b.graph.environ_map.get("VERDE_FFF_LIB_DIR") orelse
        if (cargo_target) |t| b.pathJoin(&.{ "../../vendor/fff/target", t, "release" }) else "../../vendor/fff/target/release";
    const import_lib = b.option([]const u8, "fff-import-lib", "Windows fff-c import library") orelse
        b.graph.environ_map.get("VERDE_FFF_IMPORT_LIB") orelse fff.defaultWindowsFffImportLibrary(b, target.result, lib_dir);
    const runtime_lib = b.option([]const u8, "fff-runtime-lib", "Target-matched fff-c runtime") orelse
        b.graph.environ_map.get("VERDE_FFF_RUNTIME_LIB") orelse b.pathJoin(&.{ lib_dir, fff.fffRuntimeName(target.result.os.tag) });
    // A native Rust library cannot satisfy a cross-target/glibc-pinned deployment.
    // The container builder supplies a cargo-zigbuild library for those targets.
    if (build_fff and (target.query.glibc_version != null or
        target.result.cpu.arch != b.graph.host.result.cpu.arch or target.result.os.tag != b.graph.host.result.os.tag))
        @panic("Cross-target daemon builds need -Dbuild-fff=false and -Dfff-lib-dir pointing to a target-matched fff-c library (see docs/daemon-deployment.md)");
    const cargo = if (build_fff) fff.addFffBuild(b, b.path("../../vendor/fff"), target, cargo_target) else null;
    const version = b.option([]const u8, "version", "Version embedded in verde-daemon") orelse
        b.graph.environ_map.get("VERDE_VERSION") orelse
        "0.0.0";
    const version_z: [:0]const u8 = b.allocator.dupeSentinel(u8, version, 0) catch @panic("OOM");

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });
    // Terminal sessions live in the daemon, so it needs libghostty-vt too.
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"app-runtime" = .none,
        .@"emit-lib-vt" = true,
        .@"emit-xcframework" = false,
    });
    const toml_module = b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml");
    const headless_module = b.createModule(.{
        .root_source_file = b.path("../headless/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const remote_module = b.createModule(.{
        .root_source_file = b.path("../client_core/src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "headless", .module = headless_module }},
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
        .{ .name = "ghostty-vt", .module = ghostty.module("ghostty-vt") },
        .{ .name = "headless", .module = headless_module },
        .{ .name = "verde_remote", .module = remote_module },
        .{ .name = "toml", .module = toml_module },
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
    if (cargo) |run| daemon_exe.step.dependOn(&run.step);
    daemon_exe.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    fff.addFffLink(daemon_exe, target.result.os.tag, lib_dir, import_lib);

    const install_daemon = b.addInstallArtifact(daemon_exe, .{});
    const install_fff = b.addInstallBinFile(.{ .cwd_relative = runtime_lib }, fff.fffRuntimeName(target.result.os.tag));
    if (cargo) |run| install_fff.step.dependOn(&run.step);
    install_daemon.step.dependOn(&install_fff.step);
    const install_fff_license = b.addInstallFileWithDir(b.path("../../vendor/fff/LICENSE"), .{ .custom = "share/verde/licenses" }, "fff-LICENSE.txt");
    install_daemon.step.dependOn(&install_fff_license.step);
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
    // Hermetic suites (client_core `contract`) need only the executable; the
    // provider bridge bundle requires installed JS dependencies.
    const daemon_exe_step = b.step("daemon-exe", "Build and install only the verde-daemon executable");
    daemon_exe_step.dependOn(&install_daemon.step);

    const daemon_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("../desktop/src/daemon_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &daemon_imports,
        }),
    });
    configureDaemonArtifact(daemon_tests, target.result.os.tag);
    daemon_tests.each_lib_rpath = true;
    if (cargo) |run| daemon_tests.step.dependOn(&run.step);
    daemon_tests.root_module.addIncludePath(b.path("../../vendor/fff/crates/fff-c/include"));
    fff.addFffLink(daemon_tests, target.result.os.tag, lib_dir, import_lib);
    const daemon_test_step = b.step("daemon-test", "Run GUI-free Verde daemon tests");
    addTestArtifact(b, daemon_test_step, daemon_tests, target);
}

fn configureDaemonArtifact(compile: *std.Build.Step.Compile, os_tag: std.Target.Os.Tag) void {
    compile.build_id = .sha1;
    compile.each_lib_rpath = false;
    compile.root_module.link_libc = true;
    switch (os_tag) {
        .linux => compile.root_module.addRPathSpecial("$ORIGIN"),
        .macos => compile.root_module.addRPathSpecial("@executable_path"),
        else => {},
    }
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
