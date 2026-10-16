# Multi-Machine Workspaces

Status: design. Builds on [Remote Runtimes](remote-runtimes.md) and
[Serve, Pair, and Connect](serve-pair-connect.md). Paths are relative to
`packages/`.

## Problem

A paired desktop cannot run a chat on another machine unless that machine
already has a workspace with the **same ID**. `chat.turn.start` sends the local
`project.id` (`desktop/src/state/chat_controller.zig:3652`). Workspace IDs are
hashes of the local path (`sessionizer.zig:15512`), so in practice they never
match. The only fix today is `verde-daemon workspace bind`, and when the send
fails the user sees a generic "could not start" error. Users should never need
the CLI for this; agents may.

## Model

1. **Machines own their work.** Chats, terminals, processes and checkouts stay
   on the machine that runs them.
2. **Clients merge; daemons don't sync.** Each client (desktop, phone, web)
   already connects to every paired machine and builds the combined view
   itself. Daemons never talk to each other.
3. **Repositories match by git identity.** Checkouts are the same repository
   when their normalized remote matches (`upstream`, else `origin`). Forks stay
   separate. Never match by name or path.
4. **Chats stay pinned** to the machine they started on (unchanged,
   `ThreadBinding`, `chat_types.zig:363`).

Prior art: T3 Code uses this model on desktop and mobile.

## Cases

| Workspace | Behaviour |
| --- | --- |
| Git repo with a remote | Grouped with matching checkouts on other machines. "Run on" lists every machine that has it. |
| No git, or no remote | Stays on its own machine. It can run elsewhere only after the user picks a folder there. Offer "Initialize git". |
| Context folder | An optional repository with its own identity and its own folder on each machine. If it's missing on the target: **Pick folder · Clone · Run without it**. |

Only workspace **settings** are shared between clients: label, repository list,
identities, context folders. Chats and files are not.

## What exists vs. what's missing

| Piece | Today | Change |
| --- | --- | --- |
| Repository manifest | `workspace_repositories` and `_bindings` tables (`desktop/src/db/schema.zig:571`). The `primary` repo is created automatically from `workspaces.path`. Up to 64 repos per workspace. | Reuse. |
| `vcs_identity` | Set only by hand (`daemon_main.zig:1422`). Validated, never normalized (`store.zig:5109`). | Daemon reads `upstream`/`origin` when a workspace is created or bound, and stores the raw value. |
| Normalization | Only `commitWebUrl` exists, for forge links (`git_changes.zig:2313`). | `client_core/src/shared/repo_identity.zig`: drop user/port/`.git`, lowercase the host, treat ssh and https forms as equal. One copy, shared by desktop, web and mobile. |
| Remote workspace list | `workspace.list` has `repositories[]` and `vcs_identity`. `core.snapshot` does not (`db/client.zig:187`). | Add `repositories` to the `core.snapshot` workspace scope and to `core.changes`. |
| `client_core` projection | `Workspace` has no repository fields (`client_core/src/projection.zig:39`). | Add `repositories[]` and `group_key`. |
| Folder browsing | `workspace.directory.list`: restricted roots, directories only, `repository:read` (`daemon/directory_browser.zig`). No git info. The desktop doesn't call it. The phone does. | Add `git_identity?` to each entry so the client can say "same origin". |
| Binding | `workspace.repository.binding.upsert` trusts the path it's given (`store.zig:3106`). | New `workspace.attach` RPC (below) that validates the folder. |
| Turn errors | Missing workspace, repo or binding all return `resource_not_found` (`sessionizer.zig:7493`). The manager maps this only for `manifest.get` (`runtime/manager.zig:2503`). | Add error `data: {"resource":"workspace"\|"repository_binding"}` and map it for `chat.turn.start`. |
| Context folders | Stored as absolute local paths in `<home>/verde.toml` (`desktop/src/workspace/folders.zig`). Not in the manifest. | Move them into the manifest as repositories with `role: context`, each with its own folder on each machine. Turns pass the repository roots from the manifest. |
| Scopes | Repository writes need `repository:write`. The Chat preset does not grant it. | Setup needs a **Full** device, or the owner. State this in the UI. |

### New RPC: `workspace.attach`

Run on the target machine. It's idempotent and does in one call what the CLI's
upsert → bind → default steps do (`daemon_main.zig:760-830`).

```
params: { mutation, workspace_id, label, repository_id, role: primary|context,
          root_path, expect_identity? }
result: { workspace_id, repository_id, root_path, git_identity?, store_revision }
errors: not_found (path) · identity_mismatch · path_outside_roots
```

- Creates the workspace if it's missing, using the **caller's** `workspace_id`.
- Checks that `root_path` is a directory inside the allowed roots.
- Reads the folder's git remote. If `expect_identity` was sent and doesn't
  match, it refuses with `identity_mismatch`.
- Needs the `repository:write` scope. Add it to the scope table
  (`headless/src/access_protocol.zig:368`) and to the desktop web relay
  allowlist (`desktop/src/web_runtime.zig:112`).

## UI

### Desktop

