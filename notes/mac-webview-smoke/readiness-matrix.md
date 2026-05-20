# macOS WKWebView Readiness Matrix

This matrix tracks `mac_webview.md` against current macOS evidence. It is not a
replacement for `notes/webview_migration_audit.md`; it is the short sign-off
view for the remaining macOS handoff.

## Build And Packaging

| Requirement | Status | Evidence |
| --- | --- | --- |
| `native_webview` is the default macOS desktop browser backend | Proven | `packages/desktop/build.zig` defaults `browser-backend` to `.native_webview`; `mise.toml` uses `-Dbrowser-backend=native_webview` for `dev-mac` and native build flows. |
| Active macOS shim is Swift, not Objective-C | Proven | `packages/desktop/build.zig` calls `addMacOSSwiftWebView` for app builds and native-webview tests; it compiles `src/browser/platform/macos_wkwebview.swift`. The stale `macos_wkwebview.m` implementation has been removed. |
| Swift C ABI matches Zig wrapper | Proven | `macos_wkwebview.swift` exports the `verde_macos_webview_*` functions consumed by `macos_wkwebview.zig`, plus `verde_macos_webview_has_focus` for focus-state synchronization and AppKit diagnostics/foreground helpers used by macOS smoke evidence. |
| Default setup/dev/build flows avoid CEF | Proven | `mise run setup`, `zig build --release=safe -Dbrowser-backend=native_webview`, `zig build test --release=safe -Dbrowser-backend=stub`, `mise run dev-mac`, and `mise run build` passed on macOS without CEF download/setup. |
| Installed app bundle excludes CEF/Chromium payloads | Proven | `find /Users/jhonellebriche/Applications/Verde.app ...` for CEF framework/helpers/libs/pak/locales returned no files; strict codesign verification passed. |
| CEF remains explicit fallback | Proven | `mise.toml` exposes `dev-cef`/`build-cef`; macOS package/install scripts source CEF setup only when `VERDE_BROWSER_BACKEND=cef`. |
| Repeatable macOS build/package gate | Proven | `mise run build` and `scripts/dev/check-macos-wkwebview.sh /Users/jhonellebriche/Applications/Verde.app` passed after removing the stale Objective-C shim; the checker validates Swift exports, Zig externs, installed binary Swift symbols, active Swift build wiring, absence of `macos_wkwebview.m`, macOS package/install scripts defaulting to `native_webview` with CEF SDK setup guarded behind the explicit `cef` backend, CEF-free bundle contents, no CEF/Homebrew/repo-local dynamic links, and strict codesign. |
| Repeatable macOS runtime smoke | Proven | `scripts/dev/smoke-macos-wkwebview-runtime.sh /Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde` passed; it launches the installed app with `VERDE_OPEN_BROWSER_ON_START=1`, waits for live status, verifies `native_webview`/`native_child_view`/`Ready`/`visible`/`about:blank`/no error, checks that no CEF/helper process exists while native WKWebView is running, and checks again after cleaning up the process it started. |
| Combined automated readiness gate | Proven | `mise run check-mac-webview` passed after the macOS doubled-key fix; it runs `scripts/dev/check-macos-wkwebview-ready.sh`, which checks helper syntax/executability, runs `scripts/dev/run-macos-wkwebview-manual-signoff.sh --dry-run`, runs `scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh` to prove the manual validators accept exact text and reject doubled/address-focused evidence, executes `zig build test --release=safe -Dbrowser-backend=stub`, refreshes the installed app with `scripts/release/install-macos-local.sh`, runs the build/package checker with installed-binary symbol validation plus source-level native-keyboard ownership checks for the doubled-key fix, and runs the installed-app runtime smoke, then prints the remaining manual physical-input sign-off list. |

## Runtime Smoke

| Requirement | Status | Evidence |
| --- | --- | --- |
| Startup with `VERDE_OPEN_BROWSER_ON_START=1` | Proven | `mise run dev-mac` and the installed app reported `runtime_kind: native_webview`, `presentation_kind: native_child_view`, `runtime_initialized: true`, `status: Ready`, `visible: true`, and `last_error: null`. |
| Browser pane is real WKWebView clipped to Palette content rectangle | Mostly proven | Screenshots in `notes/mac-webview-smoke/` show WKWebView clipped to the browser pane across default, resize, split, narrow-split, menu/modal, and minimize/restore cases. External-display placement was unavailable. |
| Palette remains UI shell with SDL3 GPU renderer | Proven | Browser rendering remains behind Palette dock/toolbar/UI code; screenshots show Palette controls above/around the native child view. |
| Native focus does not duplicate into Palette address field | Proven | Fresh smoke on `input-regression.html` showed `native_browser_surface_focused: true`, `browser_address_focused: false`, `status: Ready`, and no browser error. |

