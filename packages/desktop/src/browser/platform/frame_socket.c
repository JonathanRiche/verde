/* Zero-copy browser frames over SCM_RIGHTS (see frame_socket.h, LINUX_FRAME_PROTOCOL.md).
 *
 * WebKit renders into GBM buffers that wpebackend-fdo hands us as EGLImages. Instead of
 * glReadPixels into a shm slot, the EGLImage's dma-buf is exported
 * (EGL_MESA_image_dma_buf_export) and its fds are sent to the GUI, which imports them
 * into Vulkan. The WPE image stays held (WebKit will not reuse that buffer) until the
 * GUI sends RELEASE; when the release carries a sync_file the image is handed back to
 * WPE only once the fence signals (the GUI's sampling finished), without blocking.
 *
 * With the WPE Platform API (linux_wpe_platform.c) WebKit's buffers already are dma-bufs:
 * vbf_socket_send_dmabuf() forwards their fds, the rendering fence and the damage rects,
 * and release fences are passed through to WebKit (explicit sync) instead of being
 * waited for here. That path needs no EGL. */
#define _GNU_SOURCE
#include "frame_socket.h"

#ifndef VERDE_BROWSER_LINUX_WITH_FDO
#define VERDE_BROWSER_LINUX_WITH_FDO 1
#endif
#if VERDE_BROWSER_LINUX_WITH_FDO
#include <EGL/egl.h>
#include <EGL/eglext.h>
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <glib.h>
#include <glib-unix.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VBF_HELD_MAX 8
#define VBF_HELLO_TIMEOUT_MS 3000

struct vbf_held {
    uint64_t sequence;
    void *image;
    guint fence_source;
    int fence_fd;
};

struct vbf_socket {
    int fd;
    guint source;
#if VERDE_BROWSER_LINUX_WITH_FDO
    EGLDisplay display;
    PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC query;
    PFNEGLEXPORTDMABUFIMAGEMESAPROC export_image;
#endif
    gboolean forward_release_fences;
    uint32_t mode;
    uint32_t format_count;
    struct vbf_format formats[VBF_MAX_FORMATS];
    struct vbf_held held[VBF_HELD_MAX];
    vbf_release_fn release;
    void *user;
    gboolean reported_unsupported;
};

static uint64_t vbf_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void vbf_header_init(struct vbf_header *h, uint16_t type) {
    h->magic = VBF_MAGIC;
    h->version = VBF_VERSION;
    h->type = type;
}

static int vbf_header_ok(const struct vbf_header *h, ssize_t len, size_t min_len) {
    return len >= (ssize_t)min_len && h->magic == VBF_MAGIC && h->version == VBF_VERSION;
}

static ssize_t vbf_recv(int fd, void *buf, size_t len, int *fds, int max_fds, int *n_fds) {
    char control[CMSG_SPACE(sizeof(int) * 8)];
    struct iovec iov = { .iov_base = buf, .iov_len = len };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof(control) };
    *n_fds = 0;
    ssize_t r;
    do {
        r = recvmsg(fd, &msg, MSG_CMSG_CLOEXEC | MSG_DONTWAIT);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return r;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
        const int count = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        const int *in = (const int *)CMSG_DATA(c);
        for (int i = 0; i < count; i += 1) {
            if (*n_fds < max_fds) fds[(*n_fds)++] = in[i];
            else close(in[i]);
        }
    }
    return r;
}

static int vbf_send(int fd, const void *buf, size_t len, const int *fds, int n_fds) {
    char control[CMSG_SPACE(sizeof(int) * 8)];
    struct iovec iov = { .iov_base = (void *)buf, .iov_len = len };
    struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
    if (n_fds > 0) {
        memset(control, 0, sizeof(control));
        msg.msg_control = control;
        msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)n_fds);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)n_fds);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)n_fds);
    }
    ssize_t r;
    do {
        r = sendmsg(fd, &msg, MSG_NOSIGNAL);
    } while (r < 0 && errno == EINTR);
    return r == (ssize_t)len ? 0 : -1;
}

