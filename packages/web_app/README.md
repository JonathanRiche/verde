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

The gateway supports two explicit request envelopes while its listener remains loopback-only:

- `verde-web` rejects non-loopback binds.
- An owner-only token file is required at startup.
- Browser login uses `POST /auth/session` and receives a bounded, in-memory, `HttpOnly; SameSite=Strict` cookie.
- Every runtime API and the exact `/ws` WebSocket upgrade requires that cookie or an `Authorization: Bearer` credential.
- `GET /healthz` is the only unauthenticated health route and exposes liveness, not runtime inventory. `GET /login`, `GET /login.js`, and trusted static assets are public; unauthenticated app navigation redirects to `/login`.
- The gateway talks only to `verde-sessionizer.sock`. It has no Desktop Live or mock fallback.
- Folder browsing is confined to daemon-authorized roots. Authenticated `/api/file` and `/api/preview` serve workspace documents opened from chat (PDF and office files) after absolute-path validation; HTML/SVG/JS are rejected.
- Plain loopback requests support local use and SSH forwarding. Optional trusted-proxy mode accepts only the complete, exact forwarded HTTPS envelope for one configured origin, as used by Tailscale Serve; partial, mixed, duplicate, or standard `Forwarded` headers fail closed.

Do not pass secrets through `--token`, `VERDE_WEB_TOKEN`, `?token=...`, or `X-Verde-Token`. Those legacy forms are rejected. Pass only a token-file path through `--token-file` or `VERDE_WEB_TOKEN_FILE`.

Do not expose the gateway with a public bind, public firewall/NAT port, Tailscale Funnel, or an arbitrary public reverse proxy. Private Tailnet HTTPS through the ownership-checked `verde-server serve --tailscale` flow and SSH forwarding are supported; see [Standalone Daemon Deployment](../../docs/daemon-deployment.md) and [Verde Serve, Pair, and Connect](../../docs/serve-pair-connect.md).

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

The gateway adds `core.changes.delta.v1` to forwarded `core.status` and
`core.capabilities` responses, including the status in `core.hello`. The daemon
alone does not advertise it. After hello, send a targeted WebSocket RPC
`core.changes.mode` with `{"mode":"delta","cursor":123}` to resume at a saved
cursor; omit `cursor` to use the initial snapshot's `change_cursor`. The response
acknowledges `{mode,cursor}`. The existing initial snapshot precedes opt-in.
After the acknowledgement, only `core.changes` notifications follow (with the
same response envelope as legacy mode), except for one recovery snapshot on
`expired` or an `envelope.instance_nonce` change. Recovery reseeds polling from
the snapshot cursor. A failed recovery closes the connection for reconnect;
runtime-target mismatches still fail closed. Legacy clients retain their existing
snapshot behavior. Keep interactive and parked calls on `/api/rpc`; WebSocket
RPC dispatch is still sequential.

The loopback integration regression uses a temporary daemon fixture and no user
state: after `mise run web-app`, run
`python3 packages/web_app/tests/delta_feed.py` from the repository root.

`core.subscribe` remains reserved. The gateway paces daemon `core.changes` polling and fans changes out over authenticated WebSockets.

## Options

```text
verde-web --token-file <path> [--host 127.0.0.1] [--port 7420]
          [--pref-path <daemon-data-dir>] [--sessionizer <socket>]
          [--static <dist-dir>]
```

Safe configuration environment variables are `VERDE_WEB_HOST`, `VERDE_WEB_PORT`, `VERDE_WEB_TOKEN_FILE`, `VERDE_PREF_PATH`, `VERDE_WEB_STATIC`, and `VERDE_SESSIONIZER_SOCKET`. `VERDE_WEB_HOST` is still subject to the strict loopback check.

Do not run `mise run dev`, relaunch the desktop, or use `pkill verde` from a Verde pane that owns the active agent session. Coordinate and track any gateway/Vite process you start.

### Per-chat connections

The chat actions menu contains Workspace and Connection selectors on desktop and
mobile. New chats inherit `workspace-runtime-defaults.json`; an explicit Local or
remote choice overrides the default. Changing workspace opens a new chat there.
Committed conversations retain their connection. Model/effort edits preserve the
route, and remote sends use the runtime's repository binding rather than the
local workspace path.

The gateway reads the same user's `runtime-profiles.json` and workspace defaults
as the desktop and uses the shared runtime connection service. Deploy the gateway
and SPA together. Profiles must exist on the **gateway host**; the browser does
not import profiles from another computer. Saved paired-device credentials are
loaded from that user's OS keyring. Process-memory-only desktop credentials are
not available to the gateway. Missing credentials, unverified identities, and
unavailable repositories fail without falling back to Local.

