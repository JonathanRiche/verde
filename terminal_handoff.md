# Terminal Resize Handoff

## Current Symptom

The Verde desktop terminal pane still has a Neovim/LazyVim resize bug when a pane is zoomed and unzoomed. The current local build has improved the behavior compared with the starting point, but it is not fully fixed.

Observed behavior from the latest user videos/screenshots:

- Starting in a small pane with Neovim open is fine.
- Full zoom previously repainted correctly only when Verde sent a synthetic in-band size report after resize.
- Shrinking back down was wrong when that same synthetic report was sent on shrink: LazyVim kept a tall-layout placement and the small pane showed lower dashboard rows such as `Find Text` near the top.
- Removing the synthetic report fixed shrinking back down, but full zoom stopped repainting to the full-height layout.
- The current patch sends the synthetic in-band size report only when row count grows, not when it shrinks. This is the best state reached so far, but it still needs verification/final fixing.

## Files Changed In This Work

- `packages/desktop/src/terminal/terminal.zig`
- `packages/desktop/src/terminal/sessionizer.zig`
- `packages/desktop/src/ui/terminal_panel.zig`

There are unrelated dirty files in the worktree that should not be treated as part of this bug unless the user says otherwise.

## What Was Added

### Terminal diagnostics

Run Verde with:

```bash
VERDE_TERMINAL_LAYOUT_LOG=1 ./zig-out/bin/verde app
```

Logs are written to:

```bash
/home/rtg/.local/share/verde/Native/logs/verde.stderr.log
```

Useful log filter:

```bash
python3 -c "from pathlib import Path; lines=Path('/home/rtg/.local/share/verde/Native/logs/verde.stderr.log').read_text(errors='replace').splitlines(); keys=('terminal render snapshot','terminal alternate viewport reset','daemon-resize-response','daemon-write-apply','resize-redraw-check','terminal resizePaneToFit'); print('\n'.join(l for l in lines if any(k in l for k in keys))[-20000:])"
```

Look for transitions like `230x28 -> 230x57 -> 230x28`, and compare the `terminal render snapshot` row text. Good small state has the top of the Neovim logo at row 2. Bad small state has dashboard action rows like `Find Text` near row 2.

### Sessionizer changes

`sessionizer.zig` now:

- Logs PTY resize details.
- Applies `TIOCSWINSZ` to the PTY master.
- Sends `SIGWINCH` to the foreground process group and descendant process groups.
- Polls briefly after writes/resizes and returns ordered output text plus offsets to the desktop process.

This was added because resize-triggered Neovim output could arrive before or after Verde refreshed the local Ghostty model. Keeping the output ordered matters.

### Terminal model/render changes

`terminal.zig` now:

- Logs render snapshots under `VERDE_TERMINAL_LAYOUT_LOG`.
- Clears synchronized-output mode after local terminal model resize.
- Resets alternate-screen viewport to top on resize/replay.
- Applies daemon resize/write responses immediately so resize output is not delayed until a later tail.
- Sends Ctrl-L (`0x0c`) after resize when a foreground TUI is detected.
- Sends Ghostty in-band size reports only when the pane grows, because sending them on shrink caused LazyVim to repaint the tall dashboard into the small pane.

`terminal_panel.zig` now clips terminal rendering to the pane rect and pre-resizes the active pane before drawing. This prevents stale oversized cells/background/cursor from drawing outside the pane.

## Important Findings

The renderer clipping was not the root cause. Logs proved the terminal model itself was wrong after some shrink paths. For the bad state, `terminal render snapshot` already contained `Find Text` in the top rows before rendering.

The local alternate-screen clear path caused a separate regression: after zoom/unzoom, the pane could go blank with only a cursor. That was caused by locally feeding `ESC[0m ESC[2J ESC[H]` into Ghostty without guaranteed application repaint. Do not reintroduce that as a fix.

The synthetic in-band size report is double-edged:

- Helpful on grow/full zoom: LazyVim tends to redraw to the larger layout.
- Harmful on shrink: LazyVim can preserve/repaint the larger layout placement, causing cropped dashboard rows in the small pane.

## Next Things To Investigate

1. Verify the current grow-only size-report behavior with the user. If it still fails, collect a fresh video and fresh log excerpt.
2. Try changing resize ordering so the PTY/daemon receives the new winsize before `self.terminal.resize(...)`, then apply resize-triggered output into a model that already matches the PTY size. The current code updates `self.cols/self.rows` and resizes the local Ghostty terminal before backend resize.
3. Check whether Ctrl-L should be sent before or after draining resize output. Neovim may emit its own SIGWINCH redraw, and Verde may currently be applying Ctrl-L output in a confusing order.
4. Confirm whether `in_band_size_reports` mode should be answered by Verde manually at all, or whether libghostty has an API/event/callback for resize/size-report responses that Verde should be using instead.
5. Add a deterministic terminal resize test if feasible: launch a PTY with an alternate-screen app or a small Zig/Python TUI that records winsize and paints row markers, then assert `RenderState` rows after grow/shrink.

## Ghostty / libghostty Pointers

Upstream Ghostty repo: https://github.com/ghostty-org/ghostty

Ghostty docs describe the core as `libghostty`, a cross-platform C-ABI compatible library that provides terminal emulation, font handling, and rendering capabilities: https://ghostty.org/docs/about

The Ghostty GitHub README points people at Ghostling and the `examples` directory for smaller C/Zig examples of using `libghostty`, and says the Doxygen site is the current C API reference. Start with:

- https://github.com/ghostty-org/ghostty
- https://github.com/ghostty-org/ghostling
- `ghostty/src/terminal/` in upstream for Zig internals, especially resize, screen, and render-state code.
- Upstream examples that call resize/render APIs. Search terms: `ghostty_terminal_resize`, `RenderState`, `terminal.resize`, `size_report`, `in_band_size_reports`, `synchronized_output`, `scrollViewport`.

The likely missing piece is an intended libghostty resize/renderer contract. Verde currently imports `vendor/ghostty_vt.zig` and manually calls terminal resize, render-state update, stream input, and synthetic size-report encoding. If libghostty exposes a higher-level surface/resize API, or a callback/event for terminal queries and size reports, using that may avoid these ordering bugs.

## Build Command

```bash
zig build --release=safe -Dbrowser-backend=native_webview --summary all
```

## User Reproduction

1. Run Verde with `VERDE_TERMINAL_LAYOUT_LOG=1`.
2. Open the built-in terminal pane.
3. Start `nvim` / LazyVim dashboard.
4. Zoom the pane full height.
5. Unzoom back to the small split pane.
6. Compare the Neovim dashboard placement in both states.

The user has been recording videos in `~/Videos`, with names like `screenrecording-2026-05-23_02-04-19.mp4`. The latest video usually shows the active failure clearly.
