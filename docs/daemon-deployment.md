# Standalone Daemon Deployment

This is the advanced/manual VM and container guide. For the normal two-step
Tailscale or Connect flow, start with [Verde Serve, Pair, and
Connect](serve-pair-connect.md). A manually administered runtime does not
require a Verde account or hosted control plane.

The standalone `verde-daemon` and secured, loopback-only `verde-web` gateway are implemented. Tailscale Serve can terminate direct private HTTPS in front of that loopback listener; an SSH local forward remains an advanced/recovery path. A non-root container image and Compose example package the same artifacts for a dedicated Linux VM. The native desktop can add, edit, and remove non-secret connections from Settings › Runtimes & connections or the runtime picker (direct HTTPS Pair, SSH with an administrator token, or a Connect control plane), choose workspace defaults, require explicit runtime/instance trust, show Local and configured runtimes with live state, surface repository bindings and provider readiness reported by the verified runtime, and run text-only native chat through an exactly pinned runtime. Remote attachments, PTYs/TUIs, guided provider login, and desktop repository add/clone are not complete yet.

## Security and process model

Run the daemon, gateway, provider CLIs, provider GUI-chat processes, and provider terminal TUIs as one unprivileged runtime user with one effective `HOME`. This is both a security boundary and a credential requirement: providers keep authentication in their own files, keyrings, environment, or OS integration under that account.

This SSH-loopback guide assumes a dedicated VM or container network namespace. Trust is limited to the administrator/root and this runtime UID; do not place mutually untrusted local accounts or containers in the same namespace. The configured gateway port is unprivileged: if `verde-web` is down, an untrusted co-tenant could bind it and receive the next bearer sent through `ssh -W` before the desktop can validate runtime identity. A shared host needs end-to-end TLS with a pinned server identity, or a future SSH-authenticated stdio/owner-only-Unix-socket proxy. Runtime pinning after HTTP authentication is not a defense against prior bearer disclosure.

The current remote deployment has these boundaries:

- `verde-sessionizer.sock` stays on the VM and must never be exposed over the network.
- `verde-web` accepts only a loopback listener and requires an owner-only token file at startup.
- Normal Tailnet access uses Tailscale Serve for HTTPS; advanced/recovery access
  may use an SSH local forward. The gateway itself never accepts a
  non-loopback bind.
- One token grants administrative access to this single-user runtime. Persistent token scopes and multi-user authorization are not implemented.
- The gateway does not expose arbitrary filesystem browsing, file-preview, or file-download routes.

Use a dedicated VM account if the runtime should not share the administrator's home or provider credentials. Do not run the runtime as root.

## Package layout

Keep the daemon binary and provider bridge in this relative layout when installing a release archive:

```text
verde-runtime/
├── bin/
│   └── verde-daemon
└── share/
    └── verde/
        └── provider_bridge.mjs
```

The bridge is required by applicable native provider adapters. Do not copy only the binary or flatten `share/verde`.

If the browser gateway is installed from the same staging prefix, a complete manual layout is:

```text
/opt/verde/
├── bin/
│   ├── verde-daemon
│   ├── verde-web
│   └── verde-server
└── share/
    └── verde/
        ├── provider_bridge.mjs
        └── web/                 # contents of packages/web_app/dist
```

From a source checkout, produce deployment artifacts for a baseline x86_64
Linux target with:

```bash
zig build daemon --release=safe -Dtarget=x86_64-linux-gnu.2.36
zig build server --release=safe -Dtarget=x86_64-linux-gnu.2.36
mise run web-app
```

The daemon staging tree is under `zig-out/`. The gateway binary is under `packages/web_app/zig-out/bin/verde-web`, and its built SPA is under `packages/web_app/dist/`.

CPU portability: the standalone daemon, server, and web-gateway builds default
to the baseline CPU of the target architecture (matching the container
packaging pin), so artifacts never inherit the build host's CPU features. A
host-tuned binary — for example one carrying AVX-512 from the build machine —
crashes with SIGILL on a deployment CPU without those features. Never deploy
`zig-out/bin/verde-daemon` produced by the desktop build (`mise run build`);
that binary is intentionally host-native and is only for the local machine.
Use `-Dcpu=native` only when the artifact will run on the build host itself.

## Initialize and inspect a runtime

Choose one explicit data directory and use it for every administrative command. The examples use a runtime-specific shell variable; `VERDE_DATA_DIR` is not a daemon configuration variable.

