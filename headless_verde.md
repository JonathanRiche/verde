# Headless Verde Plan

Status: agreed product and architecture scope, July 2026.

## Goal

Make Verde's workspace, agent, terminal, process, persistence, coordination,
and MCP capabilities run without the native desktop GUI. The native Verde
desktop becomes one client of the headless platform rather than the owner of
the platform's state.

The result is a reusable local-first runtime and protocol that other clients
can build on. A client may implement chat, terminal, browser, process, or
workspace experiences in any combination and may choose its own renderer for
each capability. Verde does not require third-party clients to reproduce the
Palette/SDL desktop UI.

Headless Verde is the platform. The existing native desktop remains the
first-party full client.

## Settled product decisions

1. **The existing session daemon grows into the authoritative Verde daemon.**
   Do not create a competing state daemon beside it. It already owns persistent
   PTYs and in-flight provider turns.
2. **The daemon owns shared operational state.** Workspaces, threads,
   transcripts, provider turns, PTYs, managed processes, leases, durable
   notifications, and persistence move out of GUI `AppState`.
3. **Clients own presentation.** Pane layout, focus, selection, fonts,
   rendering, local scroll positions, menus, modals, clipboard, and device
   integration are client concerns.
4. **The protocol describes resources, not desktop gestures.** Stable
   workspace, thread, turn, session, process, and browser-session IDs replace
   selected indexes and pane positions at the core boundary.
5. **MCP has no desktop dependency.** `verde mcp` talks to the daemon and must
   work when no desktop process exists. Missing optional capabilities return a
   structured capability error; they do not silently require the GUI.
6. **Capability subsets are valid clients.** A phone client may be chat-only;
   a process dashboard may omit chat and browser; a terminal client may use
   Ghostty, xterm.js, another VT renderer, or plain logs.
7. **Terminal execution and terminal presentation are separate.** The daemon
   owns PTYs, ordered output, input, resize, and lifecycle. Clients choose how
   to render them. A richer daemon-side terminal-grid service is optional.
8. **Browser execution and browser presentation are separate.** The protocol
   supports abstract browser sessions. A daemon-side headless browser adapter,
   a client-hosted browser adapter, screenshots, streamed surfaces, or no
   browser are all valid capability choices.
9. **The daemon is the only database writer.** Clients mutate state through the
   protocol and maintain local projections from snapshots and events.
10. **Local headless operation comes before networking.** Unix sockets and
    Windows named pipes remain the default trust boundary. SSH forwarding is
    the first remote transport. Direct network exposure requires a separately
    hardened authenticated transport.
11. **Remote client implementations are not part of this plan.** This work
    makes desktop, mobile, web, and third-party clients possible; it does not
    require Verde to build those clients. The protocol and client SDK are the
    extension point.

## Current architecture

Verde currently has two different service boundaries:

- `packages/desktop/src/terminal/sessionizer.zig` runs the detached
  `__session-daemon`. It owns PTYs, bounded terminal-output rings, in-flight
  provider turns, approval/cancellation state, and provider workers.
- `packages/desktop/src/ipc/server.zig` runs the Live control server inside the
  native desktop process. Its handlers receive `*AppState`, queue work onto the
  SDL main loop, and directly manipulate workspaces, panes, terminal models,
  chats, processes, browser state, and Palette UI state.
- `packages/desktop/src/cli/main.zig` implements the MCP stdio protocol, but
  MCP tool calls forward to the GUI-owned Live server. The MCP framing is
  headless; the MCP functionality is not.
- `packages/desktop/src/state.zig` mixes durable domain state with textures,
  render batches, hit regions, modal editing, window focus, browser surfaces,
  and other native presentation state.
- `packages/desktop/src/state/project.zig` mixes workspace/thread records with
  terminal `Dock` instances, pane layout, leases, managed processes, and UI
  caches.
- The GUI consumes daemon chat-turn events and writes completed transcript
  state. A running daemon turn survives a GUI close, but durable chat state is
  still finalized by a GUI client.
- SQLite state is loaded and saved by the GUI. The preference-path resolver
  depends on SDL, and broad state saves delete and reinsert the application
  snapshot.
- Terminal PTYs are daemon-owned, while the Ghostty VT model and rendered
  screen are client-owned. The daemon's current `session.screen` is a bounded
  raw-output tail, not an authoritative terminal grid.
