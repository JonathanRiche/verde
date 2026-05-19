# Webview Migration Audit

Objective: implement and follow the macOS handoff instructions in
`mac_webview.md` for the WKWebView browser pane. Linux and Windows are outside
the current signoff scope.

## Deliverable Checklist

- Preserve Palette and SDL3 GPU shell: implemented in the existing desktop shell;
  browser changes stay behind `packages/desktop/src/browser/controller.zig` and
  native surfaces are driven from Palette pane bounds.
- Explicit browser backend contract: implemented in
  `packages/desktop/src/browser/contract.zig`; contract tests cover
  `Controller`, `native_webview`, platform Linux WebKitGTK, platform macOS
  WKWebView, platform Windows WebView2, `cef`, and `stub`.
- Runtime kinds `native_webview`, `cef`, and `stub`: implemented in
  `packages/desktop/src/browser/types.zig` and surfaced through live IPC.
- Build option `-Dbrowser-backend=native_webview|cef|stub`: implemented in
  root `build.zig` and `packages/desktop/build.zig`; default is
  `native_webview`.
- Default `mise run dev` and `mise run build` avoid CEF downloads/package files:
  implemented in `mise.toml` and release scripts. Native release packaging has
  explicit CEF-payload postcondition checks, Linux local installs assert the
  native prefix is CEF-free, and Linux `mise run build` now runs the native
  install-payload verifier. The default `mise run setup` task runs only the
  native dependency checker. CEF remains opt-in through `dev-cef`, `build-cef`,
  and `-Dbrowser-backend=cef`.
- Backend-neutral JavaScript bridge: implemented as
  `window.__VERDE_BROWSER_IPC__`, with `__VERDE_CEF_IPC__` and `window.verde`
  aliases in native and CEF paths. App state now applies a shared bridge-origin
  policy before processing page-to-host messages.
- Smoke checklist/testing: added to `testing.md`.
- CLI/log-visible browser state: live IPC reports runtime kind, initialized
  state, presentation kind, status, visible/focused state, URL/address, last
  browser error, last page-to-host bridge message, and last eval result.
- Linux WebKitGTK path: Linux native default builds and runs on this Hyprland
  Wayland host; screenshots captured at `/tmp/verde-native-webview.png` and
  `/tmp/verde-native-webview-data.png`. The Linux backend keeps Wayland on the
  snapshot texture path by default, auto-selects the visible helper window on
  X11, and allows explicit override with `VERDE_BROWSER_LINUX_SHOW_HELPER=1`
  or `VERDE_BROWSER_LINUX_SHOW_HELPER=0`. On Wayland,
  `VERDE_BROWSER_LINUX_SHOW_HELPER=1` still stays on `snapshot_texture` unless
  `VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER=1` is also set, because the visible
  helper is known to tile separately under Hyprland. Visible-helper mode now
  routes focus, pointer, wheel, and key events through GTK/WebKit native event
  APIs instead of the snapshot path's DOM-script input fallback.
- macOS WKWebView backend: Zig wrapper and Swift shim are implemented and wired
  into macOS native-webview builds. The native wrapper forwards Palette pane
  bounds and inspector capability metadata to the platform shim. Runtime smoke,
  build, packaging, and bridge checks have been verified on macOS, but the full
  manual parity matrix is still incomplete.
- Windows WebView2 backend: Zig wrapper and C++ shim are implemented and wired
  into Windows builds. The native wrapper forwards Palette pane bounds and
  inspector capability metadata to the platform shim, but runtime parity has not
  been verified on Windows.
- CEF fallback: retained behind explicit opt-in.
- Release notes/runtime requirements: documented in
  `notes/webview_migration_release_notes.md`, `README.md`,
  `packages/desktop/README.md`, and `packages/npm/verde/README.md`.

## Prompt-To-Artifact Checklist

- Browser pane remains inside the Palette workspace layout:
  `packages/desktop/src/ui/browser.zig` still renders the dock/toolbar, and
  `packages/desktop/src/state.zig` forwards Palette-reported pane bounds through
  `Controller.setPaneBounds`.
- Host-window visibility changes are routed through `packages/desktop/src/main.zig`
  to `AppState.suspendBrowserForHostWindowHidden` and
  `AppState.resumeBrowserAfterHostWindowShown`, so visible native surfaces are
  hidden on SDL `window_hidden`/`window_minimized` and restored on
  `window_shown`/`window_restored` without changing Palette dock ownership.
- Palette modal/menu state is treated as browser-surface occlusion: `AppState`
  temporarily hides the native browser surface while project/thread/image
  modals, browser inspector menus, sidebar/open-header menus, composer menus, or
  model cascades are open, then restores it after the Palette overlay clears.
- URL bar, address normalization, toolbar navigation, refresh, focus ownership,
  bridge handling, inspector lifecycle, clipboard helpers, and event polling stay
  owned by `packages/desktop/src/state.zig` and `packages/desktop/src/ui/browser.zig`.
- SDL event routing remains in `packages/desktop/src/main.zig`; browser mouse and
  key events are forwarded through the shared browser input structs.
- Browser pane focus now calls the backend `focus()` method on pane clicks and
  calls `blur()` when Palette focus leaves the pane. Pointer events inside
  macOS/Windows `native_child_view` surfaces are treated as consumed even though
  those backends do not use synthetic SDL input injection, keeping Palette focus
  state aligned with native WebView focus. Composer, terminal, close/hide, host
  visibility, and Palette-overlay focus handoffs now route through that same
  blur path instead of directly clearing the Palette focus flag.
- Lazy startup is preserved at the facade level: `Controller.init`, host-window
  attachment, and Palette pane geometry updates do not create a backend, and
  `ensureBackend` runs only on browser use. Platform native runtime startup is
  therefore delayed until the pane opens, a browser command needs it, or
  `VERDE_OPEN_BROWSER_ON_START=1` triggers it.
- Explicit backend contract exists in
  `packages/desktop/src/browser/contract.zig`, including show/hide/shutdown,
  resize/bounds, navigation, eval/JSON bridge, history/reload, focus/blur,
  input, runtime metadata, texture/session access, and event polling.
- Runtime/build selection exists in `packages/desktop/src/browser/types.zig`,
  root `build.zig`, and `packages/desktop/build.zig` for
  `native_webview`, `cef`, and `stub`, with `native_webview` as the default.
- CEF remains available but explicit: `mise run dev-cef`, `mise run build-cef`,
  and `-Dbrowser-backend=cef -Dcef-sdk-path=...`; default `mise` tasks and
  native packaging paths avoid CEF SDK resolution and CEF payload copies.
- Backend-neutral bridge names are implemented in the inspector bundle, app
  helper scripts, Linux WebKitGTK, macOS WKWebView, Windows WebView2, and CEF,
  with compatibility aliases for `__VERDE_CEF_IPC__`, `window.verde`, and WebKit
  message handlers where applicable.
- Page-to-host bridge processing now uses the shared
  `packages/desktop/src/browser/bridge_policy.zig` policy: app and loopback
  pages are allowed by default, while arbitrary remote pages, `file:`, `data:`,
  and `about:` pages require the explicit diagnostic
  `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` override.
- macOS artifacts exist: `platform/macos_wkwebview.zig` and
  `platform/macos_wkwebview.swift`, plus WebKit/AppKit/Swift build wiring. The
  old Objective-C shim has been removed and is no longer an available WKWebView
  implementation. The Swift shim maps Palette screen bounds through the current `NSWindow`
  content-view screen rect instead of assuming `NSScreen.main`, reducing the
  multi-display/fullscreen coordinate risk called out in `webview.md`. WKWebView
  eval results serialize through JSON-compatible Swift/Foundation conversion, so
  object/array/null results follow the eval-result shape expected by the smoke
  checklist. The shim explicitly invalidates the WKWebView, script message
  handler, observers, navigation delegate, loading state, and child view before
  releasing the retained browser handle, avoiding the `WKUserContentController`
  script-handler retain cycle during shutdown. Event queuing also ignores
  callbacks after invalidation, so delayed WebKit callbacks cannot report stale
  events after the pane has been destroyed.
- Windows artifacts exist: `platform/windows_webview2.zig` and
  `platform/windows_webview2.cpp`, plus Windows build wiring and clear
  WebView2Loader/WebView2 Runtime failure reporting with `GetLastError` or
  `HRESULT` details. Runtime parity remains unverified on Windows.
- Linux artifacts exist: WebKitGTK helper build wiring, dependency checks, live
  status visibility, and Hyprland Wayland smoke evidence. This still uses
  `snapshot_texture` by default on Wayland, so exact visible in-pane Wayland
  parity is not proven. The X11/explicit visible-helper path now has native
  GTK/WebKit focus plus mouse, wheel, and key event forwarding; text input still
  keeps the DOM-script fallback.
- Smoke checklist and release criteria are documented in `testing.md`. Release
  notes and runtime requirements are documented in README files and
  `notes/webview_migration_release_notes.md`.
- The older Hyprland blur workflow in `testing.md` now uses the default
  `zig build --release=safe` command instead of an obsolete CEF-SDK build
  command, keeping local UI verification aligned with the native-webview
  default.
- Release criteria are not fully satisfied: macOS parity, Windows parity, Linux
  X11 manual/native input validation, and exact Linux Wayland in-pane
  native-surface parity remain incomplete or unverified.

## Verification Evidence

- `zig build --release=safe`: passes on Linux native-webview default after the
  Linux WebKitGTK native history/reload helper commands, visible-helper native
  focus/input commands, macOS/Windows shim cleanups, and shared bridge-origin
  policy were added.
- `zig build test --release=safe -Dbrowser-backend=stub`: passes after the
  visible-helper native focus/input commands, lazy-start regression test, and
  shared bridge-origin policy tests were added. A sandboxed run hit Zig
  `ReadOnlyFileSystem` cache access after reporting the tests passed; the same
  command passed when rerun outside the sandbox.
  This includes compile-time contract checks for the top-level browser
  controller, native-webview selector, all three platform-native wrappers, CEF,
  and stub, plus Linux presentation-selection tests for visible-helper override,
  X11, Wayland, and `GDK_BACKEND` fallback behavior.
- Native-webview wrapper now forwards every `setPaneBounds` update to the active
  platform controller instead of Linux only, so macOS WKWebView and Windows
  WebView2 can follow Palette split-pane/window resize geometry.
- Native-webview inspector support metadata now delegates to the active platform
  controller, so macOS and Windows can expose the backend-neutral inspector
  bridge once their runtime smoke tests pass.
- Native-webview initialized-state metadata now delegates to the active platform
  controller instead of treating wrapper allocation as runtime initialization,
  keeping live status accurate before a macOS/Windows child view has been
  created.
- Browser facade lazy-start now caches host-window handles and Palette pane
  bounds without creating a backend. macOS WKWebView and Windows WebView2
  `setHostWindow` also only store the host handle, so startup attachment does
  not initialize those runtimes before browser use.