```bash
export VERDE_DATA_DIR="$HOME/.local/share/verde/runtime"
unset VERDE_SESSIONIZER_SOCKET

/opt/verde/bin/verde-daemon init \
  --data-dir "$VERDE_DATA_DIR" \
  --json
```

`init` is idempotent. It creates and verifies the durable runtime identity and SQLite store without leaving a daemon running. The containing data directory is owner-only. Preserve the whole directory across upgrades and restores: deleting or replacing its identity file creates a different runtime as far as future clients are concerned.

Start the daemon in the foreground when a supervisor is not in use:

```bash
exec /opt/verde/bin/verde-daemon serve --data-dir "$VERDE_DATA_DIR"
```

From another shell, inspect it with:

```bash
/opt/verde/bin/verde-daemon status \
  --data-dir "$VERDE_DATA_DIR" \
  --json

/opt/verde/bin/verde-daemon providers status \
  --data-dir "$VERDE_DATA_DIR" \
  --json
```

Administrative commands deliberately reject an inherited `VERDE_SESSIONIZER_SOCKET`; unset it when administering an explicit data directory from a Verde-owned terminal. `notify` is the exception: inside a daemon-created terminal it intentionally uses that inherited endpoint.

## Bind workspace repositories

The runtime executes only inside repositories that have an explicit binding
for its stable runtime ID. First, obtain the workspace's stable ID on the
desktop machine. With the desktop running, use:

```bash
verde live workspaces --json
```

`verde state workspaces --json` is the offline alternative. Copy the exact
workspace ID; labels and absolute paths are not cross-runtime identities.

On the VM, start `verde-daemon serve`, then bind an existing checkout as the
workspace's `primary` repository:

```bash
export VERDE_WORKSPACE_ID="<desktop-workspace-id>"

/opt/verde/bin/verde-daemon workspace bind \
  --data-dir "$VERDE_DATA_DIR" \
  --workspace "$VERDE_WORKSPACE_ID" \
  --label "Verde" \
  --root /srv/workspaces/verde \
  --json
```

The root must already exist and be a directory. The command canonicalizes it
and sends an upsert through the running daemon, which remains the sole SQLite
writer. It never creates, clones, moves, or deletes checkout contents.

Register additional repositories in the same workspace with stable IDs of
your choosing:

```bash
/opt/verde/bin/verde-daemon workspace repository bind \
  --data-dir "$VERDE_DATA_DIR" \
  --workspace "$VERDE_WORKSPACE_ID" \
  --repository docs \
  --label "Documentation" \
  --root /srv/workspaces/verde-docs \
  --vcs-identity https://github.com/example/verde-docs.git \
  --default-branch main \
  --json
```

Add `--default` when that repository should be the workspace's default
repository. This does not choose the workspace's default runtime; the desktop
runtime selector controls that separately, and each draft thread may override
both its runtime and repository before the first durable action.

Inspect the complete manifest and every runtime-local binding at any time:

```bash
/opt/verde/bin/verde-daemon workspace show \
  --data-dir "$VERDE_DATA_DIR" \
  --workspace "$VERDE_WORKSPACE_ID" \
  --json
```

Use the same repository ID on every runtime while supplying the checkout path
that is correct on that machine. `--vcs-identity` and `--default-branch` are
optional metadata. Keep the VCS identity credential-free: never embed a token,
password, or credential-bearing URL. Provider login and Git credentials remain
native to the runtime user's own tools and credential stores.

For the supplied container, run these commands with `docker compose exec` and
use paths visible inside the container, normally beneath `/workspace`. Removing
a manifest or binding never deletes a mounted checkout.

## Provider credentials and all integration surfaces

Verde supports eight provider integrations, but their surfaces are intentionally not identical:

| Provider | Native chat | Terminal TUI | MCP registration | Lifecycle status |
| --- | --- | --- | --- | --- |
| Codex | Yes | Yes | Yes | Yes |
| Claude | Yes | Yes | Yes | Yes |
| Cursor | Yes | Yes | Yes | Yes |
| OpenCode | Yes | Yes | Yes | Yes |
| Amp | No | Yes | Yes | Yes |
| Pi | Yes | Yes | Yes | Yes |
| FX | Yes | Yes | Yes | Yes |
| Grok | Yes | Yes | Yes | Yes |

Install each desired provider CLI in the runtime user's executable `PATH`, then run that provider's own login flow as the same user with the same `HOME` the service receives. The daemon currently suggests these commands when the matching executable is installed:

