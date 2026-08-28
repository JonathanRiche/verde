# Remote Runtimes

Status: architecture, implementation status, and remaining plan for the open-source Verde repository.

This document focuses on the desktop/runtime boundary rather than the detailed
Connect control-plane contract. The open-source desktop and daemon must support
local use, a manually administered VM, and a container without an account or
control plane. Optional Connect discovery may use the runnable self-hostable
open-source reference service or a compatible private Verde Cloud deployment;
either hands the desktop the same normalized runtime descriptor and does not
get a separate execution protocol.

The account-free Serve/Pair surface and the open contract for optional Connect
are specified in [Verde Serve, Pair, and Connect](serve-pair-connect.md).
The daemon now contains identity-bound grant/device storage and owner-only
local administration. Store-backed runtimes advertise `access.pair.v1`; the
loopback gateway provides rate-limited grant/device authentication,
short-lived access tokens, one-use WebSocket tickets, current-revocation
checks, and fail-closed per-RPC scope enforcement.

The current standalone VM path and its limitations are documented in [Standalone Daemon Deployment](daemon-deployment.md). The daemon and SSH-forwarded browser gateway are usable now. The native desktop has durable non-secret profiles, offline profile/default-management CLI commands, a masked process-memory credential flow, explicit first-contact identity trust, a live Local/configured-runtime selector, a continuously owned loopback relay with shell-free per-call `ssh -W` channels, authenticated identity-targeted RPC, immutable thread routes, and remote text-chat dispatch. Remote attachments, remote PTYs/TUIs, direct HTTPS, guided provider login, and desktop multi-repository management remain separate follow-on work.

## Outcome

The native desktop can stay connected to multiple Verde runtimes at once. Each workspace has a default runtime, and each new thread may choose Local or any configured runtime from the existing run control under the prompt. Once work starts, a thread is pinned to that runtime. A change attempted on a started thread is refused and directs the user to start a new chat; it never silently moves a live conversation, PTY, or working tree.

The remote runtime owns everything that executes or persists for that thread:

- provider GUI-chat processes;
- provider terminal TUIs and lifecycle hooks;
- MCP registration against that runtime's authenticated daemon endpoint;
- repositories and project working directories;
- transcript, turn, and attachment persistence;
- PTYs and terminal scrollback needed for reconnection.

The desktop is a detached client. It must not read a remote SQLite file or assume that remote paths exist locally.

A workspace may contain one or many repositories. Repositories are first-class records rather than one implicit workspace path. A thread pins a runtime, repository, and relative working directory, so two threads in the same workspace can work in different repositories or on different runtimes without confusing absolute paths.

## Invariants

1. The Unix session socket remains private to the runtime host.
2. Every network path is authenticated; every public network path is encrypted.
3. Local mode remains the zero-configuration default.
4. Manual SSH and HTTPS runtimes require no Verde account.
5. Runtime identity is stable and independent of labels, addresses, or SSH host aliases.
6. Workspace IDs, thread IDs, turn IDs, pane IDs, and attachment IDs are scoped by runtime ID in desktop memory and persistence.
7. A protocol mismatch reports an actionable compatibility error. A desktop must never auto-replace or restart a remote daemon.
8. Native chat and terminal TUI processes run as the same runtime UID with the same effective home directory.
9. Credentials stay provider-native on the runtime; Verde does not generically copy local auth directories.
10. Herdr remains a local editor handoff. Its SSH remote/profile layer is removed rather than reused as the runtime transport.
11. Repository identity is stable across runtimes; absolute checkout paths are runtime-specific mappings and never serve as cross-runtime identity.
12. Plain SSH-to-loopback mode assumes a dedicated runtime host/network namespace where root and the runtime UID are trusted. Mutually untrusted co-tenants require end-to-end TLS/SPKI authentication or an SSH-authenticated stdio/Unix-socket proxy before any bearer is sent.

## Terms and identity

- **Runtime**: one Verde daemon, its durable state, filesystem, provider processes, and PTYs.
- **Runtime ID**: stable random ID generated on first daemon initialization and persisted in the daemon data directory.
- **Instance ID**: changes whenever durable runtime state is recreated; useful for detecting an accidentally replaced server.
- **Connection profile**: desktop-owned instructions for reaching a runtime. Secrets are referenced from the OS credential store, not embedded in ordinary JSON.
- **Workspace default**: runtime preselected for a new thread in that workspace.
- **Thread runtime**: immutable runtime binding once the thread has its first durable action.
- **Repository ID**: stable workspace-scoped identity for one repository, independent of its checkout path on a particular runtime.
- **Repository binding**: the runtime-local root path and availability state for a repository ID.

