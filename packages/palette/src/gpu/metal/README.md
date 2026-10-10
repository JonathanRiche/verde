# src/gpu/metal: Metal backend (macOS)

The same renderer as `../vulkan`, on Metal. `../core.zig` does the backend-neutral work: the batch → 64-byte
instances + texture runs, glyph layout and atlas packing, tile-hash damage, the skip/full/partial plan and the
stream-region merge. This directory owns the Metal objects. `../root.zig` selects it when `os.tag == .macos`, and
`core.checkBackend` enforces the same interface (`Context`, `Renderer`, `Offscreen`, `Target`).

There are no build-time dependencies. Metal.framework is dlopened through `../../platform/macos/objc.zig`, and every call
is an `objc_msgSend` with the selector spelled out. There are no headers, no `.m` files, no Swift and no `xcrun`. The
shader is MSL source embedded with `@embedFile` and compiled at runtime by `newLibraryWithSource:`, so the whole backend
cross-compiles from Linux.

| file | role |
|---|---|
| `mtl.zig` | The slice of the Metal API used: enum values and by-value structs (MTLOrigin/Size/Viewport/ScissorRect/ClearColor) from the macOS 14 SDK, `MTLCreateSystemDefaultDevice` via dlsym, texture/buffer/blit helpers |
| `shader.metal` | MSL port of `src/shaders/ui.{vert,frag}.glsl`. The same maths, kept in lockstep because the goldens are shared, plus `clear_vertex`/`clear_fragment` for partial redraws |
| `renderer.zig` | `Context` (device, queue, serials, memory stats), `Renderer` (pipelines, atlases, textures, uploads, `streamTexture`, recording and commit) |
| `targets.zig` | `Offscreen` (texture + CPU readback, BGRA→RGBA) and `LayerTarget` (CAMetalLayer window target) |

## Design

* **Pipelines.** There are two: the uber-shader (blend ONE / ONE_MINUS_SRC_ALPHA, premultiplied) and a no-blend clear
  quad. Both target BGRA8Unorm, which is CAMetalLayer's default. The compile options set `mathMode = Safe`
  (`fastMathEnabled = NO` before macOS 15), so AA ramps match the SPIR-V path.
* **Instances.** Each frame slot (2–3 in flight, `Options.frames_in_flight`) has its own shared, write-combined
  `MTLBuffer` ring. On unified memory nothing is copied. The vertex shader reads `instances[[instance_id]]`, and each
  texture run is one `drawPrimitives(triangleStrip, 0, 4, count, baseInstance)`. `instance_id` includes the base, so there
  is no per-run buffer offset. The y axis is flipped in the vertex shader. Framebuffer coordinates are top-left with
  pixel centres at .5, as in Vulkan, so the fragment maths is unchanged.
* **Textures.** Images are private textures filled by blit copies from shared staging, with
  `generateMipmapsForTexture:` for the mip chain (mipmapped textures also get render-target usage, which Metal requires).
  Glyph atlases are private R8 (coverage) and RGBA8 (colour) textures. They are read with `texture.read()` at texel
  coordinates, so an atlas can grow mid-frame: a new, larger texture, `copyFromTexture`, then the new glyphs.
* **Streaming.** `streamTexture` (browser frames) gives each texture a ring of shared staging buffers, with no
  steady-state allocation, and copies only the dirty rects. A 1080p BGRA frame costs 0.25 ms per call for the full frame and
  0.02 ms for a 10% dirty rect (`gpu-bench`).
* **Lifetime and sync.** Command buffers retain every resource they reference, so destroyed objects are released at
  once and there is no retire queue. Each frame slot keeps its command buffer. Completion is a serial: `status` is
  polled (≥ completed) and `waitUntilCompleted` blocks. Command-buffer errors surface as `MetalCommandFailed`.
* **Partial redraw.** The target texture is kept (load action `load`). For each damage rect the renderer sets a
  scissor, draws a no-blend clear quad, then the runs clipped to it. Skipped frames (identical batch hash) record nothing.
