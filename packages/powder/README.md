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
zig build run-composer-prompt-lab
zig build run-layout-review
zig build run-composer-prompt-review
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

The layout lab also loads `packages/desktop/src/assets/verde_logo.png` and
renders it as texture-backed Powder image components. The image row shows native
size, contain, cover, stretch, and cropped-UV rendering so you can inspect
quality and fit behavior. It uses `TextureId` plus the SDL texture resolver to
prove that image commands can render through the SDL presenter path.

Run the layout review example from `packages/powder`:

```bash
zig build run-layout-review
```

It builds a Verde-style prompt area with provider/model/reasoning selects, a
fast toggle, a prompt input, and a send button. The example prints each computed
rect and renders the retained controls into a `RenderBatch`, so it catches both
layout and component integration regressions without opening a window.

## Text Metrics And Layout

Powder owns text layout for retained controls. Components do not ask the host to
recompute wrapping, cursor placement, selection rectangles, or scroll offsets.
Instead, the host can provide font metrics and Powder emits laid-out text runs in
the render batch.

Use fixed metrics for monospace/debug renderers:

```zig
const metrics = powder.FontMetrics.fixed(14, 8, 18);

var prompt = try powder.textInput(.{}).init(allocator, "");
prompt.setFontMetrics(metrics);
```

Use a callback when your font atlas has proportional advances:

```zig
fn advance(context: ?*anyopaque, text: []const u8, offset: usize, font_size: f32) powder.FontAdvance {
    const atlas: *Atlas = @ptrCast(@alignCast(context.?));
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return .{ .byte_len = len, .width = atlas.advance(text[offset .. offset + len], font_size) };
}

const metrics: powder.FontMetrics = .{
    .font_size = 14,
    .line_height = 18,
    .ascent = 13,
    .descent = 5,
    .baseline = 14,
    .context = &atlas,
    .advance = advance,
};
```

`TextArea`, `TextInput`, `Button`, `Select`, and `ComposerPrompt` expose
`setFontMetrics()`.
Without explicit metrics, they use the existing fixed fallback derived from
their component config.

Text commands may carry `command.text_runs`. When this slice is non-empty, a
renderer should draw each run at `run.x/run.y` using `run.text`,
`run.font_size`, `run.color`, `run.line_height`, `run.clip`, and optional
`run.font_role` / `run.font_id`. That output is authoritative: it is the same
layout Powder used for hit testing, wrapping, cursor movement, selection, and
scrolling. Hosts should not re-wrap those commands.

Font roles are renderer-neutral:

```zig
pub const FontRole = enum { ui, ui_bold, icon, mono };
```

Component configs expose role fields where text is emitted, such as
`font_role`, `icon_font_role`, `font_id`, and `icon_font_id`. Host renderers map
those roles or ids to their own font atlas. The SDL examples currently fall
back to their configured font when a role-specific font is not provided, but the
role data remains in the batch for app renderers.

## Icons And Compact Controls

Buttons and selects can emit icon text as first-class `TextRun`s. Icons are not
host-side special cases; they are text spans with `font_role = .icon` or a
custom `icon_font_id`.

```zig
const Send = powder.button(.{
    .icon_text = "^",
    .circular = true,
    .font_size = 18,
    .icon_font_role = .icon,
    .background_color = .{ .r = 0.32, .g = 0.54, .b = 0.39, .a = 1 },
});
```

Buttons also support `leading_icon`, `trailing_icon`, `icon_gap`, and centered
or start/end content alignment. `IconButton` can render either a texture-backed
image command or centered icon text.

Use `SelectVariant.compact` for inline toolbar selects:

```zig
const Model = powder.select(.{
    .variant = .compact,
    .left_icon = "O",
    .chevron_icon = ">",
    .item_label = modelLabel,
    .compact_background_color = .{ .a = 0 },
    .compact_border_width = 0,
});
```

Compact selects emit a low/no-alpha background by default, optional hover/open
background, left icon, label text, right chevron, z-indexed dropdown menu, and
font roles for each run.

## Cascade Menus

`powder.select()` is intentionally a flat dropdown. For menus that need child
submenus, use `powder.cascadeMenu()`.

```zig
const Menu = powder.cascadeMenu(.{
    .item_count = 3,
    .item_label = itemLabel,
    .child_count = childCount,
});

var menu = Menu.initFromConfig();
menu.setBounds(.{ .x = x, .y = y, .w = 220, .h = 236 });
_ = menu.handleInput(.open);
try menu.render(allocator, &batch);
```

`item_label(context, path, index)` receives the parent path for the current
menu level. `child_count(context, path, index)` returns how many children that
row owns. For example, the root row at index `0` is called with `path = &.{}`;
its first child row is called with `path = &.{0}`.

Cascade menus are retained components with runtime `setBounds()`, mouse hover,
click, wheel scrolling, keyboard navigation, close-on-outside-click, z-indexed
child panels, and renderer-neutral labels/chevrons emitted as `TextRun`s. Use
`CascadeMenuCallbacks.on_event` to receive `selected`, `highlighted`, and
`open_changed` events.

