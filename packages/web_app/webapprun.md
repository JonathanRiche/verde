# Run the Verde web app on another VM

This runbook covers the current open-source, single-user VM deployment. The GUI-free daemon and loopback web gateway do not require a Verde account. Remote browser access is through an SSH local forward.

The gateway rejects public/LAN binds. Public HTTPS, Cloudflare Tunnel, Tailscale Funnel/Serve, and direct reverse-proxy deployment are not supported in this release. The native desktop's remote connection manager and SSH profiles are also still pending.

For a long-running installation, use the systemd units, backup guidance, and provider credential notes in [Standalone Daemon Deployment](../../docs/daemon-deployment.md). This file focuses on a source-checkout smoke run.

## Processes and ports

The deployment has independent processes:

1. `verde-daemon serve` owns runtime state, turns, provider processes, and PTYs. It listens only on the private `verde-sessionizer.sock` Unix socket.
2. `verde-web` adapts that socket to authenticated HTTP/WebSocket on loopback.
3. In development only, Vite serves HMR on port 6783 and proxies to `verde-web` on port 7420.

| Mode | Browser port | Gateway port | Network bind |
| --- | --- | --- | --- |
| Bundled SPA | 6783 | 6783 | `127.0.0.1` |
| Vite HMR | 6783 | 7420 | Both listeners use `127.0.0.1` |

Keep the VM firewall closed to both ports. The client-side SSH forward is the only supported remote network path.

## Build the two artifacts

Run these commands from the repository root:

```bash
mise install
zig build daemon --release=safe -Dbrowser-backend=native_webview
mise run web-app
```

The standalone daemon staging tree contains:

```text
zig-out/bin/verde-daemon
zig-out/share/verde/provider_bridge.mjs
```

The web build produces:

```text
packages/web_app/zig-out/bin/verde-web
packages/web_app/dist/
```

Preserve the daemon binary's relative `../share/verde/provider_bridge.mjs` layout when copying it out of the repository.

## Initialize and start the daemon

Choose one explicit data directory. The shell variable below is only for the runbook; the daemon does not read `VERDE_DATA_DIR` itself. Repeat this export in each terminal that uses the variable.

```bash
export VERDE_DATA_DIR="$HOME/.local/share/verde/runtime"
unset VERDE_SESSIONIZER_SOCKET

./zig-out/bin/verde-daemon init \
  --data-dir "$VERDE_DATA_DIR" \
  --json
```

In terminal A, keep the daemon in the foreground:

```bash
./zig-out/bin/verde-daemon serve --data-dir "$VERDE_DATA_DIR"
```

From another shell, verify the real daemon and its durable store:

```bash
export VERDE_DATA_DIR="$HOME/.local/share/verde/runtime"
unset VERDE_SESSIONIZER_SOCKET
./zig-out/bin/verde-daemon status \
  --data-dir "$VERDE_DATA_DIR" \
  --json
```

The web gateway does not start a daemon and has no mock/review fallback. A browser may receive static assets while the daemon is unavailable, but runtime requests fail instead of returning invented state. `GET /healthz` checks only the gateway process, so use `verde-daemon status` when verifying runtime readiness.

Do not run the hidden desktop `__session-daemon` entry point. Do not expose `verde-sessionizer.sock` over TCP or copy the SQLite database into a web process.

## Create the mandatory token file

Generate one administrator token as the same VM user that will run `verde-web`:

```bash
install -d -m 700 "$HOME/.config/verde"
umask 077
openssl rand -hex 32 > "$HOME/.config/verde/web-token"
chmod 600 "$HOME/.config/verde/web-token"
```

The token file must be a regular, non-symlink file with no group/other permissions. The token must contain at least 32 printable non-space bytes; the command above writes 64 hexadecimal characters.

Only pass the file path to `verde-web`. Raw `--token`, `VERDE_WEB_TOKEN`, query-string tokens, and `X-Verde-Token` are obsolete and rejected. Do not print the token in logs or place it in a shell command argument.

## Option A: bundled SPA and gateway

Bundled mode is the recommended VM path. It serves static assets, authenticated APIs, and the WebSocket from one loopback listener.

In terminal B, from the repository root:

```bash
export VERDE_DATA_DIR="$HOME/.local/share/verde/runtime"
mise run web-app-run -- \
  --host 127.0.0.1 \
  --port 6783 \
  --token-file "$HOME/.config/verde/web-token" \
  --pref-path "$VERDE_DATA_DIR"
```

The equivalent command after the build is:

```bash
./packages/web_app/zig-out/bin/verde-web \
  --host 127.0.0.1 \
  --port 6783 \
  --token-file "$HOME/.config/verde/web-token" \
  --pref-path "$VERDE_DATA_DIR" \
  --static packages/web_app/dist
```

Verify the loopback listener and inventory-free liveness route on the VM:

```bash
ss -ltnp | rg '127\.0\.0\.1:6783'
curl -fsS http://127.0.0.1:6783/healthz
```

Do not also start Vite in bundled mode; it would compete for port 6783.

## Open the SSH local forward

From the browser's machine, use the VM account's normal SSH configuration and host-key policy:

```bash
ssh -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6783:127.0.0.1:6783 \
  verde-runtime
```

