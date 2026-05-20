// Standalone WPE/WebKit render-target probe for the Linux browser pane.
//
// This is intentionally not wired into Verde yet. It answers one question:
// can WPE WebKit load a page and export rendered frames to an embedder-owned
// presentation path without using the GTK snapshot loop?

#include <EGL/egl.h>
#include <glib-object.h>
#include <glib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <wpe/fdo.h>
#include <wpe/fdo-egl.h>
#include <wpe/webkit.h>

typedef struct VerdeWpeProbe {
    GMainLoop *loop;
    struct wpe_view_backend_exportable_fdo *exportable;
    WebKitWebViewBackend *backend;
    WebKitWebView *web_view;
    const char *uri;
    guint timeout_id;
    unsigned frame_count;
    unsigned egl_image_count;
    unsigned exported_image_count;
    unsigned shm_count;
    gboolean load_finished;
    int exit_code;
} VerdeWpeProbe;

static gboolean quit_probe(gpointer user_data) {
    VerdeWpeProbe *probe = (VerdeWpeProbe *)user_data;
    if (probe->loop != NULL) {
        g_main_loop_quit(probe->loop);
    }
    return G_SOURCE_REMOVE;
}

static gboolean timeout_probe(gpointer user_data) {
    VerdeWpeProbe *probe = (VerdeWpeProbe *)user_data;
    fprintf(stderr, "wpe-probe: timed out waiting for exported frames from %s\n", probe->uri);
    probe->exit_code = 2;
    if (probe->loop != NULL) {
        g_main_loop_quit(probe->loop);
    }
    return G_SOURCE_REMOVE;
}

static void mark_frame(VerdeWpeProbe *probe) {
    probe->frame_count += 1;
    probe->exit_code = 0;
    wpe_view_backend_exportable_fdo_dispatch_frame_complete(probe->exportable);
    if (probe->load_finished && probe->frame_count >= 1) {
        quit_probe(probe);
    }
}

static void export_egl_image(void *data, EGLImageKHR image) {
    VerdeWpeProbe *probe = (VerdeWpeProbe *)data;
    probe->egl_image_count += 1;
    unsigned frame = probe->frame_count + 1;
    if (frame <= 5 || frame % 60 == 0) {
        fprintf(stdout, "wpe-probe: exported raw EGLImage frame=%u image=%p\n", frame, image);
        fflush(stdout);
    }
    wpe_view_backend_exportable_fdo_egl_dispatch_release_image(probe->exportable, image);
    mark_frame(probe);
}

static void export_fdo_egl_image(void *data, struct wpe_fdo_egl_exported_image *image) {
    VerdeWpeProbe *probe = (VerdeWpeProbe *)data;
    probe->exported_image_count += 1;
    uint32_t width = wpe_fdo_egl_exported_image_get_width(image);
    uint32_t height = wpe_fdo_egl_exported_image_get_height(image);
    EGLImageKHR egl_image = wpe_fdo_egl_exported_image_get_egl_image(image);
    unsigned frame = probe->frame_count + 1;
    if (frame <= 5 || frame % 60 == 0) {
        fprintf(stdout, "wpe-probe: exported EGL frame=%u size=%ux%u image=%p\n", frame, width, height, egl_image);
        fflush(stdout);
    }
    wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(probe->exportable, image);
    mark_frame(probe);
}

static void export_shm_buffer(void *data, struct wpe_fdo_shm_exported_buffer *buffer) {
    VerdeWpeProbe *probe = (VerdeWpeProbe *)data;
    probe->shm_count += 1;
    unsigned frame = probe->frame_count + 1;
    if (frame <= 5 || frame % 60 == 0) {
        fprintf(stdout, "wpe-probe: exported SHM frame=%u buffer=%p\n", frame, (void *)buffer);
        fflush(stdout);
    }
    wpe_view_backend_exportable_fdo_egl_dispatch_release_shm_exported_buffer(probe->exportable, buffer);
    mark_frame(probe);
}

