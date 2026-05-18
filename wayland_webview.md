# Wayland Native WebView Embedding Goal

This document is a Wayland-only handoff for investigating and implementing a real embedded WebKitGTK browser surface in Verde. Ignore macOS, Windows, X11, and CEF for this goal.

## Goal

Make Linux Wayland browser scrolling and rendering feel native by replacing the current hidden WebKitGTK snapshot pane with a real Wayland-native browser surface positioned inside Verde's Palette browser pane.

The target result is:

- Verde still uses SDL3 GPU and Palette for the app shell.
- The browser toolbar, URL field, sidebar, chat, terminal panes, modals, and menus remain Palette-rendered.
- Only the browser content rectangle is a native WebKitGTK Wayland surface.
- The native surface follows pane movement, resize, split changes, window moves, and scale changes.
- WebKit owns visible browser pixels directly, so scroll, animations, text caret, video, and input are not gated on snapshot capture.
- The current snapshot texture path remains as a fallback while the Wayland embedding path is proven.

Do not work on CEF for this goal. Do not treat macOS or Windows as blockers.

## Why This Is Needed

The current Linux Wayland native webview path is snapshot based:

1. Verde forwards input to a hidden WebKitGTK view.
2. WebKit updates its internal page state.
3. The helper requests a visible snapshot.
4. The helper writes pixels.
5. Verde reads and uploads the bitmap into a GPU texture.
6. Palette draws the texture in the pane.

That model can be made usable, but it cannot match native browser feel. Fast scroll can show stale frames, latency, jitter, or bounce because visible pixels arrive through asynchronous capture and upload instead of direct compositor presentation.

The Wayland embedding goal is to prove whether Verde can put WebKit's own Wayland surface at the exact pane rect.

## Non-Goals

- Do not replace Palette.
- Do not move the entire Linux app to GTK.
- Do not require CEF.
- Do not solve macOS or Windows.
- Do not optimize the existing snapshot path as the primary deliverable, except for fallback safety.
- Do not make the browser cover Palette toolbar chrome or global UI overlays.

## Current Relevant Files

Wayland/Linux WebKitGTK path:

- `packages/desktop/src/browser/platform/linux_webkitgtk.c`
- `packages/desktop/src/browser/platform/linux_webkitgtk.zig`
- `packages/desktop/src/browser/platform/linux_helper_main.zig`
- `packages/desktop/src/browser/platform/linux_ipc.zig`

Backend and app integration:

- `packages/desktop/src/browser/native_webview_backend.zig`
- `packages/desktop/src/browser/controller.zig`
- `packages/desktop/src/browser/types.zig`
- `packages/desktop/src/browser/input.zig`
- `packages/desktop/src/state.zig`
- `packages/desktop/src/ui/browser.zig`
- `packages/desktop/src/main.zig`

Build/dev entry points:

- `mise.toml`
- `packages/desktop/build.zig`
- `scripts/dev/check-desktop-build-deps.sh`
- `testing.md`

Expected dev command:

```bash
mise run dev
```

This should use `-Dbrowser-backend=native_webview`. It should not download, link, or compile CEF.

## Architecture Target

Add a new Linux Wayland presentation mode, separate from the current snapshot mode.

Suggested presentation kinds:

- `snapshot_texture`: current hidden WebKit snapshot fallback.
- `native_wayland_surface`: new embedded Wayland surface mode.

In `native_wayland_surface` mode:

- Verde computes the browser content rectangle from Palette layout.
- The Linux backend receives `setPaneBounds` updates.
- The backend positions and resizes a WebKitGTK-owned Wayland surface to match that rectangle.
- Palette stops drawing a browser texture for that pane.
- Input should be native wherever possible, because the Wayland compositor and WebKit surface handle pointer, wheel, keyboard, IME, caret, and selection directly.

The browser surface must be clipped to the browser content rect, not the full browser pane including toolbar.

## Critical Unknowns To Prove First

Before making broad app changes, build a small prototype or focused branch spike that answers these questions:

1. Can SDL3 expose Verde's Wayland `wl_display` and parent `wl_surface` reliably from the app window?
2. Can GTK/WebKitGTK expose or be coerced into a `wl_surface` suitable for parenting or subsurface positioning?
3. Can a WebKitGTK Wayland surface be made a child/subsurface of the SDL window surface?
4. Can that child surface be moved and resized smoothly to arbitrary pane rectangles?
5. Can it be clipped to the pane content rectangle?
6. Does native scroll work smoothly in that surface while the SDL/Palette app continues rendering?
7. What happens when Palette UI should appear above the browser, such as menus, modals, command palettes, or inspector popovers?

If any answer is "no" for GTK/WebKitGTK under SDL Wayland, document the exact blocker and fall back to optimizing snapshot mode.

## Prototype Milestone

First milestone should be intentionally small:

- Launch Verde on Wayland.
- Open a browser surface at a fixed rectangle, such as `x=800, y=100, w=700, h=600`.
- Navigate to `https://lytx.io/`.
- Confirm native scroll is smooth and immediate.
- Confirm no snapshot texture path is used for the visible browser pixels.
- Confirm moving/resizing the main window does not leave the surface detached.

Do not start by wiring every pane feature. First prove that SDL Wayland plus WebKitGTK Wayland surface embedding is possible.

## Implementation Plan

1. Add backend capability detection.

   Detect Wayland at runtime from SDL/native window properties and environment. Keep snapshot fallback when the required Wayland handles or GTK/WebKit surface access are unavailable.

2. Add a Linux presentation kind.

   Extend browser runtime metadata so `verde live status --json` can report something like:

   ```json
   {
     "runtime_kind": "native_webview",
     "presentation_kind": "native_wayland_surface"
   }
   ```

3. Extract SDL Wayland handles.

   In `packages/desktop/src/main.zig` or the Linux backend boundary, get the native Wayland display/window/surface from SDL3. Keep this isolated so non-Wayland builds are unaffected.

4. Create a WebKitGTK surface.

   Use the existing Linux helper code as the starting point, but change presentation away from hidden snapshots. The WebKit view should be visible through a Wayland-native surface path.

5. Parent or position the surface.

   Investigate one of:

   - Wayland subsurface protocol if GTK exposes usable `wl_surface` handles.
   - GTK/Wayland APIs for embedding or foreign surfaces.
   - A helper toplevel window positioned over the SDL window only as a diagnostic fallback, not as the release answer unless clipping/focus are acceptable.

6. Wire pane bounds.

   Reuse existing `setPaneBounds` flow. On every browser pane layout update, send exact logical or pixel bounds to the Linux backend. Be precise about scale conversion.

7. Route focus and input.

   Prefer native compositor routing. If the surface is a real child/subsurface, clicks and wheel should go directly to WebKit when inside the browser content rect. Palette should retain ownership of toolbar and non-browser UI.

8. Handle hide/show/lifecycle.

   Browser close, app minimize, pane hidden, split removed, and app shutdown must hide or destroy the Wayland surface without leaving orphan GTK/WebKit surfaces.

9. Keep fallback mode.

   If native Wayland embedding fails at runtime, emit a useful diagnostic and fall back to `snapshot_texture`.

## Overlay And Z-Order Constraints

Native surfaces often do not compose like Palette-drawn textures. This is the main UI risk.

Acceptance rules:

- The browser surface must never cover the URL toolbar.
- The browser surface must never cover the sidebar.
- The browser surface must not cover terminal/chat panes outside its content rect.
- Palette modals and menus should appear above the browser, or the browser must be hidden while those UI surfaces are open.
- Splitter drag handles must remain usable.
- Browser focus must not trap global shortcuts meant for Verde.

If Wayland surface stacking cannot satisfy these rules, document the limitation and decide whether temporary hiding during overlays is acceptable.

## Testing Checklist

Run on a real Wayland session, preferably the primary Hyprland environment.

## Autonomous Hyprland Test Loop

The agent should test on Hyprland directly and should not require the user to manually verify every iteration.

Use the normal dev entry point:

```bash
mise run dev
```

For startup browser smoke:

```bash
VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ mise run dev
```