## Parity Matrix

| Area | Status | Evidence / Gap |
| --- | --- | --- |
| Basic pane lifecycle | Proven | Browser open/close/toggle, launch-on-start, resize, split changes, close while loading, minimize/restore, and Palette overlay occlusion are documented in `notes/webview_migration_audit.md`. |
| Focus sequencing | Partially proven | Browser, chat, terminal, project/thread/image/transcript modal, sidebar/composer menu, and overlay handoffs are proven. Broader hands-on sidebar/composer/modal focus sequencing still needs manual parity confirmation. |
| Navigation | Mostly proven | `about:blank`, localhost, `example.com`, URL/address updates, reload, back, forward, and close/reopen while loading are proven. Mouse back/forward buttons remain test-device dependent: the status checklist now requires both hardware directions or records an explicit unavailable evidence file when the device has no browser buttons. |
| Page input and clicks | Partially proven | Earlier local smoke proved page input typing, button clicks, and wheel scroll. The latest macOS event routing stops SDL text input while the native WKWebView pane owns keyboard focus, stops SDL text input before forwarding the click that gives WKWebView focus, and no longer enables SDL text input globally at startup, addressing the doubled-letter report. The package checker now source-checks those ownership invariants. Real physical keypress parity still needs manual verification because automation could not deliver OS keystrokes. |
| AppKit foreground diagnostics | Partially proven | `browser.macos_appkit_diagnostics` proves the WKWebView is attached and first responder inside the SDL-created NSWindow, but terminal-based captures report `appActive: false`, `windowIsKey: false`, `windowIsMain: false`, and System Events reports `frontmost:false`. Real keyboard parity still needs a direct foreground-app manual pass. |
| Clipboard shortcuts | Partially proven | Live helper paths for select-all/copy/cut/paste are proven. Real Command+A/C/X/V through WebKit/AppKit remains manual-only. |
| Editing keys | Unverified | Arrow keys, Home, End, Backspace, Delete, Enter, Tab, and Escape require manual verification on `input-regression.html`. |
| Modifier click/wheel | Unverified | Requires manual verification on `input-regression.html`. |
| IME/composed text | Unverified | Requires manual verification with a macOS input method. |
| Bridge and scripts | Proven | Live eval, host-to-page `post-json`, page-to-host `__VERDE_BROWSER_IPC__`, `__VERDE_CEF_IPC__`, `window.verde`, and failed-eval reporting are documented with live-status evidence. |
| Inspector lifecycle | Mostly proven | Enable/disable/mode switch, reapply after reload, prompt-to-draft, menu overlay, and synthetic point/draw-box/draw-freeform selection paths are proven. Physical pointer/trackpad inspector gestures remain manual-only. |
| Shutdown/recovery | Proven | Quit with browser open, quit during mid-load page, reopen after explicit browser failure, and no stuck Verde/CEF/Chromium helper processes are documented. |

## Manual Sign-Off Still Required

Run `mise run mac-webview-manual-signoff` on a Mac with direct
keyboard/trackpad access. This wraps
`scripts/dev/run-macos-wkwebview-manual-signoff.sh`. For individual passes, use
`scripts/dev/run-macos-wkwebview-manual-input-checklist.sh` and
`scripts/dev/run-macos-wkwebview-manual-status-checklist.sh`. The one-command
signoff writes a fresh run directory under
`notes/mac-webview-smoke/manual-evidence/runs/` by default. Summarize evidence
with the run-specific directory printed by the signoff script:

```bash
scripts/dev/summarize-macos-wkwebview-manual-evidence.sh notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/*.json
scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/*.json
```

The remaining items are:

- real keypress text input after duplicate-input fixes
- real Command+A/C/X/V in focused WKWebView inputs
- editing keys in input and textarea
- modifier click and modifier wheel/trackpad scroll
- IME/composed text
- physical inspector Point, Draw Box, and Draw Freeform gestures
- mouse back/forward buttons if the test device has them, or generated unavailable evidence if it does not

Do not mark the macOS WKWebView goal complete until those manual items have
evidence in `notes/webview_migration_audit.md` using the summary template in
`notes/mac-webview-smoke/manual-input-checklist.md`, or are explicitly declared
unavailable for the test device.
