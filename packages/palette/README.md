# Palette

Palette is Verde's retained UI component package. Since the palette-native port
it has no build-time dependencies beyond libc: the window system layer is a
pure-Zig Wayland client (AppKit via the objc runtime on macOS, Win32 on
Windows), rendering is Vulkan / Metal / Direct3D 11 reached through the OS
loader at runtime, and fonts and PNG decoding are pure Zig.

The source under `src/`, `tools/wayland-scanner.zig` and `protocols/` is
vendored from palette-native; `VENDORED_FROM` records the commit. Refresh with:

```bash
scripts/dev/vendor-palette-native.sh <palette-native repo> <commit>
```

Do not edit vendored files in place; change palette-native and re-vendor.
`build.zig`, `build.zig.zon`, `AGENTS.md` and this file are Verde's own.

API overview (see the READMEs under `src/platform`, `src/gpu`, `src/font`):

| Module | Purpose |
| --- | --- |
| `palette.platform` | `App` / `Window`: events, text input, clipboard, cursors, `prefPath` |
| `palette.event`, `palette.keyboard` | event union, `Keycode`, `Mods`, HID `Scancode`, held-key `State` |
| `palette.Graphics`, `palette.WindowRenderer` | shared GPU + fonts, per-window presentation and pacing |
| `palette.fonts`, `palette.font` | role/fallback font table, measurement, `glyphInk` |
| components (`palette.textArea`, `palette.menu`, ...) | retained widgets, unchanged in style |

Tests: `cd packages/palette && zig build test`.
