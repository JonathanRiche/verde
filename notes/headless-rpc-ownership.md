# Headless RPC/MCP ownership and migration decisions

M0 artifact for issue #116 ("Make Verde daemon and MCP fully headless").
This table gives every Live RPC method and every MCP tool an explicit owner
and migration decision, per the Phase 0 exit criteria in `headless_verde.md`.

Classifications:

- **daemon-domain** — moves to (or already lives in) the headless daemon.
  Works with no desktop process once its target phase lands.
- **client-presentation** — stays client-owned (pane layout, focus, selection,
  palette, overlays). Headless callers get `capability_unavailable` /
  `client_not_found`, never a silent GUI dependency and never a fake empty
  result.
- **optional capability** — served by a registered capability adapter
  (browser, terminal grid). Returns `capability_unavailable` when no adapter
  is registered; the desktop registers itself as one adapter.

Phases `M0`–`M6` are `headless_verde.md` migration phases 0–6 (M0 contracts,
M1 headless package + daemon dispatch, M2 processes/leases, M3
workspace/thread persistence + sole writer, M4 daemon-owned chat, M5
subscriptions + desktop-as-client, M6 capability adapters).

Current state (this branch): `packages/headless` (protocol/dispatch/client)
and daemon-hosted `core.status` / `core.capabilities` landed in commits
`ac582939` / `916fc061`, plus CLI `verde core`
(`packages/desktop/src/cli/main.zig:handleCore`). MCP terminal tools
(`tail_surface_output`, `write_surface_text`, `send_terminal_key`,
`read_surface_screen`) already accept `session_id` and route daemon-direct
without Live/GUI (`cli/main.zig:mcpToolsCall` →
`mcpDaemonSessionCallAlloc`), including the `raw_tail` fidelity marker
(`mcpDaemonScreenResponseWithFidelityAlloc`).

All Live symbols below are in `packages/desktop/src/ipc/server.zig`; all MCP
symbols are in `packages/desktop/src/cli/main.zig`. Dispatch entry points:
`handleRequest` (Live), `mcpToolsList` / `mcpToolsCall` (MCP). The advertised
Live command list is `capabilitiesResponse`.

## Table 1: Live RPC methods

Aliases handled by one dispatch arm share a row (`workspaces`/`projects`,
`surfaces`/`surface.list`, `notification.create`/`notification.update`,
`workspace.close`/`workspace.archive`,
`browser.overlay.workspaceModal*`/`projectModal*`). Note: `browser.cutFocused`
is dispatched by `browserCommandResponse` but is missing from the
`capabilitiesResponse` advertisement; treat the dispatch as authoritative.

### Core / inspection

| Live method | Symbol | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|---|
| `status` | `statusResponse` | split: daemon-domain core status; selected index/focus/pane fields are client-presentation | M1/M5 | Daemon counterpart is `core.status` (headless `dispatch.zig`, daemon-hosted). Live `status` remains a desktop compat view until M5, then becomes a client-side projection. | daemon side done |
| `capabilities` | `capabilitiesResponse` | split: daemon-domain capability negotiation; Live command list is a desktop adapter contract | M1/M5 | Daemon counterpart is `core.capabilities` with capability flags per `headless_verde.md`. Live `capabilities` continues to describe the desktop adapter only. | daemon side done |
| `workspaces` / `projects` | `workspacesResponse` | daemon-domain | M3 | Becomes `workspace.list` on daemon-owned workspace records. `selected_workspace_index` field is client-scoped and leaves the core response. | pending |
| `active` | `activeResponse` | client-presentation | M5 | Selected workspace / focused pane is client-local state. Headless: `client_not_found` (no registered presentation client). | pending |
| `panes` | `panesResponse` | client-presentation | M5 | Deprecated toward `thread.list` + `terminal.list`. Headless: `capability_unavailable`/`client_not_found`, **not** an empty list (see compatibility section). | pending |
| `threads` | `threadsResponse` | daemon-domain | M3 | Becomes `thread.list` over daemon-persisted thread records. | pending |
| `terminals` | `terminalsResponse` | daemon-domain | M2 | Daemon already owns sessions (`session.list`); M2 derives terminal process state from daemon PTY metadata; pane decoration stays client-side. | pending |
| `inspect` | `inspectResponse` | client-presentation | M5 | Pane-addressed inspect; deprecated toward `thread.get` / `terminal.inspect` / `process.inspect` by resource ID. | pending |

