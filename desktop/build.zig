const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zgui = b.dependency("zgui", .{
        .backend = .sdl3_opengl3,
        .shared = false,
    });
    const zsdl = b.dependency("zsdl", .{});
    const imgui = zgui.artifact("imgui");

    // zgui's sdl3_opengl3 backend currently adds the nested SDL3 include dir,
    // but imgui_impl_sdl3.cpp includes <SDL3/SDL.h> and needs the parent root.
    if (target.result.os.tag == .macos) {
        imgui.root_module.addIncludePath(zsdl.path("libs/sdl3/include"));
    }

    const exe = b.addExecutable(.{
        .name = "verde",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgui", .module = zgui.module("root") },
                .{ .name = "zsdl3", .module = zsdl.module("zsdl3") },
            },
        }),
    });
    exe.linkLibrary(imgui);
    exe.linkLibC();
    exe.root_module.addIncludePath(b.path("src/vendor"));
    exe.addCSourceFile(.{
        .file = b.path("src/vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    switch (target.result.os.tag) {
        .linux => {
            exe.linkSystemLibrary("SDL3");
            exe.linkSystemLibrary("GL");
        },
        .windows => {
            exe.linkSystemLibrary("SDL3");
            exe.linkSystemLibrary("opengl32");
        },
        .macos => {
            if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
                exe.addFrameworkPath(sdl3_prebuilt.path("Frameworks"));
            }
            exe.linkFramework("SDL3");
            exe.linkFramework("OpenGL");
        },
        else => {},
    }

    switch (target.result.os.tag) {
        .linux => exe.root_module.addRPathSpecial("$ORIGIN"),
        .macos => exe.root_module.addRPathSpecial("@executable_path"),
        else => {},
    }

    b.installArtifact(exe);
    if (target.result.os.tag == .macos) {
        if (zsdl.builder.lazyDependency("sdl3_prebuilt_macos", .{})) |sdl3_prebuilt| {
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = sdl3_prebuilt.path("Frameworks/SDL3.framework"),
                .install_dir = .bin,
                .install_subdir = "SDL3.framework",
            }).step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_tests.root_module.addIncludePath(b.path("src/vendor"));
    exe_tests.addCSourceFile(.{
        .file = b.path("src/vendor/stb_image_impl.c"),
        .flags = &.{},
    });
    exe_tests.linkLibC();
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}
