# Verde Mobile — Orchestrator Task List

This file is the work queue for building the mobile apps. The design lives
in [`mobile-app-plan.md`](mobile-app-plan.md); read it before dispatching or
doing any task. Every task below is sized for one agent working in one
session.

---

## Part A — Orchestrator protocol

### A1. Loop

1. Read the **Status board** (Part B).
2. A task is **ready** when its status is `todo` and every task in its
   `depends` line is `done`.
3. Dispatch ready tasks, one agent per task. Tasks can run in parallel only
   if their `touches` areas don't overlap (see A4).
4. When an agent finishes, check its report against the task's **Done when**
   list. Set the status to `done (<commit sha>)`, or back to `todo` with a
   note, or to `blocked: <reason>`.
5. `human` tasks go to the owner. Tell them exactly what to do and what to
   send back. Don't spin on them; keep dispatching other lanes.
6. Only the orchestrator edits the Status board. Agents report; they don't
   edit this file.

### A2. How to dispatch

- **Linux tasks:** open a Verde chat in workspace `baaa819e66d8f3be`
  (`/home/rtg/development/verde`) with `open_chat` and send the task using
  the brief template in A3. Pass the orchestrator's `parent_thread_id` so
  completion and blocked status come back automatically. Subagents with
  worktree isolation work too.
- **Mac tasks** (`machine: mac`): the agent still runs on Linux. It edits
  files in the Linux checkout, commits, and pushes. It then drives the Mac
  over SSH:
  ```sh
  ssh mac 'cd ~/development/verde && git pull --ff-only && <build/test command>'
  ```
  `mac` is the SSH alias created in H-01. Never hand-edit files on the Mac;
  everything goes through git. Swift sources and the XcodeGen `project.yml`
  are plain text, so they can be edited on Linux.
- **Phone tasks** (`machine: phone`):
  - Android: the agent uses `adb` from Linux, either over USB or wireless
    adb across Tailscale.
  - iOS devices: driven through the Mac (`xcrun devicectl`).
  - Anything that needs a hand on a phone, like scanning a QR code or
    judging how the app feels, has a `human-verify` step. The owner does
    that step and reports back.

### A3. Agent brief template

```
You are doing task <ID> from docs/mobile-app-tasks.md in /home/rtg/development/verde.
Read: AGENTS.md (and its scoped rules for the areas you touch), docs/mobile-app-plan.md,
and the full text of task <ID>. Do only that task.
Work in a git worktree (git worktree add ../verde-wt/<ID> master), rebase onto master
before committing, and commit directly to master with a message starting "mobile(<ID>):".
Run the task's verification commands and include their results in your report.
If you are blocked on a decision or on a human step, call report_chat_blocked with the
exact question and stop. Report: commit sha, files changed, verification output, follow-ups.
```

### A4. Rules that apply to every task

- **The working tree is shared.** Other people's and agents' work lives in
  `/home/rtg/development/verde`, and there can be large uncommitted diffs.
  Always use a worktree. Never revert, stash or commit changes you didn't
  make.
- **Branching:** commit straight to master; no feature branches. Keep one
  commit per task where possible, and never force-push.
- **Serialization hotspots.** Tasks that touch the same file must not run
  at the same time:
  - `packages/headless/src/access_protocol.zig`
  - `packages/web_app/src/http.zig`
  - `packages/desktop/src/terminal/sessionizer.zig`
  - `packages/desktop/src/daemon/store.zig`
- **Builds.** Follow the root `AGENTS.md`:
  - Lease `build` for full Zig builds, and `port:<n>` for any listener.
  - Never run bare `zig build`. Lower-level targets take
    `--release=safe -Dbrowser-backend=native_webview`.
  - Never restart Verde, and never run `mise run dev`, `mise run dev-term`
    or `zig build run` from inside Verde.
- **Verification commands** used throughout this file:
  - `ZB="zig build --release=safe -Dbrowser-backend=native_webview"`, then
    `$ZB headless-test`, `$ZB runtime-test`, `$ZB server-test`,
    `$ZB daemon-test`.
  - `mise run web-app-test`, `mise run web-app`.
  - `mise run dev-build` (desktop UI changes).
  - Mobile tasks add their own commands (D-01, I-01, K-01).
- **Tests** use temporary state, loopback fixtures and finite deadlines. No
  live providers, no user daemon, no network services.
- **Secrets** never go into the repo, logs or reports. That covers signing
  keys, keystore passwords, APNs `.p8` keys, FCM service accounts and pair
  codes. Keep them in environment variables or files outside the repo, and
  have the owner supply them (human tasks).
- **Docs:** any task that adds a package also adds its `AGENTS.md` and a
  link in the root `AGENTS.md` scoped-rules list.

### A5. Status values

`todo` · `in_progress (<agent/thread>)` · `review` · `done (<sha>)` ·
`blocked: <reason>` · `human` (waiting on the owner)

---

## Part B — Status board

| ID | Title | Lane | Machine | Depends | Status |
|---|---|---|---|---|---|
| H-01 | Mac SSH access + alias | human | mac | — | done |
| H-02 | Xcode 16.2 + Apple ID on the Mac | human | mac | H-01 | done (team sign-in after H-04) |
| H-03 | Google Play developer account | human | — | — | human |
| H-04 | Apple Developer Program | human | — | — | human |
| H-05 | Firebase project + FCM/APNs keys | human | — | H-03, H-04 | human |
| H-06 | Tailscale on both phones | human | phone | — | human |
| H-07 | Android phone dev setup (adb) | human | phone | — | human |
| H-08 | Choose pairing permission presets | human | — | — | done (owner: Full default) |
| A-01 | Confine `/api/file` + `/api/preview` | host | linux | — | done (363bece0) |
| A-02 | Paired-device allowlist parity + new scopes | host | linux | — | done (a570cce2) |
| A-03 | Confined directory-list RPC | host | linux | A-02 | in_progress (astra cli-thread-1790362331784-8004a4c995475ec2) |
| A-04 | Device self-service RPCs | host | linux | A-02 | done (42a3582b) |
| A-05 | Idempotent pair exchange | host | linux | — | done (a36897f0) |
| A-06 | Terminal QR + App Link pair URL | host | linux | — | done (b0f6e50b; phone-camera scan pending human-verify) |
| A-07 | Desktop "Pair a phone" + Paired devices UI | host | linux | A-04, A-06 | done (b7499bdf, b5a0d579; human-verify pending) |
| A-08 | Web Settings paired-devices list | host | linux | A-04 | done (f6ff1cb9) |
| A-09 | Pairing presets + access-mode cap | host | linux | A-02, H-08 | done (c844e093) |
| A-10 | `mobile.min_client` + capability flags | host | linux | — | done (f8aa0db8) |
| A-11 | Delta change feed on the gateway | host | linux | A-10 | done (1b1a7d34) |
| A-12 | Push crypto module (seal/open) | host | linux | — | done (7f5c621f) |
| A-13 | Push outbox + `device.push.*` RPCs | host | linux | A-02, A-12 | done (8827ee2a) |
| A-14 | Attention events → outbox | host | linux | A-13 | done (8832302d) |
| A-15 | Harden served-file open (TOCTOU, special files, leak, logs) | host | linux | A-01 | done (310be446) |
| A-16 | `workspace.list` exposes repository binding roots | host | linux | A-01, A-02 | done (fb84ca8c) |
| A-17 | Daemon-native workspace close | host | linux | A-02 | todo |
| A-18 | Daemon-native subagent open | host | linux | A-02 | todo |
| W-01 | App Link / universal link files + pair landing page | website | linux | H-03, H-04 | todo |
| C-01 | Spike: APNs reachability from Workers | cloud | linux | — | done (research; recorded in plan §8, see C-02) |
| C-02 | Push relay Worker | cloud | linux | C-01, A-12 | human (code done in verde-cloud c16126bd; waiting on owner approval to deploy the throwaway APNs probe) |
| C-03 | Demo runtime for store review | cloud | linux | A-09 | todo |
| K-01 | Core skeleton + Android toolchain proof | core | linux | — | done (951a5a5a) |
| K-02 | iOS xcframework toolchain proof | core | mac | K-01, H-01, H-02 | done (e2f73abb) |
| K-03 | Core API spec (events, effects, queries) | core | linux | K-01 | done (a5a81401; reviewed) |
| K-04 | Extract shared remote-client modules from desktop | core | linux | K-01 | done (e1111a8c) |
| K-05 | Split `headless/client.zig` codec from I/O | core | linux | K-01 | done (b12e4c17) |
| K-06 | Sans-IO host engine + C ABI | core | linux | K-03, K-04, K-05 | done (e3e60c35, e4a0e6ab) |
| K-07 | Auth in core | core | linux | K-06, A-05 | done (ffb390ec) |
| K-08 | RPC client + target pinning | core | linux | K-06 | done (fd4cfc22) |
| K-09 | Sync + projection | core | linux | K-08 | done (dfbd6d6f) |
| K-10 | Chat engine | core | linux | K-09 | in_progress (astra cli-thread-1790362328697-dc5576a2ceb2b5f4) |
| K-11 | Markdown AST / highlight spans / diff parse exports | core | linux | K-06 | done (93000154, c37e038c) |
| K-12 | Terminal handle + PTY pump | core | linux | K-06 | in_progress (astra cli-thread-1790362330364-2f0c30d725920233) |
| K-13 | Allowlist coverage test | core | linux | K-10, A-02 | todo |
| K-14 | Contract suite vs real gateway + daemon | core | linux | K-10 | todo |
| K-15 | Kotlin/Swift model codegen from Zig types | core | linux | K-06 | done (fdb77f3d) |
| K-16 | Delta-mode sync | core | linux | K-09, A-11 | todo |
| K-17 | Attention state machine + push decrypt | core | linux | K-09, A-12 | todo |
| D-01 | Android project scaffold | android | linux | K-01 | done (ee3c19df; on-device version display pending human-verify) |
| D-02 | Core bridge + effect executor | android | linux | D-01, K-06, K-15 | done (0f7fb9c6) |
| D-03 | Pairing flow | android | linux+phone | D-02, K-07, A-06, H-06, H-07 | in_progress (astra cli-thread-1790362326049-d70c7a394ff4ae6b) |
| D-04 | Hosts list + switcher + sign out | android | linux | D-03, A-04 | todo |
| D-05 | Home + Workspaces + lifecycle | android | linux+phone | D-04, K-09 | todo |
| D-06 | Transcript screen | android | linux | D-05, K-10, K-11 | todo |
| D-07 | Diff card | android | linux | D-06 | todo |
| D-08 | Composer + pickers + attachments + follow-ups | android | linux | D-06 | todo |
| D-09 | Approvals card | android | linux | D-06 | todo |
| D-10 | History, new chat, workspace management | android | linux | D-05, A-03 | todo |
| D-11 | Native terminal view | android | linux+phone | D-05, K-12 | todo |
| D-12 | File viewer | android | linux | D-06, A-01 | todo |
| D-13 | Theme + reduced motion | android | linux | D-05 | todo |
| D-14 | Push + actionable notifications | android | linux+phone | D-09, K-17, A-14, C-02, H-05 | todo |
| D-15 | App lock + secure screen | android | linux | D-05 | todo |
| D-16 | Maestro flows + UI tests | android | linux+phone | D-08, D-09 | todo |
| D-17 | Release build + Play internal track | android | linux | D-16, H-03 | todo |
| I-01 | iOS project scaffold (XcodeGen) | ios | mac | K-02 | done (bdfcfd3e; unsigned simulator only until H-04) |
| I-02 | Core bridge + effect executor | ios | mac | I-01, K-06, K-15 | done (f389ab00, b6dc5f03, 69c813af, 10b4f4cd) |
| I-03 | Pairing flow | ios | mac+phone | I-02, K-07, A-06 | done (abe0dafd..ce41f917; phone verify pending H-06, universal links pending H-04) |
| I-04 | Hosts + Home + Workspaces + lifecycle | ios | mac | I-03, D-05 | todo |
| I-05 | Transcript + diff + approvals | ios | mac | I-04, D-06, D-07, D-09 | todo |
| I-06 | Composer + pickers + attachments + follow-ups | ios | mac | I-05, D-08 | todo |
| I-07 | History, new chat, workspace management | ios | mac | I-04, D-10 | todo |
| I-08 | Native terminal view | ios | mac+phone | I-04, D-11 | todo |
| I-09 | File viewer, theme, app lock | ios | mac | I-05, D-12, D-13, D-15 | todo |
| I-10 | Push + NSE + actionable notifications | ios | mac+phone | I-05, K-17, C-02, H-05 | todo |
| I-11 | XCUITest / Maestro flows | ios | mac | I-06 | todo |
| I-12 | TestFlight pipeline (GitHub Actions) | ios | ci | I-11, H-04 | todo |
| R-01 | Store listings, privacy / data-safety forms | release | human | D-17, I-12, C-03 | todo |