### Surfaces and notifications

| Live method | Symbol | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|---|
| `surfaces` / `surface.list` | `surfacesResponse` | daemon-domain | M2 | Durable surface records are meaningful without a GUI. Open decision: merge with daemon session registry (see below). | pending |
| `surface.inspect` | `surfaceInspectResponse` | daemon-domain | M2 | Targets `session_id` already; moves with the surface registry. | pending |
| `surface.focus` | `surfaceFocusResponse` | split: focus is client-presentation; attention-clear side effect is daemon-domain | M2/M5 | Split into daemon `surface.clearAttention` + client focus command (see compatibility section). Headless focus: `client_not_found`. | pending |
| `surface.clearAttention` | `surfaceClearAttentionResponse` | daemon-domain | M2 | Attention state lives on the durable surface record in the daemon. | pending |
| `notification.create` / `notification.update` | `notificationUpdateResponse` | daemon-domain | M2 | Durable notification records move to the daemon; clients render them from events. | pending |
| `notification.clear` | `notificationClearResponse` | daemon-domain | M2 | Same as above. | pending |

### Workspace commands (`workspaceCommandResponse`)

| Live method | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|
| `workspace.select` | client-presentation | M5 | Selection is client-local (plan: no daemon-global selected index). Headless: `client_not_found`; may become client-scoped persisted state keyed by `client_id`. | pending |
| `workspace.create` | daemon-domain | M3 | `workspace.create` on daemon records; daemon becomes sole DB writer. | pending |
| `workspace.rename` | daemon-domain | M3 | `workspace.update`. | pending |
| `workspace.close` / `workspace.archive` | daemon-domain | M3 | `workspace.archive`. | pending |
| `workspace.reopen` | daemon-domain | M3 | `workspace.reopen`. | pending |
| `workspace.processes` (also top-level `processes` alias → `workspaceProcessesResponse`) | daemon-domain | M2 | `process.list` over daemon-owned workspace process registries. | pending |
| `workspace.checkCommand` | daemon-domain | M2 | `lease.check` / command classification in daemon. | pending |
| `workspace.acquireLease` | daemon-domain | M2 | `lease.acquire` (+ renew semantics) in daemon so independent MCP clients coordinate. | pending |
| `workspace.releaseLease` | daemon-domain | M2 | `lease.release` in daemon. | pending |

### Pane commands (`paneCommandResponse`)

All pane topology is client layout state; pane IDs are not core resource IDs.

| Live method | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|
| `pane.focus` | client-presentation | M5 | `capability_unavailable`/`client_not_found` headless. | pending |
| `pane.split` | client-presentation | M5 | Same. | pending |
| `pane.resize` | client-presentation | M5 | Same. | pending |
| `pane.move` | client-presentation | M5 | Same. | pending |
| `pane.maximize` | client-presentation | M5 | Same. | pending |
| `pane.close` | client-presentation | M5 | Same. Closing a pane must not destroy the underlying daemon session/thread. | pending |

### Chat commands (`chatCommandResponse`, `chatOpenResponse`)

| Live method | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|
| `chat.open` | split: thread creation is daemon-domain; pane creation is client-presentation | M3/M4 | Becomes `thread.create` returning `thread_id`; pane presentation optional (see compatibility section). | pending |
| `chat.status` | split: turn/thread status daemon-domain; pane/draft fields client | M4 | Becomes `chat.turn.get` / `thread.get` by stable IDs. | pending |
| `chat.transcript` | daemon-domain | M4 | Durable transcript reads move to daemon once transcript application is daemon-owned. | pending |
| `chat.draft.set` | shared but client-scoped | M5 | Draft is client-scoped state (plan: keyed by `client_id` if daemon-persisted). Open decision below. | pending |
| `chat.draft.append` | shared but client-scoped | M5 | Same. | pending |
| `chat.send` | daemon-domain | M4 | Provider execution already daemon-hosted (`chat.turn.start`); M4 removes the AppState hop and the GUI consume handshake. Idempotent by request key. | pending |
| `chat.followup` | daemon-domain | M4 | By `thread_id`/`turn_id`. | pending |
| `chat.stop` | daemon-domain | M4 | Daemon `chat.turn.cancel` by `turn_id`. | pending |
| `chat.approve` | daemon-domain | M4 | Daemon `chat.turn.approve` by `turn_id`/`call_id`; approvals durable across client reconnect. | pending |

