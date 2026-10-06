# Palette

Follow the [root rules](../../AGENTS.md). Palette batches draw commands in drawable (device) pixels; callers scale UI units with `theme.scaledUi`, so most coordinates arrive fractional at 1.25x/1.5x display scales.

## Crisp chrome (borders, rings, dividers)

Soft, uneven or "pixelated" borders with lumpy corners come from these mistakes:

- **Fractional stroke widths.** `scaledUi(1.0)` is 1.25 px at 1.25x, so the ring smears across two pixel rows. Strokes must be whole device pixels (`@max(@round(w), 1.0)`). The SDF renderer now enforces this for stroked rects (`renderer.strokePixelWidth`), but compute layout with the same width so insets agree.
- **Off-grid edges.** Snap each edge independently (`round(x)`, `round(x + w) - round(x)`), not origin and size separately. Otherwise neighbours gap or overlap by a pixel. The renderer snaps stroked rects (`renderer.snapRectToPixelGrid`); fill-only rects keep sub-pixel geometry so motion stays smooth.
- **Fill and border as two commands.** A rounded fill followed by a separate `rectBorder` stacks two anti-aliased edges, and translucent layers double up at the corners. Draw a bordered surface as one `panel(fill, border, radius, width)` command; the shader composites border over fill in one pass. When you must layer translucent washes, pre-flatten them to opaque colours (see `opaqueOver` in `desktop/src/ui/companion.zig`).
- **Hairline dividers as thin rects.** Use a snapped `h = stroke` rect on an integer `y`, never `scaledUi(1.0)` tall at a fractional `y`.

Check new chrome at a fractional display scale in the real app; 1x screenshots hide all of the above.
