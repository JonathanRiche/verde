# Native Webview Backend Release Notes

Verde desktop builds now default to the host platform webview backend instead of
bundling Chromium Embedded Framework. CEF remains available as an explicit
fallback through `mise run dev-cef`, `mise run build-cef`, or
`zig build -Dbrowser-backend=cef -Dcef-sdk-path=/path/to/cef`.

Runtime requirements:

- Linux: GTK 3 and WebKitGTK 4.1 runtime packages. Source builds also require
  the matching development packages.
- macOS: WKWebView from the system WebKit framework.
- Windows: Microsoft Edge WebView2 Runtime and `WebView2Loader.dll` available
  next to `verde.exe` or on the DLL search path. Source builds require the
  Microsoft WebView2 SDK headers.

Release validation requirements:

- Run the browser smoke checklist in `testing.md` on Linux WebKitGTK, macOS
  WKWebView, and Windows WebView2.
- On macOS, run `mise run check-mac-webview` to verify the stub tests, refreshed
  local WKWebView app install, Swift-only package/symbol/codesign gate, and
  installed-app runtime smoke. The gate also source-checks the native-keyboard
  ownership rules that prevent doubled physical text input in focused WKWebView
  fields. It self-tests the manual evidence validators so doubled text, stale
  address-field focus, invalid inspector status, failed URL matches, and
  malformed unavailable records cannot be accepted as passing physical input
  evidence. Then complete
  `notes/mac-webview-smoke/manual-input-checklist.md` for real keyboard,
  Command-key shortcut, modifier, IME/composition, and physical inspector
  gesture parity, then run `mise run check-mac-webview-manual` to check the
  latest timestamped evidence run before final sign-off.
- Capture Hyprland Wayland screenshots proving that the browser surface stays
  clipped to the Palette browser pane and does not cover toolbar, sidebar,
  terminal, chat, or modal UI.
- Confirm default development and package builds do not download or include CEF
  files, and confirm the CEF fallback path remains opt-in.
- Confirm page-to-host bridge messages are accepted only from app and loopback
  pages by default. `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` is a diagnostic
  escape hatch for arbitrary pages and `data:` URL smokes.