/* `fence`: GUI release fence handed to the callback (-1 = none). */
static void vbf_release_held_with(struct vbf_socket *s, struct vbf_held *h, int fence) {
    if (h->image == NULL) {
        if (fence >= 0) close(fence);
        return;
    }
    if (h->fence_source != 0) g_source_remove(h->fence_source);
    if (h->fence_fd >= 0) close(h->fence_fd);
    void *image = h->image;
    *h = (struct vbf_held){ .fence_fd = -1 };
    if (s->release != NULL) s->release(s->user, image, fence);
    else if (fence >= 0) close(fence);
}

static void vbf_release_held(struct vbf_socket *s, struct vbf_held *h) {
    vbf_release_held_with(s, h, -1);
}

static gboolean vbf_on_fence(gint fd, GIOCondition condition, gpointer user_data) {
    (void)fd;
    (void)condition;
    struct vbf_socket *s = user_data;
    for (int i = 0; i < VBF_HELD_MAX; i += 1) {
        struct vbf_held *h = &s->held[i];
        if (h->image != NULL && h->fence_fd == fd) {
            h->fence_source = 0; /* removed by returning G_SOURCE_REMOVE */
            vbf_release_held(s, h);
            break;
        }
    }
    return G_SOURCE_REMOVE;
}

static void vbf_handle_release(struct vbf_socket *s, const struct vbf_release *msg, int fence) {
    for (int i = 0; i < VBF_HELD_MAX; i += 1) {
        struct vbf_held *h = &s->held[i];
        if (h->image == NULL || h->sequence != msg->sequence) continue;
        if (fence >= 0 && s->forward_release_fences) {
            vbf_release_held_with(s, h, fence);
            return;
        }
        if (fence >= 0) {
            struct pollfd p = { .fd = fence, .events = POLLIN };
            if (poll(&p, 1, 0) == 1) {
                close(fence);
            } else {
                /* sync_files poll readable once signalled: hand the buffer back then. */
                h->fence_fd = fence;
                h->fence_source = g_unix_fd_add(fence, G_IO_IN, vbf_on_fence, s);
                return;
            }
        }
        vbf_release_held(s, h);
        return;
    }
    if (fence >= 0) close(fence);
}

static gboolean vbf_on_socket(gint fd, GIOCondition condition, gpointer user_data) {
    struct vbf_socket *s = user_data;
    if (condition & (G_IO_HUP | G_IO_ERR)) {
        /* GUI gone: give every buffer back to WebKit. */
        for (int i = 0; i < VBF_HELD_MAX; i += 1) vbf_release_held(s, &s->held[i]);
        s->mode = VBF_MODE_SHM;
        s->source = 0;
        return G_SOURCE_REMOVE;
    }
    for (;;) {
        struct vbf_release msg;
        int fds[4];
        int n_fds = 0;
        const ssize_t r = vbf_recv(fd, &msg, sizeof(msg), fds, 4, &n_fds);
        if (r < 0) break;
        if (r == 0) break;
        int fence = -1;
        for (int i = 0; i < n_fds; i += 1) {
            if (i == 0 && (msg.flags & VBF_RELEASE_FLAG_FENCE)) fence = fds[i];
            else close(fds[i]);
        }
        if (!vbf_header_ok(&msg.header, r, sizeof(msg)) || msg.header.type != VBF_RELEASE) {
            if (fence >= 0) close(fence);
            continue;
        }
        vbf_handle_release(s, &msg, fence);
    }
    return G_SOURCE_CONTINUE;
}

#if VERDE_BROWSER_LINUX_WITH_FDO
static int vbf_has_extension(EGLDisplay display, const char *name) {
    const char *exts = eglQueryString(display, EGL_EXTENSIONS);
    if (exts == NULL) return 0;
    const size_t n = strlen(name);
    for (const char *p = exts; (p = strstr(p, name)) != NULL; p += n) {
        if ((p == exts || p[-1] == ' ') && (p[n] == ' ' || p[n] == '\0')) return 1;
    }
    return 0;
}
#endif

struct vbf_socket *vbf_socket_open_from_env(void *egl_display, vbf_release_fn release, void *user) {
    const char *value = getenv(VBF_SOCKET_ENV);
    if (value == NULL || value[0] == '\0') return NULL;
    char *end = NULL;
    const long fd = strtol(value, &end, 10);
    if (end == value || *end != '\0' || fd < 0) return NULL;
    /* WebKit subprocesses must not inherit the socket. */
    (void)fcntl((int)fd, F_SETFD, FD_CLOEXEC);