---

## Part C — Tasks

### Human setup

#### H-01 · Mac SSH access + alias
- **machine:** mac · **depends:** —
- **Status: done (2026-09-25).** `ssh -o BatchMode=yes mac 'uname -sm'` prints
  `Darwin arm64`. The alias `mac` is defined in the operator's own
  `~/.ssh/config`; the host name and user stay out of the repo. It uses
  plain macOS Remote Login over the tailnet.
  Tailscale SSH is **not** an option: the Mac runs the GUI Tailscale app, which
  can't act as a Tailscale SSH server.
- The Ghostty terminfo is installed on the Mac (`infocmp -x xterm-ghostty | ssh mac 'tic -x -'`),
  so interactive Verde panes work. For scripted commands, prefix with
  `TERM=xterm-256color GIT_PAGER=cat`.

#### H-02 · Xcode 16.2 + Apple ID on the Mac
- **machine:** mac · **depends:** H-01
- **Inventory (2026-09-25):**
  - Mac mini M2, **macOS 14.6 Sonoma**, about 65 GiB free.
  - brew, mise, Zig 0.16.0 and xcodegen 2.46.0 are installed.
  - The repo is cloned at `~/development/verde` and is up to date with
    `origin/master`.
  - Only the Command Line Tools are installed; there is no Xcode.
- **Decision: the Mac stays on macOS 14.**
  - Sonoma can run at most Xcode 16.2 (iOS 18.2 SDK). That covers all
    development: simulator builds, the Zig xcframework, and development or
    ad-hoc installs on the iPhone.
  - App Store Connect uploads (including TestFlight) need Xcode 26+. Those
    run on GitHub Actions macOS runners instead (I-12); they are free
    because the repo is public.
  - Swift code must therefore compile under both SDKs (18.2 locally, 26 in
    CI).
  - Homebrew treats macOS 14 as Tier 3 (no bottles), so installs are slower
    but still work.
- **Status (2026-09-25): Xcode done; team sign-in waits for H-04.**
  - Xcode 16.2 (16C5032a) is at `/Applications/Xcode-16.2.0.app` and
    selected with `xcode-select`. The license is accepted and first launch
    has run.
  - The iPhoneOS 18.2 SDK compiles a SwiftUI test app for arm64. The iOS
    18.3.1 simulator runtime was downloaded with
    `xcodebuild -downloadPlatform iOS` (log at `~/xcode-ios-runtime.log`).
  - Getting Xcode onto macOS 14: Homebrew's `xcodes` formula refuses to
    install on macOS older than Sequoia, but the prebuilt binary (`xcodes.zip`
    from the GitHub release) runs on macOS 13+, so it went into
    `/opt/homebrew/bin/xcodes`. Run `xcodes signout` on the Mac to clear any
    cached Apple ID login.
  - `~/.zshenv` now puts `~/.local/bin`, the mise shims and `/opt/homebrew/bin`
    on the PATH, so non-interactive `ssh mac '…'` commands find `mise`,
    `zig`, `xcodegen` and `brew` (backup at `~/.zshenv.bak-verde`).
  - Still to do: step 3 below, after H-04.
- **Do (owner):**
  1. Download Xcode 16.2 from developer.apple.com/download/all (Apple ID
     sign-in), or install it with `xcodes install 16.2`. Move it to
     `/Applications/Xcode.app`.
  2. Run `sudo xcodebuild -license accept` and
     `sudo xcode-select -s /Applications/Xcode.app`. Install the iOS 18.2
     platform if Xcode prompts for it.
  3. Sign in to the Apple ID / team in Xcode → Settings → Accounts (after
     H-04). Register the iPhone's UDID as a development device.
- **Early check (agent, as soon as Xcode is in):** install a hello-world app
  on the iPhone. If the phone runs iOS 26 and Xcode 16.2 refuses to deploy
  to it (missing device support), fall back to upgrading macOS to 26/27.
  `softwareupdate` offers macOS 27; it needs the admin password and a
  restart.
- **Done when:** `ssh mac 'xcodebuild -version && xcodegen --version && cd ~/development/verde && mise exec -- zig version'` succeeds, and a signed build runs on the iPhone.

#### H-03 · Google Play developer account
- **Do:** register the account (one-time fee). Reserve the application ID
  `dev.verdeai.app` (change it here if you prefer another one).
- **Done when:** the Play Console app exists; the ID is recorded here.

#### H-04 · Apple Developer Program
- **Do:** enrol (annual fee). Create the App ID `dev.verdeai.app` with the
  capabilities Push Notifications, Associated Domains and App Groups (used
  by the NSE).
- **Done when:** the Team ID is recorded here, and the Mac's Xcode shows the
  team.

#### H-05 · Firebase project + push keys
- **depends:** H-03, H-04
- **Do:**
  1. Create a Firebase project, and inside it an Android app with ID
     `dev.verdeai.app`.
  2. Download `google-services.json` and keep it **outside** the repo; the
     build reads its path from an environment variable.
  3. Create a service-account key for FCM HTTP v1.
  4. Create an APNs Auth Key (`.p8`) in the Apple portal and note its Key
     ID and the Team ID. C-01 decided iOS goes **direct to APNs** from the
     relay, so the key becomes a Worker secret (C-02) and is **not**
     uploaded to Firebase. Firebase is needed for the Android app and the
     FCM service account only.
- **Done when:** the files are stored where C-02/D-14 expect them (paths
  given by those tasks) and none of them is in git.

#### H-06 · Tailscale on both phones
- **Done when:** both phones are on the tailnet and can open
  `https://<host>.ts.net` (the web app) in a browser.

#### H-07 · Android phone dev setup
- **Do:** turn on Developer options → USB debugging (or Wireless debugging
  over the tailnet). Accept this machine's key.
- **Done when:** `adb devices` lists the phone.

#### H-08 · Choose pairing permission presets
- **Decided (2026-09-25):** three presets.
  - **Full** (default): all scopes, including `terminal:write`,
    `process:*` and `device:write`; no access-mode cap.
  - **Chat**: read everything, chat and approve, no terminal write or
    processes; turns capped at approval-required.
  - **Monitor**: read-only plus push.
- Over-cap requests are clamped to the cap, with a notice in the turn. This
  was proposed and not objected to; confirm with the owner if A-09 needs to
  reject instead.

### Host lane (verde repo)

#### A-01 · Confine `/api/file` + `/api/preview`
- **touches:** `packages/web_app/src/http.zig` (+ a new helper module if
  cleaner)
- **Why:** `validServedFilePath` accepts any absolute path, for example
  `~/.ssh/id_ed25519`, for any caller with `repository:read`.
- **Do:**
  - Resolve the path with realpath, following symlinks. Allow it only if it
    lies inside a registered workspace/repository root, taken from daemon
    `workspace.list` / repository bindings and cached with a short TTL.
  - Keep the existing extension and size checks.
  - Return 403 `path_outside_workspace`.
  - Update the "Security contract" section of `packages/web_app/AGENTS.md`.
- **Done when:**
  - Tests cover: inside root OK; `..` rejected; a symlink escaping the root
    rejected; a sibling-prefix root (`/a/b` vs `/a/bc`) rejected; outside
    rejected.
  - `mise run web-app-test` and `mise run web-app` pass.
- **Done (363bece0).** A read-only audit (Codex, 2026-09-25) cleared the
  stable-path checks, cache ownership and authorization, and raised the
  follow-ups now tracked as A-15 (open-time hardening) and A-16 (daemon
  binding roots).