- The embedded browser is an in-process native WebView and therefore cannot be
  treated as an existing daemon capability.

This plan preserves the parts that already have the right ownership and moves
the remaining shared state across that boundary incrementally.

## Target architecture

```text
                              local socket / named pipe
  MCP stdio adapter ----------------------+
  Verde CLI ------------------------------+
  Native desktop client ------------------+----> Verde daemon
  Other local client ---------------------+        |
                                                   +-- headless core
  Remote client -- SSH tunnel/WSS gateway --------+-- SQLite store
                                                   +-- PTYs/processes
                                                   +-- provider turns
                                                   +-- event journal
                                                   +-- optional adapters
```

The target is protocol-first:

```text
client intent
  -> typed client request
  -> versioned protocol envelope
  -> daemon command dispatcher
  -> authoritative mutation + transactional persistence
  -> revisioned event
  -> subscribed client projections
```

No core command should need to enter the SDL frame loop. Presentation commands
may be implemented by a particular client, but they are not headless-domain
commands and are not required for daemon correctness.

## Package and module boundary

The intended reusable boundary is a new logical `headless` package. Exact file
splits can remain incremental while code is migrated, but the dependency rule
is strict: headless modules must not import SDL, Palette, a native WebView,
desktop `AppState`, or terminal rendering/UI types.

Suggested shape:

```text
packages/headless/
  src/core.zig             authoritative runtime and command dispatch
  src/protocol.zig         IDs, request/response/event envelopes, versions
  src/store.zig            daemon-owned persistence interface
  src/workspaces.zig       workspace records and resource registry
  src/chat.zig             threads, turns, transcripts, approvals
  src/terminal.zig         PTY/session contracts and ordered streams
  src/processes.zig        managed/tracked processes and leases
  src/browser.zig          abstract browser-session capability contracts
  src/files.zig            attachment/file metadata and transfer contracts
  src/events.zig           revisions, subscriptions, and replay journal
  src/client.zig           transport-neutral Zig client

packages/desktop/
  src/daemon/...           process host and platform transport adapters
  src/state/...            desktop projection and per-client view state
  src/ui/...               Palette rendering and native interaction
```

The standalone daemon and native desktop may remain modes of the same shipped
binary. Package separation is about ownership and dependencies, not requiring
another installed executable.

External clients should normally use the versioned wire protocol or a client
SDK rather than linking the Zig runtime. Direct Zig embedding remains possible,
but the network/process boundary is the canonical interoperability contract.

## Ownership model

### Daemon-owned shared state

- Workspace identity, label, host path, archive state, and configuration
- Thread identity, messages, provider continuation IDs, models, and settings
- In-flight turns, structured events, approvals, cancellation, and completion
- Durable transcripts and attachment metadata
- PTY session identity, host CWD, command, PID/process group, output cursor,
  input, size, and lifecycle
- Managed process definitions and runtime state
- Tracked background/provider processes and terminal process outcomes
- Expiring workspace leases and conflict classification
- Durable surface/notification records that are meaningful without a GUI
- Browser-session records when a browser capability provider exists
- SQLite persistence, schema migration, and data consistency
- Global event revisions and replay journal
- Connected-client identity, authorization, and capability registration

### Client-owned presentation state

- Selected workspace and focused resource
- Pane/tab/split topology and responsive geometry
- Maximized/floating panes and client window state
- Terminal font, VT renderer, selection, viewport, and local scroll position
- Transcript layout, markdown caches, expanded cards, and local scroll position
- Browser presentation surface, toolbar, local focus, and native WebView details
- Draft editing cursor/selection and transient composition state
- Menus, modals, command palette, hover, animation, and hit regions
- Textures, render batches, frame arenas, and GPU resources
- Clipboard, file picker, notifications, deep links, and OS integration

### Shared but client-scoped state

Some state may be persisted by the daemon without becoming globally shared.
Examples are a client's last selected workspace, optional saved layouts, or an
unsent draft. Such records must be keyed by `client_id` or an explicit profile;
they must not become a single daemon-global focus or selected index.

## Resource model

Every shared resource receives a stable opaque ID:

- `workspace_id`
- `thread_id`
- `turn_id`
- `session_id`
- `process_id`
- `lease_id`
- `browser_session_id`
- `attachment_id`
- `client_id`

