# Webview Migration Plan

This document is the plan for replacing Verde's CEF browser backend with platform webviews as the default desktop browser runtime, while preserving the browser pane behavior the app already exposes.

## Goal

Remove Chromium Embedded Framework from the default desktop build and release packages. The replacement must keep the current browser feature contract:

- In-app browser pane rendered inside the Palette workspace layout.
- URL bar with typed address navigation and automatic `https://` normalization.
- Back and forward navigation through toolbar buttons and mouse buttons 4 and 5.
- Refresh/navigation button behavior.
- SDL mouse motion, click, wheel, keyboard, and text input forwarding into the page.
- Browser focus ownership that does not steal terminal, composer, or modal input.
- Page events back to app state: opened, closed, navigated, title changed, document loaded, JavaScript messages, eval results, failures.
- Host to page JSON dispatch through the Verde bridge.
- Page to host JavaScript bridge for clipboard messages and inspector messages.
- JavaScript evaluation for toolbar actions, browser history, copy/cut/select-all helpers, and the inspector bundle.
- Browser frame presentation in the workspace pane without breaking split panes or layout resizing.
- Lazy startup: no browser runtime should start until the pane is used or `VERDE_OPEN_BROWSER_ON_START=1` asks for it.
- `mise run dev` and `mise run build` remain the supported developer entry points.
- Palette remains Verde's UI system, and SDL3 GPU remains the renderer for the desktop shell. The browser migration must not replace Palette, bypass Palette layout, or move the desktop app to a different UI toolkit.
- Linux Wayland on the current Hyprland development machine is the first required target. Do not treat Linux Wayland as a later cleanup item; the default backend cannot flip until this machine works correctly.

## Current State

The repo already has a browser abstraction boundary:

- `packages/desktop/src/browser/controller.zig` is the facade used by app state and UI.
- `packages/desktop/src/browser/types.zig` defines the runtime events and runtime kind.
- `packages/desktop/src/browser/input.zig` defines the normalized mouse and key events sent from SDL.
- `packages/desktop/src/state.zig` owns browser pane focus, URL normalization, event polling, inspector lifecycle, bridge messages, and clipboard helpers.
- `packages/desktop/src/ui/browser.zig` renders the browser toolbar, URL field, inspector controls, and close/back/forward actions.
- `packages/desktop/src/browser/texture.zig` is the texture handoff used by Palette when browser frames are rendered into the app.

The CEF path is selected when `-Dcef-sdk-path=...` is passed:

- `mise.toml` currently makes `setup`, `dev`, `run`, `debug`, `dev-sdl-gpu`, and `build` download or pass a CEF SDK.
- Root `build.zig` forwards `-Dcef-sdk-path` into `packages/desktop/build.zig`.
- `packages/desktop/build.zig` builds `verde-browser-cef` and `verde-browser-cef-process` with CMake, then installs CEF runtime files.
- Linux packages copy `libcef.so`, `chrome-sandbox`, pak files, locales, `v8_context_snapshot.bin`, Vulkan/GLES libraries, and the helper binaries.
- macOS app packaging copies `verde-browser-cef`, `verde-browser-cef-process`, and the Chromium Embedded Framework bundle when CEF is enabled.

The current CEF implementation is a helper process plus off-screen renderer:

- Zig app sends JSON-line commands to `verde-browser-cef`.
- The helper owns CEF and sends JSON-line events back.
- Browser frames are copied through shared frame slots into `PaneTexture`.
- SDL input is remapped to pane-local coordinates, then forwarded to CEF.
- The inspector injects JavaScript that currently posts to `window.__VERDE_CEF_IPC__`.

There is also a pre-CEF Linux native helper:

- `packages/desktop/src/browser/platform/linux_webkitgtk.zig`
- `packages/desktop/src/browser/platform/linux_webkitgtk.c`
- `packages/desktop/src/browser/platform/linux_helper_main.zig`

