const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const palette_mod = b.addModule("palette", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "palette-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    const text_area_lab = addExample(b, .{
        .name = "palette-text-area-lab",
        .root_source_file = "examples/text_area_lab_main.zig",
        .linux_root_source_file = "examples/text_area_lab.zig",
        .linux_c_source_file = "examples/linux_main.c",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const component_lab = addExample(b, .{
        .name = "palette-component-lab",
        .root_source_file = "examples/component_lab_main.zig",
        .linux_root_source_file = "examples/component_lab.zig",
        .linux_c_source_file = "examples/linux_component_lab_main.c",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const layout_lab = addExample(b, .{
        .name = "palette-layout-lab",
        .root_source_file = "examples/layout_lab_main.zig",
        .linux_root_source_file = "examples/layout_lab.zig",
        .linux_c_source_file = "examples/linux_layout_lab_main.c",
        .link_image_loader = true,
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const composer_prompt_lab = addExample(b, .{
        .name = "palette-composer-prompt-lab",
        .root_source_file = "examples/composer_prompt_lab_main.zig",
        .linux_root_source_file = "examples/composer_prompt_lab.zig",
        .linux_c_source_file = "examples/linux_composer_prompt_lab_main.c",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const font_loading_check = addExample(b, .{
        .name = "palette-font-loading-check",
        .root_source_file = "examples/font_loading_check_main.zig",
        .linux_root_source_file = "examples/font_loading_check.zig",
        .linux_c_source_file = "examples/linux_font_loading_check_main.c",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const layout_review = addCliExample(b, .{
        .name = "palette-layout-review",
        .root_source_file = "examples/layout_review.zig",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const composer_prompt_review = addCliExample(b, .{
        .name = "palette-composer-prompt-review",
        .root_source_file = "examples/composer_prompt_review.zig",
        .target = target,
        .optimize = optimize,
        .palette_mod = palette_mod,
    });
    const run_text_area_lab_step = b.step("run-text-area-lab", "Run the Text/TextArea component lab");
    const run_component_lab_step = b.step("run-component-lab", "Run the retained component visual lab");
    const run_layout_lab_step = b.step("run-layout-lab", "Run the runtime layout visual lab");
    const run_composer_prompt_lab_step = b.step("run-composer-prompt-lab", "Run the composer prompt visual lab");
    const run_layout_review_step = b.step("run-layout-review", "Run the runtime layout review example");
    const run_composer_prompt_review_step = b.step("run-composer-prompt-review", "Run the composer prompt review example");
    const examples_step = b.step("examples", "Build palette examples");
    wireExampleRun(b, text_area_lab, run_text_area_lab_step, examples_step);
    wireExampleRun(b, component_lab, run_component_lab_step, examples_step);
    wireExampleRun(b, layout_lab, run_layout_lab_step, examples_step);
    wireExampleRun(b, composer_prompt_lab, run_composer_prompt_lab_step, examples_step);
    wireExampleRun(b, layout_review, run_layout_review_step, examples_step);
    wireExampleRun(b, composer_prompt_review, run_composer_prompt_review_step, examples_step);
    examples_step.dependOn(font_loading_check.step);

    const component_catalog_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/component_catalog.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "palette", .module = palette_mod },
            },
        }),
    });
    examples_step.dependOn(&b.addRunArtifact(component_catalog_tests).step);

    const test_step = b.step("test", "Run unit tests");
    const gpu_backends_step = b.step("test-gpu-backends", "Validate SDL_GPU Vulkan/Metal renderer coverage");
    const compile_shader_steps = compileGpuShaders(b);
    const exe_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_tests = b.addTest(.{
        .root_module = exe_tests_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    exe_tests.step.dependOn(compile_shader_steps);
    test_step.dependOn(&run_exe_tests.step);
    gpu_backends_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&b.addRunArtifact(component_catalog_tests).step);
    const layout_review_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/layout_review.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "palette", .module = palette_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(layout_review_tests).step);
    const composer_prompt_review_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/composer_prompt_review.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "palette", .module = palette_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(composer_prompt_review_tests).step);
    const run_font_loading_check = if (font_loading_check.artifact) |artifact|
        b.addRunArtifact(artifact)
    else blk: {
        const run_check = b.addSystemCommand(&.{font_loading_check.output_path});
        run_check.step.dependOn(font_loading_check.step);
        break :blk run_check;
    };
    test_step.dependOn(&run_font_loading_check.step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" } });
    test_step.dependOn(&fmt_check.step);
}

const ExampleOptions = struct {
    name: []const u8,
    root_source_file: []const u8,
    linux_root_source_file: []const u8,
    linux_c_source_file: []const u8,
    link_image_loader: bool = false,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    palette_mod: *std.Build.Module,
};

const CliExampleOptions = struct {
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    palette_mod: *std.Build.Module,
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
                .{ .name = "palette", .module = options.palette_mod },
            },
        }),
    });
    linkSdl(exe.root_module, options.target.result.os.tag);
    if (options.link_image_loader) linkBundledImageLoader(b, exe.root_module);
    return .{
        .artifact = exe,
        .step = &exe.step,
        .output_path = b.fmt("zig-out/bin/{s}", .{options.name}),
    };
}