### Browser commands (`browserCommandResponse`)

Browser *sessions* are an optional capability served by a registered adapter
(daemon headless browser, client-hosted WebView, external provider, or
state-only). Desktop-gesture browser methods are client-presentation and never
become headless-domain commands.

| Live method | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|
| `browser.status` | optional capability | M6 | `browser.inspect`/`browser.capabilities` on a `browser_session_id`; `capability_unavailable` without adapter. | pending |
| `browser.open` | optional capability | M6 | `browser.create` (+ navigate) on abstract session. | pending |
| `browser.close` | optional capability | M6 | `browser.close` by session ID. | pending |
| `browser.navigate` | optional capability | M6 | `browser.navigate`. | pending |
| `browser.back` / `browser.forward` / `browser.reload` | optional capability | M6 | History ops; adapter feature-gated. | pending |
| `browser.restart` / `browser.reset` | optional capability | M6 | Adapter lifecycle ops; adapter declares support. | pending |
| `browser.eval` | optional capability | M6 | `browser.evaluate`; adapter feature `javascript_eval`. | pending |
| `browser.postJson` | optional capability | M6 | Adapter feature; capability-gated. | pending |
| `browser.pointerDown` / `browser.pointerMove` / `browser.pointerUp` | optional capability | M6 | `browser.pointer`; adapter feature `low_level_pointer`. | pending |
| `browser.screenshot` | optional capability | M6 | `browser.screenshot`; adapter feature-gated (CPU-frame capture today). | pending |
| `browser.toggle` | client-presentation | M5 | Pane visibility gesture; `capability_unavailable` headless. | pending |
| `browser.focus` / `browser.blur` | client-presentation | M5 | Native surface focus; headless `client_not_found`. | pending |
| `browser.toolbarHit` | client-presentation | M5 | Desktop toolbar geometry; never headless. | pending |
| `browser.selectAllFocused` / `browser.copyFocused` / `browser.cutFocused` / `browser.pasteTextFocused` | client-presentation | M5 | Clipboard/native-field gestures; clipboard never enters the core. (`cutFocused` is unadvertised in `capabilitiesResponse`; fix advertisement or drop.) | pending |
| `browser.inspector.enable` / `.disable` / `.toggle` / `.mode` / `.menuOpen` / `.menuClose` | client-presentation | M5 | Desktop inspector UI; `capability_unavailable` headless. | pending |
| `browser.overlay.workspaceMenuOpen`/`Close`, `.sidebarMenuOpen`/`Close`, `.composerMenuOpen`/`Close`, `.workspaceModalOpen`/`Close` (alias `projectModal*`), `.threadModalOpen`/`Close`, `.imageModalOpen`/`Close`, `.transcriptModalOpen`/`Close` | client-presentation | M5 | Overlay/modal state is pure desktop UI; `capability_unavailable` headless. | pending |

### Palette commands (`paletteCommandResponse`)

| Live method | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|
| `palette.list` | client-presentation | M5 | Command palette is desktop UI (`ui/command_palette.zig`). Headless: `capability_unavailable`. | pending |
| `palette.run` | client-presentation | M5 | Same. | pending |

### Terminal commands (`terminalCommandResponse`)

Execution is daemon-domain (daemon already owns PTYs); the *pane* addressing
in these methods is client compat. See compatibility section.

| Live method | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|
| `terminal.write` | daemon-domain (pane selector compat-only) | M1 | Core path is `session.write` by `session_id` (daemon-direct today via MCP/typed client); Live pane form remains a compat selector. | daemon path done |
| `terminal.key` | daemon-domain (pane selector compat-only) | M1 | Validated chord encoding → `session.write`; same allowlist as Live (`mcpEncodeTerminalKeyAlloc` / `terminalKeyChordParam`). | daemon path done |
| `terminal.tail` | daemon-domain (pane selector compat-only) | M1 | Core path is `session.tail` (`terminal.output`). | daemon path done |
| `terminal.screen` | split: raw tail daemon-domain; rendered VT grid is optional capability | M1/M6 | Daemon `session.screen` is a bounded raw tail (`fidelity: raw_tail`). Live `terminal.screen` reads the client Ghostty grid; that fidelity becomes the optional `terminal_grid` capability. | raw path done; grid pending |

### Process, agent, stack commands