That path uses WebKitGTK snapshots and synthetic JavaScript input. It is useful prior art, but it is not equal to the CEF path because it is snapshot-based, Linux-only, and simulates some input through JS rather than native webview events.

macOS and Windows legacy backends are stubs today:

- `packages/desktop/src/browser/platform/macos_wkwebview.zig`
- `packages/desktop/src/browser/platform/windows_webview2.zig`

## Upstream `webview/webview` Fit

`https://github.com/webview/webview` is a small C/C++ wrapper over native web engines:

- Linux: GTK + WebKitGTK.
- macOS: Cocoa + WebKit.
- Windows: Win32 + WebView2.
- It supports navigation, setting HTML, JavaScript init/eval, and two-way JavaScript bindings.
- Its C API includes `webview_create`, `webview_destroy`, `webview_run`, `webview_dispatch`, `webview_navigate`, `webview_set_html`, `webview_init`, `webview_eval`, `webview_bind`, `webview_unbind`, and `webview_return`.
- It can create its own native window or embed into an existing native window handle.
- Windows needs the WebView2 runtime installed on Windows versions before Windows 11.
- Linux needs GTK/WebKitGTK runtime packages instead of bundled Chromium.

This is a good direction for reducing bundle size because it delegates browser engine weight to the OS or distro. It is not a drop-in replacement for the current CEF renderer because it does not provide a cross-platform off-screen pixel stream equivalent to CEF's `OnPaint` path. If Verde keeps rendering the browser as a Palette texture, `webview/webview` alone is not enough.

The decision point is therefore not "CEF versus webview" only. It is also "browser as off-screen texture" versus "browser as native child/overlay view".

## Recommended Architecture

Use platform native webviews as the default backend and remove CEF from the default build. Keep the existing Zig `Controller` API as the app-facing contract. Replace the backend implementation under that facade.

Do not change the app's rendering architecture. Palette still owns all workspace layout, browser toolbar chrome, URL field, hit regions, sidebar notices, chat panels, terminal panels, modal UI, and command UI. SDL3 GPU still presents the native shell. A native webview may only occupy the browser content rectangle that Palette has already reserved and reported through `noteBrowserPaneRegion`.

The preferred implementation strategy is native child views, not off-screen snapshots:

- macOS: add a `WKWebView` as a child `NSView` inside the SDL window's content view, clipped and positioned to the Palette browser pane rect.
- Windows: create a child `HWND` or use the SDL window `HWND`, then host WebView2 with bounds matching the Palette browser pane rect.
- Linux X11: host a GTK/WebKitGTK child or helper window positioned over the SDL window's browser rect.
- Linux Wayland: prefer a GTK helper window or xdg-foreign style integration if available. Wayland embedding is the hardest part and should be treated as the highest-risk OS path.

This changes only the browser content presentation contract internally:

- Today: web engine paints pixels, Zig uploads `PaneTexture`, Palette draws the texture.
- Proposed: Palette reserves the browser pane rectangle, and a native webview is moved/resized/clipped to that rectangle above or within the SDL window.

From app state and UI, behavior stays the same. The browser facade still exposes `show`, `hide`, `navigate`, `eval`, `postJson`, `resizePane`, `handleMouse`, `handleKey`, `pollEvent`, and runtime metadata.

The native child or overlay view is not a replacement for Palette. It is the browser content surface only. Toolbar buttons, inspector controls, URL editing, browser focus state, browser notices, split-pane sizing, and all non-browser UI remain Palette-rendered SDL3 GPU content.

Important overlay constraint: if a native child view is stacked above the SDL surface, Palette cannot draw browser toolbar UI on top of that native child view. The implementation must keep the native webview clipped below the Palette toolbar and exactly inside the browser content rect. If an OS cannot reliably clip and z-order that native surface, that OS is not ready to drop the CEF fallback.

## Why Not Keep Texture Rendering

Keeping the exact CEF off-screen model without CEF would require one of these:

- A per-platform private/unsupported off-screen webview capture path.
- Frequent snapshots of the visible webview.
- A custom WebKitGTK/WKWebView/WebView2 compositor path.

Snapshots are not good enough for exact behavior. They add latency, can miss animation/video/caret updates, and force us to keep manually forwarding input. The existing Linux WebKitGTK helper demonstrates that this path works as a scaffold, but it is not a production-quality browser pane.

Native child views avoid CPU frame copies, avoid texture upload throttling, preserve IME/accessibility/browser input semantics, and are closer to how OS webviews are intended to be embedded.

## Browser Backend Contract

Before replacing CEF, make the backend contract explicit in code and tests:

```zig
pub const BrowserBackend = struct {
    show,
    hide,
    shutdown,
    resizePane,
    navigate,
    eval,
    postJson,
    goBack,
    goForward,
    reload,
    focus,
    blur,
    pollEvent,
};
```

Add explicit methods for `goBack`, `goForward`, and `reload` instead of implementing them only through `eval("history.back()")` and toolbar scripts. Keep JS fallback for engines that do not expose native methods.

Events must preserve:

- `.opened`
- `.closed`
- `.navigated`
- `.title_changed`
- `.document_loaded`
- `.js_message`
- `.eval_result`
- `.failed`

For the inspector and clipboard bridge, standardize one JS bridge name:

```js
window.__VERDE_BROWSER_IPC__.postMessage(JSON.stringify(event))
```

During migration, keep aliases:

```js
window.__VERDE_CEF_IPC__ = window.__VERDE_BROWSER_IPC__
window.verde.postMessage(...)
window.webkit.messageHandlers.verde.postMessage(...)
```

The goal is to remove CEF naming from app-level scripts.

## Platform Plan

### macOS

Backend: `WKWebView` with Objective-C or Objective-C++ shim called from Zig.

Implementation outline:

- Add `packages/desktop/src/browser/platform/macos_webview.m`.
- Use SDL native window properties to get the `NSWindow`.
- Create a browser container `NSView` under the SDL content view.
- Add `WKWebView` as a subview of that container.
- Move and resize the container on every `resizePane` and every Palette layout update.
- Use `WKUserContentController` for script messages.
- Use `evaluateJavaScript:completionHandler:` for `eval`.
- Use `loadRequest:` for navigation.
- Emit title and URL changes through KVO on `title` and `URL`.
- Emit document-loaded from `WKNavigationDelegate`.
- Implement `goBack`, `goForward`, and `reload` natively.
- Support inspector by injecting the existing bundle and forwarding messages through `window.webkit.messageHandlers.verde`.

Build changes:

- Link `WebKit`.
- Keep `AppKit`.
- Remove macOS CEF helper builds and Chromium framework packaging from the default path.

Risk:

- Need reliable SDL3 native handle extraction.
- Need z-order and clipping to stay aligned with Palette split panes.
- Need to handle Spaces/fullscreen/minimize/window movement.

### Windows

Backend: WebView2.

Implementation outline:

- Add `packages/desktop/src/browser/platform/windows_webview2.cpp` plus Zig C ABI wrapper.
- Get the SDL window `HWND`.
- Create a child host window or use WebView2 controller bounds on the SDL window.
- Initialize COM as apartment-threaded on the UI/browser thread.
- Create `ICoreWebView2Environment` and `ICoreWebView2Controller`.
- Use `Navigate`, `ExecuteScript`, `PostWebMessageAsJson`, `AddWebMessageReceived`, `AddNavigationCompleted`, `AddDocumentTitleChanged`, and source-change events.
- Implement `goBack`, `goForward`, `reload` natively.
- Inject the bridge with `AddScriptToExecuteOnDocumentCreated`.
- Check WebView2 runtime availability and emit a clear `.failed` event if missing.

Build changes:

- Link Windows libraries already expected by `webview/webview`: `advapi32`, `ole32`, `shell32`, `shlwapi`, `user32`, `version`.
- Decide whether to vendor WebView2 headers or use the `webview/webview` amalgamation to avoid directly managing the loader.

Risk:

- WebView2 runtime dependency on older Windows.
- COM/threading rules.
- Input focus between SDL and child HWND.

### Linux

Backend: WebKitGTK.

Linux Wayland on the current Hyprland machine is the priority implementation path. X11 support is useful, but it is not sufficient for this migration because the primary development and verification environment is Wayland.

Preferred short-term implementation:

- Reuse the existing helper-process approach, but replace the snapshot/input-simulation contract with a native visible WebKitGTK window positioned over the browser pane.
- Keep the helper outside the SDL process to avoid GTK and SDL event-loop conflicts.
- Send pane global coordinates, size, focus, and visibility to the helper.
- Helper owns GTK main loop and a real `WebKitWebView`.
- On X11, make the helper window transient/child-like where possible and keep it above the SDL window only inside the pane rect.
- On Wayland, prove the overlay/clipping/focus model first. If reliable in-pane embedding is not possible, the migration must find another Wayland-native strategy before the default backend flips. A popout helper can be a temporary diagnostic fallback, but it is not parity with the current in-app browser pane.

Better long-term implementation:

- Build a GTK/WebKitGTK host that owns the top-level window and embeds the SDL rendering area plus browser view as sibling widgets. This would make GTK the Linux application shell and SDL a rendering child, which is a larger architecture change.

Build changes:

- Prefer WebKitGTK 4.1 initially because the current code already uses `gtk+-3.0` and `webkit2gtk-4.1`.
- Later evaluate WebKitGTK 6.0 and GTK 4 if distro support is acceptable.
- Add Linux production dependency checks in `scripts/dev/check-desktop-build-deps.sh`.

Risk:

- Wayland embedding is the first blocker to solve, not a deferred risk.
- Distro WebKitGTK version spread.
- Helper window positioning under tiling WMs and fractional scaling.

## Palette And SDL3 GPU Invariants

Agents working on this migration must preserve these invariants:

- `packages/desktop/src/ui/browser.zig` remains the browser dock and toolbar renderer.
- `packages/desktop/src/state.zig` remains the owner of browser focus, URL normalization, bridge events, inspector lifecycle, and browser pane geometry.
- `packages/desktop/src/main.zig` remains the SDL event routing boundary.
- `palette-renderer=sdl_gpu` remains the normal renderer path.
- Browser bounds must come from Palette layout, not from duplicated platform-specific layout math.
- Native webviews must be moved/resized when Palette reports a new pane rect.
- Native webviews must be hidden when the browser pane is hidden, when the app is minimized, and when layout state says the browser is not visible.
- Native webviews must not cover Palette toolbar controls, sidebar UI, terminal panes, modal overlays, or debug UI.
- `PaneTexture` can remain for the CEF/stub path during migration, but native child-view backends should not require CPU snapshots or Palette texture uploads for normal rendering.

The right model is: Palette decides where the browser content lives; the platform backend makes the OS webview follow that rectangle.

## How To Use `webview/webview`

Use `webview/webview` as a candidate backend library only if it can accept the native parent handles we need and expose enough native handles for bounds/focus control.

Best use:

- Vendor or fetch the amalgamated header for a spike.
- Wrap its C API from Zig.
- Use it for Windows/macOS first, where child view embedding is likely cleaner.
- Keep direct platform shims where `webview/webview` hides a handle we need.

Avoid using it as a black box if it forces Verde into separate top-level browser windows. That would not preserve the current in-app browser pane.

Evaluation checklist:

- Can it embed into SDL's native window handle on macOS and Windows?
- Can it expose or accept the specific child view/window we need to clip to a Palette rectangle?
- Can we inject a persistent bridge before page scripts run?
- Can we receive page messages, navigation, title, and load events with enough fidelity?
- Can we move/resize/focus it every frame or on layout changes without flicker?
- Can Linux Wayland be made acceptable without CEF?