static void on_load_changed(WebKitWebView *web_view, WebKitLoadEvent load_event, gpointer user_data) {
    (void)user_data;
    const char *label = "unknown";
    switch (load_event) {
    case WEBKIT_LOAD_STARTED:
        label = "started";
        break;
    case WEBKIT_LOAD_REDIRECTED:
        label = "redirected";
        break;
    case WEBKIT_LOAD_COMMITTED:
        label = "committed";
        break;
    case WEBKIT_LOAD_FINISHED:
        label = "finished";
        ((VerdeWpeProbe *)user_data)->load_finished = TRUE;
        break;
    }
    fprintf(stdout, "wpe-probe: load %s uri=%s\n", label, webkit_web_view_get_uri(web_view));
    fflush(stdout);
    VerdeWpeProbe *probe = (VerdeWpeProbe *)user_data;
    if (probe->load_finished && probe->frame_count >= 1) {
        quit_probe(probe);
    }
}

static gboolean on_load_failed(WebKitWebView *web_view, WebKitLoadEvent load_event, const gchar *failing_uri, GError *error, gpointer user_data) {
    (void)web_view;
    (void)load_event;
    VerdeWpeProbe *probe = (VerdeWpeProbe *)user_data;
    fprintf(stderr, "wpe-probe: load failed uri=%s error=%s\n", failing_uri != NULL ? failing_uri : "(null)", error != NULL ? error->message : "(unknown)");
    probe->exit_code = 3;
    return FALSE;
}

static void on_progress_changed(GObject *object, GParamSpec *pspec, gpointer user_data) {
    (void)pspec;
    (void)user_data;
    WebKitWebView *web_view = WEBKIT_WEB_VIEW(object);
    fprintf(stdout, "wpe-probe: progress %.3f\n", webkit_web_view_get_estimated_load_progress(web_view));
    fflush(stdout);
}

static void on_frame_displayed(WebKitWebView *web_view, gpointer user_data) {
    (void)web_view;
    VerdeWpeProbe *probe = (VerdeWpeProbe *)user_data;
    if (probe->frame_count <= 5 || probe->frame_count % 60 == 0) {
        fprintf(stdout, "wpe-probe: WebKit frame-displayed callback\n");
        fflush(stdout);
    }
}

static void destroy_exportable(gpointer user_data) {
    struct wpe_view_backend_exportable_fdo *exportable = (struct wpe_view_backend_exportable_fdo *)user_data;
    if (exportable != NULL) {
        wpe_view_backend_exportable_fdo_destroy(exportable);
    }
}