| Provider | Current setup command |
| --- | --- |
| Codex | `codex login` |
| Claude | `claude` |
| Cursor | `agent login` |
| OpenCode | `opencode auth login` |
| Amp | `amp login` |
| Pi | `pi` |
| FX | `fx login` |
| Grok | `grok login` |

Provider login commands and storage formats belong to their providers and can change. Follow the provider's official setup instructions when they differ.

`verde-daemon providers status` currently performs a bounded executable check for all eight integrations. Authentication is intentionally reported as `unknown`, even after a successful login, because several third-party authentication probes do not yet offer a cancellable deadline suitable for a daemon transport worker. Treat `installed=true` as an installation result, not proof that the account is authenticated.

Systemd user services do not source interactive shell startup files. If a provider was installed into a user-specific directory, add an explicit `Environment=PATH=...` line to the service unit or install it in another location already present in the service manager's `PATH`. Keep the daemon, native-chat process, TUI, hooks, and MCP configuration under the same runtime UID and home. Logging in as one user and serving as another does not share authentication.

Verde does not generically copy local provider credentials to the VM. If an administrator supplies API keys through a service environment file, that file remains provider-specific secret material and should be owner-only. Backing up or cloning an entire provider home can also copy refresh tokens and account identity; do that only with explicit security review.

## Lifecycle notifications

Daemon-created PTYs export `VERDE_CLI`, `VERDE_SESSIONIZER_SOCKET`, `VERDE_SESSION_ID`, and their workspace/pane identity. Provider hooks can report a state through the exact daemon that owns the PTY:

```bash
"$VERDE_CLI" notify \
  --quiet \
  --provider codex \
  --status working \
  --title "Running checks"
```

Accepted providers are `codex`, `claude`, `cursor`, `opencode`, `amp`, `pi`, `fx`, and `grok`. Accepted states are `idle`, `working`, `waiting`, `done`, and `error`; `--clear` also clears the durable surface state.

Outside a Verde-owned PTY, target the daemon and name the session explicitly:

```bash
/opt/verde/bin/verde-daemon notify \
  --data-dir "$VERDE_DATA_DIR" \
  --session maintenance-check \
  --provider fx \
  --status done \
  --title "Maintenance complete"
```

`notify` records lifecycle state. It does not authenticate a provider account.

## Systemd user service

Create `~/.config/systemd/user/verde-daemon.service` for the runtime user:

```ini
[Unit]
Description=Verde standalone session daemon

[Service]
Type=simple
UMask=0077
UnsetEnvironment=VERDE_SESSIONIZER_SOCKET
ExecStartPre=/opt/verde/bin/verde-daemon init --data-dir %h/.local/share/verde/runtime
ExecStart=/opt/verde/bin/verde-daemon serve --data-dir %h/.local/share/verde/runtime
Restart=on-failure
RestartSec=2s
KillMode=mixed
TimeoutStopSec=infinity
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

Add the provider installation directories to `PATH` in this unit when necessary. Then load and start it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now verde-daemon.service
systemctl --user status verde-daemon.service
journalctl --user -u verde-daemon.service -f
```

If the service must start at boot before this user logs in, the VM administrator can enable systemd user lingering for the runtime account. That is an operating-system policy choice, not something Verde changes automatically.

## Non-root container and Compose

The repository includes a Linux container package under
`packages/daemon/container`. It runs as UID/GID `10001`, keeps the daemon,
gateway, provider processes, and terminal TUIs under one `HOME`, and persists
that home plus the workspace volume. It does not require a Verde account.

Build artifacts and the local image with the repo-pinned Zig and Bun tools:

```bash
mise run runtime-container
```

The packaging script cross-targets glibc 2.36 for the host architecture,
builds the GUI-free daemon, gateway, and SPA, stages only those runtime files,
and creates `verde-runtime:local`. Override the image tag with
`VERDE_CONTAINER_TAG`; `x86_64` and `aarch64` are supported. The script does
not publish the image.

On a dedicated Linux VM, start the supplied Compose service:

```bash
docker compose \
  -f packages/daemon/container/compose.yaml \
  up -d

docker compose \
  -f packages/daemon/container/compose.yaml \
  exec verde-runtime \
  verde-daemon status --data-dir /home/verde/.local/share/verde/runtime --json
```

