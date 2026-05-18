# Wayland WebView Prototype Notes

This branch adds an explicit Linux presentation kind, `native_wayland_surface`, but does not use it for the current helper-process prototype because the prototype is not a true SDL child/subsurface.

The diagnostic Wayland toplevel overlay is gated by:

```bash
VERDE_BROWSER_LINUX_WAYLAND_HELPER=1
```

`VERDE_BROWSER_LINUX_NATIVE_WAYLAND_SURFACE=1` is still accepted as a compatibility alias for the earlier smoke runs, but it does not mean a true subsurface is active.

When the flag is set in a Wayland session, Verde reports `presentation_kind: "helper_window"` through `verde live status --json`, treats browser pane bounds as diagnostic native window bounds, and asks the WebKitGTK helper to show a visible Wayland GTK/WebKit toplevel instead of producing visible snapshot frames. The default Linux path remains `snapshot_texture`.

`native_wayland_surface` is reserved for a future implementation that can prove a real SDL-parented Wayland subsurface.

Important limitations:

- The helper is a separate Wayland `xdg_toplevel`, not an SDL-parented child or subsurface.
- `gtk_window_move()` and the existing `setPaneBounds` flow may not reliably position that Wayland toplevel, because the compositor controls toplevel placement.
- `SDL.window.wayland.surface` is discovered and passed through the existing host-window channel, but it is not currently used to parent WebKit under SDL.
- Current diagnostic mode should report `helper_window`; `native_wayland_surface` is reserved for a future true embedding path.
- Snapshot mode must remain the default.

## Prototype Evidence

- SDL3 exposes Wayland handles through window properties. The app now passes `SDL.window.wayland.surface` to the native browser backend when available, falling back to the existing X11 window id.
- The existing `setPaneBounds` flow is reused for Wayland surface positioning and resizing.
- Palette stops treating the browser as a texture-backed pane when the diagnostic helper window is active.
- The helper suppresses snapshot requests in diagnostic helper-window mode, so visible pixels are expected to come from the GTK/WebKit toplevel surface.
- `zig build --release=safe -Dbrowser-backend=native_webview --summary all` succeeded.
- Launch command used for the smoke test:

  ```bash
  VERDE_BROWSER_LINUX_WAYLAND_HELPER=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
  ```

- Earlier smoke-test status reported `presentation_kind: "native_wayland_surface"` while the code still used that label for the diagnostic Wayland overlay. That was corrected: the helper-process overlay should report `helper_window`, and `native_wayland_surface` is only valid for a true SDL child/subsurface implementation.
- After the correction, `verde live status --json` with the same diagnostic launch command reported `presentation_kind: "helper_window"`, `runtime_initialized: true`, `visible: true`, and URL `https://lytx.io/`.
- After renaming the diagnostic flag, `VERDE_BROWSER_LINUX_WAYLAND_HELPER=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app` also reported `presentation_kind: "helper_window"`.
- Without the diagnostic flag, the startup smoke command reported `presentation_kind: "snapshot_texture"`, `runtime_initialized: true`, `visible: true`, and URL `https://lytx.io/`, confirming snapshot fallback remains the default.
- Page eval reported title `Lytx`, `innerWidth: 626`, `innerHeight: 1030`, and `devicePixelRatio: 1`.
- Hyprland reported the WebKit surface as a separate native Wayland client: class `verde-browser-linux`, title `Verde Browser Surface`, `xwayland: 0`.
- Keyboard input reached the WebKit surface: after a focused PageDown input, page eval reported `scrollY: 824`.
- Screenshot evidence was captured at:

  ```text
  /tmp/verde-wayland-webview.png
  /tmp/verde-wayland-webview-pane-before.png
  /tmp/verde-wayland-webview-pane-after-click-scroll.png
  /tmp/verde-wayland-webview-pane-after-pagedown.png
  ```

- After terminating the app, `pgrep -af 'verde-browser-linux|zig-out/bin/verde|mise run dev'` returned no remaining app/helper processes.

## Snapshot Performance Follow-up