| Live method | Symbol | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|---|
| `process.list` | `processCommandResponse` | daemon-domain | M2 | Managed-process registry moves to daemon. | pending |
| `process.inspect` | `processCommandResponse` | daemon-domain | M2 | By `process_id`/name. (Pane-form `inspect` without `name` is client compat.) | pending |
| `process.start` / `process.stop` / `process.restart` | `processCommandResponse` | daemon-domain | M2 | Daemon starts/owns managed processes; desktop projects state. | pending |
| `process.logs` | `processCommandResponse` | daemon-domain | M2 | Bounded log tail from daemon-owned process records. | pending |
| `agent.open` | `agentCommandResponse` | split: TUI session spawn is daemon-domain (`terminal.create` + provider command); pane placement is client-presentation | M5 | Headless form creates a daemon PTY session running the provider TUI and returns `session_id`/`process_id`; pane presentation optional, like `chat.open`. | pending |
| `stack.status` | `stackCommandResponse` | daemon-domain | M2 | Stack is a grouping over managed processes; moves with them. | pending |
| `stack.start` / `stack.stop` / `stack.restart` | `stackCommandResponse` | daemon-domain | M2 | Same. | pending |

### Herdr commands

| Live method | Symbol | Classification | Phase | Headless behavior / migration | Status |
|---|---|---|---|---|---|
| `herdr.open` | `herdrOpenResponse` | split: workspace link record daemon-domain; opening/selecting the workspace pane client-presentation | M3 | Link creation persists with workspace records; presentation optional. Open decision below. | pending |
| `herdr.handoff` | `herdrHandoffResponse` | daemon-domain | M3 | Runs the herdr CLI against workspace link records; no UI dependency in principle. Open decision on where the herdr subprocess runs. | pending |
| `herdr.unlink` | `herdrUnlinkResponse` | daemon-domain | M3 | Mutates persisted link records. | pending |
| `herdr.status` | `herdrStatusResponse` | daemon-domain | M3 | Reads link records; today enriched with pane state (client-side detail drops out of core response). | pending |

## Table 2: MCP tools

All tools are declared in `mcpToolsList` and dispatched in `mcpToolsCall`.
Today every tool except the `session_id` terminal paths forwards to the GUI
Live server via `sendLiveRequestAlloc`. Target: every daemon-domain tool
calls the daemon typed client; client-presentation tools return structured
errors; optional-capability tools negotiate adapters.

### Workspace / pane / chat

| MCP tool | Wraps today | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|---|
| `list_workspaces` | Live `workspaces` | daemon-domain | M3 | Daemon `workspace.list`; drops `selected_workspace_index` dependence. | pending |
| `list_panes` | Live `panes` | client-presentation | M5 | Deprecated toward `thread.list`/`terminal.list`; headless returns `capability_unavailable`, not an empty list. | pending |
| `open_chat` | Live `chat.open` (`focus:false`) | split: thread creation daemon-domain; pane optional | M3/M4 | Becomes `thread.create` (+ optional presentation hint); never fails merely because no desktop exists. | pending |

### Surfaces / terminal

| MCP tool | Wraps today | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|---|
| `list_surfaces` | Live `surfaces` | daemon-domain | M2 | Daemon surface registry (merge decision below). | pending |
| `inspect_surface` | Live `surface.inspect` | daemon-domain | M2 | By `session_id`; moves with surface registry. | pending |
| `read_surface_screen` | daemon `session.screen` with `session_id` (+ `fidelity: raw_tail`); Live `terminal.screen` with `pane_id` | daemon-domain baseline; rendered grid optional capability | M1/M6 | `session_id` path needs no GUI (done). Grid-fidelity read becomes optional `terminal_grid` capability. Pane selector compat-only. | session path done |
| `tail_surface_output` | daemon `session.tail` with `session_id`; Live `terminal.tail` with `pane_id` | daemon-domain | M1 | Daemon-direct path done; pane selector compat-only. | done (daemon path) |
| `write_surface_text` | daemon `session.write` with `session_id`; Live `terminal.write` with `pane_id` | daemon-domain | M1 | Daemon-direct path done; pane selector compat-only. | done (daemon path) |
| `send_terminal_key` | daemon `session.write` (validated chord encoding) with `session_id`; Live `terminal.key` with `pane_id` | daemon-domain | M1 | Daemon-direct path done with the same key allowlist as Live. | done (daemon path) |
| `notify_surface` | Live `notification.update` | daemon-domain | M2 | Durable notification record in daemon. | pending |
| `clear_surface_attention` | Live `surface.clearAttention` | daemon-domain | M2 | Attention state in daemon surface record. | pending |

