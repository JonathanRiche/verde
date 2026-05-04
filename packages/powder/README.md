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
zig build run-layout-lab
zig build run-layout-review
```

If shader source changes, regenerate the Vulkan SPIR-V assets:

```bash
zig build compile-gpu-shaders
```

## Runtime Layout

Powder components are retained, but controls that expose `setBounds()` can be
laid out every frame. Use `powder.layout` for container-style layout instead of
hand-writing every rect.

The layout package is CPU-only. It does not render anything by itself. It
computes `draw.Rect` values, then either returns those rects to you or applies
them to retained components through `setBounds()`. A typical frame looks like:

```zig
powder.layout.applyFlex(container, config, items, .{ &input, &button });
try input.update(allocator, &event);
try button.update(&event);
try input.render(allocator, &batch);
try button.render(allocator, &batch);
```

Components that currently support direct `applyFlex()` / `applyGrid()` usage are
the controls with runtime bounds: `Button`, `IconButton`, `Select`, `TextInput`,
`Checkbox`, and `Toggle`. For other components, call `powder.layout.flex()` or
`powder.layout.grid()` into a rect array and wire the rects manually once that
component exposes runtime bounds.

### Boxes, Padding, And Margins

Use `powder.layout.Box` when a panel/container needs margin and padding. Margin
shrinks the outer rect; padding shrinks the content rect inside the margin.

```zig
const shell: powder.layout.Box = .{
    .rect = window_rect,
    .margin = powder.layout.Edges.all(12),
    .padding = powder.layout.Edges.xy(16, 10),
};

const content = shell.contentRect();
```

`Edges` helpers:

```zig
powder.layout.Edges.all(8)      // top/right/bottom/left = 8
powder.layout.Edges.xy(12, 6)   // left/right = 12, top/bottom = 6
powder.layout.Edges.axis(12, 6) // same as xy()
```

### Flex Layout

Flex rows and columns support:

- `direction`: `.row` or `.column`
- `wrap`: start a new line/column when children overflow
- `gap`, `row_gap`, `column_gap`
- container `padding`
- item `margin`
- item `grow`
- item `min_w`, `min_h`, `max_w`, `max_h`
- `align_items`: `.start`, `.center`, `.end`, `.stretch`
- `justify_content`: `.start`, `.center`, `.end`, `.space_between`

Use `applyFlex()` when every child is a component with `setBounds()`:

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

Use `flex()` when you want the rects back:

```zig
var rects: [3]powder.Rect = undefined;
powder.layout.flex(
    panel_rect,
    .{ .direction = .row, .wrap = true, .gap = 8 },
    &.{
        powder.layout.FlexItem.fixed(120, 32),
        powder.layout.FlexItem.fixed(120, 32),
        powder.layout.FlexItem.fixed(120, 32),
    },
    &rects,
);
```

`FlexItem.fixed(w, h)` creates a fixed-size item. `FlexItem.fill(h, grow)` is a
convenience for row layouts where width should grow and height is fixed.

### Grid Layout

Grid layout supports:

- fixed pixel tracks: `.{ .px = 120 }`
- fractional tracks: `.{ .fr = 1 }`
- `gap_x`, `gap_y`
- container `padding`
- item `margin`
- `column`, `row`
- `column_span`, `row_span`

Use `applyGrid()` when every child has `setBounds()`:

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

Use `grid()` when you want rects back:

```zig
const columns = [_]powder.layout.Track{ .{ .px = 96 }, .{ .fr = 1 }, .{ .fr = 1 } };
const rows = [_]powder.layout.Track{ .{ .px = 32 }, .{ .px = 32 } };
const cells = [_]powder.layout.GridItem{
    .{ .column = 0, .row = 0 },
    .{ .column = 1, .row = 0, .column_span = 2 },
};
var rects: [cells.len]powder.Rect = undefined;

try powder.layout.grid(
    allocator,
    panel_rect,
    .{ .columns = &columns, .rows = &rows, .gap_x = 8, .gap_y = 8 },
    &cells,
    &rects,
);
```

### Review Example

Run the visual layout lab from `packages/powder`:

```bash
zig build run-layout-lab
```

It opens an SDL window with a resizable shell, padded content regions, a grid
row, a growing flex prompt row, and a wrapping flex row. Orange, blue, and green
outlines show the shell, content, and padded content rects. Resize the window to
verify that the retained controls move, stretch, and wrap while hit testing and
rendering stay aligned.

Run the layout review example from `packages/powder`:

```bash
zig build run-layout-review
```

It builds a Verde-style prompt area with provider/model/reasoning selects, a
fast toggle, a prompt input, and a send button. The example prints each computed
rect and renders the retained controls into a `RenderBatch`, so it catches both
layout and component integration regressions without opening a window.

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