#### A-02 · Paired-device allowlist parity + new scopes
- **touches:** `packages/headless/src/access_protocol.zig`, the gateway auth
  wiring, the `verde-server` pair/device CLI help
- **Do:**
  - Add scopes `process:read`, `process:write` and `device:write`.
    Existing grants keep their stored scopes, and new scopes are **not** in
    the default grant.
  - Map these in `requiredScopeMaskForRpc`, following plan P2:
    - `workspace.create`, `workspace.rename`, `workspace.close` →
      `repository:write`
    - `chat.open_subagent`, `provider.threads.list` → `chat:read`
    - `provider.title.generate` → `chat:write`
    - `terminal.open`, `terminal.tail`, `terminal.screen` →
      `terminal:read`/`terminal:write` as appropriate
    - `terminal.write`, `terminal.key` → `terminal:write`
    - `process.list`, `process.definitions` → `process:read`
    - `process.start`, `process.restart`, `process.stop` → `process:write`
    - `daemon.client.register` → `runtime:read`
  - Make sure each method is actually dispatched for paired clients (check
    the gateway's paired-client path and `paired_clients.zig`).
- **Done when:**
  - Tests cover each new mapping plus the reachability test.
  - `$ZB headless-test`, `mise run web-app-test` and `$ZB server-test`
    pass.
- **Done (a570cce2).** New opt-in scopes `process:read`, `process:write`, `device:write` (not in the default grant). Mapped: `provider.threads.list` (`chat:read`), `provider.title.generate` (`chat:write`), `process.list`/`process.definitions` (`process:read`), `process.start`/`restart`/`stop` (`process:write`; the gateway binds `client_id` to the paired session), `daemon.client.register` (`runtime:read`). **Deferred** because their handlers exist only in the desktop GUI (`ipc/server.zig`, plan rule 3): `workspace.create`/`rename` (mobile uses `workspace.upsert`), `workspace.close` (`workspace.upsert` with `archived:true` covers metadata only; full close is A-17), `chat.open_subagent` (A-18), and `terminal.open`/`tail`/`screen`/`write`/`key` (mobile uses `session.create`/`tail`/`screen`/`write`, with keys encoded in the core). `headless-test`, `web-app-test` and `server-test` pass; a daemon dispatch test proves each mapped method has a handler.

#### A-03 · Confined directory-list RPC
- **depends:** A-02 · **touches:** the daemon dispatch and the gateway
  `directory_browser.zig`
- **Do:** add a daemon RPC `workspace.directory.list {path}` with scope
  `repository:read`. Confine it to allowed roots: the home directory,
  existing workspace parents, and configured roots, mirroring
  `web.directory.list` policy. Directories only; no file contents. The web
  gateway's `web.directory.list` may delegate to it.
- **Done when:** tests cover confinement and listing; `$ZB headless-test`
  and `mise run web-app-test` pass.

#### A-04 · Device self-service RPCs
- **depends:** A-02
- **Do:**
  - `device.self.get` (scope `device:read`) returns this device's label,
    scopes, created and last-seen times.
  - `device.self.revoke` lets a device sign itself out. It clears the
    device's tokens and closes its sockets.
  - `device.list` / `device.revoke` for **owner** callers only (the web
    owner session and the desktop), for the A-07/A-08 UIs.
- **Done when:** tests cover self-revoke invalidating the next call, and a
  paired device being unable to list or revoke other devices.
  `$ZB headless-test` and `mise run web-app-test` pass.
- **Done (42a3582b).** `device.self.get` and `device.self.revoke` are bound to the authenticated device, and any caller-supplied device ID is ignored. Self-revoke needs only `device:read`, so devices with the default grant can sign themselves out. It invalidates the device's tokens and tickets, closes its socket, and clears its push data through A-13's revoke path. `device.list` and `device.revoke` are for owner callers only, on both HTTP and WebSocket. `headless-test`, `web-app-test` and `daemon-test` pass. The running daemon and gateway need a relaunch to pick this up.

#### A-05 · Idempotent pair exchange
- **touches:** `access_protocol.zig`, the daemon grant consume path, the
  gateway `/auth/pair/exchange`
- **Do:** accept an optional `client_nonce` (32 hex characters). A repeat
  exchange with the same grant and nonce inside the grant TTL returns the
  **same** device and credential instead of failing. A different nonce
  still fails. Store only a hash of the nonce.
- **Done when:** tests cover a lost-response retry succeeding, a
  different-nonce replay failing, and a retry after the TTL failing.
  `docs/serve-pair-connect.md` is updated. `$ZB headless-test` and
  `mise run web-app-test` pass.
- **Done (a36897f0).** In `daemon/access_store.zig`, a retried exchange with the same grant and `client_nonce` returns the same device. Only a hash of the nonce is stored; the retry credential is derived from the presented grant secret plus the nonce, so it survives a daemon restart without storing a recoverable credential. Retries stop at the grant's original expiry or when the device is revoked. `access.pair.idempotent.v1` is advertised by the daemon and in the gateway pairing descriptor. `headless-test` and `web-app-test` pass, and the focused access-store tests pass 7/7. A running runtime needs a relaunch to pick this up.

#### A-06 · Terminal QR + App Link pair URL
- **touches:** `packages/server/src/main.zig` (`printPairGrant`), a new small
  QR encoder module (pure Zig with tests; or vendor a vetted MIT/BSD
  encoder)
- **Do:**
  - `verde-server pair create` prints a UTF-8 half-block QR code of the
    pair URL on a TTY. `--no-qr` turns it off; it is automatically off when
    output isn't a TTY or when `--json` is used.
  - Also print the App Link form
    `https://verdeai.dev/pair?host=…&grant_id=…#code=…`. The code stays in
    the fragment.
  - Put the QR encoder somewhere the desktop can reuse it (A-07).
- **Done when:**
  - The QR encoder's test vectors decode correctly (compare against known
    outputs).
  - `$ZB server-test` passes.
  - Manual check: the phone camera scans the printed QR code (human-verify
    once apps exist; for now any QR scanner app shows the URL).
- **Done (b0f6e50b).** Encoder in `packages/headless/src/qr.zig` (exported from headless `root.zig` for A-07); `verde-server pair create` prints the half-block QR plus the App Link, suppressed by `--no-qr`, `--json` or a non-TTY. 684 reference comparisons match; ZBar decodes the rendered terminal QR to the exact App Link. Still open: a physical phone-camera scan (owner).

#### A-07 · Desktop "Pair a phone" + Paired devices UI
- **depends:** A-04, A-06 · **touches:**
  `packages/desktop/src/ui/settings_modal.zig`, the desktop state, the
  daemon pair create path
- **Do:**
  - Settings gets a "Pair a phone" button. It creates a grant (preset
    picker once A-09 lands) and shows the QR code (rendered from the A-06
    encoder), the App Link, the expiry countdown and "copy link".
  - Add a "Paired devices" list: label, source, last seen, scopes, Revoke.
  - Read `packages/desktop/AGENTS.md` first.
- **Done when:** `mise run dev-build` passes. The owner relaunches and
  checks that the QR code shows and revoke works (human-verify).
- **Done (b7499bdf, b5a0d579).** Desktop **Settings → Connections → Pair a phone** shows a QR code and link with a countdown and an explicit Copy link button. A preset picker offers Full (the default), Chat and Monitor, and requests send only `preset`. The picker locks while a link is shown, so the QR always matches the chosen preset. The Paired devices list shows each device's preset and access cap ("Custom / legacy" and "No cap" when empty) and can revoke with confirmation. `dev-build` passes and the focused tests pass 8/8. The owner still needs to check it visually and with a real device.

#### A-08 · Web Settings paired-devices list
- **depends:** A-04 · **touches:** `packages/web_app/web/src/ui/Overlays.tsx`
  (Settings), `lib/store.ts`
- **Do:** owner-session-only list with Revoke. Hidden for paired-device
  sessions.
- **Done when:** `mise run web-app-types`, `bun test` in `packages/web_app`
  and `mise run web-app` pass.
- **Done (f6ff1cb9).** The gateway exposes no session role, so Settings calls `device.list` when it opens. On success it shows the list with Revoke and refetches after each revoke. A `forbidden` rejection (a paired-device session) hides the section. Any other error shows "Couldn't load devices" inline with Retry. The preset is shown when present. Hiding is presentation only; the gateway enforces owner-only access. `web-app-types`, `bun test` (247 passed) and `web-app` pass.

#### A-09 · Pairing presets + access-mode cap
- **depends:** A-02, H-08
- **Do:** implement the preset list decided in H-08:
  - `verde-server pair create --preset <name>`, the desktop dialog option,
    and the grant record storing the preset's scopes.
  - Add an optional per-device `max_access_mode`. `chat.turn.start` and
    `chat.shell.run` from that device are rejected, or clamped (as H-08
    decides), when they ask for more.
  - Show the preset in the device lists.
- **Done when:** tests cover each preset's scopes and the cap being
  enforced. `$ZB headless-test`, `$ZB server-test` and
  `mise run web-app-test` pass.
- **Done (c844e093).** Three presets: Full (the default), Chat and Monitor, listed in `access_protocol.PAIRING_PRESETS`. Pass `"preset":"<name>"` to `daemon.access.pairing.create` and omit `scopes`. Each device's cap is stored. The gateway lowers over-cap requests to the cap and adds a notice to the transcript. Running a supervised shell needs confirmation. Create, exchange, list and self responses carry nullable `preset` and `max_access_mode`. `headless-test`, `server-test`, `daemon-test` and `web-app-test` pass.

#### A-10 · `mobile.min_client` + capability flags
- **Do:** `core.capabilities` / `core.status` advertise `mobile.min_client`
  (an integer protocol revision for the mobile core), and the new
  capability names as they land (`core.changes.delta.v1`,
  `device.push.v1`, `workspace.directory.v1`, `access.pair.idempotent.v1`).
  Keep them in `RUNTIME_CAPABILITY_NAMES`.
