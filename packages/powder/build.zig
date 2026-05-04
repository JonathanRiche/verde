const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const powder_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "powder",
        .use_lld = if (target.result.os.tag == .linux) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "powder", .module = powder_mod },
            },
        }),
    });
    linkSdl(exe.root_module, target.result.os.tag);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const text_area_lab = addExample(b, .{
        .name = "powder-text-area-lab",
        .root_source_file = "examples/text_area_lab_main.zig",
        .linux_root_source_file = "examples/text_area_lab.zig",
        .linux_c_source_file = "examples/linux_main.c",
        .target = target,
        .optimize = optimize,
        .powder_mod = powder_mod,
    });
    const component_lab = addExample(b, .{
        .name = "powder-component-lab",
        .root_source_file = "examples/component_lab_main.zig",
        .linux_root_source_file = "examples/component_lab.zig",
        .linux_c_source_file = "examples/linux_component_lab_main.c",
        .target = target,
        .optimize = optimize,
        .powder_mod = powder_mod,
    });
    const run_text_area_lab_step = b.step("run-text-area-lab", "Run the Text/TextArea component lab");
    const run_component_lab_step = b.step("run-component-lab", "Run the retained component visual lab");
    const examples_step = b.step("examples", "Build powder examples");
    wireExampleRun(b, text_area_lab, run_text_area_lab_step, examples_step);
    wireExampleRun(b, component_lab, run_component_lab_step, examples_step);

    const component_catalog_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/component_catalog.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "powder", .module = powder_mod },
            },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(component_catalog_tests).step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(component_catalog_tests).step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}

const ExampleOptions = struct {
    name: []const u8,
    root_source_file: []const u8,
    linux_root_source_file: []const u8,
    linux_c_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    powder_mod: *std.Build.Module,
};

const Example = struct {
    artifact: ?*std.Build.Step.Compile = null,
    step: *std.Build.Step,
    output_path: []const u8,
};

fn addExample(b: *std.Build, options: ExampleOptions) Example {
    if (options.target.result.os.tag == .linux) {
        return addLinuxExample(b, options);
    }

    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.root_source_file),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "powder", .module = options.powder_mod },
            },
        }),
    });
    linkSdl(exe.root_module, options.target.result.os.tag);
    return .{
        .artifact = exe,
        .step = &exe.step,
        .output_path = b.fmt("zig-out/bin/{s}", .{options.name}),
    };
}

fn wireExampleRun(b: *std.Build, example: Example, run_step: *std.Build.Step, examples_step: *std.Build.Step) void {
    if (example.artifact) |artifact| {
        const run_example = b.addRunArtifact(artifact);
        if (b.args) |args| {
            run_example.addArgs(args);
        }
        run_step.dependOn(&run_example.step);
        examples_step.dependOn(&artifact.step);
    } else {
        const run_example = b.addSystemCommand(&.{example.output_path});
        if (b.args) |args| {
            run_example.addArgs(args);
        }
        run_example.step.dependOn(example.step);
        run_step.dependOn(&run_example.step);
        examples_step.dependOn(example.step);
    }
}

fn addLinuxExample(b: *std.Build, options: ExampleOptions) Example {
    const out_dir = "zig-out/bin";
    const object_path = b.fmt("{s}/{s}.o", .{ out_dir, options.name });
    const output_path = b.fmt("{s}/{s}", .{ out_dir, options.name });

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", out_dir });

    const build_obj = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-obj",
        optimizeArg(b, options.optimize),
        "--dep",
        "powder",
        "-fno-entry",
        b.fmt("-Mroot={s}", .{options.linux_root_source_file}),
        "-Mpowder=src/root.zig",
        b.fmt("-femit-bin={s}", .{object_path}),
    });
    build_obj.step.dependOn(&mkdir.step);

    const link = b.addSystemCommand(&.{
        "cc",
        "-no-pie",
        object_path,
        options.linux_c_source_file,
        "-lSDL3",
        "-lSDL3_ttf",
        "-lc",
        "-o",
        output_path,
    });
    link.step.dependOn(&build_obj.step);

    return .{
        .step = &link.step,
        .output_path = output_path,
    };
}

fn optimizeArg(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    _ = b;
    return switch (optimize) {
        .Debug => "-ODebug",
        .ReleaseSafe => "-OReleaseSafe",
        .ReleaseFast => "-OReleaseFast",
        .ReleaseSmall => "-OReleaseSmall",
    };
}

fn linkSdl(module: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    module.linkSystemLibrary("c", .{});
    switch (os_tag) {
        .linux => {
            module.linkSystemLibrary("SDL3", .{ .use_pkg_config = .yes });
            module.linkSystemLibrary("SDL3_ttf", .{ .use_pkg_config = .yes });
        },
        .macos => {
            module.linkFramework("SDL3", .{});
            module.linkFramework("SDL3_ttf", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("QuartzCore", .{});
        },
        else => {
            module.linkSystemLibrary("SDL3", .{});
            module.linkSystemLibrary("SDL3_ttf", .{});
        },
    }
}
