# Wayland WebView Prototype Notes

## Next Agent Goal

Read this document and continue the WPE Linux webview path. Focus only on the env-gated WPE path:

```bash
VERDE_BROWSER_LINUX_WPE=1
```

Do not spend time on GTK/WebKitGTK, CEF, Windows, macOS, or the `VERDE_BROWSER_LINUX_SUBSURFACE=1` probe unless needed for comparison. Keep default Linux fallback behavior unchanged.

Current state: WPE renders in the Verde pane and now receives an explicit device scale on HiDPI Wayland outputs. On the local Hyprland eDP monitor at scale `1.67`, `https://lytx.io/` reported `devicePixelRatio=1.6666666269302368` and a logical viewport of `670x787`, with a visible in-pane render captured at `/tmp/verde-wpe-hidpi-scale.png`. The remaining WPE work is performance/usability hardening: remove the CPU readback path if possible, keep checking input/scroll feel, and solve dark color-scheme matching without regressing page rendering.

Build and test with:

```bash
zig build --release=safe -Dbrowser-backend=native_webview --summary all
zig build test --release=safe -Dbrowser-backend=stub
VERDE_BROWSER_LINUX_WPE=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
./packages/desktop/zig-out/bin/verde live browser eval "JSON.stringify({w:innerWidth,h:innerHeight,dpr:devicePixelRatio,screenW:screen.width,screenH:screen.height,visualW:visualViewport.width,visualH:visualViewport.height,scheme:matchMedia('(prefers-color-scheme: dark)').matches})"
```

Take screenshot evidence on Hyprland, update this document with results, and commit only relevant changes.

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

## WPE Exportable Render Target

GTK/WebKitGTK is still useful as the conservative fallback, but it is the wrong primary path for a high-performance Wayland pane inside an SDL-owned app window. Local GTK 4 and WebKitGTK 6 headers expose APIs for GTK-owned widgets and GTK-owned Wayland surfaces, not an API for rendering a `WebKitWebView` into an externally supplied SDL child `wl_surface`.

WPE WebKit is the better Wayland target for this app shape. It lets the app create an embedder-owned WPE view backend, load a `WebKitWebView`, and receive exported render frames. Those frames can then be imported into Verde's renderer or presented through an app-owned Wayland surface without the current WebKitGTK snapshot/readback/upload loop.

A standalone probe now lives at:

```text
packages/desktop/src/browser/platform/linux_wpe_exportable_probe.c
```

Compile command:

```bash
cc -Wall -Wextra -o /tmp/verde-wpe-probe packages/desktop/src/browser/platform/linux_wpe_exportable_probe.c $(pkg-config --cflags --libs wpe-webkit-2.0 wpebackend-fdo-1.0 egl glib-2.0 gobject-2.0)
```

Runtime command used on Hyprland:

```bash
/tmp/verde-wpe-probe https://lytx.io/ 1280 720 1
```

Observed result:

```text
wpe-probe: backend=libWPEBackend-fdo-1.0.so
wpe-probe: EGL initialized version=1.5
wpe-probe: loading https://lytx.io/ at 1280x720 scale=1.00
wpe-probe: load started uri=https://lytx.io/
wpe-probe: exported EGL frame=1 size=1280x720 image=...
wpe-probe: load committed uri=https://lytx.io/
wpe-probe: exported EGL frame=2 size=1280x720 image=...
wpe-probe: load finished uri=https://lytx.io/
wpe-probe: summary frames=344 raw_egl=0 exported_egl=344 shm=0 exit=0
```

This proves the viable render target is WPEBackend-fdo exportable EGL frames. It does not yet prove final in-pane presentation, input routing, or popup/z-order behavior inside Verde.

Recommended implementation sequence:

1. Add a `VERDE_BROWSER_LINUX_WPE=1` helper/runtime path that owns the WPE view backend and exports EGL frames.
2. Import each exported `EGLImageKHR` into the existing SDL/OpenGL texture path, or into a new app-owned Wayland presentation path if that is cleaner with the current renderer.
3. Drive WPE size, scale, refresh rate, visibility, and focus from Verde's existing browser pane state.
4. Translate Verde browser pane pointer, wheel, key, and text events to `wpe_view_backend_dispatch_*` calls so scrolling is native WebKit scrolling instead of snapshot polling.
5. Keep `snapshot_texture` as the default until the WPE path renders `https://lytx.io/` visibly in the pane and passes focus, clipping, and z-order smoke tests.