    struct vbf_socket *s = g_new0(struct vbf_socket, 1);
    s->fd = (int)fd;
#if VERDE_BROWSER_LINUX_WITH_FDO
    s->display = egl_display != NULL ? (EGLDisplay)egl_display : EGL_NO_DISPLAY;
#endif
    s->release = release;
    s->user = user;
    s->mode = VBF_MODE_SHM;
    for (int i = 0; i < VBF_HELD_MAX; i += 1) s->held[i].fence_fd = -1;

    /* HELLO: the GUI sends it right after spawning us. */
    struct pollfd p = { .fd = s->fd, .events = POLLIN };
    struct vbf_hello *hello = g_new0(struct vbf_hello, 1);
    int fds[4];
    int n_fds = 0;
    ssize_t r = -1;
    if (poll(&p, 1, VBF_HELLO_TIMEOUT_MS) == 1) r = vbf_recv(s->fd, hello, sizeof(*hello), fds, 4, &n_fds);
    for (int i = 0; i < n_fds; i += 1) close(fds[i]);
    const size_t fixed = offsetof(struct vbf_hello, formats);
    if (r >= (ssize_t)fixed && vbf_header_ok(&hello->header, r, fixed) && hello->header.type == VBF_HELLO) {
        const uint32_t count = MIN(hello->count, (uint32_t)((r - (ssize_t)fixed) / (ssize_t)sizeof(struct vbf_format)));
        s->format_count = MIN(count, VBF_MAX_FORMATS);
        memcpy(s->formats, hello->formats, sizeof(struct vbf_format) * s->format_count);
    }
    g_free(hello);

    const char *forced = getenv("VERDE_BROWSER_LINUX_FRAME_TRANSPORT");
    const int want_dmabuf = forced == NULL || strcmp(forced, "shm") != 0;
    if (want_dmabuf && s->format_count > 0 && egl_display == NULL) {
        s->mode = VBF_MODE_DMABUF; /* WPE Platform: WebKit allocates dma-bufs itself */
    }
#if VERDE_BROWSER_LINUX_WITH_FDO
    if (want_dmabuf && s->format_count > 0 && s->display != EGL_NO_DISPLAY && vbf_has_extension(s->display, "EGL_MESA_image_dma_buf_export")) {
        s->query = (PFNEGLEXPORTDMABUFIMAGEQUERYMESAPROC)eglGetProcAddress("eglExportDMABUFImageQueryMESA");
        s->export_image = (PFNEGLEXPORTDMABUFIMAGEMESAPROC)eglGetProcAddress("eglExportDMABUFImageMESA");
        if (s->query != NULL && s->export_image != NULL) s->mode = VBF_MODE_DMABUF;
    }
#endif

    struct vbf_mode_msg mode = { .mode = s->mode };
    vbf_header_init(&mode.header, VBF_MODE);
    if (vbf_send(s->fd, &mode, sizeof(mode), NULL, 0) != 0) s->mode = VBF_MODE_SHM;
    fprintf(stderr, "verde-browser-linux: frame transport %s (%u GUI formats)\n", s->mode == VBF_MODE_DMABUF ? "dmabuf" : "shm", s->format_count);
    fflush(stderr);
    if (s->mode == VBF_MODE_DMABUF) {
        s->source = g_unix_fd_add(s->fd, G_IO_IN | G_IO_HUP | G_IO_ERR, vbf_on_socket, s);
    }
    return s;
}

int vbf_socket_dmabuf_active(const struct vbf_socket *s) {
    return s != NULL && s->mode == VBF_MODE_DMABUF;
}

const struct vbf_format *vbf_socket_formats(const struct vbf_socket *s, unsigned *count) {
    *count = s != NULL ? s->format_count : 0;
    return s != NULL ? s->formats : NULL;
}

void vbf_socket_forward_release_fences(struct vbf_socket *s, int forward) {
    if (s != NULL) s->forward_release_fences = forward != 0;
}

