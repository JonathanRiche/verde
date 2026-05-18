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
- Capture Hyprland Wayland screenshots proving that the browser surface stays
  clipped to the Palette browser pane and does not cover toolbar, sidebar,
  terminal, chat, or modal UI.
- Confirm default development and package builds do not download or include CEF
  files, and confirm the CEF fallback path remains opt-in.
- Confirm page-to-host bridge messages are accepted only from app and loopback
  pages by default. `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1` is a diagnostic
  escape hatch for arbitrary pages and `data:` URL smokes.