If the answer is yes for an OS, use it there. If the answer is no, use a direct platform shim for that OS.

## Migration Steps

### 1. Lock The Existing Contract

- Add a browser smoke-test checklist to this document or `testing.md`.
- Add logs or CLI-visible state for runtime kind, backend initialized, URL, visible/focused state, and last browser error.
- Make inspector bridge naming backend-neutral.
- Add explicit `goBack`, `goForward`, and `reload` backend calls.
- Do not start by deleting CEF. Keep CEF as the known-good fallback until Linux Wayland on Hyprland passes the parity and screenshot checks.

### 2. Add A New Runtime Kind

Change `RuntimeKind` from:

```zig
legacy_native,
cef,
```

to:

```zig
native_webview,
cef,
stub,
```

Then rename the current `legacy_backend.zig` to a native-webview backend once the platform implementations are real. Keep a temporary CEF backend behind an opt-in build flag during rollout.

### 3. Implement macOS Native Webview

- Replace `macos_wkwebview.zig` stub with a real WKWebView shim.
- Link WebKit in `packages/desktop/build.zig`.
- Drive it through the existing `Controller`.
- Verify URL navigation, eval results, bridge messages, inspector, focus, resize, hide/show, and app shutdown.

### 4. Implement Windows Native Webview

- Replace `windows_webview2.zig` stub with a real WebView2 shim.
- Use `webview/webview` only if it does not block required native handle control.
- Add runtime missing-dependency error handling.
- Verify parity with macOS.

### 5. Fix Linux WebKitGTK Path

- Make Linux Wayland on Hyprland work first.
- Decide whether the Linux default can be in-pane on Wayland, then validate X11.
- If X11 works but Wayland cannot be made reliable, do not remove CEF or flip the default backend.
- Replace file snapshots and synthetic JS input with a real visible native WebKitGTK surface where possible.
- Keep the helper process boundary unless the Linux app shell moves to GTK.

### 6. Flip Defaults

- Add a build option such as `-Dbrowser-backend=native_webview|cef|stub`.
- Default to `native_webview`.
- Make CEF opt-in only:

```bash
zig build -Dbrowser-backend=cef -Dcef-sdk-path=...
```

- Update root `build.zig` to forward `browser-backend`.
- Update `mise.toml` so `mise run dev` and `mise run build` no longer download CEF.
- Keep a temporary `mise run dev-cef` and `mise run build-cef` while validating parity.
- Only flip `mise run dev` to native webview after Linux Wayland on this Hyprland machine passes the parity matrix.

### 7. Remove Default CEF Packaging

After native webview parity is accepted:

- Remove CEF download from `mise run setup`, or repurpose `setup` to install/check native webview dependencies.
- Remove CEF from `scripts/release/package-linux.sh`.
- Remove default CEF handling from `scripts/release/package-macos-app.sh`.
- Remove `install-linux-local-cef.sh` as the default install path.
- Keep CEF scripts only under an explicit legacy/experimental path until deleted.
- Delete `scripts/release/cef-common.sh` after all release jobs stop using it.
- Delete `packages/desktop/src/browser/cef/**` after the opt-in fallback is no longer needed.

## Build And Packaging Changes

Root `mise.toml` target shape:

```toml
[tasks.dev]
description = "Builds and runs Verde from the repo-local Zig build output."
run = "bash -lc 'bash scripts/dev/check-desktop-build-deps.sh && zig build run --release=safe -Dbrowser-backend=native_webview'"

[tasks.build]
description = "Builds the desktop app."
run = "bash -lc 'bash scripts/dev/check-desktop-build-deps.sh && case \"$(uname -s)\" in Darwin) scripts/release/install-macos-local.sh ;; Linux) scripts/release/install-linux-local.sh ;; *) echo \"unsupported build host: $(uname -s)\" >&2; exit 1 ;; esac'"

[tasks.dev-cef]
description = "Builds and runs Verde with the legacy CEF browser backend."
run = "VERDE_CEF_CACHE_DIR=\"$HOME/.cache/verde/cef-sdk\" bash -lc 'bash scripts/dev/check-desktop-build-deps.sh && source scripts/release/cef-common.sh && verde_cef_ensure_sdk \"$(verde_cef_host_os)\" \"$(uname -m)\" >/dev/null && zig build run --release=safe -Dbrowser-backend=cef -Dcef-sdk-path=\"$VERDE_CEF_SDK_PATH_RESOLVED\"'"
```

