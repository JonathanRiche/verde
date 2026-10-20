# Multi-Machine Workspaces

Status: design. Builds on [Remote Runtimes](remote-runtimes.md) and
[Serve, Pair, and Connect](serve-pair-connect.md). Paths are relative to
`packages/`. Code is cited by symbol rather than line number.

## Problem

A paired desktop cannot run a chat on another machine unless that machine
already has a workspace with the **same ID**. `chat.turn.start` sends the local
project's `workspace_id` (`desktop/src/state/chat_controller.zig`). Workspace
IDs are hashes of the local path, or of the creation request key for managed
workspaces (`workspace.create` in `desktop/src/terminal/sessionizer.zig`), so
in practice they never match across machines. The only fix today is
`verde-daemon workspace bind`. When the send fails, the user sees the generic
"Verde could not start this message" error: `chat.turn.start` +
`resource_not_found` classifies as `.unknown`, so the existing
`RemoteWorkspaceBindingMissing` message never shows. Users should never need
the CLI for this; agents may.

## Model

1. **Machines own their work.** Chats, terminals, processes, checkouts and
   workspace settings stay on the machine that has them.
2. **Clients merge; daemons don't sync.** Each client (desktop, phone, web)
   already connects to every paired machine and builds the combined view
   itself. Daemons never talk to each other, and no client writes one
   machine's settings to another.
3. **Repositories match by git identity.** Checkouts are the same repository
   when their normalized `origin` matches. Forks stay separate. Never match by
   name or path.
4. **Chats stay pinned** to the machine they started on (unchanged,
   `ThreadBinding`, `runtime_route` in `desktop/src/state/chat_types.zig`).
5. **Grouping is display only.** A matching checkout on another machine is
   shown, but a chat can only run there after that machine has a workspace with
   the same `workspace_id`. Setting that up is one click (**Use it**, below).

Prior art: T3 Code uses this model on desktop and mobile.

## Cases

| Workspace | Behaviour |
| --- | --- |
| Git repo with an `origin` | Grouped with matching checkouts on other machines. "Run on" lists machines that have the workspace and offers **Use it** on machines with a matching checkout. |
| No git, or no `origin` | Stays on its own machine. It can run elsewhere only after the user picks a folder there. Offer "Initialize git". |
| Several repos, no root repo (e.g. a folder holding two clones) | Treated as "no git" until context folders land (phase 6); then grouped by its primary repository. |
| Context folder | An optional repository with its own identity and its own folder on each machine. If it's missing on the target: **Pick folder · Clone · Run without it**. |

Each machine keeps its own label, repository list and context folders. Clients
show the local machine's settings for a merged row; nothing is copied between
machines except the `workspace_id` that `workspace.attach` reuses.

## Repository identity

- **Source:** `origin` only. `upstream` is ignored, so a fork never groups with
  the repository it was forked from.
- **Read:** the daemon reads `git remote get-url origin` (so `insteadOf`
  rewrites apply) when a workspace is created or bound, and again on
  `workspace.repository.manifest.get`, so `set-url` changes are picked up.
  It stores the raw value in `vcs_identity`.
- **Normalize** (client side, one copy in `client_core/src/shared/repo_identity.zig`):
  - drop the user, port, trailing `/` and `.git`;
  - lowercase the host;
  - treat `git@host:owner/repo`, `ssh://host/owner/repo` and
    `https://host/owner/repo` as equal;
  - lowercase `owner/repo` for `github.com` only; compare it exactly for every
    other host.
- **Version:** the normalized form starts with `v1:`. Changing the rules bumps
  the prefix, so an old and a new client never silently disagree.
- **`group_key`:** the normalized identity of the workspace's `primary`
  repository. Null when it has no `origin`.
- **Known misses:** SSH host aliases from `~/.ssh/config` (`git@github-work:…`)
  don't match. The user can still pick the folder by hand.

When one machine has several workspaces with the same `group_key` (worktrees,
second clones), "Run on" and the setup card list each one with its path.

## What exists vs. what's missing

