# Verde web client

The Verde web client is a Solid + Vite SPA with a small Zig HTTP/WebSocket gateway. `verde-web` is a detached client of the GUI-free session daemon; the desktop app does not need to be running.

The desktop remains the native Palette/SDL client. This package owns browser presentation, focus, and rendering. The session daemon owns workspaces, transcripts, turns, and PTYs.

## Layout

```text
packages/web_app/
  src/           Zig gateway: HTTP, WebSocket, auth, daemon client
  web/           Solid SPA
  dist/          bun run build output, served by verde-web
```

Zig is the repository-pinned 0.16 toolchain from the root [`mise.toml`](../../mise.toml). Use `mise` from the repository root instead of a system Zig installation.

## Current security model

The first remote release is loopback plus SSH only:

- `verde-web` rejects non-loopback binds.
- An owner-only token file is required at startup.
- Browser login uses `POST /auth/session` and receives a bounded, in-memory, `HttpOnly; SameSite=Strict` cookie.
- Every runtime API and the exact `/ws` WebSocket upgrade requires that cookie or an `Authorization: Bearer` credential.
- `GET /healthz` is the only unauthenticated health route and exposes liveness, not runtime inventory. `GET /login`, `GET /login.js`, and trusted static assets are public; unauthenticated app navigation redirects to `/login`.
- The gateway talks only to `verde-sessionizer.sock`. It has no Desktop Live or mock fallback.
- Arbitrary filesystem browsing and the legacy `/api/file` and `/api/preview` routes are not available.

Do not pass secrets through `--token`, `VERDE_WEB_TOKEN`, `?token=...`, or `X-Verde-Token`. Those legacy forms are rejected. Pass only a token-file path through `--token-file` or `VERDE_WEB_TOKEN_FILE`.

Do not expose the gateway with a public bind, public firewall/NAT port, Cloudflare Tunnel, Tailscale Funnel/Serve, or a public reverse proxy. See [Standalone Daemon Deployment](../../docs/daemon-deployment.md) for the supported SSH-forwarded VM setup.

## Build and checks

From the repository root:

```bash
mise install
mise run web-app
mise run web-app-test
mise run web-app-types
cd packages/web_app && bun test
```

`mise run web-app` builds `packages/web_app/zig-out/bin/verde-web` and `packages/web_app/dist/`. These build/test commands do not start a server.

## Run the built client

Create a development token without placing the secret in a process argument or URL:

```bash
gateway_token_dir="$(mktemp -d)"
chmod 700 "$gateway_token_dir"
openssl rand -hex 32 > "$gateway_token_dir/token"
chmod 600 "$gateway_token_dir/token"
```

With a session daemon already serving its data directory, run the bundled SPA and gateway on loopback port 6783:

```bash
mise run web-app-run -- \
  --port 6783 \
  --token-file "$gateway_token_dir/token" \
  --pref-path "$HOME/.local/share/verde/runtime"
```

Open `http://127.0.0.1:6783/login` and enter the token. The login page continues to the SPA after the session cookie is issued. Never append the token to the URL. Remove the temporary token directory after the gateway stops.

The gateway does not start the session daemon. Use `verde-daemon init/serve/status` or the systemd user unit in the deployment guide.

## Hot reload

Start the authenticated gateway on its default loopback port in one terminal:

```bash
mise run web-app-run -- \
  --token-file "$gateway_token_dir/token" \
  --pref-path "$HOME/.local/share/verde/runtime"
```

Start Vite in a second terminal:

```bash
mise run web-app-dev
```

Open `http://127.0.0.1:6783/login`. Vite proxies `/login`, `/auth`, `/api`, and `/ws` to the gateway on port 7420.

Vite also binds `127.0.0.1:6783`. Keep it as a development-only process and use an SSH local forward if the browser is on another machine.

| Task | Command |
| --- | --- |
| Install JS dependencies | `mise run web-app-setup` |
| Build gateway + SPA | `mise run web-app` |
| Zig tests | `mise run web-app-test` |
| Typecheck SPA | `mise run web-app-types` |
| Frontend tests | `cd packages/web_app && bun test` |
| Serve built SPA | `mise run web-app-run -- --token-file <path>` |
| Vite proxy/HMR | `mise run web-app-dev` |

Do not start duplicate gateway or Vite processes. Inspect `ss -ltnp | rg ':(6783|7420)\b'` first and respect the existing owner.

## Protocol routes

- `GET /healthz` reports gateway liveness without daemon inventory.
- `GET /login` and `GET /login.js` provide the public, no-store login flow; unauthenticated app navigation redirects there.
- `POST /auth/session` verifies the token and issues the browser session cookie.
- `POST /api/rpc` forwards one bounded JSON-RPC envelope to the headless session daemon.
- `GET /api/status` and `GET /api/snapshot` are authenticated convenience wrappers over `core.status` and `core.snapshot`.
- Exact `GET /ws` upgrades to the authenticated WebSocket projection. It sends the initial snapshot, pushes bounded `core.changes`, and accepts client RPC calls.

`core.subscribe` remains reserved. The gateway paces daemon `core.changes` polling and fans changes out over authenticated WebSockets.

## Options

```text
verde-web --token-file <path> [--host 127.0.0.1] [--port 7420]
          [--pref-path <daemon-data-dir>] [--sessionizer <socket>]
          [--static <dist-dir>]
```

Safe configuration environment variables are `VERDE_WEB_HOST`, `VERDE_WEB_PORT`, `VERDE_WEB_TOKEN_FILE`, `VERDE_PREF_PATH`, `VERDE_WEB_STATIC`, and `VERDE_SESSIONIZER_SOCKET`. `VERDE_WEB_HOST` is still subject to the strict loopback check.

Do not run `mise run dev`, relaunch the desktop, or use `pkill verde` from a Verde pane that owns the active agent session. Coordinate and track any gateway/Vite process you start.
