# AGENTS.md

## Zig Development

Always use `zigdoc` to discover APIs for the Zig standard library and any third-party dependencies.

Examples:
```bash
zigdoc std.fs
zigdoc std.posix.getuid
zigdoc ghostty-vt.Terminal
zigdoc vaxis.Window
```

## Common Zig Patterns

These patterns reflect current Zig APIs and may differ from older documentation.

**ArrayList:**
```zig
var list: std.ArrayList(u32) = .empty;
defer list.deinit(allocator);
try list.append(allocator, 42);
```

**HashMap/StringHashMap (unmanaged):**
```zig
var map: std.StringHashMapUnmanaged(u32) = .empty;
defer map.deinit(allocator);
try map.put(allocator, "key", 42);
```

**HashMap/StringHashMap (managed):**
```zig
var map: std.StringHashMap(u32) = std.StringHashMap(u32).init(allocator);
defer map.deinit();
try map.put("key", 42);
```

**stdout/stderr Writer:**
```zig
var buf: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buf);
defer writer.flush() catch {};
try writer.print("hello {s}\n", .{"world"});
```

**build.zig executable/test:**
```zig
b.addExecutable(.{
    .name = "foo",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

**JSON writing:**
```zig
// Use std.json.Stringify with a buffered writer
var buf: [4096]u8 = undefined;
var writer = std.fs.File.stdout().writer(&buf);
defer writer.interface.flush() catch {};

var jw: std.json.Stringify = .{
    .writer = &writer.interface,
    .options = .{ .whitespace = .indent_2 },
};
try jw.write(my_struct);  // Serialize any struct/value directly
```

**Allocating writer (dynamic buffer):**
```zig
var writer: std.Io.Writer.Allocating = .init(allocator);
defer writer.deinit();
try writer.writer.print("hello {s}", .{"world"});
const output = writer.toOwnedSlice();  // Get result
```

## Zig Code Style

**Naming:**
- `camelCase` for functions and methods
- `snake_case` for variables and parameters
- `PascalCase` for types, structs, and enums
- `SCREAMING_SNAKE_CASE` for constants

**Struct initialization:** Prefer explicit type annotation with anonymous literals:
```zig
const foo: Type = .{ .field = value };  // Good
const foo = Type{ .field = value };     // Avoid
```

**File structure:**
1. `//!` doc comment describing the module
2. `const Self = @This();` (for self-referential types)
3. Imports: `std` → `builtin` → project modules
4. `const log = std.log.scoped(.module_name);`

**Functions:** Order methods as `init` → `deinit` → public API → private helpers

**Memory:** Pass allocators explicitly, use `errdefer` for cleanup on error

**Documentation:** Use `///` for public API, `//` for implementation notes. Always explain *why*, not just *what*.

**Tests:** Inline in the same file, register in src/main.zig test block

## Safety Conventions

Inspired by [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).

**Assertions:**
- Add assertions that catch real bugs, not trivially true statements
- Focus on API boundaries and state transitions where invariants matter
- Good: bounds checks, null checks before dereference, state machine transitions
- Avoid: asserting something immediately after setting it, checking internal function arguments

**Function size:**
- Soft limit of 70 lines per function
- Centralize control flow (switch/if) in parent functions
- Push pure computation to helper functions

**Comments:**
- Explain *why* the code exists, not *what* it does
- Document non-obvious thresholds, timing values, protocol details

## Native UI Stack

`packages/native` is a native desktop app built on:
- `SDL3` via `zsdl3` for window creation, events, display/usable-bounds queries, and OpenGL context setup
- `OpenGL` for final rendering
- `zgui` as the Zig binding layer for Dear ImGui
- Dear ImGui for all application UI layout and widgets

In practice:
- `SDL3` owns the real window size, drawable pixel size, monitor/display scale, and event loop
- `zgui.backend` bridges SDL3 + OpenGL into ImGui
- `main.zig` is responsible for choosing the correct size space for layout and for feeding the backend the right dimensions every frame

When editing UI in `packages/native`, assume this is an ImGui app first, not a web/CSS layout.

## Coordinate Spaces

This app uses multiple size spaces. Mixing them incorrectly causes the exact failures we hit before: top-left-only rendering, giant black unused areas, or UI that changes apparent size across displays.