- **Sidebar** (`desktop/src/ui/sidebar.zig`):
  - Workspaces from all machines are merged by `group_key`. A workspace on
    several machines is one row with a badge ("Also on Lightning"). A workspace
    that exists only on a remote machine shows that machine's badge.
  - Chats from a remote machine get a machine icon, taken from
    `thread.selectedRuntimeRoute()`.
  - A **machine filter** next to the existing all/one workspace scope
    (`state.zig:4858`). The default is "All machines". It only filters; it never
    changes where anything runs.
  - Remote workspace lists come from a per-machine `core.snapshot` cache in
    `state/runtime_connections_controller.zig`.
- **Run on** (`syncPaletteRuntimePicker`, `state.zig:14531`). Today it lists
  every connection with no filtering. Change it to list:
  1. Machines that have the workspace. "Has it" means a binding, or a
     repository with the same `group_key`.
  2. "Set up on Zod…" entries for machines that don't.

  The choice locks after the first message: "Chats stay on the machine they
  started on." This needs a manifest cache per machine and per workspace. Today
  only the expanded Settings profile is probed
  (`runtime_connections_controller.zig:1495`).
- **Setup card** in the transcript, modelled on
  `renderProviderFailureActionCard` (`ui/chat_panel.zig:6967`):
  > **Lightning doesn't have "verde" yet.** Chats here will run on Lightning.
  > `~/development/verde_workspace/verde` · same origin · **Use it**
  > **Pick folder…** · **Clone** (later) · **Cancel**

  It opens from:
  - a "Set up on…" entry in Run on;
  - `commitAcceptanceDispatch` `.rejected` with
    `RemoteWorkspaceBindingMissing` (`chat_controller.zig:~3908`), in place of
    `appendInitialSendFailure`.

  **Pick folder** reuses `state/folder_browser.zig` and `ui/folder_browser.zig`
  with a remote backend that calls `workspace.directory.list`. A new picker
  purpose is routed in `pollPicker` (`state.zig:16565`). Confirming calls
  `workspace.attach`. The draft is kept, and the user sends again.
- **New workspace:** pick the machine first, then **Open folder** (browsed on
  that machine) or **Clone**.

### Mobile (iOS, Android)

- **Home** is merged by default. Every host session is already live
  (`HostsModel.swift:280`, `HostsModel.kt:155`). `BrowseModel` takes the rows
  from every host and calls `vc_workspace_groups`, a pure C export modelled on
  `vc_push_open` (`client_core/src/push.zig:76`).
- **Filter:** the host menu (`HostMenu`, `BrowseScreens.swift:211`) becomes the
  machine filter. "All machines" is the default. Picking one host gives
  today's single-machine view.
- **Routes carry a host ID.** Today `BrowseRoute` (`BrowseScreens.swift:4`) and
  the Android routes (`VerdeApp.kt:29`) have none. Screens look up
  `hosts.session(route.host)`. Opening a notification goes straight to the chat
  without switching the active host (`VerdeApp.swift:237`,
  `PushActions.kt:110`).
- **New chat:** pick the workspace group, then the machine (only machines that
  have it). Missing machines get a **Set up** sheet that reuses the
  `AddWorkspaceScreen` folder browser (`ManageScreens.swift:125`, `.kt:289`)
  and then calls `workspace.attach`.
- **Machines** move to Settings → Machines (today's hosts screen).

### Web (`verde-web`)

- It's served by one machine and talks to one daemon over its own origin
  (`web_app/web/src/lib/live.ts:78`). It shows that machine's workspaces. No
  change now.
- Later: add `core.snapshot` and `workspace.attach` to the relay allowlist
  (`desktop/src/web_runtime.zig:111`), poll each connection, and group with the
  same `client_core/src/shared` code. `web_app/build.zig:18` already imports it.

## Phases

1. **Errors and logging.**
   - Daemon: error `data` on `chat.turn.start` not-found
     (`sessionizer.zig:7493`, `:8910`).
   - Manager: map it for `chat.turn.start` and add `remote_error_code` to
     `RpcResponse` (`manager.zig:266`, `:2503`, `:2537`). Update the test at
     `:3580`.
   - Log `@errorName` and the remote error code with `runtime_log.diagnostic`
     at `chat_controller.zig:3169`, `:3715`, `:3799`.
   - Retry `RuntimeRpcBusy` for plain sends (`:3715`). Today a send fails if it
     collides with a heartbeat.
2. **Identity.** Read the git remote in the daemon; add `repo_identity.zig`
   to `client_core/src/shared`; add `repositories` to `core.snapshot`, the
   projection, and `git_identity` in `workspace.directory.list`.
3. **Desktop setup.** Add `workspace.attach` plus scopes; the remote folder
   browser backend; the setup card; "Set up on…" entries in Run on.
4. **Desktop merge.** Per-machine snapshot cache, `group_key`-filtered Run on,
   merged sidebar with badges and filter.
5. **Mobile.** `vc_workspace_groups`, host IDs in routes, merged Home and
   filter, the machine step in new chat, the setup sheet.
6. **Context folders.** Migrate `verde.toml` folders into the manifest as
   `role: context`, build turn roots from the manifest, and add "Run without
   it" to the setup card.
7. **Later.** Clone on a remote machine; other machines in the web client.

## Non-goals

- Syncing chats, files or terminals between machines.
- Moving a started chat to another machine.
- Matching folders by name or path.