Open `http://127.0.0.1:6783/login`. Enter the VM token; the browser posts it to `/auth/session`, receives an `HttpOnly; SameSite=Strict` session cookie, and continues to the SPA at `/`. The SPA then uses the same-origin cookie for APIs and the exact `/ws` WebSocket endpoint.

Never append `?token=...` to the URL. Keep the local SSH listener on `127.0.0.1`, not `0.0.0.0`, and do not disable SSH host-key verification.

The browser-facing endpoint is ordinary HTTP on its own loopback interface, so the current cookie is not marked `Secure`. SSH encrypts transit between machines. This model must not be repurposed as a public HTTP service.

## Option B: frontend development with HMR

Use HMR only while editing the frontend. The standalone daemon from terminal A must still be running.

Start the authenticated gateway on its default loopback port in terminal B:

```bash
export VERDE_DATA_DIR="$HOME/.local/share/verde/runtime"
mise run web-app-run -- \
  --token-file "$HOME/.config/verde/web-token" \
  --pref-path "$VERDE_DATA_DIR"
```

Start Vite in terminal C:

```bash
mise run web-app-dev
```

Open `http://127.0.0.1:6783/login`. Vite proxies `/login`, `/auth`, `/api`, and `/ws` to the gateway at `127.0.0.1:7420`. Use the same SSH local-forward command from the bundled instructions if the browser is on another machine.

The repository's Vite configuration binds `127.0.0.1:6783`. Keep it as a development tool, not a deployment server, and use the same SSH local forward when the browser is on another machine.

To verify HMR without sending the administrator token from a command line:

```bash
curl -fsS http://127.0.0.1:7420/healthz
curl -fsS http://127.0.0.1:6783/login
ss -ltnp | rg ':(6783|7420)\b'
```

## Authentication behavior

`GET /healthz`, `GET /login`, `GET /login.js`, and trusted static assets are public. Unauthenticated app-shell navigation redirects to `/login`; runtime inventory is not public.

`POST /auth/session` is the only token-to-browser-session exchange. Failed attempts are rate-limited. Browser sessions are bounded, expire in memory, and disappear when `verde-web` restarts. The configured administrator token may also be presented through `Authorization: Bearer` by a non-browser API client.

Every runtime API and exact `GET /ws` upgrade requires a valid browser session or bearer. The gateway rejects query-token and legacy custom-header authentication, permissive cross-origin requests, non-loopback Host values, and WebSocket targets other than exact `/ws`.

To rotate the token, replace the owner-only token file and restart `verde-web`. The restart clears all issued browser sessions. Persistent token scopes, per-token metadata, and selective revocation are not implemented.

## Provider setup on the VM

Install and authenticate provider CLIs as the same VM UID and `HOME` used by `verde-daemon`. A login performed under another account is not visible to the runtime. Systemd user services also do not source shell startup files, so provider installation directories must be present in the service's explicit `PATH`.

Inspect the eight integration rows with:

```bash
./zig-out/bin/verde-daemon providers status \
  --data-dir "$VERDE_DATA_DIR" \
  --json
```

The command currently reports bounded executable installation checks for Codex, Claude, Cursor, OpenCode, Amp, Pi, FX, and Grok. Authentication is always reported as `unknown`; it does not prove whether the provider login succeeded. Run each provider's own login flow manually as the runtime user.

## Troubleshooting

- `TokenFileRequired`: add `--token-file` with an absolute or correctly resolved owner-only path.
- `InsecureTokenFilePermissions`: run `chmod 600` on the token file and ensure its parent directory is private.
- `NonLoopbackHost`: remove the public bind. The supported value is `127.0.0.1` with an SSH local forward.
- `/healthz` succeeds but runtime calls fail: the gateway process is alive, but the daemon may be stopped or using another data directory. Run `verde-daemon status --data-dir "$VERDE_DATA_DIR" --json`.
- Browser receives `401`: log in again at `http://127.0.0.1:6783/login`. Do not try a query token or legacy header.
- Browser receives an origin/Host rejection: use the exact SSH-forwarded `http://127.0.0.1:6783/` origin and do not access the VM IP directly.
- WebSocket reconnects repeatedly: confirm the session cookie was issued, the browser targets exact `/ws`, and the SSH forward is still alive.
- Vite reports `/auth`, `/api`, or `/ws` proxy failures: confirm `verde-web` is listening on loopback port 7420 with the same daemon data directory.
- Port 6783 or 7420 is occupied: inspect `ss -ltnp`; stop only the exact process you own.
- `providers status` says `installed=false`: the provider executable is absent from the daemon service's `PATH`.
- `providers status` says `authentication=unknown`: that is the current expected result; verify with the provider's own CLI.

## Stop safely

Stop only processes started by this runbook, normally with `Ctrl-C` in the gateway/Vite terminals. Stop the daemon last. Its `SIGINT`/`SIGTERM` handler enters the daemon's PID-checked prepare-shutdown path and waits for a safe exit.

Do not use `pkill verde` or `kill -9` for normal cleanup. When working through a Verde-hosted agent session, do not run `mise run dev` or `mise run dev-term`; those commands can terminate the session that owns the work.