The Compose service uses the host network intentionally while `verde-web`
still binds only `127.0.0.1`. Consequently the VM's SSH server can reach
`127.0.0.1:7420` for `ssh -W`, but Docker publishes no LAN-facing port. This
mode has the same dedicated-VM/network-namespace trust requirement as the
systemd setup. Do not use it on a host with mutually untrusted local users or
containers. Confirm that the container engine's host-network mode behaves as
documented on that Linux host before entering a bearer.

On first start the container creates an owner-only random gateway token. Read
it from the container only when you are ready to enter it into the browser or
desktop credential prompt:

```bash
docker compose \
  -f packages/daemon/container/compose.yaml \
  exec verde-runtime \
  bash -lc 'cat "$VERDE_WEB_TOKEN_FILE"'
```

The token is not passed as an environment variable or command-line argument.
The `verde-home` volume retains it together with the runtime user's
provider-native configuration; `verde-workspaces` retains repositories. For
host bind mounts or additional repository roots, mount each path beneath
`/workspace` and make it writable by UID/GID `10001`. Removing a repository
from a Verde manifest never deletes that mounted checkout.

Provider CLIs are intentionally not baked into the base image. Extend the
image with the exact provider versions you want, then authenticate them as the
`verde` user so GUI chat, terminal TUIs, hooks, and MCP use the same effective
home. Rebuilding the image leaves logins in `verde-home`; deleting that volume
deletes those credentials and the gateway token.

For daemon-only process testing, set `VERDE_MODE=daemon`. Remote desktop and
browser access require the default `runtime` mode because it starts both the
daemon and its authenticated loopback gateway. The entrypoint forwards
termination to both processes and waits for the daemon's graceful durability
handoff; the Compose example grants a 30-minute stop window.

## Gateway token and service

Generate the gateway's single administrator token as the runtime user. The file must be a regular, non-symlink file owned by that user and inaccessible to group/other users:

```bash
install -d -m 700 "$HOME/.config/verde"
umask 077
openssl rand -hex 32 > "$HOME/.config/verde/web-token"
chmod 600 "$HOME/.config/verde/web-token"
```

The token itself is entered into the browser login form. Never put it in a URL, a command-line option, or `VERDE_WEB_TOKEN`. The gateway accepts the token-file path through `--token-file` or `VERDE_WEB_TOKEN_FILE`; it rejects the obsolete raw-token environment variable and command-line forms.

Create `~/.config/systemd/user/verde-web.service`:

```ini
[Unit]
Description=Verde loopback web gateway
Requires=verde-daemon.service
After=verde-daemon.service

[Service]
Type=simple
UMask=0077
UnsetEnvironment=VERDE_SESSIONIZER_SOCKET
ExecStart=/opt/verde/bin/verde-web --host 127.0.0.1 --port 7420 --token-file %h/.config/verde/web-token --pref-path %h/.local/share/verde/runtime --static /opt/verde/share/verde/web
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

Enable it and verify only loopback is listening:

```bash
systemctl --user daemon-reload
systemctl --user enable --now verde-web.service
systemctl --user status verde-web.service
journalctl --user -u verde-web.service -f
ss -ltnp | rg '127\.0\.0\.1:7420'
curl -fsS http://127.0.0.1:7420/healthz
```

`GET /healthz` is intentionally limited to liveness. `GET /login`, `GET /login.js`, and trusted built SPA assets are also public; unauthenticated app-shell navigation redirects to `/login`. Runtime inventory, RPC, and the exact `/ws` upgrade require either the authenticated browser session cookie or an authorization bearer. Browser login exchanges the administrator token for a bounded, in-memory, `HttpOnly; SameSite=Strict` session cookie. Raw tokens in query strings and `X-Verde-Token` headers are not accepted. The gateway has no production Live/mock fallback: it talks only to the configured headless session daemon.

The advanced SSH-loopback browser path uses HTTP at the browser's loopback
endpoint, so its session cookie is not marked `Secure`; SSH encrypts network
transit. The normal native Pair path instead uses Tailscale-terminated HTTPS
and scoped device credentials.

## Connect through SSH

Leave the VM firewall closed to port 7420. From the client machine, create a loopback-only local forward using the user's normal SSH host-key policy:

```bash
ssh -N -T \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:7420:127.0.0.1:7420 \
  verde-runtime
```

Open `http://127.0.0.1:7420/login` and enter the token from the VM's token file. After the cookie is issued, the login page sends the browser to the SPA at `http://127.0.0.1:7420/`. Do not append `?token=...`.