Indexes may appear in a response for display ordering, but commands must not
use a mutable index as the authoritative identity. Pane IDs remain valid inside
a client's layout; they are not core resource IDs.

Every mutable resource exposes a revision or update sequence. Commands that
can overwrite concurrent edits should optionally accept an expected revision
and return a conflict rather than silently replacing newer state.

## Protocol contract

### Request and response

Keep the existing JSON request/response envelope initially, but make the
protocol types explicit and transport-neutral:

```json
{
  "id": 42,
  "protocol_version": 1,
  "method": "chat.send",
  "params": {
    "workspace_id": "workspace-...",
    "thread_id": "thread-...",
    "prompt": "Fix the failing test"
  }
}
```

```json
{
  "id": 42,
  "ok": true,
  "result": {
    "turn_id": "turn-...",
    "accepted_revision": 108
  }
}
```

Errors retain stable machine-readable codes. Add at least:

- `capability_unavailable`
- `unauthorized`
- `conflict`
- `revision_expired`
- `client_not_found`
- `resource_not_found`
- `invalid_state`

### Snapshot and event subscription

Request/response polling is insufficient for a thin desktop client or a
remote client. Add a long-lived subscription channel:

```text
core.snapshot { scopes, workspace_ids? }
core.subscribe { after_revision, topics? }
core.unsubscribe { subscription_id }
```

Events carry:

```json
{
  "type": "event",
  "revision": 109,
  "topic": "chat.turn.delta",
  "resource_id": "turn-...",
  "payload": {}
}
```

Requirements:

- Monotonic daemon revision for shared domain changes
- Existing per-terminal byte cursor retained for raw output
- Existing per-turn sequence retained for detailed provider events
- Bounded event replay with a clear snapshot fallback
- Reconnect from last acknowledged revision
- Backpressure and bounded per-client queues
- No unbounded transcript, output, or screenshot payload in one frame
- Server heartbeat and explicit disconnect reason

Binary frames may be added later for terminal data, images, or browser frames.
JSON remains the control-plane envelope.

### Capability negotiation

Both daemon and client advertise capabilities. Capability absence is normal,
not a protocol failure.

Example daemon capabilities:

```json
{
  "chat": true,
  "terminal_raw": true,
  "terminal_grid": false,
  "managed_processes": true,
  "browser_automation": false,
  "file_transfer": true
}
```

Example client capabilities:

```json
{
  "client_id": "client-...",
  "terminal_renderer": true,
  "browser_surface": false,
  "notifications": true,
  "file_picker": true
}
```

The daemon must never infer that a desktop GUI exists merely because a local
socket is reachable.

## Headless API surface

The exact names are versioned protocol decisions, but the resource-oriented
surface should cover the following groups.

### Core and clients

- `core.status`
- `core.capabilities`
- `core.snapshot`
- `core.subscribe`
- `client.register`
- `client.updateCapabilities`
- `client.disconnect`

### Workspaces

- `workspace.list`
- `workspace.get`
- `workspace.create`
- `workspace.update`
- `workspace.archive`
- `workspace.reopen`

Selecting or focusing a workspace is client-local and is not a shared core
mutation.

### Threads and chat

- `thread.list`
- `thread.get`
- `thread.create`
- `thread.update`
- `thread.archive`
- `chat.send`
- `chat.followup`
- `chat.stop`
- `chat.approve`
- `chat.turn.get`
- `chat.turn.events`

The current MCP `open_chat` operation becomes a thread creation operation and
returns resource IDs. A particular GUI may choose to present the new thread in
a pane, but successful creation does not depend on that presentation.

### Terminals

- `terminal.list`
- `terminal.create`
- `terminal.inspect`
- `terminal.attach`
- `terminal.detach`
- `terminal.input`
- `terminal.resize`
- `terminal.output`
- `terminal.snapshot` when terminal-grid capability exists
- `terminal.kill`
- `terminal.cleanup`

### Processes and coordination

- `process.list`
- `process.inspect`
- `process.start`
- `process.stop`
- `process.restart`
- `process.logs`
- `process.wait`
- `lease.check`
- `lease.acquire`
- `lease.renew`
- `lease.release`

### Browser sessions