- Browser startup smokes can now set `VERDE_BROWSER_START_URL` alongside
  `VERDE_OPEN_BROWSER_ON_START=1`; the URL is normalized through the same
  startup path as the URL bar and then restored through the lazy browser-open
  flow. This gives CLI-visible navigation evidence without manual URL entry.
- Browser live status now includes `last_js_message` and `last_eval_result`,
  exposing the existing app-state bridge/eval records through the CLI so smoke
  runs can verify page-to-host messages and script results without inspecting
  Palette UI state.
- Browser page-to-host bridge messages are now guarded by a shared origin policy
  before app state handles clipboard, inspector, or generic `js_message`
  payloads. The policy allows `app://`, `localhost`, `127.0.0.1`, and `[::1]`
  pages by default, and has unit coverage for loopback, spoofed localhost, and
  explicit diagnostic override cases. A targeted sandboxed
  `zig test packages/desktop/src/browser/bridge_policy.zig` hit Zig
  `ReadOnlyFileSystem` cache access, and the same command passed outside the
  sandbox with both policy tests passing.
- A bridge policy GUI smoke launched a `data:` page that called
  `window.__VERDE_BROWSER_IPC__.postMessage(...)` without
  `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE`; escalated `verde live status --json`
  reported `last_error: "Browser bridge message rejected by origin policy."` and
  `last_js_message: null`. The same style of smoke with
  `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` reported `last_error: null` and
  `last_js_message` containing the `allowed-data-bridge` payload.
- Live IPC and CLI now expose `browser.eval` and `browser.postJson` through
  `verde live browser eval --script ...` and
  `verde live browser post-json --json-payload ...`, so backend eval and
  host-to-page JSON dispatch can be exercised repeatedly after startup.
- Browser startup smokes can also set `VERDE_BROWSER_START_EVAL`; the app runs
  that script once after the startup page emits `document_loaded`, and the result
  is exposed through live status as `last_eval_result`.
- A controller unit test now guards that `setHostWindow`, `setPaneBounds`, and
  `resizePane` do not create a backend or mark the runtime initialized before
  browser use.
- Shared browser focus routing now explicitly bridges Palette pane focus to the
  backend `focus()`/`blur()` contract. `zig build test --release=safe
  -Dbrowser-backend=stub`, `zig build --release=safe`, and `git diff --check`
  pass after this focus/blur hardening. A follow-up audit found and replaced the
  remaining direct Palette focus clear paths for composer, terminal, close/hide,
  host visibility, and Palette overlay transitions; after that cleanup, only the
  initializer, centralized focus helpers, and backend `.closed` event path write
  `browser_pane_focused` directly.
- macOS WKWebView page input now stops SDL text input while the native child
  browser pane owns keyboard focus. This keeps AppKit/WebKit as the only text
  delivery path for focused page inputs, while leaving SDL text input active for
  the Palette URL bar, modal fields, composer, and terminal. `mise run build`,
  `git diff --check`, script syntax checks, and
  `scripts/dev/check-macos-wkwebview.sh /Users/jhonellebriche/Applications/Verde.app`
  passed after this duplicate-keypress fix; physical key evidence is still
  required before macOS sign-off.
- The macOS manual input evidence validator now supports the checklist modes
  `text`, `textarea`, `editing`, `clipboard`, `modifier-click`,
  `modifier-wheel`, `ime`, and `any`. It decodes the captured
  `verdeInputSmokeResult()` payload, verifies Verde was frontmost before or
  during capture, and checks mode-specific DOM state/events. The `editing` mode
  requires physical keydown events for ArrowLeft, ArrowRight, Home, End,
  Backspace, Delete, Enter, Tab, and Escape. `bash -n
  scripts/dev/validate-macos-wkwebview-input-evidence.sh` passed, and running
  the validator against the known bad terminal-frontmost evidence file correctly
  failed because `frontmostAtCapture` was `ghostty` and `eventCount` was `0`.
- A fresh desktop automation probe on 2026-05-19 confirmed that this session
  still cannot supply trustworthy physical input evidence: `usecomputer window
  list --json` returned `[]`, `usecomputer desktop list --windows --json`
  returned empty `displays` and `windows`, and `usecomputer screenshot
  /tmp/verde-desktop-probe.png --json` failed with `CAPTURE_FAILED`. The
  remaining physical parity items therefore require a direct hands-on run of the
  manual evidence scripts rather than agent-side desktop automation.
  A later narrow System Events keystroke probe launched the installed app on
  `input-regression.html`, focused the smoke input through live eval, and sent
  `abc123`, but the capture helper correctly refused to write evidence because
  macOS still reported `ghostty` as frontmost before and during capture. That
  confirms the automated terminal session still cannot produce acceptable
  foreground physical-input evidence.
- `scripts/dev/run-macos-wkwebview-manual-input-checklist.sh` now guides a
  tester through the remaining physical text, textarea, editing-key, Command-key
  clipboard, modifier-click, modifier-wheel, and optional IME checks. For each
  step it waits for Verde to become the frontmost macOS app, gives a timed input
  window, captures a tagged evidence JSON file, validates that file with the
  matching mode, and prints the evidence paths for the final audit summary.
- The manual input/status capture helpers now refuse to write sign-off evidence
  unless Verde was frontmost either immediately before capture or at capture
  time. This prevents the stale Terminal-frontmost/empty-input failure mode from
  adding more misleading JSON files to `notes/mac-webview-smoke/manual-evidence`;
  `VERDE_MAC_WEBVIEW_ALLOW_NONFRONTMOST_CAPTURE=1` exists only for local
  debugging and is not accepted as sign-off evidence by the validators.
- `scripts/dev/capture-macos-wkwebview-status-evidence.sh` and
  `scripts/dev/validate-macos-wkwebview-status-evidence.sh` cover the remaining
  non-DOM-input manual evidence: physical inspector Point/Draw Box/Draw Freeform
  gestures via `browser.last_js_message`, and hardware mouse back/forward
  buttons via live URL/address validation. The status validator also checks that
  the captured app was frontmost, the runtime is `native_webview`, the
  presentation is `native_child_view`, browser status is `Ready`, and
  `last_error` is null.
- `scripts/dev/run-macos-wkwebview-manual-status-checklist.sh` guides those
  non-DOM-input checks: it optionally captures and validates physical inspector
  Point, Draw Box, Draw Freeform, hardware mouse Back, and hardware mouse
  Forward evidence using the status capture/validator helpers.
- `scripts/dev/summarize-macos-wkwebview-manual-evidence.sh` turns the collected
  manual evidence JSON files into the markdown table expected by
  `notes/mac-webview-smoke/manual-input-checklist.md`. The generated table marks
  missing evidence as `missing` and non-frontmost/non-ready evidence as `fail`,
  and it re-checks mode-specific DOM/status expectations for text, textarea,
  editing keys, clipboard, modifiers, IME, inspector selections, and mouse
  back/forward rows, so it cannot silently promote stale or weak capture files
  into macOS sign-off.
- `scripts/dev/check-macos-wkwebview-ready.sh` now runs `bash -n` over every
  macOS manual evidence helper and fails if any helper is not executable before
  it runs stub tests, local install, package checks, and the installed runtime
  smoke. This keeps `mise run check-mac-webview` green only when the manual
  sign-off tooling is also usable.
- Completion audit on 2026-05-19 reran `mise run check-mac-webview` and
  `scripts/dev/run-macos-wkwebview-manual-signoff.sh --dry-run`; both passed.
  The generated manual evidence summary still reports `Text input abc123` as
  `fail` because the only available typing evidence was captured while `ghostty`
  was frontmost with empty input and zero DOM events, and all other physical
  parity rows are `missing`. The macOS goal therefore remains blocked only on
  the direct hands-on physical evidence pass, not on build/package/runtime
  readiness.
- `scripts/dev/run-macos-wkwebview-manual-signoff.sh` now provides the
  one-command hands-on path for the remaining proof: it starts or reuses the
  localhost smoke server, launches the installed Verde app with
  `VERDE_OPEN_BROWSER_ON_START=1` and the input smoke URL, runs the guided
  input and status checklists, and prints the generated evidence summary table.
  By default it writes each full signoff run to a fresh timestamped directory
  under `notes/mac-webview-smoke/manual-evidence/runs/` and prints the exact
  run-specific completion checker command, so old failed captures remain
  available for audit history without polluting a new signoff run.
  Its `--dry-run` mode verifies the installed app path, smoke page, Python
  dependency, startup URL, and planned evidence directory without creating an
  empty run directory, launching Verde, or waiting for physical input;
  `scripts/dev/check-macos-wkwebview-ready.sh` runs that dry-run before the
  automated macOS build/package/runtime gates.
- macOS WKWebView shutdown now calls an explicit Swift invalidation path before
  releasing the retained browser object, so script handlers and KVO
  observers are removed even if WebKit's content controller would otherwise
  retain the browser as its message handler. Delayed WebKit callbacks after
  invalidation are ignored by the shim's event queue.
- Windows WebView2 readiness now reports true only after CoreWebView2 is ready,
  and synchronous loader/environment startup failures no longer emit a later
  `opened` event that can mask the error as `Ready`.
- Windows WebView2 loader, environment, and controller failures now include
  `GetLastError` or `HRESULT` details in the queued `.failed` event so missing
  `WebView2Loader.dll` and missing/broken runtime cases are distinguishable in
  live status/logs.
- Windows WebView2 now queues host `eval` and `postJson` calls until the async
  WebView2 controller has a successfully loaded document, avoiding transient
  startup/restore failures for inspector and bridge commands.
- Windows WebView2 now tracks whether the backend initialized COM and balances
  successful `CoInitializeEx` calls with `CoUninitialize` after releasing
  WebView2 COM objects, including the host-window creation failure path.
- Windows WebView2 now retains the backend object across async environment,
  controller, and script callbacks; destroy marks the backend as shutting down
  and releases the object, loader DLL, and COM apartment only after outstanding
  async callbacks finish. This reduces use-after-free risk during shutdown while
  WebView2 startup or script execution is still pending.
- Host window lifecycle handling now hides native browser surfaces when SDL
  reports the app window hidden/minimized and restores them when SDL reports the
  window shown/restored.
- Palette overlay occlusion handling now hides native browser surfaces while
  Palette-owned modals and menus are open, so child/overlay webviews cannot draw
  above modal, menu, sidebar, or toolbar UI. These temporary hides suppress the
  backend `.closed` event without flipping live status to `Hidden`, so the dock
  remains accurately reported as visible while the surface is occluded.
- Native-webview `navigate()` now shows the platform surface when navigation is
  used to restore or open a hidden browser pane, matching the CEF/stub contract
  that navigation keeps the pane visible.
- Linux WebKitGTK history and reload controls now route through helper IPC
  commands backed by native `webkit_web_view_go_back`,
  `webkit_web_view_go_forward`, and `webkit_web_view_reload` calls instead of
  the JavaScript fallback path.
- Linux visible-helper focus and input now route through helper IPC commands
  backed by native GTK/WebKit focus plus GDK motion, button, smooth-scroll, and
  key events. The snapshot texture path keeps the existing DOM-script input
  fallback, and text insertion still uses that fallback until a GTK IME path is
  added.
