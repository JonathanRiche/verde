# Verde Mobile (Android + iOS) — Gameplan

Status: proposal, 2026-09-25. Nothing here is built yet.
Decision: **native UI (Jetpack Compose on Android, SwiftUI on iOS) on a shared
Zig client core. Android ships first, then iOS on the settled core.**

## 1. What we are building

The mobile app is a native client for a remote Verde runtime. It works like
`packages/web_app`: it sends everything to a `verde-daemon` through the
`verde-web` gateway and runs nothing on the phone. No agents, no providers, no
PTYs and no workspace files live on the device.

Rules for everything below:

1. **The app is only an interface.** Every capability comes from daemon RPCs.
   If something is missing, fix it in the daemon or gateway, not in app-side
   workarounds.
2. **Match the web app's features.** Adapt them for touch, small screens and
   short sessions. Don't redesign the product.
3. **The desktop app must not be required.** Like the web client, the app
   works when the desktop app is closed. It uses no `workspaces` / `panes` /
   `chat.status` desktop-mirror RPCs.
4. **Logic in Zig, screens in the platform toolkit.** Protocol, sync,
   transcript assembly, markdown and diff parsing, and terminal emulation live
   in one Zig core. Kotlin and Swift own UI, networking, secure storage, push
   and lifecycle.

## 2. How the phone connects (reuse what exists)

```
Phone app ──HTTPS/WSS──> Tailscale Serve (https://<host>.ts.net)
                              │ exact trusted-proxy envelope
                              ▼
                        verde-web  (127.0.0.1:7420, gateway)
                              │ JSON-RPC over the Unix socket
                              ▼
                        verde-daemon (host-private)
```

The native-client auth chain already exists and the web app doesn't use it.
It lives in `packages/headless/src/access_protocol.zig`, `web_app/src/auth.zig`
and `web_app/src/http.zig`, and is documented in `docs/serve-pair-connect.md`:

| Step | Call | Result |
|---|---|---|
| Pair (once per install) | Scan `verde://pair?host=…&grant_id=…#code=…` → `POST /auth/pair/exchange` | `device_id` + 64-hex `device_credential` (long-lived; stored in the Keystore/Keychain) |
| Optional discovery | `GET /.well-known/verde-runtime` | `runtime_id`, `instance_id`, URLs, capabilities |
| Access token | `POST /auth/access-token` with `Authorization: VerdeDevice <id>.<cred>` | 15-minute scoped Bearer token (one live token per device) |
| WS ticket | `POST /auth/websocket-ticket` (Bearer) | Single-use ticket, valid 30 s |
| Live socket | `GET /ws` with `Sec-WebSocket-Protocol: verde.v1, verde.ticket.<t>` | `core.hello`, `core.snapshot`, `core.changes` pushes |
| RPC | `POST /api/rpc` (Bearer) with `{id, method, params, target:{runtime_id, instance_id}}` | Interactive calls and parked long-polls |

Native clients send no `Origin` header, so the gateway's cookie/Origin checks
don't apply. There's no CORS to deal with.

**Reachability in v1:** the phone runs the Tailscale app, and the host runs
`verde-server serve --tailscale`. Connect (the control plane) handles
discovery and bootstrap only; it does not relay traffic (see Phase 10).

## 3. Why native + Zig core

| Option | Verdict |
|---|---|
| **Compose + SwiftUI on a Zig core** ✅ | Reuses the desktop's existing remote-client Zig code. Gives a native terminal (libghostty-vt, no WebView) and the best platform feel. Widgets, Live Activities and notification extensions are native anyway. Cost: two UI codebases, though Compose and SwiftUI are nearly the same model, so the second UI is mostly translation. |
| React Native + TS core | One mobile UI and logic shared with web. But the terminal would sit in a WebView, and the logic would be a TypeScript port of code that already exists in Zig. |
| Capacitor shell around the SPA | This is essentially the PWA we already have. Not worth a store app. |

The desktop is already a remote client (`packages/desktop/src/runtime/*`).
That makes it the natural source for mobile logic, not the web app's
TypeScript. The web app keeps its TypeScript for now; compiling the same core
to wasm for it is an option later (ghostty-vt already runs as wasm there).

