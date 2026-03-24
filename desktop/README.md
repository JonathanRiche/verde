# `@packages/native`

Standalone Zig native shell for the EditorTs chat workflow.

This package is separate from [`packages/desktop`](/home/rtg/development/blinkx-projects/editor-ts/packages/desktop). `packages/desktop` is the Electrobun app. `packages/native` is the direct Zig + SDL3 + zgui shell.

## Prerequisites

- Zig `0.15.x`
- SDL3 development files installed and discoverable via `pkg-config`
- OpenGL development libraries for your platform

On this repo, `zig build` succeeds with Zig `0.15.2` and SDL3 available through `pkg-config`.

## Build locally

From the repo root:

```bash
cd packages/native
zig build
```

That builds the app and installs the binary into:

```bash
zig-out/bin/native
```

Useful commands while working on it:

```bash
cd packages/native
zig build run
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

`zig build test` runs the Zig tests and the format check defined in [`build.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/build.zig).

## Local development loop

The normal loop is:

1. Edit code under [`src`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src).
2. Run `zig build run` to launch the shell.
3. Run `zig build test` before you hand off changes.

Main files:

- [`build.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/build.zig): build entrypoint, links SDL3/OpenGL, defines `run` and `test` steps
- [`src/main.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src/main.zig): app entrypoint, UI, persistence, event loop
- [`src/harness.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src/harness.zig): provider-neutral AI harness interface
- [`src/providers`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src/providers): Codex/OpenCode provider integrations
- [`src/config.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src/config.zig): user config loading
- [`src/keybinds.zig`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/src/keybinds.zig): keyboard shortcut parsing and overrides

## State and config

The app persists session state through SDL's pref path as `state.json`. The exact location depends on platform because it comes from `SDL_GetPrefPath`.

User config is loaded from:

- `$XDG_CONFIG_HOME/verde/verde.json`, or
- `~/.config/verde/verde.json`

Current supported config includes UI font size and keybind overrides. Example:

```json
{
  "ui": {
    "font_size": 20
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "F5"]
  }
}
```

The built-in refresh bindings are `CommandOrControl+R`, `CommandOrControl+Shift+R`, and `F5`. Refresh reloads app state from disk and reloads keybinds.

## Dependencies

Third-party Zig dependencies are declared in [`build.zig.zon`](/home/rtg/development/blinkx-projects/editor-ts/packages/native/build.zig.zon):

- `zgui`
- `zsdl`

Zig fetches them automatically during build.

## Notes

- This package does not have a `package.json`; use Zig commands directly.
- If you want the shipped desktop app, use [`packages/desktop`](/home/rtg/development/blinkx-projects/editor-ts/packages/desktop) instead.
