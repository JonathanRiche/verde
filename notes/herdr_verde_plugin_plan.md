# Herdr-backed Verde Workspace Plan

Status: feature-complete MVP implemented for the agreed CLI/plugin/UI flow. The
CLI/plugin attach-pickup path, local and remote Herdr handoff, runtime
unlink/back-to-local flow, command-palette/workspace-context controls, saved
remote profiles, in-app remote profile picker, default remote workspace
directories, remote-workspace terminal SSH launch, and remote Codex GUI
execution slice have landed. Local and remote Herdr handoff/pickup are
verified; remote Codex GUI sends have been smoke-tested through the SSH tunnel.
Phase 4/5 remain the structured-backend, reconnect, and hardening buckets
rather than blockers for the v1 workflow.

Goal: let a Verde workspace run on either Verde's current local runtime or a
Herdr session, with Herdr providing persistent local/remote panes and a TUI
fallback. When Verde is unavailable, the user should be able to continue in
Herdr; when Verde is available again, the user should be able to pick up the
same Herdr workspace in the Verde GUI.

References:

- https://herdr.dev/docs/how-to-work/
- https://herdr.dev/docs/persistence-remote/
- https://herdr.dev/docs/session-state/
- https://herdr.dev/docs/cli-reference/
- https://herdr.dev/docs/plugins/
- https://herdr.dev/docs/socket-api/

## Product model

Herdr should be treated as a session backend, not as a replacement for the Verde
GUI.

```text
Verde GUI
  -> Herdr CLI/socket
  -> local or remote Herdr server
  -> persistent terminal panes / TUI agents / agent state
```

The user-facing promise:

> Verde can attach to a Herdr-backed workspace when a GUI is useful. Herdr keeps
> the actual work running and remains usable directly from any terminal or SSH
> client.

This solves the original remote requirement because the long-running work lives
inside the Herdr server on the machine where the code and credentials live. SSH
is only the transport.

## Important constraints

- Do not make SSH credentials the persistence story. Persistence comes from the
  Herdr server and its live panes.
- Prefer SSH config aliases over storing raw host/user/key details in Verde.
  Verde can store the alias, session name, and remote cwd.
- Do not store passwords or API keys in Verde settings. Remote agents must use
  credentials already available on the remote host, or an explicit future
  credential-sync flow.
- The Herdr plugin cannot provide native Verde GUI UI. Herdr plugin v1 is a
  manifest plus out-of-process commands, actions, hooks, terminal panes, and
  link handlers. The plugin should invoke Verde, not render Verde.
- Switching a workspace from local to Herdr-backed should not promise live
  migration in the first version. It should attach/create a corresponding Herdr
  session and make the boundary clear.

## Core workflow

### Start in Verde

1. User creates or opens a Verde workspace.
2. User chooses runtime:
   - `Verde local`
   - `Herdr local`
   - `Herdr remote: <profile>`
3. Verde creates or attaches to a Herdr session and Herdr workspace.
4. Verde renders the GUI shell while process-backed panes are owned by Herdr.
5. If Verde exits, the Herdr server and panes continue.

### Continue in Herdr

For a local Herdr-backed workspace:

```bash
herdr --session verde-<workspace>
```

For a remote Herdr-backed workspace:

```bash
herdr --remote workbox --session verde-<workspace>
```

Or from a normal SSH shell:

```bash
ssh workbox
herdr --session verde-<workspace>
```

### Pick back up in Verde

From inside Herdr, the Herdr-Verde plugin exposes an action such as
`Open in Verde`. That action calls a Verde CLI entrypoint with the current
Herdr context:

```bash
verde herdr open \
  --session "$HERDR_SESSION" \
  --herdr-workspace "$HERDR_WORKSPACE_ID" \
  --pane "$HERDR_PANE_ID"
```

For remote sessions:

```bash
verde herdr open \
  --remote workbox \
  --session verde-myproject \
  --herdr-workspace "$HERDR_WORKSPACE_ID"
```

Verde then focuses or starts the GUI, resolves the Herdr target, and attaches
to the matching workspace instead of creating a duplicate.

## Data model sketch

Keep Herdr identity separate from Verde's existing project/thread identity.