## 4. Host-side prerequisites (verde repo, must land first)

### P1. Security: confine `/api/file` and `/api/preview` (blocker)

`validServedFilePath` (`web_app/src/http.zig`) accepts **any absolute path**
the gateway user can read, for example `~/.ssh/id_ed25519`. A paired device
only needs `repository:read` to do that. Phones get lost. Restrict reads to
registered workspace or repository roots after resolving symlinks (realpath),
and add tests. The web client benefits from the same fix.

### P2. Paired-device RPC allowlist parity

`requiredScopeMaskForRpc` (`headless/src/access_protocol.zig`) leaves out
methods the web app depends on:

| Missing for paired devices | Proposal |
|---|---|
| `workspace.create`, `workspace.rename`, `workspace.close` | `repository:write` |
| `chat.open_subagent`, `provider.title.generate`, `provider.threads.list` | `chat:read` / `chat:write` |
| `terminal.open`, `terminal.tail`, `terminal.screen`, `terminal.write`, `terminal.key` (desktop-native panes) | `terminal:*`; otherwise mobile uses `session.*` only |
| `process.list`, `process.definitions` / `process.start`, `process.restart`, `process.stop` | New `process:read` / `process:write` scopes (not granted by default) |
| `daemon.client.register` | Allow; `config.ui.set` isn't needed on mobile |
| `workspaces`, `panes`, `chat.status` (desktop mirror) | **Not added.** Move the web app off them too (continues `c793788d`). |
| `web.directory.list` (new-workspace browser) | Daemon RPC under `repository:read`, confined to allowed roots |

Because the core is Zig, **the allowlist check becomes a unit test in the
core**: every method it can call must map to a scope in
`requiredScopeMaskForRpc`. Both are Zig, so there is no drift between
languages.

### P3. Change feed that suits mobile

The gateway re-sends a full `core.snapshot` (up to 8 MiB) after every change
and ignores client cursors. Add the capability `core.changes.delta.v1`: when
a client opts in, the WS forwards change entries only, resumes from the
client's cursor, and doesn't push snapshots. `expired` or a changed
`instance_nonce` → one full snapshot. Keep the default behaviour for the web
app until it moves over.

### P4. Parked calls and WS concurrency

The WS handles requests one at a time, so a parked `chat.turn.tail` blocks
everything else. Mobile uses the web pattern: WS for pushes, `/api/rpc` for
interactive and parked calls. Concurrent WS dispatch is an optional later
improvement.

### P5. Push notification pipeline (see §8)

- New RPCs: `device.push.register`, `device.push.unregister`,
  `device.push.test` (new scope `device:write`).
- Attention events: turn completed, failed or aborted; approval needed;
  `chat.tasks.blocked` (input needed).
- A durable outbox in the daemon store, retried with backoff and
  deduplicated per `(turn_id, kind)`.

### P6. Device self-service and management

- Map `device:read` to `device.self.get`. Add `device.self.revoke`
  ("Sign out of this host").
- Desktop and web Settings get a **Paired devices** list (label, last seen,
  scopes, revoke) and a **Pair a phone** button that shows the pair URL as a
  QR code. `verde-server pair create` prints a terminal QR code.
- Make pair exchange idempotent per client nonce within the grant TTL, so a
  lost response doesn't burn the grant.
- Add an App Link / universal link form
  `https://verdeai.dev/pair?host=…#code=…` alongside `verde://`.

### P7. Small protocol additions

- `core.capabilities` advertises `mobile.min_client` so either side can show
  a clear "please update" screen.
- Scoped `core.snapshot` pagination if a large host goes over 1 MiB per call.
- Use the existing `workspace.files.search` for `@` mentions (web
  `searchFiles` is a stub).

### P8. Pairing permission presets

Pair grants currently always grant all eight scopes. Add presets, chosen when
the grant is created (`verde-server pair create --preset …` and the desktop
"Pair a phone" dialog), plus an optional per-device cap on the access mode of
turns started from that device, enforced by the daemon on `chat.turn.start`.
The preset list and default are open decision 4; see the tasks file (H-08).

## 5. The Zig client core (`packages/client_core`)

### 5.1 Reuse map

