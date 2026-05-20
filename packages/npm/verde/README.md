# verde-app

npm launcher package for the Verde desktop app.

Typical usage:

```bash
npx verde-app
npm i -g verde-app
verde
```

The launcher installs the packaged Verde desktop app. Source builds default to
the native platform webview backend; the legacy CEF backend is opt-in from the
repository build scripts. Native browser runtime requirements are WebKitGTK 4.1
on Linux, WKWebView on macOS, and Microsoft WebView2 Runtime plus
`WebView2Loader.dll` availability on Windows.
