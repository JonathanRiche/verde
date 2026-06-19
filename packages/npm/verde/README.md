# verde-app

npm launcher package for the [Verde](https://verdeai.dev) desktop app — a tiling
workspace that runs Codex, Claude Code, OpenCode, and Cursor side by side in one
native window.

Typical usage:

```bash
npx verde-app
npm i -g verde-app
verde
```

The launcher installs the packaged Verde desktop app. Source builds default to
the native platform webview backend; the legacy CEF backend is opt-in from the
repository build scripts. Native browser runtime requirements are WPE WebKit on
Linux (`wpewebkit` and `wpebackend-fdo`), WKWebView on macOS, and the Microsoft
WebView2 Runtime plus `WebView2Loader.dll` availability on Windows.
