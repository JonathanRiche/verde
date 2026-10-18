# src/platform/macos: AppKit backend

The macOS counterpart of `../wayland`, with the same `App` / `Window` / `Event` API, selected by
`../root.zig` when `os.tag == .macos`. There are no SDK headers, no Objective-C sources, no Swift
and no nib. `objc.zig` dlopens `libobjc` plus Foundation, AppKit, QuartzCore, Metal and
CoreGraphics at runtime, and `backend.zig` registers its three classes (window, view, delegate)
with `objc_allocateClassPair`. Everything therefore cross-compiles from Linux
(`zig build -Dtarget=aarch64-macos`). Only libc/libSystem is linked.

| file | role |
| --- | --- |
| `objc.zig` | Runtime shim: `send(R, target, "sel:", .{args})` (typed `objc_msgSend`; arm64 has no `_stret`), classes, selectors, class builder (methods, ivars, protocols), `Pool` (autorelease), `nsString`/`utf8`, `cSymbol` (dlsym into the loaded frameworks), NSRect/NSPoint/NSRange structs. |
| `keys.zig` | `kVK_*` to evdev scancode (the same values SDL3 reports, e.g. kVK_F13 to KEY_SYSRQ), keycodes, modifier flags to `Mods` / `ModKeys` (left/right from the device-dependent bits), ISO keyboard swap. Pure; unit tested on every host. |
| `text_input.zig` | `NSTextInputClient` state: marked text, with UTF-16 ranges converted to byte cursors, commit, and `firstRectForCharacterRange`. Pure; unit tested on every host. |
| `backend.zig` | `App` (NSApplication, event queue, wakeup, signals, clipboard, theme) and `Window` (NSWindow + layer-backed NSView whose backing layer is a `CAMetalLayer`). |

## Behaviour

* **Event loop.** `waitEvent` blocks in `-[NSApplication nextEventMatchingMask:untilDate:...]`. The key and flags
  events are translated directly. Everything is then forwarded to `sendEvent:`, so menus, the window delegate and the
  view's mouse/IME methods run normally. Cross-thread `App.wakeup(u64)`, display-link frames, appearance KVO and
  SIGINT/SIGTERM (`handle_signals`, via dispatch sources) post an application-defined NSEvent so the wait returns.
  An idle window uses ~0.1% CPU (`run-macos-window`: 1.9 ms over 1.5 s).
* **Frame pacing.** `Window.requestFrame()` unpauses the view's `CADisplayLink` (`-[NSView displayLinkWithTarget:selector:]`,
  macOS 14+, so it follows the window's screen). It posts one `Event.frame` per request and then pauses again. On
  macOS < 14 a one-shot 1/60 s NSTimer stands in. A hidden window gets its frame immediately, so nothing waits
  forever.
* **Sizes.** `logicalSize()` is in points. `pixelSize()` = points x `backingScaleFactor`, which is what the
  `CAMetalLayer.drawableSize` must be. `viewDidChangeBackingProperties` updates `contentsScale` and fires
  `resized` when a window moves between Retina and non-Retina screens.
* **Activation and focus.** The policy is `AppOptions.activation_policy` (`regular` by default) and is applied before
  `finishLaunching`. Unbundled executables are not activated by the system, so `activate = true` activates on the first
  `show`. An app id starting with `palette-test` forces the accessory policy and no activation, which keeps tests from
  stealing focus. With activation allowed, `show` calls `makeKeyAndOrderFront:` (and activates once); without it,
  only `orderFront:` is called.
* **Keyboard and IME.** `keyDown:` runs `interpretKeyEvents:` only while text input is on (`startTextInput`), so
  `text_input` follows SDL's gating, as on Wayland. Marked text produces `text_editing` with a byte cursor and length.
  `setTextInputRect` positions the candidate window through `firstRectForCharacterRange:`. Key repeat comes
  from AppKit (`repeat = true`).
* **Mouse.** View coordinates are flipped (top-left origin, points). Click counts come from AppKit. Wheel input uses
  SDL's sign convention: lines for wheel mice, `precise` pixels for trackpads. `mouse_enter`/`leave` come from a tracking area.
* **Clipboard.** `NSPasteboard` general pasteboard:
  * `setClipboardText` / `getClipboardText` handle UTF-8 text.
  * `getClipboardData(alloc, mime)` returns raw bytes for one MIME type or UTI.
  * `getClipboardImage(alloc)` tries PNG, then JPEG, then TIFF or anything `NSImage` reads, re-encoded as PNG.
    This is the same order as Verde's `macos_clipboard.m`.
  * `clipboard_update` fires when `changeCount` moves while the app is not the writer. The pasteboard has no
    notification, so it is polled every 500 ms while events are processed.
  * There is no primary selection: set returns `error.Unsupported`, get returns null.
* **Theme.** `systemTheme()` reads `NSApp.effectiveAppearance` (Aqua → light, DarkAqua → dark). KVO on that key
  posts `system_theme_changed`. The live check flips it with an app-local `NSApp.appearance`; no system setting is
  touched.
* **Visibility.** `hide()` / `show()` (`orderOut:` / `orderFront:`) post `window_hidden` / `window_shown` with
  reason `.unmapped`. Miniaturize, or full occlusion (`occlusionState`), posts the `.suspended` pair, like
  xdg `suspended`. Closing the window (red button, `performClose:`) posts `close_requested` and leaves the window open. The host decides,
  which is what Verde's close-to-hide handoff wants.