- `browser.capabilities`
- `browser.create`
- `browser.inspect`
- `browser.navigate`
- `browser.back`
- `browser.forward`
- `browser.reload`
- `browser.evaluate`
- `browser.pointer`
- `browser.screenshot`
- `browser.close`

These commands operate on a browser session, not a desktop pane. The providing
adapter declares whether it supports DOM inspection, low-level pointer input,
screenshots, streaming frames, or only URL/state coordination.

### Files and attachments

- `attachment.create`
- `attachment.upload`
- `attachment.inspect`
- `attachment.download`
- `attachment.delete`

Host file paths must never be assumed to exist on a remote client. Protocol
requests distinguish a daemon-host path from an uploaded attachment ID.

## Terminal capability design

### Required baseline: raw terminal service

The existing sessionizer behavior becomes the baseline terminal capability:

- Daemon owns the PTY and child process
- Output is ordered and cursor-addressable
- Input and resize are explicit commands
- Attach/detach supports multiple clients
- Session metadata includes command, CWD, PID/process group, dimensions,
  running/exited state, and bounded output availability
- Clients may feed output into Ghostty, xterm.js, another VT parser, or a log
  view

This baseline is sufficient for the current desktop and many third-party
clients, but a late client cannot always reconstruct an exact full-screen TUI
after old escape sequences leave the bounded output ring.

### Optional capability: authoritative terminal grid

For exact late attachment and bandwidth-conscious remote rendering, add an
optional daemon-side VT/grid adapter:

- Full grid and mode snapshot on attach
- Damage/delta events after the snapshot
- Scrollback retrieval separate from the visible grid
- Cursor, style, title, and terminal-mode state
- Explicit canonical resize policy when several clients attach

This service must remain presentation-neutral. It provides cells and state,
not fonts, colors, pixels, selection, or touch behavior.

The raw stream remains available even when grid capability exists.

## Browser capability design

The existing native WebView remains a desktop presentation implementation; it
is not moved wholesale into the daemon.

The browser protocol is implemented by a registered adapter. Valid adapters
include:

1. A daemon-owned headless Chromium/CDP implementation
2. A client-hosted native WebView implementation
3. An external browser automation provider
4. A state-only implementation that coordinates URLs but cannot evaluate DOM

An adapter reports granular features such as:

- navigation/history
- JavaScript evaluation
- DOM inspection
- selectors and form input
- low-level pointer input
- screenshots
- frame streaming
- downloads/uploads

A client decides whether and how to display the session. It may show a streamed
surface, periodically request screenshots, open the URL in its own WebView, or
provide no browser UI.

The standalone headless daemon may ship without a browser adapter initially.
In that state browser calls return `capability_unavailable`, while all other
headless and MCP behavior remains valid. MCP tool advertisement should reflect
the active daemon capabilities rather than promising a hidden GUI dependency.

## Chat and provider execution

Provider execution already belongs largely in the daemon. Complete that
ownership by moving transcript application and durable turn state into the
headless core.

Required behavior:

- `chat.send` is idempotent by a client-provided request key
- A daemon-accepted turn survives all client disconnects
- Provider deltas and structured tool events are appended in sequence
- Pending approvals are durable enough to be recovered after client reconnect
- A permitted client can approve or deny by `turn_id` and `call_id`
- Completion transactionally records assistant reply, tool/system events,
  provider continuation ID, usage metadata when available, and final status
- The daemon publishes events after state is committed
- Clients never need to consume a daemon result to make it durable
- Multiple clients observing one turn receive the same ordered event history

The existing provider transcript contracts remain in force: images are
preserved, streaming text and structured events remain distinct, and provider
failures are visible rather than silently dropped.

## Persistence and daemon lifecycle

### Single writer

The daemon opens the existing Verde SQLite database and becomes its only
writer. Desktop and CLI state mutations go through the daemon.

Migration requirements:

- Resolve the exact existing preference/database path without initializing SDL
- Preserve and test legacy path behavior on Linux, macOS, and Windows
- Back up or transactionally migrate before changing schema ownership
- Replace whole-application snapshot saves with targeted writes over time
- Serialize writes and publish events only after successful commit
- Ensure read snapshots correspond to a known committed revision
- Remove direct/offline client writes once the daemon can auto-start safely

### Lifetime

The authoritative daemon cannot retain the current generic 30-second idle-exit
behavior. It may be lazily started, but once started it remains available until
an explicit graceful stop, upgrade handoff, user logout, or platform service
lifecycle ends it.