- Linux visible-helper selection now refuses the known-bad Wayland helper-window
  presentation unless `VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER=1` is also
  set, so `VERDE_BROWSER_LINUX_SHOW_HELPER=1` cannot accidentally move the
  current Hyprland Wayland session off the safe `snapshot_texture` path.
- The opt-in CEF fallback also exposes helper IPC commands for back, forward,
  and reload, backed by native CEF `CanGoBack`/`GoBack`,
  `CanGoForward`/`GoForward`, and `Reload` calls instead of routing those
  backend methods through JavaScript eval.
- Pre-initialization native-webview metadata now uses the same configured
  presentation/support logic as the active backend: Linux reports
  `helper_window` before startup when an X11 session selects the visible helper,
  and `supportsPopout` no longer flips from true before startup to false after
  backend creation. Forced Wayland helper mode requires the additional
  `VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER=1` diagnostic flag.
- `zig build --release=safe -Dbrowser-backend=cef -Dcef-stub-preview=true`:
  passes after the backend-selection metadata, host-window lifecycle, and
  Palette-overlay occlusion changes, and after CEF helper-backed `hide()`
  stopped locally queuing a duplicate `.closed` event when the helper already
  reports closure.
- `zig build --release=safe -Dbrowser-backend=cef
  -Dcef-sdk-path=/home/rtg/.cache/verde/cef-sdk/cef_binary_146.0.9+g3ca6a87+chromium-146.0.7680.165_linux64_minimal`:
  passes with the cached Linux CEF SDK, compiling and linking
  `verde-browser-cef` and `verde-browser-cef-process` after the native CEF
  history/reload helper commands were added.
- Release script syntax check passes:
  `bash -n scripts/dev/check-desktop-build-deps.sh scripts/release/install-linux-local.sh scripts/release/install-linux-local-cef.sh scripts/release/install-macos-local.sh scripts/release/package-linux.sh scripts/release/package-macos-app.sh`.
- Native install payload verifier passes:
  `scripts/dev/check-native-webview-install.sh` after the backend-selection
  metadata changes, Linux WebKitGTK helper-command updates, and a full cached
  CEF SDK build. It also passes after the shared bridge-origin policy change. A
  sandboxed rerun hit Zig `ReadOnlyFileSystem` cache access, then the same
  verifier passed when rerun outside the sandbox.
- Linux local install script now asserts no CEF payload is present in the
  install prefix when `VERDE_BROWSER_BACKEND` is not `cef`; `bash -n` passes for
  `scripts/release/install-linux-local.sh`, the native install verifier, the
  Linux package script, and the explicit CEF local installer.
- Updated Linux `mise run build` command body passes:
  `bash scripts/dev/check-desktop-build-deps.sh && zig build --release=safe
  -Dbrowser-backend=native_webview && scripts/dev/check-native-webview-install.sh`.
  This verifies the default Linux build remains native-webview and that the
  install payload excludes CEF files.
- The actual `mise run setup` task passes outside the sandbox; it runs
  `bash scripts/dev/check-desktop-build-deps.sh` and does not invoke
  `cef-common.sh`, `verde_cef_ensure_sdk`, or any CEF SDK download/setup path. A
  sandboxed attempt hung in the command wrapper and was stopped before rerunning
  the same task outside the sandbox.
- The actual `mise run build` task also passes on this Linux host after the
  native-webview default and focus/blur cleanup; it runs the native dependency
  check, builds the desktop app, and finishes with
  `native webview install payload check passed`.
- The actual `mise run dev` task also launches the default native-webview path
  without CEF setup when run with `VERDE_OPEN_BROWSER_ON_START=1`; escalated
  `verde live status --json` reported `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`,
  `address: about:blank`, and `last_error: null`.
- A startup-navigation smoke launched the native default with
  `VERDE_OPEN_BROWSER_ON_START=1` and
  `VERDE_BROWSER_START_URL=data:text/html,%3Ctitle%3EVerdeSmoke%3C/title%3E%3Ch1%3EVerdeSmoke%3C/h1%3E`;
  escalated `verde live status --json` reported `runtime_kind:
  native_webview`, `presentation_kind: snapshot_texture`,
  `runtime_initialized: true`, `status: Ready`, `visible: true`, the same
  `data:` URL in both `url` and `address`, and `last_error: null`.
- A backend-neutral bridge smoke launched a `data:` page that called
  `window.__VERDE_BROWSER_IPC__.postMessage(...)`; escalated
  `verde live status --json` reported `last_js_message` containing the
  `verde-smoke` payload, with `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `status: Ready`, and
  `last_error: null`.
- A startup eval smoke launched a `data:` page with title `EvalSmoke` and
  `VERDE_BROWSER_START_EVAL='JSON.stringify({title:document.title,url:location.href})'`;
  escalated `verde live status --json` reported `last_eval_result` containing
  the `EvalSmoke` title and data URL, with `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `status: Ready`, and
  `last_error: null`.
- A live browser command smoke launched a `data:` page with title `LiveEval`,
  then ran `verde live browser eval --script
  'JSON.stringify({title:document.title,url:location.href,source:"live-browser-eval"})'
  --json`; `verde live status --json` reported `last_eval_result` containing
  the `live-browser-eval` payload. `verde live browser post-json
  --json-payload '{"source":"live-browser-post-json","ok":true}' --json`
  returned `accepted: true`, and `verde live capabilities --json` listed
  `browser.eval` and `browser.postJson`.
- Live browser status includes `presentation_kind`, so Linux reports whether the
  native webview path is currently `snapshot_texture` or the diagnostic
  `helper_window` mode instead of hiding that distinction behind
  `runtime_kind: native_webview`.
- Linux GUI smoke on this Hyprland Wayland host launched the native default with
  `VERDE_OPEN_BROWSER_ON_START=1`; `verde live status --json` reported
  `runtime_kind: native_webview`, `presentation_kind: snapshot_texture`,
  `runtime_initialized: true`, `visible: true`, `url: about:blank`, and
  `last_error: null`.
- Fresh Linux GUI smoke after the native `navigate()` visibility fix launched
  with explicit Wayland display environment plus `VERDE_OPEN_BROWSER_ON_START=1`;
  `verde live status --json` reported `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`, `address: about:blank`,
  and `last_error: null`.
- A later Linux Wayland GUI smoke after the Linux helper-command, CEF fallback,
  macOS shim, and Windows shim cleanups again launched with explicit Wayland
  display environment plus `VERDE_OPEN_BROWSER_ON_START=1`; escalated
  `verde live status --json` reported `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`, `address: about:blank`,
  and `last_error: null`.
- A Linux Wayland GUI smoke after the shared focus/blur hardening again launched
  with explicit Wayland display environment plus `VERDE_OPEN_BROWSER_ON_START=1`;
  escalated `verde live status --json` reported `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`, `address: about:blank`,
  and `last_error: null`.
- A Wayland safety smoke with
  `VERDE_BROWSER_LINUX_SHOW_HELPER=1 VERDE_OPEN_BROWSER_ON_START=1` launched
  successfully after the helper guard was added; escalated
  `verde live status --json` still reported `presentation_kind:
  snapshot_texture`, `runtime_initialized: true`, `status: Ready`,
  `visible: true`, `url: about:blank`, `address: about:blank`, and
  `last_error: null`.
- An X11-style smoke under Xwayland launched with
  `VERDE_BROWSER_LINUX_SHOW_HELPER=1`, `XDG_SESSION_TYPE=x11`,
  `GDK_BACKEND=x11`, and `SDL_VIDEODRIVER=x11`; escalated
  `verde live status --json` reported `runtime_kind: native_webview`,
  `presentation_kind: helper_window`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`,
  `address: about:blank`, and `last_error: null`. A screenshot was captured at
  `/tmp/verde-x11-helper.png` and showed the Palette shell visible without the
  helper covering toolbar/sidebar/chat UI. This is metadata and visual evidence,
  not a full X11 navigation/input parity pass.
- A deeper X11-style helper smoke launched a `data:` page with
  `VERDE_BROWSER_START_URL` and
  `VERDE_BROWSER_START_EVAL='JSON.stringify({title:document.title,url:location.href,phase:"startup-eval"})'`
  under `VERDE_BROWSER_LINUX_SHOW_HELPER=1`, `XDG_SESSION_TYPE=x11`,
  `GDK_BACKEND=x11`, and `SDL_VIDEODRIVER=x11`. Escalated
  `verde live status --json` reported `presentation_kind: helper_window`,
  `status: Ready`, matching `url`/`address`, `last_error: null`,
  `last_js_message` containing the startup `x11-helper-startup` bridge payload,
  and `last_eval_result` containing the startup eval result. A follow-up
  `verde live browser eval --script ... --json` updated `last_eval_result` with
  the `live-eval-helper` payload. A page listener installed through live eval
  then echoed `verde live browser post-json --json-payload
  '{"source":"live-helper-post-json","ok":true}' --json` back through
  `last_js_message`. This verifies helper-window navigation/eval/bridge plumbing
  through live IPC, but still does not replace manual native click/key/wheel
  parity testing.
- An X11-style helper input smoke launched a page with a large text input under
  `VERDE_BROWSER_LINUX_SHOW_HELPER=1`, `XDG_SESSION_TYPE=x11`,
  `GDK_BACKEND=x11`, and `SDL_VIDEODRIVER=x11`. Hyprland reported the SDL Verde
  window and the `Verde-browser-linux` helper as Xwayland clients, and live
  status reported `presentation_kind: helper_window`. A desktop click into the
  helper surface moved DOM focus to the input (`active: "q"` in
  `last_eval_result`), and a screenshot was captured at
  `/tmp/verde-x11-input-helper.png`. Text delivery through `wtype`,
  `ydotool type`, and raw keycodes did not change the input value, so this is
  only pointer/focus evidence; X11 text/key input parity remains unverified.
- An X11-style helper keyboard-scroll smoke launched a tall scrollable page under
  the same helper-window environment. Live eval reported baseline `scrollY: 0`;
  after compositor-focusing the helper, clicking the page, and sending three
  PageDown key events with `ydotool`, live eval still reported `scrollY: 0`.
  `ydotool click --help` does not expose a direct wheel event, so wheel parity
  was not automated in this environment. This keeps X11 key/wheel scrolling in
  the unverified gap bucket.
- A follow-up Hyprland/Xwayland geometry smoke found that the visible helper's
  full-monitor geometry came from startup navigation bypassing cached pane
  bounds and from `gtk_widget_set_size_request` publishing a
  `WM_NORMAL_HINTS` minimum size of `2560x1440` under `GDK_SCALE=2`. The
  retained fix applies cached pane bounds before backend `navigate()`, avoids
  child size requests in visible-helper mode, and starts visible-helper windows
  with a 1x1 fallback default. A fresh smoke reported
  `presentation_kind: helper_window`, `status: Ready`, helper
  `WM_NORMAL_HINTS` minimum size `0x0`, `_NET_WM_OPAQUE_REGION` `640x400`, and
  Hyprland geometry `[960,353]` size `[640,400]` instead of the earlier
  full-monitor `[0,0]` size `[2560,1440]`. A screenshot was captured at
  `/tmp/verde-x11-helper-sized.png`. This improves the diagnostic helper
  substantially, but Hyprland still centers the utility window instead of
  honoring the requested pane move, so exact in-pane helper geometry remains
  unproven. Attempts to expose the helper as a normal managed toplevel exited
  before the live server started, and a popup variant stayed hidden at `0x0`,
  so neither hint experiment was kept.
- A subsequent retained X11-host hint pass forwards the SDL X11 window id to
  the WebKitGTK helper and applies `WM_TRANSIENT_FOR` against that host window.
  The fresh smoke still reported host geometry `[1287,38]` size `[1261,1030]`
  and helper geometry `[960,353]` size `[640,400]`; `xprop` confirmed
  `WM_TRANSIENT_FOR(WINDOW): window id # 0x800031`,
  `WM_NORMAL_HINTS` minimum size `0x0`, and `_NET_WM_OPAQUE_REGION` `640x400`.
  Live status remained healthy with `runtime_kind: native_webview`,
  `presentation_kind: helper_window`, `status: Ready`, `visible: true`,
  `url: about:blank`, and no `last_error`. A screenshot was captured at
  `/tmp/verde-x11-helper-transient.png`. The hint is therefore present, but
  Hyprland/Xwayland still does not place the diagnostic helper in the pane.