The modules that matter already import only `std` and `headless`:

| Source | What it gives mobile | Work needed |
|---|---|---|
| `headless/src/*` protocol modules (`protocol`, `access_protocol`, `changes_protocol`, `store_protocol`, `attachment_protocol`, `session_protocol`) | Envelopes and every request/response type | Use as-is |
| `headless/src/client.zig` | Typed RPC helpers | Split encode/decode from its I/O (it touches `std.Io`) |
| `desktop/src/runtime/connection.zig` | Connection phases, failure kinds, reconnect backoff, handshake validation. Already pure. | Move to a shared package |
| `desktop/src/runtime/pair_client.zig` | Pair exchange, device authorization | Move; route HTTP through the core's effect API |
| `desktop/src/runtime/profile.zig`, `profile_store.zig` | Host profiles, URL validation (`/ws` pairing), descriptor parsing | Move; storage goes through a platform callback |
| `desktop/src/runtime/pin_controller.zig` | Trust / SPKI pinning decisions | Move; the platform does the actual TLS check |
| `desktop/src/runtime/thread_binding.zig` | Thread ↔ runtime binding | Move |
| `desktop/src/chat/transcript_apply.zig` | Streamed turn events → transcript rows. Already pure and documented as such; the web's `applyTailEvent` mirrors it. | Use as-is |
| `desktop/src/chat/threads.zig`, `slash_commands.zig`, `handoff.zig` | Thread, slash command and handoff logic | Separate the pure parts |
| `zig_markdown` (streaming parser) | Markdown → AST, drawn natively (`AnnotatedString` / `AttributedString`) | Add an AST export |
| `zig_treesitter` | Syntax highlighting spans for code blocks | Export spans |
| `zig_dif` (parsing, not the imgui `view.zig`) | Diff cards | Export parsed hunks |
| libghostty-vt (same pin as desktop) | Native terminal emulation | Wrap write/resize/snapshot |

Not reused: `gateway_transport.zig` and `manager.zig` (desktop I/O and
threads), `credential_store.zig` (shells out to OS secret tools), `ssh_tunnel*`,
the loopback redirect in `connect_client.zig`, all desktop UI and `state.zig`,
and all daemon and provider code.

Extracting these modules into a shared package benefits the desktop too: its
remote client becomes the same code the phones run.

### 5.2 Shape: sans-IO core, platform does the networking

The core never opens sockets, reads files or starts threads. The platform
feeds events in and carries out the effects the core asks for. This matters
because Zig's `std.crypto` TLS can't read the Android or iOS certificate
stores. OkHttp and URLSession already handle VPNs (Tailscale runs as a system
VPN), proxies, power management and certificate trust.

```
             events in (JSON)                          effects out (JSON)
Compose/SwiftUI ──> vc_host_handle(host, event) ──> [ {http_request…}, {ws_send…},
   ▲                                                  {state_changed: scopes…},
   │                                                  {secure_store_put…}, {notify…} ]
   └── vc_host_query(host, "home" | "thread:<id>" | …) → view-model JSON
```

- **C ABI**, roughly 10 functions: `vc_host_new`, `vc_host_free`,
  `vc_host_handle`, `vc_host_query`, `vc_buf_free`, plus a terminal handle
  API (`vc_term_new`, `write`, `resize`, `snapshot`, `scroll`).
- **Android:** `libverde_client.so` built by Zig for `aarch64-linux-android`
  (plus `x86_64-linux-android` for the emulator) against the NDK libc. The
  JNI entry points (`Java_dev_verdeai_core_Native_*`, package `dev.verdeai.core`) are written in Zig
  directly, so no C shim is needed. Kotlin wraps them in a coroutine
  single-thread dispatcher per host.
- **iOS:** static library for `aarch64-ios` and `aarch64-ios-simulator`,
  packaged as `VerdeClient.xcframework` with a module map. Swift wraps it in
  an `actor` per host.
- Threading: each host core instance is single-threaded and driven from one
  serial executor. Terminal handles are separate objects.
- Memory: the core allocates with `std.heap.c_allocator`; every returned
  buffer is freed with `vc_buf_free`. No pointers kept across calls.
