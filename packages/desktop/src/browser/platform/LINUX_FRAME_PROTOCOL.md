# verde-browser-linux: frame transport protocol

The helper is copied from Verde (`packages/desktop/src/browser/platform`, commit 78045fc2).
Version 1 adds an optional zero-copy frame socket next to Verde's existing IPC. Without the
socket, the helper behaves like Verde's helper: frames go through the shm slots.

## Backends

| | WPE Platform API (default) | fdo (`VERDE_BROWSER_LINUX_BACKEND=fdo`) |
|---|---|---|
| WebKit API | `webkit_web_view_new` with a custom `WPEDisplay` (`src/linux_wpe_platform.c`) | libwpe + wpebackend-fdo exportable (Verde's current helper) |
| buffers | `WPEBufferDMABuf` allocated by WebKit (GBM on the render node) | `wpe_fdo_egl_exported_image`, exported with `EGL_MESA_image_dma_buf_export` |
| format | `XR24` first (the GUI's formats, ranked XR24, AR24, XB24, AB24) | `AR24` |
| acquire sync | explicit: the rendering fence travels with FRAME | implicit (the dma-buf's write fences) |
| release sync | explicit: the GUI's sync_file goes to `wpe_buffer_set_release_fence` | the helper waits for the sync_file, then releases the image |
| damage | rects from WebKit (`PropagateDamagingInformation`) | none (whole frames) |
| shm fallback | WebKit renders on the CPU into `WPEBufferSHM` (no DRM device offered) | `glReadPixels` into the slots |
| helper links | WPE WebKit + wpe-platform | + wpebackend-fdo, EGL, GLESv2 |

`zig build -Dfdo=false` compiles the fdo backend out: that helper links no EGL, GLESv2 or
wpebackend-fdo, and reports a `failed` event if fdo is requested. The default build keeps fdo
as a runtime fallback. palette-native links nothing in either case (Vulkan is loaded with
dlopen); the GUI side of the protocol is the pure-Zig file `src/frame_protocol.zig`.

## What stays the same

- **Command/event channel.** stdin and stdout carry JSON lines (`src/linux_ipc.zig`). No
  commands, events or fields were added. This matters because Verde parses `ipc.Event`
  strictly.
- **Shm slots.** Three memfds of 4096*2160*4 bytes sit at the fds named by
  `VERDE_BROWSER_LINUX_FRAME{0,1,2}_FD`. Verde puts them at fds 240, 241 and 242.
- **Shm frame events.** These are unchanged: `frame_ready` with `frame_slot` 0..2 and
  `byte_len = w*h*4`. Pixels are BGRA, top-down, with stride `w*4`. The GUI returns the slot
  with `{"kind":"frame_release","frame_slot":s,"frame_sequence":n}`.
- **Geometry.** `show` / `set_bounds` / `resize_pane` / `navigate` carry the pane's *logical*
  size and the device `scale`, as Verde sends them (pane pixels / scale). See "Scale".

## The socket

The GUI creates an `AF_UNIX` / `SOCK_SEQPACKET` socketpair. The helper's end is inherited at
fd 243 and named by the environment variable `VERDE_BROWSER_LINUX_FRAME_SOCKET_FD=243`. The
helper sets CLOEXEC on it, so WebKit subprocesses do not inherit it.

Wire format:
- One message per record, little-endian.
- Fds travel as `SCM_RIGHTS`.
- Every message starts with `{u32 magic = 0x46424456 ("VDBF"), u16 version = 1, u16 type}`.
- The struct layouts are in `src/frame_socket.h` and are mirrored byte for byte in
  `src/frame_protocol.zig`. `zig build test` checks that the two match.

## Handshake

1. **GUI → helper: HELLO (type 1).** The GUI sends this right after spawning the helper.
   - Fields: `u32 flags = 0, u32 count`, then `count` entries of
     `{u32 fourcc, u32 reserved, u64 modifier}` (at most 256).
   - The list contains the (DRM fourcc, modifier) pairs the GUI can import as sampled images.
     palette-native gets it from `Graphics.dmabufImportFormats`.
   - The record may be truncated to `count` entries.
2. **Helper → GUI: MODE (type 2).** Fields: `u32 mode, u32 reserved`, where mode `0` = shm and
   `1` = dmabuf.
   - The helper waits up to 3 s for HELLO while it creates the view.
   - It answers `dmabuf` only when HELLO had `count > 0`, `VERDE_BROWSER_LINUX_FRAME_TRANSPORT`
     is not `shm`, and (fdo only) EGL has `EGL_MESA_image_dma_buf_export`.
   - Otherwise it answers `shm`: the runtime fallback. An empty HELLO is how a GUI asks for shm.
   - Platform API: the display offers WebKit exactly the HELLO pairs (minus
     `DRM_FORMAT_MOD_INVALID`) on the render node `VERDE_BROWSER_LINUX_DRM_RENDER_NODE`, else
     the first `/dev/dri/renderD*`. In shm mode (or without a render node) it offers no DRM
     device, and WebKit renders on the CPU into `WPEBufferSHM`.

## Frames in dmabuf mode

**FRAME (type 3), helper → GUI.** The plane fds are attached, one per plane in plane order,
then the acquire fence if `flags` bit0 is set. A non-disjoint buffer repeats the same dma-buf.

| field | meaning |
|---|---|
| `u64 sequence` | the same sequence space as the JSON `frame_sequence` |
| `u64 buffer_id` | `st_ino` of plane 0's dma-buf. Informative only: GUIs key their import cache on `(st_dev, st_ino)` of the fd they received. |
| `u32 width, height` | buffer size in device pixels |
| `u32 fourcc, plane_count` | DRM fourcc and number of planes |
| `u64 modifier` | DRM format modifier |
| `{u32 offset, u32 stride}[4]` | per-plane layout |
| `u32 flags` | bit0 = the last fd is an acquire sync_file (Platform API with explicit sync) |
| `u32 damage_count, rect[8]` | `{i32 x, y, w, h}` in buffer pixels, the area that changed since the producer's previous frame. 0 = the whole frame. More than 8 WebKit rects: the first 7 plus the bounding box of the rest. |
| `u64 exported_at_ns` | CLOCK_MONOTONIC time when WebKit handed the frame to the helper |
| `u64 sent_at_ns` | CLOCK_MONOTONIC time when the helper sent it |

Each FRAME is followed on stdout by the usual `frame_ready` event, with `frame_slot = 255`
and `byte_len = 0`.
- Verde's existing parser accepts this event.
- A GUI that does not understand slot 255 must not release it as a shm slot.
- The event still carries `input_serial` and `input_sent_at_ns` for latency accounting.

**Acquire sync.**
- Platform API: `wpe_buffer_get_rendering_fence` (WebKit keeps ownership; the socket dup's it).
  The GUI passes it as `acquire_fence` to `Graphics.importDmabufTexture`, which takes
  ownership and waits on it on the GPU.
- fdo, or `VERDE_BROWSER_LINUX_EXPLICIT_SYNC=0`: no fence. The GUI waits on the buffer's
  implicit write fences (`DMA_BUF_IOCTL_EXPORT_SYNC_FILE` imported as a Vulkan semaphore);
  palette-native does this when `acquire_fence = -1`.

**Damage.** The damage is relative to the producer's previous frame, not to what the GUI
shows. A GUI that drops a frame without showing it must merge the dropped frame's damage into
the next one (any full frame makes the merge full). palette-native accumulates damage of
imports that were never drawn itself; the demo's IO thread merges frames it supersedes.
`Graphics.importDmabufTexture(.{ .damage = rects })` then repaints only those texels (the gpu
damage tracker; 1 device-pixel margin for filtering).

**RELEASE (type 4), GUI → helper.** The GUI sends this when it no longer needs the frame.
- Fields: `u64 sequence, u32 flags, u32 reserved`.
- If `flags` bit0 is set, one sync_file fd is attached. It signals when the GUI's GPU
  finished sampling the frame.
- The helper keeps the buffer (WebKit will not reuse it) until RELEASE.
  - Platform API: the fence goes to `wpe_buffer_set_release_fence` (WebKit waits on it
    before writing the buffer again), then `wpe_view_buffer_released`. No CPU wait.
  - fdo: the helper waits, without blocking, until the fence signals, then calls
    `wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image`.
- palette-native releases a frame as soon as a newer one is bound to the same texture:
  `RELEASE(old) + Graphics.dmabufReleaseFence(old_key)`.
- The GUI must release every FRAME it receives, including ones it drops.

**Pacing.** WebKit draws the next frame only after the helper reports the previous one
done: `wpe_view_buffer_rendered` (Platform API) or `frame_complete` (fdo). The helper sends
that on its own 60 Hz schedule (the same `completion_deadline` logic in both backends). WebKit
needs about two buffers in flight for 60 fps; it allocates more when the GUI holds on to them.

**Per-frame fallback to readback.** Even in dmabuf mode, the helper sends a frame through a
shm slot (a normal `frame_ready` with slot 0..2) when:
- the GUI already holds 8 frames, or sending fails;
- fdo: the frame's (fourcc, modifier) was not in HELLO (logged once), or the export fails.
  The Platform API never produces such a frame, since WebKit only allocates offered formats.

Platform frames are then copied out with `wpe_buffer_import_to_pixels` (slow: WebKit's own
EGL readback). A GUI in dmabuf mode must keep handling shm frames and order the two kinds by
`sequence`.

**Disconnect.** If the socket hangs up, the helper releases every held frame and switches to
shm for the rest of its life.

## Scale

The GUI sends the logical pane size and the device scale (Verde: pane pixels / scale, rounded;
`scale = browserPaneDeviceScale()`). Any value in 0.05..5 works, fractional ones included.
- Platform API: `wpe_toplevel_resized(logical)` + `wpe_toplevel_scale_changed(scale)`.
- fdo: `wpe_view_backend_dispatch_set_size(logical)` +
  `wpe_view_backend_dispatch_set_device_scale_factor(scale)`.

WebKit then renders buffers of `floor(logical × scale)` pixels (853 × 1.5 → 1279) with
`devicePixelRatio = scale` and `innerWidth` = the logical width. The GUI draws the buffer 1:1
in device pixels, so there is no resampling. A scale change at runtime is just another
`set_bounds`; the next buffer has the new size, and old imports are dropped.

**Input** (`mouse_*` commands) is in logical px, the same space as the pane size. The
Platform API takes it as is. fdo pointer and wheel events are in device px (WebKit divides by
the scale), so the helper multiplies by the scale there. A wheel notch scrolls 40 CSS px in
both backends at every scale. Verified with `palette-test-webview --probe` at 1.0, 1.25, 1.5
and 2.0: a click at logical (x, y) arrives as `clientX/Y = (x, y)`.

## Environment switches

| variable | effect |
|---|---|
| `VERDE_BROWSER_LINUX_BACKEND=fdo` | use the fdo backend (default: the Platform API) |
| `VERDE_BROWSER_LINUX_FRAME_TRANSPORT=shm` | answer MODE shm whatever HELLO says |
| `VERDE_BROWSER_LINUX_EXPLICIT_SYNC=0` | Platform API: no rendering/release fences (implicit sync) |
| `VERDE_BROWSER_LINUX_DAMAGE=0` | Platform API: do not enable `PropagateDamagingInformation`; whole frames |
| `VERDE_BROWSER_LINUX_DRM_RENDER_NODE=/dev/dri/renderD129` | render node WebKit allocates on (pick the GUI's GPU) |
| `VERDE_BROWSER_FRAME_LOG=1` | per-frame log on stderr (path, size, damage, held buffers) |

## Formats seen in practice

On an Intel TGL GT2 with Mesa iris/ANV and WPE WebKit 2.52.6:
- Platform API: `XR24` with modifier `0x0100000000000008` (`I915_FORMAT_MOD_Y_TILED_GEN12_RC_CCS_CC`),
  3 planes (main surface, CCS aux plane, clear color) in one buffer.
- fdo (wpebackend-fdo 1.16.1): `AR24` with the same modifier and planes.

The GUI imports these directly. The image is not linear, and the compression stays enabled
through the import. Rows are top-down in every path.

Damage seen on the test page: `[1168,8 84x84]` (the animated box), `[11,74 161x28]` (the
frame counter) and `[1259,0 21x800]` (the overlay scrollbar region, which WebKit reports on
every frame of an animating page).

## WPE WebKit 2.52 gaps

- **Damage is opt-in.** It needs the non-default `PropagateDamagingInformation` feature;
  without it `render_buffer` gets no rects. The helper enables it unless
  `VERDE_BROWSER_LINUX_DAMAGE=0`.
- **No frame clock for custom displays.** A `WPEDisplay` without a compositor gets no vsync
  source, so the helper paces with its own 60 Hz timer (as with fdo). It does not follow the
  GUI's real refresh or presentation feedback.
- **`wpe_buffer_import_to_pixels`** is the only readback, and it is slow. It only runs on the
  rare per-frame fallback.
- **`get_egl_display`** must be implemented by every display; the helper returns
  `NOT_SUPPORTED` because the UI process never touches the pixels.
- **Cursor and IME** go through the page-side cursor observer and `key_input`/`text_input`,
  as before; `set_cursor_from_name` and the input-method API are not used.
- **libwpe stays linked.** WPE WebKit 2.52 itself depends on it, even without fdo.