static int vbf_format_accepted(const struct vbf_socket *s, uint32_t fourcc, uint64_t modifier) {
    for (uint32_t i = 0; i < s->format_count; i += 1) {
        if (s->formats[i].fourcc == fourcc && s->formats[i].modifier == modifier) return 1;
    }
    return 0;
}

static struct vbf_held *vbf_free_slot(struct vbf_socket *s) {
    for (int i = 0; i < VBF_HELD_MAX; i += 1) {
        if (s->held[i].image == NULL) return &s->held[i];
    }
    return NULL;
}

/* Copies up to VBF_MAX_DAMAGE rects; the overflow is folded into the last one's bounds. */
static uint32_t vbf_pack_damage(struct vbf_rect *out, const struct vbf_rect *in, uint32_t n) {
    if (n <= VBF_MAX_DAMAGE) {
        memcpy(out, in, sizeof(*in) * n);
        return n;
    }
    memcpy(out, in, sizeof(*in) * (VBF_MAX_DAMAGE - 1));
    int32_t x0 = INT32_MAX, y0 = INT32_MAX, x1 = INT32_MIN, y1 = INT32_MIN;
    for (uint32_t i = VBF_MAX_DAMAGE - 1; i < n; i += 1) {
        x0 = MIN(x0, in[i].x);
        y0 = MIN(y0, in[i].y);
        x1 = MAX(x1, in[i].x + in[i].w);
        y1 = MAX(y1, in[i].y + in[i].h);
    }
    out[VBF_MAX_DAMAGE - 1] = (struct vbf_rect){ x0, y0, x1 - x0, y1 - y0 };
    return VBF_MAX_DAMAGE;
}

int vbf_socket_send_dmabuf(struct vbf_socket *s, const struct vbf_dmabuf *buffer, int acquire_fence,
    const struct vbf_rect *damage, uint32_t n_damage, void *held, uint64_t sequence, uint64_t exported_at_ns) {
    if (!vbf_socket_dmabuf_active(s) || buffer == NULL || held == NULL) return 0;
    if (buffer->plane_count < 1 || buffer->plane_count > VBF_MAX_PLANES) return 0;
    struct vbf_held *slot = vbf_free_slot(s);
    if (slot == NULL) return 0;
    if (!vbf_format_accepted(s, buffer->fourcc, buffer->modifier)) {
        if (!s->reported_unsupported) {
            fprintf(stderr, "verde-browser-linux: GUI cannot import fourcc 0x%08x modifier 0x%016llx\n", buffer->fourcc, (unsigned long long)buffer->modifier);
            fflush(stderr);
            s->reported_unsupported = TRUE;
        }
        return 0;
    }
    struct vbf_frame msg;
    memset(&msg, 0, sizeof(msg));
    vbf_header_init(&msg.header, VBF_FRAME);
    msg.sequence = sequence;
    msg.width = buffer->width;
    msg.height = buffer->height;
    msg.fourcc = buffer->fourcc;
    msg.plane_count = buffer->plane_count;
    msg.modifier = buffer->modifier;
    struct stat st;
    if (fstat(buffer->fds[0], &st) == 0) msg.buffer_id = (uint64_t)st.st_ino;
    int send_fds[VBF_MAX_PLANES + 1];
    int n_fds = 0;
    for (uint32_t i = 0; i < buffer->plane_count; i += 1) {
        msg.planes[i].offset = buffer->offsets[i];
        msg.planes[i].stride = buffer->strides[i];
        send_fds[n_fds++] = buffer->fds[i] >= 0 ? buffer->fds[i] : buffer->fds[0];
    }
    if (acquire_fence >= 0) {
        msg.flags |= VBF_FRAME_FLAG_FENCE;
        send_fds[n_fds++] = acquire_fence;
    }
    msg.damage_count = damage != NULL ? vbf_pack_damage(msg.damage, damage, n_damage) : 0;
    msg.exported_at_ns = exported_at_ns;
    msg.sent_at_ns = vbf_now_ns();
    if (vbf_send(s->fd, &msg, sizeof(msg), send_fds, n_fds) != 0) return 0;
    slot->sequence = sequence;
    slot->image = held;
    slot->fence_fd = -1;
    slot->fence_source = 0;
    return 1;
}

