# CLI pane-control review fixes (handoff)

Scope: the **uncommitted working-tree changes** implementing
`notes/cli_full_pane_control_plan.md` (CLI/IPC browser open/navigate/status,
palette.list/run, workspace.select/create/rename/archive, pane.move). The
implementation builds clean and is structurally right; a review found the
issues below. Fix them **in the same working tree before committing**. Line
numbers refer to the current uncommitted state.

Build/verify: `zig build --release=safe -Dbrowser-backend=native_webview` from
the repo root, then `zig build test`. Never run `mise run dev`, `zig build run`,
or `pkill verde` from inside a Verde pane (kills the daemon you're running in);
the human relaunches the app for live smoke tests.

---

## 1. Cross-project pane commands mutate the wrong workspace (severity: high)

`packages/desktop/src/ipc/server.zig` — `paneCommandResponse` (~line 649
region). `resolvePaneTarget` honors `--project/--workspace` and can return a
`target.project_index` that is **not** the selected workspace (see
`resolveProjectIndex`, ~line 1111). `pane.move` correctly calls
`state.moveWorkspacePaneInDirection(target.project_index, …)`, but the seven
sibling commands still call `*CurrentProject*` state methods:

- `focus` / `split` → `splitCurrentProjectWorkspacePane…`
- `resize` → `resizeCurrentProjectWorkspaceSplit`
- `minimize` → `minimizeCurrentProjectWorkspacePane`
- `maximize`, `restore`, `close` → likewise

Pane ids are per-layout counters, so ids collide across projects:
`verde live pane close --project 2 --pane 3` validates pane 3 in project 2,
then closes an unrelated pane 3 **in the user's selected workspace**.

**Fix at the right depth:** add project-aware variants in `state.zig` (e.g.
`minimizeWorkspacePane(project_index, pane_id)` etc., mirroring what
`moveWorkspacePaneInDirection` does — operate on
`self.projects.items[project_index].workspace_layout`, only touch shared focus
state like `terminal_focused` when `project_index == selected_project_index`),
keep the `*CurrentProject*` names as thin wrappers calling the new ones with
`selected_project_index`, and switch `paneCommandResponse` to the
project-aware versions using `target.project_index`. While there, check
`chatCommandResponse` and `terminalCommandResponse` for the same pattern —
the plan's Tier-2 audit requires every pane-id-based mutation to honor
`target.project_index`. Also verify the response body after a cross-project
mutation reports the **target** project's panes, not the selected one's.

## 2. Url-less `browser.open` reopen paths are broken (severity: high)

`packages/desktop/src/state.zig` — `openBrowserInWorkspace` (~line 7438), the
branch:

```zig
if (url) |target_url| {
    try self.navigateBrowserToUrl(target_url);
} else if (!self.browser_state.controller.runtimeInitialized()) {
    try self.showBrowserRuntimeForLiveOpen();
}
```

Compare with `toggleBrowser` (~line 7330): it computed
`restore_last_url = !runtimeInitialized() and current_url != null` and
**navigated** to the saved URL in that case, and called `controller.show()`
**unconditionally** otherwise. The new code drops both behaviors:

- (a) Runtime initialized but hidden (user/agent ran `hideBrowser` via
  `browser.toggle`; `controller.hide()` was called, runtime stays
  initialized): the else-if is skipped entirely → `controls_visible = true`
  but **`show()` is never called** → browser pane renders with an
  invisible/black surface. Note `restoreBrowserSurfaceForRenderedLayout`
  doesn't save you: `hideBrowser` clears `browser_surface_suspended_for_layout`
  so it early-returns.
- (b) Runtime shut down (`closeBrowser` → `controller.shutdown()`) with a
  saved `browser_state.current_url`: new code calls `show()` only, losing the
  restore-last-URL navigation → reopens blank instead of the last page.

**Fix:** replicate toggleBrowser's decision tree for the url-less case:

```zig
if (url) |target_url| {
    try self.navigateBrowserToUrl(target_url);
} else if (!self.browser_state.controller.runtimeInitialized() and
    self.browser_state.current_url != null)
{
    try self.navigateBrowserToUrl(self.browser_state.current_url.?);
} else {
    try self.showBrowserRuntimeForLiveOpen(); // safe when already shown
}
```

(Confirm `controller.show()` is idempotent when already visible — toggleBrowser
called it unconditionally, so it should be.) Then re-check the
target != selected ordering: `noteBrowserPaneNotRendered()` must still run
after, so the surface ends suspended when the pane is in a background
workspace.

## 3. Rejected `workspace.archive` still switches the user's workspace (severity: high)

`packages/desktop/src/state.zig` — `archiveProjectAtIndex` (~line 4649):

```zig
self.selected_project_index = index;   // <-- happens BEFORE the guard
self.archiveSelectedProject();         // busy-guard may early-return
```

`archiveSelectedProject` refuses when any thread has a pending send — but the
selection was already moved, so `verde live workspace archive --project 2`
against a busy workspace returns `rejected` **and silently switches the user's
view to workspace 2**. This violates the settled "never pull the user's
workspace" decision in `notes/cli_full_pane_control_plan.md`.

**Fix:** hoist the busy check so nothing mutates on rejection — e.g. refactor
`archiveSelectedProject`'s pending-send loop into
`fn projectHasPendingSend(self, index) bool`, check it first in
`archiveProjectAtIndex`/`archiveProjectAtIndexResult`, and only then change
selection + archive. `archiveProjectAtIndexResult` can then return false
without side effects, and the IPC handler's `rejected` response becomes
truthful. Also reconsider whether archive-via-IPC should change selection at
all when archiving a non-selected workspace (it must end with a valid
`selected_project_index`, but it shouldn't *target-switch* first — mirror
whatever `archiveSelectedProject` does for index fixup after removal).

## 4. `verde open` parses option values as the URL (severity: medium)

`packages/desktop/src/cli.zig` — `handleOpen` (~line 220):

```zig
const url = args.optionValue(argv, "--url") orelse args.positional(argv, 0) orelse ...
```

`cli_args.positional` only skips `--`-prefixed tokens — it **counts option
values as positionals**. `verde open --project self https://example.com`
returns `"self"` as the URL → navigates to `https://self`. Every other handler
uses `trailingFreeArg(argv, N)` (cli.zig ~2160), which skips values of flags
listed in `optionConsumesValue`.

**Fix:** use `trailingFreeArg(argv, 0)` instead of `positional(argv, 0)`.
Add a smoke assertion in your verification: `verde open --project self
https://example.com` must send `url=https://example.com`.

## 5. `--label` missing from `optionConsumesValue` (severity: low)

`packages/desktop/src/cli.zig` — `optionConsumesValue` (~line 2183). The diff
added `--direction --path --url --target --script --json-payload --mode
--command` but not `--label` (used by `workspace rename` and registered in
completions/cli_spec). Any `trailingFreeArg`/free-arg parse with `--label`
present treats the label value as a positional. Add `--label` to the list.
Audit the list against `cli_spec.all_flags` while there (e.g. `--title`,
`--body`, `--status` from notify) so the two stay in sync — consider a test
that asserts every value-taking flag in `cli_spec.zig` is covered.

## 6. Duplicate state methods (severity: cleanup, do if cheap)

- `state.zig navigateBrowserToUrl` (~7490) duplicates
  `navigateBrowserFromAddress` (~8230): make the address-field path call
  `navigateBrowserToUrl` and keep only the address-input handling around it.
  Note the new method calls `setCurrentUrl` eagerly while the address path
  waits for load events — pick one behavior (event-driven is the existing
  contract; consider dropping the eager `setCurrentUrl`).
- `createProjectFromPath` (~4017) vs `importProjectFromInput`: extract the
  shared trim→resolve→dedupe→addProject→select→notice core; the import-modal
  wrapper adds only modal-state cleanup.
- `renameProjectAtIndex` vs `renameSelectedProject`: one should call the other.
- `selectProjectAtIndex` (new) vs `main.zig selectWorkspaceBySidebarOrdinal`
  (~1913): update main.zig to call the state method (it additionally closes
  `workspace_header_open_menu_open` / `sidebar_context_menu_open` — fold those
  into `selectProjectAtIndex`; closing menus on select is correct for the IPC
  path too).

## 7. `browser.status` scans all projects 4× per request (severity: cleanup)

`ipc/server.zig writeBrowserStatus` (~276) calls `browserWorkspaceIndex()`
twice (workspace_index, workspace_id) and `browserWorkspacePaneId()` rescans
via `browserWorkspaceIndex` again. Compute once: have a single state helper
return `?struct { index: usize, pane_id: WorkspacePaneId }` and emit all three
fields from it. Status is the designated agent polling endpoint.

---

## Acceptance

- [ ] `verde live pane close|minimize|maximize|restore|split|resize|focus
      --project <other> --pane <id>` mutate the **target** workspace (verify
      with colliding pane ids in two workspaces), and the JSON response
      reflects the target project.
- [ ] `verde live browser open` (no url) after `browser toggle` (hide) shows a
      working surface; after `browser close`, it restores the last URL.
- [ ] `verde live workspace archive --project <busy>` returns `rejected` and
      the selected workspace is **unchanged**.
- [ ] `verde open --project self https://example.com` navigates to the URL
      regardless of flag order.
- [ ] `--label` consumes its value in free-arg parsing.
- [ ] `zig build --release=safe -Dbrowser-backend=native_webview` and
      `zig build test` pass; rerun the smoke sequence in
      `notes/cli_full_pane_control_plan.md`.
