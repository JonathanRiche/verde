//! Build graph for the Verde mobile client core (`libverde_client`).
//!
//! Steps:
//! - `test`: Zig unit tests plus a C smoke test of `include/verde_client.h`
//!   against the host shared library.
//! - `android-libs`: `libverde_client.so` for arm64-v8a and x86_64 against the
//!   NDK sysroot (`ANDROID_NDK_HOME` or `-Dandroid-ndk`), installed to
//!   `zig-out/lib/android/<abi>/` and checked for allowed NEEDED entries.
//! - `ios-xcframework`: device + simulator arm64 static libraries packaged
//!   as `zig-out/lib/VerdeClient.xcframework` (macOS with Xcode).

const std = @import("std");
const zon = @import("build.zig.zon");

const lib_name = "verde_client";
/// Matches the Android app's minSdk (Android 10).
const android_api_level: u32 = 29;
/// Android 15+ devices may use 16 KB pages; Play requires aligned segments.
const android_page_size: u64 = 16 * 1024;

const AndroidAbi = struct {
    /// Directory name under `jniLibs/`.
    name: []const u8,
    arch: std.Target.Cpu.Arch,
    /// NDK sysroot triple directory.
    triple: []const u8,
};

const android_abis = [_]AndroidAbi{
    .{ .name = "arm64-v8a", .arch = .aarch64, .triple = "aarch64-linux-android" },
    .{ .name = "x86_64", .arch = .x86_64, .triple = "x86_64-linux-android" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ndk_option = b.option([]const u8, "android-ndk", "Android NDK root (default: $ANDROID_NDK_HOME)");

    const options = b.addOptions();
    options.addOption([:0]const u8, "version", zon.version);

    addModelSteps(b, options);
    addIosSteps(b, optimize, options);
    const headless = b.createModule(.{
        .root_source_file = b.path("../headless/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const remote = b.addModule("verde_remote", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "headless", .module = headless }},
    });
    addTestStep(b, target, optimize, options, remote);
    addAndroidStep(b, optimize, options, ndk_option orelse b.graph.environ_map.get("ANDROID_NDK_HOME"));
}

fn addTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    remote: *std.Build.Module,
) void {
    const test_step = b.step("test", "Run unit tests and the C ABI smoke test");
    const remote_tests = b.addTest(.{ .root_module = remote, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(remote_tests).step);

    const unit_tests = b.addTest(.{
        .root_module = createCoreModule(b, target, optimize, options),
        .use_llvm = true,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const host_lib = addCoreLibrary(b, createCoreModule(b, target, optimize, options));
    const smoke_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_module.addIncludePath(b.path("include"));
    smoke_module.addCSourceFile(.{ .file = b.path("tests/abi_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Werror" } });
    smoke_module.linkLibrary(host_lib);
    const smoke = b.addExecutable(.{ .name = "abi_smoke", .root_module = smoke_module, .use_llvm = true });
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.addArg(zon.version);
    run_smoke.expectExitCode(0);
    test_step.dependOn(&run_smoke.step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    test_step.dependOn(&fmt_check.step);
}

fn addAndroidStep(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    ndk_root: ?[]const u8,
) void {
    const android_step = b.step("android-libs", "Build libverde_client.so for Android arm64-v8a and x86_64");
    const ndk = ndk_root orelse {
        android_step.dependOn(&b.addFail("android-libs needs the Android NDK: set ANDROID_NDK_HOME or pass -Dandroid-ndk=<path>").step);
        return;
    };
    const host_tag = switch (b.graph.host.result.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        else => {
            android_step.dependOn(&b.addFail("android-libs supports Linux and macOS build hosts only").step);
            return;
        },
    };
    const prebuilt = b.pathJoin(&.{ ndk, "toolchains", "llvm", "prebuilt", host_tag });
    const sysroot = b.pathJoin(&.{ prebuilt, "sysroot" });
    const readelf = b.pathJoin(&.{ prebuilt, "bin", "llvm-readelf" });
    const libc_files = b.addWriteFiles();

    for (android_abis) |abi| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = abi.arch,
            .os_tag = .linux,
            .abi = .android,
            .android_api_level = android_api_level,
        });
        const lib = addCoreLibrary(b, createCoreModule(b, target, optimize, options));
        lib.setLibCFile(libc_files.add(
            b.fmt("libc-{s}.txt", .{abi.triple}),
            androidLibcFile(b, sysroot, abi.triple),
        ));
        lib.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/lib", abi.triple, "29" }) });
        lib.link_z_max_page_size = android_page_size;
        lib.link_z_common_page_size = android_page_size;

        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("lib/android/{s}", .{abi.name}) } },
        });
        android_step.dependOn(&install.step);

        const check = b.addSystemCommand(&.{"bash"});
        check.addFileArg(b.path("scripts/check-android-lib.sh"));
        check.addArg(readelf);
        check.addFileArg(lib.getEmittedBin());
        check.setName(b.fmt("check {s} {s}", .{ lib_name, abi.name }));
        check.expectExitCode(0);
        android_step.dependOn(&check.step);
    }
}

