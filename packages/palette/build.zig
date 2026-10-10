//! Verde's build of the vendored palette-native package (see VENDORED_FROM).
//!
//! Exposes one `palette` module: retained components plus the platform layer
//! (Wayland / AppKit / Win32), the GPU renderer (Vulkan / Metal / Direct3D 11,
//! all dlopened or OS-provided), the pure-Zig font engine and PNG codec. Only
//! libc is linked, for dlopen. The Wayland protocol bindings are generated at
//! build time from the vendored XML in `protocols/`.
const std = @import("std");

const wayland_protocols = [_][]const u8{
    "wayland.xml",
    "xdg-shell.xml",
    "xdg-decoration-unstable-v1.xml",
    "viewporter.xml",
    "fractional-scale-v1.xml",
    "cursor-shape-v1.xml",
    "tablet-v2.xml",
    "text-input-unstable-v3.xml",
    "primary-selection-unstable-v1.xml",
    "linux-dmabuf-v1.xml",
    "linux-drm-syncobj-v1.xml",
    "xdg-activation-v1.xml",
    "xdg-foreign-unstable-v2.xml",
    "relative-pointer-unstable-v1.xml",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const palette_mod = b.addModule("palette", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // libc only so the GPU backend can dlopen the system Vulkan loader.
        .link_libc = true,
    });

    const scanner = b.addExecutable(.{
        .name = "wayland-scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/wayland-scanner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const gen = b.addRunArtifact(scanner);
    const generated = gen.addOutputFileArg("wayland_protocol.zig");
    for (wayland_protocols) |name| gen.addFileArg(b.path(b.fmt("protocols/{s}", .{name})));
    const protocol_mod = b.createModule(.{ .root_source_file = generated, .target = target, .optimize = optimize });
    palette_mod.addImport("wayland_protocol", protocol_mod);

    // Core unit tests (components, event model, keyboard tables, app glue).
    // The font/gpu/platform area suites live upstream with their fixtures.
    const core_tests = b.addTest(.{
        .root_module = palette_mod,
        .use_llvm = true,
        .use_lld = useLld(target),
    });
    const test_step = b.step("test", "Run Palette core unit tests");
    const run_core_tests = b.addRunArtifact(core_tests);
    // fonts.zig tests load the bundled faces from `../assets/fonts`; Verde ships
    // the same files in packages/desktop/src/assets/fonts.
    run_core_tests.setCwd(b.path("../desktop/src/ui"));
    test_step.dependOn(&run_core_tests.step);
}

/// Zig 0.16's self-hosted ELF linker cannot consume the system crt1.o
/// (.sframe relocations); libc-linked ELF/COFF artifacts link with LLD.
/// Mach-O keeps Zig's own linker.
pub fn useLld(target: std.Build.ResolvedTarget) bool {
    return target.result.ofmt != .macho;
}