- Builds come from `packages/client_core/build.zig` steps (`android-libs`,
  `ios-xcframework`), using the LLVM backend per the repo rules.

### 5.3 Core responsibilities

- Auth: parse pair links, pair exchange, token manager (refresh at T-2min,
  single-flight), ticket minting, and deciding when to re-pair.
- RPC: ids, `target` pinning to `runtime_id`/`instance_id`, typed errors,
  retry classes (`connection.FailureKind`).
- Sync: snapshot plus change feed (delta mode with snapshot fallback),
  projection into workspaces, threads, panes and the active/attention list.
  `instance_id` change → silent full resync.
- Chat: turn tail cursor, `transcript_apply`, send pipeline (upsert →
  attachment chunks → `chat.turn.start`), follow-up queue/steer states,
  approvals, transcript paging, diff parsing.
- Catalogs: models, slash commands, shell-mode confirmation, usage parsing,
  history buckets. These port from the web app's pure TS files
  (`models.ts`, `composer_commands.ts`, `shell_mode.ts`, `usage.ts`,
  `history.ts`) where the desktop has no Zig equivalent.
- Attention: the web app's `notify.ts` state machine (`advanceAttention`),
  so foreground notifications for the focused pane are suppressed.
- Terminal: `session.tail` / `write` / `resize` pump logic and key encoding.
  VT state lives in the terminal handle.

### 5.4 Core testing

Zig unit tests plus a contract suite against a real `verde-web` and a
temporary headless daemon (`runtime-test` style: temp state, loopback,
finite deadlines, no providers). Tests drive the sans-IO API directly and
need no phone. This is where most bugs should be caught.

## 6. Mobile app scope (both platforms)

### 6.1 Screen map (web → mobile)

| Web feature | Mobile form | v1? |
|---|---|---|
| Login page | **Pair flow**: scan QR / paste link / enter host, grant and code by hand; device label defaults to the phone's name | ✅ |
| (none) | **Hosts list**: several paired runtimes, switcher, status dot, "Sign out of host" | ✅ |
| Sidebar ACTIVE list | **Home**: working and needs-attention panes first, with live status, timer and swipe actions (stop, open) | ✅ |
| Sidebar workspace groups | **Workspaces**: workspace → chats and terminals; long-press menu (rename, close, new chat, new terminal, history) | ✅ |
| Chat transcript | Native lazy list (`LazyColumn` / `List`): markdown, code with highlighting and copy, grouped tool/command cards, subagent cards, Working/Thinking row, images, file-citation chips, load older on scroll | ✅ |
| Diff card | Stacked diff, per-file collapse, horizontal scroll | ✅ |
| Approvals card | Large Approve/Deny with a haptic; also from the notification (§8) | ✅ |
| Composer | Native multiline input that follows the keyboard, send/stop, draft saved per thread | ✅ |
| Model / effort / access / speed pickers | Bottom sheets; favourites pinned | ✅ |
| Attachments | Camera, photos and files via `chat.attachment.*` (no host-path routes) | ✅ |
| Slash commands, `@` mentions | Suggestion strip above the keyboard; `@` uses `workspace.files.search` | ✅ |
| Follow-ups (queue/steer) | Same states as web: pending, sent inline, retry, pull back | ✅ |
| Shell mode `!cmd` | Confirmation sheet | ✅ |
| Provider readiness banner, usage card | Native equivalents | ✅ |
| History | Search, buckets, archive/unarchive, closed workspaces | ✅ |
| New chat / routing / cwd | "New chat" sheet: workspace, provider/model, cwd | ✅ |
| Add workspace | Path entry plus confined directory browser (P2) | ✅ |
| Terminal panes | **Native view**: libghostty-vt snapshot drawn on a Compose `Canvas` / Core Text view; accessory key row (Esc, Tab, Ctrl, Alt, arrows, `|`, `~`, `/`), pinch zoom, selection → native copy, hardware keyboard support | ✅ |
| File viewer | PDF through Android `PdfRenderer` / iOS PDFKit; markdown/text native; Share / Open in | ✅ |
| Command palette | Global search sheet | v1.1 |
| Processes | Read-only list and logs; start/stop with `process:write` | v1.1 |
| Theme | Follow `/api/theme` host colours (same as web) plus Material You / system dark mode override | ✅ |
| Reduced motion | OS setting plus the host's verde.json flags | ✅ |
| Split layout editing (`pane.resize` / `pane.move`) | No on phones; tablets / iPad show 2 panes side by side (v1.1) | ✗ |
| Browser panes | Placeholder, same as web | ✗ |