int main(int argc, char **argv) {
    const char *uri = argc > 1 ? argv[1] : "https://lytx.io/";
    uint32_t width = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 10) : 1280;
    uint32_t height = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 10) : 720;
    float scale = argc > 4 ? strtof(argv[4], NULL) : 1.0f;
    const char *backend_library = argc > 5 ? argv[5] : "libWPEBackend-fdo-1.0.so";

    if (width == 0 || height == 0) {
        fprintf(stderr, "usage: %s [uri] [width] [height] [scale]\n", argv[0]);
        return 64;
    }

    VerdeWpeProbe probe = {
        .uri = uri,
        .exit_code = 1,
    };

    if (!wpe_loader_init(backend_library)) {
        fprintf(stderr, "wpe-probe: failed to initialize WPE backend library %s\n", backend_library);
        return 1;
    }
    fprintf(stdout, "wpe-probe: backend=%s\n", wpe_loader_get_loaded_implementation_library_name());
    fflush(stdout);

    EGLDisplay egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (egl_display == EGL_NO_DISPLAY) {
        fprintf(stderr, "wpe-probe: eglGetDisplay returned EGL_NO_DISPLAY\n");
    } else {
        EGLint egl_major = 0;
        EGLint egl_minor = 0;
        if (!eglInitialize(egl_display, &egl_major, &egl_minor)) {
            fprintf(stderr, "wpe-probe: eglInitialize failed error=0x%x\n", eglGetError());
        } else if (!wpe_fdo_initialize_for_egl_display(egl_display)) {
            fprintf(stderr, "wpe-probe: wpe_fdo_initialize_for_egl_display failed\n");
        } else {
            fprintf(stdout, "wpe-probe: EGL initialized version=%d.%d\n", egl_major, egl_minor);
            fflush(stdout);
        }
    }

    const struct wpe_view_backend_exportable_fdo_egl_client client = {
        .export_egl_image = export_egl_image,
        .export_fdo_egl_image = export_fdo_egl_image,
        .export_shm_buffer = export_shm_buffer,
    };

    probe.exportable = wpe_view_backend_exportable_fdo_egl_create(&client, &probe, width, height);
    if (probe.exportable == NULL) {
        fprintf(stderr, "wpe-probe: failed to create WPE FDO EGL exportable backend\n");
        return 1;
    }

    struct wpe_view_backend *view_backend = wpe_view_backend_exportable_fdo_get_view_backend(probe.exportable);
    if (view_backend == NULL) {
        fprintf(stderr, "wpe-probe: failed to get WPE view backend\n");
        wpe_view_backend_exportable_fdo_destroy(probe.exportable);
        return 1;
    }

    wpe_view_backend_dispatch_set_size(view_backend, width, height);
    wpe_view_backend_dispatch_set_device_scale_factor(view_backend, scale);
    wpe_view_backend_set_target_refresh_rate(view_backend, 60000);
    wpe_view_backend_add_activity_state(
        view_backend,
        wpe_view_activity_state_visible | wpe_view_activity_state_focused | wpe_view_activity_state_in_window);

    probe.backend = webkit_web_view_backend_new(view_backend, destroy_exportable, probe.exportable);
    if (probe.backend == NULL) {
        fprintf(stderr, "wpe-probe: failed to create WebKit web view backend\n");
        wpe_view_backend_exportable_fdo_destroy(probe.exportable);
        return 1;
    }

    probe.web_view = WEBKIT_WEB_VIEW(webkit_web_view_new(probe.backend));
    if (probe.web_view == NULL) {
        fprintf(stderr, "wpe-probe: failed to create WebKit web view\n");
        g_object_unref(probe.backend);
        return 1;
    }

    g_signal_connect(probe.web_view, "load-changed", G_CALLBACK(on_load_changed), &probe);
    g_signal_connect(probe.web_view, "load-failed", G_CALLBACK(on_load_failed), &probe);
    g_signal_connect(probe.web_view, "notify::estimated-load-progress", G_CALLBACK(on_progress_changed), &probe);
    webkit_web_view_add_frame_displayed_callback(probe.web_view, on_frame_displayed, &probe, NULL);

    fprintf(stdout, "wpe-probe: loading %s at %ux%u scale=%.2f\n", uri, width, height, scale);
    fflush(stdout);

    probe.loop = g_main_loop_new(NULL, FALSE);
    probe.timeout_id = g_timeout_add_seconds(15, timeout_probe, &probe);
    webkit_web_view_load_uri(probe.web_view, uri);
    g_main_loop_run(probe.loop);

    if (probe.timeout_id != 0) {
        g_source_remove(probe.timeout_id);
    }

    fprintf(
        stdout,
        "wpe-probe: summary frames=%u raw_egl=%u exported_egl=%u shm=%u exit=%d\n",
        probe.frame_count,
        probe.egl_image_count,
        probe.exported_image_count,
        probe.shm_count,
        probe.exit_code);
    fflush(stdout);

    // Process teardown is enough for this probe. WPEWebKit and the backend may
    // still have cross-process shutdown work queued here, and explicit GLib
    // teardown can obscure the render-target result with shutdown-only failures.
    _exit(probe.exit_code);
}
