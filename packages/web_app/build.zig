const std = @import("std");

/// Standalone web client: Zig HTTP/WebSocket gateway + optional frontend embed path.
pub fn build(b: *std.Build) void {
    // verde-web deploys next to verde-daemon on other machines, so it must
    // never inherit the build host's CPU features (an AVX-512 host would emit
    // instructions that SIGILL on a lesser deployment CPU). Default to the
    // architecture baseline; opt back in with an explicit `-Dcpu=native`.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const headless_module = b.createModule(.{
        .root_source_file = b.path("../headless/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "verde-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "headless", .module = headless_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the Verde web gateway");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "headless", .module = headless_module },
            },
        }),
    });
    _ = tests.getEmittedBin();

    const test_step = b.step("test", "Run web_app unit tests");
    const host = b.graph.host.result;
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    } else {
        test_step.dependOn(&tests.step);
    }
}
