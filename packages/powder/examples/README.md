# Powder Examples

Run examples from `packages/powder`.

```bash
zig build run-text-area-lab
zig build run-component-lab
```

The text area lab focuses on multiline editing. The component lab opens a separate SDL3 window for the retained controls added after `TextArea`: text input, selectable text, button, icon button, checkbox, toggle, listbox, select, tabs, scroll area, menu, modal, table, and code view.

Rendering is intentionally command-based until the SDL_GPU presenter in `src/renderer.zig` grows real vertex/index buffer submission.