## Toolbar And Composer Prompt

`powder.toolbar()` is a retained horizontal layout helper for inline command
bars. It computes child rects, supports fixed and flexible item widths,
right-aligned actions, vertical centering, and separator commands.

```zig
const Bar = powder.toolbar(.{ .gap = 8 });
var bar = Bar.init();
bar.setBounds(toolbar_rect);

const items = [_]powder.ToolbarItem{
    powder.ToolbarItem.fixed(132, 32),
    powder.ToolbarItem.flexible(120, 32, 1),
    .{ .width = 36, .height = 36, .right_aligned = true },
};
var rects: [items.len]powder.Rect = undefined;
bar.layout(&items, &rects);
try bar.renderSeparators(allocator, &batch, &items, &rects);
```

For Verde-style command prompts, `powder.composerPrompt()` owns the retained
composer behavior and visual model: rounded shell, multiline text buffer,
placeholder, compact model/reasoning menus, fast/access toggles, toolbar
separators, hover/focus states, icon roles, and send/stop/pending/disabled send
button state.

```zig
const Composer = powder.composerPrompt(.{
    .model_icon = "O",
    .model_label = "GPT-5.5",
    .reasoning_label = "Low",
    .fast_icon = "~",
    .fast_label = "Fast",
    .access_icon = "L",
    .access_label = "Full access",
    .send_icon = "^",
});

var composer = Composer.init();
defer composer.deinit(allocator);
composer.setBounds(prompt_rect);

composer.setCallbacks(.{ .context = app, .on_event = handleComposerEvent });
composer.setModelOptions(app, model_count, modelLabel);
composer.setReasoningOptions(app, reasoning_count, reasoningLabel);
try composer.setText(allocator, draft_text);
try composer.setPlaceholder(allocator, "Ask anything, or use / to show commands");
composer.setSendState(.send);

try composer.update(allocator, &event);
try composer.render(allocator, &batch);
```

The common runtime API:

- `setBounds(rect)` / `bounds()`
- `setText(allocator, value)` / `text()`
- `selection()`, `scrollY()`, `contentHeight()`, `maxScrollY()`
- `setPlaceholder(allocator, value)`
- `setModelLabel()`, `setReasoningLabel()`, `setFastLabel()`,
  `setAccessLabel()`
- `setSendState(.send | .stop | .disabled | .pending)`
- `setModelOptions()` / `setReasoningOptions()` / `setOptions()`
- `setFontMetrics()` for prompt text layout and hit testing
- `setToolbarFontMetrics()` / `setIconFontMetrics()` for measured toolbar pills
- `handleInput(allocator, input)` or SDL `update(allocator, event)`
- `render(allocator, batch)`

Composer events include text changes, submit, model/reasoning click and change,
fast/access changes, send clicks, and focus changes. The host feeds events,
listens to callbacks, and draws the batch; it does not position a separate
TextArea, Selects, toggles, or Button to recreate the prompt.

The composer uses the same `FontMetrics` instance for wrapping prompt text,
click hit testing, cursor geometry, selection rectangles, scrolling, and
emitted text run positions. The prompt text viewport owns `scroll_y`, mouse
wheel scrolling, auto-scroll into view, clipped cursor/text, scrollbar commands,
drag selection, shift-arrow selection, and replace-selection editing. Toolbar
pill rects are measured from icon, label, chevron, configured padding, and
configured gaps; fixed min/max widths are constraints rather than hardcoded
layout.

Run the visual composer lab:

```bash
zig build run-composer-prompt-lab
```

It opens an SDL window where you can resize the composer, type multiline prompt
text, open model/reasoning menus, toggle fast/access, hover/click send, and
inspect live command/text/icon counts.

Run the batch-level review:

```bash
zig build run-composer-prompt-review
```

It validates that the composer emits rounded panel commands, text/icon runs with
font roles, separators, and a circular send button without host renderer
heuristics.

## Z-Index

Render commands carry `z_index`. Higher z-index commands draw later, and equal
z-index commands keep insertion order.

```zig
var batch: powder.RenderBatch = .{};

try batch.rect(allocator, background_rect, background_color);
const previous_z = batch.setZIndex(100);
try batch.rect(allocator, floating_rect, floating_color);
batch.restoreZIndex(previous_z);
```

Runtime-positioned controls expose `setZIndex()` where overlapping is common:
`Button`, `IconButton`, `Select`, `TextInput`, `TextArea`, `Checkbox`, `Toggle`,
and `Image`. `Select` also has `setMenuZOffset()` and defaults its dropdown menu
to an overlay z above its control, so a menu can overlap later layout sections
without being hidden.

## Shape And Borders

Powder render commands carry renderer-neutral shape style. Hosts should consume
these fields directly instead of guessing from rect size:

- `radius`
- `border_width`
- `border_color`

Use batch helpers when emitting custom surfaces:

```zig
try batch.roundedRect(allocator, rect, background, 10);
try batch.rectBorder(allocator, rect, border, 10, 1);
try batch.panel(allocator, rect, background, border, 10, 1);
```