- **Done when:** tests pass; `$ZB headless-test` passes.
- **Done (f8aa0db8).** `MOBILE_MIN_CLIENT = 1` in `protocol.zig`;
  `core.status` / `core.capabilities` carry `"mobile":{"min_client":1}`
  (older hosts decode as 0 = not advertised). The four future names live in
  `PENDING_RUNTIME_CAPABILITY_NAMES` and are not advertised; each later
  task moves its constant into the advertised list in the same commit as
  the feature. Notes: A-05 should also add `access.pair.idempotent.v1` to
  the gateway's hard-coded pairing descriptor in `http.zig`; A-11 must
  decide whether the gateway adds `core.changes.delta.v1` itself (the
  feature is gateway-side but the list comes from the daemon).

#### A-11 · Delta change feed on the gateway
- **depends:** A-10 · **touches:** `packages/web_app/src/http.zig`
  (`serveWebSocket`, `pollChanges`)
- **Do:**
  - Clients opt in with a WS request `core.changes.mode {mode:"delta",
    cursor?}` right after `core.hello`.
  - In delta mode:
    - forward `core.changes` entries only;
    - resume from the client's cursor;
    - send no automatic `core.snapshot` after changes;
    - send one snapshot on `expired` or when the `instance_nonce` changes.
  - Default mode is unchanged for the web app.
- **Done when:** gateway tests cover delta mode and resume-from-cursor, and
  confirm that legacy mode behaves exactly as before.
  `mise run web-app-test` and `mise run web-app` pass.
- **Done (1b1a7d34).** The gateway adds `core.changes.delta.v1` to the `core.status` and `core.capabilities` it forwards, including hello's status envelope; the daemon does not advertise this gateway-only feature. Clients opt in with a targeted `core.changes.mode` and resume from an explicit cursor or the initial snapshot cursor. Stale polls are discarded. Delta mode sends a recovery snapshot on `expired` or an `instance_nonce` change and closes if recovery fails. Legacy mode is unchanged. The loopback regression is `packages/web_app/tests/delta_feed.py`. `web-app-test`, `web-app` and `headless-test` pass. WebSocket RPC stays sequential, so interactive and parked calls use `/api/rpc` (K-08).

#### A-12 · Push crypto module
- **touches:** new `packages/headless/src/push_seal.zig` (shared by the
  daemon and the core)
- **Do:**
  - Sealed box: ephemeral X25519 → HKDF-SHA256 (info
    `"verde-push-v1"`) → ChaCha20-Poly1305, all from `std.crypto`.
  - API: `seal(recipient_pub, plaintext) → envelope` and
    `open(recipient_secret, envelope) → plaintext`.
  - The envelope is versioned and base64url. Maximum plaintext is 3 KiB
    (FCM/APNs payload limits).
- **Done when:** tests cover round-trip, tampering rejected, wrong key
  rejected, size limit, and fixed test vectors (so the Kotlin/Swift sides
  can't drift, even though they call this same code).
  `$ZB headless-test` passes.
- **Done (7f5c621f).** `packages/headless/src/push_seal.zig`: envelope =
  version `0x01` ‖ ephemeral pub (32) ‖ ciphertext ‖ tag (16), base64url
  unpadded; HKDF-SHA256 salt = ephemeral pub ‖ recipient pub, info
  `verde-push-v1`, output 32-byte key + 12-byte nonce; AAD = the 33-byte
  header. Fixed vector uses the RFC 7748 §6.1 keys. Note: a full 3 KiB
  plaintext seals to a 4162-char envelope, above the 4096-byte FCM/APNs
  payload limits — A-13 caps the plaintext (see A-13).

#### A-13 · Push outbox + `device.push.*` RPCs
- **Decision (orchestrator):** `push.relay_url` is the relay's https base URL, and the daemon appends `/v1/send`. The default stays empty until C-02 deploys the relay. With no URL set, registrations and outbox rows are still stored, the sender stays idle, and `device.push.test` returns `relay_not_configured`. C-02 sets the production default.
- **depends:** A-02, A-12 · **touches:** `packages/desktop/src/daemon/store.zig`,
  the daemon dispatch, a new daemon push module
- **Do:**
  - `device.push.register {platform, send_token, public_key}`,
    `device.push.unregister` and `device.push.test` (scope
    `device:write`). Stored per device and cleared when the device is
    revoked.
  - Wire format for `public_key`: base64url (unpadded) of the raw 32-byte
    X25519 public key, matching the envelope encoding. Validate it at
    registration by running `push_seal.seal` once (it rejects low-order
    keys) and return `invalid_public_key` on failure.
  - A durable outbox table: `(device_id, kind, dedupe_key, sealed_payload,
    attempts, next_attempt_at)`.
  - Payload budget: the envelope for a 3 KiB plaintext is 4162 characters,
    over the 4096-byte FCM/APNs limits once wrapped in JSON. Cap the sealed
    plaintext at **2560 bytes** (truncate `snippet`, then `title`, before
    sealing) so the relay's JSON body stays under 4 KB with room for the
    placeholder alert and `collapse_id`.
  - A sender loop posts `{send_token, ciphertext, collapse_id}` to the relay
    URL (config `push.relay_url`, default the production relay) with
    exponential backoff. It drops entries after N attempts and on relay 410
    ("token gone").
  - Never log payloads or send tokens.
- **Done when:** tests use a loopback fake relay and cover delivery, retry,
  dedupe, revoke clearing registrations, and 410 handling.
  `$ZB daemon-test` and `$ZB headless-test` pass.
- **Done (8827ee2a).** Push registrations and a durable outbox live in `daemon/push.zig` and `store.zig`, and revoking a device clears its registrations. The access tables' column limit is raised to 2047, with a migration for existing databases. `device.push.v1` is advertised. `push.relay_url` works as decided above; `DEFAULT_RELAY_URL` is empty until C-02. Nothing logs payloads, send tokens or relay URLs. `daemon-test` and `headless-test` pass on `780a4557`, and the daemon suite no longer hits the layout crash.

#### A-14 · Attention events → outbox
- **depends:** A-13
- **Do:** enqueue for every push-registered device on these events:
  - a turn reaching completed, failed or aborted;
  - an approval becoming pending;
  - `chat.tasks.blocked` (input needed).

  The payload is `{runtime_id, workspace_id, thread_id, turn_id, kind,
  title, snippet≤200 chars}`. The dedupe key is `turn_id:kind`. Skip
  devices that were active on the WS within the last N seconds (they get
  in-app notices).
- **Done when:** tests drive a fake turn through each state and assert the
  outbox rows. `$ZB daemon-test` passes.
- **Done (8832302d).** All five attention events (completed, failed, aborted, approval pending, `chat.tasks.blocked`) write sealed outbox rows with dedupe key `turn_id:kind`. Snippets are capped at 200 codepoints, within the 2560-byte plaintext limit. Devices whose `last_used_at_ms` is within `ACTIVE_DEVICE_WINDOW_MS` (30 s) are skipped; this is a proxy for WS activity, so a quiet long-lived socket counts as inactive. Exact gateway WS activity is a follow-up. Changes are in `daemon/push.zig` and `sessionizer.zig`. `daemon-test` passes. Delivery still needs C-02's relay URL.

#### A-15 · Harden served-file open (TOCTOU, special files, leak, logs)
- **depends:** A-01 · **touches:** `packages/web_app/src/served_files.zig`,
  `packages/web_app/src/http.zig` (`handleWorkspaceFile` only),
  `packages/web_app/src/office_preview.zig`
- **Why (audit of 363bece0):**
  1. High: confinement checks a pathname, then the read (and LibreOffice's
     own reopen for `/api/preview`) follows the pathname again. A symlink
     swapped in between — on the file or any ancestor — escapes the root,
     and the extension check still sees the approved name.
  2. Medium: FIFOs and other special files pass confinement; an open on a
     FIFO with no writer blocks a gateway connection slot indefinitely.
  3. Low: an in-root symlink whose outside target is missing yields 404
     while an existing target yields 403, so escaping links can probe
     outside existence. Escaping directory symlinks let callers probe
     names under the target.
  4. Low: `office_preview.zig` error branches log the resolved path and raw
     converter stderr.
- **Do:**
  - Open through the root, not the pathname: hold the confined root as a
    directory descriptor and open the relative remainder with
    `openat2(RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS)` on Linux (in-root
    symlinks stay allowed; escapes fail at the kernel). On other OSes fall
    back to `O_NOFOLLOW` per component or an equivalent walk. Add
    `O_NONBLOCK | O_NOCTTY` (or the openat2 equivalent) so special files
    never block; `fstat` the descriptor and serve regular files only.
  - Serve from that descriptor. For office previews, copy the descriptor's
    bytes into a private per-conversion temp directory and convert the copy;
    never hand the original pathname to the converter. Validate cache files
    are regular files, not symlinks.
  - Map any escape (kernel `EXDEV`/`ELOOP` from `RESOLVE_BENEATH`, or a
    realpath outside the root, dangling or not) to 403
    `path_outside_workspace`; only a genuinely missing in-root object is 404.
  - Replace path logging in `office_preview.zig` with an opaque request id
    and a bounded, sanitised error string.
- **Done when:** tests cover: swap-after-check (create file, confine, replace
  with an escaping symlink, assert the open fails/403), an escaping ancestor
  directory symlink, dangling escaping file and directory symlinks → 403,
  a FIFO → rejected without blocking (finite deadline), a directory →
  rejected, and the five A-01 cases still pass. `mise run web-app-test` and
  `mise run web-app` pass. The `Security contract` in `packages/web_app/AGENTS.md`
  states that files are opened beneath the root descriptor.
- **Done (310be446).** Files open beneath the root descriptor (`served_files.zig`); FIFOs are rejected within a finite deadline; office previews convert a private copy; escapes return 403 consistently; `office_preview.zig` no longer logs paths. `web-app-test` passes 67/67 and `web-app` builds. The non-Linux fallback was not runtime-tested.

#### A-16 · `workspace.list` exposes repository binding roots
- **depends:** A-01, A-02 · **touches:** `packages/desktop/src/terminal/sessionizer.zig`
  (the `workspace.list` projection), possibly `store_protocol.zig`
- **Why (audit of 363bece0):** the gateway's `RootCache` expects each
  workspace entry to carry its repository bindings, but the daemon
  synthesizes only a primary binding whose root is the workspace path and
  never loads the stored repository manifest. Files under a secondary
  repository root therefore get 403 from `/api/file`, and the A-01 fixture
  test masks this by supplying data the daemon does not produce.
- **Do:** make the daemon's `workspace.list` projection include the real
  bindings from the repository manifest (id, `root_path`, `runtime_id`,
  availability). The gateway collector then keeps only bindings that belong
  to the serving runtime and are available. Add a daemon test with a
  two-repository workspace and a gateway test that uses the daemon's actual
  response shape.
- **Done when:** `$ZB daemon-test`, `$ZB headless-test` and
  `mise run web-app-test` pass; a file under a secondary binding root is
  served and one outside all bindings is 403.
- **Done (fb84ca8c).** The daemon's `workspace.list` now loads the stored repository manifest: every binding with `root_path`, `runtime_id` and availability, plus the serving runtime ID (`store_protocol.zig`). The gateway's `RootCache` keeps only available bindings that belong to the serving runtime. A new daemon test covers a stored secondary binding, and a gateway test uses the real response type to serve a file under a secondary root and reject foreign, unavailable and outside roots. `headless-test` and `web-app-test` pass; `daemon-test` fails only on the pre-existing `workspace_layout` crash.

#### A-17 · Daemon-native workspace close
- **depends:** A-02 · **touches:** `packages/desktop/src/terminal/sessionizer.zig` (daemon dispatch), `access_protocol.zig`
- **Why (A-02):** `workspace.close` is handled only by the desktop GUI. Paired devices can archive through `workspace.upsert {archived:true}`, but that doesn't stop the workspace's sessions or turns the way the GUI close does.
- **Do:** add a daemon RPC with the GUI's close semantics (archive, stop or detach its sessions, end running turns as the GUI does) that works with the desktop closed; map it to `repository:write`. Make the desktop's close path call it where possible.
- **Done when:** a daemon test closes a workspace that has a live session and a running turn; `$ZB daemon-test`, `$ZB headless-test` and `mise run web-app-test` pass.

#### A-18 · Daemon-native subagent open
- **depends:** A-02 · **touches:** `sessionizer.zig`, `access_protocol.zig`
- **Why (A-02):** `chat.open_subagent` exists only in the desktop GUI; mobile has no daemon equivalent.
- **Do:** add a daemon RPC that creates a linked child thread (parent link, provider/model, prompt), matching what the web and desktop clients show as subagents; map it to `chat:write`.
- **Done when:** tests cover link creation and paired-device reachability; `$ZB daemon-test` and `$ZB headless-test` pass.

### Website / cloud lane

#### W-01 · App Link / universal link files + pair landing page
- **depends:** H-03, H-04 (signing fingerprint, Team ID) · **touches:**
  `packages/website` (read its `AGENTS.md`)
- **Do:**
  - Serve `/.well-known/assetlinks.json` (Android package + SHA-256 signing
    fingerprint) and `/.well-known/apple-app-site-association` (`appID`
    `<TeamID>.dev.verdeai.app`, paths `/pair`, `/h/*`).
  - A static `/pair` page. It **never** reads the fragment on the server and
    sends no analytics. It shows "Open in Verde / Get the app / Use the
    desktop app" and passes the fragment to `verde://pair` client-side.
- **Done when:** the website build passes; the files are served with the
  right content type; a manual link check passes after deploy
  (human-verify).

#### C-01 · Spike: APNs reachability from Workers
- **touches:** `verde-cloud` scratch only
- **Do:** find out whether a Cloudflare Worker can send to APNs (HTTP/2
  only) directly. If it can't, the decision is: send iOS through FCM (APNs
  key uploaded to Firebase; the iOS app uses FirebaseMessaging tokens).
  Record the result in `mobile-app-plan.md` §8 and in C-02/I-10.