### 6.2 Native-only features (why the store app exists)

1. **Push notifications**: turn done, failed, needs approval, needs input,
   with deep links to the pane.
2. **Actionable notifications**: Approve / Deny / Reply from the
   notification. Approve/Deny require the device to be unlocked.
3. **Running-turn indicator**: an Android ongoing notification with elapsed
   time and a Stop button, and an iOS Live Activity (v1.1).
4. **Share target**: send text, URLs, images or files from any app into a
   chat (v1.1).
5. **Home-screen widget**: active agents and panes waiting on you (v2).
6. **App lock**: optional biometric gate. Android sets `FLAG_SECURE`
   (optional); iOS blurs the app-switcher snapshot.
7. **Deep links**: `verde://pair…`, `verde://h/<runtime>/thread/<id>`,
   App Links / universal links.
8. Haptics; system voice input comes free with the native keyboard.

### 6.3 Non-goals

Running agents or providers on the device. Offline editing. Browser panes.
Desktop layout editing. Owner-token login. The chat-connections editor.
Reimplementing daemon logic.

## 7. Platform stacks

| Concern | Android (first) | iOS (second) |
|---|---|---|
| Language / UI | Kotlin, Jetpack Compose, Material 3 | Swift, SwiftUI |
| Min OS | Android 10 (API 29) | iOS 17 |
| HTTP / WS | OkHttp (HTTP/2, WebSocket, subprotocol header) | URLSession + `URLSessionWebSocketTask` |
| Secure storage | Android Keystore-backed encryption (credential never leaves the device; no cloud backup) | Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| QR | CameraX + ML Kit barcode | AVFoundation / VisionKit `DataScannerViewController` |
| Push | FCM + `FirebaseMessagingService` (decrypts via the core) | APNs + Notification Service Extension (links the core) |
| Background | WorkManager for push-registration refresh only; no persistent socket | None; push plus foreground catch-up |
| Cache | Room/SQLite or a DataStore file per host | SwiftData/SQLite file per host |
| Crash reports | Play Console + a symbol upload for the Zig `.so` | Xcode Organizer + dSYM for the Zig static library |
| Build machine | This Linux box (Android SDK/NDK, Gradle, emulator or USB phone) | The Mac mini (already a Verde remote connection; stays on macOS 14 / Xcode 16.2): Xcode builds, simulator, development and ad-hoc installs. TestFlight and App Store builds run on GitHub Actions macOS runners (Xcode 26+; free for this public repo). The Zig xcframework can be built there too, or cross-built on Linux against the SDK copied from the Mac. |
| Location | `packages/mobile_android` (Gradle Kotlin DSL) | `packages/mobile_ios` (XcodeGen `project.yml`, so project files are text agents can edit on Linux) |

Each app gets an `AGENTS.md` containing the security contract below, and the
root scoped-rules index gets an entry for each.

**Security contract (both):**
- The device credential exists only in secure storage.
- Tokens are held in memory only.
- Nothing sensitive in logs, crash reports, URLs or analytics.
- TOFU-pin the host's TLS key on first pair, with a clear re-trust flow.
  Tailscale certificates rotate, so pin the key or the issuer, not the leaf.
- No owner token entry at all.

**Lifecycle (both):**
- Foreground: refresh the token if needed → mint a ticket → open the WS →
  delta catch-up from the cursor → resume tail loops for running turns.
- Background: close the WS within a few seconds and stop polling. Push takes
  over.
- Network change: reconnect with the core's jittered backoff.

## 8. Push notifications

APNs and FCM credentials belong to the app publisher, so user-run daemons
can't send pushes directly. A small **Verde push relay** that knows nothing
about content sits in between:

```
daemon outbox ──HTTPS──> push relay (verde-cloud Worker) ──> FCM / APNs ──> phone
                  (sealed payload + send_token)          service / NSE decrypts via the Zig core
```

