const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zgui = b.dependency("zgui", .{
        .shared = false,
        .use_wchar32 = true,
    });

    const module = b.addModule("zgui_text_select", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, module, target, zgui);

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureModule(b, tests.root_module, target, zgui);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}

fn configureModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    zgui: *std.Build.Dependency,
) void {
    const cflags = &.{
        "-std=c++17",
        "-fno-sanitize=undefined",
        "-Wno-error=date-time",
        "-Wno-elaborated-enum-base",
    };

    module.link_libc = true;
    if (target.result.abi != .msvc) {
        module.link_libcpp = true;
    }
    module.linkLibrary(zgui.artifact("imgui"));
    module.addIncludePath(zgui.path("libs"));
    module.addIncludePath(zgui.path("libs/imgui"));
    module.addIncludePath(b.path("vendor/ImGuiTextSelect"));
    module.addCSourceFile(.{
        .file = b.path("src/zgui_text_select.cpp"),
        .flags = cflags,
    });
    module.addCSourceFile(.{
        .file = b.path("vendor/ImGuiTextSelect/textselect.cpp"),
        .flags = cflags,
    });
}