- **Done when:** the decision is written down with evidence (a doc link or
  a spike result).
- **Result (2026-09-25): direct APNs works from deployed Workers** (edge
  negotiates HTTP/2 to origin; workerd#4841, workerd#5266,
  `@fivesheepco/cloudflare-apns2`), not from `wrangler dev`. Decision and
  caveats are in plan §8. Follow-ups are folded into C-02, I-10 and H-05.

#### C-02 · Push relay Worker
- **depends:** C-01, A-12 · **touches:** `verde-cloud` (read its
  `AGENTS.md`/README; Alchemy v2, OAuth profile, stage `prod`)
- **Do:**
  - `POST /v1/register {platform, push_token}` returns `{send_token}`: an
    HMAC-bound, revocable capability for that one token. D1 stores only a
    token hash mapped to the push token.
  - `POST /v1/send {send_token, ciphertext, collapse_id}` → a
    `PushBackend` interface with two implementations chosen by the
    registration's `platform`: **FCM HTTP v1 for Android** and **direct APNs
    for iOS** (per C-01: plain `fetch()` to `api.push.apple.com` /
    `api.sandbox.push.apple.com` with a WebCrypto ES256 JWT cached and
    refreshed under 50 minutes; `apns-push-type: alert`, `apns-priority: 10`,
    `apns-collapse-id`, `apns-topic` = bundle id). Both send a placeholder
    `aps.alert` plus `mutable-content: 1` and the ciphertext under a custom
    key, at most 4 KB.
  - iOS registrations carry `environment: "production" | "sandbox"` (debug
    builds get sandbox tokens); store it with the token hash and pick the
    APNs host from it.
  - **First step:** deploy the C-01 probe Worker once (throwaway `wrangler`
    project, sandbox host, all-zero token) and record the APNs JSON `reason`
    in the task report; then delete it. `wrangler dev` cannot reach APNs, so
    unit tests mock both backends.
  - `DELETE /v1/register`.
  - Per-token and per-IP rate limits. Return 410 when the push token is
    invalid (FCM `UNREGISTERED`/404 or `INVALID_ARGUMENT` with a valid
    payload; APNs 400 `BadDeviceToken` / 410 `Unregistered`). No content
    logging.
  - Secrets (FCM service account, APNs key) are Worker secrets from H-05.
- **Done when:** unit tests use mocked FCM/APNs; `bun run check` passes in
  verde-cloud. Deploy only when the owner says so (human-verify).
- **Status (2026-09-25).** The repo is now the private `JonathanRiche/verde-cloud` (baseline `5e251739`). The relay is `services/push-relay` (`c16126bd`): Worker, D1 migration, HMAC send-token capabilities, IP and device rate limits, FCM and APNs backends, and a probe config. `bun run check` passes: 85 tests, 24 of them relay tests with FCM, APNs and OAuth mocked. Secret scans of the baseline and history were clean. Still open: owner approval to deploy the throwaway APNs probe; then the H-05 credentials, a separate approval for the production deploy, and setting A-13's `DEFAULT_RELAY_URL`.

#### C-03 · Demo runtime for store review
- **depends:** A-09
- **Do:** a sandboxed daemon with a scripted/mock provider (no real LLM
  keys) and seeded workspaces. It runs behind a public HTTPS proxy that
  meets the gateway's trusted-proxy envelope, paired with a
  restricted-preset grant. Document how to issue a fresh pair code for
  reviewers.
- **Done when:** a fresh phone can pair and run a scripted chat; the runbook
  lives in `docs/`.

### Core lane (`packages/client_core`)

#### K-01 · Core skeleton + Android toolchain proof
- **Do:**
  - Create `packages/client_core` with `build.zig` / `build.zig.zon` and an
    `AGENTS.md`.
  - Export `vc_version()` over a C ABI (`include/verde_client.h`) and a
    Zig-written JNI entry point `Java_dev_verdeai_core_Native_version`.
  - Build step `android-libs` produces `libverde_client.so` for
    `aarch64-linux-android` and `x86_64-linux-android` against the NDK
    sysroot (`ANDROID_NDK_HOME`), with the LLVM backend.
  - mise tasks `mobile-core-test` and `mobile-core-android`.
  - Document the NDK/SDK install for this Linux box.
- **Done when:** `mise run mobile-core-test` passes, the `.so` files are
  built, and `readelf -d` shows the expected NEEDED libraries only. D-01
  loads it.
- **Done (951a5a5a).** NEEDED is `libc.so` + `libdl.so` only; segments are
  16 KB-aligned. The NDK lives under `$HOME/Android/Sdk`
  (`packages/client_core/docs/android-toolchain.md`); Gradle needs
  `ANDROID_HOME`, the Zig build `ANDROID_NDK_HOME`. Kotlin side for D-01:
  `System.loadLibrary("verde_client")` then
  `object Native { @JvmStatic external fun version(): String }` in package
  `dev.verdeai.core`.

#### K-02 · iOS xcframework toolchain proof
- **depends:** K-01, H-01, H-02 · **machine:** mac
- **Do:** build step `ios-xcframework` builds static libraries for
  `aarch64-ios` and `aarch64-ios-simulator` against
  `xcrun --sdk iphoneos/iphonesimulator --show-sdk-path`, then runs
  `xcodebuild -create-xcframework` → `VerdeClient.xcframework` with a
  module map. mise task `mobile-core-ios`.
- **Done when:** `ssh mac 'cd ~/development/verde && git pull --ff-only && mise run mobile-core-ios'` succeeds; I-01 links it.
- **Done (e2f73abb).** Static arm64 device + simulator slices → `packages/client_core/zig-out/lib/VerdeClient.xcframework` with `include/module.modulemap`; a Swift import/link smoke runs per slice. SDK discovery lives in `scripts/build-ios-xcframework.sh` (Mac only), documented in `docs/ios-toolchain.md`. LLVM stays on; LLD is off for these archives because Zig 0.16 rejects it for Mach-O.

#### K-03 · Core API spec
- **Do:** write `packages/client_core/docs/core-api.md`:
  - Host lifecycle, and the **event** types (platform → core): `start`,
    `foreground`, `background`, `network_changed`, `http_response`,
    `ws_open`, `ws_message`, `ws_closed`, `timer_fired`,
    `secure_store_value`, plus user intents.
  - The **effect** types (core → platform): `http_request`, `ws_open`,
    `ws_send`, `ws_close`, `set_timer`, `cancel_timer`, `secure_store_put`,
    `secure_store_get`, `secure_store_delete`, `state_changed{scopes}`,
    `notify`, `log`.
  - **Queries** and their view-model shapes: `hosts`, `home`,
    `workspaces`, `thread:<id>`, `composer:<thread>`, `terminal:<id>`.
  - Correlation IDs, error model, memory ownership (`vc_buf_free`),
    threading rules (single-threaded per host).