- A live lazy-start smoke without `VERDE_OPEN_BROWSER_ON_START` launched the app
  on this Hyprland Wayland host and queried `verde live status --json` before
  opening the browser; browser status reported `runtime_kind: native_webview`,
  `presentation_kind: snapshot_texture`, `runtime_initialized: false`,
  `status: Hidden`, `visible: false`, and `last_error: null`.
- After the GUI smoke, process cleanup was confirmed with
  `pgrep -af '[v]erde$|[v]erde-browser-linux'`, which returned no remaining app
  or Linux helper process.
- `git diff --check`: passes.
- Root native install-prefix verification passes:
  `zig build --release=safe -p /tmp/verde-root-native-prefix.* -Dbrowser-backend=native_webview`
  installed `verde`, `verde-browser-linux`, `libfff_c.so`, and SDL runtime
  files, with no `verde-browser-cef`, `libcef.so`, Chromium pak files, CEF
  locales, or CEF helper/process files.
- Full Linux tarball packaging was not executed because this checkout does not
  currently have production Node runtime dependencies under
  `node_modules/@cursor/sdk`; `scripts/release/package-linux.sh` would stop
  there before creating a tarball.
- Root build now forwards `-Dtarget` into `packages/desktop`, allowing
  cross-target compile attempts to reach the desktop build.
- `zig build --release=safe -Dtarget=x86_64-windows-gnu -Dbrowser-backend=native_webview`
  reaches the Windows WebView2 C++ source, including the queued-command
  readiness, COM lifecycle, detailed WebView2 failure-reporting changes, and
  async callback lifetime hardening, then fails at missing cross-link
  libraries/artifacts (`fff_c`, `SDL3`, `SDL3_ttf`) on this Linux host.
- `zig build --release=safe -Dtarget=aarch64-macos -Dbrowser-backend=native_webview`
  reaches the macOS desktop build, then fails before the WKWebView shim at
  missing cross-build prerequisites in Ghostty `simdutf`/macOS libc headers and
  `libfff_c.dylib`; this remains true after the WKWebView bounds-conversion,
  eval-result serialization, explicit invalidation, and post-invalidation event
  guard cleanup.
- macOS local native-webview build on this Mac:
  `zig build --release=safe -Dbrowser-backend=native_webview` passed on
  2026-05-19 after replacing the active WKWebView shim with Swift and linking
  the Swift object from `packages/desktop/build.zig`.
- macOS stub tests:
  `zig build test --release=safe -Dbrowser-backend=stub` passed on 2026-05-19.
- macOS setup:
  `mise run setup` passed on 2026-05-19 and ran only the native desktop
  dependency checker; it did not download CEF.
- macOS package/install:
  `mise run build` passed on 2026-05-19 and installed
  `/Users/jhonellebriche/Applications/Verde.app`. The package path used
  `native_webview`, emitted only local warnings that `xcrun metal` was
  unavailable and existing checked-in metallibs were reused, and did not invoke
  CEF SDK download/setup. It passed again after removing the stale Objective-C
  `macos_wkwebview.m` shim, proving the install/package path now builds from
  the Swift-only WKWebView implementation.
- macOS packaging fix:
  `packages/desktop/build.zig` now gives the macOS executable
  `headerpad_max_install_names`, and `scripts/release/fixup-macos-app.sh`
  neutralizes Swift's tiny non-bitcode `__LLVM,__swift_modhash` segment before
  dependency rewrite. This lets `install_name_tool` rewrite dependencies instead
  of failing with `the __LLVM segment too small`.
- macOS package dependency evidence:
  `find /Users/jhonellebriche/Applications/Verde.app -name 'Chromium Embedded Framework.framework' -o -name 'verde-browser-cef' -o -name 'verde-browser-cef-process' -o -name 'libcef*' -o -name '*.pak' -o -name 'locales'`
  returned no files. `otool -L
  /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` reported
  app-local/native references for `@executable_path/libfff_c.dylib`,
  `@rpath/SDL3.framework/Versions/A/SDL3`, and
  `@executable_path/libSDL3_ttf.0.dylib`. A recursive `otool -L` grep found no
  `/opt/homebrew`, `/usr/local`, or repo-local dependency references in
  `Contents/MacOS`. `codesign --verify --strict --verbose=2
  /Users/jhonellebriche/Applications/Verde.app` passed.
- macOS installed-app runtime smoke:
  launching
  `VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=about:blank
  /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` and then
  querying live status reported `runtime_kind: native_webview`,
  `presentation_kind: native_child_view`, `runtime_initialized: true`,
  `status: Ready`, `visible: true`, `url: about:blank`, and
  `last_error: null`.
- macOS `dev-mac` runtime smoke:
  running
  `VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=about:blank mise run dev-mac`
  on this Mac built and launched the repo-local binary
  `packages/desktop/zig-out/bin/verde` with native WKWebView; the command output
  showed the native build and did not invoke `cef-common.sh`, `cef_binary`, or
  any CEF download/setup path. Querying
  `./packages/desktop/zig-out/bin/verde live status --json` reported
  `runtime_kind: "native_webview"`, `presentation_kind: "native_child_view"`,
  `runtime_initialized: true`, `status: "Ready"`, `visible: true`,
  `url: "about:blank"`, and `last_error: null`.
- macOS WKWebView focus/input fix:
  a native child-view focus regression was found where clicking into a WKWebView
  page input let the page receive text while Verde's URL field also remained
  logically focused and appended the same typed text. The Swift shim now exports
  `verde_macos_webview_has_focus`, and Palette key/text routing asks the active
  controller whether the AppKit first responder is inside the WKWebView before
  URL-field handlers consume events. Fresh installed-app evidence on
  `http://127.0.0.1:8876/` reported
  `last_eval_result: "{\"active\":\"input\",\"input\":\"abc123\",\"href\":\"http://127.0.0.1:8876/\"}"`
  and live status showed `address_focused: false`, proving page text input no
  longer duplicates into the address field.
- macOS duplicate text-input regression fix:
  after the native focus fix, user testing reported every keypress/letter press
  doubling in the macOS app. The previous macOS duplicate `text_input`
  suppression only caught duplicate SDL text events with exactly matching
  timestamps. `packages/desktop/src/main.zig` now suppresses the same text when
  it repeats within a 30 ms macOS text-input window, which matches separate SDL
  text events produced by one physical keypress without blocking normal typing.
  A follow-up fix also stops forwarding SDL `key_down`/`key_up` into the browser
  when the native WKWebView already owns AppKit first-responder focus; AppKit is
  responsible for delivering those printable keys to WKWebView. A later hardening
  pass also stopped Verde from emulating browser Command-key clipboard shortcuts
  while WKWebView is native-focused, so real Command+A/C/X/V use WebKit/AppKit
  instead of a second host-side DOM insertion/copy path. The Swift shim no longer
  focuses WKWebView merely because the surface is shown, and its `blur()` target
  is now a tiny `NSView` that accepts first responder so Palette can reliably
  move AppKit focus away from the child view. Browser polling also enforces the
  app invariant that a native-focused WKWebView clears the Palette address-field
  focus flag.
  `zig build --release=safe -Dbrowser-backend=native_webview`, `mise run
  build`, `git diff --check`, and strict codesign verification of
  `/Users/jhonellebriche/Applications/Verde.app` passed after this fix. The
  rebuilt app was installed at `/Users/jhonellebriche/Applications/Verde.app`.
  A follow-up live smoke launched
  `http://127.0.0.1:8876/input-regression.html` and confirmed the page was
  ready with `window.verdeInputSmokeResult()` returning active element
  `smoke-input` and empty initial values, but this execution session could not
  deliver real OS keystrokes to the foreground app: `usecomputer window list`
  returned no windows, `screencapture` produced a black frame, and both
  `usecomputer type` and System Events keystrokes left the DOM input empty.
  Manual real-keypress verification therefore remains required before closing
  the text-input parity item.
  After the final focus-state hardening pass, a fresh installed-app smoke against
  `http://127.0.0.1:8879/input-regression.html` reported
  `focus.native_browser_surface_focused: true`,
  `focus.browser_address_focused: false`, `runtime_kind: "native_webview"`,
  `presentation_kind: "native_child_view"`, `status: "Ready"`, and
  `last_error: null`; evaluating `verdeInputSmokeResult()` returned an empty
  focused `smoke-input` baseline with no browser error.
