# src/platform/windows: Win32 backend

The Win32 backend has the same `App` / `Window` API as `../wayland/backend.zig`, and
`../root.zig` picks it at comptime when the target is Windows. It links only OS DLLs: user32,
kernel32, imm32, shell32, dwmapi, shcore and advapi32. Every function is declared by hand
in `win32.zig`, so it needs no zigwin32 and no SDL.

## Files

| file | role |
| --- | --- |
| `win32.zig` | Hand-written types, constants and externs. Also UTF-8/UTF-16 and LPARAM helpers. `MAKEINTRESOURCE` is `align(1)` because odd ids like IDC_HAND are not u16-aligned. |
| `keymap.zig` | Pure tables. `evdevFromScancode` maps a set-1 scancode (plus the extended bit) to evdev, `keycodeFromVk` maps a VK to `Keycode`, and `rawScancode` gives the native code (SDL's `raw`). It has no OS calls and is unit tested on Linux. |
| `translate.zig` | Pure input translator: keys, `WM_CHAR` surrogates, dead keys, IME composition, mouse, capture, click counting, wheel/hwheel and DPI arithmetic. OS queries go through a `Host` interface, so the Linux tests drive it with a fake host. |
| `backend.zig` | `App` / `Window`. Window class, message-only window, `waitEvent`, window procedure, DPI, cursors, clipboard, theme, monitors and the console handler. |
| `../paths.zig` | `prefPath`, SDL3-exact on Windows. It is `SHGetFolderPathW(CSIDL_APPDATA \| CSIDL_FLAG_CREATE)` + `\org\app\`, with each level created. |

## What Verde needs, through the native API

| need | API |
| --- | --- |
| key / scancode / mods | `Event.key_down/up`. `KeyEvent.scancode` is **evdev on every platform**, and `platform.windows_keymap.rawScancode(k.scancode)` gives the Windows set-1 code. Other fields: `key` (layout-resolved `Keycode`), `codepoint`, `base_codepoint`, `mod`, `mod_keys` (L/R), `repeat`. `App.modState()` / `modKeys()`. AltGr arrives as Ctrl+Alt, as Windows reports it. |
| text / IME | `Window.startTextInput(rect)` / `stopTextInput()` / `setTextInputRect`. `text_input` is generated only while text input is active. IME preedit arrives as `text_editing` (UTF-8, cursor in bytes), the candidate window is placed at the rect, and the IME is detached while text input is off. |
| native handles | `Window.nativeHandles()` returns `{ hwnd, hinstance }`. This is the parent HWND for WebView2. The top-level window has `WS_CLIPCHILDREN`. |
| clipboard | `App.setClipboardText` / `getClipboardText` (CF_UNICODETEXT, LF↔CRLF) and `Event.clipboard_update` (AddClipboardFormatListener). Primary selection is process-local. |
| cursor | `Window.setCursor(shape)`. CSS names map to IDC_* cursors, and `.hidden` hides the cursor. |
| theme | `App.systemTheme()` reads `HKCU\...\Themes\Personalize\AppsUseLightTheme`, and `.unknown` means the key is missing. Title bars follow the theme through `DWMWA_USE_IMMERSIVE_DARK_MODE`, updated on WM_SETTINGCHANGE. There is no theme-change event; query `systemTheme()` again on focus or a timer. |
| pref path | `platform.prefPath(gpa, .{}, org, app)` |
| usable bounds | `App.usableBounds()` returns a logical size. `App.usableRect()` returns the logical work area with its origin = physical origin / scale. Both use the monitor of the first window, else the primary monitor. |
| position / size | `Window.position()` / `setPosition(x, y)` take the client origin in physical screen pixels. `Window.setSize(w, h)` takes a logical client size (Win32 only). |
| hide / show | `Window.hide()` / `show()` emit `window_hidden` / `window_shown` (`.unmapped`). Minimise and restore emit them with `.suspended`. |
| wakeup | `App.wakeup(u64)` is thread-safe. It posts a private message to the message-only window, and repeated values coalesce. |
| quit | `AppOptions.handle_signals` uses `SetConsoleCtrlHandler`: Ctrl+C, Ctrl+Break and console close become `Event.quit`. Only one App per process can use it. |
| frame pacing | `Window.requestFrame()` plus `setFrameWaitable(dxgi_waitable)`. `palette.WindowRenderer` (`../../app_win32.zig`) does this. `waitEvent` waits on the swapchain's frame-latency waitable together with the message queue, so an idle app uses 0% CPU. |
| modal move/resize | `App.setModalLoopCallback(ctx, fn)` is called from a 10 ms timer and after each WM_SIZE while DefWindowProc's modal loop runs. Render from it to keep painting during a drag. |

Units: sizes, mouse coordinates and `resized.width/height` are logical (pixels / scale), the
same as on Wayland. `pixel_width/height` and `scale` = DPI/96 come with every `resized`. The
process is per-monitor-v2 DPI aware, and WM_GETDPISCALEDSIZE keeps the logical client size
when a window moves to a monitor with a different DPI.

## Tests

* On Linux, `zig build test` runs the pure parts: `keymap.zig`, `translate.zig` (synthetic
  message sequences), the `win32.zig` helpers, the clipboard line-ending conversion and the
  Windows prefPath composer.
* Under Wine, use `tools/wine-zig.sh test` (private prefix `../.wine-test`, null display
  driver, `wineserver -k` at the end). It also runs the live tests:
  * `src/app_win32.zig`: a window, the DXGI swapchain (present, frame events, unchanged skip,
    partial redraw, resize) and messages posted to its own HWND.
* `tools/wine-zig.sh run-windows-window -- --selftest` runs the example window. It posts
  mouse, wheel, key and close messages and a SetWindowPos to its **own** HWND, checks every
  resulting event, and exits non-zero on a mismatch.
* Never run a built `.exe` directly. binfmt_misc hands it to the default `~/.wine`. The build
  refuses to run Windows binaries on a non-Windows host without `-fwine`: tests become
  compile-only, and tool runs fail with a message.

Wine cannot verify everything. Under the null driver, rendering is not throttled by vsync and
there is no real DWM, IME, touchpad, multi-monitor or DPI change. See the hardware checklist
in `../../../../STATUS.md`.
