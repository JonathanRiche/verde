# Verde UI Scroll Blur Test

Use this workflow when checking the native UI blur issue on Hyprland.

1. Build the desktop app:
   ```bash
   zig build --release=safe
   ```

2. Open the app from this worktree:
   ```bash
   packages/desktop/zig-out/bin/verde
   ```

3. Find the Verde window and its exact compositor geometry:
   ```bash
   hyprctl clients -j | jq -r '.[] | select(.class=="com.verde.native") | {address,at,size,monitor,workspace,title}'
   ```

4. Focus the window using the reported address:
   ```bash
   hyprctl dispatch focuswindow address:<address>
   ```

5. Capture the window with `grim` using the reported `at` and `size` values:
   ```bash
   grim -g '<x>,<y> <w>x<h>' /tmp/verde-open.png
   ```

6. Put the pointer over the transcript area, then send PageUp key presses:
   ```bash
   ydotool mousemove -a -- <x> <y>
   ydotool click 0xC0
   for i in {1..3}; do ydotool key 104:1 104:0; sleep 0.08; done
   ```

7. Capture the same window again:
   ```bash
   grim -g '<x>,<y> <w>x<h>' /tmp/verde-pageup-3.png
   ```

8. For local inspection, enlarge the sidebar crop without smoothing:
   ```bash
   magick /tmp/verde-pageup-3.png -filter point -crop 330x760+0+80 -resize 300% /tmp/verde-pageup-3-sidebar-3x.png
   ```

Pass criteria: after several PageUp presses, sidebar text, thread title text, transcript text, and composer text remain pixel-crisp and do not become globally softened.

## Confirmed Fix Notes

The May 14, 2026 repro was not only a DPI/scaling issue. The scrolled render appended enough Palette text to reallocate the shared frame text `ArrayList`; existing render commands kept slices into the old allocation, so SDL_ttf later read stale bytes and rendered replacement glyphs / blurry-looking corrupted text.

The fixed path stores render-command text in a per-frame arena, reset at the start of each frame. Code-copy payload bytes still use `palette_frame_text` because those are addressed by offset/length instead of render-command slices.

Validated with:

```bash
grim -g '1287,38 1261x1030' /tmp/verde-arena-3pageup.png
grim -g '1287,38 1261x1030' /tmp/verde-arena-15pageup.png
magick /tmp/verde-arena-15pageup.png -filter point -crop 360x760+0+80 -resize 300% /tmp/verde-arena-15pageup-sidebar-3x.png
```

The 15-PageUp capture keeps the sidebar, transcript, and composer text readable and stable.

# Browser Webview Smoke Checklist

Use this checklist for the native webview migration described in `webview.md`.

1. Start the default native webview path without downloading CEF:
   ```bash
   mise run dev
   ```

2. Verify the default native install payload excludes CEF:
   ```bash
   scripts/dev/check-native-webview-install.sh
   ```

3. Start with the browser pane opened lazily by environment request:
   ```bash
   VERDE_OPEN_BROWSER_ON_START=1 mise run dev
   ```
   To smoke-test startup navigation without manual URL entry, add a startup
   URL:
   ```bash
   VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://example.com mise run dev
   ```
   To smoke-test eval reporting, add:
   ```bash
   VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_EVAL='JSON.stringify({title:document.title,url:location.href})' mise run dev
   ```

4. Verify basic pane behavior: open, hide, close, resize the main window, resize split panes, focus browser, focus terminal, focus composer, and open a modal/menu above the browser.

5. Verify navigation: enter `example.com` and confirm `https://example.com`, enter `about:blank`, enter a localhost URL, use toolbar back/forward, use mouse buttons 4/5, and use the refresh button.

6. Verify input: click page controls, type into inputs/textareas, paste, select all, copy, cut, use arrow/Home/End/Backspace/Delete/Enter/Tab/Escape, scroll with the wheel, and use modifier-click/wheel.

7. Verify bridge and scripts: run the default eval string, post the default JSON payload, receive page-to-host `js_message`, confirm eval results for JSON/string/null values, and confirm failed eval reports an error.
   Page-to-host bridge messages are accepted by default only from `app://`,
   `localhost`, `127.0.0.1`, and `[::1]` pages. For local diagnostics against
   arbitrary pages or `data:` URLs, launch Verde with
   `VERDE_BROWSER_ALLOW_UNTRUSTED_BRIDGE=1`.
   The CLI can drive repeatable eval and host-to-page bridge checks while the
   browser is open:
   ```bash
   verde live browser eval --script 'JSON.stringify({title:document.title,url:location.href})' --json
   verde live browser post-json --json-payload '{"type":"ping"}' --json
   verde live status --json
   ```

8. Verify inspector: enable the inspector, switch Point/Draw Box/Draw Freeform modes, select an element, submit an inspector prompt to the current draft, navigate while armed and confirm it reapplies, then disable the inspector.

9. Verify shutdown: close the app with the browser open, reopen after a browser failure, and confirm no browser helper process remains after exit.

10. For Hyprland Wayland overlay work, capture screenshots with:
   ```bash
   hyprctl clients -j
   grim -g '<x>,<y> <w>x<h>' /tmp/verde-browser-native-webview.png
   ```

11. Before release, repeat the checklist on each native runtime:
    - Linux WebKitGTK on the normal Hyprland Wayland session, plus X11 where available. Linux should report `presentation_kind: "snapshot_texture"` on Wayland by default and `presentation_kind: "helper_window"` on X11 unless `VERDE_BROWSER_LINUX_SHOW_HELPER=0` is set. On Wayland, `VERDE_BROWSER_LINUX_SHOW_HELPER=1` must still report `snapshot_texture` unless paired with the diagnostic-only `VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER=1` flag. On X11, verify native focus, click, wheel, and key input in the helper window in addition to the default snapshot path.
    - macOS WKWebView.
    - Windows WebView2 with and without the runtime/loader preinstalled to confirm clear failure reporting.

Pass criteria: the webview is clipped to the browser content area only, never covers Palette toolbar/sidebar/terminal/chat/modal UI, follows pane resize/split changes, does not show blank/stale/offset content after navigation, mouse hit testing matches the visible page, and `verde` live status reports the selected runtime kind, presentation kind, initialization state, focused/visible state, URL, last browser error, last bridge message, and last eval result.