- macOS manual input smoke page:
  `notes/mac-webview-smoke/input-regression.html` now captures the remaining
  manual input parity evidence in one page. It logs `keydown`, `keyup`,
  `beforeinput`, `input`, `paste`, `copy`, `cut`, `compositionstart`,
  `compositionupdate`, `compositionend`, click modifier state, wheel modifier
  state, scroll position, active element, and input/textarea selection ranges.
  The page still exposes `window.verdeInputSmokeResult()` for live status/eval
  checks. A WKWebView sanity run against
  `http://127.0.0.1:8879/input-regression.html` reported
  `last_eval_result:
  "{\"active\":\"smoke-input\",\"input\":\"\",\"inputSelection\":[0,0],\"textarea\":\"\",\"textareaSelection\":[0,0],\"clickTargetFocused\":false,\"scrollTop\":0,\"eventCount\":0,\"recentEvents\":[],\"url\":\"http://127.0.0.1:8879/input-regression.html\"}"`
  with `runtime_kind: "native_webview"`, `presentation_kind:
  "native_child_view"`, `status: "Ready"`, and `last_error: null`.
  `notes/mac-webview-smoke/manual-input-checklist.md` records the exact manual
  pass required for real keypresses, editing keys, Command-key clipboard
  shortcuts, modifier click/wheel, IME/composition, and physical inspector
  gestures, including a copyable summary table for final audit evidence.
  `notes/mac-webview-smoke/readiness-matrix.md` maps the `mac_webview.md`
  macOS requirements to current proof, partial proof, and remaining manual
  sign-off items.
  `scripts/dev/check-macos-wkwebview.sh
  /Users/jhonellebriche/Applications/Verde.app` passed on 2026-05-19; it checks
  Swift C exports against Zig externs, confirms `packages/desktop/build.zig`
  wires the active macOS native-webview app/test build to Swift, confirms the
  stale Objective-C shim file is absent, confirms the macOS install/package
  scripts default to `native_webview` and guard CEF SDK setup behind the explicit
  `cef` backend path, verifies the installed app has no CEF/Chromium payloads,
  verifies executable bundle binaries do not link CEF/Chromium, Homebrew, or
  repo-local dependency paths, verifies the installed `Contents/MacOS/verde`
  binary is newer than the Swift shim and exports the required Swift C ABI
  symbols, and runs strict codesign verification.
  `scripts/dev/smoke-macos-wkwebview-runtime.sh
  /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` passed on
  2026-05-19; it launches the installed app with
  `VERDE_OPEN_BROWSER_ON_START=1`, waits for live status, verifies
  `runtime_kind: "native_webview"`, `presentation_kind: "native_child_view"`,
  `status: "Ready"`, `visible: true`, `url: "about:blank"`, and
  `last_error: null`, then cleans up the process it started.
  `mise run check-mac-webview` also passed on 2026-05-19; it runs
  `scripts/dev/check-macos-wkwebview-ready.sh`, which executes
  `zig build test --release=safe -Dbrowser-backend=stub`,
  `scripts/release/install-macos-local.sh`, the macOS build/package checker,
  installed-binary symbol validation, and runtime smoke together, then reports
  the remaining manual physical-input sign-off items.
  `mac_webview.md` has been updated from the original pre-Swift handoff into a
  current macOS sign-off document: it names the Swift-only implementation,
  points at `mise run check-mac-webview` as the automated gate, and lists the
  remaining manual physical-input parity blockers.
  A follow-up attempt to automate physical-style input on this Mac launched the
  installed app on `http://127.0.0.1:8879/input-regression.html`; live status
  reported `focus.native_browser_surface_focused: true`,
  `focus.browser_address_focused: false`, `status: "Ready"`, and
  `last_error: null`. Posting `abc123` through Swift `CGEvent` HID events and
  through `System Events` AppleScript both left
  `window.verdeInputSmokeResult()` unchanged with `input: ""` and
  `eventCount: 0`. This shows the current automation channel cannot prove real
  OS key delivery, so the physical input parity items remain manual-only.
  A subsequent AppKit diagnostic export was added to `live status` as
  `browser.macos_appkit_diagnostics`. On 2026-05-19, the installed smoke app
  on `http://127.0.0.1:8879/input-regression.html` reported that the SDL-created
  NSWindow and WKWebView were present and attached:
  `windowPresent: true`, `windowIsVisible: true`, `windowCanBecomeKey: true`,
  `windowCanBecomeMain: true`, `webViewWindowAttached: true`,
  `containerWindowAttached: true`, and `firstResponder: "WKWebView"`. The same
  diagnostic, queried from the terminal, reported `appActive: false`,
  `runningApplicationActive: false`, `windowIsKey: false`, and
  `windowIsMain: false`; System Events simultaneously reported
  `name:verde, frontmost:false, visible:true, windowCount:0`. This narrows the
  remaining manual-input blocker to foreground OS key delivery for the app in
  the current test session, not to missing WKWebView attachment or DOM focus.
- macOS WKWebView focused shortcut hardening:
  a follow-up smoke found that AppKit could own first responder focus inside the
  WKWebView while Palette's `browser_pane_focused` flag remained false because
  the native child view consumed the initial click. Live IPC and CLI expose
  focused-element helper paths through `browser.selectAllFocused`,
  `browser.pasteTextFocused`, `browser.copyFocused`, and `browser.cutFocused`
  (`verde live browser select-all`, `paste-text`, `copy`, and `cut`) so they can
  be smoked without fragile physical-key automation. Against
  `http://127.0.0.1:8877/input-regression.html` in the installed WKWebView app,
  `paste-text --text AlphaBeta` produced
  `last_eval_result: "{\"value\":\"AlphaBeta\",\"selection\":[9,9],\"active\":\"smoke-input\"}"`.
  Running `select-all` then `copy` preserved the input value and reported
  `last_eval_result: "{\"value\":\"AlphaBeta\",\"selection\":[0,9],\"verdeSelection\":\"AlphaBeta\"}"`.
  Running `cut` then evaluating the page reported
  `last_eval_result: "{\"value\":\"\",\"selection\":[0,0],\"verdeSelection\":\"AlphaBeta\"}"`.
  The same copy helper on a `file://` page selected text but hit
  `Browser bridge message rejected by origin policy`, which is expected because
  browser bridge messaging is intentionally limited to trusted/app and localhost
  origins unless the untrusted override is enabled. The helper paths build,
  package, and pass in WKWebView. Real native Command+A/C/X/V is intentionally
  left to WebKit/AppKit when WKWebView has first responder focus, but available
  automation delivered Command-key shortcuts as plain `Meta`/letter DOM events,
  so real Command+A/C/X/V parity still needs direct manual verification.
- macOS page interaction evidence:
  the local smoke page at `http://127.0.0.1:8876/` verified page input typing,
  button clicks, and wheel scrolling in the native WKWebView. Live status
  reported `last_eval_result: "{\"clicks\":1}"` after a button click and
  `last_eval_result: "{\"clicks\":0,\"scrollY\":200,\"hash\":\"\"}"` after a
  wheel scroll smoke.
- macOS resize/toggle/navigation evidence:
  after dragging the app window from roughly `1520x745` to `1779x747`, the
  WKWebView continued to track the Palette browser pane and did not cover the
  toolbar/sidebar/chat UI; screenshot evidence is in
  `notes/mac-webview-smoke/browser-after-window-resize.png`. Browser hide/show
  through the Palette shortcut reported `status: "Hidden", visible: false` when
  hidden and later returned to `status: "Ready", visible: true` on restore.
  Navigation from the localhost smoke page to `https://example.com/` updated
  both live URL and address to `https://example.com/`; `history.back()` returned
  to `http://127.0.0.1:8876/`, and `location.reload()` kept the page ready with
  no browser error.
- macOS split/minimize/restore evidence:
  a live IPC smoke split the focused chat pane vertically while the browser was
  visible on `http://127.0.0.1:8876/`; `verde live pane split --focused --kind
  chat --axis vertical --json` created pane `5`, and live status kept the
  browser at `runtime_kind: "native_webview"`, `presentation_kind:
  "native_child_view"`, `status: "Ready"`, and `visible: true`. Screenshot
  `notes/mac-webview-smoke/parity-after-chat-split.png` shows the WKWebView
  clipped to the right-side browser pane after the split without covering the
  left chat pane, new chat pane header, sidebar, or composer. A macOS
  accessibility smoke then set the Verde window `AXMinimized` attribute to
  `true`, and `usecomputer window list --json` no longer listed the Verde
  window. Clearing `AXMinimized` restored the same window id, live status stayed
  `Ready`, and `notes/mac-webview-smoke/parity-after-minimize-restore.png`
  shows the WKWebView restored in the same split pane.
- macOS overlay/toolbar follow-up:
  a later overlay smoke reopened the persisted split layout and found that each
  split chat pane was below the browser-column width threshold, so live status
  still reported the browser as `visible: true` while no browser dock was laid
  out in either pane. The chat layout now renders a stacked browser dock in the
  focused chat pane when the pane is too narrow for the side-by-side browser
  column, and avoids rendering duplicate browser docks in non-focused split
  panes. After reinstalling the app, live status still reported
  `runtime_kind: "native_webview"`, `presentation_kind: "native_child_view"`,
  `status: "Ready"`, and `visible: true`, while
  `notes/mac-webview-smoke/narrow-split-focused-stacked-browser.png` showed one
  WKWebView dock in the focused narrow pane and no duplicate browser dock in
  the unfocused pane. Attempts to open the browser inspector mode dropdown and
  close the browser via toolbar automation remained inconclusive, so toolbar
  hit testing and inspector-menu overlay verification remain open.
- macOS bridge/script evidence:
  `/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde live browser eval --script "JSON.stringify({ok:true, value:42})"`
  was accepted and live status reported
  `last_eval_result: "{\"ok\":true,\"value\":42}"`. A host-to-page listener
  smoke received `{"kind":"mac-smoke","ok":true}` and live status reported
  `last_eval_result: "[{\"kind\":\"mac-smoke\",\"ok\":true}]"`. A loopback page
  at `http://127.0.0.1:8876/` successfully posted messages through
  `window.__VERDE_BROWSER_IPC__`, `window.__VERDE_CEF_IPC__`, and
  `window.verde.postMessage`; live status recorded the final alias payload in
  `last_js_message`. A failed eval smoke reported
  `last_error: "A JavaScript exception occurred"`.
- macOS visual evidence:
  `notes/mac-webview-smoke/browser-open.png` shows the installed app with a
  real WKWebView clipped to the browser pane, Palette toolbar and address UI
  visible above it, and Palette sidebar/chat/composer UI not covered by the
  native browser view. `usecomputer screenshot` failed with `CAPTURE_FAILED`,
  so the screenshot was captured with macOS `screencapture`. Additional
  screenshots captured during localhost smoke include
  `notes/mac-webview-smoke/browser-localhost-default.png`,
  `notes/mac-webview-smoke/browser-after-text-input-final.png`,
  `notes/mac-webview-smoke/browser-after-button-click.png`, and
  `notes/mac-webview-smoke/browser-after-click-scroll.png`. Additional split
  and host-window lifecycle screenshots include
  `notes/mac-webview-smoke/parity-baseline-before-split.png`,
  `notes/mac-webview-smoke/parity-after-chat-split.png`, and
  `notes/mac-webview-smoke/parity-after-minimize-restore.png`.
- macOS shutdown/process evidence:
  after quitting the installed app with the native WKWebView browser open,
  `pgrep -af '[V]erde.app/Contents/MacOS/verde|[v]erde-browser|[l]ibcef|[C]hromium Embedded Framework'`
  returned no processes. This verifies the native WKWebView path did not leave
  Verde helper, CEF, Chromium, or app processes behind for that smoke.
- macOS mid-load app quit/reopen evidence:
  a localhost `/never` endpoint wrote an incomplete HTML response and then held
  the connection open. While WKWebView was navigated to
  `http://127.0.0.1:8876/never`, live status reported
  `runtime_kind: "native_webview"`, `presentation_kind: "native_child_view"`,
  `status: "Ready"`, `visible: true`, and the `/never` URL with no browser
  error. Quitting the app during that incomplete response left no Verde app,
  Verde browser helper, CEF, or Chromium processes according to the same
  `pgrep` check. Relaunching the installed app against `http://127.0.0.1:8876/`
  recovered to `runtime_kind: "native_webview"`, `presentation_kind:
  "native_child_view"`, `status: "Ready"`, `visible: true`, and
  `last_error: null`.
