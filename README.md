# verde

`verde` is a desktop chat app built in Zig with SDL3, OpenGL, and zgui.

This repo currently contains the desktop app in [`desktop/`](desktop). If you clone the repo and want to run the app locally in development, that is the directory you want.

## Quick start

```bash
git clone <repo-url> verde
cd verde
zig build run
```

That launches the app in development mode.

## Prerequisites

- Zig `0.15.x` (`0.15.2` is confirmed working in this repo)
- OpenGL development libraries for your platform
- SDL3 available for your platform
  - Linux and Windows: install SDL3 development files
  - macOS: the build uses the bundled SDL3 framework from the Zig dependency
- At least one supported provider CLI on your `PATH` if you want to send prompts from the app:
  - `codex`
  - `opencode`

## Development commands

From the repo root:

```bash
zig build
zig build run
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

- `zig build` builds the app
- `zig build run` builds and launches it
- `zig build test` runs the Zig tests and the format check

The built binary is written to:

```bash
desktop/zig-out/bin/verde
```

## Provider runtime notes

The desktop app talks to local provider CLIs rather than bundling its own backend:

- Codex threads use the local `codex` CLI and start `codex app-server` automatically when needed.
- OpenCode threads use the local `opencode` CLI and can start `opencode serve` automatically when needed.
- Both providers run against the project directory you import into the app.

If prompt sending fails, the first thing to check is that the relevant CLI is installed, on your `PATH`, and already authenticated.

## Config and saved state

- App state is saved through SDL's pref path as `state.json`.
- User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or `~/.config/verde/verde.json`.

Example config:

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

## More detail

See [`desktop/README.md`](desktop/README.md) for the desktop app's build details, runtime notes, and current config behavior.