| Piece | Today | Change |
| --- | --- | --- |
| Repository manifest | `workspace_repositories` and `workspace_repository_bindings` tables (`desktop/src/db/schema.zig`). The `primary` repo is created automatically from `workspaces.path`. Up to `MAX_WORKSPACE_REPOSITORIES` (64) per workspace. | Reuse. |
| `vcs_identity` | Set only by hand (`workspace repository bind --vcs-identity`, `desktop/src/daemon_main.zig`). Validated, never normalized (`desktop/src/daemon/store.zig`). | Daemon reads `origin` as described above and stores the raw value. |
| Normalization | Only `commitWebUrl` exists, for forge links (`desktop/src/daemon/git_changes.zig`). | `client_core/src/shared/repo_identity.zig`, shared by desktop, web and mobile. |
| Remote workspace list | `workspace.list` has `repositories[]` and `vcs_identity`. `core.snapshot` does not (`desktop/src/db/client.zig`). | Add `repositories` to the `core.snapshot` workspace scope and to `core.changes`. |
| `client_core` projection | `Workspace` has no repository fields (`client_core/src/projection.zig`). | Add `repositories[]` and `group_key`. |
| Folder browsing | `workspace.directory.list`: roots from `VERDE_DIRECTORY_ROOTS` plus host defaults, directories only, `repository:read` (`desktop/src/daemon/directory_browser.zig`). No git info. The desktop doesn't call it. The phone does. | Add `git_identity?` to each entry so the client can say "same origin". |
| Binding | `workspace.repository.binding.upsert` trusts the path it's given (`store.zig`). | New `workspace.attach` RPC (below) that validates the folder. |
| Turn errors | Missing workspace and missing binding both return `resource_not_found` ("workspace not found" / "repository binding not found on this runtime", `chatTurnStartResponse` in `sessionizer.zig`). `classifyRpcError` (`desktop/src/runtime/manager.zig`) maps it only for `manifest.get`. The desktop side (`.workspace_binding_missing` → `RemoteWorkspaceBindingMissing` → user message) already exists. | Add error `data: {"resource":"workspace"\|"repository_binding"}` and one `chat.turn.start` branch in `classifyRpcError`. |
| Context folders | Stored as absolute local paths in `<home>/verde.toml` (`desktop/src/workspace/folders.zig`). Not in the manifest. | Move them into the manifest as repositories with `role: context`, each with its own folder on each machine. Turns pass the repository roots from the manifest. |
| Scopes | Repository writes need `repository:write`. The Chat preset (`chat:write` + `repository:read`) does not grant it. | Setup needs a **Full** device, or the owner. State this in the UI. |
| Version skew | — | New capability `workspace.attach.v1`. Without it, clients hide **Use it** / **Set up on…** and show today's error. Without `repositories` in the snapshot, the machine's workspaces show ungrouped. |

### New RPC: `workspace.attach`

Run on the target machine. It's idempotent and does in one call what the CLI's
upsert → bind → default steps do (`handleWorkspaceRepositoryBind` in
`daemon_main.zig`).

```
params: { mutation, workspace_id, label, repository_id, role: primary|context,
          root_path, expect_identity? }
result: { workspace_id, repository_id, root_path, git_identity?, store_revision,
          reused: bool }
errors: not_found (path) · identity_mismatch · path_outside_roots
```

- Checks that `root_path` is a directory inside the same roots
  `workspace.directory.list` allows, using its descriptor-based containment.
- If `root_path` already belongs to a workspace on this machine, it **reuses**
  that workspace: it adds the caller's `workspace_id` as an alias of it and
  returns `reused: true`. Chats sent with either ID land in the same
  workspace. It never creates a second workspace for the same folder.
- Otherwise it creates the workspace with the **caller's** `workspace_id`.
- Reads the folder's `origin`. If `expect_identity` was sent and the
  normalized values differ, or the folder has no `origin`, it refuses with
  `identity_mismatch`. The client always sends `expect_identity` when the
  source workspace has one.
- Needs the `repository:write` scope. Add it to the scope table
  (`headless/src/access_protocol.zig`). Not on the desktop web relay
  allowlist (`allowedMethod` in `desktop/src/web_runtime.zig`); the relay
  rejects repository writes on purpose (see Web).

## UI

### Desktop

- **Sidebar** (`desktop/src/ui/sidebar.zig`):
  - Workspaces from all machines are merged by `group_key`. A workspace on
    several machines is one row with a badge ("Also on Lightning"). A workspace
    that exists only on a remote machine shows that machine's badge.
  - Chats from a remote machine get a machine icon, taken from
    `ChatThread.selectedRuntimeRoute()`.
  - A **machine filter** next to the existing all/one workspace scope. The
    default is "All machines". It only filters; it never changes where
    anything runs.
  - Remote workspace lists come from a per-machine `core.snapshot` cache in
    `state/runtime_connections_controller.zig`.
- **Run on** (`syncPaletteRuntimePicker` in `state.zig`). Today it lists every
  connection with no filtering. Change it to list:
  1. Machines that have the workspace: a workspace with the same
     `workspace_id` (directly or as an alias).
  2. Machines with a matching checkout (same `group_key`): "Lightning · same
     origin · **Use it**". One click calls `workspace.attach` with
     `expect_identity`, then selects the machine.
  3. "Set up on Zod…" entries for the rest. They open the setup card.

  The choice locks after the first message: "Chats stay on the machine they
  started on." This needs the per-machine snapshot cache (phase 3). Today only
  the expanded Settings profile is probed for its manifest
  (`runtime_connections_controller.zig`).