```zig
const WorkspaceRuntime = union(enum) {
    verde_local,
    herdr_local: HerdrTarget,
    herdr_remote: HerdrRemoteTarget,
};

const HerdrTarget = struct {
    session_name: []const u8,
    workspace_id: ?[]const u8,
    cwd: []const u8,
};

const HerdrRemoteTarget = struct {
    profile_id: []const u8,
    ssh_target: []const u8, // Prefer SSH config alias, e.g. "workbox".
    session_name: []const u8,
    workspace_id: ?[]const u8,
    remote_cwd: []const u8,
};

const HerdrWorkspaceLink = struct {
    verde_workspace_id: []const u8,
    runtime: WorkspaceRuntime,
    last_tab_id: ?[]const u8,
    last_pane_id: ?[]const u8,
    updated_at_unix_ms: i64,
};
```

Open question for implementation: decide where this mapping belongs. Likely
options are the existing Verde project DB for durable workspace links, plus a
small JSON cache for transient last-pane focus.

## Verde CLI surface

Add a Verde-side Herdr command group. This is required because the Herdr plugin
needs a stable way to ask Verde to open/focus a GUI workspace.

```bash
verde herdr open \
  --herdr-workspace <herdr-workspace-id> \
  [--session <session-name>] \
  [--profile <name>|--remote <ssh-target>] \
  [--pane <herdr-pane-id>] \
  [--cwd <path>] \
  [--remote-cwd <path>] \
  [--local-dir <path>] \
  [--json]

verde herdr handoff \
  [--workspace <id|index|path|current>] \
  [--all] \
  [--session <session-name>] \
  [--profile <name>|--remote <ssh-target>] \
  [--remote-cwd <path>] \
  [--dry-run] \
  [--json]

verde herdr unlink \
  [--workspace <id|index|path|current>] \
  [--all] \
  [--json]

verde herdr status [--json]

verde herdr profiles list --json
verde herdr profiles add --name <name> --ssh-target <alias> [--session <name>] [--remote-cwd <path>] [--local-dir <path>] [--json]
verde herdr profiles remove <name> [--json]
verde herdr profiles test <name> [--json]
```

Expected behavior:

- `verde herdr open` starts or focuses Verde through the existing daemon/IPC
  path where possible.
- If the target is already linked to a Verde workspace, focus that workspace.
- If the target is unknown, create a Verde workspace shell linked to the Herdr
  target.
- If `--profile` or `--remote` is present, all Herdr operations target the
  remote server. `--profile` resolves the SSH target/session/default paths from
  `verde herdr profiles`; `--remote` remains the raw SSH alias escape hatch.
- `verde herdr handoff` mirrors Verde workspace panes into Herdr for local or
  remote terminal/TUI takeover.
- `verde herdr unlink` removes Verde's durable Herdr mapping so GUI sends and
  terminals fall back to the local Verde workspace. It intentionally does not
  delete the Herdr workspace or close any existing Herdr terminal pane.
- Verde exposes the same local controls in the command palette and workspace
  context menu: handoff to Herdr, focus the linked Herdr terminal, and run
  locally/unlink.
- `verde herdr profiles` stores named SSH aliases and defaults in Verde's Herdr
  data directory, and `open`/`handoff` can consume them with `--profile <name>`.
  It intentionally stores no credentials; SSH config remains the credential
  boundary.
- When a remote profile does not specify a remote cwd, Verde creates and uses a
  per-workspace directory under the remote user's Verde data area:
  `.local/share/verde/herdr-workspaces/<workspace-label>-<workspace-id>`. Users
  can override that with profile/CLI `--remote-cwd`.
- Terminal-backed Verde actions inside a remote-linked workspace launch through
  SSH in the remote cwd by default: new terminal panes, terminal tabs, terminal
  lazy-start/revive, agent TUI panes, Amp shell panes, and managed stack
  processes. Plain terminal panes open a normal remote login shell; they do not
  open the Herdr TUI unless the user explicitly runs Herdr or chooses the Herdr
  terminal action.
- JSON errors should follow the live CLI convention where practical:
  `not_found`, `invalid_target`, `rejected`, `unsupported`.

## Herdr control strategy

Start with Herdr CLI calls because they are stable, scriptable, and match the
plugin surface. Move lower-level operations to the socket API only where the CLI
is too slow or cannot express the needed action.

Useful Herdr operations:

```bash
herdr --session <name>
herdr --remote <ssh-target> --session <name>
herdr session list --json
herdr workspace list
herdr workspace create --cwd <path> --label <label> --no-focus
herdr pane list --workspace <workspace-id>
herdr pane split <pane-id> --direction right --cwd <path>
herdr pane read <pane-id> --source recent-unwrapped --lines 120
herdr pane send-text <pane-id> <text>
herdr pane run <pane-id> <command>
herdr agent start <name> --cwd <path> -- <argv...>
herdr agent wait <target> --status idle --timeout <ms>
```

Remote command execution needs an adapter so the rest of Verde does not care
whether the backing command is local Herdr or `herdr --remote`.

## Herdr-Verde plugin

The plugin is the Herdr-side bridge for "pick this up in Verde".

### Manifest actions

Initial action set:

- `open-in-verde`: open/focus the current Herdr workspace in Verde.
- `open-pane-in-verde`: open/focus the current Herdr pane in Verde.
- `create-verde-layout`: optional later action that asks Verde to create a
  GUI-friendly layout from the current Herdr workspace.

The plugin should read Herdr-injected env/context:

```text
HERDR_BIN_PATH
HERDR_SESSION
HERDR_WORKSPACE_ID
HERDR_TAB_ID
HERDR_PANE_ID
HERDR_PLUGIN_CONTEXT_JSON
```

Then invoke `verde herdr open ...`.

### Plugin config

Use `herdr plugin config-dir <plugin_id>` for user-editable plugin config.
Likely config values:

```toml
verde_bin = "verde"
default_remote = ""
default_remote_cwd = ""
prefer_existing_window = true
```

The current Zig plugin reads env-style config from
`HERDR_PLUGIN_CONFIG_DIR/config.env`: `VERDE_BIN`, `VERDE_REMOTE_PROFILE`,
`VERDE_REMOTE_ALIAS`, `VERDE_REMOTE_CWD`, `VERDE_HERDR_SESSION`,
`VERDE_LOCAL_DIR`, and `VERDE_OPEN_MODE`. Leave `VERDE_REMOTE_CWD` unset to use
Verde's per-workspace remote default; set it only when a user wants all handoffs
from that plugin config to land in an explicit remote path.

### Plugin limits

- The plugin should not duplicate workspace state. Verde owns the durable
  Verde-to-Herdr mapping.
- The plugin should not manage SSH credentials. Use SSH config aliases and
  Herdr's remote attach flow.
- The plugin can be useful without Verde running: it can fail with a clear
  message that tells the user which `verde herdr open ...` command would be
  used.

## Implementation phases

### Phase 1 - Basic Herdr attach pane

Purpose: prove the product flow with minimal architecture.

- Add workspace runtime option: `Herdr local` or `Herdr remote`.
- Current UI implementation exposes this as command-palette/workspace-context
  actions for local Herdr handoff, remote profile handoff, focused Herdr
  terminal pickup, and unlink/back-to-local. A dedicated settings/profile editor
  remains polish.
- Add a settings/profile model for Herdr remote targets using SSH aliases.
  CLI profile storage, `--profile` resolution, and an in-app profile picker for
  handoff are implemented; a full CRUD settings UI remains polish.
- Open a Verde terminal pane that runs:
  - local: `herdr --session verde-<workspace>`
  - remote: `herdr --remote <ssh-target> --session verde-<workspace>`
- Persist the selected runtime and session name on the Verde workspace.
- Show a small runtime indicator in the workspace chrome/sidebar.

Acceptance:

- A Herdr-backed workspace can be started from Verde.
- User can detach/close Verde and reattach directly with Herdr.
- Remote Herdr panes keep running on the remote host after Verde exits.

### Phase 2 - Verde Herdr CLI entrypoint

Purpose: support plugin-driven pickup.

- Add `verde herdr open`.
- Add `verde herdr status`.
- Add `verde herdr handoff` and `verde herdr unlink` for explicit handoff and
  back-to-local runtime control.
- Add profile list/add/remove/test commands if profile storage lands in this
  phase. The basic CLI-backed version is implemented and can drive
  `open`/`handoff` via `--profile`.
- Implement focus/create behavior through the existing daemon IPC path.
- Persist `HerdrWorkspaceLink` when a target is opened.

Acceptance:

- Running `verde herdr open --session <name> --herdr-workspace <id>` focuses or
  creates the linked Verde workspace.
- Re-running the command does not create duplicates.
- Remote targets can be represented even if rich remote control is still
  limited.

### Phase 3 - Herdr-Verde plugin

Purpose: let a user pick up a Herdr session from inside Herdr.

- Create a Herdr plugin directory with `herdr-plugin.toml`.
- Add `open-in-verde` action.
- Add `open-pane-in-verde` action if Herdr context includes pane identity.
- Document local development:
  - `herdr plugin link /path/to/plugin`
  - `herdr plugin action list --plugin <id>`
  - `herdr plugin action invoke <id>`
- Add clear error output when `verde` is missing or the Verde daemon cannot
  start.

Acceptance:

- From a Herdr workspace, invoking `Open in Verde` opens/focuses the matching
  Verde workspace.
- The action works for local Herdr sessions.
- Remote Herdr sessions have a documented path and either work or fail with an
  explicit `--profile`/`--remote` setup message. Current remote plugin actions
  print the local pickup command because they execute on the remote Herdr host.

### Phase 4 - Structured Herdr backend

Purpose: make Verde more than a terminal wrapper for Herdr.

- Add a Herdr backend adapter in Verde for:
  - workspace list/create/focus
  - pane list/split/close/read/send/run
  - agent list/start/read/send/wait
- Map Herdr panes into Verde workspace panes where possible.
- Keep terminal/TUI panes backed by Herdr instead of spawning local child
  processes.
- Add reconnect logic that refreshes Herdr pane/agent state when Verde starts.

Acceptance:

- Verde can show Herdr pane and agent state without requiring the full Herdr TUI
  to be visible in a terminal pane.
- Basic input/output works through Verde controls.
- Herdr remains the source of truth for process lifecycle.

### Phase 5 - Polish and restore behavior

Purpose: make this reliable for daily use.

- Handle missing Herdr binary with clear install guidance.
- Add first-seen remote host/fingerprint language if Verde ever invokes SSH
  directly rather than relying entirely on Herdr.
- Add remote bootstrap checks:
  - Herdr present on remote host
  - remote cwd exists
  - required agent CLIs are on PATH
  - provider credentials exist on the remote host
- Add "Open in Herdr" from Verde for fallback in the other direction. Current
  implementation provides this as local handoff + focused Herdr terminal from
  the command palette/workspace context menu, plus remote profile handoff through
  the in-app profile picker.
- Add session health and reconnect UI.
- Add tests for CLI parsing and workspace mapping.

## UX notes

Workspace runtime selector:

```text
Run with:
  Verde local
  Herdr local
  Herdr remote...
```

Remote profile fields:

```text
Name
SSH target / config alias
Default Herdr session
Default remote path (optional; otherwise Verde uses
`.local/share/verde/herdr-workspaces/<workspace>` on the remote host)
```

Avoid asking users for passwords in the first version. The expected setup is:

```sshconfig
Host workbox
  HostName server.example.com
  User rtg
  Port 22
```

Then Verde stores `workbox`.

## Open questions

- Does Verde need a custom terminal renderer attachment to individual Herdr
  terminals, or is the Herdr CLI/socket read/send path enough for the first
  structured backend?
- Should remote Herdr profiles live only in Verde, or should the first version
  require users to define SSH aliases outside Verde?
- How much of Herdr's workspace layout should Verde mirror versus presenting a
  Verde-native layout linked to the same Herdr panes?
- Should `verde herdr open` support a URI form for link handlers, such as
  `verde://herdr/open?...`, or is CLI invocation enough for the plugin?
- What is the minimum Herdr version required for plugin context and remote
  attach behavior?

## First work slice

1. Inspect Verde's current CLI/IPC startup path and project persistence.
2. Add the `verde herdr open` command as a no-op/status-only prototype that
   parses local and remote targets.
3. Add the Herdr workspace link data structure and persistence location.
4. Implement local Herdr open/focus/create behavior.
5. Create the Herdr plugin skeleton with an `open-in-verde` action.
6. Test:
   - `herdr --session verde-test`
   - `verde herdr open --session verde-test --workspace <id> --json`
   - `herdr plugin link <plugin-dir>`
   - plugin action invokes Verde and focuses the expected workspace.