Protocol-version replacement must become graceful:

1. New client detects an incompatible daemon
2. Client requests prepare-for-upgrade shutdown
3. Daemon stops accepting mutations, commits state, drains or preserves active
   PTYs/turns according to the compatible handoff policy, and closes listeners
4. New daemon starts and proves database/protocol readiness
5. Clients reconnect from a snapshot/revision

Never terminate an authoritative daemon solely because a JSON payload reports
a PID without the existing platform trust checks.

## MCP architecture

`verde mcp` remains a stdio JSON-RPC/MCP process, but becomes only an adapter:

```text
MCP initialize/tools/list/tools/call
  -> MCP schema validation
  -> headless client call
  -> daemon response/event cursor
  -> MCP content result
```

Requirements:

- Auto-start or connect to the daemon without starting SDL
- Derive default workspace from explicit arguments, Verde environment identity,
  or CWD; never from a desktop-selected workspace
- Map MCP tools to resource IDs rather than GUI pane focus
- Generate tool availability/descriptions from daemon capabilities where MCP
  client behavior allows it
- Return a clear structured error for an unavailable optional capability
- Preserve existing safety confirmations for sensitive browser/form actions
- Keep resource leases daemon-owned so independent MCP clients coordinate
- Keep MCP framing and domain command implementations separate and testable

GUI-oriented MCP tools need deliberate compatibility behavior:

- `open_chat` creates a thread and returns its IDs; presentation is optional
- `list_panes` is deprecated in favor of resource/session/thread queries or is
  explicitly scoped to a registered presentation client
- `focus_surface` is a client presentation command and is not part of the
  headless baseline
- Browser tools target `browser_session_id`, not the desktop singleton pane
- Terminal reads target `session_id`, with workspace/pane aliases retained only
  as compatibility selectors

The current Live RPC may remain temporarily as a desktop compatibility adapter,
but MCP must stop using it before headless completion is declared.

## Client SDK contract

The first SDK is the Zig client used by the native desktop and CLI. It owns:

- Endpoint discovery and daemon startup/probing
- Protocol negotiation
- Request IDs and typed result decoding
- Authentication context
- Snapshot loading
- Subscription lifecycle
- Cursor/revision persistence
- Reconnect with replay or snapshot fallback
- Bounded event queues and cancellation
- Capability registration and updates

It does not own rendering, pane layout, provider business logic, or persistence.

Publish the wire contract sufficiently for independent Swift, Kotlin,
TypeScript, Rust, or other clients. Generated SDKs are optional follow-up work;
they are not required to complete the core migration.

## Remote readiness and security

Headless does not by itself mean internet-safe. The existing local socket trusts
the current OS user and exposes operations equivalent to local code execution.

### Supported progression

1. Per-user Unix socket / Windows named pipe
2. SSH-forwarded local socket for remote desktop use
3. Optional authenticated network gateway after the protocol is stable

### Direct network gateway requirements

- Encryption in transit
- Device/user authentication and pairing
- Revocable credentials
- Per-method and per-workspace authorization scopes
- Server-side approval policy for sensitive operations
- Rate limits, payload limits, timeouts, and backpressure
- Audit records that exclude secrets and terminal/clipboard contents
- Origin protection for browser clients
- Explicit host-path versus uploaded-file semantics
- No default listener on `0.0.0.0`
- No reuse of the current `local-user-socket` claim over TCP

An SSH tunnel is the recommended first remote deployment because it supplies a
mature authenticated transport without expanding Verde's public attack surface.

## Explicit non-goals

- Building a Verde mobile application or PWA
- Porting Palette/SDL rendering to the browser
- Requiring external clients to reproduce Verde's pane layout
- Streaming the native desktop window as pixels
- Making browser or terminal rendering mandatory in every client
- Hosting provider inference or relaying user credentials through a Verde cloud
- Public unauthenticated TCP control
- Replacing SSH, tmux, or general remote-desktop products
- Recovering live PTYs across machine reboot or daemon process destruction
- Moving fonts, GPU state, clipboard contents, or native widgets into the core
- Designing every future client SDK before stabilizing the protocol

## Migration plan

Each phase must leave the current desktop usable and preserve existing terminal
and chat durability. Prefer extracting one ownership boundary at a time over a
large rewrite.

