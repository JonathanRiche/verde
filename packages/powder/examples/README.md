# Powder Examples

See [`../README.md`](../README.md) for SDL3, SDL3_ttf, pkg-config, and shader
setup before running the labs.

Run examples from `packages/powder`.

```bash
zig build run-text-area-lab
zig build run-component-lab
zig build run-layout-lab
zig build run-layout-review
```

The text area lab focuses on multiline editing. It renders through `powder.RenderBatch` plus Powder's SDL debug presenter, so the example does not manually lay out TextArea text.

The component lab opens a separate SDL3 window for the retained controls added after `TextArea`: text input, selectable text, button, icon button, checkbox, toggle, listbox, select, tabs, scroll area, menu, modal, table, and code view.

The layout lab opens an SDL3 window for `powder.layout`. Resize it to inspect
grid tracks, flex growth, flex wrapping, margins, padding, and runtime
`setBounds()` behavior with real controls. It also renders the desktop
`verde_logo.png` asset through the SDL texture resolver path.

The layout review example is a CLI example for `powder.layout`. It computes a
Verde-style command prompt layout, applies the rects to retained controls, emits
a render batch, and prints the final bounds for review.

Rendering is command-based. Components emit `powder.RenderBatch` commands, and
the labs use Powder's SDL presenter for local inspection.
