# K-12 terminal snapshot fixture

`snapshot.json` is a real `vc_term_snapshot` result, not a hand-written view. It was
produced by the client core's Ghostty VT (`zig build jvm-lib --release=safe`) from a
`vc_term_new` handle configured as `{"api_version":1,"cols":20,"rows":4,"scrollback_rows":100}`
after writing the `text` of the recorded K-12 daemon tail
`packages/client_core/src/fixtures/terminal/tail.json` (title, bold red `RED`, a wide
`界`, a combining `é`, then DECCKM and bracketed paste on).

`TerminalJniTest` re-derives the same snapshot through the real JNI boundary and asserts
it still matches this file, so a VT change that alters it fails the test instead of
silently drifting. To regenerate, repeat the steps above (a small ctypes or JNI
harness around `vc_term_new` / `vc_term_write` / `vc_term_snapshot`).
