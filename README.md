# verde

`verde` is a desktop GUI for coding agents, currently built around Codex and OpenCode, with more integrations coming soon.

This repo currently contains the desktop app in [`packages/desktop/`](packages/desktop). If you clone the repo and want to run the app locally in development, that is the directory you want.

## Getting started

Verde talks to local provider CLIs rather than bundling its own backend.

> [!WARNING]
> To actually use Verde, you need at least one supported provider installed and authenticated on your machine:
> - Codex: install [Codex CLI](https://github.com/openai/codex) and run `codex login`
> - OpenCode: install [OpenCode](https://github.com/anomalyco/opencode) and make sure `opencode` is available on your `PATH`

If you just want to install the app instead of building it yourself, use one of these paths first.

### Install from releases

Download the latest release from [GitHub Releases](https://github.com/JonathanRiche/verde/releases).

- Linux: download `verde-<version>-linux-x86_64.tar.gz`, extract it, then run:

```bash
./install-local.sh
```

- macOS: download the `.dmg` or `.zip` for your architecture
  - `.dmg`: open it and drag `Verde.app` into `Applications`
  - `.zip`: unzip it and move `Verde.app` into `Applications`

### Install on Arch Linux

An AUR package is available for Arch users:

```bash
yay -S verde-bin
```

Package page: [verde-bin on the AUR](https://aur.archlinux.org/packages/verde-bin)

### Build from source

```bash
git clone https://github.com/JonathanRiche/verde
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

## Install on Linux or macOS from source

The root build now forwards Zig install prefixes into `packages/desktop`, so you can build and install from the repo root with one command.

User-local install:

```bash
zig build --release=safe -p ~/.local
```

Linux source install with the embedded CEF browser pane:

```bash
bash ./scripts/release/install-linux-local-cef.sh
```

macOS source install with the embedded CEF browser pane:

```bash
./scripts/release/install-macos-local.sh
```

System-wide install:

```bash
zig build --release=safe -p /usr/local
```

That requires write access to `/usr/local`.

That installs:

- `verde` into `bin/`
- `libfff_c.so` on Linux or `libfff_c.dylib` on macOS into `bin/`
- `verde.desktop` into `share/applications/` on Linux
- `verde.png` into `share/pixmaps/` on Linux
- `SDL3.framework` into `bin/SDL3.framework` on macOS
- when `-Dcef-sdk-path=...` is provided, the CEF helper binaries and platform runtime are installed alongside the app binaries

After a user-local install, make sure `~/.local/bin` is on your `PATH`.

On macOS, that prefix install is still a CLI-style install. It does not create a Finder app or anything that shows up in `/Applications` or the Dock.

To install a real macOS app bundle, use:

```bash
./scripts/release/install-macos-local.sh
```

On macOS, that installer now downloads and bundles the matching CEF runtime automatically by default.

If you already have a local CEF SDK cache and want to force a specific one, set `VERDE_CEF_SDK_PATH`:

```bash
VERDE_CEF_SDK_PATH=$HOME/.cache/verde/cef-sdk/cef_binary_..._macosarm64_minimal \
  ./scripts/release/install-macos-local.sh
```

If you want a no-CEF app bundle for faster local iteration, set:

```bash
VERDE_CEF_DISABLE_DOWNLOAD=1 ./scripts/release/install-macos-local.sh
```

That builds `Verde.app` and copies it into `~/Applications` by default. To install for all users instead:

```bash
./scripts/release/install-macos-local.sh /Applications
```

Release `.zip` artifacts on macOS already contain `Verde.app`, so end users can also unzip and drag the app bundle into `Applications`.

## Install with npm

For developers who prefer npm-style tools, Verde can also be distributed as a platform-specific npm package with a thin launcher.

Typical usage:

```bash
npx verde-app
npm install -g verde-app
verde
```

The npm path is intended for developer machines on:

- macOS Apple Silicon
- macOS Intel
- Linux x86_64

## Development

From the repo root:

```bash
zig build
zig build run
zig build run -Dui-debug=true
zig build test
zig build -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
```

- `zig build` builds the app
- `zig build run` builds and launches it
- `zig build run -Dui-debug=true` launches it with the native UI debug window enabled
- `zig build test` runs the Zig tests and the format check

The built binary is written to:

```bash
packages/desktop/zig-out/bin/verde
```

## Release builds

GitHub Actions builds release artifacts from tags that start with `v`.

- Linux: `verde-<version>-linux-x86_64.tar.gz`
- macOS Intel: `verde-<version>-macos-x86_64.zip` and `verde-<version>-macos-x86_64.dmg`
- macOS Apple Silicon: `verde-<version>-macos-arm64.zip` and `verde-<version>-macos-arm64.dmg`

The Linux archive contains a local install helper:

```bash
./install-local.sh
```

That installs the archive contents into `~/.local` by default.

## Embedded terminal

The desktop app includes a project-scoped embedded terminal dock powered by Ghostty's `libghostty-vt` terminal engine.

- Hidden by default and toggled with `CommandOrControl+J`
- Docked at the bottom of the chat workspace without taking sidebar width
- Starts a shell in the selected project's working directory
- Supports per-terminal zoom with `Ctrl+-` and `Ctrl+=` while the terminal is focused

For input/focus debugging while working on the terminal UI, launch with:

```bash
zig build run -Dui-debug=true
```

That enables a separate `UI Debug` window with live terminal/composer focus and input-routing state.

## Provider runtime notes

The desktop app talks to local provider CLIs rather than bundling its own backend:

- Codex threads use the local `codex` CLI and start `codex app-server` automatically when needed.
- OpenCode threads use the local `opencode` CLI and can start `opencode serve` automatically when needed.
- Both providers run against the project directory you import into the app.

If prompt sending fails, the first thing to check is that the relevant CLI is installed, on your `PATH`, and already authenticated.

## Crash logs and traces

On Linux, Verde now writes desktop runtime logs under the SDL pref path:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

Those files capture:

- Zig panic output from the desktop shell
- stderr from spawned Codex and OpenCode helper processes
- the last panic marker written before the app aborted

If a user reports a crash, ask them to collect:

```bash
tail -n 200 ~/.local/share/verde/Native/logs/verde.stderr.log
cat ~/.local/share/verde/Native/logs/last-crash.log
coredumpctl --no-pager --reverse | rg verde
```

If there is a matching coredump entry, ask them for the detailed trace too:

```bash
coredumpctl --no-pager info <PID>
```

For local repro work, launch the app from the repo root so the log file and any panic output are both easy to inspect:

```bash
zig build run
tail -f ~/.local/share/verde/Native/logs/verde.stderr.log
```

## Config and saved state

- App state is saved through SDL's pref path in `state.sqlite`.
- Legacy installs may still have an older `state.json` alongside the SQLite database.
- User config is loaded from `$XDG_CONFIG_HOME/verde/verde.json` or `~/.config/verde/verde.json`.

Example config:

```json
{
  "ui": {
    "font_size": 20
  },
  "keybinds": {
    "refresh": ["CommandOrControl+R", "F5"],
    "sidebar": "CommandOrControl+S",
    "browser": "Ctrl+B",
    "terminal": {
      "toggle":       "CommandOrControl+J",
      "new_tab":      "CommandOrControl+Shift+T",
      "close":        "CommandOrControl+Shift+W",
      "rename_tab":   "CommandOrControl+Shift+R",
      "tab_previous": "CommandOrControl+Shift+PageUp",
      "tab_next":     "CommandOrControl+Shift+PageDown",
      "split_up":     "CommandOrControl+Shift+Up",
      "split_down":   ["CommandOrControl+Shift+E", "CommandOrControl+Shift+Down"],
      "split_left":   "CommandOrControl+Shift+Left",
      "split_right":  ["CommandOrControl+Shift+O", "CommandOrControl+Shift+Right"],
      "focus_up":     "CommandOrControl+Alt+Up",
      "focus_down":   "CommandOrControl+Alt+Down",
      "focus_left":   "CommandOrControl+Alt+Left",
      "focus_right":  "CommandOrControl+Alt+Right"
    }
  }
}
```

Keybinds are loaded from the user config on startup and on app refresh. Use a string for one shortcut or a string array for multiple shortcuts for the same action.

## Third-Party Components

Verde uses and distributes third-party software. The main components in the desktop app are:

- `fff.nvim` / `fff-c` / `fff-search` by Dmitriy Kovalenko for fast file indexing and file search. Vendored in [`vendor/fff`](vendor/fff). License: MIT.
- Codicon by Microsoft for file-type glyphs in the composer file search UI. Vendored in [`packages/desktop/src/assets/fonts/Codicon.ttf`](packages/desktop/src/assets/fonts/Codicon.ttf). License: CC BY 4.0.
- Symbols Nerd Font Mono by Nerd Fonts for language-specific file glyphs in the composer file search UI. Vendored in [`packages/desktop/src/assets/fonts/SymbolsNerdFontMono-Regular.ttf`](packages/desktop/src/assets/fonts/SymbolsNerdFontMono-Regular.ttf). License: MIT.
- `nvim-web-devicons` for the file-type icon mapping reference used by Verde's native picker. License: MIT.
- Dear ImGui by Omar Cornut for the immediate-mode UI layer used by the native app. Pulled in through `zgui`. License: MIT.
- `zgui` from `zig-gamedev` for Zig bindings and backend integration around Dear ImGui. Declared in [`packages/desktop/build.zig.zon`](packages/desktop/build.zig.zon). License: MIT.
- `zsdl` from `zig-gamedev` for Zig bindings to SDL3. Declared in [`packages/desktop/build.zig.zon`](packages/desktop/build.zig.zon). License: MIT.
- SDL3 from libsdl-org for windowing, input, display integration, and OpenGL context management at runtime.
- `zqlite` by Karl Seguin for SQLite access in the desktop app. Declared in [`packages/desktop/build.zig.zon`](packages/desktop/build.zig.zon). License: MIT-style.
- `stb_image` by Sean Barrett and contributors for image decoding in the native app. Vendored in [`vendor/stb_image.h`](vendor/stb_image.h). License: public domain or MIT.
- Ghostty / `libghostty-vt` by Mitchell Hashimoto and contributors for terminal emulation and VT parsing in the embedded terminal dock. Declared in [`packages/desktop/build.zig.zon`](packages/desktop/build.zig.zon). License: MIT.

If you redistribute Verde, keep the relevant upstream notices and license texts with the distributed app and any vendored source.

## License

Verde is licensed under the MIT License. See [LICENSE](LICENSE).

## More detail

See [`packages/desktop/README.md`](packages/desktop/README.md) for the desktop app's build details, runtime notes, and current config behavior.
