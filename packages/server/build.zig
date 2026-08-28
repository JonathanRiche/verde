const std = @import("std");

/// Dependency-light operator CLI for the standalone Verde runtime.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version embedded in verde-server") orelse
        b.graph.environ_map.get("VERDE_VERSION") orelse
        "0.0.0";
    const version_z: [:0]const u8 = b.allocator.dupeSentinel(u8, version, 0) catch @panic("OOM");
    const build_options = b.addOptions();
    build_options.addOption([:0]const u8, "version", version_z);

    const imports = [_]std.Build.Module.Import{
        .{ .name = "build_options", .module = build_options.createModule() },
    };
    const exe = b.addExecutable(.{
        .name = "verde-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const server_step = b.step("server", "Build and install verde-server");
    server_step.dependOn(b.getInstallStep());

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    tests.root_module.link_libc = true;
    _ = tests.getEmittedBin();
    const test_step = b.step("test", "Run verde-server unit tests");
    const host = b.graph.host.result;
    const is_native = target.result.os.tag == host.os.tag and
        target.result.cpu.arch == host.cpu.arch and
        target.result.abi == host.abi;
    if (is_native) {
        test_step.dependOn(&b.addRunArtifact(tests).step);
    } else {
        test_step.dependOn(&tests.step);
    }
}
