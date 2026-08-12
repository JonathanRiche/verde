# Verde web client

A first-party **web client** of the headless Verde daemon: Solid + Vite for presentation, a small Zig HTTP/WebSocket gateway for Zig-to-Zig protocol talk.

The desktop app stays the native Palette/SDL client. This package owns layout, focus, and rendering. It does not own workspaces, transcripts, or PTYs.

## Layout

```
packages/web_app/
  src/           Zig gateway (HTTP, WebSocket, unix-socket daemon client)
  web/           Solid SPA
  dist/          `bun run build` output, served by verde-web
```

Bind address defaults to `127.0.0.1`. Remote access is an SSH tunnel, not a public listen.

Zig is the repo-pinned `0.16.0` from root [`mise.toml`](../../mise.toml). Use `mise` from the repo root — do not rely on a system `zig`.

## Dev

From the repo root:

```bash
mise install          # zig 0.16.0 + zls
mise run web-app      # zig gateway + Solid SPA
mise run web-app-run  # serve http://127.0.0.1:7420/
```

Hot-reload the UI against that gateway (second terminal):

```bash
mise run web-app-dev
```

Vite is on `http://127.0.0.1:6783` (all interfaces) and proxies `/api` + `/ws` to `:7420`.

| Task | Command |
| --- | --- |
| Install JS deps | `mise run web-app-setup` |
| Build gateway + SPA | `mise run web-app` |
| Zig tests | `mise run web-app-test` |
| Typecheck SPA | `mise run web-app-types` |
| Serve built SPA | `mise run web-app-run` |
| Vite proxy / HMR | `mise run web-app-dev` |

`mise run web-app-run -- --port 7421` forwards extra flags to `verde-web`.

If the session daemon is not running, the gateway serves a review snapshot so the UI is still usable.

Do not start `web-app-run` from a Verde pane that owns this agent session if you are also iterating on the desktop daemon. The web gateway only talks over sockets; it does not replace `mise run dev`.

## Protocol

- `POST /api/rpc` — one JSON-RPC envelope, forwarded to the headless session daemon (`verde-sessionizer.sock`). Live (`verde.sock`) is only a fallback for methods the daemon does not implement
- `GET /api/status`, `GET /api/snapshot` — convenience wrappers over `core.status` / `core.snapshot`
- `WS /ws` — hello, then `core.snapshot` (`store` + `sessions` + `turns`); `core.changes` is pushed as notifications; client calls go the other way

`core.subscribe` is reserved and not dispatched by the daemon yet. The gateway long-polls `core.changes` and fans the result out over WebSocket.

## Options

```
verde-web --host 127.0.0.1 --port 7420 --token <secret> --static dist
```

Environment: `VERDE_WEB_HOST`, `VERDE_WEB_PORT`, `VERDE_WEB_TOKEN`, `VERDE_PREF_PATH`, `VERDE_SESSIONIZER_SOCKET`, `VERDE_LIVE_ENDPOINT`.