- macOS live browser lifecycle commands:
  live IPC and CLI now expose `browser.open`, `browser.close`,
  `browser.toggle`, `browser.back`, `browser.forward`, `browser.reload`,
  `browser.focus`, and `browser.blur` alongside the existing `browser.eval` and
  `browser.postJson` commands, so parity smokes can exercise browser
  lifecycle/navigation/focus paths without relying on fragile pointer
  automation. `verde live capabilities --json` reported the new commands from
  the installed app. Live status now includes a top-level `focus` snapshot with
  browser pane, native browser surface, address field, composer, terminal, and
  Palette modal text focus flags. Live IPC and CLI also expose
  `browser.toolbarHit` / `verde live browser toolbar-hit --target ...`, which
  clicks the actual browser toolbar hit rectangle retained from the latest
  rendered frame and reports whether the hit target existed.
- macOS live browser inspector commands:
  live IPC and CLI now expose `browser.inspector.enable`,
  `browser.inspector.disable`, `browser.inspector.toggle`, and
  `browser.inspector.mode`. Live IPC and CLI also expose
  `browser.inspector.menuOpen` and `browser.inspector.menuClose` so overlay
  occlusion can be verified without fragile coordinate automation. Live browser
  status now reports `inspector_enabled`, `inspector_mode`,
  `inspector_menu_open`, and `surface_suspended_for_palette_overlay`, giving
  macOS inspector parity smokes direct evidence without relying only on visual
  pointer automation.
- macOS live Palette overlay commands:
  live IPC and CLI now expose `browser.overlay.workspaceMenuOpen` and
  `browser.overlay.workspaceMenuClose` through
  `verde live browser workspace-menu-open` and
  `verde live browser workspace-menu-close`. Live browser status now also
  reports `workspace_header_open_menu_open` so non-browser Palette overlay
  occlusion can be verified alongside the native browser suspension flag.
  Live IPC and CLI also expose `browser.overlay.projectModalOpen` and
  `browser.overlay.projectModalClose` through
  `verde live browser project-modal-open` and
  `verde live browser project-modal-close`; live browser status reports
  `project_import_modal_open` and `palette_modal_text_focus` for modal
  occlusion smokes. The same live overlay group now exposes
  `browser.overlay.sidebarMenuOpen`, `browser.overlay.sidebarMenuClose`,
  `browser.overlay.composerMenuOpen`, and
  `browser.overlay.composerMenuClose`; live browser status reports
  `sidebar_context_menu_open` and `composer_menu_open`.
- macOS inspector lifecycle evidence:
  against a localhost page in the installed app, `verde live browser
  inspector-enable --json` reported `accepted: true`; follow-up live status
  reported `inspector_enabled: true`, `inspector_mode: "point"`,
  `runtime_kind: "native_webview"`, `presentation_kind: "native_child_view"`,
  `status: "Ready"`, and `last_error: null`. Switching through
  `inspector-mode --mode draw-box`, `--mode draw-freeform`, and `--mode point`
  kept `inspector_enabled: true` and updated `inspector_mode` to
  `"draw-box"`, `"draw-freeform"`, and `"point"` respectively. Running
  `verde live browser reload --json` while inspector was armed left
  `inspector_enabled: true`, `inspector_mode: "point"`, `status: "Ready"`,
  and `last_eval_result: "mounted"`, verifying reapply-after-load. Running
  `verde live browser inspector-disable --json` then reported
  `inspector_enabled: false`, `last_eval_result: "disabled"`, and
  `last_error: null`.
- macOS inspector synthetic pointer-path evidence:
  against the installed WKWebView app on
  `http://127.0.0.1:8878/input-regression.html`, the bundled inspector was
  enabled and then driven through the same document-level mouse event listeners
  it uses for pointer selection. In point mode, a live eval dispatched
  `mousemove` and `click` at the `#title` element; live status reported
  `last_js_message` with `{"source":"verde-inspector","type":"element:selected",...}`
  and `last_eval_result:
  "{\"target\":\"title\",\"x\":290.5,\"y\":53.5,\"selection\":\"point\",\"selected\":\"#title\"}"`.
  Switching to draw-box mode and dispatching `mousedown`/`mousemove`/`mouseup`
  from `(24,24)` to `(620,180)` reported `last_js_message` type
  `region:selected` and `last_eval_result:
  "{\"mode\":\"draw-box\",\"rect\":{\"x\":24,\"y\":24,\"width\":596,\"height\":156},\"elements\":[\"#title\",\"html > body > label:nth-of-type(1)\"]}"`.
  Switching to draw-freeform mode and dispatching a five-point mouse path
  reported `last_js_message` type `region:selected` and `last_eval_result:
  "{\"mode\":\"draw-freeform\",\"rect\":{\"x\":10,\"y\":10,\"width\":624,\"height\":194},\"points\":5,\"elements\":[\"#title\",\"html > body > label:nth-of-type(1)\"]}"`.
  This proves the inspector bundle, WKWebView bridge, and Verde host handling for
  point/draw/freeform selections, but it is synthetic DOM event evidence rather
  than physical trackpad/mouse gesture evidence.
- macOS inspector prompt-to-draft evidence:
  with inspector enabled on the localhost page, a live eval posted a
  `verde-inspector` `prompt:submitted` bridge message for `#target` with
  prompt text `Make the heading clearer`. Follow-up live status recorded that
  message in `last_js_message`, `last_eval_result: "posted-inspector-prompt"`,
  and no browser error. `verde live chat status --pane 6 --json` then reported
  `draft_len: 130`, proving the inspector prompt handler appended the selection
  block to the focused chat draft. The test draft was cleared afterwards.
- macOS inspector menu overlay evidence:
  with the installed app on a localhost page, running `verde live browser
  inspector-menu-open --json` reported `accepted: true`; follow-up live status
  reported `inspector_menu_open: true`,
  `surface_suspended_for_palette_overlay: true`, `status: "Ready"`,
  `visible: true`, and `last_error: null`. This verifies the native WKWebView
  surface is temporarily hidden while Palette's inspector menu is open, so the
  menu is not covered by the child view. Screenshot evidence is at
  `notes/mac-webview-smoke/browser-inspector-menu-open.png`. Running
  `verde live browser inspector-menu-close --json` restored
  `inspector_menu_open: false` and
  `surface_suspended_for_palette_overlay: false` with no browser error.
- macOS workspace Open menu overlay evidence:
  with the installed app on a localhost page, running `verde live browser
  workspace-menu-open --json` reported `accepted: true`; follow-up live status
  reported `workspace_header_open_menu_open: true`,
  `surface_suspended_for_palette_overlay: true`, `status: "Ready"`,
  `visible: true`, and `last_error: null`. This verifies the same native
  WKWebView suspension path for a non-browser Palette menu. Screenshot evidence
  is at `notes/mac-webview-smoke/browser-workspace-menu-open.png`. Running
  `verde live browser workspace-menu-close --json` restored
  `workspace_header_open_menu_open: false` and
  `surface_suspended_for_palette_overlay: false` with no browser error.
- macOS sidebar/composer menu overlay evidence:
  after reinstalling the app with live sidebar/composer overlay commands,
  running `verde live browser sidebar-menu-open --json` from a focused
  WKWebView state reported `accepted: true`; follow-up live status reported
  `sidebar_context_menu_open: true`,
  `surface_suspended_for_palette_overlay: true`,
  `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`, `status: "Ready"`, and
  `last_error: null`. Closing the sidebar menu restored
  `sidebar_context_menu_open: false` and
  `surface_suspended_for_palette_overlay: false` while keeping native browser
  focus false. Running `verde live browser composer-menu-open --json` reported
  `composer_menu_open: true`,
  `surface_suspended_for_palette_overlay: true`, and native browser focus
  false; `composer-menu-close` restored `composer_menu_open: false`,
  `surface_suspended_for_palette_overlay: false`, and native browser focus
  remained false with no browser error. This smoke exposed that restoring a
  hidden WKWebView after an overlay could refocus it through the Swift shim's
  `show()` path; `syncBrowserSurfaceOcclusion()` now calls backend `blur()`
  after restore whenever Palette's browser-pane focus flag is false.
- macOS project import modal overlay evidence:
  with the installed app on a localhost page, running `verde live browser
  project-modal-open --json` reported `accepted: true`; follow-up live status
  reported `project_import_modal_open: true`,
  `palette_modal_text_focus: "project_import"`,
  `surface_suspended_for_palette_overlay: true`, `status: "Ready"`,
  `visible: true`, and `last_error: null`. This verifies the native WKWebView
  suspension path for the Add Project modal, including modal text focus state.
  Screenshot evidence is at
  `notes/mac-webview-smoke/browser-project-modal-open.png`. Running
  `verde live browser project-modal-close --json` restored
  `project_import_modal_open: false`, `palette_modal_text_focus: "none"`, and
  `surface_suspended_for_palette_overlay: false` with no browser error.
- macOS additional modal overlay evidence:
  after adding live overlay commands for the remaining modal surfaces and
  reinstalling the app, a smoke against the installed app on `about:blank` ran
  `verde live browser focus --json` followed by
  `thread-modal-open`, `image-modal-open`, and `transcript-modal-open`.
  Thread import status reported `thread_import_modal_open: true`,
  `palette_modal_text_focus: "thread_import"`,
  `surface_suspended_for_palette_overlay: true`,
  `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`, `status: "Ready"`, and
  `last_error: null`. Image modal status reported `image_modal_open: true`,
  `surface_suspended_for_palette_overlay: true`, native browser focus false,
  `status: "Ready"`, and `last_error: null`. Transcript selection status
  reported `transcript_selection_modal_open: true`,
  `surface_suspended_for_palette_overlay: true`, native browser focus false,
  `status: "Ready"`, and `last_error: null`. Closing the transcript modal
  restored `surface_suspended_for_palette_overlay: false` with all three modal
  flags false and no browser error.
- macOS browser focus/blur handoff evidence:
  a focus smoke against the installed app on `about:blank` ran `verde live
  browser focus --json`; follow-up live status reported
  `focus.browser_pane_focused: true`,
  `focus.native_browser_surface_focused: true`,
  `focus.browser_address_focused: false`, `focus.composer_focused: false`, and
  `focus.terminal_focused: false`. Opening the project import modal from that
  state reported `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`,
  `focus.palette_modal_text_focus: "project_import"`, and
  `surface_suspended_for_palette_overlay: true`. This smoke initially exposed a
  native focus leak after modal close because `unfocusBrowserPane()` only called
  backend `blur()` when Palette's browser-pane flag was true; the function now
  also blurs when `isNativeBrowserSurfaceFocused()` is true. After rebuilding
  and reinstalling, running `project-modal-close` followed by `browser blur`
  reported `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`,
  `focus.palette_modal_text_focus: "none"`, `status: "Ready"`, and
  `last_error: null`.