* **Window target (`LayerTarget`).** Drawables rotate, and the layer may hand out a fresh one at any time, so they
  cannot hold retained contents. Each window therefore has one persistent private BGRA8 *backbuffer*. Damage is
  rendered into it, and in the same command buffer the whole backbuffer is blitted into `nextDrawable` (the layer uses
  `framebufferOnly = NO`) followed by `presentDrawable:`. A missing drawable (zero size or offscreen) is counted in
  `missed_drawables` and the frame is not presented. The layer is tagged sRGB (`LayerOptions.srgb_colorspace`), so P3
  panels colour-match it. Resizing replaces the backbuffer and sets `drawableSize`; the next frame is full.
* **Pacing (`app.MetalWindowRenderer`).** After a present it calls `Window.requestFrame()`, which unpauses the view's
  display link, and it is `throttled` until the `frame` event arrives. `frame_timeout_ms` is the fallback. It never
  returns `.no_buffer`. `bufferBytes()` counts the backbuffer plus 3 drawables.

## Measurements (M2, macOS 14.6)

* **Goldens.** `zig build test-gpu` renders the shared reference scene offscreen and compares it with the
  Vulkan-generated goldens. Tolerance is 3 LSB, with no more than 0.1% of pixels beyond it. On Metal, 0 pixels exceed the
  tolerance. 15906 of 153600 pixels at 1x and 21826 of 240000 at 1.25x differ, all by exactly **1 LSB**. They sit in AA
  ramps and blended overlays (e.g. 43 vs 44). Solid fills, text placement and the background are identical. The
  expected-pixel test allows ±1 on Metal for the same reason. Partial redraw matches full redraw with 0 mismatches.
* **Damage.** In `run-macos-window` every animation frame was partial: the average damage was 3136 of 79200 px (4%),
  90/90 frames were presented at 60.2–60.6 fps (interval p50 16.7 ms), and renderer CPU was 0.6 ms/frame in Debug.
  In `gpu-bench` (2000 commands, 1920x1080) wall+GPU time per frame is 1479 µs for a full redraw, 398 µs when one label
  changes (damage 0.1%) and 152 µs for an unchanged frame (hash skip, nothing submitted). Damage tracking saves 73% when
  one label changes. The backbuffer→drawable blit is part of every windowed frame. It was not timed separately: there is no
  GPU timestamp query in the bench. It is a single 4 bytes/px copy of the window, ~4 MB at 1280x800.
* **Startup.** `MTLCreateSystemDefaultDevice` takes ~45 ms. Compiling the MSL takes ~400 ms the first time a given binary
  runs, then ~2 ms, because Metal's shader cache is keyed per executable. Warm, the first offscreen frame comes ~54 ms after main.
* **Idle.** With nothing dirty no command buffer is created and the display link is paused: 0.1–0.2% CPU.
* **Memory.** At 360x220 the GPU memory is the atlases plus the backbuffer, about 2 MiB (`gpu_mem` in `gpu-offscreen`).
  In the bench window (1280x800) the process `phys_footprint` is 23–35 MiB, against 34–50 MiB for the old SDL renderer
  (`baseline/COMPARISON-macos.md`).

## Not supported / not done

* **Precompiled `.metallib`.** Building one needs Apple's `metal` toolchain on a Mac. Shipping it would remove the ~400 ms
  first-run compile.
* **EDR/HDR and wide-gamut output.** The layer is SDR BGRA8 in sRGB. There is no `wantsExtendedDynamicRangeContent`.
* **Explicit present timing.** There is no `presentDrawable:atTime:` or `afterMinimumDuration:`, and no frame statistics
  from `MTLDrawable.presentedTime`. Pacing is the display link.
* **Discrete GPUs / multi-GPU Macs.** The system default device is used. Intel Macs with a discrete GPU would want
  `MTLCopyAllDevices` and a low-power preference; only Apple Silicon was run.
* **Zero-copy browser frames.** The Linux dma-buf path has no counterpart here. The IOSurface-backed equivalent
  (`newTextureWithDescriptor:iosurface:plane:`) is not implemented. WKWebView draws itself as an NSView subview anyway
  (see `../../platform/macos/README.md`).
