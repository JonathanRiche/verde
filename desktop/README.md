# `verde`

`verde` is the desktop app in this repo. It is a standalone Zig application built with SDL3, OpenGL, and zgui.

If you cloned the repo and want to run the app locally, you can use `zig build run` from the repo root or work directly from this directory.

## Prerequisites

- Zig `0.15.x`
- OpenGL development libraries for your platform
- SDL3 available for your platform
  - Linux and Windows: install SDL3 development files
  - macOS: the build uses the bundled SDL3 framework from the Zig dependency
- Optional but required for actual provider requests:
  - `codex` on your `PATH` for Codex threads
  - `opencode` on your `PATH` for OpenCode threads

On this repo, `zig build` and `zig build test` succeed with Zig `0.15.2`.

## Build and run

From the repo root:

```bash
zig build
zig build run
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

These root commands delegate into `desktop/`.

From this directory directly:

```bash
zig build
zig build run
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

What these do:

- `zig build`: build the app
- `zig build run`: build and launch the app
- `zig build test`: run the Zig tests plus the format check from `build.zig`

The built executable is:

```bash
zig-out/bin/verde
```

## Typical development loop

1. Edit files in `src/`.
2. Run `zig build run` to launch the desktop app.
3. Run `zig build test` before handing off changes.

Main files:

- `build.zig`: build entrypoint, links SDL3/OpenGL, defines `run` and `test` steps
- `src/main.zig`: app entrypoint, window/UI shell, provider controls
- `src/state.zig`: app state, persistence, projects, threads
- `src/harness.zig`: provider-neutral interface
- `src/providers/codex.zig`: Codex integration through `codex app-server`
- `src/providers/opencode.zig`: OpenCode integration through the local HTTP server
- `src/config.zig`: user config loading
- `src/keybinds.zig`: keyboard shortcut parsing and overrides

## How provider runtime works

The desktop app uses local CLIs for provider access.

### Codex

- Uses the local `codex` CLI.
- Starts `codex app-server --listen ws://127.0.0.1:4500` automatically when needed.
- New threads default to the Codex provider.
- Image attachments currently work with Codex threads only.

### OpenCode

- Uses the local `opencode` CLI.
- Starts `opencode serve --hostname 127.0.0.1 --port 4096` automatically when needed.
- Requests are sent against the selected project directory.

If sending prompts fails, check that the relevant CLI exists on your `PATH` and is already authenticated.

## State and config

The app persists session state through SDL's pref path as `state.json`. The exact location depends on the platform because it comes from `SDL_GetPrefPath`.

User config is loaded from:

- `$XDG_CONFIG_HOME/verde/verde.json`
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

Built-in refresh bindings are `CommandOrControl+R`, `CommandOrControl+Shift+R`, and `F5`. Refresh reloads app state from disk and reloads keybinds.

## Dependencies

Third-party Zig dependencies are declared in `build.zig.zon`:

- `zgui`
- `zsdl`

Zig fetches them automatically during build.

## Notes

- From the repo root, the desktop app lives in `desktop/`.