Package expectations after CEF removal:

- macOS bundle size drops by removing the Chromium Embedded Framework bundle and helper binaries.
- Linux tarball drops CEF shared libraries, pak files, locales, sandbox, and helper binaries.
- Windows package must not bundle Chromium. It should rely on WebView2 runtime detection and install guidance if missing.

## Parity Test Matrix

Run these through `mise run dev` and, where possible, a release build from `mise run build`.

Basic pane:

- Toggle browser open/closed.
- Launch with `VERDE_OPEN_BROWSER_ON_START=1`.
- Resize main window and split workspace panes while browser is visible.
- Focus browser, terminal, composer, sidebar, and modal inputs in sequence.
- Close browser while a page is loading.

Navigation:

- Navigate to `example.com` and confirm URL normalizes to `https://example.com`.
- Navigate to `about:blank`.
- Navigate to a localhost dev server.
- Back/forward toolbar buttons.
- Mouse back/forward buttons.
- Reload.
- Navigation event updates URL bar.
- Title change event updates internal state.

Input:

- Click links and buttons.
- Type into text inputs and textareas.
- Paste text with primary modifier plus `V`.
- Select all in focused input.
- Copy and cut focused selection.
- Arrow keys, Home, End, Backspace, Delete, Enter, Tab, Escape.
- Mouse wheel scroll.
- Modifier keys with click and wheel.
- IME/composed text on macOS and Windows.

Bridge and scripts:

- Run the default JavaScript eval string.
- Post the default JSON bridge payload.
- Confirm page-to-host `js_message`.
- Confirm eval result for JSON/string/null values.
- Confirm failed eval reports an error.

Inspector:

- Enable inspector.
- Switch Point, Draw Box, and Draw Freeform modes.
- Select an element.
- Submit an inspector prompt into the current chat draft.
- Navigate while inspector is armed and confirm it reapplies after load.
- Disable inspector.

Shutdown:

- Close app with browser open.
- Reopen app after a browser failure.
- Ensure no helper processes remain after exit.

Packaging:

- `mise run build` on macOS.
- `mise run build` on Linux X11.
- `mise run build` on Linux Wayland.
- Confirm no CEF files are present in the install/package.
- Confirm native webview dependencies are documented or detected.

## Hyprland Screenshot Verification

For Linux UI and overlay work, use Hyprland screenshots as part of manual verification. The point is to catch native-child z-order, clipping, scaling, and focus bugs that unit tests will not see.

Start the app from the repo root:

```bash
mise run dev
```

For browser startup smoke tests:

```bash
VERDE_OPEN_BROWSER_ON_START=1 mise run dev
```

Find the Verde window and capture screenshots:

```bash
hyprctl clients -j
grim -g "$(slurp)" goal_samples/browser-native-webview.png
```

Capture at least these states:

- Browser closed.
- Browser open at default size.
- Browser open after resizing the main window.
- Browser open after changing workspace splits.
- Browser toolbar hovered/focused with URL field selected.
- Browser content focused after clicking into a page input.
- Browser underneath any modal or menu that should appear above it.
- Browser after toggling inspector mode menu.
- Browser on fractional scaling if the machine supports it.
- Browser on X11 and Wayland sessions when available.
- Browser on this machine's normal Hyprland Wayland session before any default backend flip.

Screenshot acceptance criteria:

- The native webview is clipped to the browser content area only.
- The webview does not cover the Palette toolbar, URL field, inspector menu, sidebar, terminal, chat content, or modal UI.
- The webview tracks the pane rectangle after resize and split changes.
- No blank, stale, or offset browser surface appears after navigation.
- Mouse hit testing matches the visible page location.
- Text in Palette controls still fits and remains readable.

If a screenshot shows the webview covering Palette controls, that backend is not parity-complete. Fix clipping/z-order before removing the CEF fallback for that platform.

## Release Criteria

CEF can stop being the default only when:

- macOS WKWebView matches the parity matrix.
- Windows WebView2 matches the parity matrix or Windows is explicitly out of scope for the release.
- Linux WebKitGTK or another native Linux webview strategy works in-pane on this machine's Hyprland Wayland session.
- Linux X11 is validated after Wayland, not instead of Wayland.
- `mise run dev` does not download CEF.
- `mise run build` does not package CEF.
- Browser inspector works through backend-neutral bridge names.
- The CEF backend is opt-in, not implicit.
- Release notes call out platform webview runtime requirements.

CEF code can be deleted only after at least one release cycle where native webview is the default and the CEF opt-in fallback is no longer needed.

## Open Risks

- Linux Wayland may block exact in-pane browser behavior without a larger GTK shell change.
- `webview/webview` may hide platform handles we need for precise pane clipping, especially on Linux.
- Native child windows can have z-order/focus issues over an SDL-rendered UI.
- OS webviews differ in engine behavior: WebKit on macOS/Linux, Edge WebView2 on Windows. Some page behavior will differ from Chromium.
- DevTools support differs by backend. The bundled Verde inspector should be treated as the supported cross-platform inspection tool.
- Security policy must stay strict: host messaging should remain limited to app and localhost origins unless explicitly relaxed.

## References

Repo files used for this plan:

- `mise.toml`
- `build.zig`
- `packages/desktop/build.zig`
- `packages/desktop/src/browser/controller.zig`
- `packages/desktop/src/browser/types.zig`
- `packages/desktop/src/browser/input.zig`
- `packages/desktop/src/browser/texture.zig`
- `packages/desktop/src/browser/legacy_backend.zig`
- `packages/desktop/src/browser/cef/backend.zig`
- `packages/desktop/src/browser/cef/linux_helper.zig`
- `packages/desktop/src/browser/cef/ipc.zig`
- `packages/desktop/src/browser/cef/c/native_linux.cc`
- `packages/desktop/src/browser/cef/c/helper_linux.cc`
- `packages/desktop/src/browser/platform/linux_webkitgtk.zig`
- `packages/desktop/src/browser/platform/linux_webkitgtk.c`
- `packages/desktop/src/browser/platform/linux_helper_main.zig`
- `packages/desktop/src/browser/platform/macos_wkwebview.zig`
- `packages/desktop/src/browser/platform/windows_webview2.zig`
- `packages/desktop/src/browser/inspector.zig`
- `packages/desktop/src/state.zig`
- `packages/desktop/src/ui/browser.zig`
- `packages/desktop/src/main.zig`
- `scripts/release/package-linux.sh`
- `scripts/release/package-macos-app.sh`
- `scripts/release/install-linux-local-cef.sh`
- `scripts/release/install-macos-local.sh`
- `scripts/release/cef-common.sh`

External references:

- `https://github.com/webview/webview`
- `https://raw.githubusercontent.com/webview/webview/master/core/include/webview/api.h`

## Immediate Next Work

1. Add `-Dbrowser-backend=native_webview|cef|stub` and keep CEF behind explicit opt-in.
2. Rename the inspector bridge from CEF-specific to backend-neutral, with compatibility aliases.
3. Implement and prove Linux Wayland on the current Hyprland machine before any default flip.
4. Implement macOS WKWebView after the Linux Wayland path is viable.
5. Spike WebView2 on Windows using either direct shims or `webview/webview`.