### Processes / leases

| MCP tool | Wraps today | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|---|
| `list_processes` | Live `workspace.processes` | daemon-domain | M2 | Daemon `process.list`. | pending |
| `check_command` | Live `workspace.checkCommand` | daemon-domain | M2 | Daemon `lease.check`/classification. | pending |
| `acquire_lease` | Live `workspace.acquireLease` | daemon-domain | M2 | Daemon `lease.acquire`; independent MCP clients coordinate. | pending |
| `release_lease` | Live `workspace.releaseLease` | daemon-domain | M2 | Daemon `lease.release`. | pending |
| `wait_for_process` | client-side 500 ms polling of Live `workspace.processes` (`mcpWaitForWorkspaceProcessAlloc` → `waitForWorkspaceProcessWithTransportAlloc`) | daemon-domain | M2 | Repoint polling at the daemon in M2; open decision on daemon-side `process.wait`/subscription below. | pending |
| `inspect_process` | Live `process.inspect` | daemon-domain | M2 | By name/`process_id`. | pending |
| `tail_process_logs` | Live `process.logs` | daemon-domain | M2 | Daemon-owned bounded logs. | pending |
| `restart_process` | Live `process.restart` | daemon-domain | M2 | Daemon process control. | pending |
| `stop_process` | Live `process.stop` | daemon-domain | M2 | Daemon process control. | pending |
| `start_process` | Live `process.start` | daemon-domain | M2 | Daemon process control. | pending |

### Browser

All browser tools become optional-capability tools targeting a
`browser_session_id` served by a registered adapter; `capability_unavailable`
with no adapter. The desktop WebView registers as one adapter (M6).

| MCP tool | Wraps today | Classification | Phase | Headless behavior | Status |
|---|---|---|---|---|---|
| `browser_status` | Live `browser.status` | optional capability | M6 | `browser.inspect` + adapter capability report. | pending |
| `open_browser` | Live `browser.open` | optional capability | M6 | `browser.create`/`browser.navigate` on session. | pending |
| `navigate_browser` | Live `browser.navigate` | optional capability | M6 | `browser.navigate`. | pending |
| `restart_browser` | Live `browser.restart` | optional capability | M6 | Adapter lifecycle. | pending |
| `reset_browser` | Live `browser.reset` | optional capability | M6 | Adapter lifecycle. | pending |
| `evaluate_browser_js` | Live `browser.eval` + `browser.status` result polling (`mcpBrowserEvalAndWaitAlloc`) | optional capability | M6 | `browser.evaluate` with a real completion result instead of nonce polling. | pending |
| `browser_pointer_input` | Live `browser.pointerDown`/`Move`/`Up` | optional capability | M6 | `browser.pointer`; adapter feature `low_level_pointer`. | pending |
| `inspect_browser_page` | injected JS via `browser.eval` (`mcpBrowserInspectScriptAlloc`) | optional capability | M6 | Adapter DOM-inspection feature. | pending |
| `click_browser_element` | injected JS via `browser.eval` (`mcpBrowserClickScriptAlloc`; sensitivity check inside injected script) | optional capability | M6 | Adapter selector-click feature; safety confirmation moves daemon-side (see below). | pending |
| `type_browser_text` | injected JS via `browser.eval` (`mcpBrowserTypeScriptAlloc`; password/submit confirmation inside injected script) | optional capability | M6 | Adapter form-input feature; safety confirmation moves daemon-side. | pending |
| `capture_browser_screenshot` | Live `browser.screenshot` | optional capability | M6 | Adapter screenshot feature. | pending |

## Compatibility strategy for GUI-shaped operations

### `open_chat` → thread creation

`open_chat` becomes `thread.create` semantics: the daemon creates and
persists a thread (workspace ID, provider, model, reasoning settings) and
returns `thread_id` (plus `turn_id` once a prompt is attached via
`chat.send`). Pane creation is an optional presentation effect: when a
desktop client is registered, the daemon (or the adapter path) may notify it
to open a pane using today's `target_pane_id`/`axis`/`focus:false` hints;
when none is registered, creation still succeeds and the hints are recorded
or ignored. `open_chat` must never fail because no desktop exists. The MCP
input schema keeps `target_pane_id`/`axis` as optional presentation hints
only.