Always distinguish:
- `window size`: logical client-area size from SDL
- `size in pixels`: drawable framebuffer size from SDL
- `display scale`: the monitor/window scale factor from SDL

Rules:
- Use the same coordinate space consistently for root layout and ImGui display size.
- Feed `zgui.backend.newFrame(...)` the drawable framebuffer size, not guessed dimensions.
- If you change how root layout sizing works, verify that `renderRoot(...)`, `zgui.io.setDisplaySize(...)`, and framebuffer sizing still agree.
- Do not “fix” DPI/layout issues by piling on extra scale factors without checking the underlying SDL values first.

Before changing sizing behavior, inspect:
```zig
window.getSize(...)
SDL_GetWindowSizeInPixels(...)
SDL_GetWindowDisplayScale(...)
```

If the UI only fills the top-left portion of the window, assume a coordinate-space mismatch first.

## ImGui Sizing Rules

Do not introduce new hard-coded layout numbers unless they are true design tokens with clear intent.

Avoid patterns like:
```zig
renderSidebar(state, 272.0, content[1]);
renderChatWorkspace(state, content[0] - 288.0, content[1]);
const composer_reserved: f32 = 200.0;
const card_width: f32 = 260.0;
```

Prefer:
- sizing from `zgui.getContentRegionAvail()`
- ratios with clamps
- measured text size from `zgui.calcTextSize(...)`
- shared helpers such as `clampf(...)`, `scaledUi(...)`, `uiScaleFactor()`
- style-driven spacing from `zgui.getStyle()`

Good patterns:
```zig
const avail = zgui.getContentRegionAvail();
const sidebar_width = clampf(avail[0] * 0.235, scaledUi(230.0), avail[0] * 0.38);
const gap = clampf(avail[0] * 0.012, scaledUi(10.0), scaledUi(18.0));
```

```zig
const label_width = zgui.calcTextSize(label, .{})[0];
zgui.setNextItemWidth(label_width + scaledUi(36.0));
```

```zig
const composer_height = clampf(content[1] * 0.27, scaledUi(168.0), content[1] * 0.42);
```

Use hard-coded constants only when they are:
- minimums
- maximums
- touch targets
- icon/button affordances
- intentional visual tokens reused across the file

If you must add a constant, prefer naming it and documenting why it exists.

## Responsive Layout Checklist

When changing any major UI in `packages/native`, verify all of these:
- Ultrawide desktop: layout should expand without leaving controls stranded in corners
- Typical laptop width: no giant unused black region, no clipped root UI
- Shorter laptop height: transcript and composer must both remain usable
- Different monitor scale factors: UI should not suddenly become tiny or enormous
- Sidebar text rows: titles and timestamps should truncate from measured space, not guessed character counts
- Attachment/image cards: width and height should derive from available space, not fixed card dimensions

If a section is too tall, do not just shrink fonts. Rebalance the layout:
- reduce reserved height ratios
- clamp panel heights
- let transcript/composer split adapt to available height
- allow content regions to own width rather than subtracting arbitrary constants

## Editing Policy For ImGui UI

Before editing:
1. Identify whether the bug is window sizing, framebuffer sizing, display scale, or widget layout.
2. Read the surrounding render path, not just the widget function.
3. Check whether the current code is using logical size or framebuffer size.

When editing:
1. Prefer helper functions over scattering raw numbers.
2. Keep ratios and clamp ranges close to where they are used, unless shared broadly.
3. Use `zgui.calcTextSize(...)` for width-sensitive controls.
4. Use `zgui.getContentRegionAvail()` instead of “subtract magic 24/56/88 pixels”.
5. Keep root/window sizing logic in sync with SDL.

After editing:
1. Build with `zig build`
2. Run tests with `zig build test`
3. Sanity check on both a wide monitor and a normal laptop-sized window when the change affects layout

## Anti-Patterns For This Package

Do not:
- assume web-style responsive behavior exists automatically in ImGui
- use raw `width - 288.0` style math for major panel layout
- compute truncation from guessed monospace character widths when `calcTextSize(...)` can measure it
- treat SDL logical size and drawable pixel size as interchangeable
- add another scale multiplier to “try to fix” DPI issues without tracing the current size path first

If a future change needs a one-off hard-coded number, leave a brief comment explaining:
- what the number represents
- why it is safe across laptop and desktop screens