- **Done when:** the spec is reviewed by the orchestrator and consistent
  with plan §5. It gates K-06.
- **Done (a5a81401), reviewed.** `packages/client_core/docs/core-api.md` rev 1: one serialized host handle per profile; effect IDs + `generation` reject stale completions; acknowledged storage effects (`secure_store_done`); intent receipts so uncertain mutations never replay; TLS = system trust **and** SPKI pin via `tls_probe`/`tls_peer`; separate `vc_term` handles with `terminal_output`/`terminal_applied`. Additions beyond the plan sketch are listed in §4. Note for K-12: `terminal_create` says "desktop-native open when available", but A-02 leaves `terminal.open`/`tail`/`screen`/`write`/`key` unmapped for paired devices (desktop-only, plan rule 3) — mobile terminals use `session.*` only.

#### K-04 · Extract shared remote-client modules from desktop
- **touches:** `packages/desktop/src/runtime/*`, `packages/desktop/src/chat/*`,
  the desktop `build.zig`
- **Do:**
  - Move `connection.zig`, `pin_controller.zig`, `thread_binding.zig`,
    `transcript_apply.zig`, the pure parts of `profile.zig` /
    `pair_client.zig` / `threads.zig` / `slash_commands.zig` into a shared
    Zig module (`packages/client_core/src/shared/`, exposed as module
    `verde_remote`).
  - The desktop imports from there, with no behaviour change. I/O stays in
    the desktop (`gateway_transport.zig`, `manager.zig`,
    `credential_store.zig`).
  - These desktop files may be under active edit by others: rebase
    carefully and keep diffs to moves plus import changes.
- **Done when:** `$ZB headless-test`, `$ZB runtime-test` and
  `mise run dev-build` pass, and the moved tests run under
  `mise run mobile-core-test`.
- **Done (e1111a8c).** Module `verde_remote` in `packages/client_core/src/shared/` contains `connection`, `thread_binding`, `transcript_apply` and `threads` (moved byte for byte), plus the pure parts of `pin_controller`, `profile`, `pair_client` and `slash_commands`. Randomness is passed in by the caller. The desktop keeps the I/O (pin persistence, `Manager`, the profile store) and re-exports the existing names; the daemon and web_app builds import the module too. `mobile-core-test` passes 51/51, and `headless-test` and `dev-build` pass. `runtime-test`: 334 passed plus the pre-existing `workspace_layout.zig:1963` crash.

#### K-05 · Split `headless/client.zig` codec from I/O
- **Do:** separate request encoding and response decoding (pure) from the
  socket calls, so the core can use the codec without `std.Io`. Existing
  callers keep working.
- **Done when:** `$ZB headless-test` and `$ZB runtime-test` pass.
- **Done (b12e4c17).** Pure request encoding and response decoding are in `packages/headless/src/client_codec.zig`; `client.zig` keeps the socket I/O and its existing API. `headless-test` passes. `runtime-test` matches the baseline (367 passed) apart from the pre-existing `state.workspace_layout` "browser tabs and a detached quick pane" crash, which is owned elsewhere.

#### K-06 · Sans-IO host engine + C ABI
- **depends:** K-03, K-04, K-05
- **Do:**
  - Implement the K-03 spec skeleton: `vc_host_new/free/handle/query`,
    `vc_buf_free`, JSON in/out, a per-host arena strategy, the effect
    queue, a timer model and correlation IDs.
  - JNI wrappers in Zig mirroring the C ABI.
  - Replace the default panic handler with one that logs through `liblog`
    on Android (and `os_log`/stderr on iOS). K-01 found that the std
    default drags a 256 KB per-thread signal stack into the `.so`; a
    custom handler should drop it. Verify with `readelf -S`/`nm`.
  - A deterministic test harness that scripts events and asserts effects.
- **Done when:** harness tests pass under `mise run mobile-core-test`; the
  `.so` and xcframework still build.
- **Done (e3e60c35, e4a0e6ab).** Transactional host engine (`src/host.zig`), C ABI and JNI wrappers (`include/verde_client.h`, `src/jni.zig`; 11 exports), a deterministic harness (`src/harness.zig`), and a custom panic handler: the Android `.so` has no TLS sections or signal-stack/default-panic symbols and needs only `liblog.so` and `libc.so`. The iOS archives bundle compiler-runtime helpers. `mobile-core-test` passes 63/63, and the Android and iOS builds pass. Spec interpretations are in `packages/client_core/docs/host-skeleton.md`: resource budgets, the diagnostic-code allowlist, fresh IDs for early timer re-arms, and persisted-receipt discovery deferred until the storage format exists. Intents owned by K-07 through K-12 return `unsupported`.

#### K-07 · Auth in core
- **depends:** K-06, A-05
- **Do:**
  - Parse pair links: the `verde://pair` form and the App Link form,
    fragment only.
  - Exchange with `client_nonce`, retried safely.
  - Keep the device credential through `secure_store_*` effects.
  - Token manager: refresh 2 minutes before expiry, single-flight, retry
    on 401 once, then flag "re-pair needed".
  - Mint tickets and build the WS subprotocol headers.
  - Read `/.well-known/verde-runtime` for discovery, and apply TOFU pin
    decisions through `pin_controller`.
- **Done when:** harness tests cover the happy path, lost exchange response
  → retry OK, expired grant, revoked device → re-pair state, and token
  refresh. `mise run mobile-core-test` passes.
- **Done (ffb390ec).** Pairing and authentication run in the core (`auth.zig`, `auth_rpc.zig`, and `docs/auth.md`). Credentials persist across restarts, and only one authentication runs at a time. SPKI pins are canonical lowercase 64-character hex. Exchange retries happen only when the server capability allows them. Tokens with two minutes or less remaining are refreshed rather than used. `mobile-core-test` passes 103/103, and `mobile-core-android` and `mobile-models-check` pass.

#### K-08 · RPC client + target pinning
- **depends:** K-06
- **Do:**
  - Envelope ids and the `target {runtime_id, instance_id}` on every call
    except `core.status`.
  - Route calls: `/api/rpc` for interactive and parked calls, the WS for
    pushes (plan P4).
  - Typed errors and `connection.FailureKind` retry classes.
  - A changed `instance_id` triggers a full resync, not an error screen.
- **Done when:** harness tests pass.
- **Done (fd4cfc22).** `src/rpc.zig` sends independent `/api/rpc` requests with numeric IDs and pins `target` on every call except `core.status`, reusing the K-05 codec. Failures are typed, and a 403 scope denial is kept distinct from an auth failure. After a transport loss a mutation is reported as uncertain and never replayed. A changed `instance_id` cancels old work, repeats the handshake and signals a full resync. JNI allows bounded large responses for snapshots, with a 1 MiB limit on everything else. The K-07 and K-09 integration points (`attachBearer`, `beginHandshake`, the resync signal) are described in `packages/client_core/docs/rpc.md`.

#### K-09 · Sync + projection
- **depends:** K-08
- **Do:**
  - Snapshot (`core.snapshot` scopes `workspaces, registry, sessions,
    turns, config`) plus WS `core.changes` handling (legacy mode for now).
  - Project into the view models: hosts, home/active list, workspaces →
    threads/terminals.
  - Port the projection rules from web `store.ts` (`panesForWorkspace`,
    `parseWorkspaceLayout`, `mergeThreadCatalogSettings`, attention
    ordering) where the desktop has no Zig equivalent. **No**
    `workspaces` / `panes` / `chat.status` desktop-mirror calls.
  - Page through `chat.thread.list`.
- **Done when:** harness tests use recorded fixture snapshots, taken from a
  temp daemon rather than the user's.
- **Done (dfbd6d6f).** The core has the legacy sync path, paged thread catalogs, and the workspace and Home projections, and its types are registered for codegen. Fixtures were recorded against a temporary daemon with isolated state. `mobile-core-test` (including 9 sync tests), `mobile-core-android` and `mobile-models-check` pass. Delta mode is K-16.

#### K-10 · Chat engine
- **depends:** K-09
- **Do:**
  - Transcript paging (`chat.message.list`, 40 per page, cursor; fallback
    `chat.thread.get`).
  - Tail loop (`chat.turn.tail`, `after_seq` cursor, resumes after
    failures) → `transcript_apply` overlay → commit on terminal status.
  - Send pipeline: optimistic user row → `chat.thread.upsert` → attachment
    chunks (`chat.attachment.create/append/commit`) → `chat.turn.start` →
    tail.
  - Stop (`chat.turn.cancel`), follow-ups queue/steer with the web state
    machine (port `followups.ts`), approvals (`approvalFromTurn`,
    `chat.turn.approve`).
  - Shell mode confirm (`chat.shell.run`), slash commands
    (`provider.slash.list/run`), models / effort / access catalogs (port
    `models.ts`), usage parsing (`usage.ts`), history buckets
    (`history.ts`), `@` search via `workspace.files.search`, draft
    persistence effects.
- **Done when:** harness tests replay recorded tail event streams and match
  the committed transcripts. Follow-up and approval state tests pass.

#### K-11 · Markdown AST / highlight spans / diff parse exports
- **depends:** K-06
- **Do:**
  - Query/utility calls exposing: `zig_markdown` → a compact AST JSON;
    `zig_treesitter` highlight spans for code blocks (cross-compiled for
    both targets); `zig_dif` / `VERDE_DIFF_V2` parsing → hunks with
    word-level spans (match web `parseDiffV2`).
  - Citation links → abstract `{path, line}` targets.
- **Done when:** golden tests pass, including the web app's markdown/diff
  test cases ported over.
