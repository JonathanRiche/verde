# Native UI

- Palette owns everything: windows, events, logical size, drawable pixels, and display scale (Wayland/Win32/AppKit backends), GPU rendering (Vulkan/D3D11/Metal), layout, and batches. This is not HTML/CSS, ImGui, or SDL.
- `main.zig` coordinates sizing/events; `palette_frame_renderer.zig` owns rendering/fonts. Inspect `window.logicalSize()`, `window.pixelSize()`, and `window.scale()` before adding scale factors. Layout, commands, and renderer must share a coordinate space; render against drawable pixels.
- Use explicit `palette.Rect`s, shared spacing, measured text, and clamped ratios. Name unusual geometry tokens. Never guess character widths for truncation or caret placement.
- Borders, rings, and dividers follow [Palette's crisp-chrome rules](../../../palette/AGENTS.md): whole-pixel strokes, edge-snapped rects, one `panel` command per bordered surface.
- Start render methods with a short region comment; explain non-obvious geometry. For major changes check wide, laptop, short-height, and differing-scale layouts in the real app with screenshots, subject to root session-safety rules.
- Transcript scrolling is direct: apply wheel/keyboard offsets once, without inertia or continuous frames. Clear pending scroll on thread switches and jump-to-bottom.

## Text fields

Every changed input needs a metric-aligned caret; click/drag, double-click word, and triple-click field/line selection; Left/Right/Home/End with Shift; platform select-all/copy/cut/paste; selection-aware insertion/Backspace/Delete; and blur cleanup. Strip control characters in single-line fields.

References: `browser.zig` (URL bar), `layout.zig` (modal fields). Keep transcript categories centralized in `chat_panel.zig`; provider event rules live in [../providers/AGENTS.md](../providers/AGENTS.md).

## Selectable text

Content text (transcripts, the Companion conversation, logs, details, error bodies) must be selectable and copyable; controls and chrome (buttons, chips, menus, sidebar rows, tabs, badges) stay plain. Required: click-drag selection with a visible highlight that auto-scrolls past the viewport edge, double-click word and triple-click message/line selection, primary-modifier+C copy and +A select-all once the surface was clicked, a right-click Copy / Select all menu (`context_menu.zig` chrome), and Escape to clear. Drive rendering, hit-testing, highlight, and copy from one positioned line layout so they cannot drift; see `itemTextLayout` in `companion.zig` and the transcript selection in `chat_panel.zig`. Never log copied text.

## Cursors

Every hit region needs its OS cursor. Each surface exposes `systemCursorAt(x, y) ?palette.platform.CursorShape` and `main.zig` `syncMouseCursor` consults it in z-order (topmost surface first). Return `.text` over selectable text (only where text is actually drawn, not the whole panel) and text fields, `.pointer` over buttons, chips, dropdowns, links and clickable rows, `.grab` / `.grabbing` or the resize shapes for drag handles (keep the drag cursor while a drag is captured, even off the handle), and `.default` over plain chrome or modal dismiss layers. Example: `systemCursorAt` in `companion.zig`.