unsigned vbf_socket_held_count(const struct vbf_socket *s) {
    if (s == NULL) return 0;
    unsigned n = 0;
    for (int i = 0; i < VBF_HELD_MAX; i += 1) n += s->held[i].image != NULL;
    return n;
}

int vbf_socket_send_frame(struct vbf_socket *s, void *image_ptr, void *held, uint32_t width, uint32_t height,
    uint64_t sequence, uint64_t exported_at_ns) {
#if VERDE_BROWSER_LINUX_WITH_FDO
    EGLImageKHR image = (EGLImageKHR)image_ptr;
    if (!vbf_socket_dmabuf_active(s) || s->query == NULL || image == EGL_NO_IMAGE_KHR) return 0;
    struct vbf_held *slot = NULL;
    for (int i = 0; i < VBF_HELD_MAX; i += 1) {
        if (s->held[i].image == NULL) {
            slot = &s->held[i];
            break;
        }
    }
    if (slot == NULL) return 0; /* GUI holds too many: degrade this frame to readback */

    int fourcc = 0;
    int planes = 0;
    EGLuint64KHR modifiers[VBF_MAX_PLANES] = { 0 };
    if (!s->query(s->display, image, &fourcc, &planes, modifiers) || planes < 1 || planes > (int)VBF_MAX_PLANES) return 0;
    /* GUIs import XRGB/ARGB the same way; an opaque view is still exported as AR24. */
    const uint32_t f = (uint32_t)fourcc;
    if (!vbf_format_accepted(s, f, modifiers[0])) {
        if (!s->reported_unsupported) {
            fprintf(stderr, "verde-browser-linux: GUI cannot import fourcc 0x%08x modifier 0x%016llx; using readback\n", f, (unsigned long long)modifiers[0]);
            fflush(stderr);
            s->reported_unsupported = TRUE;
        }
        return 0;
    }
    int fds[VBF_MAX_PLANES] = { -1, -1, -1, -1 };
    EGLint strides[VBF_MAX_PLANES] = { 0 };
    EGLint offsets[VBF_MAX_PLANES] = { 0 };
    if (!s->export_image(s->display, image, fds, strides, offsets)) return 0;

    struct vbf_frame msg;
    memset(&msg, 0, sizeof(msg));
    vbf_header_init(&msg.header, VBF_FRAME);
    msg.sequence = sequence;
    msg.width = width;
    msg.height = height;
    msg.fourcc = f;
    msg.plane_count = (uint32_t)planes;
    msg.modifier = modifiers[0];
    struct stat st;
    if (fstat(fds[0], &st) == 0) msg.buffer_id = (uint64_t)st.st_ino;
    /* Mesa may return one fd for all planes of a non-disjoint buffer (others -1). */
    int send_fds[VBF_MAX_PLANES];
    for (int i = 0; i < planes; i += 1) {
        msg.planes[i].offset = (uint32_t)offsets[i];
        msg.planes[i].stride = (uint32_t)strides[i];
        send_fds[i] = fds[i] >= 0 ? fds[i] : fds[0];
    }
    msg.exported_at_ns = exported_at_ns;
    msg.sent_at_ns = vbf_now_ns();
    /* No fence: the GUI waits for the dma-buf's implicit write fences of WebKit's
     * rendering (DMA_BUF_IOCTL_EXPORT_SYNC_FILE). The fdo backend exposes none. */
    const int ok = vbf_send(s->fd, &msg, sizeof(msg), send_fds, planes) == 0;
    for (int i = 0; i < planes; i += 1) if (fds[i] >= 0) close(fds[i]);
    if (!ok) return 0;
    slot->sequence = sequence;
    slot->image = held;
    slot->fence_fd = -1;
    slot->fence_source = 0;
    return 1;
#else
    (void)s; (void)image_ptr; (void)held; (void)width; (void)height; (void)sequence; (void)exported_at_ns;
    return 0;
#endif
}

void vbf_socket_close(struct vbf_socket *s) {
    if (s == NULL) return;
    for (int i = 0; i < VBF_HELD_MAX; i += 1) vbf_release_held(s, &s->held[i]);
    if (s->source != 0) g_source_remove(s->source);
    close(s->fd);
    g_free(s);
}