Core controls expose matching config fields and emit styled commands themselves:
`corner_radius`, `border_width`, and for `Select` also `menu_corner_radius`.
Buttons also support centered icon text for send-style actions:

```zig
const Send = powder.button(.{
    .icon_text = ">",
    .font_size = 18,
    .corner_radius = 999,
});
```

The SDL presenters draw rounded fills and borders from those command fields.
The GPU mesh path preserves the same command data and draws rectangular
fallback borders until a rounded GPU path is wired in.

## Rich Text

`powder.text()` can render styled inline spans without host-side text splitting.
Set spans on the retained Text instance and Powder emits laid-out `TextRun`s
with per-run color and optional font size.

```zig
const Message = powder.text(.{ .width = 520, .height = 24, .glyph_width = 8 });
var message = try Message.init(allocator, "Done for WIT-27.");
try message.setSpans(allocator, &.{
    .{ .start = 9, .end = 15, .color = .{ .r = 0.90, .g = 0.70, .b = 0.25, .a = 1.0 } },
});
try message.render(allocator, &batch);
```

This is intended for message text with inline code/status/link styling. Hosts
draw the emitted runs directly; they do not need to infer which ranges should be
highlighted.

## Virtual Lists

Use `powder.virtualList()` for large or variable-height scrollable lists such as
chat history, saved chats, or project rows. The component owns scroll state,
visible range calculation, row hit testing, selection/highlight state, scrollbar
commands, and clipped text labels.

```zig
fn rowLabel(_: ?*anyopaque, index: usize) []const u8 {
    return if (index == 0) "now" else "earlier";
}

fn rowHeight(_: ?*anyopaque, index: usize) f32 {
    return if (index == 0) 64 else 36;
}

const Chats = powder.virtualList(.{
    .item_count = 200,
    .item_label = rowLabel,
    .row_height_fn = rowHeight,
    .corner_radius = 8,
});

var chats = Chats.initFromConfig();
chats.setBounds(sidebar_rect);
try chats.update(&event);
try chats.render(allocator, &batch);
```

For custom row contents, use `visibleRange()` and `rowRect(index)` to render
additional retained controls or app-owned commands into the returned row rects.

## Images And Textures

Powder image rendering is command-based, like text and rectangles. Components
emit a stable `TextureId`; the renderer resolves that ID to a backend texture.
This keeps Powder components portable across SDL debug rendering, Vulkan, and
Metal without storing backend pointers in retained component state.

Create image commands directly when you already have a rect:

```zig
try batch.image(
    allocator,
    image_rect,
    powder.TextureId.init(1),
    .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    powder.Color.white,
    image_rect,
);
```

Use the retained image component when you want runtime bounds and fit behavior:

```zig
const Avatar = powder.image(.{
    .source_width = 256,
    .source_height = 256,
    .fit = .cover,
});

var avatar = Avatar.init(powder.TextureId.init(1));
avatar.setBounds(.{ .x = 12, .y = 12, .w = 40, .h = 40 });
try avatar.render(allocator, &batch);
```

Fit modes:

- `.stretch`: fill the bounds exactly
- `.contain`: preserve aspect ratio inside the bounds
- `.cover`: preserve aspect ratio and cover the bounds
- `.none`: draw at source size, clipped to the bounds

Powder also ships a reusable image decoder backed by bundled `stb_image` files
under `packages/powder/vendor`. It supports PNG, JPEG, BMP, and GIF as compiled
by `vendor/stb_image_impl.c`.

```zig
const loaded = try powder.ImageLoader.load("assets/avatar.png");
defer loaded.deinit();

const texture = try powder.sdl.createTextureFromImage(renderer, loaded);
defer powder.sdl.destroyTexture(texture);
```

If your executable uses `powder.ImageLoader`, link the bundled decoder from your
`build.zig`:

```zig
const powder_dep = b.dependency("powder", .{ .target = target, .optimize = optimize });
const powder_mod = powder_dep.module("powder");
exe.root_module.addImport("powder", powder_mod);

const powder_build = @import("path/to/packages/powder/build.zig");
powder_build.linkImageLoader(powder_dep, exe.root_module);
```

The retained UI API does not depend on a specific decoder. Apps can still load
textures through another pipeline and only hand Powder a `TextureId`.

For SDL presenter examples, provide a texture lookup callback:

```zig
fn lookupTexture(context: ?*anyopaque, id: powder.TextureId) ?powder.renderer.SdlTexture {
    const store: *TextureStore = @ptrCast(@alignCast(context orelse return null));
    if (id.value != store.id.value) return null;
    return .{ .texture = store.texture, .width = store.width, .height = store.height };
}

var presenter = powder.renderer.sdlFontRendererWithTextures(
    renderer,
    font,
    16,
    &texture_store,
    lookupTexture,
);
try presenter.renderBatch(&batch);
```

The SDL presenter can render arbitrary `SDL_Texture`s this way. The SDL_GPU path
already tracks image commands separately and currently reports them as
unsupported until a GPU texture registry is wired in; the public command model is
ready for Vulkan/Metal texture binding without changing components.

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
