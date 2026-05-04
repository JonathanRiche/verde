# Powder Examples

See [`../README.md`](../README.md) for SDL3, SDL3_ttf, pkg-config, and shader
setup before running the labs.

Run examples from `packages/powder`.

```bash
zig build run-text-area-lab
zig build run-component-lab
```

The text area lab focuses on multiline editing. It renders through `powder.RenderBatch` plus Powder's SDL debug presenter, so the example does not manually lay out TextArea text.

The component lab opens a separate SDL3 window for the retained controls added after `TextArea`: text input, selectable text, button, icon button, checkbox, toggle, listbox, select, tabs, scroll area, menu, modal, table, and code view.

Rendering is command-based. Components emit `powder.RenderBatch` commands, and
the labs use Powder's SDL presenter for local inspection.
