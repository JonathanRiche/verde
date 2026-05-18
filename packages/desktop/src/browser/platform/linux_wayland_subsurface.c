#define _GNU_SOURCE

#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

typedef struct VerdeWaylandSubsurface {
    struct wl_display *display;
    struct wl_surface *parent_surface;
    struct wl_event_queue *event_queue;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_subcompositor *subcompositor;
    struct wl_shm *shm;
    struct wl_surface *surface;
    struct wl_subsurface *subsurface;
    struct wl_buffer *buffer;
    void *pixels;
    uint32_t buffer_width;
    uint32_t buffer_height;
    uint32_t width;
    uint32_t height;
    int32_t x;
    int32_t y;
    int visible;
} VerdeWaylandSubsurface;

typedef struct VerdeWaylandRegistryState {
    uint32_t compositor_name;
    uint32_t compositor_version;
    uint32_t subcompositor_name;
    uint32_t shm_name;
} VerdeWaylandRegistryState;

VerdeWaylandSubsurface *verde_wayland_subsurface_create(void *display_ptr, void *parent_surface_ptr);
void verde_wayland_subsurface_destroy(VerdeWaylandSubsurface *surface);
int verde_wayland_subsurface_set_bounds(VerdeWaylandSubsurface *surface, int32_t x, int32_t y, uint32_t width, uint32_t height);
int verde_wayland_subsurface_show(VerdeWaylandSubsurface *surface);
void verde_wayland_subsurface_hide(VerdeWaylandSubsurface *surface);

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version
) {
    (void)registry;
    VerdeWaylandRegistryState *state = (VerdeWaylandRegistryState *)data;
    if (strcmp(interface, "wl_compositor") == 0) {
        state->compositor_name = name;
        state->compositor_version = version;
    } else if (strcmp(interface, "wl_subcompositor") == 0) {
        state->subcompositor_name = name;
    } else if (strcmp(interface, "wl_shm") == 0) {
        state->shm_name = name;
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void destroy_buffer(VerdeWaylandSubsurface *surface) {
    if (surface->buffer != NULL) {
        wl_buffer_destroy(surface->buffer);
        surface->buffer = NULL;
    }
    if (surface->pixels != NULL) {
        const size_t byte_len = (size_t)surface->buffer_width * (size_t)surface->buffer_height * 4u;
        munmap(surface->pixels, byte_len);
        surface->pixels = NULL;
    }
    surface->buffer_width = 0;
    surface->buffer_height = 0;
}

static int ensure_buffer(VerdeWaylandSubsurface *surface, uint32_t width, uint32_t height) {
    if (surface->buffer != NULL && surface->pixels != NULL && surface->buffer_width == width && surface->buffer_height == height) {
        return 0;
    }

    destroy_buffer(surface);

    if (width > 8192 || height > 8192) {
        fprintf(stderr, "verde wayland subsurface refusing oversized buffer %ux%u\n", width, height);
        fflush(stderr);
        return -1;
    }

    const uint32_t stride = width * 4u;
    const size_t byte_len = (size_t)stride * (size_t)height;
    if (byte_len == 0) {
        return -1;
    }
    int fd = memfd_create("verde-wayland-browser-subsurface", MFD_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "verde wayland subsurface memfd_create failed errno=%d\n", errno);
        fflush(stderr);
        return -1;
    }
    if (ftruncate(fd, (off_t)byte_len) != 0) {
        fprintf(stderr, "verde wayland subsurface ftruncate failed bytes=%zu errno=%d\n", byte_len, errno);
        fflush(stderr);
        close(fd);
        return -1;
    }

    surface->pixels = mmap(NULL, byte_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (surface->pixels == MAP_FAILED) {
        surface->pixels = NULL;
        fprintf(stderr, "verde wayland subsurface mmap failed bytes=%zu errno=%d\n", byte_len, errno);
        fflush(stderr);
        close(fd);
        return -1;
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(surface->shm, fd, (int32_t)byte_len);
    close(fd);
    if (pool == NULL) {
        fprintf(stderr, "verde wayland subsurface wl_shm_create_pool failed\n");
        fflush(stderr);
        destroy_buffer(surface);
        return -1;
    }
    surface->buffer = wl_shm_pool_create_buffer(
        pool,
        0,
        (int32_t)width,
        (int32_t)height,
        (int32_t)stride,
        WL_SHM_FORMAT_ARGB8888
    );
    wl_shm_pool_destroy(pool);
    if (surface->buffer == NULL) {
        fprintf(stderr, "verde wayland subsurface wl_shm_pool_create_buffer failed\n");
        fflush(stderr);
        destroy_buffer(surface);
        return -1;
    }
    surface->buffer_width = width;
    surface->buffer_height = height;
    return 0;
}

static void fill_probe_pixels(VerdeWaylandSubsurface *surface) {
    if (surface->pixels == NULL || surface->width == 0 || surface->height == 0) {
        return;
    }
    uint32_t *pixels = (uint32_t *)surface->pixels;
    const uint32_t width = surface->buffer_width;
    const uint32_t height = surface->buffer_height;
    for (uint32_t y = 0; y < height; y += 1) {
        for (uint32_t x = 0; x < width; x += 1) {
            const int border = x < 2 || y < 2 || x + 3 > width || y + 3 > height;
            pixels[(size_t)y * (size_t)width + (size_t)x] = border ? 0xff3fb950u : 0xff0b1115u;
        }
    }
}

static int render_surface(VerdeWaylandSubsurface *surface) {
    if (!surface->visible || surface->surface == NULL) {
        return 0;
    }
    if (surface->width == 0 || surface->height == 0) {
        return 0;
    }
    if (ensure_buffer(surface, surface->width, surface->height) != 0) {
        return -1;
    }

    fill_probe_pixels(surface);
    wl_surface_attach(surface->surface, surface->buffer, 0, 0);
    wl_surface_damage_buffer(surface->surface, 0, 0, (int32_t)surface->width, (int32_t)surface->height);
    wl_surface_commit(surface->surface);
    wl_display_flush(surface->display);
    return 0;
}

VerdeWaylandSubsurface *verde_wayland_subsurface_create(void *display_ptr, void *parent_surface_ptr) {
    if (display_ptr == NULL || parent_surface_ptr == NULL) {
        return NULL;
    }

    VerdeWaylandSubsurface *surface = calloc(1, sizeof(VerdeWaylandSubsurface));
    if (surface == NULL) {
        return NULL;
    }
    surface->display = (struct wl_display *)display_ptr;
    surface->parent_surface = (struct wl_surface *)parent_surface_ptr;

    surface->event_queue = wl_display_create_queue(surface->display);
    if (surface->event_queue == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }

    struct wl_display *display_wrapper = wl_proxy_create_wrapper(surface->display);
    if (display_wrapper == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }
    wl_proxy_set_queue((struct wl_proxy *)display_wrapper, surface->event_queue);

    surface->registry = wl_display_get_registry(display_wrapper);
    wl_proxy_wrapper_destroy(display_wrapper);
    if (surface->registry == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }

    VerdeWaylandRegistryState registry_state = {0};
    if (wl_registry_add_listener(surface->registry, &registry_listener, &registry_state) != 0) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }
    if (wl_display_roundtrip_queue(surface->display, surface->event_queue) < 0) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }
    if (registry_state.compositor_name == 0 || registry_state.subcompositor_name == 0 || registry_state.shm_name == 0) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }

    uint32_t compositor_version = registry_state.compositor_version < 4 ? registry_state.compositor_version : 4;
    surface->compositor = wl_registry_bind(surface->registry, registry_state.compositor_name, &wl_compositor_interface, compositor_version);
    surface->subcompositor = wl_registry_bind(surface->registry, registry_state.subcompositor_name, &wl_subcompositor_interface, 1);
    surface->shm = wl_registry_bind(surface->registry, registry_state.shm_name, &wl_shm_interface, 1);
    if (surface->compositor == NULL || surface->subcompositor == NULL || surface->shm == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }

    surface->surface = wl_compositor_create_surface(surface->compositor);
    if (surface->surface == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }
    surface->subsurface = wl_subcompositor_get_subsurface(surface->subcompositor, surface->surface, surface->parent_surface);
    if (surface->subsurface == NULL) {
        verde_wayland_subsurface_destroy(surface);
        return NULL;
    }

    wl_subsurface_set_desync(surface->subsurface);
    wl_subsurface_set_position(surface->subsurface, surface->x, surface->y);
    wl_surface_commit(surface->parent_surface);
    wl_display_flush(surface->display);
    return surface;
}

