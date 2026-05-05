# Powder Examples

See [`../README.md`](../README.md) for SDL3, SDL3_ttf, pkg-config, and shader
setup before running the labs.

Run examples from `packages/powder`.

```bash
zig build run-text-area-lab
zig build run-component-lab
zig build run-layout-lab
zig build run-layout-review
zig build run-composer-prompt-review
```

The text area lab focuses on multiline editing. It renders a rounded multiline
composer through `powder.RenderBatch` plus Powder's SDL presenter, so the
example does not manually lay out TextArea text or infer panel shape.

The component lab opens a separate SDL3 window for the retained controls added after `TextArea`: text input, selectable text, button, icon button, checkbox, toggle, listbox, select, tabs, scroll area, menu, modal, table, and code view.
The package also includes unit coverage for rich inline text spans and
virtualized scroll lists; use the README snippets as the minimal integration
examples for those APIs.

The layout lab opens an SDL3 window for `powder.layout`. Resize it to inspect
grid tracks, flex growth, flex wrapping, margins, padding, and runtime
`setBounds()` behavior with real controls. It also renders the desktop
`verde_logo.png` asset as native-size, contain, cover, stretch, and cropped-UV
image components through the SDL texture resolver path.
It also shows rounded selects and an explicit icon-text circular send button.

The layout review example is a CLI example for `powder.layout`. It computes a
Verde-style command prompt layout, applies the rects to retained controls, emits
a render batch, and prints the final bounds for review.

The composer prompt review example is a CLI example for the higher-level
`powder.composerPrompt()` visual model. It validates rounded panel commands,
font-role text/icon runs, toolbar separators, compact control presentation, and
the circular send button without opening a window.

Rendering is command-based. Components emit `powder.RenderBatch` commands, and
the labs use Powder's SDL presenter for local inspection.
