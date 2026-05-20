# macOS WKWebView Finish Goal

This document tracks the macOS WKWebView sign-off work for the native-webview
migration. The automated macOS build/package/runtime gates now pass; the
remaining completion blocker is the direct physical input parity pass listed
below.

## Goal

Finish and verify the macOS native webview backend for Verde, using the Swift
WKWebView shim.

The expected result is:

- `native_webview` is the default desktop browser backend on macOS.
- The browser pane is a real `WKWebView` clipped to the Palette browser content rectangle.
- Palette remains the UI shell, and SDL3 GPU remains the desktop renderer.
- The macOS platform shim is implemented in Swift, not Objective-C.
- Default macOS dev/build flows do not download or package CEF.
- CEF remains available only as an explicit opt-in fallback.
- The parity matrix below passes on macOS and is documented with evidence.

Do not spend time on Linux X11 or Windows in this goal. Linux X11 and Windows are intentionally out of scope for this macOS handoff.

## Current Branch State

Important files already implemented or changed:

- `packages/desktop/src/browser/platform/macos_wkwebview.zig`
- `packages/desktop/src/browser/platform/macos_wkwebview.swift`
- `packages/desktop/src/browser/native_webview_backend.zig`
- `packages/desktop/src/browser/controller.zig`
- `packages/desktop/src/browser/types.zig`
- `packages/desktop/src/browser/contract.zig`
- `packages/desktop/src/state.zig`
- `packages/desktop/src/main.zig`
- `packages/desktop/build.zig`
- root `build.zig`
- `mise.toml`
- `scripts/release/package-macos-app.sh`
- `scripts/release/install-macos-local.sh`
- `testing.md`
- `notes/webview_migration_audit.md`
- `notes/webview_migration_release_notes.md`
- `notes/mac-webview-smoke/input-regression.html`
- `notes/mac-webview-smoke/manual-input-checklist.md`
- `notes/mac-webview-smoke/readiness-matrix.md`
- `scripts/dev/capture-macos-wkwebview-input-evidence.sh`
- `scripts/dev/capture-macos-wkwebview-status-evidence.sh`
- `scripts/dev/check-macos-wkwebview.sh`
- `scripts/dev/check-macos-wkwebview-ready.sh`
- `scripts/dev/open-macos-wkwebview-input-smoke.sh`
- `scripts/dev/run-macos-wkwebview-manual-input-checklist.sh`
- `scripts/dev/run-macos-wkwebview-manual-input-step.sh`
- `scripts/dev/run-macos-wkwebview-manual-signoff.sh`
- `scripts/dev/run-macos-wkwebview-manual-status-checklist.sh`
- `scripts/dev/smoke-macos-wkwebview-runtime.sh`
- `scripts/dev/summarize-macos-wkwebview-manual-evidence.sh`
- `scripts/dev/validate-macos-wkwebview-input-evidence.sh`
- `scripts/dev/validate-macos-wkwebview-status-evidence.sh`

The old Objective-C `macos_wkwebview.m` shim has been removed. The active macOS
implementation is `macos_wkwebview.swift`, built through
`packages/desktop/build.zig`.

Current status:

- `mise run check-mac-webview` passes on macOS. It runs
  `zig build test --release=safe -Dbrowser-backend=stub`,
  the manual evidence validator self-test for doubled text/address-focus,
  inspector status, URL-match, and generated unavailable-evidence regressions,
  `scripts/release/install-macos-local.sh`, the Swift-only
  build/package/codesign/CEF-free checker, installed-binary symbol validation,
  native-keyboard ownership guards for the doubled-key fix, and the
  installed-app runtime smoke.
- `mise run build` installs `/Users/jhonellebriche/Applications/Verde.app`
  without CEF payloads.
- The installed app runtime smoke reports `runtime_kind: "native_webview"`,
  `presentation_kind: "native_child_view"`, `status: "Ready"`,
  `visible: true`, `url: "about:blank"`, and `last_error: null`.
- `notes/webview_migration_audit.md` and
  `notes/mac-webview-smoke/readiness-matrix.md` contain the current automated
  evidence and remaining gaps.

The Swift shim exports these Zig-callable functions:

- `verde_macos_webview_create`
- `verde_macos_app_configure_foreground`
- `verde_macos_webview_appkit_diagnostics`
- `verde_macos_webview_destroy`
- `verde_macos_webview_show`
- `verde_macos_webview_hide`
- `verde_macos_webview_set_bounds`
- `verde_macos_webview_navigate`
- `verde_macos_webview_eval`
- `verde_macos_webview_post_json`
- `verde_macos_webview_go_back`
- `verde_macos_webview_go_forward`
- `verde_macos_webview_reload`
- `verde_macos_webview_focus`
- `verde_macos_webview_blur`
- `verde_macos_webview_has_focus`
- `verde_macos_webview_pop_event`
- `verde_macos_webview_free_string`

