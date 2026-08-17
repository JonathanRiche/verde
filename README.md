<p align="center">
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/verde-logo.png" alt="Verde" width="72" />
</p>

<h1 align="center">Verde</h1>

<p align="center">
  <strong>Every coding agent. One tiling window.</strong><br />
  Local · native · keyboard-first
</p>

<p align="center">
  <a href="https://verdeai.dev/">Website</a> ·
  <a href="https://verdeai.dev/docs/quickstart">Docs</a> ·
  <a href="https://github.com/JonathanRiche/verde/releases">Releases</a> ·
  <a href="LICENSE">MIT</a>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/verde.png" alt="Verde tiling workspace — Codex GUI chat, Claude Code TUI, Amp, Grok Build, and shell in one window" width="100%" />
</p>

<p align="center">
  <em>Codex GUI + Claude Code TUI + Amp + Grok Build — tiled or scrolled with shell. Every agent local, no hosted relay.</em>
</p>

---

## Why Verde

Most AI coding tools pick a lane: a chat sidebar, a terminal CLI, or a hosted web app. Verde is the **workstation** for the agents you already run locally.

- **One window for every agent.** Codex, Claude Code, OpenCode, and Cursor as native chat *or* TUI panes; Grok Build and Amp as terminal TUIs.
- **A real tiling workspace.** Split chat, terminal, and browser — or scroll them as a Niri-style strip when you open more panes. Layouts persist.
- **Local-first.** Verde drives the provider CLIs already on your machine. No Verde-hosted inference, no prompt relay, no telemetry sink.
- **Keyboard-first.** Command palette (`Ctrl+Shift+P`), pane focus, zoom, and workspace jumps — remappable in one config file.
- **Native, not Electron.** Zig + SDL3 + [Palette](packages/palette) (our in-tree GUI framework), Ghostty VT for terminals, system webview for the browser pane.

| | Verde | tmux + CLIs | Hosted agent apps | IDE extension |
| --- | :---: | :---: | :---: | :---: |
| Multi-agent tiling | ✓ | ~ | – | ~ |
| Native GUI chat + TUI | ✓ | – | ~ | – |
| Embedded browser + Design Mode | ✓ | – | ~ | – |
| Local-only (no relay) | ✓ | ✓ | – | ~ |
| Scriptable live control | ✓ | ~ | – | – |

✓ full · ~ partial · – not really

### Supported agents

| Agent | GUI chat | Terminal TUI | How Verde talks to it |
| --- | :---: | :---: | --- |
| **Codex** | ✓ | ✓ | Local `codex` CLI + `codex app-server` |
| **Claude Code** | ✓ | ✓ | Claude Agent SDK against your installed Claude Code |
| **OpenCode** | ✓ | ✓ | Local `opencode` CLI + `opencode serve` |
| **Cursor** | ✓ | ✓ | Cursor CLI ACP (`agent acp`) |
| **Grok Build** | – | ✓ | Local `grok` CLI in an embedded Ghostty pane |
| **Amp** | – | ✓ | Local `amp` CLI in an embedded Ghostty pane |

Verde does not host models or relay prompts. Install the provider CLIs you care about; Verde drives them on your machine.