## WPE In-App Smoke

The first Verde-integrated WPE path is now gated by:

```bash
VERDE_BROWSER_LINUX_WPE=1
```

Launch command used on Hyprland:

```bash
VERDE_BROWSER_LINUX_WPE=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
```

What is implemented:

- `packages/desktop/src/browser/platform/linux_wpe.c` exposes the same helper ABI as the Linux WebKitGTK helper, so the existing JSON-line helper process can drive WPE.
- The helper creates a WPE WebKit view backend using WPEBackend-fdo exportable EGL frames.
- Exported EGL frames are imported through EGL/GLES2, read back as RGBA, swizzled into the existing BGRA shared memfd frame slots, and announced with the existing `frame_ready` IPC event.
- The WPE helper is selected only when `VERDE_BROWSER_LINUX_WPE=1` is set. The default Linux native-webview path remains WebKitGTK `snapshot_texture`.
- Pointer move/button, wheel, keyboard, navigation, reload/history, eval, and the Verde JS bridge are wired through the existing helper protocol.
- WPE frame publication is throttled to roughly one frame per display tick so the app does not ingest the full WPE export stream.
- Verde passes the pane's logical viewport plus the app window device scale through the helper protocol. WPE applies that value with `wpe_view_backend_dispatch_set_device_scale_factor()`, so HiDPI outputs can render physical-pixel frames while exposing logical CSS coordinates to the page and input pipeline.

Verification commands:

```bash
cc -Wall -Wextra -fsyntax-only packages/desktop/src/browser/platform/linux_wpe.c $(pkg-config --cflags wpe-webkit-2.0 wpebackend-fdo-1.0 egl glesv2 glib-2.0 gobject-2.0 javascriptcoregtk-6.0)
zig build --release=safe -Dbrowser-backend=native_webview --summary all
zig build test --release=safe -Dbrowser-backend=stub
VERDE_BROWSER_LINUX_WPE=1 VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
./packages/desktop/zig-out/bin/verde live status --json
./packages/desktop/zig-out/bin/verde live browser eval "JSON.stringify({w:innerWidth,h:innerHeight,dpr:devicePixelRatio,screenW:screen.width,screenH:screen.height,visualW:visualViewport.width,visualH:visualViewport.height,scheme:matchMedia('(prefers-color-scheme: dark)').matches})"
grim -g '12,1118 1416x910' /tmp/verde-wpe-hidpi-scale.png
```

Observed status from the latest smoke test:

- `runtime_kind: "native_webview"`
- `presentation_kind: "offscreen_texture"`
- `runtime_initialized: true`
- `status: "Ready"`
- `visible: true`
- `url: "https://lytx.io/"`
- `last_error: null`
- On the local scale-1.00 DP monitor, eval returned viewport metrics `{"w":593,"h":907,"dpr":1,"screenW":1200,"screenH":800,"visualW":593,"visualH":907,"scheme":false}`.
- On the local scale-1.67 eDP monitor, eval returned viewport metrics `{"w":670,"h":787,"dpr":1.6666666269302368,"screenW":670,"screenH":787,"visualW":670,"visualH":787,"scheme":false}`.

Screenshot evidence:

```text
/tmp/verde-wpe-app-upright.png
/tmp/verde-wpe-hidpi-scale.png
```

Current WPE limitations:

- The integrated path is still a CPU readback into shared memory, not a final zero-copy EGL texture import into Verde's renderer.
- The HiDPI viewport/device-scale contract is now wired for WPE, but it still needs repeated subjective testing across monitors and resize/move cases.
- The page reports `prefers-color-scheme: dark` as false. A WPE platform `WPE_SETTING_DARK_MODE` attempt was tested after WPE view creation, but it did not flip the media query and made the captured page render mostly blank, so that change was removed. Do not re-add it without proving visible page rendering and `scheme:true`.
- Popup/window creation, downloads, context menus, IME composition, clipboard integration, and WebKit process crash recovery are not hardened yet.
- `snapshot_texture` remains the default until WPE scale, input, clipping, and subjective scroll feel pass repeated app-level testing.

## Current Blocker

The helper can create a GTK/WebKit Wayland toplevel and position it as a diagnostic overlay, but this is not yet a true child/subsurface of the SDL window. GTK/WebKitGTK does not expose a stable public API in this code path for taking the WebKit widget's internal `wl_surface` and reparenting it under SDL's `wl_surface` with the Wayland subsurface protocol.

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