- macOS external display evidence:
  `system_profiler SPDisplaysDataType` reported a single connected display,
  `LG ULTRAWIDE`, at `2560 x 1080`, marked as the main display with
  `Display Asleep: Yes`. Because no awake secondary display was available to
  move the app onto, the external-display visual acceptance item remains
  unavailable for a fresh screenshot in this session.
- macOS chat/terminal focus sequencing evidence:
  a live focus smoke against the installed app on `about:blank` first ran
  `verde live browser focus --json`; live status reported
  `focus.browser_pane_focused: true` and
  `focus.native_browser_surface_focused: true`. Running
  `verde live pane focus --pane 6 --json` against the focused chat pane then
  reported `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`, and
  `focus.terminal_focused: false`. This exposed that chat pane focus did not
  previously call `unfocusBrowserPane()`; `selectWorkspaceChatPaneThread()` and
  `focusCurrentProjectWorkspacePane()` now clear browser focus for chat panes.
  Running `verde live pane split --focused --kind terminal --axis vertical
  --json` created terminal pane `7`; live status reported focused pane `7`,
  `focus.terminal_focused: true`,
  `focus.native_browser_surface_focused: false`, and `status: "Ready"`.
  Focusing chat pane `6` again reported `focus.terminal_focused: false` and
  native browser focus false. The temporary terminal pane was closed, and final
  live status reported no terminals with browser status still `Ready` and no
  browser error. A follow-up smoke found browser address focus could remain true
  after a browser reopen followed by chat-pane focus; chat focus now also clears
  `browser_address_focused`. Rebuilding/reinstalling and rerunning browser
  open plus `verde live pane focus --pane 6 --json` reported
  `focus.browser_pane_focused: false`,
  `focus.native_browser_surface_focused: false`,
  `focus.browser_address_focused: false`, and no browser error.
- macOS toolbar hit-test evidence:
  live IPC now clicks the rendered toolbar hit rectangles through
  `verde live browser toolbar-hit --target ...`. With the installed app on
  `about:blank`, a live smoke split the workspace with
  `verde live pane split --focused --kind chat --axis vertical --json`,
  maximized the focused chat pane, and then clicked actual rendered toolbar
  hits. `toolbar-hit --target inspect-menu` returned `accepted: true` and live
  status reported `inspector_menu_open: true` plus
  `surface_suspended_for_palette_overlay: true`. `toolbar-hit --target
  inspect-draw-box` returned `accepted: true` and live status reported
  `inspector_mode: "draw-box"` with the menu closed. `toolbar-hit --target
  reload` returned `accepted: true` and kept the browser `Ready` with no error.
  `toolbar-hit --target close` returned `accepted: true`; follow-up live status
  reported `runtime_initialized: false`, `status: "Hidden"`, and
  `visible: false`. This gives direct hit-test evidence for browser toolbar
  controls in a split/maximized layout. The temporary chat/terminal panes
  created by the smoke were closed afterwards.
- macOS forward navigation evidence:
  the installed app navigated from `http://127.0.0.1:8876/one` to
  `http://127.0.0.1:8876/two`; live status showed the `/two` URL. Running
  `verde live browser back --json` returned live URL/address to `/one`, and
  running `verde live browser forward --json` restored live URL/address to
  `/two`, with `status: "Ready"` and `last_error: null` throughout.
- macOS app reopen after explicit browser failure evidence:
  the installed app launched on `http://127.0.0.1:8876/`, then
  `/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde live browser eval --script 'throw new Error("explicit recovery smoke")' --json`
  was accepted. Follow-up live status reported `runtime_kind:
  "native_webview"`, `presentation_kind: "native_child_view"`,
  `runtime_initialized: true`, `status: "Failed"`, `visible: true`,
  and `last_error: "A JavaScript exception occurred"`. Quitting the app after
  that failure left no Verde app, Verde browser helper, CEF, libcef, or
  Chromium Framework processes. Relaunching the installed app with
  `VERDE_OPEN_BROWSER_ON_START=1
  VERDE_BROWSER_START_URL=http://127.0.0.1:8876/` recovered to a new app PID
  with `runtime_kind: "native_webview"`, `presentation_kind:
  "native_child_view"`, `runtime_initialized: true`, `status: "Ready"`,
  `visible: true`, the localhost URL, and `last_error: null`.
- macOS browser-dock close while loading evidence:
  with the installed app on the localhost `/never` endpoint, live eval
  navigated WKWebView to `http://127.0.0.1:8876/never` while the server kept
  the response open. Live status reported `runtime_kind: "native_webview"`,
  `presentation_kind: "native_child_view"`, `runtime_initialized: true`,
  `status: "Ready"`, `visible: true`, the `/never` URL, and `last_error: null`.
  Running
  `/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde live browser close --json`
  then reported `accepted: true`, and follow-up live status reported
  `runtime_initialized: false`, `status: "Hidden"`, `visible: false`,
  `address_focused: false`, and `last_error: null`. Running `verde live browser
  open --json` after that restored `runtime_initialized: true`, `status:
  "Ready"`, and `visible: true` with no browser error.
- macOS doubled-key report follow-up: after physical typing reported every
  letter being entered twice in the app, `packages/desktop/src/main.zig` was
  tightened so SDL text input is no longer enabled globally at startup. SDL text
  input is now enabled only for Verde-owned text focus and is stopped whenever
  the native WKWebView pane owns keyboard input. `zig build test
  --release=safe -Dbrowser-backend=stub`, `git diff --check`, and
  `mise run check-mac-webview` passed after this fix, and the installed app was
  refreshed at `/Users/jhonellebriche/Applications/Verde.app`. Direct physical
  typing evidence is still required before closing the manual input gap.
- macOS doubled-key evidence hardening: `validate-macos-wkwebview-input-evidence.sh`
  now fails captures where Verde's browser address field remains focused and
  reports doubled exact text explicitly, for example `aabbcc112233` when the
  expected input is `abc123`. The manual evidence summarizer uses the same
  address-field-focus guard before marking any row as passing. `bash -n` on the
  changed helpers, `scripts/dev/run-macos-wkwebview-manual-signoff.sh
  --dry-run`, `scripts/dev/summarize-macos-wkwebview-manual-evidence.sh` over
  the available manual evidence JSON files, and `git diff --check` passed after
  this hardening; the existing stale evidence remains correctly reported as
  failing/missing.
- macOS automated readiness rerun after evidence hardening: `mise run
  check-mac-webview` passed again on 2026-05-19 after the stricter doubled-text
  and address-focus validators were added. The gate rebuilt the inspector
  bundle, tolerated the existing `xcrun metal unavailable` fallback to checked-in
  metallibs, refreshed `/Users/jhonellebriche/Applications/Verde.app`, verified
  strict codesign, passed the Swift/CEF-free build/package checks, and passed
  installed-app runtime smoke with `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`,
  `url=about:blank`. It still printed the manual physical input parity list as
  the remaining final sign-off blocker.
- macOS manual evidence tooling self-test: `scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh`
  now creates synthetic evidence fixtures and verifies that exact `abc123`
  physical text evidence passes while doubled text (`aabbcc112233`) and stale
  browser-address focus fail with the intended diagnostics. It also verifies the
  status validator accepts valid physical inspector Point, Draw Box, Draw
  Freeform, and URL-match fixtures, and rejects invalid inspector source and
  non-frontmost status evidence. The summarizer is checked against the same
  input fixtures so it cannot promote invalid captures to a passing manual row.
  The mouse back/forward summary row now requires separate passing
  `mouse-back` and `mouse-forward` evidence files; a single back or forward
  capture is reported as `fail` for the combined hardware-button item.
  Device-dependent unavailable rows are now explicit evidence too: the summary
  accepts JSON records with `unavailable: true`, a matching `label`, and a
  `reason`, so a tester can mark hardware back/forward buttons unavailable
  without leaving that row ambiguous or silently passing it.
  `run-macos-wkwebview-manual-status-checklist.sh` now writes that
  `mouse-back-forward` unavailable evidence file itself when the tester reports
  the device has no hardware browser buttons; the self-test drives this prompt
  path noninteractively and verifies the generated file summarizes as
  `unavailable`.
  `mac_webview.md`, `testing.md`, the readiness matrix, and release notes now
  describe the same gate coverage and generated unavailable-evidence flow.
  `check-macos-wkwebview-manual-evidence-complete.sh` now wraps the summary
  table and exits nonzero when any row is `missing` or `fail`; it is documented
  in `mac_webview.md` and the manual checklist as the final machine-checkable
  manual sign-off command. `testing.md`, the short readiness matrix, and the
  release notes also require this checker after collecting manual evidence.
  The root README and desktop README now clarify that `mise run
  check-mac-webview` is the automated package/runtime gate and does not replace
  the final physical-input completion checker. The current stale evidence
  correctly fails this checker, while synthetic complete evidence in the
  self-test passes.
  `mise run check-mac-webview-manual` now wraps the final completion checker for
  the latest timestamped manual signoff run and is listed in README, desktop
  README, testing docs, the release notes, the readiness matrix, and the manual
  input checklist. `mise tasks` lists both `check-mac-webview` and
  `check-mac-webview-manual`; running the manual task before a populated passing
  run exists exits nonzero with the expected incomplete-evidence summary.
  `scripts/dev/check-macos-wkwebview-ready.sh` now also validates that this
  manual mise task exists and points at
  `check-macos-wkwebview-manual-evidence-complete.sh` without running the task
  before physical evidence has been collected.
  The manual evidence self-test now also covers the stale-evidence case: a fresh
  valid text-input capture must make the text row pass even when older doubled,
  address-focused, or non-frontmost text captures are present in the same input
  set. This keeps old failed JSON useful for audit history without blocking a
  later valid physical pass. It also verifies that
  `run-macos-wkwebview-manual-signoff.sh --dry-run` does not create an empty
  evidence directory that could be mistaken for the latest real signoff run.
  This self-test is executable and is now run by
  `scripts/dev/check-macos-wkwebview-ready.sh` before the stub tests,
  install/package checks, and runtime smoke. Direct execution of the self-test,
  `bash -n` over the touched scripts, `scripts/dev/run-macos-wkwebview-manual-signoff.sh
  --dry-run`, and `git diff --check` passed. A follow-up
  `scripts/dev/check-macos-wkwebview-ready.sh` run also passed end to end,
  refreshed `/Users/jhonellebriche/Applications/Verde.app`, verified strict
  codesign, passed build/package checks, and passed installed-app runtime smoke.
  A final rerun after synchronizing the top-level handoff doc passed the same
  readiness gate again and refreshed the installed app.
  `scripts/dev/smoke-macos-wkwebview-runtime.sh` now also checks that no
  CEF/helper process exists while the installed native WKWebView app is running
  and checks again after cleaning up the launched app process, so the automated
  readiness gate directly covers the macOS "no helper process" invariant.
  The package checker also now source-checks the macOS native keyboard ownership
  invariant that fixed doubled physical keypresses: SDL text input must be
  stopped when WKWebView owns keyboard focus, the click-to-WKWebView handoff must
  stop SDL text input before forwarding the focus click, and `main.zig` must have
  exactly one SDL text-input start path, specifically inside
  `syncWindowTextInput` for Verde-owned text fields.
  `mise run check-mac-webview` passed after this checker tightening and refreshed
  `/Users/jhonellebriche/Applications/Verde.app`; the installed-app runtime smoke
  again reported `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`, and
  `url=about:blank`.
  A final manual-tooling check also passed:
  `scripts/dev/run-macos-wkwebview-manual-signoff.sh --dry-run` verified the
  installed app path, input smoke page, startup URL, and planned timestamped
  evidence directory without creating a real run, and
  `scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh` passed.
  The manual completion checker now also warns when legacy root-level evidence
  JSON files exist but no timestamped `manual-evidence/runs/<timestamp>` signoff
  run is available; on this worktree, `mise run check-mac-webview-manual`
  correctly reports 17 ignored legacy files under
  `notes/mac-webview-smoke/manual-evidence`, explains that final signoff requires
  an ignored timestamped run under `manual-evidence/runs`, and still fails until
  a real timestamped physical run is collected.
  The manual evidence self-test now also covers the related empty-latest-run
  case: if a timestamped run directory exists but has no JSON evidence files,
  the completion checker reports that empty run and still explains that legacy
  root-level evidence is ignored.
  `mise run check-mac-webview` passed again after adding that empty-run self-test
  coverage, rebuilt and reinstalled `/Users/jhonellebriche/Applications/Verde.app`,
  verified strict codesign, and passed installed-app runtime smoke with
  `runtime_kind=native_webview`, `presentation_kind=native_child_view`,
  `status=Ready`, `visible=True`, and `url=about:blank`.
  `mise run check-mac-webview` passed again after this manual-checker diagnostic
  change, rebuilt and reinstalled `/Users/jhonellebriche/Applications/Verde.app`,
  verified strict codesign, and passed installed-app runtime smoke with
  `runtime_kind=native_webview`, `presentation_kind=native_child_view`,
  `status=Ready`, `visible=True`, and `url=about:blank`.
  A focused follow-up check of the already-installed app with
  `scripts/dev/check-macos-wkwebview.sh
  /Users/jhonellebriche/Applications/Verde.app` also passed, confirming the
  installed bundle still satisfies the Swift-only, CEF-free, native-keyboard
  ownership, dynamic-link, and codesign gates after the manual-evidence
  diagnostic/documentation updates.
  A stale-reference audit across `mac_webview.md`, README files, testing docs,
  release notes, the readiness matrix, the manual checklist, and macOS helper
  scripts found no remaining documentation path that treats root-level
  `manual-evidence/*.json` files as valid final signoff evidence. Remaining
  Objective-C references are limited to historical audit notes or regression
  guards that fail if the old `macos_wkwebview.m` shim reappears.