### `list_panes` deprecation

`list_panes` is a projection of one client's layout, which the daemon must
not own. It is deprecated in favor of `thread.list` + `terminal.list`
(resource queries) or an explicitly client-scoped query against a registered
presentation client. Headless behavior is a structured
`capability_unavailable`/`client_not_found` error — not an empty list, which
would falsely report "no panes" and mislead agents into recreating
resources.

### `surface.focus` split

`surfaceFocusResponse` today both focuses the pane and clears attention.
Split: attention-clear is a daemon-domain mutation on the durable surface
record (`surface.clearAttention`), because attention must be visible and
clearable without a GUI. Focus is a client presentation command routed to a
registered client; headless it returns `client_not_found`. MCP has no
`focus_surface` tool and must not gain one in the headless baseline.

### Browser tools

Browser commands negotiate a registered adapter per `headless_verde.md`
(daemon headless browser, client-hosted WebView, external provider, or
state-only). The desktop registers its native WebView as an adapter with
granular features (eval, pointer, screenshot, DOM inspection). Without any
adapter the standalone daemon returns `capability_unavailable` and MCP
advertisement reflects that. Safety confirmations for sensitive actions
(`confirmed=true` for submit/password/destructive clicks) are currently
enforced inside injected JavaScript built by the MCP process; in the target
architecture the confirmation policy is enforced daemon-side so it cannot be
bypassed by talking to the adapter directly, and adapters only execute
already-authorized actions.

### Terminal aliases

`session_id` is the authoritative address for terminal reads/writes; the
daemon-direct MCP path for `tail_surface_output`, `write_surface_text`,
`send_terminal_key`, and `read_surface_screen` is done. `pane_id` +
`workspace` selectors remain compatibility-only addressing through the
desktop Live adapter and are dropped from the headless baseline.
`read_surface_screen` responses from the daemon carry `fidelity: "raw_tail"`
(done) to make explicit that the daemon screen is a bounded raw ring tail,
not a rendered grid; grid-fidelity reads are the optional `terminal_grid`
capability (M6). Key encoding uses the same allowlist as Live
(`terminal.encodeKeyChordDefaultAlloc`), so the daemon path never accepts
free-form control strings that Live would reject.

## Open decisions

1. **Terminal grid fidelity contract (M6).** What exactly does the optional
   `terminal_grid` capability guarantee: full grid + mode snapshot, damage
   deltas, scrollback access, canonical multi-client resize policy? And when
   a desktop client with a Ghostty grid is connected but the daemon has no
   grid adapter, may `read_surface_screen` route a grid read through that
   client, or is `raw_tail` the only headless answer?
2. **`wait_for_process`: polling vs subscription.** Today it is client-side
   500 ms polling of `workspace.processes`. Options: keep polling but against
   the daemon (M2), add a daemon-side blocking `process.wait`, or build on
   `core.subscribe` process events (M5). Blocking waits hold a connection;
   subscriptions need the M5 event channel. Decide before M2 exit criteria
   are declared.
3. **Herdr pane-link split.** `herdr.open` mixes durable link records with
   opening/selecting a workspace in the GUI; `herdr.handoff` spawns the herdr
   CLI from the desktop process. Decide: does the daemon own the herdr link
   records and run the herdr subprocess (daemon-domain), with the desktop
   only presenting linked workspaces — or does herdr integration remain a
   desktop-client feature layered on daemon workspace records?
4. **`chat.draft` scope.** Drafts are "shared but client-scoped" per the
   plan. Decide whether drafts are daemon-persisted keyed by `client_id`
   (survive client restart, enable hand-off) or purely client-local (Live
   `chat.draft.*` then becomes a client command and disappears from the
   core protocol).
5. **Static vs dynamic MCP `tools/list` advertisement.** The plan wants tool
   availability derived from daemon capabilities, but many MCP clients cache
   `tools/list` once. Decide between: static full list with structured
   `capability_unavailable` results (current direction), dynamic list at
   initialize time, or `listChanged` notifications when adapters
   register/unregister.
6. **Surfaces-vs-sessions registry merge.** The Live surface registry
   (`surfaces`, `surface.inspect`, `notify_surface`) overlaps the daemon
   session registry (`session.list` metadata). Decide whether surfaces
   become notification/attention fields on daemon session records (one
   registry, one ID space) or remain a separate durable record type that can
   also describe non-PTY surfaces.