fn addCliExample(b: *std.Build, options: CliExampleOptions) Example {
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.root_source_file),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "palette", .module = options.palette_mod },
            },
        }),
    });
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

fn compileGpuShaders(b: *std.Build) *std.Build.Step {
    const step = b.step("compile-gpu-shaders", "Compile Palette Vulkan SPIR-V shader assets");
    const shaders = [_]struct {
        stage: []const u8,
        input: []const u8,
        output: []const u8,
    }{
        .{ .stage = "vertex", .input = "src/shaders/ui.vert.glsl", .output = "src/shaders/ui.vert.spv" },
        .{ .stage = "fragment", .input = "src/shaders/ui.solid.frag.glsl", .output = "src/shaders/ui.solid.frag.spv" },
        .{ .stage = "fragment", .input = "src/shaders/ui.text.frag.glsl", .output = "src/shaders/ui.text.frag.spv" },
    };
    for (shaders) |shader| {
        const compile = b.addSystemCommand(&.{
            "glslc",
            b.fmt("-fshader-stage={s}", .{shader.stage}),
            shader.input,
            "-o",
            shader.output,
        });
        step.dependOn(&compile.step);
    }
    return step;
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
        "palette",
        "-fno-entry",
        b.fmt("-Mroot={s}", .{options.linux_root_source_file}),
        "-Mpalette=src/root.zig",
        b.fmt("-femit-bin={s}", .{object_path}),
    });
    build_obj.step.dependOn(&mkdir.step);

    var link = b.addSystemCommand(&.{
        "cc",
        "-no-pie",
        object_path,
        options.linux_c_source_file,
    });
    if (options.link_image_loader) link.addArg("vendor/stb_image_impl.c");
    link.addArgs(&.{
        "-lSDL3",
        "-lSDL3_ttf",
        "-lm",
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

fn linkBundledImageLoader(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("vendor"));
    module.addCSourceFile(.{ .file = b.path("vendor/stb_image_impl.c"), .flags = &.{} });
    module.link_libc = true;
}

pub fn linkImageLoader(palette_dependency: *std.Build.Dependency, module: *std.Build.Module) void {
    module.addIncludePath(palette_dependency.path("vendor"));
    module.addCSourceFile(.{ .file = palette_dependency.path("vendor/stb_image_impl.c"), .flags = &.{} });
    module.link_libc = true;
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
            linkSdlPkgConfig(module);
        },
        .macos => {
            linkSdlPkgConfig(module);
            module.linkFramework("Metal", .{});
            module.linkFramework("QuartzCore", .{});
        },
        else => {
            module.linkSystemLibrary("SDL3", .{});
            module.linkSystemLibrary("SDL3_ttf", .{});
        },
    }
}

fn linkSdlPkgConfig(module: *std.Build.Module) void {
    module.linkSystemLibrary("sdl3", .{ .use_pkg_config = .yes });
    module.linkSystemLibrary("sdl3-ttf", .{ .use_pkg_config = .yes });
}