* **Cursors.** Public `NSCursor` class methods are used where they exist. The diagonal and one-sided resize, move and help
  cursors use AppKit's private `_windowResize…` / `_moveCursor` / `_helpCursor` methods, guarded by
  `respondsToSelector:`. When a private method is missing, a close public cursor is used.
* **Other.** `usableBounds()` is the main screen's `visibleFrame` (menu bar and Dock excluded). The other calls are
  `setPosition`/`position` (top-left, in points), `setMinSize`, `setMaximized` (zoom), `minimize`, `setFullscreen`
  (`toggleFullScreen:`), `requestAttention` (dock bounce) and `sync` (`CATransaction flush`). A minimal app menu
  (About, Hide, Quit, Window > Minimize/Zoom/Full Screen) is built when the app has none and the policy is regular.
* **Native handles.** `Window.nativeHandles()` returns `ns_window` (NSWindow*), `ns_view` (the content view) and
  `metal_layer` (its CAMetalLayer). The view is layer-*backed* (`makeBackingLayer`), not layer-hosting, so
  subviews such as a WKWebView work. `run-macos-webview` checks this.
* **prefPath.** `platform.prefPath` returns `~/Library/Application Support/<org>/<app>/`, from
  `NSSearchPathForDirectoriesInDomains`, the same as `SDL_GetPrefPath`. Tests only use the pure
  `composeMacPrefPath`; they never create the real directory.

## Live checks (run on a Mac; both use small, inactive windows that close themselves)

* `zig build run-macos-live` (`palette-test-macos-live`, 45 checks). It covers no focus stealing, the accessory policy,
  the frame request, idle CPU, cross-thread wakeup, in-process injected mouse/wheel/key/flags/IME events, the clipboard
  (text and images, with the user's pasteboard snapshotted and restored), resize/title/min size/position, cursors, usable
  bounds, theme + `system_theme_changed`, hide/show, close request and SIGTERM.
* `zig build run-macos-window` (`palette-test-macos-window`) covers the Metal `WindowRenderer` with fonts: first frame,
  display-paced partial redraws, unchanged frames, idle CPU and resize.
* `zig build run-macos-webview` (`palette-test-macos-webview`) covers a WKWebView subview over the Metal view: load,
  hit testing, presents, resize and hide/show.

Input is injected in-process only, by sending NSEvents to the window or calling the view's methods. No CGEventPost or
AppleScript is used, and no Accessibility or Input Monitoring permission is ever requested. Screenshots of the screen
(which need Screen Recording permission) are not used either.

## Limitations

* **Live resize and modal loops.** While the user drags the window edge, or a menu is open, AppKit runs its own tracking
  loop inside `sendEvent:`. `waitEvent` does not return until it ends, and `resized` events queue up. SDL has
  the same limitation. Programmatic resizes (`setContentSize:`) are unaffected. A fix would render from
  `viewDidEndLiveResize` / `setFrameSize:` callbacks during the drag; it is not done.
* **IME needs a human.** The NSTextInputClient path is exercised with synthetic `setMarkedText`/`insertText` calls.
  Real input methods (Japanese/Chinese IMEs, the dead-key and press-and-hold accent popups, the emoji picker,
  dictation) need someone at the keyboard. They also need the input source enabled, which is a system setting the tests do not touch.
* **No window icon API.** Unbundled processes get a generic Dock icon; a bundle provides one (below).
* **One App per process, main thread only** (AppKit's rule). `App.wakeup` is the only thread-safe call.
* **macOS 13 and older** fall back to an NSTimer for frame pacing. Only macOS 14.6 on Apple Silicon has been run.

## Running as a .app bundle instead of a bare executable

Everything above works from a bare executable, which is how tests and the benchmarks run. A shipped app (Verde) would be
a bundle `Verde.app/Contents/{Info.plist, MacOS/verde, Resources/verde.icns}`. Compared with the bare executable:

* **Activation.** LaunchServices activates a bundled app on launch, so `AppOptions.activate` can stay true or be
  set false (it is then redundant). The Dock icon and menu bar name come from `CFBundleName` / `CFBundleIconFile`
  instead of the executable name and a generic icon.
* **Identity.** `CFBundleIdentifier` names the app for the system: notifications, `NSUserDefaults`, the
  window-restoration state, TCC permission records and Keychain access groups. A bare executable is
  identified by its path, so a rebuilt binary can re-trigger permission prompts.
* **Permissions.** Camera, microphone and location use from a WKWebView, or any other TCC-guarded API, *require* the
  matching `NS…UsageDescription` keys in Info.plist. Without them the process is killed on first use. A bare executable
  attributes prompts to the terminal that launched it.
* **Retina.** Set `NSHighResolutionCapable = YES`. Modern macOS already treats unbundled apps as high-resolution,
  so nothing changes in the backend; it reads `backingScaleFactor` either way.
* **Signing and notarization.** Distribution needs a Developer ID signature with the hardened runtime, plus
  notarization. The backend only dlopens system frameworks at fixed `/System/Library/...` paths, which the hardened
  runtime allows without the `disable-library-validation` entitlement. Ad-hoc signing (`codesign -s -`) is
  enough for local runs; on Apple Silicon the linker already ad-hoc signs.
* **Files.** `prefPath` is unchanged (`~/Library/Application Support/<org>/<app>/`). With the App Sandbox enabled
  it would resolve inside the container instead, and WKWebView's network access would need the
  `com.apple.security.network.client` entitlement. Verde is not sandboxed today.
* **Fonts.** Bundled fonts would live in `Contents/Resources`, and the host passes that directory to `FaceSet.fromDir`.
  System fallback discovery (`/System/Library/Fonts`, `/Library/Fonts`, `~/Library/Fonts`) is the same either way.