void verde_wayland_subsurface_destroy(VerdeWaylandSubsurface *surface) {
    if (surface == NULL) {
        return;
    }
    verde_wayland_subsurface_hide(surface);
    destroy_buffer(surface);
    if (surface->subsurface != NULL) {
        wl_subsurface_destroy(surface->subsurface);
    }
    if (surface->surface != NULL) {
        wl_surface_destroy(surface->surface);
    }
    if (surface->shm != NULL) {
        wl_shm_destroy(surface->shm);
    }
    if (surface->subcompositor != NULL) {
        wl_subcompositor_destroy(surface->subcompositor);
    }
    if (surface->compositor != NULL) {
        wl_compositor_destroy(surface->compositor);
    }
    if (surface->registry != NULL) {
        wl_registry_destroy(surface->registry);
    }
    if (surface->event_queue != NULL) {
        wl_event_queue_destroy(surface->event_queue);
    }
    free(surface);
}

int verde_wayland_subsurface_set_bounds(VerdeWaylandSubsurface *surface, int32_t x, int32_t y, uint32_t width, uint32_t height) {
    if (surface == NULL) {
        return -1;
    }
    surface->x = x;
    surface->y = y;
    surface->width = width == 0 ? 1 : width;
    surface->height = height == 0 ? 1 : height;
    if (surface->subsurface != NULL) {
        wl_subsurface_set_position(surface->subsurface, surface->x, surface->y);
        wl_surface_commit(surface->parent_surface);
    }
    return render_surface(surface);
}

int verde_wayland_subsurface_show(VerdeWaylandSubsurface *surface) {
    if (surface == NULL) {
        return -1;
    }
    surface->visible = 1;
    return render_surface(surface);
}

void verde_wayland_subsurface_hide(VerdeWaylandSubsurface *surface) {
    if (surface == NULL) {
        return;
    }
    surface->visible = 0;
    if (surface->surface != NULL) {
        wl_surface_attach(surface->surface, NULL, 0, 0);
        wl_surface_commit(surface->surface);
        wl_display_flush(surface->display);
    }
}
