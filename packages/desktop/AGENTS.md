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

**UI methods:** In `packages/desktop/src/ui`, always add a short leading comment for each UI-rendering method explaining what region/component it renders. If a UI method uses non-obvious layout constants or geometry, add a brief comment explaining why.

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

`packages/desktop` is a native desktop app built on:
- `SDL3` via `zsdl3` for window creation, events, display/usable-bounds queries, and OpenGL context setup
- `OpenGL` for final rendering
- `palette` for application UI primitives, layout surfaces, retained hit regions, and render-batch commands

In practice:
- `SDL3` owns the real window size, drawable pixel size, monitor/display scale, and event loop
- `main.zig` is responsible for choosing the correct size space for layout and for routing SDL events into Palette-owned UI state
- `palette_gl_renderer.zig` is responsible for drawing Palette batches through OpenGL

When editing UI in `packages/desktop`, assume this is a native Palette app first, not a web/CSS layout.

## Coordinate Spaces

This app uses multiple size spaces. Mixing them incorrectly causes the exact failures we hit before: top-left-only rendering, giant black unused areas, or UI that changes apparent size across displays.

Always distinguish:
- `window size`: logical client-area size from SDL
- `size in pixels`: drawable framebuffer size from SDL
- `display scale`: the monitor/window scale factor from SDL

Rules:
- Use the same coordinate space consistently for root Palette layout and renderer dimensions.
- Render Palette batches against the drawable framebuffer size, not guessed dimensions.
- If you change how root layout sizing works, verify that `renderRoot(...)`, Palette command coordinates, and framebuffer sizing still agree.
- Do not “fix” DPI/layout issues by piling on extra scale factors without checking the underlying SDL values first.

Before changing sizing behavior, inspect:
```zig
window.getSize(...)
SDL_GetWindowSizeInPixels(...)
SDL_GetWindowDisplayScale(...)
```

If the UI only fills the top-left portion of the window, assume a coordinate-space mismatch first.

## Palette Sizing Rules

Do not introduce new hard-coded layout numbers unless they are true design tokens with clear intent.

Avoid patterns like:
```zig
renderSidebar(state, 272.0, content[1]);
renderChatWorkspace(state, content[0] - 288.0, content[1]);
const composer_reserved: f32 = 200.0;
const card_width: f32 = 260.0;
```

Prefer:
- explicit `palette.Rect` inputs passed down from the root layout
- ratios with clamps
- measured or estimated Palette text metrics from the local UI helper layer
- shared helpers such as `clampf(...)`, `scaledUi(...)`, `uiScaleFactor()`
- spacing from shared theme tokens

Good patterns:
```zig
const sidebar_width = clampf(root.w * 0.235, scaledUi(230.0), root.w * 0.38);
const gap = clampf(root.w * 0.012, scaledUi(10.0), scaledUi(18.0));
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

When changing any major UI in `packages/desktop`, verify all of these:
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

## Native App Visual Testing

For manual/agent validation of the desktop UI, use the real app. Do not substitute unit tests or alternate build commands when the task is about runtime layout, input, rendering, window resizing, or Palette migration behavior.

Use only:
```bash
mise run dev
```

Recommended agent workflow:
1. Close stale Verde windows before launching a new one so screenshots and input target the current binary:
   ```bash
   hyprctl clients -j | jq -r '.[] | select((.class|test("verde";"i")) or (.title|test("verde";"i"))) | .address' |
     while read -r addr; do [ -n "$addr" ] && hyprctl dispatch closewindow address:$addr; done
   ```
2. Start the app with `mise run dev` from the repo/worktree root.
3. Use Hyprland to find and focus/move the Verde window:
   ```bash
   hyprctl clients -j | jq -r '.[] | [.address,.class,.title] | @tsv' | rg -i 'verde'
   hyprctl dispatch focuswindow class:com.verde.native
   hyprctl dispatch movetoworkspacesilent 2,class:com.verde.native
   ```
4. Use Wayland tools for interaction when available:
   ```bash
   printf 'paste smoke text' | wl-copy
   wtype -M ctrl -k v -m ctrl
   ```
5. Capture screenshots from the compositor instead of guessing from logs:
   ```bash
   grim -g "$(hyprctl activewindow -j | jq -r '.at + .size | @tsv' | awk '{print $1","$2" "$3"x"$4}')" /tmp/verde-active.png
   ```

When checking responsiveness, resize or tile the actual window through Hyprland and take another screenshot. If the UI does not reflow after window changes, inspect the SDL window-size/drawable-size path and Palette root layout invalidation before tuning component dimensions.

Runtime diagnostics are written to:
```bash
~/.local/share/verde/Native/logs/verde.stderr.log
```

For clipboard/input bugs, prefer length-only diagnostics and never log clipboard contents.
- allow content regions to own width rather than subtracting arbitrary constants

## Editing Policy For Palette UI

Before editing:
1. Identify whether the bug is window sizing, framebuffer sizing, display scale, or widget layout.
2. Read the surrounding render path, not just the widget function.
3. Check whether the current code is using logical size or framebuffer size.

When editing:
1. Prefer helper functions over scattering raw numbers.
2. Keep ratios and clamp ranges close to where they are used, unless shared broadly.
3. Use Palette text metrics or local estimated text metrics for width-sensitive controls.
4. Pass explicit `palette.Rect` values instead of deriving layout from implicit cursor state.
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

## CI

If this is a Node.js project, install Agent CI as a dev dependency
using the project's package manager (npm, pnpm, yarn, or bun):

```bash
<package-manager> install -D @redwoodjs/agent-ci
```

If this is not a Node.js project, you can run Agent CI directly
with npx:

```bash
npx @redwoodjs/agent-ci
```

Install the agent skill:

```bash
npx skills add redwoodjs/agent-ci --skill agent-ci
```

Before completing any work, run the `agent-ci` skill to validate
your changes locally. If it fails, fix the issue and re-run.
Do not report work as done until it passes.
