# Web client and gateway

Follow the [root rules](../../AGENTS.md). This Solid/Vite client and Zig gateway are detached daemon clients: `core.snapshot` / `core.changes`, `chat.turn.start`, and `session.*`. They must survive desktop closure; no Desktop Live/mock fallback.

## Commands

Run from the repository root. Token fixtures, serving, and tunnel examples: [README](README.md).

| Work | Command |
| --- | --- |
| Focused checks | `mise run web-app-types`, `mise run web-app-test`; JS tests: `bun test` in this package |
| Final gateway/UI build | `mise run web-app` |
| HMR gateway | `mise run web-app-run -- --token-file <path>` |
| HMR UI | `mise run web-app-dev` |

Browser-facing port is **6783**; the HMR gateway uses **7420**, with Vite proxying `/login`, `/auth`, `/api`, and `/ws`. Built SPA mode serves everything on 6783 without Vite. Bind loopback, respect port leases, and never substitute Vite's default 5173.

## Security contract

- Bind only `127.0.0.1`, `localhost`, or `::1`. Keep the daemon socket host-private; the gateway is the network adapter.
- Require an owner-only, regular, non-symlink token file containing at least 32 printable bytes. Pass its path via `--token-file` / `VERDE_WEB_TOKEN_FILE`; never accept raw `--token`, `VERDE_WEB_TOKEN`, query tokens, or `X-Verde-Token`.
- Browser sessions are bounded, in-memory, `HttpOnly; SameSite=Strict`; API clients may use Bearer auth. Never expose credentials in URLs, process arguments, logs, screenshots, or support output.
- Only liveness-only `GET /healthz`, login pages/scripts, and trusted static assets are public. Redirect unauthenticated app navigation to login; authenticate APIs and the exact `GET /ws` upgrade.
- Serve static files only from the trusted built SPA. No permissive CORS, arbitrary file access, `/api/file`, `/api/preview`, or repository HTML/SVG previews.
- Preserve plain loopback/SSH access. Trusted proxy mode accepts one configured origin's complete exact Tailscale-style HTTPS envelope; reject partial/mixed/duplicate or standard `Forwarded` headers. No public bind/NAT, Funnel, or arbitrary public proxy; use ownership-checked `verde-server serve --tailscale` or local SSH forwarding. Never overwrite user tunnels.

## Terminal and PWA

- Extend `web/src/lib/ghostty_vt.ts`; use official SIMD128 wasm, no third-party wrappers. Keep its commit aligned with desktop `build.zig.zon`; pin/hash/bump procedure: [NOTICE](web/src/assets/ghostty-vt.NOTICE.md).
- `web/public/sw.js` must not cache `/api`, `/auth`, `/login`, `/healthz`, or `/ws`. Manifest/service-worker changes may require a hard refresh.
