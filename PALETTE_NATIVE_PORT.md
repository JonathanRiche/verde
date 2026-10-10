# Verde desktop on palette-native

Branch `desktop/palette-native`, based on master `aa8a4f7c`. palette-native vendored from
`palette-decouple-research` master `32e7458` into `packages/palette` (see `VENDORED_FROM`).

## What changed

- **Build**: SDL3, SDL3_ttf, zsdl and wayland-client are gone from `packages/desktop`. Libc-linked
  executables use `.use_llvm = true, .use_lld = true`. The Linux browser helper builds
  `linux_wpe.c`, `linux_wpe_platform.c` and `frame_socket.c` (option `browser-linux-fdo`, default on).
- **Platform**: the main loop runs on `palette.platform.App`/`Window`. That covers events, keyboard,
  text input and pre-edit, mouse and wheel, focus, resize and scale, theme, `waitEvent` with timeout,
  and cross-thread wakeup through `App.wakeup` (`runtime/loop_wakeup.zig`). `ui/host.zig` provides
  the clipboard, held keys, modifiers and cursors. prefPath is computed the same way as before.
- **Rendering**: `palette.Graphics` + `WindowRenderer` (Vulkan on Linux, Metal on macOS, D3D on
  Windows), with `palette.fonts` (0.86 scale, glyphInk). Textures, terminal cells and inline images
  go through Graphics. Browser frames go through `streamTexture`, and on Linux/Vulkan through
  zero-copy `importDmabufTexture`.
- **Browser**:
  - The WPE helper is ported to the upstream frame socket (HELLO/MODE/FRAME/RELEASE over
    SEQPACKET, fd 243), and dma-buf frames are imported with release fences.
  - It falls back to shm automatically, or when `VERDE_BROWSER_LINUX_FRAME_TRANSPORT=shm` is set.
  - `linux_wayland_subsurface.c` and the WPE Wayland probe are removed.
  - macOS hosts WKWebView in the NSView and Windows hosts WebView2 in the HWND.
- **macOS clipboard images**: `macos_clipboard.m` is replaced by `App.getClipboardImage`.
- **Dev hooks** (off unless the env is set):
  - `VERDE_PALETTE_SNAPSHOT=/p.png`: touching `/p.png.request` writes the next frame, rendered
    offscreen, to `/p.png`.
  - `VERDE_PALETTE_INJECT=/p`: an event script at `/p` is replayed through the normal dispatch
    path (see `ui/dev_inject.zig`).
- **Trial launcher**: `scripts/run-palette-native-trial.sh [--visible] [--no-build]`.

Diff vs `aa8a4f7c`, excluding `packages/palette`: 246 files (11 added, 46 modified, 189 deleted,
mostly zsdl). `packages/palette`: 174 files.

## Test results

| Suite | Port | Baseline aa8a4f7c |
|---|---|---|
| desktop (`zig build test --release=safe -Dbrowser-backend=native_webview`) | 1095/1099 (3 skip, 1 fail) | 1086/1090 (same failure) |
| palette | 206/209 (3 skip) | does not compile |

The failure is the same on both sides: `state.test.ordinary browser focus and deletion preserve
exact pane runtime ownership`, which predates the port.

Cross-compile checks:
- macOS: compiles; linking needs the real Xcode toolchain (swift libs, libfff_c.dylib).
- Windows: compiles; the only error is the WebView2Loader link.

## Live trial (Linux)

The trial ran isolated:
- temp HOME/XDG under `/tmp/vt-port`, its own daemon, socket and live endpoint
- `VERDE_SESSION_DAEMON_CHAT_STUB=1`
- app id `palette-test-verde-port`

The user's Verde and daemon were never contacted or signalled.

Verified live:
- Starts on Vulkan ("palette renderer active backend=vulkan") with the isolated daemon.
- `verde live status` and `workspace create` work against the trial endpoint.
- The sidebar, chat pane, composer pills and the MCP onboarding modal render correctly
  (offscreen snapshots).
- The snapshot and inject hooks work.

**Blocked**: during the trial, Hyprland workspace 5 moved off the hidden PALETTE-TEST output onto
eDP-1, and the `5 → PALETTE-TEST` workspace rule is no longer active. The trial window was briefly
visible on the laptop screen before it was killed. Nothing in the user's compositor setup was
changed. The rest of the feature walk, the side-by-side baseline comparison and the perf runs are
waiting until the hidden output is restored. The launcher refuses hidden mode while ws 5 is not on
PALETTE-TEST.

### Feature checklist

| Feature | Old (aa8a4f7c) | New | Status | Notes |
|---|---|---|---|---|
| Window open, Vulkan render | SDL_GPU | palette Graphics | works | live |
| Fonts, icons, theme colors | SDL_ttf | palette.fonts | works | live snapshot |
| Sidebar, workspace list | ✓ | ✓ | works (render) | live |
| Chat pane / composer render | ✓ | ✓ | works (render) | live |
| Modal (MCP onboarding) | ✓ | ✓ | works (render) | live |
| Long messages, code, markdown | ✓ | ? | not trialed | blocked |
| Composer typing, multiline, selection, IME pre-edit | ✓ | ? | not trialed | inject hook ready |
| Slash commands, pills/selects | ✓ | ? | not trialed | blocked |
| Scrolling (chat, terminal, lists, sidebar; wheel/precise) | ✓ | ? | not trialed | blocked |
| Tabs (terminal/browser/chat) | ✓ | ? | not trialed | blocked |
| Panes split/move/resize/drag | ✓ | ? | not trialed | blocked |
| Terminal cells, colors, inline images, cursor | ✓ | ? | not trialed | unit tests pass |
| Browser load/scroll/click/type, scale | ✓ | ? | not trialed | blocked |
| Browser dma-buf zero-copy | n/a (shm) | new | not trialed live | unit tests pass |
| Clipboard copy/paste | ✓ | ? | not trialed | never log contents |
| Keybind table | ✓ | ? | not trialed | binding table unchanged |
| Cursor shapes | ✓ | ? | not trialed | |
| Resize, maximize, hide/show | ✓ | ? | not trialed | |
| Close/quit | ✓ | ? | partial | SIGTERM shutdown clean (GUI + daemon exit); UI quit not trialed |

## Performance

Not measured yet (blocked as above). Planned: idle, composer typing, terminal scroll and an animating
browser page. For each, CPU % from /proc deltas across the GUI, helper and WebKit processes, PSS from
smaps_rollup, and GPU memory from DRM fdinfo, for both the port and aa8a4f7c.

## Known gaps

- `measureText` is advance-based. No IME candidate rect is sent to the compositor.
- On Wayland the system theme is unknown, so Verde falls back to dark.
- Intermediate commits don't build on their own; the branch head does.
- CI may need a `wpe-platform-2.0` package. Windows bootstrap scripts still fetch SDL.
- The helper sources keep their upstream SDL comments so re-syncs stay byte-identical.
- Hidden or background browser runtimes don't drain the frame socket. The helper holds up to 8
  frames, then falls back to shm.
- The "SDL thread stall" log marker is kept for log continuity.

## Manual checklist

Run `scripts/run-palette-native-trial.sh --visible`, then check:

1. Type in the composer, including IME pre-edit. Select text and copy/paste it.
2. Scroll chat, sidebar and terminal with wheel and touchpad.
3. Open, switch and close terminal, browser and chat tabs. Split, drag and resize panes.
4. Browser: load a page, scroll, click and type. The log should say "frame transport: dmabuf".
5. Walk the keybinds. Check cursor shapes over links, text and splitters.
6. Resize, maximize and hide/show the window. Quit.
