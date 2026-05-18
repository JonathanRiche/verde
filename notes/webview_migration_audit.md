# Webview Migration Audit

Objective: implement and follow the instructions in `webview.md`.

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
- macOS WKWebView backend: Zig wrapper and Objective-C shim are implemented and
  wired into macOS builds. The native wrapper forwards Palette pane bounds and
  inspector capability metadata to the platform shim, but runtime parity has not
  been verified on macOS.
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
  `platform/macos_wkwebview.m`, plus WebKit/AppKit build wiring. Runtime parity
  remains unverified on macOS. The Objective-C shim maps Palette screen bounds
  through the current `NSWindow` content-view screen rect instead of assuming
  `NSScreen.mainScreen`, reducing the multi-display/fullscreen coordinate risk
  called out in `webview.md`. WKWebView eval results now serialize through
  `NSJSONWritingFragmentsAllowed`, so string, numeric, object/array, and null
  results follow the JSON-compatible eval-result shape expected by the smoke
  checklist. The shim now explicitly invalidates the WKWebView, script message
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
- macOS WKWebView shutdown now calls an explicit Objective-C invalidation path
  before releasing the retained browser object, so script handlers and KVO
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

## Remaining Gaps

- macOS WKWebView must be built and smoke-tested on macOS against the parity
  matrix in `webview.md`.
- Windows WebView2 must be built and smoke-tested on Windows against the parity
  matrix, including missing-runtime/loader failure reporting.
- Linux X11 parity is still only partially verified. Hyprland Wayland evidence
  exists, and X11-style Xwayland smokes confirm `helper_window` metadata,
  startup navigation, eval, post-json/bridge plumbing, screenshots, and pointer
  focus into a page input. Text input and PageDown scrolling did not affect DOM
  state through the available desktop automation, wheel parity could not be
  automated with the installed input tools, and the visible helper no longer
  expands to full-monitor geometry and now publishes a host `WM_TRANSIENT_FOR`
  hint, but still does not honor exact pane position under Hyprland/Xwayland.
  Text/key/wheel and exact in-pane geometry parity remain unverified. Wayland
  remains snapshot-based by default because the visible helper tiled as a
  separate window under Hyprland, and the unsafe Wayland helper override is not
  release parity.

Status: not complete until the platform parity gaps above are verified or
explicitly scoped out for a release.
