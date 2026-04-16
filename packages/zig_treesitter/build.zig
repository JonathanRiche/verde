const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zig_treesitter", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, module);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = createRootModule(b, target, optimize),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon", "vendor" } });
    test_step.dependOn(&fmt_check.step);
}

fn createRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, module);
    return module;
}

fn configureModule(b: *std.Build, module: *std.Build.Module) void {
    module.link_libc = true;
    module.linkSystemLibrary("tree-sitter", .{ .use_pkg_config = .force });
    module.addIncludePath(b.path("vendor/tree-sitter-typescript/typescript/src"));
    module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-typescript/typescript/src/parser.c"),
        .flags = &.{},
    });
    module.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter-typescript/typescript/src/scanner.c"),
        .flags = &.{},
    });
}