→ Setup notes: [Provider docs](https://verdeai.dev/docs/providers)

---

## Install

**Linux / macOS**

```bash
curl -fsSL https://verdeai.dev/install.sh | sh
```

**Windows x64 (PowerShell)**

```powershell
irm https://verdeai.dev/install.ps1 | iex
```

Or grab a package from [GitHub Releases](https://github.com/JonathanRiche/verde/releases):

| Platform | Artifact |
| --- | --- |
| Linux x86_64 | `verde-v*-linux-x86_64.tar.gz` → extract, run `./install-local.sh` |
| macOS | `.dmg` or `.zip` → move `Verde.app` into Applications |
| Windows x64 | `verde-v*-windows-x86_64.zip` → verify `.sha256`, run packaged `install.ps1` |
| Arch Linux | [`verde-bin`](https://aur.archlinux.org/packages/verde-bin) (`yay -S verde-bin`) |

Windows installs per-user (no admin), adds a Start Menu shortcut, and needs the [WebView2 Evergreen Runtime](https://developer.microsoft.com/microsoft-edge/webview2/). Linux browser support uses system WPE WebKit — the installer warns if packages are missing; set `VERDE_INSTALL_BROWSER_DEPS=1` to install them.

Full install variants and platform notes: [verdeai.dev/#install](https://verdeai.dev/#install) · [Troubleshooting](https://verdeai.dev/docs/troubleshooting)

---

## First five minutes

Verde does **not** ship a model. Install and authenticate at least one provider CLI first:

| Provider | Setup |
| --- | --- |
| **Codex** | [Codex CLI](https://github.com/openai/codex) → `codex login` |
| **Claude Code** | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) + Node on `PATH` → log in |
| **OpenCode** | [OpenCode](https://github.com/anomalyco/opencode) on `PATH` |
| **Cursor** | [Cursor CLI](https://cursor.com/docs/cli/installation) → `agent login` (or `CURSOR_API_KEY`) |
| **Grok Build** | [Grok Build](https://docs.x.ai/build/overview#install) → `grok` on `PATH` · terminal TUI (palette → **Start New Grok TUI**) |
| **Amp** | [Amp](https://ampcode.com) on `PATH` · terminal TUI |

Then:

```bash
verde
```

1. **Import a project** — sidebar `+` or right-click the rail. Threads and agents run against that workspace root.
2. **New chat** — `Ctrl+T` / `Cmd+T`. Pick provider + model, set run permissions, send a prompt.
3. **Tile a browser** — `Ctrl+Shift+B` (native webview: WPE / WKWebView / WebView2).
4. **Split a terminal** — `Ctrl+Shift+T`. Open Codex/Claude/Grok TUIs from the palette or `verde live agent open`.
5. **Command palette** — `Ctrl+Shift+P` jumps to threads, panes, workspaces, and app commands.

If no GUI provider is ready, Verde shows a **Connect an AI provider** screen so you can finish setup without guessing.

→ Full walkthrough: [Quickstart](https://verdeai.dev/docs/quickstart)

---

## Features

<p align="center">
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/ristretto.png" alt="Same multi-agent layout under the Ristretto theme" width="100%" />
</p>

### Tiling workspace, not a chat box

Every pane is first-class. Split a chat beside a browser, drop a terminal next to it, zoom with `Alt+Z`, and rearrange with `Ctrl+Shift+H/J/K/L`. Layouts and per-terminal zoom persist across launches.

### Scrolling pane layout (Niri-style)

With two or more tiled panes, Verde can switch to a horizontal or vertical strip — free-form wheel/touchpad panning, resizable columns, sidebar reorder, and hover-edge navigation. **Settings → Workspace** (or the command palette) chooses Automatic / Always / Disabled, per-workspace overrides, direction, and panes-per-view.

### Command palette (`Ctrl+Shift+P`)

One Raycast-style launcher ranks threads, open panes, workspaces, and commands. `Ctrl+Enter` opens a result in a new pane. Slash commands like `/stack` and `/process` run from the composer.

### Browser + Design Mode

Tile a native webview next to your agent. Point at an element or draw a region, describe the change, and route visual context into a chat or terminal TUI — without leaving the workspace.

### Experimental companion + Mission Control

Opt-in under **Settings → Experimental**: a pane-less orchestration sidecar (Sprout, Moss, or Vireo) with durable threads, operation inspection, and Mission Control for multi-step goals. Still experimental — APIs and UI may change.

### Project-scoped terminal dock

Ghostty-powered terminals under every workspace. Shell tabs, agent launch profiles, OSC titles, and zoom that stick with the layout.

### Managed processes (`verde.yml`)

Declare dev servers and agents once; start/stop/restart from chat or CLI:

```yaml
processes:
  web:
    command: "npm run dev"
    resources:
      - "port:3000"

agents:
  codex:
    provider: codex
    command: "codex"
    revive: attach_or_create
    hooks: true
```

### Headless session daemon

Chat turns and terminal sessions live in a **session daemon**, not the window. The GUI, CLI, MCP bridge, and the experimental web client all attach as detached clients — agent turns keep running and land durably if the window closes, and the daemon drains and upgrades itself when a new Verde version starts. Drafts, image attachments, and transcripts persist across restarts.

### Scriptable from your shell

Every running instance exposes local IPC (`verde live`). Inspect panes, open chats, send prompts, steer a running turn, write to terminals, open the browser — from hooks, dotfiles, or automation:

```bash
verde live status --json
verde live chat open --workspace $WS --provider codex --model gpt-5.6-sol --reasoning high
verde live chat send --pane $PANE --prompt "run the tests and fix failures"
verde live chat followup --pane $PANE --prompt "also update the changelog"  # steer the running turn
verde live terminal write --focused --text $'cargo test\r'
verde open http://localhost:3000
```

The same chat surface is exposed to agents over MCP (`verde mcp`): open panes, send prompts, read transcripts, and queue mid-turn follow-ups — daemon-direct, without stealing focus or touching your composer.

→ Full surface: [CLI reference](https://verdeai.dev/docs/cli)

### Themes that match your rig

On Omarchy, Verde follows the active `colors.toml` automatically. Everywhere else, import portable themes from the site:

```bash
verde theme import https://verdeai.dev/themes/tokyo-night.json
```

<p align="center">
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/tokyo-night.png" alt="Tokyo Night" width="32%" />
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/catppuccin.png" alt="Catppuccin" width="32%" />
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/gruvbox.png" alt="Gruvbox" width="32%" />
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/kanagawa.png" alt="Kanagawa" width="32%" />
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/osaka-jade.png" alt="Osaka Jade" width="32%" />
  <img src="https://raw.githubusercontent.com/JonathanRiche/verde/master/assets/themes/matte-black.png" alt="Matte Black" width="32%" />
</p>

<p align="center">
  <em>Same workspace, different skins — try them live on <a href="https://verdeai.dev/">verdeai.dev</a> (also Catppuccin Latte, Ristretto, Verde default).</em>
</p>

---

## Move around

| Key | Action |
| --- | --- |
| `Ctrl+Shift+P` | Command palette |
| `Ctrl+T` | New chat thread |
| `Ctrl+Shift+T` | Split terminal pane |
| `Ctrl+Shift+B` | Toggle browser pane |
| `Ctrl+H/J/K/L` | Focus panes (vim-style); `Ctrl+Arrow` also moves across scrolling panes |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` | Next / previous pane in sidebar order |
| `Ctrl+Shift+H/J/K/L` | Swap / rearrange panes |
| `Alt+Z` | Zoom focused pane |
| `Alt+1`…`Alt+9` | Jump workspaces |

→ All defaults + remapping: [Keybinds](https://verdeai.dev/docs/keybinds)

---

## Documentation

| Topic | Link |
| --- | --- |
| Quickstart | [docs/quickstart](https://verdeai.dev/docs/quickstart) |
| Providers | [docs/providers](https://verdeai.dev/docs/providers) |
| Chat, models & runs | [docs/chat](https://verdeai.dev/docs/chat) |
| Panes & tiling | [docs/panes](https://verdeai.dev/docs/panes) |
| Design Mode | [docs/design-mode](https://verdeai.dev/docs/design-mode) |
| CLI (`verde live`, state, browser) | [docs/cli](https://verdeai.dev/docs/cli) |
| Config, themes, `verde.yml` | [docs/config](https://verdeai.dev/docs/config) |
| Troubleshooting | [docs/troubleshooting](https://verdeai.dev/docs/troubleshooting) |

Agent-friendly crawl: [llms.txt](https://verdeai.dev/llms.txt) · [llms-full.txt](https://verdeai.dev/llms-full.txt) · any page as `/docs/<slug>.md`

---

## Development

Source builds live in [`packages/desktop/`](packages/desktop). Use [`mise`](https://mise.jdx.dev/) from the repo root (Zig `0.16.0` is pinned in [`mise.toml`](mise.toml)):

```bash
mise install
mise run setup
mise run build    # release-style local build
mise run dev      # build + run (native webview)
```

| Task | Command |
| --- | --- |
| Dependency check | `mise run setup` |
| Dev run | `mise run dev` |
| Release-style build | `mise run build` |
| SDL_GPU Palette renderer | `mise run dev-sdl-gpu` |
| Web client (Zig gateway + Solid SPA) | `mise run web-app` / `mise run web-app-run` |

**Do not use bare `zig build`** — the default Debug + WPE path is known to fail. Prefer `mise run build` / `mise run dev`, or explicitly:

```bash
zig build --release=safe -Dbrowser-backend=native_webview
```

Platform notes (WebView2 SDK, WPE packages, macOS codesign, Windows MSVC): see [Troubleshooting](https://verdeai.dev/docs/troubleshooting) and comments in [`scripts/`](scripts/).

The UI stack is SDL3 (window/events/scale) + SDL_GPU + Palette — not web UI or ImGui. Desktop package overview: [`packages/desktop`](packages/desktop).

---

## Under the hood

- **Zig 0.16** — native executable, no Electron shell
- **SDL3 + Palette** — windowing, input, and in-tree Zig GUI framework
- **Headless session daemon** — owns chat turns and PTYs; GUI, web gateway, CLI, and MCP are detached clients, so agent work survives window restarts
- **Ghostty / libghostty-vt** — embedded terminal engine, pinned to upstream (no vendored fork)
- **Native webview** — WPE WebKit · WKWebView · WebView2 (no bundled Chromium)
- **SQLite** — local projects, threads, transcripts, drafts, and image attachments

The render loop is tuned for low idle cost: prompt acceptance is sub-millisecond even on long threads, daemon round-trips run off the render thread, and streaming large transcripts stays O(delta) per update.

Third-party notices and licenses for vendored components are listed under [Third-party components](#third-party-components) below when redistributing.

---

## Config cheat sheet

| What | Where |
| --- | --- |
| App state | SDL pref path → `state.sqlite` |
| User config | `~/.config/verde/verde.json` (Unix) · `%APPDATA%\Verde\verde.json` (Windows) · override with `VERDE_CONFIG` |
| Project stack | `verde.yml` / `verde.yaml` in the workspace root |
| Logs (Linux) | `~/.local/share/verde/Native/logs/verde.stderr.log` |
| Logs (any) | `verde state path --json` then open `logs/` under that directory |

Example stack and full `verde.json` schema: [Configuration & state](https://verdeai.dev/docs/config)

---

## Third-party components

Main third-party pieces used by the desktop app:

- `@anthropic-ai/claude-agent-sdk` — Claude Code provider integration
- `fff.nvim` / `fff-c` / `fff-search` — file indexing/search ([`vendor/fff`](vendor/fff), MIT)
- Ghostty / `libghostty-vt` — terminal emulation (MIT)
- `zsdl` (zig-gamedev) — SDL3 bindings (MIT)
- SDL3 — windowing, input, display, rendering
- `zqlite` — SQLite access (MIT-style)
- `zig_dif` / `zig_markdown` — chat markdown and code rendering
- `stb_image` — image decoding ([`vendor/stb_image.h`](vendor/stb_image.h))
- Font assets (Codicon, Nerd Fonts, Noto Sans, JetBrains Mono Nerd Font, Cal Sans) — see [`packages/desktop/src/assets/fonts`](packages/desktop/src/assets/fonts)

If you redistribute Verde, keep the relevant upstream notices with the distributed app and vendored source.

---

## License

Verde is licensed under the [MIT License](LICENSE).
