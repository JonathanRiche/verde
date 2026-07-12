# verde-app-windows-x64

Platform runtime package for Verde on Windows x64.

The package carries the GUI-subsystem entry point at `app/Verde.exe` and the
console CLI at `bin/verde.exe`, with a complete adjacent DLL set for each. The
top-level `verde-app` launcher selects the GUI for an argument-free launch and
the console executable whenever CLI arguments are supplied.

The Microsoft Edge WebView2 Evergreen Runtime is a prerequisite. The bundled
`WebView2Loader.dll` is the application loader and does not contain the browser
runtime.
