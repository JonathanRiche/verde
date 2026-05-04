# Powder

Powder is Verde's retained UI component package. It uses Zig, SDL3, SDL3_ttf,
and SDL_GPU.

## Setup

Run all commands in this directory:

```bash
cd packages/powder
```

### macOS

Install Zig plus SDL dependencies with Homebrew:

```bash
brew install zig sdl3 sdl3_ttf pkg-config shaderc
```

`pkg-config` is required because the Powder build links Homebrew's SDL
libraries as normal Unix libraries, not as `.framework` bundles. It tells Zig
where SDL headers and libraries are installed.

Verify discovery before building:

```bash
pkg-config --libs --cflags sdl3 sdl3-ttf
```

That command should print include and library flags. If it prints an error,
check that Homebrew is on your shell path and that `pkg-config` can see
Homebrew's `.pc` files.

### Linux

Install Zig, pkg-config, SDL3, SDL3_ttf, and shaderc from your distro packages.
Package names vary, but the required pkg-config modules are:

```bash
pkg-config --libs --cflags sdl3 sdl3-ttf
```

The shader compiler command used by the build is:

```bash
glslc --version
```

## Build And Test

```bash
zig build test
zig build examples
zig build test-gpu-backends
```

Run the visual labs:

```bash
zig build run-text-area-lab
zig build run-component-lab
```

If shader source changes, regenerate the Vulkan SPIR-V assets:

```bash
zig build compile-gpu-shaders
```

## Runtime Layout

Powder components are retained, but controls that expose `setBounds()` can be
laid out every frame. Use `powder.layout` for container-style layout instead of
hand-writing every rect.

Flex rows and columns support padding, per-item margins, gaps, grow, alignment,
justification, and optional wrapping:

```zig
powder.layout.applyFlex(
    panel_rect,
    .{ .direction = .row, .gap = 8, .padding = powder.layout.Edges.all(12) },
    .{
        powder.layout.FlexItem{ .basis_w = 180, .basis_h = 32, .grow = 1 },
        powder.layout.FlexItem.fixed(72, 32),
    },
    .{ &input, &send_button },
);
```

Grid layout supports fixed pixel tracks, fractional tracks, gaps, spans,
padding, and per-item margins:

```zig
try powder.layout.applyGrid(
    allocator,
    panel_rect,
    .{
        .columns = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
        .rows = &.{ .{ .px = 32 }, .{ .px = 32 } },
        .gap_x = 8,
        .gap_y = 8,
    },
    .{
        powder.layout.GridItem{ .column = 0, .row = 0 },
        powder.layout.GridItem{ .column = 1, .row = 0 },
    },
    .{ &provider_select, &model_select },
);
```

For lower-level control, call `powder.layout.flex()` or `powder.layout.grid()`
to fill an array of `draw.Rect`s, then route those rects into any system that
understands runtime bounds.

## Troubleshooting

If macOS reports `unable to find framework 'SDL3'`, update to a build that uses
pkg-config for SDL, then install:

```bash
brew install sdl3 sdl3_ttf pkg-config
```

If `pkg-config --libs --cflags sdl3 sdl3-ttf` fails on Apple Silicon, make sure
Homebrew's path is active:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

On Intel macOS, Homebrew is usually under `/usr/local` instead.
