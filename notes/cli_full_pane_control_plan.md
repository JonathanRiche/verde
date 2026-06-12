# CLI Full Pane Control Plan (handoff)

Goal: the `verde` CLI must allow full control of every pane kind (chat,
terminal, **browser**) in any workspace through the daemon, so an agent
running inside a Verde terminal pane can e.g. open a browser at a URL in its
own workspace with one command — without yanking the human user's focus.

This doc is a self-contained implementation handoff. Product decisions below
are settled (confirmed by Jonathan, June 2026); don't re-litigate them.

## Settled product decisions

1. **Opening a browser in a workspace must NOT switch the user's selected
   workspace and must NOT steal focus.** The pane opens in the target
   workspace's layout; the user sees it when they next visit (Alt+N).
2. **Top-level sugar exists:** `verde open <url>` (see below).
3. **`palette.run` ships now** (Tier 2 includes it): the CLI can invoke any
   command-palette entry by stable id.
4. **`browser.eval` stays as-is.** No new guardrails.
5. **Browser stays a singleton runtime** (one webview engine/surface). We
   document move semantics instead of building per-workspace instances:
   *"the browser lives in one workspace at a time; opening it elsewhere moves
   it there."* Do not attempt multi-instance browsers in this work.

## Current state (verified June 2026)

- IPC server: `packages/desktop/src/ipc/server.zig` (~1700 lines). Method
  registry is the string table in the `capabilities` response (~line 332).
  Existing groups: `pane.*` (focus/split/resize/minimize/maximize/restore/
  close), `chat.*` (draft.set/append, send, followup, stop, approve, status,
  transcript), `terminal.*` (write/tail/screen), `process.*`,
  `browser.*` (open/close/toggle/back/forward/reload/focus/blur/toolbarHit/
  eval/postJson/inspector.*, overlay.*).
- CLI: `packages/desktop/src/cli.zig` (`live browser` group exists, ~line
  538/1009/1162). Static completion tree: `packages/desktop/src/cli_spec.zig`.
- **`browser.open` takes no URL** — it only ensures visibility
  (`state.toggleBrowser()` path). **There is no `browser.navigate` method.**
  Navigate logic lives in `state.navigateBrowserFromAddress`
  (`state.zig` ~7968): trims, `normalizeBrowserUrl`, `controller.navigate`,
  `setAddress`. Reuse that pipeline, minus the address-input coupling.
- `state.toggleBrowser` (`state.zig` ~7222) targets `selected_project_index`,
  calls `workspace_layout.ensureBrowserPane`, and **focus-steals**
  (`browser_address_focused = true`, focuses the pane). The IPC path needs a
  new non-focus-stealing entry point — do not reuse toggleBrowser directly.
- Browser singleton state: `state.browser_state` (one controller, one
  `current_url`, one native surface). Surface suspension flags already exist
  (`browser_surface_suspended_for_layout`,
  `browser_surface_suspended_for_palette_overlay`) — when the browser pane is
  not in the selected workspace, the surface must be/stay suspended; check how
  layout suspension is driven before wiring open-in-background.
- Read-side queries already resolve project targets (`resolveProjectIndex` in
  `ipc/server.zig`); **most mutations ignore project params** and act on the
  selected workspace.
- Every Verde terminal pane exports identity env vars
  (`terminal/terminal.zig` ~3142): `VERDE_SESSION_ID`, `VERDE_WORKSPACE_ID`,
  `VERDE_WORKSPACE_PATH`, `VERDE_DOCK_ID`, `VERDE_PANE_ID`. `verde notify`
  already consumes them (`cli.zig` ~574–586).
- Command palette: `packages/desktop/src/ui/command_palette.zig`. The
  `STATIC_COMMANDS` table has stable ids (`thread.new`,
  `pane.split_chat_right`, `workspace.rename`, `app.settings`, …), per-command
  `enabled(state)` predicates, and `run(state)` fns. Built for exactly this
  reuse.

## Tier 1 — agent browser flow

### New IPC methods (`ipc/server.zig`)

- `browser.open { url?: string, project?: selector }`
  - Resolve target project (default: selected). Ensure a browser pane in
    **that** project's `workspace_layout` (`ensureBrowserPane`).
  - If `url` present: normalize + navigate (reuse the
    `navigateBrowserFromAddress` pipeline).
  - **Never** change `selected_project_index`; **never** set
    `browser_address_focused`; **never** move keyboard focus away from the
    user's focused pane in the *selected* workspace. Setting the *target*
    (non-selected) layout's `focused_pane_id` to the browser pane is fine.
  - If the browser pane currently lives in a different workspace, it moves
    (singleton semantics). Return `{ accepted, moved_from_workspace? }`.
  - If the target IS the selected workspace, show the surface as today (still
    without focusing the URL bar).
- `browser.navigate { url: string }` — normalize + navigate the singleton.
  Error `rejected` when the browser runtime is not open/visible anywhere.
- `browser.status` — `{ visible, suspended, url, status, workspace_index,
  workspace_id, pane_id }` so agents can assert outcomes.