`scripts/dev/check-macos-wkwebview.sh` verifies the Swift exports, matching Zig
externs, active Swift build wiring, absence of the stale Objective-C shim,
installed-binary Swift symbols, CEF-free installed app contents, and strict
codesign. It also source-checks the native-keyboard ownership invariants behind
the doubled-key fix: SDL text input must stop while WKWebView owns keyboard
focus, the click-to-WKWebView handoff must stop SDL text input before forwarding
the focus click, and SDL text input may only be started through the Verde-owned
text-field synchronization path.

## What To Verify First

Start from a clean pull of this branch on a macOS machine with the normal Verde
development prerequisites.

Run:

```bash
git status --short
mise run setup
mise run build
mise run check-mac-webview
```

`mise run check-mac-webview` includes the stub Zig test gate, the manual
evidence validator self-test, and refreshes the local installed macOS app before
checking installed symbols/codesign/runtime. The self-test proves that exact
text evidence passes, doubled text and stale address-field focus fail, physical
inspector/URL-match status validators reject bad captures, and generated
unavailable evidence is summarized explicitly. The build/package checker also
guards the native-keyboard ownership rules that prevent duplicated physical text
input in focused WKWebView fields. If `mise run setup`, `mise run build`, `mise run dev-mac`, or
`mise run check-mac-webview` attempts to download CEF, that is a bug for this
goal.

For an interactive dev smoke, also run:

```bash
VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=about:blank mise run dev-mac
```

Then inspect the macOS app bundle or install prefix and confirm it does not contain CEF or Chromium payloads such as:

- `Chromium Embedded Framework.framework`
- `verde-browser-cef`
- `verde-browser-cef-process`
- `libcef`
- CEF pak files
- CEF locales

## macOS Runtime Smoke

Use the native-webview default unless explicitly testing the CEF fallback.

Run startup smoke:

```bash
VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=about:blank mise run dev-mac
```

From another terminal, query live status:

```bash
./packages/desktop/zig-out/bin/verde live status --json
```

Expected browser fields:

- `runtime_kind: "native_webview"`
- `presentation_kind: "native_child_view"`
- `runtime_initialized: true` after browser open
- `status: "Ready"`
- `visible: true`
- `url: "about:blank"`
- `last_error: null`

If the app binary is installed somewhere else by the macOS build, use that `verde live` binary instead.

## Parity Matrix

Verify and fix the WKWebView backend until these pass.

Basic pane:

- Toggle browser open/closed.
- Launch with `VERDE_OPEN_BROWSER_ON_START=1`.
- Resize the main window while browser is visible.
- Change split panes while browser is visible.
- Focus browser, terminal, composer, sidebar, and modal inputs in sequence.
- Close browser while a page is loading.
- Minimize/hide the app and restore it; the WKWebView must hide and restore with the host window.
- Open Palette modals, menus, and inspector menus over/near the browser; the WKWebView must not cover Palette UI.

Navigation:

- Navigate to `example.com` and confirm URL normalizes to `https://example.com`.
- Navigate to `about:blank`.
- Navigate to a localhost dev server.
- Back/forward toolbar buttons.
- Mouse back/forward buttons if available on the test device, or generated
  unavailable evidence if the device has no hardware browser buttons.
- Reload.
- Navigation event updates URL bar.
- Title change event updates internal browser state.

Input:

- Click links and buttons.
- Type into text inputs and textareas.
- Paste text with Command+V.
- Select all in focused input with Command+A.
- Copy and cut focused selection with Command+C and Command+X.
- Arrow keys, Home, End, Backspace, Delete, Enter, Tab, Escape.
- Mouse wheel or trackpad scroll.
- Modifier keys with click and wheel/scroll.
- IME or composed text on macOS.

Bridge and scripts:

- Run:

```bash
./packages/desktop/zig-out/bin/verde live browser eval --script "JSON.stringify({ok:true, value:42})"
```

- Confirm `last_eval_result` updates in live status.
- Run:

```bash
./packages/desktop/zig-out/bin/verde live browser post-json --json-payload '{"kind":"mac-smoke","ok":true}'
```

- Confirm the page can receive host JSON dispatch.
- From an app or localhost page, call:

```js
window.__VERDE_BROWSER_IPC__.postMessage(JSON.stringify({kind:"mac-page-message", ok:true}))
```

- Confirm live status reports the page-to-host message.
- Confirm `window.__VERDE_CEF_IPC__` and `window.verde.postMessage` remain compatibility aliases.
- Confirm failed eval reports a useful error.

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
- Confirm no stuck helper or child processes remain after exit. macOS WKWebView should not create Verde helper processes for the native backend.

Packaging:

- `mise run build` on macOS.
- Confirm no CEF files are present in the install/package.
- Confirm native runtime requirements are documented in README/release notes.

## Visual Acceptance

Capture screenshots for the audit. Store them under a local temporary or notes path and record the paths in `notes/webview_migration_audit.md`.