- **Done (93000154, c37e038c).** Markdown, syntax highlighting and diffs render through bounded queries, with golden tests. Highlighting covers JS/JSX, TS, TSX and JSON; other languages show as plain text. The Android library grew by about 3.4 MiB per ABI (stripped: 3.77 MiB on arm64, 3.85 MiB on x86_64). iOS archives are about 8.3 MB. `mobile-core-test` passes 86/86, `mobile-core-android` passes, and the iOS import and link smoke test passes on the Mac.

#### K-12 · Terminal handle + PTY pump
- **depends:** K-06
- **Do:**
  - `vc_term_new/write/resize/snapshot/scroll/free` over libghostty-vt,
    using the same pin as the desktop `build.zig.zon`.
  - Pump logic as effects: `session.tail` offsets, trimming the first
    replay (`alignPtyStream` equivalent), 160 ms active / 1 s idle, paused
    when backgrounded.
  - Key encoding: Ctrl, Alt, named keys, paste in 4 KB chunks.
  - `session.create/resize/write/kill` and `terminal.open` for
    desktop-native panes.
- **Done when:** tests feed VT fixtures and assert the snapshots; the
  handle builds for both targets.

#### K-13 · Allowlist coverage test
- **depends:** K-10, A-02
- **Do:** a comptime or test-time list of every RPC method the core can
  send. Assert that each one has `requiredScopeMaskForRpc(method) != null`.
- **Done when:** the test fails if a method is added without an allowlist
  entry; `mise run mobile-core-test` passes.

#### K-14 · Contract suite vs real gateway + daemon
- **depends:** K-10
- **Do:** a `runtime-test`-style suite:
  - start a temp headless daemon plus `verde-web` on loopback, with temp
    state and a loopback-only proxy that fakes the trusted-proxy envelope;
  - create a pair grant, then drive the core through pair → token → ticket
    → WS → snapshot → create thread → mock turn → tail → approve →
    revoke.
  - Lease the ports.
- **Done when:** the suite passes locally with finite deadlines and is
  wired into `mise run mobile-core-test` (or a separate
  `mobile-core-contract` task).

#### K-15 · Kotlin/Swift model codegen
- **depends:** K-06
- **Do:** a Zig build step that walks the view-model and event/effect types
  at comptime and emits Kotlin `@Serializable` data classes and Swift
  `Codable` structs into the app packages. Generated files are committed
  with a "do not edit" header.
- **Done when:** codegen is deterministic and a CI check fails when the
  generated files are stale.
- **Done (fdb77f3d).** All generated types come from one list, `src/model_registry.zig`, and produce `CoreModels.kt` and `CoreModels.swift`. The generator keeps wire field names and decimal-string counters, and generates codecs for tagged unions. `mise run mobile-models-generate` regenerates the files, and `mise run mobile-models-check` fails when they are stale; it also runs in CI. Codec tests pass on Android (5) and iOS (5). To add a type, append `.{ "NativeName", module.Type }` to the registry and regenerate (`docs/model-codegen.md`). K-09 fills in the empty collection placeholders.

#### K-16 · Delta-mode sync
- **depends:** K-09, A-11
- **Do:** opt into `core.changes.mode delta` when advertised. Fetch only
  changed resources, persist the cursor per host, and fall back to legacy
  mode on older hosts.
- **Done when:** a contract test shows no full snapshots after hello, and a
  legacy-host test still passes.

#### K-17 · Attention state machine + push decrypt
- **depends:** K-09, A-12
- **Do:**
  - Port `notify.ts` `advanceAttention` / `notificationStatus`, which
    suppress notices for the focused pane.
  - `vc_push_open(secret, envelope)` using `push_seal.zig`, returning a
    notification view model (title, body, deep link, actions allowed). Any
    `open` error → the generic "A Verde chat needs attention" model;
    `UnsupportedVersion` additionally sets an `update_required` flag so the
    app can prompt for an update.
  - Build this small enough for the iOS NSE memory limit.
- **Done when:** tests use A-12's fixed vectors.

### Android lane (`packages/mobile_android`)

Shared rules: Kotlin, Compose, Material 3, min SDK 29, application ID
`dev.verdeai.app` (from H-03). Verification is `mise run mobile-android-test`
(unit + Robolectric) and `mise run mobile-android-build` (`assembleDebug`).
Tasks marked `+phone` also install with `adb install` and include a
human-verify step.

#### D-01 · Android project scaffold
- **depends:** K-01
- **Do:**
  - Gradle KTS project, version catalog, Compose BOM, the `dev.verdeai.app`
    ID and an `AGENTS.md` (security contract from plan §7).
  - A Gradle task that calls `zig build android-libs` and copies the
    `.so` files into `jniLibs`.
  - mise tasks `mobile-android-build` and `mobile-android-test`.
  - An empty screen showing `vc_version()`.
  - Add the root `AGENTS.md` scoped-rules link.
- **Done when:** both mise tasks pass; the APK runs in the emulator or on
  the phone and shows the core version.
- **Done (ee3c19df).** `packages/mobile_android` (Gradle KTS, Compose, `dev.verdeai.app`, min SDK 29); an explicit `preBuild` dependency runs `zig build android-libs` and packages both ABIs (16 KB alignment checked). `mobile-android-build` and `mobile-android-test` pass (Robolectric on API 29 and 35). Still open: install on a phone or emulator and confirm it shows the core version (needs H-07 or an AVD).

#### D-02 · Core bridge + effect executor
- **depends:** D-01, K-06, K-15
- **Do:**
  - `CoreHost` wrapper on a single-thread coroutine dispatcher per host.
  - Effect executor:
    - OkHttp for HTTP;
    - OkHttp WebSocket with the `Sec-WebSocket-Protocol` header;
    - coroutine timers;
    - secure storage (Keystore-wrapped keys + EncryptedFile/DataStore,
      no backup: `android:allowBackup=false` for the credential store).
  - `StateFlow` of view models refreshed on `state_changed`.
- **Done when:** unit tests with a fake core cover the effect round-trips.
- **Done (0f7fb9c6).** Added `CoreHost.kt` (runs the core on one thread), `EffectExecutor.kt` (OkHttp HTTP with the pin checked on every connection, WebSockets, timers) and `SecureStore.kt` (Keystore-wrapped keys, no backup). `mobile-android-test` passes 13 tests and `mobile-android-build` succeeds. Checking JNI and the Keystore on a real device is still open.

#### D-03 · Pairing flow
- **depends:** D-02, K-07, A-06, H-06, H-07
- **Do:**
  - Onboarding: scan (CameraX + ML Kit), paste link, or manual entry.
  - Intent filters for `verde://pair` and the App Link
    `https://verdeai.dev/pair`.
  - Device label defaults to the phone model. TOFU trust prompt; clear
    errors (grant expired / used / host unreachable → "Is Tailscale on?").
- **Done when:** unit tests pass. Human-verify: the owner scans the QR code
  from A-06 on their Android phone and lands on an empty Home screen.

#### D-04 · Hosts list + switcher + sign out
- **depends:** D-03, A-04
- **Do:** multi-host list with a status dot; switching host; "Sign out of
  host" calls `device.self.revoke` and wipes local data.
- **Done when:** tests pass.

#### D-05 · Home + Workspaces + lifecycle
- **depends:** D-04, K-09
- **Do:**
  - Navigation Compose. Home lists active/needs-attention panes with status
    and a timer. Workspaces lists workspaces → chats/terminals, with
    long-press menus.
  - `ProcessLifecycleOwner` → core foreground/background events;
    `ConnectivityManager` → `network_changed`.
  - Local cache for a warm start.
- **Done when:** tests pass. Human-verify: live status updates while a
  desktop chat runs; background → foreground recovers within about 2 s.

#### D-06 · Transcript screen
- **depends:** D-05, K-10, K-11
- **Do:**
  - Reversed `LazyColumn`. Markdown AST → `AnnotatedString`, code blocks
    with highlight spans and copy, grouped tool/command cards, subagent
    cards, Working/Thinking row with a timer.
  - Images with Coil, loaded through authenticated requests. Citation
    chips → file viewer (D-12). Load older on scroll.
- **Done when:** screenshot/UI tests of a fixture transcript pass;
  scrolling a 500-message fixture holds frame rate on the phone
  (human-verify).

#### D-07 · Diff card
- **depends:** D-06
- **Do:** stacked diff, per-file collapse, word-level highlights,
  horizontal scroll.
- **Done when:** golden tests against K-11 fixtures pass.

#### D-08 · Composer + pickers + attachments + follow-ups
- **depends:** D-06
- **Do:**
  - Multiline input with `imePadding`, send/stop, per-thread drafts.
  - Provider/model, effort, access and speed bottom sheets, with favourites.
  - Attachments from the Photo Picker, camera and SAF, sent through core
    chunk upload.
  - Slash and `@` suggestion strip; follow-up queue/steer UI; shell-mode
    confirm sheet.
- **Done when:** UI tests pass. Human-verify: a full round trip on the
  phone (send, stream, stop, attach a photo, queue a follow-up).

#### D-09 · Approvals card
- **depends:** D-06
- **Do:** inline Approve/Deny with a haptic; pending state; reflects
  approvals made elsewhere (desktop/web).
- **Done when:** tests pass; human-verify on a real approval.

#### D-10 · History, new chat, workspace management
- **depends:** D-05, A-03
- **Do:**
  - History: search, buckets, archive/unarchive, closed workspaces.
  - "New chat" sheet (workspace, provider/model, cwd).
  - Add workspace (path + `workspace.directory.list` browser),
    rename/close.
  - Thread menu: rename, regenerate title, sync, close.
- **Done when:** tests pass.

#### D-11 · Native terminal view
- **depends:** D-05, K-12
- **Do:**
  - Compose `Canvas` renderer from the K-12 snapshot: monospace metrics,
    colours from the host theme, cursor.
  - Accessory key row (Esc, Tab, Ctrl, Alt, arrows, `|`, `~`, `/`), IME
    input, hardware keyboard, pinch zoom (font size), long-press selection
    → clipboard (never logged).
  - Resize → `session.resize`; landscape support.
- **Done when:** tests pass. Human-verify: nvim and htop usable on the
  phone.

#### D-12 · File viewer
- **depends:** D-06, A-01
- **Do:** PDF with `PdfRenderer` (office files through `/api/preview`);
  markdown/text native; Share / Open with. Files go to cache storage only
  and are cleared on sign-out.