### Phase 0: freeze contracts and establish conformance tests

- Inventory every Live RPC and MCP tool as domain, presentation, or optional
  capability
- Define stable IDs, protocol envelopes, error codes, and capability schema
- Add transport-independent dispatcher tests
- Add current database-path and protocol-version fixtures for all platforms
- Record baseline terminal detach/reattach and daemon-turn recovery behavior

Exit criteria:

- Every existing command has an explicit target owner and migration decision
- New protocol types compile without importing SDL, Palette, or `AppState`
- Existing app behavior is unchanged

### Phase 1: extract the headless package and unify daemon dispatch

- Create the dependency-clean headless package boundary
- Move session/turn protocol types out of `sessionizer.zig` where appropriate
- Introduce the authoritative core dispatcher inside the existing daemon mode
- Give CLI, MCP, and desktop a shared typed daemon client
- Preserve old sessionizer methods through compatibility routing
- Replace daemon idle exit with an explicit lifecycle suitable for state
  ownership

Exit criteria:

- Headless package tests run without native GUI dependencies
- Existing PTY and in-flight turn behavior uses the shared client/dispatcher
- No second daemon process or competing source of session truth exists

### Phase 2: move process coordination and leases

- Move managed-process state, tracked process metadata, outcomes, command
  classification, and leases into daemon-owned workspace registries
- Derive terminal process state directly from daemon PTY metadata
- Route MCP process and lease tools directly to the daemon
- Keep the desktop as a projection of daemon process/lease events

Exit criteria:

- With the desktop closed, MCP can list/check/wait for processes and
  acquire/renew/release leases
- Two independent MCP clients observe the same conflicts and lease expiry
- Desktop process controls remain behaviorally equivalent

### Phase 3: move workspace/thread persistence and make the daemon sole writer

- Decouple preference path and database initialization from SDL
- Load workspace/thread records in the daemon
- Separate `Project` domain records from terminal docks and sidebar/UI caches
- Replace daemon-global selected/focused state with client-scoped state
- Route workspace/thread mutations through the daemon
- Remove or disable direct GUI database writes after parity is proven

Exit criteria:

- Daemon can start, inspect, and mutate persisted workspaces without a GUI
- Closing all clients cannot lose an accepted mutation
- Existing databases migrate without path or transcript loss
- Concurrent clients cannot overwrite state with stale whole-app snapshots

### Phase 4: make chat fully daemon-owned

- Move durable transcript application into the daemon
- Persist provider deltas/tool events and final turn outcomes transactionally
- Make approvals, cancellation, followups, and reconnect operate by stable IDs
- Remove the requirement that a GUI consume a completed daemon turn
- Route MCP chat tools directly to the daemon

Exit criteria:

- A headless MCP client can create a thread, send a prompt, observe streaming
  events, approve/deny, stop, and read the durable transcript
- A turn completes and persists while every GUI is closed
- Reopening the desktop renders the same transcript without a consume handshake

### Phase 5: add subscriptions and convert the desktop to a client

- Add snapshot, event subscription, replay, heartbeat, and reconnect behavior
- Split native `AppState` into daemon projection and per-client `ViewState`
- Route desktop domain mutations through the typed client
- Keep Ghostty parsing/rendering and the native WebView in the desktop client
- Remove GUI-main-loop ownership from the authoritative Live RPC
- Retain a compatibility facade for documented CLI commands during migration

Exit criteria:

- Native desktop can close/reopen/reconnect without owning shared state
- Desktop and CLI/MCP can mutate and observe the same workspace concurrently
- No core or MCP command requires `LiveServer.processPending(&AppState)`
- Disconnection and replay are covered by integration tests

### Phase 6: complete capability adapters

- Formalize raw terminal streaming as the required terminal capability
- Add an optional terminal-grid snapshot/delta adapter if demanded by clients
- Formalize browser-session provider registration and granular capabilities
- Add a daemon headless-browser adapter only as a separately testable feature
- Add attachment upload/download rather than assuming shared local paths
- Make MCP tool behavior and advertisement capability-aware

Exit criteria:

- A client can implement terminal or browser presentation without importing
  Verde desktop code
- Clients that omit terminal or browser remain valid
- Missing adapters return stable capability errors
- File/image prompts work across a process or machine boundary

### Phase 7: remote transport hardening