`GET /api/chat-connections` and `POST /api/chat-connection-rpc` require an owner
login (or the gateway owner bearer); runtime-scoped paired clients cannot use the
host's other saved connections. The browser receives only connection labels,
readiness, runtime IDs, and workspace defaults. Credentials and remote endpoints
remain server-side. The bridge permits only chat execution/control/read methods
and repository inspection. Remote web-chat image uploads are currently rejected
with the draft attachments retained; local uploads continue to work.

### Confined directory browsing

The web **Add Workspace** dialog accepts an optional workspace name for both
new and existing folders. A blank name keeps the generated or folder-derived
name. It creates a managed folder when its optional
path is empty, using the same Verde data-root `workspaces/` directory and
`verde.toml` defaults as desktop. **Browse** opens a tappable host folder picker;
no path typing or native dialog on the phone is required. Creation uses daemon
RPC `workspace.create` with store mutation metadata and optional `path`, under
`repository:write` for paired clients. Existing directories are imported without
changing their files.

Paired clients can call daemon RPC `workspace.directory.list {"path":"/absolute/path"}`
with `repository:read`; `workspace.directory.v1` advertises support. It returns
`{path,parent,directories:[{name,path}]}` with directories only (maximum 4096).
Omit `path` to start at the daemon home directory (or the first authorized root).
The daemon allows its home directory, parents of existing persisted workspace
directories, and additional absolute roots in its colon-separated
`VERDE_DIRECTORY_ROOTS` environment variable. Missing roots are ignored. No
client-supplied root is accepted. Parent navigation stops at the policy boundary.
Paths containing `..`, escaping symlinks, and non-directory entries are rejected
or omitted. Linux permits relative in-root directory symlinks; the portable
fallback rejects symlinks. Listing uses a descriptor opened beneath the root,
so the desktop need not be running. The legacy `web.directory.list` remains
blocked.

## Host desktop (experimental)

The sidebar's **Host desktop** opens an owner-only noVNC viewer for the gateway
host. This is independent of the chat connection selector: selecting a saved
remote chat runtime does **not** switch the desktop. For a remote Omarchy box,
run the gateway and host helper on that box and use its private SSH/Tailscale web
address. Routing desktop streams through saved runtime profiles is not implemented.

Desktop access is disabled by default. Opt in with exactly one backend:

- `--desktop-socket /absolute/private/vnc.sock` or `VERDE_WEB_DESKTOP_SOCKET`:
  raw RFB Unix socket, same UID, no symlinks, socket and containing directory with
  no group/other access. This is the recommended Omarchy backend.
- `--desktop-port 5900` or `VERDE_WEB_DESKTOP_PORT`: raw RFB TCP on **127.0.0.1**
  only. The VNC server remains responsible for authentication and its own listener
  exposure. This option does not make a wildcard VNC listener private.

See [Omarchy setup](../../docs/remote-desktop-omarchy.md) and
[macOS candidate/diagnostics](../../docs/remote-desktop-macos.md). After starting
the Omarchy helper explicitly, launch a gateway with your existing arguments plus:

```sh
--desktop-socket "$XDG_RUNTIME_DIR/verde-remote-desktop/vnc.sock"
```

`GET /api/desktop` returns whether a backend is configured, not whether capture is
working. Exact `GET /ws/desktop` upgrades to a separate binary RFB relay after
owner authentication and origin validation. Paired runtime/device grants are
rejected; they do not acquire host control. The relay permits one viewer, bounds
frames/buffers and backend connection time, and joins both directions when either
peer closes. Login revocation/expiry disconnects the stream (checked at most one
second later); all connections have a one-hour limit and can reconnect.

The viewer starts with input paused. **Enable control** permits mouse/keyboard;
**Stop control** disconnects to release held input, and reconnecting starts paused
again. This UI toggle is not a server-enforced view-only permission. Use the
Omarchy helper's `--view-only` for a backend that disables input. Password/username
prompts use transient noVNC credentials, never browser storage or URLs. Clipboard
sync, audio, file transfer, remote resizing, separate sessions, pre-login access,
and saved-profile routing are outside this first version. Browser/OS-reserved
shortcuts may not reach the host. NoVNC is lazy-loaded and pinned in `package.json`;
its MPL-2.0 and bundled third-party notices ship in its package.

Verification after `mise run web-app`:

```sh
python3 scripts/remote-desktop/gateway-test.py
python3 scripts/remote-desktop/omarchy_test.py
bash scripts/remote-desktop/macos-screen-sharing-test.sh
# Optional, with agent-browser on PATH and a workspace browser lease:
python3 scripts/remote-desktop/browser-test.py
```

Tests use temporary state and synthetic RFB, never the user's desktop or daemon.
Live Omarchy capture/input and native macOS compatibility still require host
validation. Do not restart Verde from a Verde-hosted session to deploy this change.
