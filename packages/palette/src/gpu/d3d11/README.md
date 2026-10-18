# src/gpu/d3d11: Direct3D 11 backend (Windows)

This backend implements the interface that `../core.zig` defines and that `core.checkBackend`
checks. It uses the shared core, so the encoder, damage tracking, the full/partial/skip plan,
glyph atlases and stream-region merging are the same code that Vulkan runs. `../root.zig`
selects it when the target OS is Windows (`gpu.backend_kind == .d3d11`). It has the same
exports: `Context`, `Renderer`, `Offscreen`, `Target`, `Caps`, `ContextOptions`, and
additionally `Swapchain`. The Vulkan-only names (`vk`, `DmabufTargets`, `SyncMode`, ...) are
`void` on Windows.

There are no dependencies. The only import is `D3D11CreateDevice` from d3d11.dll. DXGI is
reached through COM from the device (`IDXGIDevice` → adapter → `IDXGIFactory2`). Every
interface is a hand-written vtable in `com.zig`, and the slot indices were checked against the
mingw-w64 headers. It needs no zigwin32 and no d3dcompiler at runtime.

## Files

| file | role |
|---|---|
| `com.zig` | Constants, descriptor structs (with layout tests), IIDs and vtable wrappers for Device, DeviceContext, the resources and views, DXGIDevice/Adapter/Factory2/Factory5 and SwapChain1-2. `check()` maps HRESULTs to `D3D11Failed` / `DeviceRemoved` / `OutOfMemory`. |
| `context.zig` | Device and immediate context at feature level 11_1, falling back to 11_0 and then 10_x. Options `warp` and `debug`. `Caps` holds the feature level, vendor/device id, `allow_tearing` and `software`. Submission serials come from a ring of 8 event queries (`submit`, `pollCompleted`, `waitSerial`). It also has the texture/buffer helpers and the memory statistics. |
| `renderer.zig` | Pipeline (one VS/PS, input layout of the 64-byte `core.Instance`, premultiplied blend, scissor) and the dynamic instance-buffer ring (NO_OVERWRITE / DISCARD). R8 and RGBA8 glyph atlases grow by copying. Images have mips (`GenerateMips`). `streamTexture` uses a ring of STAGING textures and per-region `CopySubresourceRegion`. `render` = core plan → upload → record → submit. A partial redraw draws one unblended clear quad per damage rect and scissors each run. |
| `targets.zig` | `Offscreen` (render plus BGRA→RGBA readback through a staging copy) and `Swapchain` (below). |
| `shaders/ui.hlsl` | HLSL port of `../../shaders/ui.{vert,frag}.glsl` (SM 4.0). The VS flips y, and the PS has the same kind branches as the GLSL. |
| `shaders/ui_vs.dxbc`, `ui_ps.dxbc` | Precompiled bytecode, embedded with `@embedFile`. |

## Swapchain and present loop

`Swapchain.init(renderer, hwnd, w, h, .{ .buffers = 2 })` creates the swapchain with
DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, BGRA8, DXGI_SCALING_NONE (falling back to STRETCH),
ALPHA_MODE_IGNORE and FRAME_LATENCY_WAITABLE_OBJECT. It also sets MaximumFrameLatency(1),
turns off Alt+Enter, and adds ALLOW_TEARING when requested and supported.

* Flip-sequential keeps the contents of the back buffers. Each buffer gets its own damage
  history slot (`Target`, indexed by `presents % buffer_count`), which gives the core encoder
  the buffer age. Partial frames render only the damaged tiles and call `Present1` with those
  dirty rects. An unchanged batch submits and presents nothing.
* `waitable` is handed to the platform window (`Window.setFrameWaitable`). `waitEvent` waits
  on it next to the message queue and emits `frame` when DXGI can take another frame. Nothing
  spins, and an idle window costs 0% CPU.
* `DXGI_STATUS_OCCLUDED` (minimised, covered, locked) drops the frame and invalidates the
  buffers. `palette.WindowRenderer` then polls with `DXGI_PRESENT_TEST` at the frame timeout
  and does no GPU work until the window is visible again. After that it repaints fully.
* `resize` releases the RTV, calls `ClearState` + `Flush` + `ResizeBuffers(0, w, h)`, and
  repaints fully.

Hosts normally use `palette.WindowRenderer` (`../../app_win32.zig`). It has the same API and
`Outcome`s as the Wayland one, so a host loop is unchanged.

## Shaders (dev-only rebuild)

The `.dxbc` files are checked in, and normal builds never compile HLSL. To regenerate them
after editing `ui.hlsl`:

```sh
# on Windows
zig build compile-hlsl
# on Linux, through Wine's d3dcompiler_47 (private prefix)
tools/wine-zig.sh compile-hlsl
```

The step builds `tools/hlsl-compile.zig`. That tool `LoadLibrary`s `d3dcompiler_47.dll` and
calls `D3DCompile(..., vs_main|ps_main, vs_4_0|ps_4_0, ENABLE_STRICTNESS | OPTIMIZATION_LEVEL3)`.
It writes `src/gpu/d3d11/shaders/ui_{vs,ps}.dxbc`. The output is deterministic: a rerun under
Wine reproduces the checked-in files byte for byte. The checked-in blobs come from **Wine's**
d3dcompiler (vkd3d-shader). Microsoft's runtime accepts them, but they have not been through
Microsoft's validator. On real Windows, run `zig build compile-hlsl` once (hardware
checklist, STATUS.md) and commit the result if it differs.