- Document and test SSH socket forwarding
- Add authenticated network gateway only after threat-model review
- Add pairing, revocation, scopes, audit metadata, and transport limits
- Test independent client versions, reconnect, slow consumers, and upgrades

Exit criteria:

- Another machine can run a Verde client against the host daemon over an
  authenticated encrypted connection
- No public/LAN listener is enabled by default
- Security tests cover unauthorized terminal input, process control, approvals,
  browser evaluation, and attachment access

This phase makes remote clients supportable; implementing a mobile or web UI is
left to client authors.

## Compatibility and rollout

- Maintain the current sessionizer protocol until the desktop and CLI use the
  new client path
- Version the headless protocol independently from UI release details
- Advertise minimum/maximum compatible protocol versions
- Prefer additive fields and capabilities within a protocol version
- Use explicit migrations for renamed or redefined methods
- Preserve terminal session IDs and provider turn IDs through migration
- Preserve existing SQLite location and data before changing ownership
- Keep a rollback path until daemon-owned persistence has survived real usage
- Never run old and new writers against the same database concurrently

The first release may ship the daemon-backed path only for process/lease tools,
then expand ownership by phase. Do not claim full headless completion until the
acceptance criteria below pass with no desktop process running.

## Verification strategy

### Unit tests

- Protocol decoding, unknown fields, limits, and stable error codes
- Stable ID parsing and selector resolution
- Capability negotiation
- Event ordering, replay, expiry, and snapshot fallback
- Lease conflict, renewal, force, and expiry
- Terminal cursor/ring overflow behavior
- Turn idempotency, event order, approval, cancellation, and persistence
- Store migrations and transactional event publication

### Daemon integration tests

- Start/probe/graceful shutdown and incompatible-version handoff
- No-GUI workspace and thread load/mutation
- PTY create/attach/write/resize/tail/detach/kill
- Provider turn completion with all clients disconnected
- Two-client subscriptions and reconnect from revision
- Slow-client backpressure and bounded memory
- Crash/restart recovery for committed state

### Desktop regression tests

- Existing pane layout, terminal rendering, chat streaming, approvals, and
  browser behavior
- Desktop reconnect after daemon restart
- Desktop and MCP simultaneous mutations
- Client-local focus/layout remains independent between two clients
- No GUI frame-loop stalls from daemon requests

### Remote transport tests

- SSH-forwarded socket from another machine/process namespace
- Authentication rejection and credential revocation
- Reconnect after transient network loss
- Attachment transfer without shared paths
- Raw terminal and optional grid behavior under latency

Every completed Zig phase follows repository policy: focused checks during
iteration and `mise run build` before completion.

## Definition of done

Headless Verde is complete when all of the following are true:

- [ ] The daemon starts and serves the supported core protocol without SDL,
      Palette, a native window, or desktop `AppState`
- [ ] The daemon is the sole writer of workspace, thread, transcript, process,
      and lease state
- [ ] `verde mcp` works with no desktop process and never forwards through the
      GUI Live server
- [ ] Headless clients can list/mutate workspaces, create/send/read chats,
      operate PTY sessions, inspect/control processes, and coordinate leases
- [ ] Accepted provider turns and their transcripts survive all client
      disconnects
- [ ] Native desktop operates as a snapshot/event client of the daemon
- [ ] Two clients can concurrently observe shared resources without sharing
      focus or presentation state
- [ ] Terminal raw-stream behavior is documented and usable by independent
      renderers
- [ ] Browser behavior is exposed through explicit optional capabilities, with
      no hidden desktop dependency
- [ ] Attachment APIs do not assume client and daemon share a filesystem
- [ ] Protocol reconnect/replay and version negotiation are tested
- [ ] No unauthenticated network listener is introduced
- [ ] The wire contract is documented well enough for an independent client to
      implement only the features it wants

## Outcome

After this plan, Verde is not merely a desktop app with a background helper. It
is a local-first headless workspace and agent runtime with a first-party native
client.

Desktop, mobile, web, and third-party clients can choose their own experience:

- consume only chat and approvals
- render PTYs with their preferred terminal implementation
- use daemon-hosted or client-hosted browser capabilities
- build process and lease dashboards
- create a full tiled workspace or no panes at all

The daemon guarantees durable shared behavior. Each client decides what to
present and how to present it.
