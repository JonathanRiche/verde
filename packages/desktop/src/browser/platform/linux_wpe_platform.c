/* WPE Platform API display for the browser helper (see linux_wpe_platform.h). */
#include "linux_wpe_platform.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define VERDE_WPE_MOD_INVALID 0x00ffffffffffffffull

#define VERDE_TYPE_WPE_DISPLAY (verde_wpe_display_get_type())
G_DECLARE_FINAL_TYPE(VerdeWpeDisplay, verde_wpe_display, VERDE, WPE_DISPLAY, WPEDisplay)
#define VERDE_TYPE_WPE_VIEW (verde_wpe_view_get_type())
G_DECLARE_FINAL_TYPE(VerdeWpeView, verde_wpe_view, VERDE, WPE_VIEW, WPEView)
#define VERDE_TYPE_WPE_TOPLEVEL (verde_wpe_toplevel_get_type())
G_DECLARE_FINAL_TYPE(VerdeWpeToplevel, verde_wpe_toplevel, VERDE, WPE_TOPLEVEL, WPEToplevel)

struct _VerdeWpeDisplay {
    WPEDisplay parent;
    WPEDRMDevice *drm_device; /* NULL = SHM rendering */
    char *render_node;
    gboolean explicit_sync;
    struct vbf_format *formats;
    unsigned format_count;
    struct verde_wpe_sink sink;
    WPEKeymap *keymap;
};

struct _VerdeWpeView {
    WPEView parent;
};

struct _VerdeWpeToplevel {
    WPEToplevel parent;
};

G_DEFINE_FINAL_TYPE(VerdeWpeDisplay, verde_wpe_display, WPE_TYPE_DISPLAY)
G_DEFINE_FINAL_TYPE(VerdeWpeView, verde_wpe_view, WPE_TYPE_VIEW)
G_DEFINE_FINAL_TYPE(VerdeWpeToplevel, verde_wpe_toplevel, WPE_TYPE_TOPLEVEL)

/* ---- toplevel: one view, sized and scaled by the helper (wpe_toplevel_resized /
 * wpe_toplevel_scale_changed); page-initiated resizes are refused. */

static WPEBufferFormats *verde_wpe_display_formats(WPEDisplay *display);

static WPEBufferFormats *verde_wpe_toplevel_get_preferred_buffer_formats(WPEToplevel *toplevel) {
    return verde_wpe_display_formats(wpe_toplevel_get_display(toplevel));
}

static gboolean verde_wpe_toplevel_resize(WPEToplevel *toplevel, int width, int height) {
    (void)toplevel;
    (void)width;
    (void)height;
    return FALSE;
}

static void verde_wpe_toplevel_class_init(VerdeWpeToplevelClass *klass) {
    WPEToplevelClass *toplevel_class = WPE_TOPLEVEL_CLASS(klass);
    toplevel_class->get_preferred_buffer_formats = verde_wpe_toplevel_get_preferred_buffer_formats;
    toplevel_class->resize = verde_wpe_toplevel_resize;
}

static void verde_wpe_toplevel_init(VerdeWpeToplevel *toplevel) {
    (void)toplevel;
}

/* ---- view: frames go to the sink */

static gboolean verde_wpe_view_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage, guint n_damage, GError **error) {
    VerdeWpeDisplay *display = VERDE_WPE_DISPLAY(wpe_view_get_display(view));
    if (display->sink.render_buffer != NULL && display->sink.render_buffer(display->sink.user, view, buffer, damage, n_damage)) return TRUE;
    g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "verde helper dropped the frame");
    return FALSE;
}

static void verde_wpe_view_buffers_changed(WPEView *view, WPEBuffer **buffers, guint n_buffers) {
    (void)buffers;
    (void)n_buffers;
    VerdeWpeDisplay *display = VERDE_WPE_DISPLAY(wpe_view_get_display(view));
    if (display->sink.buffers_changed != NULL) display->sink.buffers_changed(display->sink.user, view);
}

static void verde_wpe_view_set_cursor_from_name(WPEView *view, const char *name) {
    /* The page-side cursor observer (linux_wpe.c) reports cursors to the GUI. */
    (void)view;
    (void)name;
}

static void verde_wpe_view_class_init(VerdeWpeViewClass *klass) {
    WPEViewClass *view_class = WPE_VIEW_CLASS(klass);
    view_class->render_buffer = verde_wpe_view_render_buffer;
    view_class->buffers_changed = verde_wpe_view_buffers_changed;
    view_class->set_cursor_from_name = verde_wpe_view_set_cursor_from_name;
}

static void verde_wpe_view_init(VerdeWpeView *view) {
    (void)view;
}

/* ---- display */

static gboolean verde_wpe_display_connect(WPEDisplay *display, GError **error) {
    (void)display;
    (void)error;
    return TRUE;
}

static WPEView *verde_wpe_display_create_view(WPEDisplay *display) {
    WPEView *view = g_object_new(VERDE_TYPE_WPE_VIEW, "display", display, NULL);
    WPEToplevel *toplevel = g_object_new(VERDE_TYPE_WPE_TOPLEVEL, "display", display, "max-views", 1, NULL);
    wpe_view_set_toplevel(view, toplevel);
    g_object_unref(toplevel);
    return view;
}

static gpointer verde_wpe_display_get_egl_display(WPEDisplay *display, GError **error) {
    /* The UI process never touches the buffers' pixels on the GPU. */
    (void)display;
    g_set_error_literal(error, WPE_DISPLAY_ERROR, WPE_DISPLAY_ERROR_NOT_SUPPORTED, "the verde helper has no EGL display");
    return NULL;
}

static WPEDRMDevice *verde_wpe_display_get_drm_device(WPEDisplay *display) {
    return VERDE_WPE_DISPLAY(display)->drm_device;
}

