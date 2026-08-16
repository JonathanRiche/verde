# AGENTS.md — `packages/web_app`

This package is the first-party Verde **web client**: Solid + Vite UI and a Zig HTTP/WebSocket gateway (`verde-web`) that talks to the **headless session daemon** (`verde-sessionizer.sock`). Desktop Live (`verde.sock`) is optional fallback only.

UIs are detached: they project `core.snapshot` / `core.changes`, send chat via `chat.turn.start`, and drive PTYs via `session.*`. Closing the desktop app must not take the web client down.

Do not start `mise run dev` / `pkill verde` from a Verde pane that owns the agent session.

## Ports

| What | Port | Bind |
| --- | --- | --- |
| **Web UI (dev and prod)** | **6783** | `0.0.0.0` in Vite; pass `--host 0.0.0.0` for `verde-web` |
| Zig gateway during Vite HMR | 7420 | `127.0.0.1` (Vite proxies `/api` and `/ws` here) |

**Always use 6783 for the URL people open.** Do not use Vite’s default 5173 — other apps in this environment already take that port.

- Local: `http://127.0.0.1:6783/`
- LAN / Tailscale IP: `http://<host>:6783/`
- Real PWA **Install app** needs HTTPS (see Tunnels below). Plain `http://` only offers a browser shortcut.

## Testing (dev)

From the repo root, with the session daemon already running (`verde-sessionizer.sock` under the Verde pref path):

```bash
# Terminal A — gateway (only if one is not already listening on 7420)
mise run web-app-run

# Terminal B — Vite HMR UI on :6783
mise run web-app-dev
```

`mise run web-app-dev` is the test path. It binds Vite to `0.0.0.0:6783` and proxies `/api` + `/ws` to `127.0.0.1:7420`.

Quick checks:

- `mise run web-app-types` while iterating on the Solid app
- `mise run web-app-test` for gateway Zig tests
- `curl -sS http://127.0.0.1:6783/` and `curl -sS http://127.0.0.1:7420/api/health`

Do not run a second `web-app-dev` if 6783 is already taken. Inspect `ss -ltnp | rg 6783` first.

## After testing — production mode on 6783

When the UI is good enough to use without HMR, stop Vite and serve the built SPA **on the same port (6783)** from `verde-web`:

```bash
# From repo root
mise run web-app
./packages/web_app/zig-out/bin/verde-web --host 0.0.0.0 --port 6783 --static packages/web_app/dist
```

Or from `packages/web_app` after `zig build --release=safe && bun run build`:

```bash
./zig-out/bin/verde-web --host 0.0.0.0 --port 6783 --static dist
```

`mise run web-app-run` still defaults to **7420**. For prod on 6783 you must pass `--port 6783` (and `--host 0.0.0.0` if phones / tunnels should reach it):

```bash
mise run web-app-run -- --host 0.0.0.0 --port 6783
```

In this mode there is no Vite proxy: `/`, `/api`, and `/ws` all come from `verde-web`.

Optional: set `VERDE_WEB_TOKEN` and open `/?token=…` if the listen address is more than a personal tailnet.

## Tunnels — user-owned only

Do **not** start a Cloudflare tunnel, Tailscale Funnel, or Tailscale Serve for the user unless they explicitly ask. They bring their own.

Point whatever they already use at **this machine, port 6783**. Examples they may run themselves:

```bash
# Tailnet-only HTTPS (PWA install). Replaces this node's Serve config for :443.
sudo tailscale serve --bg 6783

# Public HTTPS on the tailnet Funnel (internet-visible). User's choice.
sudo tailscale funnel --bg 6783

# Cloudflare quick tunnel (user's cloudflared).
cloudflared tunnel --url http://127.0.0.1:6783
```

Notes for agents:

- `tailscale serve` / `funnel` add HTTPS on this node’s MagicDNS name (port 443 → 6783). They do **not** block `http://<tailscale-ip>:6783` or other ports (`:5173`, `:3000`, …).
- `sudo tailscale serve reset` / `sudo tailscale funnel reset` undo that node config.
- Serve/funnel often need `sudo` or `sudo tailscale set --operator=$USER` once. Do not loop on a failing sudo prompt.
- Android Chrome **Install app** requires the **https://\*.ts.net** (or Cloudflare HTTPS) URL, not `http://100.x:6783`.

## Terminal engine (ghostty-vt.wasm)

The web terminal uses the official pre-built `ghostty-vt.wasm` from upstream `ghostty-org/ghostty`, vendored at `web/src/assets/` with its pin, SHA-256, and bump procedure documented in `ghostty-vt.NOTICE.md` beside it. The Verde-owned binding is `web/src/lib/ghostty_vt.ts`.

- The wasm commit must match the desktop Zig pin in `packages/desktop/build.zig.zon` — bump both together, never independently.
- Fresh builds come from `https://tip.files.ghostty.org/<commit>/ghostty-vt.wasm`; update the NOTICE (commit + hash) whenever the wasm changes.
- The module requires wasm SIMD128 (any current browser).
- Do not reintroduce third-party wrapper packages (e.g. `@slopus/ghostty-wasm`); extend the binding instead.

## PWA

Manifest, icons, and `sw.js` live under `web/public/`. Service worker must not cache `/api` or `/ws`. After changing SW/manifest, users may need a hard refresh on the phone.

## Safety

- Never `pkill verde`, `mise run dev`, or relaunch the desktop from a Verde-hosted session.
- Never force a Tailscale Serve/Funnel that would overwrite a config the user did not ask to change.
- Prefer `6783` in any URL, screenshot note, or handoff you write for this package.