If the tool environment cannot keep the GUI attached through `mise run dev`, build first and then launch the built app from the active graphical session:

```bash
zig build --release=safe
VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL=https://lytx.io/ ./packages/desktop/zig-out/bin/verde app
```

Use live status to confirm the runtime and presentation mode:

```bash
./packages/desktop/zig-out/bin/verde live status --json
```

Expected for this goal after native embedding is implemented:

- `runtime_kind: "native_webview"`
- `presentation_kind: "native_wayland_surface"`
- `visible: true`
- `runtime_initialized: true`
- URL is `https://lytx.io/` or the currently tested URL.

Use live browser eval for page-side checks:

```bash
./packages/desktop/zig-out/bin/verde live browser eval --script 'JSON.stringify({url:location.href,title:document.title,scrollY,innerWidth,innerHeight,devicePixelRatio})' --json
```

Process checks:

```bash
pgrep -af 'verde-browser-linux|zig-out/bin/verde|mise run dev'
```

Hyprland/window checks that are useful while debugging:

```bash
hyprctl activewindow
hyprctl clients
```

Screenshots can be captured without involving the user:

```bash
grim /tmp/verde-wayland-webview.png
```

For pane-specific screenshots, use a geometry crop after locating the app/pane:

```bash
grim -g '<x>,<y> <w>x<h>' /tmp/verde-wayland-webview-pane.png
```

Automated input can be used for basic smoke tests, but visual/feel quality still needs careful interpretation:

```bash
wtype 'https://lytx.io'
ydotool
```

When using automated input, record exactly what command or gesture was used and confirm the page state afterward with `verde live browser eval`.

The agent should record evidence in the goal response:

- Build command and result.
- Launch command.
- `verde live status --json` browser fields.
- Screenshot paths.
- Any Hyprland-specific observations.
- Whether native Wayland surface mode or snapshot fallback was active.

Basic:

- `mise run dev`
- Open browser pane.
- Navigate to `https://lytx.io/`.
- Verify `verde live status --json` reports `native_wayland_surface`.
- Scroll slowly and quickly.
- Stop scrolling and verify the page does not jitter, bounce, or keep moving from stale frames.
- Resize the main window.
- Resize/split panes.
- Hide and show the browser.
- Close the app and confirm no helper remains.

Input:

- Click links/buttons.
- Type in inputs.
- Use textarea editing.
- Select/copy/paste text.
- Use keyboard navigation.
- Use mouse back/forward buttons if available.
- Test touchpad and wheel if both devices are available.

UI composition:

- Open sidebar interactions while browser is visible.
- Open Palette modals/menus above or near browser.
- Focus terminal/composer after browser focus.
- Drag splitters around the browser pane.

Diagnostics:

```bash
./packages/desktop/zig-out/bin/verde live status --json
./packages/desktop/zig-out/bin/verde live browser eval --script 'JSON.stringify({url:location.href,title:document.title,scrollY})' --json
pgrep -af 'verde-browser-linux|zig-out/bin/verde'
```

## Pass Criteria

Wayland native embedding is successful when:

- Browser pixels are presented by WebKit's native Wayland surface, not by snapshots.
- Scroll feels immediate and native on `https://lytx.io/`.
- Fast scroll does not show stale-frame bounce.
- Pane resize and split changes keep browser content aligned.
- Browser content is clipped to the browser content rect.
- Palette toolbar, sidebar, terminal/chat panes, and modal UI remain usable.
- Focus and keyboard behavior are no worse than snapshot mode.
- The app shuts down cleanly without orphan browser processes or surfaces.

## Fallback If Embedding Fails

If true Wayland embedding is blocked, write down the exact blocker and keep `snapshot_texture` as the default while optimizing it separately.

Snapshot optimizations to consider only after embedding is proven blocked:

- Replace file-based frame transfer with shared memory or `memfd`.
- Add frame sequence numbers and discard stale frames.
- Avoid Cairo scaling on every frame.
- Reduce full-frame copies where possible.
- Request frames on a controlled compositor-like cadence.

These are fallback improvements. They are not equivalent to native Wayland embedding.