Desktop keys must be composite where data from several runtimes can coexist:

```text
(runtime_id, workspace_id)
(runtime_id, workspace_id, repository_id)
(runtime_id, workspace_id, local_thread_id)
(runtime_id, pane_id)
(runtime_id, turn_id)
```

Never infer runtime ownership from whichever connection is currently selected.

## User flow

### Local

Local remains preconfigured. The desktop connects to the local Unix socket and may manage the matching local daemon lifecycle as it does today.

### Add an SSH runtime

The desktop collects a label, SSH host or config alias, optional user and port, and the remote gateway port. It verifies the SSH host key through the user's normal SSH policy, continuously owns the selected client-side loopback listener, obtains no shell credential itself, and performs an authenticated protocol handshake through a shell-free `ssh -W` channel.

An SSH profile is a transport profile, not Herdr state. The Verde-owned listener remains bound while bearer-bearing work can connect; each permitted RPC gets one bounded, observable `ssh -W` process tree scoped to that call. Verde must not disable host-key checking or scrape passwords from terminal output.

### Add a direct HTTPS runtime

The desktop collects an HTTPS URL and token/key reference, verifies TLS and the runtime handshake, and stores only the non-secret profile fields in config. This path is appropriate behind Caddy, nginx, Traefik, a VPN, or an administrator's equivalent TLS setup.

### Choose per thread

The workspace runtime is only the default. The run control under the prompt lists Local plus configured runtimes and their current status, and allows an individual new thread to opt out of that default. Existing threads show their pinned runtime. If a user chooses another runtime while viewing a started thread, Verde leaves the current thread untouched and tells the user to start a new chat for that route.

### Use multiple repositories in one workspace

Workspace settings can add an existing repository root, clone a repository, rename its display label, choose a default repository, or remove a repository reference without deleting its checkout. The prompt run controls choose both runtime and repository for a new thread; the directory control then selects a relative subdirectory within that repository.

The workspace stores a repository manifest such as:

```json
{
  "repository_id": "repo-api",
  "label": "API",
  "vcs_identity": "https://example.com/org/api.git",
  "default_branch": "main",
  "bindings": {
    "runtime-local": "/home/me/src/api",
    "runtime-devbox": "/work/api"
  }
}
```

Credentials and clone URLs containing secrets are not persisted in this manifest. A runtime that lacks a binding reports `missing`; Verde offers to select another repository, configure an existing checkout, or clone it through an explicit runtime-side flow. Verde must not guess that two same-named directories are the same repository.

## Connection profiles

Use one desktop model with transport-specific options:

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "profile-0123456789abcdef0123456789abcdef",
      "label": "Home lab",
      "expected_runtime_id": "fedcba9876543210fedcba9876543210",
      "expected_instance_id": "00112233445566778899aabbccddeeff",
      "transport": {
        "kind": "ssh_tunnel",
        "host": "devbox",
        "user": "verde",
        "port": 22,
        "remote_gateway_port": 7420
      }
    }
  ]
}
```

The desktop stores this non-secret document as `runtime-profiles.json` beside `verde.json`, using an atomic owner-only file on POSIX. `verde runtime path|list|add-ssh|remove` manages it without starting SDL. Workspace defaults live in a separate strict owner-only `workspace-runtime-defaults.json`; `verde runtime default --workspace ID [--profile ID | --clear]` inspects or changes them. Local remains implicit and is not written to the profile document. Tokens, authorization headers, provider credentials, and raw credential-store values are rejected from both schemas.

Supported kinds:

- `local_socket`: built-in local profile; not user-secret-bearing.
- `ssh_tunnel`: Verde-owned loopback listener with one bounded `ssh -W`
  channel per permitted RPC to the remote loopback gateway.
- `https`: planned direct HTTPS/WSS endpoint; not accepted by the version-1 profile decoder yet.

Keep the descriptor extensible enough for an external provisioner to return an `https` profile later, but do not add SaaS account fields to it.

The first usable SSH slice keeps the gateway bearer only in desktop process memory. Selecting a profile with no hydrated token opens a masked credential modal; cancelling disables that profile and clears the token. The user must explicitly approve the complete runtime and instance IDs on first contact. The accepted identity pair is persisted in the non-secret profile transaction, but the bearer is wiped at shutdown and must be entered again after relaunch. Account-free Pair avoids that: the wizard exchanges a one-time grant over the same SSH forward, confirms the runtime identity, and stores the device credential in the OS credential store by reference (memory-only fallback is stated in the UI).

## Connection manager

The desktop needs a runtime connection manager instead of one global sessionizer endpoint. It owns one state machine per profile:

```text
disabled -> connecting -> handshaking -> awaiting trust -> transport ready
               |              |                 |                |
               +----------> failed <------------+----------------+
                                  |
                              reconnecting
