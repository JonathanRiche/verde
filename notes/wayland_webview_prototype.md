# Wayland WebView Prototype Notes

This branch adds an explicit Linux presentation kind, `native_wayland_surface`. The current implementation has two Wayland-only paths:

- `VERDE_BROWSER_LINUX_WAYLAND_HELPER=1` starts the older diagnostic GTK/WebKit helper as a separate Wayland toplevel.
- `VERDE_BROWSER_LINUX_SUBSURFACE=1` creates a real SDL-parented `wl_subsurface` inside the browser pane, but it is a probe surface only. It does not load or display WebKit content yet.

If the pane shows a dark rectangle with a green border under `VERDE_BROWSER_LINUX_SUBSURFACE=1`, that is expected. It proves the app can attach, position, resize, clip, and stack an app-owned Wayland subsurface under the SDL window. It is not a loaded page.

The diagnostic Wayland toplevel overlay is gated by:

```bash
VERDE_BROWSER_LINUX_WAYLAND_HELPER=1
```

`VERDE_BROWSER_LINUX_NATIVE_WAYLAND_SURFACE=1` is still accepted as a compatibility alias for the earlier smoke runs, but it does not mean a true subsurface is active.

When the flag is set in a Wayland session, Verde reports `presentation_kind: "helper_window"` through `verde live status --json`, treats browser pane bounds as diagnostic native window bounds, and asks the WebKitGTK helper to show a visible Wayland GTK/WebKit toplevel instead of producing visible snapshot frames. The default Linux path remains `snapshot_texture`.

`native_wayland_surface` now means the app-owned subsurface probe is active. It should not be treated as a working WebKit renderer until WebKit can render into that child surface.

Important limitations:

- The helper is a separate Wayland `xdg_toplevel`, not an SDL-parented child or subsurface.
- `gtk_window_move()` and the existing `setPaneBounds` flow may not reliably position that Wayland toplevel, because the compositor controls toplevel placement.
- `SDL.window.wayland.surface` is discovered and passed through the existing host-window channel, but it is not currently used to parent WebKit under SDL.
- Current diagnostic mode should report `helper_window`; `native_wayland_surface` is reserved for a future true embedding path.
- Snapshot mode must remain the default.

## True Subsurface Probe

The true SDL-parented subsurface path is gated by:

```bash
VERDE_BROWSER_LINUX_SUBSURFACE=1
```

Launch command used for the latest Hyprland smoke test:

```bash
VERDE_BROWSER_LINUX_SUBSURFACE=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
```

What is implemented:

- Verde reads SDL's Wayland display and parent `wl_surface` handles from the host window.
- The Linux browser backend passes those handles to a C shim instead of using Zig `@cImport`.
- The shim creates an app-owned `wl_surface`, makes it a `wl_subsurface` of SDL's parent surface, and commits a `wl_shm` probe buffer.
- Browser pane bounds are passed as pane-relative coordinates for `native_wayland_surface`, so the child surface sits inside the browser content area instead of using global screen coordinates.
- The subsurface is shown/hidden and resized with the browser pane.

What is not implemented:

- WebKitGTK does not render into this subsurface.
- `https://lytx.io/` will not visually load in this mode.
- JavaScript eval, reload, history, and page scrolling are no-ops in this mode.
- Live status reports the probe limitation as `last_error` instead of pretending navigation succeeded.

Latest local verification:

```bash
cc -Wall -Wextra -fsyntax-only packages/desktop/src/browser/platform/linux_wayland_subsurface.c $(pkg-config --cflags wayland-client)
zig build --release=safe -Dbrowser-backend=native_webview --summary all
VERDE_BROWSER_LINUX_SUBSURFACE=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
grim /tmp/verde-wayland-subsurface-current.png
```

Observed status from the smoke test:

- `runtime_kind: "native_webview"`
- `presentation_kind: "native_wayland_surface"`
- `runtime_initialized: true`
- `visible: true`
- `address: "https://lytx.io/"`
- `last_error: "Wayland subsurface probe is attached, but WebKitGTK content is not embedded in it yet."`

Screenshot evidence:

```text
/tmp/verde-wayland-subsurface-current.png
```

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

Frame file ownership is split between helper and app:

- If the helper replaces a frame path before it has announced that frame to the app, the helper deletes the old unpublished file.
- Once the helper announces a frame path, the app owns deleting that file after upload or stale-frame discard.

Timing diagnostics were added around the file-backed snapshot path:

- Helper stderr logs snapshot sequence, WebKit capture duration, scale duration, file write duration, byte count, source/output size, whether scaling occurred, and whether another request was queued while capture was pending.
- App logs snapshot read duration and texture upload duration per uploaded sequence.
- App logs total render-tick upload duration when a frame was uploaded.

These per-frame diagnostics are gated by:

```bash
VERDE_BROWSER_FRAME_LOG=1
```

They should stay disabled for normal subjective scroll-feel testing because logging every snapshot/upload can distort performance.

Snapshot request throttling remains conservative:

- Direct diagnostic helper-window mode still suppresses snapshot requests.
- Hidden helper windows no longer start new snapshot requests.
- Size-change requests still coalesce through the existing `snapshot_pending` / `snapshot_requested_while_pending` path.
- Scaling still only runs when WebKit returns a different size than the requested pane size.

The default snapshot transfer path now uses three memfd-backed shared frame slots modeled after the CEF helper path. The desktop process creates anonymous `memfd_create` fds named `verde-browser-linux-frame-*`, sizes them to `4096 * 2160 * 4`, maps them shared, passes fixed fd numbers to the WebKitGTK helper through `VERDE_BROWSER_LINUX_FRAME0_FD` through `VERDE_BROWSER_LINUX_FRAME2_FD`, and copies each announced slot into a staging buffer before uploading. This removes per-frame temp-file create/read/delete from the normal Wayland snapshot path.

The old file transfer path remains as a fallback if shared slot creation or helper-side `mmap` is unavailable. Helper frame diagnostics include `shared_slot=<n>` for shared frames and `shared_slot=-1` for fallback file frames when `VERDE_BROWSER_FRAME_LOG=1` is set.

Verification commands used after this pass:

```bash
cc -fsyntax-only packages/desktop/src/browser/platform/linux_webkitgtk.c $(pkg-config --cflags gtk+-3.0 webkit2gtk-4.1 x11)
zig build --release=safe -Dbrowser-backend=native_webview --summary all
zig build test --release=safe -Dbrowser-backend=stub
VERDE_BROWSER_FRAME_LOG=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
VERDE_BROWSER_LINUX_WAYLAND_HELPER=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
```

Fresh live-status evidence:

- Default launch reported `runtime_kind: "native_webview"`, `presentation_kind: "snapshot_texture"`, `runtime_initialized: true`, `visible: true`, and URL `https://lytx.io/`.
- Shared-slot launch with `VERDE_BROWSER_FRAME_LOG=1` reported the same default `snapshot_texture` status and accepted a live `window.scrollBy(0, 600)` eval during the smoke run.
- Screenshot evidence for the shared-slot smoke run was captured at `/tmp/verde-webkit-memfd-snapshot.png`.
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