This manual fixed-port `ssh -L` workflow trusts the client machine's local-user boundary. If SSH exits, another local process could bind port 7420 and impersonate that browser origin. Confirm the SSH process is still running before entering the token, and close the Verde browser tab immediately when the forward exits. The native desktop's managed transport uses a continuously Verde-owned listener relayed through `ssh -W`; this manual browser command does not gain that ownership guarantee.

### Prepare and use a native desktop profile

On the desktop machine, either the Settings › **Runtimes & connections** card (or **Add connection…** in the runtime picker under the prompt) or the offline CLI creates the non-secret connection profile. Both paths hold the same cross-process lock across the complete load-modify-save transaction and reread the document before adopting it. If you used the systemd unit above, its remote gateway port is `7420`:

```bash
verde runtime add-ssh \
  --label "Build VM" \
  --host verde-runtime \
  --gateway-port 7420

verde runtime list --json
verde runtime path
```

`--host` accepts the same SSH config alias used by the manual `ssh` command. Add `--user` or `--ssh-port` only when they are not already expressed by SSH config. `--expected-runtime-id` accepts a previously verified 32-character lowercase hexadecimal runtime ID; normally the connection handshake will ask the user to trust and pin a first-seen identity instead of requiring manual entry.

These commands never accept a token, and the desktop wizard has no token field. In the desktop, create or focus a draft chat and open the runtime control below the prompt, or press **Connect** on the row in Settings. Choose the configured profile. Verde opens a masked token modal because the bearer is absent, starts the owned SSH relay only after the token is hydrated, and then shows the complete runtime and instance IDs for explicit first-contact approval. Cancelling either step leaves the profile disabled. The bearer stays in process memory and is wiped on shutdown; enter it again after relaunch. The accepted identity pair is persisted in the non-secret profile file so a replaced runtime fails closed instead of being trusted silently.

Once the profile reports Connected, send a text-only prompt normally. The thread is pinned to that exact runtime after accepted or ambiguously accepted work. Selecting Local or another profile on a draft affects only that thread; a started thread cannot be migrated and asks for a new chat instead. Attachment-bearing remote prompts are rejected visibly before transcript mutation until runtime-scoped upload support lands.

### Recover a desktop connection

The runtime control below the prompt and **Settings › Runtimes &
connections** show the same typed status and recovery actions:

- **Offline**, **Unreachable**, and other transient transport failures retry with
  bounded backoff. **Connect**, **Retry**, or **Reconnect** starts an immediate
  attempt without changing the thread's selected runtime.
- **Workspace binding missing**, **Provider unavailable**, and **Provider not
  authenticated** mean the network session opened but the runtime is not ready
  to execute that thread. Fix the VM-side repository/provider setup, then press
  **Reconnect** to drop the stale session and re-read readiness. **Show server
  setup** keeps the relevant operator instructions available beside that action.
- **Token required**, **Authentication failed**, **Pairing required**, and
  **Device revoked** require new authorization. Enter the administrator token
  for an advanced SSH profile or use **Re-pair device** for a direct/Tailnet
  profile; repeated reconnects cannot repair a missing or revoked credential.
- **Verify identity** is first-contact trust. **Identity mismatch** is a hard
  stop: inspect or edit the endpoint and explicitly trust the replacement.
  Reconnect never silently re-pins a changed runtime.
- **Copy diagnostics** copies redacted connection state and identifiers, not
  administrator tokens, Pair codes, or device credentials.

A started thread remains pinned while its runtime is unavailable. Verde never
runs that work on Local as a fallback; restore the original runtime or create a
new thread and choose another runtime. For a Tailscale profile, the desktop
connects directly to the saved HTTPS origin, so reconnecting does not require an
SSH session. The remote `verde-daemon`, `verde-web`, Tailscale client, and Serve
mapping must still be running; use `verde-server service status --json` and
`verde-server tailscale doctor --json` on the runtime when UI retries keep
returning the same server-side failure.

To make the profile the default only for future chats in one workspace, copy the profile ID from `verde runtime list --json` and the workspace ID from `verde live workspaces --json`, then run:

```bash
verde runtime default \
  --workspace <workspace-id> \
  --profile <profile-id>

verde runtime default --workspace <workspace-id> --json
```

