# AGENTS.md — `packages/web_app`

This package is the first-party Verde web client: a Solid + Vite UI and the Zig HTTP/WebSocket gateway (`verde-web`). The gateway is a detached client of the headless session daemon (`verde-sessionizer.sock`) and has no Desktop Live or mock fallback in production.

UIs project `core.snapshot` / `core.changes`, send chat through `chat.turn.start`, and drive PTYs through `session.*`. Closing the desktop app must not take the web client down.

Do not start `mise run dev`, relaunch Verde, or use `pkill verde` from a Verde pane that owns the agent session.

## Security contract

The gateway listener remains loopback-only. It supports plain loopback/SSH
requests and one explicitly configured trusted HTTPS proxy origin:

- `verde-web` accepts only `127.0.0.1`, `localhost`, or `::1`; a public/LAN bind is a configuration error.
- A token file is mandatory. It must be an owner-only, regular, non-symlink file containing at least 32 printable bytes.
- Pass only the token-file path through `--token-file` or `VERDE_WEB_TOKEN_FILE`. Raw `--token`, `VERDE_WEB_TOKEN`, query-string tokens, and `X-Verde-Token` are forbidden.
- Browser login creates a bounded, in-memory, `HttpOnly; SameSite=Strict` session cookie. API clients may use `Authorization: Bearer`, but authorization data must never be logged.
- `GET /healthz` reveals liveness only. `GET /login`, `GET /login.js`, and trusted static assets are also public; unauthenticated app navigation redirects to `/login`. APIs and the exact `GET /ws` upgrade require authentication.
- Keep the session daemon's Unix socket private to the host. The gateway is the only network adapter.
- Do not restore Desktop Live/mock fallback, permissive CORS, arbitrary file browsing, `/api/file`, or `/api/preview`.
- Trusted-proxy mode must preserve plain loopback/SSH requests and accept only
  the complete exact Tailscale-style forwarded HTTPS envelope. Partial, mixed,
  duplicate, or standard `Forwarded` headers fail closed. Do not use Tailscale
  Funnel, an arbitrary public reverse proxy, or a public firewall/NAT port.

Static assets must come from the trusted built SPA directory. Do not turn static serving into a general filesystem server, and do not add repository HTML/SVG preview as an authenticated shortcut.

## Ports

| What | Port | Bind |
| --- | --- | --- |
| Web UI during Vite HMR | 6783 | Loopback; development only |
| Zig gateway during Vite HMR | 7420 | Loopback; Vite proxies `/login`, `/auth`, `/api`, and `/ws` |
| Built SPA and gateway | 6783 | Loopback only; pass `--port 6783` |

Use `http://127.0.0.1:6783/` as the browser URL. Do not use Vite's default port 5173. The HMR server is loopback-only and remains a development tool, not a deployment server.

## Token fixture

Create a fresh development token without placing the secret in a process argument or URL:

```bash
gateway_token_dir="$(mktemp -d)"
chmod 700 "$gateway_token_dir"
openssl rand -hex 32 > "$gateway_token_dir/token"
chmod 600 "$gateway_token_dir/token"
```

Pass `--token-file "$gateway_token_dir/token"` to the gateway. Remove the temporary directory after the gateway stops. Never print the token in a handoff or test log.

## Testing with HMR

From the repository root, with the session daemon already running:

```bash
# Terminal A — loopback gateway on 7420
mise run web-app-run -- --token-file "$gateway_token_dir/token"

# Terminal B — Vite UI on 6783
mise run web-app-dev
```

Open `http://127.0.0.1:6783/login` and enter the token. After login, continue to the SPA at `http://127.0.0.1:6783/`. The token must not appear in the URL.

Quick non-mutating checks:

```bash
curl -fsS http://127.0.0.1:7420/healthz
curl -fsS http://127.0.0.1:6783/login
```

Do not run a second gateway or Vite process if its port is occupied. Inspect `ss -ltnp | rg ':(6783|7420)\b'` and respect the existing owner.

## Verification without servers

Use the narrowest relevant check while iterating:

```bash
mise run web-app-types
mise run web-app-test
cd packages/web_app && bun test
```

Before handing off a complete gateway/UI change, also build both artifacts:

```bash
mise run web-app
```

These checks do not require opening a listening port.

## Built SPA on port 6783

After `mise run web-app`, serve the built SPA and gateway from one loopback process:

```bash
./packages/web_app/zig-out/bin/verde-web \
  --host 127.0.0.1 \
  --port 6783 \
  --token-file /absolute/owner-only/path/to/web-token \
  --static packages/web_app/dist
```

Or, from `packages/web_app`:

```bash
./zig-out/bin/verde-web \
  --port 6783 \
  --token-file /absolute/owner-only/path/to/web-token \
  --static dist
```

In this mode `/`, `/api`, and `/ws` all come from `verde-web`; do not also run Vite on 6783.

For a manually administered VM, leave the gateway on loopback and use either
the ownership-checked `verde-server serve --tailscale` flow or a local-only SSH
forward with normal host-key verification:

```bash
ssh -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6783:127.0.0.1:6783 \
  verde-runtime
```

Then open `http://127.0.0.1:6783/login`; the login page continues to the SPA
after the session cookie is issued. The SSH tunnel encrypts network transit.
In Tailnet mode, Tailscale Serve terminates private HTTPS and forwards to the
same loopback gateway; the gateway does not bind publicly or implement TLS.

## Terminal engine (`ghostty-vt.wasm`)

The web terminal uses the official pre-built `ghostty-vt.wasm` from upstream `ghostty-org/ghostty`, vendored under `web/src/assets/`. Its pin, SHA-256, and bump procedure are in `ghostty-vt.NOTICE.md` beside it. The Verde-owned binding is `web/src/lib/ghostty_vt.ts`.

- The wasm commit must match the desktop Zig pin in `packages/desktop/build.zig.zon`; bump both together.
- Fresh builds come from `https://tip.files.ghostty.org/<commit>/ghostty-vt.wasm`; update the NOTICE whenever it changes.
- The module requires wasm SIMD128 in the browser.
- Do not reintroduce a third-party wrapper package; extend the existing binding.

## PWA

Manifest, icons, and `sw.js` live under `web/public/`. The service worker must not cache `/api`, `/auth`, `/login`, `/healthz`, or `/ws`. After changing the service worker or manifest, users may need a hard refresh.

## Safety

- Never put a credential in a URL, process argument, screenshot, console message, or support output.
- Never weaken the loopback bind or authentication checks to make a remote test convenient.
- Never navigate, reset, or terminate a browser session owned by another pane/workspace.
- Never force a public tunnel or overwrite a user-owned tunnel configuration.
- Prefer port 6783 for browser-facing examples and 7420 only for the HMR gateway backend.