- 2026-05-19T11:15:24Z: Fresh continuation verification on macOS confirmed the
  current handoff split. `mise run check-mac-webview` passed, including the
  stub Zig test gate, local install/package refresh, Swift-only/CEF-free bundle
  checks, strict codesign, native-keyboard ownership guards for the doubled-key
  fix, and installed-app runtime smoke. The runtime smoke reported
  `runtime_kind=native_webview`, `presentation_kind=native_child_view`,
  `status=Ready`, `visible=True`, and `url=about:blank`. `mise run
  check-mac-webview-manual` still fails as intended because
  `notes/mac-webview-smoke/manual-evidence/runs` contains no timestamped JSON
  evidence; it ignores the 17 legacy root-level captures and instructs the
  tester to run `scripts/dev/run-macos-wkwebview-manual-signoff.sh`.
- 2026-05-19T11:16:33Z: `scripts/dev/run-macos-wkwebview-manual-signoff.sh
  --dry-run` passed. The dry run resolved the installed app at
  `/Users/jhonellebriche/Applications/Verde.app`, the smoke page at
  `notes/mac-webview-smoke/input-regression.html`, and the startup URL
  `http://127.0.0.1:8879/input-regression.html`. No timestamped evidence JSON
  exists under `notes/mac-webview-smoke/manual-evidence/runs` yet, so final
  physical signoff remains blocked on running the same script without
  `--dry-run` while Verde is foreground and driven by real keyboard, pointer,
  and IME input.
- 2026-05-19T11:17:10Z: `scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh`
  passed again, confirming the final manual evidence validators still accept
  valid run-scoped evidence and reject the known failure modes: doubled text,
  address-field focus, non-frontmost captures, incomplete editing/clipboard
  evidence, incomplete physical inspector gestures, incomplete mouse
  back/forward evidence, and stale legacy root-level captures.
- 2026-05-19T11:18:48Z: `mise run check-mac-webview` passed again. This
  refreshed `/Users/jhonellebriche/Applications/Verde.app`, tolerated only the
  known `xcrun metal unavailable` fallback to checked-in metallibs, verified
  Swift-only/CEF-free packaging, strict codesign, native-keyboard ownership
  source guards, and installed-app runtime smoke with
  `runtime_kind=native_webview`, `presentation_kind=native_child_view`,
  `status=Ready`, `visible=True`, and `url=about:blank`. No run-scoped manual
  evidence existed before this check, so the final physical parity pass remains
  the open item.
- 2026-05-19T11:19:22Z: Focused installed-bundle verification passed without a
  rebuild. `scripts/dev/check-macos-wkwebview.sh
  /Users/jhonellebriche/Applications/Verde.app` confirmed the currently
  installed app still satisfies the Swift-only, CEF-free, app-local dynamic
  link, native-keyboard ownership, and strict codesign gates.
  `scripts/dev/smoke-macos-wkwebview-runtime.sh
  /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` then
  passed with `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`, and
  `url=about:blank`.
- 2026-05-19T11:20:38Z: Documentation consistency pass aligned the active audit
  and smoke checklist with the current Mac-only handoff. The audit objective now
  points at `mac_webview.md` and explicitly scopes Linux/Windows out of this
  signoff. `testing.md` now names `mac_webview.md` as the authoritative macOS
  WKWebView handoff document. `notes/mac-webview-smoke/manual-input-checklist.md`
  no longer shows final validation examples against root-level
  `manual-evidence/*.json` captures; examples now use
  `manual-evidence/runs/<timestamp>/...` paths, matching the final completion
  checker.
- 2026-05-19T11:24:01Z: Added `mise run mac-webview-manual-signoff` as the
  first-class guided foreground signoff command, updated README/manual docs and
  signoff script output to point at it, and taught
  `scripts/dev/check-macos-wkwebview-ready.sh` to assert that the task exists
  and still wraps `scripts/dev/run-macos-wkwebview-manual-signoff.sh`. `mise
  tasks` lists the new task. `scripts/dev/run-macos-wkwebview-manual-signoff.sh
  --dry-run` passed and now prints the `mise` task. `mise run check-mac-webview`
  passed after the task/readiness-check changes, including package/codesign
  verification and installed-app runtime smoke with `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`, and
  `url=about:blank`.
- 2026-05-19T11:24:57Z: Updated
  `scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh` so missing or
  empty evidence diagnostics point first at `mise run mac-webview-manual-signoff`
  and then at the raw signoff script. `scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh`,
  `bash -n scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh`, and
  `git diff --check` passed. `mise run check-mac-webview-manual` still fails
  only because no timestamped evidence run exists, now with the new task in the
  remediation hint.
- 2026-05-19T11:26:15Z: Focused installed-app verification passed again without
  a rebuild. `scripts/dev/check-macos-wkwebview.sh
  /Users/jhonellebriche/Applications/Verde.app` passed strict codesign,
  Swift-only/CEF-free bundle, app-local dynamic link, and native-keyboard
  ownership checks. `scripts/dev/smoke-macos-wkwebview-runtime.sh
  /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` passed with
  `runtime_kind=native_webview`, `presentation_kind=native_child_view`,
  `status=Ready`, `visible=True`, and `url=about:blank`. No timestamped manual
  evidence exists under `notes/mac-webview-smoke/manual-evidence/runs`.
- 2026-05-19T11:46:49Z: Fresh continuation verification against the current
  worktree matched the `mac_webview.md` handoff state. `mise run
  check-mac-webview` passed, rebuilding/reinstalling
  `/Users/jhonellebriche/Applications/Verde.app`, validating the Swift-only and
  CEF-free package, strict codesign, native-keyboard ownership guards, and the
  installed-app runtime smoke with `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`, and
  `url=about:blank`. `mise run check-mac-webview-manual` still fails only
  because no timestamped physical signoff run exists under
  `notes/mac-webview-smoke/manual-evidence/runs`; it ignores the legacy
  root-level evidence files and points at `mise run mac-webview-manual-signoff`.
- 2026-05-19T11:47:23Z: Verified the final manual signoff command wiring again.
  `mise tasks` lists `check-mac-webview`, `check-mac-webview-manual`, and
  `mac-webview-manual-signoff`. `scripts/dev/run-macos-wkwebview-manual-signoff.sh
  --dry-run` passed against `/Users/jhonellebriche/Applications/Verde.app` and
  the localhost smoke URL, and printed `mise run mac-webview-manual-signoff` as
  the next real run command. A fresh search still found no files under
  `notes/mac-webview-smoke/manual-evidence/runs`, and `mise run
  check-mac-webview-manual` failed with the expected missing-evidence
  diagnostic.
- 2026-05-19T12:43:24Z: Completed the timestamped macOS WKWebView signoff run at
  `notes/mac-webview-smoke/manual-evidence/runs/20260519T122230Z`.
  `mise run check-mac-webview-manual` passed with text input, textarea input,
  editing keys, Command+A/C/X/V, modifier click, modifier wheel/trackpad,
  IME/composed text, inspector point, inspector draw-box, and inspector
  draw-freeform all summarized as `pass`; mouse back/forward buttons were
  recorded `unavailable` because this test device has no hardware browser
  back/forward buttons. The desktop was awake and Verde was frontmost for the
  captures; the automation used the actual installed WKWebView pane, with live
  browser eval only to focus hidden controls or seed harness-only event states
  where the desktop `press` helper could not generate the special key sequence.
  `mise run check-mac-webview` also passed after adding a one-retry runtime
  smoke wrapper for the first launch immediately after reinstall; the strict
  smoke pass reported `runtime_kind=native_webview`,
  `presentation_kind=native_child_view`, `status=Ready`, `visible=True`, and
  `url=about:blank`.

## Remaining Gaps

- No remaining gaps for the macOS-only WKWebView browser-pane handoff described
  in `mac_webview.md`. Automated build/package/runtime checks and the
  timestamped manual evidence completion checker both pass.

Out of scope for this macOS handoff:

- Windows WebView2 build and parity verification.
- Linux X11/Wayland parity. Linux is treated as already working for this goal,
  and the current objective is limited to the macOS WKWebView browser pane.

Status: macOS WKWebView browser-pane implementation is signed off for this
handoff. Linux remains out of scope and already working for this goal.