The desktop command palette also provides **Use Current Chat Runtime as Workspace Default** and **Use Local as Workspace Runtime Default**, and each row in Settings › Runtimes & connections has **Use as default**. None of these rewrites an existing thread. Editing a saved connection's host, user, or ports clears its persisted runtime/instance pin and disconnects it; the next connect asks for trust again. Removing a connection leaves already-pinned chats locked and marked unavailable. `verde runtime default --workspace <workspace-id> --clear` removes the saved mapping, making Local the effective fallback. If a saved profile is later removed, new drafts fall back to Local while the CLI reports the stale preference.

Keep the forward bound to `127.0.0.1`, not `0.0.0.0`. Do not disable SSH host-key checking. Verde's desktop connection manager uses an observable, continuously owned listener plus an exact, bounded `ssh -W` process for each permitted call. Heartbeat and every post-trust RPC are targeted to the persisted runtime/instance pair and rejected before dispatch if that pair changes.

The gateway rejects public/LAN binds. The supported direct private path keeps
that invariant: Tailscale Serve terminates HTTPS and proxies to the loopback
port under one exact trusted-origin contract. Other reverse proxies and public
Internet exposure remain advanced, operator-managed deployments and must meet
the same forwarding and certificate requirements.

## Shutdown, backup, and upgrade

`verde-daemon serve` handles `SIGINT` and `SIGTERM` by asking the daemon instance with the expected PID to enter its prepare-shutdown path. It keeps trying until the daemon reports that it is safe to exit. `KillMode=mixed` sends the initial stop signal to the daemon rather than every provider child at once, and the unit does not impose a short stop timeout. Prefer:

```bash
systemctl --user stop verde-web.service
systemctl --user stop verde-daemon.service
```

Do not use `kill -9` during normal operation. A forced kill can interrupt PTYs, turns, or a store write.

For a consistent backup, stop both services, copy the entire daemon data directory, and then restart them. The gateway token and provider-native credentials live outside that directory and require separate, secret-aware backup decisions. On restore, retain `runtime-identity.json` with `state.sqlite`; do not combine identity and database files from different backups.

For an upgrade:

1. Stop the gateway and daemon cleanly.
2. Replace the complete `bin/verde-daemon` plus `share/verde/provider_bridge.mjs` layout, and replace `verde-web` plus the built SPA together when the gateway changed.
3. Start `verde-daemon.service` and verify `verde-daemon status --json` against the same data directory.
4. Start `verde-web.service`, check `/healthz`, and reconnect the SSH forward.

Gateway browser sessions are in memory and do not survive a gateway restart. To rotate the administrator token, atomically replace the owner-only token file and restart `verde-web`; all old browser sessions then disappear with the process.

## Current limitations

- The native desktop remote path currently supports text-only native chat. Remote prompt attachments, repository file transfer/preview, reconnectable PTYs, provider TUIs, and terminal lifecycle parity are pending.
- Administrator gateway bearers are process-memory-only and must be entered again after desktop relaunch. Paired device credentials persist by reference in the OS credential store (Linux Secret Service) or, without one, stay memory-only with a visible warning. Tokens are intentionally absent from profile/default JSON, diagnostics, and CLI flags.
- Connect discovery and bootstrap require an existing externally reachable
  HTTPS endpoint, normally the saved Tailscale origin or an advanced descriptor.
  No managed relay, tunnel, or NAT traversal component is bundled.
- The gateway remains loopback-only. Direct HTTPS/WSS is provided by Tailscale
  Serve as the trusted TLS-terminating proxy, not by a public gateway bind.
- SSH-to-loopback mode supports a dedicated VM/container, not a network namespace shared with mutually untrusted local accounts or containers.
- Authentication is one administrator token with ephemeral browser sessions; persistent token metadata, scopes, and selective revocation are not implemented.
- Provider installation is detected, but provider authentication is reported as `unknown`; Settings shows the runtime's provider states and remediation commands but cannot run them because there is no remote shell. Guided remote login and deadline-bounded auth probes are pending.
- Receipt-backed multi-repository manifests, runtime-local bindings, safe repository-routed chat, and manual daemon CLI administration are implemented. Settings shows each repository's binding on the selected runtime read-only; desktop add/clone/remove/default-repository and per-draft repository-picker UX are pending.
- Arbitrary remote filesystem browsing remains intentionally unavailable.
- The repository now provides a locally built non-root image and Compose deployment. A signed/published registry image, automated multi-architecture release, and provider-specific derivative images are still pending.
- One daemon is a single-user runtime. Do not share one token and provider home among mutually untrusted users.
- The current SSH-to-loopback transport also requires a dedicated remote network namespace; an untrusted co-tenant could impersonate a stopped high-port gateway.