1. The app registers its FCM/APNs token with the relay and gets back an
   opaque, rate-limited **`send_token`** that can only reach that one device.
2. The app generates an X25519 key pair (private key stays in secure
   storage) and calls `device.push.register {platform, send_token,
   public_key}` on each paired host.
3. On an attention event, the daemon seals `{runtime_id, workspace_id,
   thread_id, turn_id, kind, title, snippet}` to the device key (X25519 +
   HKDF + ChaCha20-Poly1305, all in Zig `std.crypto`, on both the daemon and
   the core) and POSTs `{send_token, ciphertext, collapse_id}` to the relay.
4. The phone decrypts locally with the same Zig code and shows the title,
   body and actions. If decryption fails, it shows a generic "A Verde chat
   needs attention".
5. The relay stores no content and has no user accounts; send tokens can be
   revoked. UnifiedPush/ntfy for self-hosters is a v2 option on Android.

The relay is a Cloudflare Worker next to the existing Alchemy stack in
verde-cloud. It needs an FCM service account (Phase 6) and an APNs `.p8` key
(Phase 8) as Worker secrets.

**Decision (C-01, 2026-09-25): iOS goes direct to APNs from the relay;
FCM is Android-only.** Production Workers `fetch()` reaches APNs: subrequests
leave through Cloudflare's proxy stack, which negotiates HTTP/2 with the
origin via ALPN, so the HTTP/2-only endpoint accepts them. Evidence: the
workerd maintainer's statement plus the reporter's production result in
cloudflare/workerd#4841 (Aug 2025), workerd#5266 ("fetch in a real Worker
uses HTTP/2 when possible"), and the MIT `@fivesheepco/cloudflare-apns2`
client, which is a plain `fetch()` to `api.push.apple.com:443` plus a
WebCrypto ES256 JWT. Caveats: this is edge behaviour, not a documented
Workers guarantee, and local `wrangler dev` / workerd is HTTP/1.1-only with no
plans to change, so APNs is mocked in tests and smoke-tested only on a
deployed preview; C-02 begins by running the sandbox probe once on our
account and recording the `reason` response. The Sockets API is not a
fallback (no HTTP/2 client exists for it). Payload shape for both paths: a
placeholder `aps.alert` ("A Verde chat needs attention") plus
`mutable-content: 1` so the NSE swaps in the decrypted content,
`apns-priority: 10`, `apns-collapse-id`, at most 4 KB; the relay stores the
APNs `environment` (production/sandbox) with each iOS token. Fallback if the
HTTP/2 path ever regresses: FCM HTTP v1 with the `.p8` uploaded to Firebase
(4096-byte limit; data-only iOS messages are forced to priority 5, so the
placeholder alert is required there too). That is a relay-side backend swap
plus an iOS token-type change in the app.

## 9. Phases

The work runs agent-driven from an orchestrator that follows
[`mobile-app-tasks.md`](mobile-app-tasks.md). There are no calendar
estimates; order and dependencies live in that file.

| Phase | Scope | Exit criteria |
|---|---|---|
| **0. Host prerequisites** (verde) | P1–P8 | A paired Bearer client can drive every web-app flow; path-escape tests pass |
| **1. Zig client core** | §5; toolchain proof on Linux (Android) and the Mac mini (iOS) first | Core drives pair → sync → send → tail → approve in tests with no phone involved |
| **2. Android skeleton** | Compose app, `.so` wiring, OkHttp, Keystore, pairing, hosts, Home/Workspaces | Your phone pairs over Tailscale and browses; survives background/foreground |
| **3. Android chat** | Transcript, composer, pickers, stream/stop, approvals, attachments, follow-ups, history | Daily-driveable chat |
| **4. Android workspaces, terminal, files** | Workspace management, native terminal, file viewer | nvim/htop usable; citations open PDFs |
| **5. Delta feed** (parallel with 3–4) | P3 | No full snapshots after hello |
| **6. Push** | P5, relay, FCM, actionable notifications | Locked phone → notification → Approve works |
| **7. Android beta** | Play internal track, crash symbols, a11y | You stop using the PWA |
| **8. iOS app** | xcframework, SwiftUI translation, Keychain, push + NSE, terminal | Parity on TestFlight |
| **9. Store release** | Demo host for review, privacy forms, assets | Live on both stores |
| **10. v1.1+** | Live Activity, share target, tablet two-pane, processes, palette, widgets, UnifiedPush, embedded tailnet / Connect relay, wasm core for web | — |

