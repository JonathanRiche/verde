/* WPE Platform API (WebKit >= 2.52 "wpe-platform") display for the browser helper.
 *
 * A minimal WPEDisplay / WPEView / WPEToplevel trio with no compositor behind it: WebKit
 * renders into buffers it allocates itself (GBM dma-bufs on the GUI's render node, or
 * WPEBufferSHM when the display offers no DRM device) and hands each finished frame to
 * `render_buffer` together with its damage rectangles and, with explicit sync, a rendering
 * fence. The helper forwards those buffers to the GUI (frame_socket.c) and paces WebKit by
 * delaying wpe_view_buffer_rendered(). No EGL or GL is used in the helper process. */
#ifndef VERDE_LINUX_WPE_PLATFORM_H
#define VERDE_LINUX_WPE_PLATFORM_H

#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>

#include "frame_socket.h"

struct verde_wpe_sink {
    /* A finished frame. Return TRUE once the buffer is owned by the sink: it must then call
     * wpe_view_buffer_rendered() and later wpe_view_buffer_released() for it. */
    gboolean (*render_buffer)(void *user, WPEView *view, WPEBuffer *buffer, const WPERectangle *damage, guint n_damage);
    /* WebKit replaced its buffer set (resize, format change): old buffers are gone. */
    void (*buffers_changed)(void *user, WPEView *view);
    void *user;
};

/* `formats`: (fourcc, modifier) pairs the GUI imports. count == 0 selects CPU rendering into
 * WPEBufferSHM (no DRM device is offered). `explicit_sync`: WebKit attaches a rendering fence
 * to every dma-buf frame and honours release fences. Returns a connected display or NULL. */
WPEDisplay *verde_wpe_display_new(const struct vbf_format *formats, unsigned count, gboolean explicit_sync,
    const struct verde_wpe_sink *sink, GError **error);
/* Render node the display hands WebKit (NULL for SHM). */
const char *verde_wpe_display_render_node(WPEDisplay *display);

#endif
