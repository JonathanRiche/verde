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

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run headless package unit tests");
    test_step.dependOn(&run_tests.step);

    // Alias used by the monorepo root step name.
    const headless_test_step = b.step("headless-test", "Run headless package unit tests");
    headless_test_step.dependOn(&run_tests.step);
}
