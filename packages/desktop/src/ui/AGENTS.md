# Native UI

- SDL3 owns windows, events, logical size, drawable pixels, and display scale; SDL_GPU renders; Palette owns layout and batches. This is not HTML/CSS or ImGui.
- `main.zig` coordinates sizing/events; `palette_frame_renderer.zig` owns rendering/fonts. Inspect `window.getSize`,  `SDL_GetWindowSizeInPixels`, and `SDL_GetWindowDisplayScale` before adding scale factors. Layout, commands, and renderer must share a coordinate space; render against drawable pixels.
- Use explicit `palette.Rect`s, shared spacing, measured text, and clamped ratios. Name unusual geometry tokens. Never guess character widths for truncation or caret placement.
- Start render methods with a short region comment; explain non-obvious geometry. For major changes check wide, laptop, short-height, and differing-scale layouts in the real app with screenshots, subject to root session-safety rules.
- Transcript scrolling is direct: apply wheel/keyboard offsets once, without inertia or continuous frames. Clear pending scroll on thread switches and jump-to-bottom.

## Text fields

Every changed input needs a metric-aligned caret; click/drag, double-click word, and triple-click field/line selection; Left/Right/Home/End with Shift; platform select-all/copy/cut/paste; selection-aware insertion/Backspace/Delete; and blur cleanup. Strip control characters in single-line fields.

References: `browser.zig` (URL bar), `layout.zig` (modal fields). Keep transcript categories centralized in `chat_panel.zig`; provider event rules live in [../providers/AGENTS.md](../providers/AGENTS.md).
