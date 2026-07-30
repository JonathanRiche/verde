# verde-app

npm launcher package for the [Verde](https://verdeai.dev) desktop app — a tiling
workspace that runs Codex, Claude Code, OpenCode, and Cursor as native chat or
terminal panes, with Grok Build and Amp available as terminal TUIs.

Typical usage:

```bash
npx verde-app
npm i -g verde-app
verde
```

The launcher installs the packaged Verde desktop app. Source builds use the
native platform webview backend. Native browser runtime requirements are WPE
WebKit on Linux (`wpewebkit` and `wpebackend-fdo`), WKWebView on macOS, and the
Microsoft WebView2 Runtime plus `WebView2Loader.dll` availability on Windows.
