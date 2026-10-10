/* Zero-copy browser frames: dma-buf fds + metadata over a SOCK_SEQPACKET socket
 * (SCM_RIGHTS). Wire format: see LINUX_FRAME_PROTOCOL.md and frame_protocol.zig (which must
 * stay byte-identical). */
#ifndef VERDE_FRAME_SOCKET_H
#define VERDE_FRAME_SOCKET_H

#include <stdint.h>

#define VBF_MAGIC 0x46424456u /* "VDBF" little-endian */
#define VBF_VERSION 1u
#define VBF_MAX_FORMATS 256u
#define VBF_MAX_PLANES 4u
#define VBF_MAX_DAMAGE 8u
/* `frame_slot` value of a JSON frame_ready event whose pixels travel as a dma-buf. */
#define VBF_DMABUF_FRAME_SLOT 255
#define VBF_SOCKET_ENV "VERDE_BROWSER_LINUX_FRAME_SOCKET_FD"

enum vbf_type {
    VBF_HELLO = 1,   /* GUI -> helper: importable (fourcc, modifier) list */
    VBF_MODE = 2,    /* helper -> GUI: chosen transport */
    VBF_FRAME = 3,   /* helper -> GUI: one frame, plane fds (+ fence) attached */
    VBF_RELEASE = 4, /* GUI -> helper: done with a frame, optional release fence attached */
};

enum vbf_mode {
    VBF_MODE_SHM = 0,
    VBF_MODE_DMABUF = 1,
};

#define VBF_FRAME_FLAG_FENCE 1u  /* last attached fd is a sync_file to wait on */
#define VBF_RELEASE_FLAG_FENCE 1u

struct vbf_header {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
};

struct vbf_format {
    uint32_t fourcc;
    uint32_t reserved;
    uint64_t modifier;
};

struct vbf_hello {
    struct vbf_header header;
    uint32_t flags;
    uint32_t count;
    struct vbf_format formats[VBF_MAX_FORMATS];
};

struct vbf_mode_msg {
    struct vbf_header header;
    uint32_t mode;
    uint32_t reserved;
};

struct vbf_plane {
    uint32_t offset;
    uint32_t stride;
};

struct vbf_rect {
    int32_t x, y, w, h;
};

struct vbf_frame {
    struct vbf_header header;
    uint64_t sequence;
    uint64_t buffer_id; /* st_ino of the dma-buf: stable per producer buffer */
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t plane_count;
    uint64_t modifier;
    struct vbf_plane planes[VBF_MAX_PLANES];
    uint32_t flags;
    uint32_t damage_count; /* 0 = whole frame */
    struct vbf_rect damage[VBF_MAX_DAMAGE];
    uint64_t exported_at_ns;
    uint64_t sent_at_ns;
};

struct vbf_release {
    struct vbf_header header;
    uint64_t sequence;
    uint32_t flags;
    uint32_t reserved;
};

struct vbf_socket;

/* The GUI is done with `held`. `release_fence` (owned by the callee, -1 = none) is only
 * passed with vbf_socket_forward_release_fences(); otherwise the socket waits for the
 * GUI's fence itself (without blocking) before calling back. */
typedef void (*vbf_release_fn)(void *user, void *held, int release_fence);

/* Opens the socket named by VBF_SOCKET_ENV, reads the GUI's HELLO (bounded wait) and
 * answers MODE. `egl_display` (an EGLDisplay) is the fdo producer that needs
 * EGL_MESA_image_dma_buf_export; NULL = the producer already has dma-buf fds (WPE
 * Platform API). Returns NULL when there is no socket (legacy shm GUI). */
struct vbf_socket *vbf_socket_open_from_env(void *egl_display, vbf_release_fn release, void *user);
int vbf_socket_dmabuf_active(const struct vbf_socket *s);
/* (fourcc, modifier) pairs from the GUI's HELLO. */
const struct vbf_format *vbf_socket_formats(const struct vbf_socket *s, unsigned *count);
/* Hand GUI release fences to the release callback instead of waiting for them here (the
 * producer waits on them, e.g. wpe_buffer_set_release_fence). */
void vbf_socket_forward_release_fences(struct vbf_socket *s, int forward);
/* fdo: exports `image` (an EGLImageKHR) as a dma-buf and sends it. On success the helper
 * must keep `held` (the WPE exported image) until the release callback; on failure
 * (format not importable by the GUI, export failed) the caller falls back to readback. */
int vbf_socket_send_frame(struct vbf_socket *s, void *image, void *held, uint32_t width, uint32_t height,
    uint64_t sequence, uint64_t exported_at_ns);

struct vbf_dmabuf {
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t plane_count;
    uint64_t modifier;
    int fds[VBF_MAX_PLANES]; /* borrowed */
    uint32_t offsets[VBF_MAX_PLANES];
    uint32_t strides[VBF_MAX_PLANES];
};

/* Sends a ready dma-buf. `acquire_fence` (borrowed, -1 = implicit sync) signals when the
 * producer finished rendering; it travels as the last fd with VBF_FRAME_FLAG_FENCE.
 * `damage` (buffer pixels, relative to the previous frame; n_damage 0 = whole frame) is
 * merged down to VBF_MAX_DAMAGE rects. Keep `held` until the release callback. */
int vbf_socket_send_dmabuf(struct vbf_socket *s, const struct vbf_dmabuf *buffer, int acquire_fence,
    const struct vbf_rect *damage, uint32_t n_damage, void *held, uint64_t sequence, uint64_t exported_at_ns);
/* Number of frames the GUI still holds. */
unsigned vbf_socket_held_count(const struct vbf_socket *s);
/* Releases every held frame (through the callback) and closes the socket. */
void vbf_socket_close(struct vbf_socket *s);

#endif