- **Done when:** tests pass.

#### D-13 · Theme + reduced motion
- **depends:** D-05
- **Do:** host theme from `/api/theme` → Material colour scheme (reuse the
  web colour math via the core, or port it). User override:
  host / system / dynamic colour. Honour the OS "remove animations" setting
  and the host's reduced-motion flags.
- **Done when:** tests pass.

#### D-14 · Push + actionable notifications
- **depends:** D-09, K-17, A-14, C-02, H-05
- **Do:**
  - FCM token → relay `/v1/register` → `send_token` → generate an X25519
    key (Keystore-protected) → `device.push.register` on each host.
  - `FirebaseMessagingService` decrypts via `vc_push_open`. Notification
    channels: Attention, Completed, Running.
  - Actions:
    - Approve/Deny use `setAuthenticationRequired(true)`, so they work from
      the lock screen after a biometric/unlock (decision 5).
    - Reply uses RemoteInput → a queued follow-up.
  - Deep links to the pane. Ongoing "running turn" notification with a
    Stop action.
  - Handle token refresh and re-register.
- **Done when:** tests pass. Human-verify: phone locked → turn finishes →
  notification; approve from the lock screen after a fingerprint.

#### D-15 · App lock + secure screen
- **depends:** D-05
- **Do:** optional BiometricPrompt gate on launch and after N minutes in the
  background. Optional `FLAG_SECURE`.
- **Done when:** tests pass.

#### D-16 · Maestro flows + UI tests
- **depends:** D-08, D-09
- **Do:** Maestro flows run against a K-14-style fixture host: pair, send,
  stop, approve, terminal input, background/resume. mise task
  `mobile-android-e2e`.
- **Done when:** the flows pass on the emulator; they also run on the phone.

#### D-17 · Release build + Play internal track
- **depends:** D-16, H-03
- **Do:** release signing from an owner-provided keystore outside the repo
  (environment variables), R8 config, and Zig `.so` debug symbols uploaded
  to Play. An upload script (Gradle Play Publisher or fastlane supply)
  pushes to the internal track. A versioning scheme separate from desktop.
- **Done when:** the owner installs from the Play internal track
  (human-verify).

### iOS lane (`packages/mobile_ios`)

Shared rules:
- Swift, SwiftUI, iOS 17+, bundle ID `dev.verdeai.app`, XcodeGen
  `project.yml`.
- Agents edit on Linux, commit and push. Builds and tests run on the Mac
  through `ssh mac 'cd ~/development/verde && git pull --ff-only && mise run mobile-ios-test'`.
- Each screen task **translates the finished Android screen** (named in
  `depends`) so behaviour matches; the core already provides the view
  models.

#### I-01 · iOS project scaffold
- **depends:** K-02
- **Do:**
  - XcodeGen `project.yml` with targets App, NotificationServiceExtension
    (placeholder) and Tests; links `VerdeClient.xcframework`; adds an
    `AGENTS.md`.
  - mise tasks `mobile-ios-build` (xcodegen + `xcodebuild build`, simulator)
    and `mobile-ios-test`. The screen shows `vc_version()`.
  - Add the root `AGENTS.md` link.
- **Done when:** both mise tasks pass over SSH.
- **Done (bdfcfd3e).** `packages/mobile_ios` holds the XcodeGen `project.yml` (App, a placeholder NotificationServiceExtension, Tests) linking `VerdeClient.xcframework`, plus `scripts/xcode.sh`. The mise tasks rebuild the xcframework and generate the project, and the tests run on a temporary simulator that is deleted afterwards. `mobile-ios-build` and `mobile-ios-test` pass over SSH (unsigned, no warnings). First simulator boot on the Mac takes about 8 minutes. Signing waits for H-04; building with the newer CI SDK is checked in I-12.

#### I-02 · Core bridge + effect executor
- **depends:** I-01, K-06, K-15
- **Do:** an `actor CoreHost`; URLSession HTTP; `URLSessionWebSocketTask`
  with protocols; Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced);
  an `@Observable` view-model store.
- **Done when:** XCTest with a fake core passes.
- **Done (f389ab00..10b4f4cd).** Added `CoreHost.swift` (an actor), `SessionTransport.swift` (URLSession with the pin checked in the delegate, WebSockets) and `KeychainStorage.swift` (this device only). XCTest passes 16/0 on the Mac. Keychain was tested through an injected fixture; testing on a signed device is still open. The pin format differs from K-07's lowercase hex; I-03 fixes this first.

#### I-03 · Pairing flow
- **depends:** I-02, K-07, A-06
- **Do:** VisionKit `DataScannerViewController`, paste, manual entry;
  `verde://` URL scheme plus the Associated Domains universal link; TOFU
  prompt; same errors as D-03.
- **Done when:** tests pass. Human-verify: pairing works on the test
  iPhone (development install through the Mac).
- **Done (abe0dafd, ffd974f4, a6a96c69, ce41f917).** iOS pins now use the core's lowercase hex (`abe0dafd`). The app has a pairing screen with QR scan, paste and manual entry, handlers for both link forms, host trust confirmation, retry after a storage failure, and a retry when a reply is lost; the tests drive the real core. A malformed link now shows an error the user can retry instead of closing the host, and the app obscures its view when inactive. `mobile-ios-build` succeeds on Xcode 16.2 and `mobile-ios-test` passes 22/0. On-phone steps are in `packages/mobile_ios/docs/pairing.md`. Associated Domains waits on H-04, and testing on a phone waits on H-06.

#### I-04 · Hosts + Home + Workspaces + lifecycle
- **depends:** I-03, D-05
- **Do:** translate D-04/D-05. `scenePhase` → foreground/background;
  `NWPathMonitor` → `network_changed`.
- **Done when:** tests pass.

#### I-05 · Transcript + diff + approvals
- **depends:** I-04, D-06, D-07, D-09
- **Do:** translate. Markdown AST → `AttributedString`; highlight spans;
  lazy list performance on long transcripts.
- **Done when:** tests pass; scrolling human-verified.

#### I-06 · Composer + pickers + attachments + follow-ups
- **depends:** I-05, D-08
- **Do:** translate. PhotosPicker, camera, document picker; keyboard
  avoidance.
- **Done when:** tests pass; round trip human-verified.

#### I-07 · History, new chat, workspace management
- **depends:** I-04, D-10
- **Done when:** tests pass.

#### I-08 · Native terminal view
- **depends:** I-04, D-11
- **Do:** translate. A Core Text / Canvas renderer, `inputAccessoryView` key
  row, hardware keyboard (`UIKeyCommand`), pinch zoom, selection.
- **Done when:** tests pass; nvim usable (human-verify).

#### I-09 · File viewer, theme, app lock
- **depends:** I-05, D-12, D-13, D-15
- **Do:** PDFKit viewer, theme mapping, Face ID gate, app-switcher privacy
  blur.
- **Done when:** tests pass.

#### I-10 · Push + NSE + actionable notifications
- **depends:** I-05, K-17, C-02, H-05
- **Do:**
  - Native APNs only (no Firebase SDK in the iOS target or the NSE, per
    C-01): `UNUserNotificationCenter` + the raw device token from
    `didRegisterForRemoteNotificationsWithDeviceToken` (hex) and the build's
    APNs environment → relay register → `send_token` → X25519 key in the
    shared Keychain access group → `device.push.register`.
  - The NSE links a minimal core slice and decrypts with `vc_push_open`
    (mind the NSE memory limit). It replaces the relay's placeholder alert;
    if decryption fails the placeholder ("A Verde chat needs attention")
    shows as-is.
  - Categories:
    - Approve/Deny use `.authenticationRequired` (lock screen after Face
      ID, decision 5).
    - Reply uses `UNTextInputNotificationAction`.
  - Deep links.
- **Done when:** tests pass. Human-verify: locked iPhone → notification →
  approve after Face ID.

#### I-11 · XCUITest / Maestro flows
- **depends:** I-06
- **Do:** the same flows as D-16 on the simulator; mise task
  `mobile-ios-e2e`.
- **Done when:** the flows pass over SSH.

#### I-12 · TestFlight pipeline (GitHub Actions)
- **depends:** I-11, H-04 · **machine:** ci (GitHub-hosted macOS runner with Xcode 26+)
- **Why CI:** the Mac mini stays on macOS 14 / Xcode 16.2, which App Store
  Connect no longer accepts (see H-02).
- **Do:** add `.github/workflows/mobile-ios.yml`, triggered by
  `workflow_dispatch` and by `mobile-ios-v*` tags. Steps:
  1. Check out the repo, install Zig through mise, and build the xcframework
     (K-02 script).
  2. Run `xcodegen`, then `xcodebuild archive` and `-exportArchive` with the
     newest Xcode on the runner.
  3. Upload to TestFlight with an App Store Connect API key.
- **Secrets:** the owner stores the distribution certificate (.p12 plus
  password), the provisioning profile (or uses API-key-based automatic
  signing), and the API key ID, issuer and .p8 in GitHub Actions secrets.
  They are never in the repo. Use a temporary keychain and delete it at the
  end of the job.
- **Done when:** a dispatched run uploads a build that appears in TestFlight
  and installs on the iPhone (human-verify).


### Release

#### R-01 · Store listings and privacy forms
- **depends:** D-17, I-12, C-03 · **human-led**; agents draft the text
- **Do:** listing copy and screenshots; the Play data-safety form and Apple
  privacy labels (no tracking; credentials on the device; push content
  end-to-end encrypted); review notes with the demo host pair instructions;
  support URL and privacy policy page on the website.
- **Done when:** both apps are submitted.

---

## Part D — Backlog (after v1, not yet broken into tasks)

Live Activity (iOS) · share target (both) · tablet/iPad two-pane · processes
screen (`process:*`) · command palette sheet · home-screen widgets ·
UnifiedPush/ntfy for self-hosters · embedded tailnet (libtailscale) or
Connect relay so the Tailscale app isn't required · Connect login on mobile
(custom-scheme redirect) · wasm build of the core for the web app · move the
web app to delta mode and off the desktop-mirror RPCs.
