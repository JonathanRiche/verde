# Palette UI Migration Plan

## Current State

The desktop app now builds its active UI path through Palette render-batch commands and SDL event routing. The root frame, sidebar, chat workspace, composer, browser placeholder, terminal placeholder, debug surface, theme metrics, and desktop text renderer have been moved off the previous immediate-mode UI backend.

Key entry points:

- Root layout: `packages/desktop/src/ui/layout.zig`
- SDL frame loop: `packages/desktop/src/main.zig`
- Palette SDL_GPU renderer: `packages/desktop/src/ui/palette_frame_renderer.zig`
- Sidebar: `packages/desktop/src/ui/sidebar.zig`
- Chat workspace: `packages/desktop/src/ui/chat_panel.zig`
- Terminal dock shell: `packages/desktop/src/ui/terminal_panel.zig`
- Browser surface: `packages/desktop/src/ui/browser.zig`

## Completed

- Removed the old desktop UI backend imports from `packages/desktop/src`.
- Removed the old UI backend dependencies from `packages/desktop/build.zig` and `packages/desktop/build.zig.zon`.
- Removed the old transcript selectable-text cache and API from `state.zig`.
- Replaced the root workspace host with explicit `palette.Rect` layout.
- Replaced chat workspace rendering with Palette rect/text commands.
- Replaced terminal dock rendering with a Palette-owned shell.
- Replaced theme ownership with Palette-oriented color and font metric helpers.
- Moved desktop text rendering to Palette SDL_GPU text backed by SDL_ttf.
- Updated desktop docs to describe Palette as the active UI stack.

## Follow-Up Refinement

- Restore rich transcript rendering on top of Palette, including markdown selection, changed-file expansion, image cards, command blocks, and scroll virtualization.
- Replace placeholder terminal shell with the full terminal viewport using Palette-owned glyph clipping, cursor inversion, split panes, tab rename input, and context menus.
- Finish browser pane fidelity by routing the live browser texture and URL editing through Palette-owned input and image APIs.
- Add Palette-owned scroll regions, text selection, clipboard paste, IME display, and accurate caret placement for modal/input-heavy paths.
- Add a Palette texture registry so components can request images without depending on pre-existing renderer texture ids.

## Verification

- `rg` over the desktop source/build path is clean for the removed UI backend names.
- `git diff --check` passes.
- `mise run dev` builds and launches; the verification command was stopped by timeout so the app process would not be left running.