- **Setup card** in the transcript, modelled on
  `renderProviderFailureActionCard` (`ui/chat_panel.zig`):
  > **Lightning doesn't have "verde" yet.** Chats here will run on Lightning.
  > `~/development/verde_workspace/verde` · same origin · **Use it**
  > **Pick folder…** · **Clone** (later) · **Cancel**

  It opens from:
  - a "Set up on…" entry in Run on;
  - `commitAcceptanceDispatch` `.rejected` with
    `RemoteWorkspaceBindingMissing` (`chat_controller.zig`), in place of
    `appendInitialSendFailure`.

  **Pick folder** reuses `state/folder_browser.zig` and `ui/folder_browser.zig`
  with a remote backend that calls `workspace.directory.list`. A new picker
  purpose is routed in `pollPicker` (`state.zig`). Confirming calls
  `workspace.attach`. The draft is kept, and the user sends again.
- **New workspace:** pick the machine first, then **Open folder** (browsed on
  that machine) or **Clone**.

### Mobile (iOS, Android)

- **Home** is merged by default. Every host session is already live
  (`HostsModel.swift`, `HostsModel.kt`). `BrowseModel` takes the rows from
  every host and calls `vc_workspace_groups`, a pure C export modelled on
  `vc_push_open` (`client_core/src/push.zig`).
- **Filter:** the host menu (`HostMenu`, `BrowseScreens.swift`) becomes the
  machine filter. "All machines" is the default. Picking one host gives
  today's single-machine view.
- **Routes carry a host ID.** Today `BrowseRoute` (`BrowseScreens.swift`) and
  the Android routes (`VerdeApp.kt`) have none. Screens look up
  `hosts.session(route.host)`. Opening a notification goes straight to the chat
  without switching the active host (`VerdeApp.swift`, `PushActions.kt`).
- **New chat:** pick the workspace group, then the machine (same three tiers as
  desktop Run on). Missing machines get a **Set up** sheet that reuses the
  `AddWorkspaceScreen` folder browser (`ManageScreens.swift`, `.kt`) and then
  calls `workspace.attach`.

### Web (`verde-web`)

- It's served by one machine and talks to one daemon over its own origin
  (`web_app/web/src/lib/live.ts`). It shows that machine's workspaces. No
  change now. The relay keeps rejecting repository writes
  (`web_runtime.zig` test: `workspace.repository.binding.upsert` is not
  allowed), so `workspace.attach` stays off it.
- Later: add `core.snapshot` to the relay allowlist, poll each connection, and
  group with the same `client_core/src/shared` code (`web_app/build.zig`
  already imports it). Allowing `workspace.attach` there is a separate,
  explicit decision to relax the relay policy.

## Phases

1. **Errors and logging.** Done.
   - Daemon: route not-found on `chat.turn.start` carries
     `data: {"resource":"workspace"|"repository_binding"}`
     (`routeNotFoundResponseAlloc` in `sessionizer.zig`).
   - Manager: `classifyRpcError` maps a tagged `chat.turn.start`
     `resource_not_found` to `workspace_binding_missing`; untagged ones (an
     expired attachment id) stay generic. The existing
     `RemoteWorkspaceBindingMissing` message then shows on its own.
   - `logRemoteTurnStartFailure` (`chat_controller.zig`) logs the error name,
     remote code and resource with `runtime_log.diagnostic`.
   - Plain sends retry `RuntimeRpcBusy` for up to 15 s through the same poll
     loop as attachment uploads, so a send no longer fails when it collides
     with a heartbeat.
2. **Identity.** Read `origin` in the daemon; add `repo_identity.zig` to
   `client_core/src/shared`; add `repositories` to `core.snapshot`, the
   projection, and `git_identity` in `workspace.directory.list`.
3. **Desktop setup.** `workspace.attach` (with aliasing, scopes and the
   `workspace.attach.v1` capability); the per-machine snapshot cache; the
   remote folder browser backend; the setup card; **Use it** and "Set up on…"
   entries in Run on.
4. **Desktop merge.** Merged sidebar with badges and the machine filter.
5. **Mobile.** `vc_workspace_groups`, host IDs in routes, merged Home and
   filter, the machine step in new chat, the setup sheet.
6. **Context folders.** Migrate `verde.toml` folders into the manifest as
   `role: context`, build turn roots from the manifest, and add "Run without
   it" to the setup card.
7. **Later.** Clone on a remote machine; other machines in the web client.

## Non-goals

- Syncing chats, files, terminals or workspace settings between machines.
- Moving a started chat to another machine.
- Matching folders by name or path.
- Grouping forks with their upstream.