- Add all new method names to the `capabilities` string table.

### CLI (`cli.zig` + `cli_spec.zig` completions)

- `verde live browser open --url <u> [--project <sel>] --json`
- `verde live browser navigate --url <u> --json`
- `verde live browser status --json`
- **`--project self`**: resolved **client-side** in the CLI (the daemon cannot
  see the caller's env): read `VERDE_WORKSPACE_ID` (fall back to
  `VERDE_WORKSPACE_PATH`) and send it as the project selector. Error exit 2
  with a clear message if `self` is requested outside a Verde pane.
- **Default for `browser open`**: `self` when `VERDE_WORKSPACE_ID` is set,
  else `current`.

### Top-level sugar

`verde open <url>` ≡ `verde live browser open --url <url>` (with the
self-default above). Add to root help + completions. Keep flags minimal:
`--project`, `--json`.

## Tier 2 — consistency + palette.run

1. **Project-selector audit for mutations.** Every mutating method should
   accept the same project selector the reads use (index / id / path /
   `current`), resolved via the existing `resolveProjectIndex`. Pane-id-based
   methods (`pane.*`, `chat.*` by pane, `terminal.*`) should look up the pane
   within the resolved project rather than assuming the selected one. Audit
   each handler in `ipc/server.zig`; fix the ones that silently assume
   `selected_project_index`. CLI flags already pass `--project` for reads —
   extend the write commands to forward it.
2. **`palette.list`** — returns `[{ id, title, section, enabled }]` from
   `STATIC_COMMANDS` (call each command's `enabled(state)`).
3. **`palette.run { command: id }`** — find by id, check `enabled`, call
   `run(state)`. Errors: `not_found` (unknown id), `rejected` (disabled).
   Note: palette commands act on the **selected** workspace by design (they
   mirror what the user could do); document that in `--help`. Export whatever
   is needed from `ui/command_palette.zig` (e.g. a
   `pub fn findCommand(id) ?*const Command` + `pub fn commandIds()`); don't
   duplicate the table.
   - CLI: `verde live palette list --json`, `verde live palette run --command
     <id> --json`.
4. **Missing controls** (new IPC + CLI):
   - `pane.move { pane, direction }` → `workspace_panes.movePaneInDirection`
     equivalents (see `main.zig` `handleKeyboardAction` for the call shapes).
   - `workspace.select { project }`, `workspace.create { path }`,
     `workspace.rename { project, label }`, `workspace.archive { project }`
     → `selected_project_index` + `ensureCurrentProjectWorkspace`,
     `importProjectFromInput`-style path add, `beginProjectRename` is
     modal-interactive so prefer a direct `renameProject(index, label)` state
     method, `archiveProjectAtIndex`.

## Conventions to follow

- Exit codes (existing contract): 0 ok, 1 failed after parse, 2 bad args,
  3 live server not ready, 4 offline target not found. Application errors
  return `ok: false` JSON with `error.code` in
  `not_found | invalid_target | rejected | unsupported | method_not_found`.
- Completions are static by design — update `cli_spec.zig` for every new
  command/flag; `verde completion bash|zsh|fish` must reflect the new tree.
- README has a CLI section; AGENTS.md "CLI And Live-Control Testing" lists
  read-only checks — add `browser status` and `palette list` there.

## Verification (from a NON-Verde shell, or accept daemon-kill risk)

Never run `mise run dev`, `zig build run`, or `pkill verde` from inside a
Verde pane (the agent would kill its own daemon). Build with
`zig build --release=safe -Dbrowser-backend=native_webview` from the repo
root; the human relaunches the app.

Smoke sequence once the app is running:

```bash
verde live status --json                                  # ok: true
verde live browser status --json                          # visible: false
verde live browser open --url https://example.com --project current --json
verde live browser status --json                          # url matches, workspace correct
verde live browser open --url https://ziglang.org --project 2 --json
verde live browser status --json                          # moved workspaces, user focus unchanged
verde live palette list --json
verde live palette run --command pane.split_terminal_down --json
verde open https://example.com                            # sugar path
```

Manual checks: while the human watches workspace A, run `browser open
--project <B>` — the user's view must not change; switching to B shows the
browser at the URL. `verde completion fish | rg browser` shows the new tree.

## Acceptance criteria

- [ ] Agent inside a Verde terminal can `verde open <url>` and the browser
      appears in *its* workspace without disturbing the user's current view.
- [ ] `browser.navigate`, `browser.status`, URL+project on `browser.open`,
      all in `capabilities` and completions.
- [ ] `--project self` works and fails loudly outside Verde panes.
- [ ] `palette.list` / `palette.run` cover every `STATIC_COMMANDS` id.
- [ ] Mutating pane/chat/terminal methods honor `--project`.
- [ ] `pane.move` + `workspace.select/create/rename/archive` exist.
- [ ] `zig build --release=safe -Dbrowser-backend=native_webview` and
      `zig build test` pass; README/AGENTS.md CLI sections updated.