```

`transport ready` is not permission to execute. A connection becomes execution-ready only after its runtime/instance pin is durably committed and an authenticated heartbeat proves the expected runtime is still responding on the current connection generation. Because SSH mode opens a fresh channel for each RPC, every post-trust request must also carry that pinned pair and the daemon must reject a mismatch before dispatching the same request; a heartbeat followed by an unbound mutation would retain a replacement race.

Each connection tracks:

- profile ID and verified runtime/instance IDs;
- transport process/socket and reconnect generation;
- negotiated protocol version and capabilities;
- latency and last successful heartbeat;
- authentication/authorization failure separately from network failure;
- subscriptions, cursors, and in-flight requests;
- provider readiness cache for that runtime.

Backoff includes jitter and resets after a stable ready interval. Local lifecycle behavior is only enabled for the built-in local profile. Multiple ready connections must coexist; opening one runtime must not rebind another workspace or browser.

## Protocol handshake and compatibility

Add a cheap unauthenticated-or-minimally-authenticated health route only if it reveals no inventory. The authenticated protocol handshake is authoritative and returns:

```json
{
  "runtime_id": "...",
  "instance_id": "...",
  "server_version": "...",
  "protocol": { "major": 1, "minor": 0 },
  "capabilities": [
    "core.changes",
    "threads.page",
    "messages.page",
    "attachments.v1",
    "pty.v1",
    "providers.status.v1"
  ],
  "limits": {
    "max_request_bytes": 1048576,
    "max_attachment_bytes": 52428800,
    "max_parked_wait_ms": 30000
  }
}
```

Rules:

- reject unknown protocol major versions;
- negotiate optional features through capabilities, not client-version guesses;
- retain a documented minor-version compatibility window;
- bind every post-trust remote RPC to the expected runtime and instance IDs, validated by the daemon before method dispatch;
- include stable machine-readable errors and user-facing remediation;
- never restart a remote process in response to incompatibility;
- retain the existing bounded shared long-poll park budget.

## Remote-safe data APIs

Today, desktop projection paths that read local SQLite directly must be replaced with bounded daemon calls before remote mode can be correct. Do this for local and remote clients so there is only one behavior to test.

Required surfaces:

- paginated workspace, project, thread, pane, turn, and message listing;
- snapshot plus ordered change cursors for incremental projection;
- bounded transcript pages in both directions around a stable cursor;
- idempotent mutations with client request IDs;
- turn tailing/cancellation and explicit terminal states;
- runtime-scoped project discovery and path validation;
- workspace repository-manifest CRUD plus per-runtime binding/readiness;
- attachment upload, metadata, download, and deletion;
- PTY create/input/resize/tail/close/reconnect;
- provider installation/authentication/readiness inventory;
- server limits, version, runtime identity, and capabilities.

Pages must have explicit maximums. Cursors are opaque. Reconnect resumes from an acknowledged cursor; a cursor older than retention causes a bounded resnapshot, not an unbounded history response.

## Attachments and files

Local file paths cannot cross the runtime boundary. Prompt attachments use a two-step flow:

1. The desktop streams bytes to the selected runtime and receives a runtime-scoped attachment ID plus digest and metadata.
2. `chat.turn.start` references attachment IDs, never desktop paths.

Uploads enforce count, size, MIME policy, timeout, and storage quotas. Temporary uploads are garbage-collected if no turn claims them. Download and preview are explicit authenticated operations. Provider adapters must still receive every image in `SendPromptRequest.images`; unsupported remote attachment types fail visibly rather than disappearing.

Remote repository browsing should start with validated project roots and narrowly scoped file operations. Do not expose an arbitrary unaudited filesystem API as a shortcut.

## Remote terminals

PTY ownership moves fully behind the daemon protocol. A remote terminal pane stores runtime ID and remote PTY ID. The desktop sends input and resize events and tails sequenced output. Reconnection resumes from a bounded scrollback cursor when available.

Terminal creation includes workspace ID, repository ID, relative cwd, shell intent, environment profile, and dimensions. The server resolves and validates the cwd beneath that repository's runtime binding. It never accepts a local absolute path merely because the desktop sent it.

Provider TUIs launch inside these PTYs under the same UID/HOME as native provider chat. This is essential for shared provider-native authentication.

## Provider installation and authentication

Provider readiness is runtime-scoped and surface-aware. Preserve the repository's intentionally different sets:

- native chat: Codex, Claude, Cursor, OpenCode, Pi, FX, and Grok;
- MCP registration/proxy: Codex, Claude, Cursor, OpenCode, Amp, Pi, FX, and Grok;
- managed terminal lifecycle integration: Codex, Claude, Cursor, OpenCode, Amp, Grok, Pi, and FX.

The daemon reports, per provider:

- CLI installed/version/path;
- native-chat, terminal, MCP, and hook capabilities;
- authenticated/not authenticated/unknown/error;
- safe account label and auth kind when the provider exposes them;
- upstream provider connections where one CLI fronts several providers;
- last probe time and a structured remediation action.

The desktop offers a guided setup action that opens a terminal on that runtime and runs the provider's official login flow. Headless device-code flows should be preferred where offered. After the command exits, the daemon re-probes readiness.

Do not add a generic “copy my local credentials” command. A provider-specific import may be considered only when the provider officially supports it, with explicit consent and secret-safe transport. API keys and noninteractive environment configuration remain valid administrator-managed options.

## GUI-free server and CLI

The repository now builds a dependency-isolated `verde-daemon` artifact without SDL, Palette, browser, font, or other desktop-only libraries. Its current public, noninteractive commands are:

```text
verde-daemon init [--data-dir <path>] [--json]
verde-daemon serve [--data-dir <path>]
verde-daemon status [--data-dir <path>] [--json]
verde-daemon providers status [--data-dir <path>] [--json]
verde-daemon workspace show --workspace <id> [--data-dir <path>] [--json]
verde-daemon workspace bind --workspace <id> --label <label> --root <path> [options]
verde-daemon workspace repository bind --workspace <id> --repository <id> --label <label> --root <path> [options]
verde-daemon pair create [--expires 10m] [--label <text>] [--scope <scope>]... [--data-dir <path>] [--json]
verde-daemon pair list [--data-dir <path>] [--json]
verde-daemon pair revoke --id <id> [--data-dir <path>] [--json]
verde-daemon device list [--data-dir <path>] [--json]
verde-daemon device revoke --id <id> [--data-dir <path>] [--json]
verde-daemon notify --status <state> [options]
verde-daemon version [--json]
```

The sibling `verde-web` process owns the network gateway; it is not a `verde-daemon gateway` subcommand. Daemon administration no longer requires launching the GUI. `init` establishes restrictive data-directory and identity permissions, and `serve` stays foreground-first so systemd, Docker, or Podman can supervise it.

Pair/device commands use the private session-daemon transport, target the exact
runtime generation probed by the CLI, and are blocked from the web gateway.
Pair creation returns its one-time grant secret only through explicit human or
`--json` output. The sibling loopback gateway implements remote pairing
exchange, short-lived access tokens, one-use WebSocket tickets, and per-RPC
scope enforcement. Convenience `service install/uninstall` remains
unimplemented. Manual systemd and owner-token-file setup is documented
separately.

## Gateway hardening

The first SSH-safe gateway slice is implemented. `verde-web` now:

- accepts loopback listeners only and rejects non-loopback configuration;
- requires an owner-only, no-follow regular token file;
- rejects raw token arguments, `VERDE_WEB_TOKEN`, query tokens, and legacy Live/mock configuration;
- exchanges a successful browser login for a bounded, expiring, in-memory, `HttpOnly; SameSite=Strict` session cookie;
- keeps `/healthz` inventory-free, serves only the login and trusted app assets publicly, and authenticates every runtime API plus the exact `/ws` upgrade;
- validates loopback Host and same-origin browser requests without permissive CORS;
- talks only to the headless session daemon and does not fall back to Desktop Live or mock state;
- enforces bounded requests, frames, responses, sessions, connections, and login failures;
- rate-limits pairing-grant exchange, failed device authentication, and failed
  access-token/ticket bootstrap in separate bounded client tables;
- retains only verifier digests for 15-minute paired access tokens and
  30-second atomic one-use WebSocket tickets, with at most one live token and
  one unconsumed ticket per device so replacement cannot exhaust another
  device's slots;
- applies one centralized fail-closed scope map to paired HTTP and WebSocket
  RPCs, scope-gates specialized API routes, and rechecks device revocation and
  expiry during bounded WebSocket polling, clearing the rejected device's
  in-memory credentials without affecting other devices;
- uses narrow, immediately cleared private-IPC encoders for the two
  secret-bearing daemon bridge requests while generic DTO serialization stays
  redacted;
- does not expose arbitrary file browsing or the legacy file/preview routes.

This is deliberately not a public server or a direct HTTPS implementation. The browser reaches it through a manually owned SSH local forward; the native desktop reaches it through its continuously owned listener and per-call `ssh -W` relay. Before a future direct HTTPS mode is supported, it still needs:

- add desktop pairing import plus OS credential-store persistence;
- add proof-of-possession device keys as an optional successor to the current
  high-entropy verifier-backed device credential;
- require TLS directly or define and test a trusted reverse-proxy contract;
- add certificate and forwarded-origin diagnostics;
- define a safe non-loopback bind mode rather than weakening the loopback default.

SSH mode keeps this gateway on loopback. The browser uses a conventional local forward, while the native desktop uses its owned relay. A future direct HTTPS mode will use the same runtime APIs through TLS.

The loopback TCP endpoint is a single-tenant deployment boundary, not merely a firewall setting. If `verde-web` is down, another untrusted account or container in the same remote network namespace could bind its unprivileged port and receive the next HTTP Authorization bearer before a runtime-identity response exists. The supported SSH deployment therefore uses a dedicated VM/container with no untrusted local users. Shared-host support must first add end-to-end TLS with a pinned server identity, or an SSH-authenticated stdio proxy to an owner-only Unix socket; a post-authentication runtime handshake cannot repair a bearer already disclosed to an impostor listener.

## Manual deployment

### VM

The implemented VM path is documented in [Standalone Daemon Deployment](daemon-deployment.md):

1. install the `verde-daemon` artifact and preserve `share/verde/provider_bridge.mjs` beside it;
2. create/choose one unprivileged runtime user;
3. run `verde-daemon init --data-dir <path>`;
4. install desired provider CLIs under that user's environment;
5. run each provider's own login flow manually as that user;
6. install/start the documented systemd user service;
7. create an owner-only gateway token file and start `verde-web` on loopback;
8. bind the workspace's existing primary and optional additional repository
   checkouts through the running daemon;
9. use an SSH local forward and the browser client when desired;
10. add a desktop SSH profile, choose it on a draft, enter the gateway bearer,
    approve the runtime identity, and send a text-only prompt.

The guide includes systemd user units, firewall/SSH guidance, archive layout, provider-home implications, logs, safe shutdown, backups, upgrades, whole-gateway token rotation, repository binding, desktop profile creation, masked bearer entry, explicit identity trust, and per-thread selection. A system-wide service-account unit and direct HTTPS/reverse-proxy instructions remain pending.

### Container

The repository now includes a locally built non-root image and Compose example
under `packages/daemon/container`. It packages the GUI-free daemon, loopback
gateway, and production SPA; runs them as UID/GID `10001`; and persists the
runtime home and repository volume. `mise run runtime-container` builds the
local image but does not publish it. Health checks verify daemon/gateway
liveness, not provider login.

Disposable containers lose provider login unless the provider-native
home/config storage is persisted. Treat snapshots of that volume as secret
material. The supplied path does not mount the Docker socket or request
privileged mode. A signed registry image, automated multi-architecture release,
and provider-specific derivative images remain future work.

## Herdr scope reduction

Remove Herdr's SSH destination, remote cwd, profile storage, and profile CLI/UI. Preserve local `open`, `handoff`, `unlink`, and `status` behavior for now. Keep tolerant decoding of old Herdr records long enough to avoid corrupting or crashing on existing state, but do not initiate a remote SSH handoff from them.

Remote runtime profiles belong to the connection manager and must not reuse Herdr files, names, or state transitions.

## Implementation status

Current branch: `feat/remote-runtimes` in the isolated `remote-runtimes` worktree.

Landed in the first foundation slice:

- Herdr's SSH/profile/remote-cwd commands and UI are removed; local open, handoff, unlink, and status remain. Legacy remote fields are decode-only compatibility data and are not executed.
- Each daemon data directory now owns durable random runtime and instance IDs. Existing malformed identity files fail startup instead of silently rotating identity.
- `core.status` and `core.capabilities` advertise runtime identity, server/runtime protocol versions, named capabilities, and hard limits; clients can reject a missing identity, protocol-major mismatch, or unexpected runtime ID.
- Bounded `workspace.list`, `chat.thread.list`, and bidirectional `chat.message.list` reads use opaque cursors and a 200-item hard maximum. Workspace and thread page cursors are revision- and query-bound; after a durable mutation or query mismatch, clients restart that listing without a cursor.
- Legacy one-path workspaces project as a stable `primary` repository with a runtime-local binding. Durable, receipt-backed repository-manifest CRUD, default-repository choice, per-runtime bindings, typed client calls, and manual `verde-daemon workspace ...` administration are advertised. The desktop add/clone/remove/repository-picker UX is not implemented yet.
- `providers.status` reports all eight integration providers with intentionally distinct native-chat, terminal, MCP, and lifecycle surfaces. It performs bounded installation checks; authentication is currently reported truthfully as `unknown` for every provider.
- The transport-neutral client has typed capability gates and decoders for these new remote-safe surfaces.
- A dependency-isolated `verde-daemon` artifact packages `bin/verde-daemon` plus `share/verde/provider_bridge.mjs` and implements idempotent init, foreground serve, runtime/store status, provider status, owner-only Pair/device administration, durable lifecycle notify, version/help, and PID-checked graceful signal shutdown.
- The loopback-only `verde-web` gateway keeps its mandatory owner token and bounded browser sessions, and now also exposes the account-free Pair exchange: independently rate-limited grant/device authentication, verifier-only 15-minute scoped access tokens, one-use 30-second WebSocket tickets, centralized fail-closed HTTP/WebSocket RPC scope enforcement, and ongoing expiry/revocation checks. It still removes Live/mock fallback and arbitrary file/preview access.
- Desktop runtime foundations include runtime-qualified thread identities, a versioned non-secret Local/SSH profile schema with runtime/instance pinning, a process-memory-only bearer-token store, a 1 MiB bounded loopback RPC transport, and a continuously owned loopback listener that relays one permitted call through each shell-free OpenSSH `-W` process. The supervisor keeps normal user SSH configuration for aliases, ProxyJump, and IdentityFile while disabling control-master reuse, never releases a bearer-bearing call to an unowned listener, bounds I/O and teardown, and terminates the exact process tree it owns.
- The per-profile connection manager validates canonical runtime and instance IDs, separates first-contact trust from transport readiness, and invalidates the connection generation when a token is cleared or replaced. A lock/reload/conflict/save/reread transaction adopts only an authoritative durable identity pair. Periodic targeted heartbeats and all general RPCs carry that pair; execution readiness requires a healthy current relay generation and `rpc.target.v1`.
- The network gateway permits only bootstrap `core.status` without a target. Browser HTTP/WebSocket clients learn one page-lifetime identity pair and target every later request; the gateway targets its own snapshot/change calls, while the daemon rejects a missing, malformed, or mismatched target before either normal or slow dispatch.
- Thread routes persist profile, verified runtime, repository, and relative working-directory identity in SQLite. A route is mutable while a thread is a draft and immutable after its first durable action; corrupt, partial, unknown-profile, or remote routes never fall back to Local execution.
- The desktop run control lists Local and configured SSH profiles with live connection status. Missing bearers open a masked process-memory credential flow, first contact requires explicit approval of the complete runtime/instance pair, and workspace defaults are stored separately from each thread's override.
- Settings › **Runtimes & connections** manages connections without the CLI: an "Add connection…" entry in the runtime picker and in Settings opens an SSH wizard (name, SSH host/config alias, optional user, SSH port, gateway port) with field-level validation and a connect step; rows show Local plus every saved runtime with live state (connected, connecting, verifying, token required, identity verification required, offline, identity mismatch, unreachable, auth failed, unsupported) and actions to connect, retry, disconnect, edit non-secret fields, forget the in-memory token, remove with confirmation, copy redacted diagnostics, and choose the workspace default. Edits go through the shared profile store lock and the authoritative reread; changing an endpoint clears the persisted identity pin and invalidates the live generation so trust is never carried to a different peer. The expanded row reads repository bindings (`workspace.repository.manifest.get`) and the runtime-scoped provider inventory (`providers.status`) from the verified runtime and renders daemon-reported paths, states, and remediation commands only; the desktop has no remote shell, so unbound repositories and signed-out providers show as honest blocked/action states rather than a fake clone or login.
- Text-only native chat can dispatch through a ready, capability-matched, exactly pinned remote runtime. Acceptance, ambiguous acceptance, streaming tails, terminal errors, cancellation, and approval responses stay on that runtime; attachment-bearing prompts fail visibly before transcript mutation instead of dropping files or running locally.
- Workspace and thread page cursors are revision- and query-bound. A mutation or query mismatch produces an actionable restart-without-cursor error instead of silently duplicating or skipping rows.
- Manual VM/systemd deployment and a locally built non-root Compose package now live in [Standalone Daemon Deployment](daemon-deployment.md).

The open-source SSH path is now usable for desktop-configured, text-only native chat on a dedicated single-user VM/container. Still required for full parity: migrate the remaining desktop projections to bounded remote APIs; add desktop Pair credential import and optional OS credential-store hydration; add guided provider setup over a safe remote execution surface and deadline-bounded authentication probes; add repository add/clone/bind from the desktop; and complete attachment, audited file, reconnectable PTY, and remote TUI transport. Direct HTTPS and signed multi-architecture image publishing are also pending.

## Delivery plan

### 1. Contract and identity foundation (in progress)

- Add runtime/instance identity, protocol version, capabilities, limits, and stable errors.
- Add bounded pagination needed to eliminate desktop SQLite reads.
- Add runtime-scoped provider readiness inventory.
- Add composite runtime-aware IDs in client state boundaries.
- Replace the single implicit workspace path at protocol boundaries with a repository manifest and stable repository IDs while preserving a one-repository compatibility projection.
- Cover local behavior with protocol tests before enabling a network transport.

Exit: the local desktop can use daemon APIs for every state read needed by a remote client.

### 2. GUI-free daemon artifact (core artifact landed)

- Keep server composition usable without the desktop binary.
- Retain the public init/serve/status/provider/notify CLI surfaces.
- Add service lifecycle helpers. Local pairing-grant/device administration and
  the loopback gateway's short-lived scoped credential exchange are landed.
- Continue verifying the artifact stays free of GUI libraries.
- Keep the desktop's local auto-management adapter separate.

Exit: a clean Linux VM can run the daemon without installing or launching the desktop.

### 3. Authenticated loopback gateway and SSH profiles (manual SSH path landed)

- Preserve the loopback-only, mandatory-token-file gateway and bounded browser sessions.
- Preserve the landed Pair credential lifecycle and centralized scope enforcement; add desktop Pair import plus optional OS credential-store hydration.
- Preserve the landed desktop profile management (Settings › Runtimes & connections and the picker's "Add connection…") that uses the shared profile store lock and authoritative reload, retain the masked process-memory credential flow, and later add optional OS credential-store hydration. Preserve host-verification guidance, owned-relay supervision, health, reconnect, and redacted diagnostics.
- Preserve the landed periodic authenticated heartbeat and generation-safe general RPC routing that validates the pinned runtime/instance pair inside every dispatched request before allowing remote execution.
- Support multiple simultaneous runtime connections.

Exit: the desktop can use Local and at least two SSH runtimes concurrently.

### 4. Thread and workspace runtime selection (text-chat slice landed)

- Preserve the landed strict, owner-only workspace default profile store and CLI/command-palette controls.
- Preserve the landed immutable runtime/repository/cwd binding on started threads and enforce it at every execution boundary.
- Preserve the live Local/configured-profile status choices, the Settings workspace-default selector, and per-draft override.
- Keep started routes immutable; choosing another runtime requires a new thread instead of migrating work.
- Preserve the landed read-only repository binding readiness in Settings; extend the landed text-only remote dispatch with attachment, PTY, TUI, and repository add/clone/selection parity.

Exit: two threads in one workspace can intentionally run on different runtimes.

### 5. Provider parity and guided setup

- Audit all applicable native-chat, MCP, terminal, hook, CLI, settings, and test surfaces.
- Preserve the landed runtime-scoped provider status and remediation display in Settings (read-only; commands are shown, never executed by the desktop).
- Launch provider-native login/setup in a remote PTY once a safe remote execution surface exists.
- Verify GUI and TUI share credentials through the same UID/HOME.

Exit: each supported provider either works on the runtime or displays a specific setup/error state without leaking credentials.

### 6. Attachments, files, and PTY parity

- Add attachment transfer and runtime IDs.
- Add remote project/path discovery.
- Add multi-repository workspace management and runtime binding/missing-repository UX.
- Add resumable bounded PTY streams and lifecycle.
- Remove remaining local-path and direct-storage assumptions.

Exit: chat images, project selection, native chat, and terminal TUIs work after a disconnect/reconnect.

### 7. Direct HTTPS and deployment documentation (manual VM and local container guides landed)

- Add direct TLS profile support and certificate diagnostics.
- Preserve the landed non-root container/Compose path and add signed multi-architecture publishing, reverse-proxy, and container recovery instructions as those modes land.
- Add hermetic remote integration coverage and a manual compatibility matrix.
- Document threat model and security defaults.

Exit: a new user can deploy a runtime on an ordinary VM/container and connect without a Verde account.

### 8. Optional Connect reference control plane (reference service landed)

- Preserve the landed versioned, language-neutral OpenAPI/JSON Schema contract for OIDC
  principals, runtime link challenge/proof, runtime inventory/descriptors,
  scoped bootstrap request/response, unlink/revoke, signer/JWKS discovery,
  audit events, and endpoint-provider adapters.
- Preserve the landed self-hostable reference service with generic OIDC, signed and
  replay-safe grant issuance, revocation/audit, and cryptographic conformance
  vectors shared by every deployment.
- Preserve the landed external operator-managed endpoint adapter, then add
  runtime/desktop outbound connector lifecycle and optional managed adapters;
  keep provider API credentials and tunnel-specific identifiers behind the
  public adapter interface.
- Allow private Verde Cloud to compose the same service with subscriptions,
  provisioning, and managed operations without replacing the public contract
  or reimplementing grant cryptography.

Exit: an operator can self-host Connect identity, discovery, grants, and
endpoint integration without a Verde account, while Serve/Pair remains usable
without any control plane.

## Test matrix

At minimum, test:

- Local plus two remote connections concurrently.
- Workspace default with a per-thread Local override and a different remote override.
- A workspace with multiple repositories, different per-runtime checkout paths, and threads pinned to different repositories.
- A selected runtime missing one repository, including configure/clone/cancel paths without silently falling back to a same-named directory.
- Restart/reconnect without runtime identity drift.
- Expected-runtime mismatch and protocol-major mismatch.
- Daemon replacement between heartbeat and a subsequent RPC, with the same-request identity guard rejecting the RPC.
- Expired/revoked/bad-scope token and changed SSH host key.
- Bounded history resnapshot after cursor expiry.
- Multiple-image prompt and oversized/aborted upload.
- PTY input, resize, reconnect, exit, and cleanup.
- Every provider's installed/authenticated/missing/error state on relevant surfaces.
- GUI chat and TUI using the same authenticated runtime home.
- No credentials in logs, JSON status, process arguments, or support output.
- VM user service and rootless container cold start with persistent state.

## Explicit non-goals for the first implementation

- Moving a started thread between runtimes.
- Sharing one thread across several runtimes.
- Generic provider credential synchronization.
- Reusing Herdr SSH profiles.
- Exposing the Unix session socket over the network.
- Multi-user authorization inside one daemon instance.
- Requiring any control plane for Serve/Pair or standalone VM/container use.
- Treating private Verde Cloud subscriptions, provisioning, or operations as
  part of this first runtime implementation.