static gboolean verde_wpe_display_use_explicit_sync(WPEDisplay *display) {
    return VERDE_WPE_DISPLAY(display)->explicit_sync;
}

static WPEKeymap *verde_wpe_display_get_keymap(WPEDisplay *display) {
    VerdeWpeDisplay *self = VERDE_WPE_DISPLAY(display);
    if (self->keymap == NULL) self->keymap = wpe_keymap_xkb_new();
    return self->keymap;
}

static int verde_wpe_format_rank(guint32 fourcc) {
    /* WebKit renders RGBA8; opaque formats first (the view background is opaque). */
    switch (fourcc) {
    case 0x34325258u: return 0; /* XR24 */
    case 0x34325241u: return 1; /* AR24 */
    case 0x34324258u: return 2; /* XB24 */
    case 0x34324241u: return 3; /* AB24 */
    default: return -1;
    }
}

static WPEBufferFormats *verde_wpe_display_formats(WPEDisplay *display) {
    VerdeWpeDisplay *self = VERDE_WPE_DISPLAY(display);
    if (self->drm_device == NULL) return NULL;
    WPEBufferFormatsBuilder *builder = wpe_buffer_formats_builder_new(self->drm_device);
    wpe_buffer_formats_builder_append_group(builder, NULL, WPE_BUFFER_FORMAT_USAGE_RENDERING);
    for (int rank = 0; rank < 4; rank += 1) {
        for (unsigned i = 0; i < self->format_count; i += 1) {
            const struct vbf_format *f = &self->formats[i];
            if (verde_wpe_format_rank(f->fourcc) != rank || f->modifier == VERDE_WPE_MOD_INVALID) continue;
            wpe_buffer_formats_builder_append_format(builder, f->fourcc, f->modifier);
        }
    }
    return wpe_buffer_formats_builder_end(builder);
}

static void verde_wpe_display_finalize(GObject *object) {
    VerdeWpeDisplay *self = VERDE_WPE_DISPLAY(object);
    if (self->drm_device != NULL) wpe_drm_device_unref(self->drm_device);
    g_clear_object(&self->keymap);
    g_free(self->render_node);
    g_free(self->formats);
    G_OBJECT_CLASS(verde_wpe_display_parent_class)->finalize(object);
}

static void verde_wpe_display_class_init(VerdeWpeDisplayClass *klass) {
    G_OBJECT_CLASS(klass)->finalize = verde_wpe_display_finalize;
    WPEDisplayClass *display_class = WPE_DISPLAY_CLASS(klass);
    display_class->connect = verde_wpe_display_connect;
    display_class->create_view = verde_wpe_display_create_view;
    display_class->get_egl_display = verde_wpe_display_get_egl_display;
    display_class->get_drm_device = verde_wpe_display_get_drm_device;
    display_class->get_preferred_buffer_formats = verde_wpe_display_formats;
    display_class->use_explicit_sync = verde_wpe_display_use_explicit_sync;
    display_class->get_keymap = verde_wpe_display_get_keymap;
}

static void verde_wpe_display_init(VerdeWpeDisplay *display) {
    (void)display;
}

/* Render node for WebKit's GBM allocations: $VERDE_BROWSER_LINUX_DRM_RENDER_NODE, else the
 * first /dev/dri/renderD*. The primary node is looked up through sysfs (WebKit only uses it
 * to identify the device). */
static char *verde_wpe_find_render_node(void) {
    const char *forced = getenv("VERDE_BROWSER_LINUX_DRM_RENDER_NODE");
    if (forced != NULL && forced[0] != '\0') return g_strdup(forced);
    for (int minor = 128; minor < 192; minor += 1) {
        char path[64];
        snprintf(path, sizeof path, "/dev/dri/renderD%d", minor);
        if (access(path, R_OK | W_OK) == 0) return g_strdup(path);
    }
    return NULL;
}

static char *verde_wpe_find_primary_node(const char *render_node) {
    const char *base = strrchr(render_node, '/');
    base = base != NULL ? base + 1 : render_node;
    char *dir_path = g_strdup_printf("/sys/class/drm/%s/device/drm", base);
    DIR *dir = opendir(dir_path);
    g_free(dir_path);
    char *primary = NULL;
    if (dir != NULL) {
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strncmp(entry->d_name, "card", 4) == 0 && strchr(entry->d_name, '-') == NULL) {
                primary = g_strdup_printf("/dev/dri/%s", entry->d_name);
                break;
            }
        }
        closedir(dir);
    }
    return primary;
}

WPEDisplay *verde_wpe_display_new(const struct vbf_format *formats, unsigned count, gboolean explicit_sync,
    const struct verde_wpe_sink *sink, GError **error) {
    VerdeWpeDisplay *self = g_object_new(VERDE_TYPE_WPE_DISPLAY, NULL);
    if (sink != NULL) self->sink = *sink;
    if (count > 0) {
        self->render_node = verde_wpe_find_render_node();
        if (self->render_node != NULL) {
            char *primary = verde_wpe_find_primary_node(self->render_node);
            self->drm_device = wpe_drm_device_new(primary, self->render_node);
            g_free(primary);
        }
        if (self->drm_device != NULL) {
            self->formats = g_memdup2(formats, sizeof(*formats) * count);
            self->format_count = count;
            self->explicit_sync = explicit_sync;
        } else {
            g_clear_pointer(&self->render_node, g_free);
        }
    }
    if (!wpe_display_connect(WPE_DISPLAY(self), error)) {
        g_object_unref(self);
        return NULL;
    }
    return WPE_DISPLAY(self);
}

const char *verde_wpe_display_render_node(WPEDisplay *display) {
    return VERDE_WPE_DISPLAY(display)->render_node;
}