Capture at least:

- Browser closed.
- Browser open at default size.
- Browser open after main-window resize.
- Browser open after changing workspace splits.
- URL field focused.
- Browser content focused after clicking into a page input.
- Browser with a Palette modal/menu that should appear above it.
- Browser with inspector mode menu open.
- Browser on an external display if available.
- Browser after app minimize/restore.

Acceptance criteria:

- WKWebView is clipped to the browser content area only.
- WKWebView does not cover the Palette toolbar, URL field, inspector menu, sidebar, terminal, chat content, or modal UI.
- WKWebView tracks pane rectangle after resize/split changes.
- No blank, stale, or offset browser surface appears after navigation.
- Mouse hit testing matches the visible page location.
- Palette text and controls remain readable and interactive.

## Likely Fix Areas

If build fails:

- Check `packages/desktop/build.zig` macOS WebKit/AppKit link wiring.
- Check Swift compilation/link wiring for `macos_wkwebview.swift`.
- If `packages/desktop/src/browser/platform/macos_wkwebview.m` reappears or is
  compiled, treat that as a regression. The final Mac implementation is Swift.
- Check SDL native property names used in `packages/desktop/src/main.zig`.
- Check whether the local macOS build needs `libfff_c.dylib` built or installed first.

If WKWebView appears in the wrong place:

- Inspect the Swift implementation of `verde_macos_webview_set_bounds`.
- Verify conversion from Palette screen bounds through the `NSWindow` content view.
- Test multiple display scale factors and external displays.
- Ensure bounds updates are triggered by `AppState.noteBrowserPaneRegion` and `AppState.noteAppWindowFrame`.

If WKWebView covers Palette UI:

- Verify the native child view is only inside the browser content rect, not the whole dock.
- Confirm `AppState.syncBrowserSurfaceOcclusion` hides native surfaces while Palette overlays are active.
- Confirm close/hide/browser toolbar interactions call backend `blur()` or `hide()` as expected.

If bridge/eval fails:

- Inspect bridge injection and script message handling in the Swift WKWebView shim.
- Confirm messages use `window.__VERDE_BROWSER_IPC__`.
- Confirm compatibility aliases are created.
- Confirm app-side bridge origin policy is not blocking the test page unless the page is intentionally untrusted.

If shutdown crashes or leaks:

- Inspect the Swift invalidation path.
- Confirm KVO observers, script message handlers, navigation delegates, loading state, and subviews are removed before the retained browser handle is released.
- Confirm delayed WebKit callbacks are ignored after invalidation.

## Completion Criteria

Before marking this macOS goal complete, update `notes/webview_migration_audit.md` with:

- macOS build/test commands run and pass/fail results.
- macOS runtime smoke results.
- Screenshot paths and what each screenshot verifies.
- Any fixes made.
- Remaining macOS gaps, if any.

The macOS goal is complete only when:

- `mise run check-mac-webview` passes on macOS.
- `mise run dev-mac` opens a working WKWebView browser pane by default.
- The active macOS WKWebView shim is Swift, not Objective-C.
- `mise run build` creates a macOS package/install without CEF payloads.
- The macOS parity matrix above passes or any excluded item is explicitly documented and accepted.
- `notes/webview_migration_audit.md` is updated with concrete evidence.

As of the current audit, the automated gates pass. The remaining unproven items
are physical/manual input parity:

- real keypress text input after duplicate-input fixes
- real Command+A/C/V/X in focused WKWebView inputs
- editing keys in input and textarea
- modifier click and modifier wheel/trackpad scroll
- IME/composed text
- physical inspector Point, Draw Box, and Draw Freeform gestures
- mouse back/forward buttons if the test device has them, or generated
  unavailable evidence if it does not

Use `notes/mac-webview-smoke/manual-input-checklist.md` for the final direct
keyboard/trackpad pass and paste the summary table into
`notes/webview_migration_audit.md`.
The shortest guided command is:

```bash
mise run mac-webview-manual-signoff
```

Before marking the manual pass complete, run
`scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh
notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/*.json` using the
run-specific evidence directory printed by
`scripts/dev/run-macos-wkwebview-manual-signoff.sh`; it fails if any summary row
is `missing` or `fail`. `mise run check-mac-webview-manual` checks the latest
timestamped evidence run by default. Older root-level JSON files under
`notes/mac-webview-smoke/manual-evidence/` are legacy debug captures and are
ignored for final signoff; the required evidence lives under
`notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/`.

If terminal-based captures show empty page input, check
`browser.macos_appkit_diagnostics` in `verde live status --json` before changing
the WKWebView input path. The latest diagnostics prove the WKWebView can be
attached and first responder while the app is inactive from the terminal's point
of view (`appActive: false`, `windowIsKey: false`, `windowIsMain: false`), so
those captures do not prove physical key delivery into WKWebView.
