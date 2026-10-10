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
    path (see `ui/dev_inject.zig`). Verbs include click, drag, move, wheel, precise, key, text, type, edit, focus,
    leave, theme, hidden, shown and close. `cursor` writes the current cursor name to `/p.cursor`.
- **Trial launcher**: `scripts/run-palette-native-trial.sh [--visible] [--no-build]`.

Diff vs `aa8a4f7c`, excluding `packages/palette`: 246 files (11 added, 46 modified, 189 deleted,
mostly zsdl). `packages/palette`: 174 files.

## Test results

| Suite | Port | Baseline aa8a4f7c |
|---|---|---|
| desktop (`zig build test -Doptimize=ReleaseSafe -Dbrowser-backend=native_webview`) | 1095/1100 (3 skip, 2 fail) | 1085/1090 (3 skip, the same 2 fail) |
| palette | 206/209 (3 skip) | does not compile |

The failures are identical on both sides and predate the port:
- `state.test.ordinary browser focus and deletion preserve exact pane runtime ownership`
- `app.keybinds.test.prefix object override changes key and merges bindings` (`expected 95,
  found 94`). It only fails in the full run; `-Dtest-filter=keybinds` passes on both.
- `state.persistence.test.partial or malformed committed routes stay quarantined` logs an error
  on both.

Cross-compile checks:
- macOS: compiles; linking needs the real Xcode toolchain (swift libs, libfff_c.dylib).
- Windows: compiles; the only error is the WebView2Loader link.

## Live trial (Linux)

### Isolation

Each build ran with its own:
- temp HOME and XDG dirs (`/tmp/vt-port`, `/tmp/vt-base`)
- daemon, socket and live endpoint
- browser profile, with `VERDE_SESSION_DAEMON_CHAT_STUB=1`
- app id (`palette-test-verde-port` / `-base`)

Both ran on Hyprland workspace 99, pinned to the headless PALETTE-TEST output. Before each launch
the launcher checks `hyprctl workspaces -j` and `hyprctl monitors -j`. After launch it checks
`hyprctl clients -j` to confirm the window is on ws 99 and not focused, and kills the window if it
isn't. Nothing synthesized input into the user's session:
- input came from the in-process `VERDE_PALETTE_INJECT` script
- screenshots came from the offscreen `VERDE_PALETTE_SNAPSHOT` readback
- processes were only killed by matching `HOME=/tmp/vt-<tag>` in their environment

The user's Verde, daemon and WebKit processes were never contacted or signalled.

**Incident (earlier run):** Hyprland ws 5 moved from PALETTE-TEST to eDP-1 (the laptop screen), and
the trial window was briefly visible there before it was killed. ws 5 is no longer used. The
launcher (`scripts/run-palette-native-trial.sh`) now pins to ws 99 and refuses hidden mode unless
ws 99 is on PALETTE-TEST.

### Baseline method

The baseline was built from a scratch copy of aa8a4f7c, not a worktree. The copy had the same dev
hooks added on top: offscreen snapshot, an inject script fed into the SDL event loop, a `cursor`
report and a frame counter. Both builds then ran the same inject scripts. Side-by-side snapshots
are in `/tmp/pn-shots`:
- `base-NN-*.png` and `port-NN-*.png` for each step
- `sbs-NN-*.png` for the composites
- `m-*.png` for the montages

### Feature checklist

"Match" means the base and port snapshots are identical apart from antialiasing noise, plus any
listed differences.