The snapshot path now carries a monotonic `frame_sequence` from the WebKitGTK helper to the app over the JSON-line helper protocol. The helper writes each published frame to a sequence-specific path such as `/tmp/verde-browser-linux-frame-<pid>-<sequence>.rgba`, and the app stores only the newest announced sequence. If an older frame event arrives after a newer one, the app discards it and deletes that stale frame file.

The app now uploads at most one pending native WebKitGTK frame per `AppState.pollBrowser()` render tick. Browser event draining no longer triggers repeated native snapshot uploads inside the same browser poll loop. Replaced-but-not-uploaded frames are deleted, so rapid scrolling should prefer the newest available frame instead of uploading a backlog.

Timing diagnostics were added around the file-backed snapshot path:

- Helper stderr logs snapshot sequence, WebKit capture duration, scale duration, file write duration, byte count, source/output size, whether scaling occurred, and whether another request was queued while capture was pending.
- App logs snapshot read duration and texture upload duration per uploaded sequence.
- App logs total render-tick upload duration when a frame was uploaded.

Snapshot request throttling remains conservative:

- Direct diagnostic helper-window mode still suppresses snapshot requests.
- Hidden helper windows no longer start new snapshot requests.
- Size-change requests still coalesce through the existing `snapshot_pending` / `snapshot_requested_while_pending` path.
- Scaling still only runs when WebKit returns a different size than the requested pane size.

The file transfer path is still the active implementation. The next low-risk performance step is to reuse the CEF helper's existing shared-memory style as a model for WebKitGTK, using shm or memfd-backed frame slots so the helper can publish pixels without repeatedly creating and reading RGBA files. That should stay separate from the stale-frame fix unless file IO remains the measured bottleneck.

Verification commands used after this pass:

```bash
cc -fsyntax-only packages/desktop/src/browser/platform/linux_webkitgtk.c $(pkg-config --cflags gtk+-3.0 webkit2gtk-4.1 x11)
zig build --release=safe -Dbrowser-backend=native_webview --summary all
VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
VERDE_BROWSER_LINUX_WAYLAND_HELPER=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
```

Fresh live-status evidence:

- Default launch reported `runtime_kind: "native_webview"`, `presentation_kind: "snapshot_texture"`, `runtime_initialized: true`, `visible: true`, and URL `https://lytx.io/`.
- Diagnostic launch with `VERDE_BROWSER_LINUX_WAYLAND_HELPER=1` reported `runtime_kind: "native_webview"`, `presentation_kind: "helper_window"`, `runtime_initialized: true`, `visible: true`, and URL `https://lytx.io/`.
- After terminating the smoke-test app processes, `pgrep -af 'verde-browser-linux|zig-out/bin/verde|mise run dev'` returned no remaining app/helper processes.

## Current Blocker

The helper can create a GTK/WebKit Wayland toplevel and position it as a diagnostic overlay, but this is not yet a true child/subsurface of the SDL window. GTK 3/WebKitGTK does not expose a stable public API in this code path for taking the WebKit widget's internal `wl_surface` and reparenting it under SDL's `wl_surface` with the Wayland subsurface protocol.

Local header inspection found:

- SDL exposes `SDL.window.wayland.surface`; Verde can discover and pass the pointer through, but this helper-process prototype does not use it for parenting.
- GDK exposes `gdk_wayland_window_get_wl_surface` and `gdk_wayland_display_get_wl_display`.
- Wayland exposes `wl_subcompositor_get_subsurface`.
- Wayland protocol requires a surface to have only one role for its lifetime, and `wl_subcompositor_get_subsurface` fails if the child surface already has another role.

The GTK/WebKit surface observed in Hyprland is already a `xdg_toplevel` window. That role cannot be converted into a `wl_subsurface`; a different creation path would be required where GTK/WebKit renders into a role-less child surface before any shell role is assigned.

Because of that, the prototype does not yet satisfy the final clipping and z-order acceptance rules:

- Palette modals and menus cannot be guaranteed above the WebKit surface.
- Browser clipping is controlled by the GTK toplevel size/position rather than an SDL-owned subsurface tree.
- Focus is still window-manager mediated instead of compositor routing within one parent surface.

Keep `snapshot_texture` as the default until a real subsurface path or another compositor-safe embedding API is proven.
