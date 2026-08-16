const std = @import("std");

/// Standalone headless package build: std-only tests with no desktop GUI deps.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const headless_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Keep the module referenced so future library artifacts can import it.
    _ = headless_module;

    const test_step = b.step("test", "Run headless package unit tests");
    // Alias used by the monorepo root step name.
    const headless_test_step = b.step("headless-test", "Run headless package unit tests");

    // Mirror packages/desktop/build.zig: foreign test binaries are compile-only.
    // Never invoke Wine/binfmt implicitly for a non-host target.
    const host = b.graph.host.result;
    // Keep a real linked artifact in the cache. Without an emitted-bin
    // consumer Zig can reduce a compile-only test to `-fno-emit-bin`.
    _ = tests.getEmittedBin();
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        headless_test_step.dependOn(&run_tests.step);
    } else {
        test_step.dependOn(&tests.step);
        headless_test_step.dependOn(&tests.step);
    }
}