| Feature | Old (aa8a4f7c) | New | Status | Notes |
|---|---|---|---|---|
| Window open, render | SDL_GPU | palette Graphics (Vulkan) | match | |
| Fonts, icons, theme colors | SDL_ttf | palette.fonts | match | identity icons differ by workspace id hash (expected) |
| MCP onboarding modal, "Not now" | yes | yes | match | 00-01 |
| Composer: unicode typing, shift+enter multiline, shift+arrow selection | yes | yes | match | 02-03 |
| IME pre-edit | not shown | not shown | parity | neither build draws pre-edit; no candidate rect |
| Slash menu, escape | yes | yes | match | 04-06 |
| Send (stub), long message, markdown (headings, lists, table, highlighted code, quote, links) | yes | yes | match | 07-13 |
| Chat wheel and precise scroll | yes | yes | match | 10-12 |
| Sidebar toggle (click, ctrl+s, ctrl+shift+s) | yes | yes | match | 14-15, 21-22 |
| Command palette (ctrl+shift+p, filter) | yes | yes | match | 20 |
| Model picker (alt+m), run config (alt+r), dir picker (alt+d), prefix help (ctrl+b ?) | yes | yes | match | 23-26 |
| Terminal: Ghostty cells, colors, truecolor, box drawing, emoji, kitty inline image, cursor | yes | yes | match | 30-31 |
| Terminal scrollback (wheel, precise) | yes | yes | match | 32-34 |
| Quick terminal (ctrl+alt+t), new tab (ctrl+b t), splits (ctrl+b v / -) | yes | yes | match | 40-43 |
| Pane focus next, grow, move, maximize toggle | yes | yes | match | 44-47b |
| Tab click, splitter drag (vertical and horizontal) with terminal reflow | yes | yes | match | 48-49b; occasional reflow prompt artifacts on both |
| Browser load, CSS animation, click, type, wheel, focus ring and caret | shm | dma-buf zero-copy | match (after fix) | 50-63; log shows "browser frame transport: dmabuf (zero-copy)" |
| `verde live browser screenshot` | yes | yes | match | |
| Browser tab new / close / switch | yes | yes | match | 90-92 |
| Cursor shapes: CSS and app chrome | yes | yes | match | port also shows `grab`/`help` (base falls back to pointer/default) |
| Settings, theme dropdown (Verde Light), system theme event | yes | yes | match | 66-74 |
| Window resize and relayout | yes | yes | match | 75-78 (tiling resize) |
| Hide/show events | yes | yes | match | 85-86; same browser status |
| Close window | yes | yes | match | GUI, helper and WPE exit; daemon and shells survive (by design) |
| Relaunch reattaches to daemon | yes | yes | works | same daemon and shell PIDs; layout, theme and URL restored |
| Clipboard copy/paste | yes | unit-tested | not trialed live | the trial shares the user's Wayland seat, so a copy would overwrite the user's clipboard; no nested compositor available |
| Window maximize (compositor) | yes | ? | not trialed live | needs the window to be active/focused, which the isolation rules forbid; pane maximize (alt+z) was checked |

### Regressions found and fixed

- **Browser pointer coordinates** (e7e00586): WPE Platform got device px instead of logical px, so
  clicks landed at 2x. Now 24,118 vs 25,118 on the baseline.
- **Browser wheel distance** (e7e00586): the port scrolled 1.25x the baseline. Now 80 CSS px per
  notch on both.
- **Browser focus** (e7e00586): the WPE toplevel was never ACTIVE, so there was no focus ring or
  caret blink. Focus/blur now toggle `WPE_TOPLEVEL_STATE_ACTIVE`.
- **CPU during animation and scroll** (f894e949): see Performance.

## Performance

Linux, hidden ws 99, one instance at a time at full width (1256x746 logical), 20 s per scenario.
CPU is % of one core from /proc deltas. Scenarios:
- idle: static page
- browser: CSS-animated page
- typing: composer, one key every 0.1 s
- term-wheel: wheel over 3000 lines of scrollback, every 0.05 s
- chat-wheel: wheel over markdown chat, every 0.05 s

| Scenario | Base GUI CPU | Port GUI CPU, before fix | Port GUI CPU, after fix |
|---|---|---|---|
| idle | 12.8% | 12.5% | 12.5% |
| browser animating | 63.5% | 99.7% | 16.4% (+4.5% WebKit) |
| composer typing | 15.7% | 15.3% | 14.8% |
| terminal wheel | 17.5% | 83.9% | 16.0% |
| chat wheel | 15.2% | 89.7% | 14.3% |

Memory (stable across scenarios):

| | Base | Port |
|---|---|---|
| PSS total (gui+daemon+browser+shell) | ~290 MiB | ~255-260 MiB |
| GUI PSS | ~68-77 MiB | ~48-50 MiB |
| GUI GPU memory (DRM fdinfo) | ~302 MiB | ~144-148 MiB |

The regression had two causes:
1. While waiting for the compositor's frame callback, the palette renderer refuses frames
   (`.throttled`), but the loop still built a full batch for each refused attempt (170-300/s).
2. The pacer only counts presented frames, so its deadlines stayed at "now" and the event-wait
   timeout was 0. The loop spun at about 100k iterations/s.

The fix skips building frames while `Renderer.ready()` is false and waits on the base timeout,
bounded by the throttle deadline. Afterwards the port presented 9.6 frames/s with no refused
attempts and about 75 loop iterations/s.

Caveat: on a hidden output both builds are limited by the frame-callback timeout (~10 fps), so on
a visible monitor the absolute numbers will be higher for both.

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
