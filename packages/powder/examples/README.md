# Powder Examples

Run examples from `packages/powder`.

```bash
zig build run-text-area-lab
```

The current lab opens an SDL3 window, routes SDL text and mouse events into `powder.TextArea`, and rebuilds a `powder.RenderBatch` every frame. Rendering is intentionally command-based until the SDL_GPU presenter in `src/renderer.zig` grows real vertex/index buffer submission.
