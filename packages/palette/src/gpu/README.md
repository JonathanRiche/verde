# src/gpu: renderer core + Vulkan backend

`core.zig` and the other top-level files are backend-neutral and shared by every backend
(Vulkan here, Metal in `metal/`, D3D11 in `d3d11/`). `root.zig` picks the backend at comptime
(`gpu.backend`) and re-exports `Context`, `Renderer`, `Offscreen`. The backend interface is
listed at the top of `core.zig` and enforced by `core.checkBackend`.

Retained-mode `draw.RenderBatch` → pixels, at parity with the old SDL_GPU renderer
(`palette/src/renderer.zig`) and with no build-time dependencies:

- `libvulkan.so.1` is `dlopen`ed at runtime; bindings are hand-written in `vulkan/vk.zig`.
- Shaders are GLSL in `src/shaders/`, with precompiled SPIR-V checked in and embedded via
  `@embedFile`. `zig build compile-shaders` (needs `glslc`) regenerates them; normal builds
  never do.
- No WSI and no libwayland. Frames are rendered into exportable dma-buf images that the
  platform layer attaches with `zwp_linux_dmabuf_v1`.

## Files

| file | role |
|---|---|
| `core.zig` | **Backend-neutral**: 64-byte `Instance` encoding, `Encoder` (batch → instances + texture runs, glyph layout, command hashing, damage, full/partial/skip `Plan`), stream-region merge/pack, option/result types, `checkBackend` |
| `vulkan/root.zig` | Vulkan backend surface |
| `vulkan/vk.zig` | Minimal Vulkan 1.1+ types / loader tables (instance, device, KHR fd/semaphore, DRM modifier exts) |
| `vulkan/context.zig` | Loader, GPU pick (prefers the compositor's DRM node), queue, caps, memory allocation, serials + deferred destruction |
| `vulkan/renderer.zig` | Pipeline, atlas images, textures + uploads, command recording/submission (on `core.Encoder`) |
| `vulkan/targets.zig` | `Offscreen` (readback) and `DmabufTargets` (modifiers, sync_file, FOREIGN queue transfer) |
| `metal/` | Metal backend (macOS): precompiled metallib uber-shader (runtime MSL fallback), offscreen + CAMetalLayer targets. See `metal/README.md` |
| `text.zig` | `GlyphSource` interface, `StubGlyphSource`, `GlyphCache` (atlases), `Layouter` (old-renderer text rules) |
| `atlas.zig` | Shelf packer with bucketed heights, growth and LRU shelf eviction |
| `damage.zig` | Tile-hash damage tracker with buffer-age history |
| `png_lite.zig` | Tiny PNG encode/decode/compare for goldens and examples |
| `scene.zig` | Deterministic reference scene (goldens) and a 2000-command bench scene |

## Usage

```zig
const gpu = @import("gpu/root.zig");

const ctx = try gpu.Context.init(gpa, .{ .preferred_device = feedback.main_device }); // optional hint
defer ctx.deinit();
const r = try gpu.Renderer.init(gpa, ctx, .{
    .glyph_source = gpu.GlyphSource.adapt(font.Collection, collection),
});
defer r.deinit();
try r.uploadTexture(id, w, h, .rgba8, pixels);   // straight alpha in, premultiplied on GPU

var bufs = try gpu.DmabufTargets.init(r, width, height, .{ .feedback = feedback });
defer bufs.deinit();

// per frame
const t = bufs.acquire() orelse return;             // null: all buffers held by compositor
const res = try bufs.render(t, &batch, .{ .clear = bg });
if (!res.stats.skipped) {
    const img = bufs.exported(t);                     // present.DmabufImage (fds, strides, modifier)
    // attach img (create the wl_buffer once per target, keep it in t.user_data),
    // damage_buffer for each rect in res.damage, commit. t is now busy.
} // skipped: nothing changed, nothing to commit; t stays free.
// on wl_buffer.release: bufs.release(bufs.find(user_data).?)
// on resize: try bufs.resize(w, h)  (re-export; recreate wl_buffers)
```

Offscreen (tests, screenshots): `gpu.Offscreen.init(r, w, h)`, `render`, `readRgba(out)`.
`readRgba` is a synchronous one-shot copy. Rendering itself never reads back.

## Rendering model

- **One pipeline, one instance format.** Each primitive is a 64-byte instance:
  rect / clip / uv vectors plus packed rgba8 fill, rgba8 border, radius and kind|border_px.
  The kinds are quad, SDF rounded/bordered rect, triangle, coverage glyph, colour glyph and
  image. A 4-vertex strip is drawn instanced. The vertex shader clips each quad against its
  clip rect, so there is no scissor state per command. Draws only split when the image
  texture changes, which takes 2 draws for the reference scene.
- **Premultiplied blending** (`ONE, ONE_MINUS_SRC_ALPHA`). B8G8R8A8_UNORM targets, exported
  as XRGB8888 (or ARGB8888 with `.opaque = false`).
- **Parity rules from the old renderer**:
  - Stroked rects snap each edge to the pixel grid, with whole-pixel strokes (minimum 1).
    Fill-only rects keep sub-pixel geometry.
  - Radius is clamped to half the smaller side. The SDF is used when radius > 0.5 or the
    rect is stroked.
  - Legacy border blending is the default (`legacy_border_blend`).
  - Text and image clips use floor/ceil scissor snapping.
  - Text uses the 0.86 font scale, rounded origins, and baseline = top + round(ascent).
    Lines advance by round(lineHeight), `\n` always breaks, and word wrap is at
    ceil(rect.w).
  - Mono text uses fixed cells, with tabs at 4 cells.
  - `text_runs` are offset by scroll.
  - Glyph x positions use 4 subpixel buckets.
- **Z-order**: commands are drawn in the batch's z-sorted order, like the old renderer.

## Text

`GlyphSource` is a 3-function vtable (`shape`, `rasterize`, `lineMetrics`). `adapt(T, *T)`
wraps any type with those methods, including `font.Collection`, which also caches shaping.
`StubGlyphSource` is a deterministic fake font for tests.

`GlyphCache` keeps two atlases:

- an R8 coverage atlas, 1024² growing to 4096²;
- an RGBA colour atlas for emoji, 256² growing to 2048².

Glyphs are packed on shelves, and every use touches the shelf. When an atlas is full it
first grows (the old contents are copied on the GPU), then evicts the least-recently-used
shelves that were not used this frame. Glyphs are rasterized once, staged in a per-frame
upload list and copied in the same command buffer as the frame. The shader samples with
`texelFetch` in texel coordinates, so growth never invalidates instances.

## Damage and buffer age

- Every visible command is hashed. The hash covers its semantic fields and, for images, the
  texture generation.
- The hash is mixed, in draw order, into each tile its clipped bounds touch. Tiles are 32 px,
  or 64 px above 2560×1600.
- Changed tiles are recorded in a 4-frame history.
- A target's age is the number of frames since it was last rendered into. Its repaint region
  is the union of the last `age` change sets, emitted as merged rects. More than 8 rects
  collapse into a single bounding box.
- Partial frames:
  - begin a LOAD render pass;
  - clear the damage rects;
  - replay the instance stream once per rect with the rect as scissor.
- Unchanged frames with no pending uploads submit nothing (`stats.skipped`).
- `res.damage` is meant for `wl_surface.damage_buffer`.
- `FrameOptions.force_full` bypasses all of this. `Target.invalidate()` forgets a buffer's
  contents.

## Synchronisation

There is no WSI and no CPU stall in the steady state.

1. **Before rendering** into a dma-buf the compositor may still read:
   - `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` (WRITE) exports the buffer's implicit fences as a
     sync_file;
   - that sync_file is imported into a temporary binary semaphore (`SYNC_FD`);
   - the submit waits on it at the colour-output and transfer stages.
2. **After the submit**, the SYNC_FD semaphore it signals is exported, and
   `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` attaches it to the dma-buf as its write fence. The
   compositor's implicit sync then waits for the GPU, not for us.
3. **Queue ownership**: images are released to `VK_QUEUE_FAMILY_FOREIGN_EXT` in GENERAL after
   each frame and acquired back before the next.
4. **Fallback** (no sync_file ioctls or no SYNC_FD support): CPU wait on the frame fence
   before handing over (`SyncMode.fence_wait`).

CPU-side frame slots (2 by default) each own a command buffer, a fence, an instance buffer
and a staging buffer. Buffers grow by doubling and never shrink mid-run. Each submission gets
a serial, and GPU objects are freed once their serial completes (`Context.retire`).

## Modifiers

`DmabufTargets` intersects the compositor's format/modifier feedback with what the driver
can render to and export (checked via `vkGetPhysicalDeviceImageFormatProperties2` with
DRM-modifier info). It creates images with `DRM_FORMAT_MODIFIER_EXT` tiling, so the driver
picks the modifier, and with dedicated exportable memory. Each plane's fd, offset, stride
and modifier is reported. Without feedback, or with `force_linear`, it uses LINEAR.

## Numbers (Intel Iris Xe TGL GT2, Mesa ANV)

`zig build gpu-bench`: 2000 commands (4867 instances, including ~400 text labels),
1920×1080, ReleaseFast.

| scenario | CPU µs/frame | of which build | wall incl. GPU |
|---|---|---|---|
| full redraw (`force_full`) | ~320 | ~240 | ~3.5 ms (fill-rate bound on the iGPU) |
| one label changes (0.1% damaged) | ~280 | ~225 | ~1.0 ms |
| unchanged (skipped, no submit) | ~210 | ~210 | ~0.2 ms |

Memory in the bench:

- **Device-local:** 18.2 MiB. This includes the 7.9 MiB 1080p offscreen target. The fixed
  part is the coverage atlas (1 MiB), the colour atlas (256 KiB), the dummy texture and the
  image textures.
- **Host-visible:** 9 MiB. Most of it is the 7.9 MiB readback buffer, which exists only for
  Offscreen. The rest is instance and staging buffers, about 300 KiB per frame slot for
  4.9k instances.
- **Renderer host scratch:** about 460 KiB (instances, glyph map, damage grid).

A dma-buf window has no readback buffer, and each of its 2–3 targets costs width×height×4.

## Tests

`zig build test-gpu` runs CPU-only unit tests (packer, damage, encoder, text layout). There
are no device or golden-image tests.

`zig build gpu-offscreen [-- --update-goldens]` writes `out/gpu_scene_{1x,1.25x}.png`.

## Known gaps

- Triangles are clipped geometrically against the clip rect. The old renderer only culled
  triangles that were fully outside it.
- Colours are quantised to rgba8 per instance (the old renderer used float colours). This
  differs by at most 1 LSB after blending.
- There is no `measureText` here; use `font.Collection` (same metrics and rules).
- The Wayland wiring lives in `src/app.zig` (`palette.WindowRenderer`), not here. It imports each target once,
  maps `wl_buffer.release` to `DmabufTargets.release` and paces on frame callbacks with a timeout.
- Single queue, no async compute and no MSAA (AA is analytic in the shaders).
