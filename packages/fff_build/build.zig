//! Shared fff-c build helpers. No desktop runtime or GUI dependency.
const std = @import("std");

pub fn build(_: *std.Build) void {}

/// Build the vendored C ABI library with the shared release/toolchain settings.
pub fn addFffBuild(
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

/// Link an artifact to a target-matched fff-c library.
pub fn addFffLink(
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

/// Return the Rust target triple for a supported Windows ABI.
pub fn windowsRustTarget(target: std.Target) ?[]const u8 {
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

/// Locate the default Windows import library for the selected ABI.
pub fn defaultWindowsFffImportLibrary(
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

/// Return the library filename installed beside each executable.
pub fn fffRuntimeName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .windows => "fff_c.dll",
        .macos => "libfff_c.dylib",
        else => "libfff_c.so",
    };
}