Critical path: 0 → 1 → 2 → 3. Android goes first because it's the daily
phone and builds entirely on the Linux box. The core API settles while
Android is being built, so iOS is mostly translating screens that already
work.

## 10. Testing and release

- **Core:** Zig unit tests plus the contract suite (§5.4). This carries most
  of the correctness burden.
- **Android:** Compose UI tests for key screens; Maestro flows (pair, send,
  approve, terminal input, background/resume) against a fixture host;
  physical-device checks for keyboard/IME and push.
- **iOS:** XCTest/XCUITest for the same flows; the same Maestro flows (it
  supports both platforms).
- **Compatibility:** the core reads `access_protocol_version`, runtime
  capabilities and `mobile.min_client`, and both apps show a clear upgrade
  screen for either side.
- **Store review:** reviewers need a working backend. Run a **demo runtime**
  (sandboxed daemon with a scripted/mock provider) behind a public HTTPS
  proxy that meets the trusted-proxy envelope, and put its pair code in the
  review notes. Remote-terminal apps (Termius, Blink, JuiceSSH) set the
  precedent that a shell client is acceptable.
- **Release:** Gradle + Play internal/closed/production tracks; Xcode Cloud
  or GitHub macOS runners + TestFlight. Mobile versions are independent of
  the Zig desktop release train; the protocol version gates compatibility.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Two UIs drift apart | All logic and view-models live in the core; screens stay thin; a shared screen checklist (§6.1) |
| Zig cross-compile friction (NDK libc, iOS SDK sysroot) | Prove the toolchain in week 1 of Phase 1 with a "hello from Zig" `.so` (Linux) and xcframework (Mac mini) loaded by empty Compose and SwiftUI apps, before extracting real code |
| Debugging across the FFI boundary | Coarse JSON API, core behaviour covered by Zig tests, symbol upload for crash reports |
| Requiring Tailscale limits adoption | Clear onboarding; embedded tailnet or Connect relay in v1.1+ |
| Data and battery cost of snapshot pushes | P3 delta feed before beta |
| iOS/Android kill background sockets | Design for push plus foreground catch-up; never rely on background sockets |
| Lost phone holds a long-lived credential | Revocation UI (P6), app lock, P1 confinement, narrower default scopes for phones |
| iOS builds depend on the Mac mini | Agents edit Swift and the XcodeGen `project.yml` on Linux and only build, test and sign on the Mac over SSH (see the tasks file). macOS CI runners are the backup. |
| The Mac mini is on macOS 14, which caps at Xcode 16.2; App Store uploads need Xcode 26+ | Develop on Xcode 16.2 and upload from GitHub Actions macOS runners (I-12). Keep the Swift code compiling under both the 18.2 and 26 SDKs. If Xcode 16.2 can't deploy to an iOS 26 phone, upgrade the Mac (H-02 fallback) |
| Desktop refactor during extraction | Move modules into the shared package with the desktop importing them from there; desktop tests keep passing at each step |

## 12. Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Tailscale app required on the phone for v1 | ✅ Accepted |
| 2 | iOS builds on the Mac mini (`ssh mac`, plain Remote Login over the tailnet; Tailscale SSH isn't supported by the Mac's GUI Tailscale app) | ✅ Accepted; SSH works (H-01 done). The Mac stays on macOS 14 with Xcode 16.2; store builds run on GitHub Actions |
| 3 | Push relay on verde-cloud's Cloudflare account; owner buys the Play and Apple developer accounts | ✅ Accepted |
| 4 | Pairing permission presets (P8) | ✅ Full (default), Chat, Monitor; over-cap requests are clamped with a notice |
| 5 | Approve / Deny from the lock screen | ✅ Allowed; the action requires a biometric/unlock confirmation |
| 6 | Apps live in the open-source monorepo | ✅ Accepted |