/// SDK discovery and packaging run only when explicitly requested, so host
/// tests and Android builds do not require Xcode (even on macOS).
fn addIosSteps(b: *std.Build, optimize: std.builtin.OptimizeMode, options: *std.Build.Step.Options) void {
    const package_step = b.step("ios-xcframework", "Package the iOS device and simulator libraries (requires Xcode)");
    const package = b.addSystemCommand(&.{"bash"});
    package.addFileArg(b.path("scripts/build-ios-xcframework.sh"));
    package.addArg(b.graph.zig_exe);
    package.addArg(@tagName(optimize));
    package.addArg(b.install_prefix);
    package.setCwd(b.path("."));
    package_step.dependOn(&package.step);

    // The packaging script supplies the SDKs discovered by xcrun. Keeping the
    // libraries in the build graph shares core module wiring with other targets.
    const libs_step = b.step("ios-libs", "Build iOS static libraries with explicit SDK paths");
    const device_sdk = b.option([]const u8, "ios-sdk", "iPhoneOS SDK path");
    const simulator_sdk = b.option([]const u8, "ios-simulator-sdk", "iPhoneSimulator SDK path");
    if (device_sdk == null or simulator_sdk == null) {
        libs_step.dependOn(&b.addFail("ios-libs needs -Dios-sdk and -Dios-simulator-sdk; use ios-xcframework for automatic discovery").step);
        return;
    }
    const slices = .{
        .{ "device", std.Target.Abi.none, device_sdk.? },
        .{ "simulator", std.Target.Abi.simulator, simulator_sdk.? },
    };
    inline for (slices) |slice| {
        const target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .abi = slice[1],
            .os_version_min = .{ .semver = .{ .major = 17, .minor = 0, .patch = 0 } },
        });
        const module = createCoreModule(b, target, optimize, options);
        module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ slice[2], "usr/include" }) });
        module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ slice[2], "usr/lib" }) });
        module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ slice[2], "System/Library/Frameworks" }) });
        const lib = b.addLibrary(.{
            .name = lib_name,
            .linkage = .static,
            .root_module = module,
            .use_llvm = true,
            // Zig 0.16 rejects LLD for Mach-O, including static archives.
            .use_lld = false,
        });
        // Swift's linker does not supply Zig's f128 JSON-decoding helpers.
        // Ship compiler-rt inside each self-contained static archive.
        lib.bundle_compiler_rt = true;
        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = "lib/ios/" ++ slice[0] } },
        });
        libs_step.dependOn(&install.step);
    }
}

fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const headless = b.createModule(.{ .root_source_file = b.path("../headless/src/root.zig"), .target = target, .optimize = optimize });
    const remote = b.createModule(.{ .root_source_file = b.path("src/shared/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "headless", .module = headless }} });
    module.addImport("verde_remote", remote);
    module.addImport("headless", headless);
    if (target.result.abi.isAndroid()) module.linkSystemLibrary("log", .{});
    module.addOptions("build_options", options);
    return module;
}

/// Shared library with an unversioned soname, built with LLVM (the
/// self-hosted x86 backend miscompiles Verde code).
fn addCoreLibrary(b: *std.Build, module: *std.Build.Module) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = lib_name,
        .linkage = .dynamic,
        .root_module = module,
        .use_llvm = true,
        .use_lld = true,
    });
}

/// Zig libc installation file pointing at the NDK's bionic headers and the
/// API-level crt objects / stub libraries.
fn androidLibcFile(b: *std.Build, sysroot: []const u8, triple: []const u8) []const u8 {
    return b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include/{s}
        \\crt_dir={s}/usr/lib/{s}/{d}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, triple, sysroot, triple, android_api_level });
}

/// Reflection runs at comptime; generated cache files are compared without touching sources.
fn addModelSteps(b: *std.Build, options: *std.Build.Step.Options) void {
    // Use the core's module wiring so registry entries can refer to shared types.
    const module = createCoreModule(b, b.graph.host, .ReleaseSafe, options);
    module.root_source_file = b.path("src/generate_models.zig");
    const generator = b.addExecutable(.{ .name = "generate-models", .root_module = module, .use_llvm = true });
    const kotlin_run = b.addRunArtifact(generator);
    kotlin_run.addArg("kotlin");
    const kotlin = kotlin_run.captureStdOut(.{});
    const swift_run = b.addRunArtifact(generator);
    swift_run.addArg("swift");
    const swift = swift_run.captureStdOut(.{});
    for ([_][]const u8{ "generate", "check" }) |mode| {
        const run = b.addSystemCommand(&.{"bash"});
        run.addFileArg(b.path("scripts/models.sh"));
        run.addArg(mode);
        run.addFileArg(kotlin);
        run.addArg(b.pathFromRoot("../mobile_android/app/src/main/java/dev/verdeai/core/CoreModels.kt"));
        run.addFileArg(swift);
        run.addArg(b.pathFromRoot("../mobile_ios/App/CoreModels.swift"));
        run.has_side_effects = true;
        b.step(b.fmt("models-{s}", .{mode}), b.fmt("{s} committed Kotlin and Swift models", .{mode})).dependOn(&run.step);
    }
}
