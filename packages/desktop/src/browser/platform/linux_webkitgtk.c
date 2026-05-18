#include <cairo.h>
#include <gtk/gtk.h>
#include <jsc/jsc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <webkit/webkit.h>

#define VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT 3
#define VERDE_BROWSER_LINUX_FRAME_BYTES_MAX (4096u * 2160u * 4u)

enum verde_browser_linux_event_kind {
    VERDE_BROWSER_LINUX_EVENT_OPENED = 1,
    VERDE_BROWSER_LINUX_EVENT_CLOSED = 2,
    VERDE_BROWSER_LINUX_EVENT_NAVIGATED = 3,
    VERDE_BROWSER_LINUX_EVENT_TITLE_CHANGED = 4,
    VERDE_BROWSER_LINUX_EVENT_DOCUMENT_LOADED = 5,
    VERDE_BROWSER_LINUX_EVENT_JS_MESSAGE = 6,
    VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT = 7,
    VERDE_BROWSER_LINUX_EVENT_FAILED = 8,
};

struct verde_browser_linux_event {
    int kind;
    char *payload;
};

struct verde_browser_linux {
    GtkWidget *window;
    WebKitWebView *web_view;
    WebKitUserContentManager *content_manager;
    GQueue *events;
    gboolean visible;
    gboolean snapshot_pending;
    gboolean snapshot_requested_while_pending;
    gboolean snapshot_dirty;
    gchar *snapshot_path;
    unsigned char *frame_slots[VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT];
    gboolean frame_slots_ready[VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT];
    guint8 frame_next_slot;
    guint64 snapshot_next_sequence;
    guint64 snapshot_pending_sequence;
    guint64 snapshot_ready_sequence;
    gint snapshot_ready_slot;
    gint64 snapshot_request_started_us;
    gint snapshot_width;
    gint snapshot_height;
    gsize snapshot_byte_len;
    gint target_width;
    gint target_height;
    guint modifier_state;
    unsigned long host_window;
};

enum verde_browser_linux_modifier_bits {
    VERDE_BROWSER_LINUX_MOD_SHIFT = 1 << 0,
    VERDE_BROWSER_LINUX_MOD_CTRL = 1 << 1,
    VERDE_BROWSER_LINUX_MOD_ALT = 1 << 2,
    VERDE_BROWSER_LINUX_MOD_SUPER = 1 << 3,
};

static void verde_browser_linux_queue_event(struct verde_browser_linux *browser, int kind, const char *payload) {
    struct verde_browser_linux_event *event = g_new0(struct verde_browser_linux_event, 1);
    event->kind = kind;
    event->payload = payload != NULL ? g_strdup(payload) : NULL;
    g_queue_push_tail(browser->events, event);
}

static double verde_browser_linux_elapsed_ms(gint64 start_us, gint64 end_us) {
    if (start_us <= 0 || end_us < start_us) return 0.0;
    return (double)(end_us - start_us) / 1000.0;
}

static char *verde_browser_linux_value_to_json_or_string(JSCValue *value) {
    char *json = jsc_value_to_json(value, 0);
    if (json != NULL) return json;
    return jsc_value_to_string(value);
}

static void verde_browser_linux_request_snapshot(struct verde_browser_linux *browser);
static void verde_browser_linux_run_internal_script(struct verde_browser_linux *browser, const char *script);
static gboolean verde_browser_linux_visible_helper_enabled(void);
static gboolean verde_browser_linux_wayland_diagnostic_helper_enabled(void);
static gboolean verde_browser_linux_direct_surface_active(void);
static gboolean verde_browser_linux_frame_log_enabled(void);

static gboolean verde_browser_linux_apply_size(struct verde_browser_linux *browser, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return FALSE;
    const gboolean changed = browser->target_width != width || browser->target_height != height;
    browser->target_width = width;
    browser->target_height = height;
    if (!changed) return FALSE;
    gtk_window_set_default_size(GTK_WINDOW(browser->window), width, height);
    gtk_widget_set_size_request(GTK_WIDGET(browser->web_view), width, height);
    return TRUE;
}

static gboolean verde_browser_linux_visible_helper_enabled(void) {
    if (verde_browser_linux_wayland_diagnostic_helper_enabled()) return TRUE;
    const char *value = getenv("VERDE_BROWSER_LINUX_SHOW_HELPER");
    const char *session_type = getenv("XDG_SESSION_TYPE");
    const char *gdk_backend = getenv("GDK_BACKEND");

    if (value != NULL) {
        if (strcmp(value, "1") == 0) return TRUE;
        if (strcmp(value, "0") == 0) return FALSE;
    }

    if (session_type != NULL && strcmp(session_type, "x11") == 0) return TRUE;
    if (session_type != NULL && strcmp(session_type, "wayland") == 0) return TRUE;

    if (gdk_backend != NULL && strstr(gdk_backend, "wayland") != NULL) return TRUE;
    return gdk_backend != NULL && strstr(gdk_backend, "x11") != NULL;
}

static gboolean verde_browser_linux_wayland_diagnostic_helper_enabled(void) {
    const char *value = getenv("VERDE_BROWSER_LINUX_WAYLAND_HELPER");
    if (value == NULL) value = getenv("VERDE_BROWSER_LINUX_NATIVE_WAYLAND_SURFACE");
    if (value == NULL || strcmp(value, "1") != 0) return FALSE;

    const char *session_type = getenv("XDG_SESSION_TYPE");
    if (session_type != NULL) {
        if (strcmp(session_type, "wayland") == 0) return TRUE;
        if (strcmp(session_type, "x11") == 0) return FALSE;
    }

    const char *wayland_display = getenv("WAYLAND_DISPLAY");
    if (wayland_display != NULL && wayland_display[0] != '\0') return TRUE;

    const char *gdk_backend = getenv("GDK_BACKEND");
    return gdk_backend != NULL && strstr(gdk_backend, "wayland") != NULL;
}

static gboolean verde_browser_linux_direct_surface_active(void) {
    return verde_browser_linux_visible_helper_enabled();
}

static gboolean verde_browser_linux_frame_log_enabled(void) {
    const char *value = getenv("VERDE_BROWSER_FRAME_LOG");
    return value != NULL && strcmp(value, "1") == 0;
}

static gboolean verde_browser_linux_read_frame_fd(guint index, int *fd) {
    char name[64];
    snprintf(name, sizeof(name), "VERDE_BROWSER_LINUX_FRAME%u_FD", index);
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') return FALSE;
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || *end != '\0' || parsed < 0) return FALSE;
    *fd = (int)parsed;
    return TRUE;
}

static gboolean verde_browser_linux_shared_frames_enabled(struct verde_browser_linux *browser) {
    if (browser == NULL) return FALSE;
    for (guint index = 0; index < VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT; index += 1) {
        if (!browser->frame_slots_ready[index] || browser->frame_slots[index] == NULL) return FALSE;
    }
    return TRUE;
}

static void verde_browser_linux_map_frame_slots(struct verde_browser_linux *browser) {
    if (browser == NULL) return;
    for (guint index = 0; index < VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT; index += 1) {
        int fd = -1;
        if (!verde_browser_linux_read_frame_fd(index, &fd)) return;
        void *mapping = mmap(NULL, VERDE_BROWSER_LINUX_FRAME_BYTES_MAX, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapping == MAP_FAILED) {
            browser->frame_slots[index] = NULL;
            browser->frame_slots_ready[index] = FALSE;
            return;
        }
        browser->frame_slots[index] = mapping;
        browser->frame_slots_ready[index] = TRUE;
    }
}

static void verde_browser_linux_unmap_frame_slots(struct verde_browser_linux *browser) {
    if (browser == NULL) return;
    for (guint index = 0; index < VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT; index += 1) {
        if (!browser->frame_slots_ready[index] || browser->frame_slots[index] == NULL) continue;
        munmap(browser->frame_slots[index], VERDE_BROWSER_LINUX_FRAME_BYTES_MAX);
        browser->frame_slots[index] = NULL;
        browser->frame_slots_ready[index] = FALSE;
    }
}

static void verde_browser_linux_apply_host_window(struct verde_browser_linux *browser) {
    (void)browser;
}

static void verde_browser_linux_on_uri_changed(GObject *object, GParamSpec *pspec, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    const char *uri = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(object));
    (void)pspec;
    if (uri == NULL) return;
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_NAVIGATED, uri);
}

static void verde_browser_linux_on_title_changed(GObject *object, GParamSpec *pspec, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    const char *title = webkit_web_view_get_title(WEBKIT_WEB_VIEW(object));
    (void)pspec;
    if (title == NULL) return;
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_TITLE_CHANGED, title);
}

static void verde_browser_linux_on_script_message(WebKitUserContentManager *manager, JSCValue *value, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    char *payload = verde_browser_linux_value_to_json_or_string(value);
    (void)manager;
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_JS_MESSAGE, payload);
    g_free(payload);
}

static void verde_browser_linux_on_snapshot_finished(GObject *object, GAsyncResult *result, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    GError *error = NULL;
    const guint64 sequence = browser->snapshot_pending_sequence;
    const gint64 request_started_us = browser->snapshot_request_started_us;
    GdkTexture *texture = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(object), result, &error);
    browser->snapshot_pending = FALSE;

    if (error != NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
        g_error_free(error);
        return;
    }
    if (texture == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot texture was null.");
        return;
    }

    const gint source_width = gdk_texture_get_width(texture);
    const gint source_height = gdk_texture_get_height(texture);
    const gint64 scale_started_us = g_get_monotonic_time();
    const gint64 scale_finished_us = g_get_monotonic_time();

    const gint width = source_width;
    const gint height = source_height;

    if (width <= 0 || height <= 0) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot texture had no pixel data.");
        g_object_unref(texture);
        return;
    }

    const gsize contiguous_len = (gsize)width * (gsize)height * 4;
    gchar *snapshot_path = NULL;
    gint snapshot_slot = -1;
    const gint64 write_started_us = g_get_monotonic_time();

    if (verde_browser_linux_shared_frames_enabled(browser) && contiguous_len <= VERDE_BROWSER_LINUX_FRAME_BYTES_MAX) {
        snapshot_slot = browser->frame_next_slot;
        unsigned char *slot = browser->frame_slots[snapshot_slot];
        GdkTextureDownloader *downloader = gdk_texture_downloader_new(texture);
        gdk_texture_downloader_set_format(downloader, GDK_MEMORY_B8G8R8A8);
        gdk_texture_downloader_download_into(downloader, slot, (gsize)width * 4);
        gdk_texture_downloader_free(downloader);
        browser->frame_next_slot = (guint8)((browser->frame_next_slot + 1) % VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT);
    } else {
        unsigned char *pixels = g_malloc(contiguous_len);
        GdkTextureDownloader *downloader = gdk_texture_downloader_new(texture);
        gdk_texture_downloader_set_format(downloader, GDK_MEMORY_B8G8R8A8);
        gdk_texture_downloader_download_into(downloader, pixels, (gsize)width * 4);
        gdk_texture_downloader_free(downloader);

        snapshot_path = g_strdup_printf("/tmp/verde-browser-linux-frame-%d-%" G_GUINT64_FORMAT ".rgba", getpid(), sequence);
        FILE *file = fopen(snapshot_path, "wb");
        if (file == NULL) {
            g_free(pixels);
            g_free(snapshot_path);
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to open Linux snapshot file.");
            g_object_unref(texture);
            return;
        }

        if (fwrite(pixels, 1, contiguous_len, file) != contiguous_len) {
            fclose(file);
            remove(snapshot_path);
            g_free(pixels);
            g_free(snapshot_path);
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to write Linux snapshot pixels.");
            g_object_unref(texture);
            return;
        }
        fclose(file);
        g_free(pixels);
    }
    const gint64 write_finished_us = g_get_monotonic_time();

    if (browser->snapshot_path != NULL) {
        if (browser->snapshot_dirty) {
            remove(browser->snapshot_path);
        }
        g_free(browser->snapshot_path);
    }
    browser->snapshot_path = snapshot_path;
    browser->snapshot_ready_sequence = sequence;
    browser->snapshot_ready_slot = snapshot_slot;
    browser->snapshot_width = width;
    browser->snapshot_height = height;
    browser->snapshot_byte_len = contiguous_len;
    browser->snapshot_dirty = TRUE;
    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(
            stderr,
            "verde-browser-linux snapshot seq=%" G_GUINT64_FORMAT " capture_ms=%.3f scale_ms=%.3f write_ms=%.3f bytes=%zu size=%dx%d source=%dx%d scaled=%d shared_slot=%d queued_again=%d\n",
            sequence,
            verde_browser_linux_elapsed_ms(request_started_us, write_started_us),
            verde_browser_linux_elapsed_ms(scale_started_us, scale_finished_us),
            verde_browser_linux_elapsed_ms(write_started_us, write_finished_us),
            (size_t)contiguous_len,
            width,
            height,
            source_width,
            source_height,
            0,
            snapshot_slot,
            browser->snapshot_requested_while_pending ? 1 : 0
        );
        fflush(stderr);
    }
    g_object_unref(texture);
    if (browser->snapshot_requested_while_pending) {
        browser->snapshot_requested_while_pending = FALSE;
        verde_browser_linux_request_snapshot(browser);
    }
}

static void verde_browser_linux_request_snapshot(struct verde_browser_linux *browser) {
    if (browser == NULL) return;
    if (!browser->visible || verde_browser_linux_direct_surface_active()) return;
    if (browser->snapshot_pending) {
        browser->snapshot_requested_while_pending = TRUE;
        return;
    }
    browser->snapshot_pending = TRUE;
    browser->snapshot_pending_sequence = ++browser->snapshot_next_sequence;
    browser->snapshot_request_started_us = g_get_monotonic_time();
    webkit_web_view_get_snapshot(
        browser->web_view,
        WEBKIT_SNAPSHOT_REGION_VISIBLE,
        WEBKIT_SNAPSHOT_OPTIONS_NONE,
        NULL,
        verde_browser_linux_on_snapshot_finished,
        browser
    );
}

static void verde_browser_linux_on_load_changed(WebKitWebView *web_view, WebKitLoadEvent load_event, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    (void)web_view;
    if (load_event == WEBKIT_LOAD_FINISHED) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_DOCUMENT_LOADED, NULL);
        if (verde_browser_linux_direct_surface_active()) return;
        verde_browser_linux_request_snapshot(browser);
    }
}

static void verde_browser_linux_on_eval_finished(GObject *object, GAsyncResult *result, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (error != NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
        g_error_free(error);
        return;
    }
    if (value == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT, "null");
        if (verde_browser_linux_direct_surface_active()) return;
        verde_browser_linux_request_snapshot(browser);
        return;
    }

    char *payload = verde_browser_linux_value_to_json_or_string(value);
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT, payload);
    g_free(payload);
    g_object_unref(value);
    if (!verde_browser_linux_direct_surface_active()) verde_browser_linux_request_snapshot(browser);
}

static void verde_browser_linux_on_post_json_finished(GObject *object, GAsyncResult *result, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (error != NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
        g_error_free(error);
        return;
    }
    if (value != NULL) g_object_unref(value);
    if (!verde_browser_linux_direct_surface_active()) verde_browser_linux_request_snapshot(browser);
}

static void verde_browser_linux_on_internal_script_finished(GObject *object, GAsyncResult *result, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (error != NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
        g_error_free(error);
        return;
    }
    if (value != NULL) {
        g_object_unref(value);
    }
    if (!verde_browser_linux_direct_surface_active()) verde_browser_linux_request_snapshot(browser);
}

static void verde_browser_linux_run_internal_script(struct verde_browser_linux *browser, const char *script) {
    if (browser == NULL || script == NULL) return;
    webkit_web_view_evaluate_javascript(
        browser->web_view,
        script,
        -1,
        NULL,
        "app://verde-browser-input.js",
        NULL,
        verde_browser_linux_on_internal_script_finished,
        browser
    );
}

struct verde_browser_linux *verde_browser_linux_create(void) {
    if (!gtk_init_check()) {
        return NULL;
    }

    struct verde_browser_linux *browser = g_new0(struct verde_browser_linux, 1);
    browser->events = g_queue_new();
    browser->target_width = 1280;
    browser->target_height = 720;
    browser->snapshot_ready_slot = -1;
    verde_browser_linux_map_frame_slots(browser);

    const gboolean visible_helper = verde_browser_linux_visible_helper_enabled();
    browser->window = gtk_window_new();
    gtk_window_set_default_size(GTK_WINDOW(browser->window), visible_helper ? 1 : 1280, visible_helper ? 1 : 720);
    gtk_window_set_title(GTK_WINDOW(browser->window), "Verde Browser Surface");
    gtk_window_set_decorated(GTK_WINDOW(browser->window), FALSE);

    browser->web_view = WEBKIT_WEB_VIEW(webkit_web_view_new());
    browser->content_manager = webkit_web_view_get_user_content_manager(browser->web_view);
    g_object_ref(browser->content_manager);

    GdkRGBA browser_background = { 0.0, 0.0, 0.0, 1.0 };
    webkit_web_view_set_background_color(browser->web_view, &browser_background);
    gtk_window_set_child(GTK_WINDOW(browser->window), GTK_WIDGET(browser->web_view));

    WebKitSettings *settings = webkit_web_view_get_settings(browser->web_view);
    webkit_settings_set_enable_developer_extras(settings, TRUE);
    gtk_widget_set_focusable(GTK_WIDGET(browser->web_view), TRUE);

    WebKitUserScript *bridge_script = webkit_user_script_new(
        "(function(){"
        "const bridge={postMessage:function(payload){window.webkit.messageHandlers.verde.postMessage(String(payload));}};"
        "window.__VERDE_BROWSER_IPC__=bridge;"
        "window.__VERDE_CEF_IPC__=bridge;"
        "window.verde=bridge;"
        "})();",
        WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        NULL,
        NULL
    );
    webkit_user_content_manager_add_script(browser->content_manager, bridge_script);
    webkit_user_script_unref(bridge_script);
    g_signal_connect(browser->content_manager, "script-message-received::verde", G_CALLBACK(verde_browser_linux_on_script_message), browser);
    if (!webkit_user_content_manager_register_script_message_handler(browser->content_manager, "verde", NULL)) {
        g_free(browser->snapshot_path);
        verde_browser_linux_unmap_frame_slots(browser);
        g_queue_free(browser->events);
        g_object_unref(browser->content_manager);
        g_free(browser);
        return NULL;
    }

    g_signal_connect(browser->web_view, "notify::uri", G_CALLBACK(verde_browser_linux_on_uri_changed), browser);
    g_signal_connect(browser->web_view, "notify::title", G_CALLBACK(verde_browser_linux_on_title_changed), browser);
    g_signal_connect(browser->web_view, "load-changed", G_CALLBACK(verde_browser_linux_on_load_changed), browser);

    gtk_window_present(GTK_WINDOW(browser->window));
    verde_browser_linux_apply_host_window(browser);
    gtk_widget_set_visible(browser->window, FALSE);
    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }

    webkit_web_view_load_uri(browser->web_view, "about:blank");
    return browser;
}

int verde_browser_linux_set_host_window(struct verde_browser_linux *browser, size_t host_window) {
    if (browser == NULL) return 0;
    browser->host_window = (unsigned long)host_window;
    verde_browser_linux_apply_host_window(browser);
    return 1;
}

int verde_browser_linux_set_device_scale(struct verde_browser_linux *browser, double scale) {
    (void)browser;
    (void)scale;
    return 1;
}

void verde_browser_linux_destroy(struct verde_browser_linux *browser) {
    if (browser == NULL) return;

    if (browser->window != NULL) {
        gtk_window_destroy(GTK_WINDOW(browser->window));
    }
    if (browser->content_manager != NULL) {
        webkit_user_content_manager_unregister_script_message_handler(browser->content_manager, "verde", NULL);
        g_object_unref(browser->content_manager);
    }
    while (!g_queue_is_empty(browser->events)) {
        struct verde_browser_linux_event *event = g_queue_pop_head(browser->events);
        if (event != NULL) {
            g_free(event->payload);
            g_free(event);
        }
    }
    if (browser->snapshot_path != NULL) {
        remove(browser->snapshot_path);
        g_free(browser->snapshot_path);
    }
    verde_browser_linux_unmap_frame_slots(browser);
    g_queue_free(browser->events);
    g_free(browser);
}

int verde_browser_linux_show(struct verde_browser_linux *browser, int width, int height, const char *url) {
    if (browser == NULL) return 0;

    const gboolean visible_helper = verde_browser_linux_visible_helper_enabled();
    if (width > 0 && height > 0) {
        (void)verde_browser_linux_apply_size(browser, width, height);
    }
    if (!browser->visible) {
        browser->visible = TRUE;
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_OPENED, NULL);
    }
    if (visible_helper) {
        gtk_window_present(GTK_WINDOW(browser->window));
        verde_browser_linux_apply_host_window(browser);
        gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));
    }
    if (url != NULL) {
        webkit_web_view_load_uri(browser->web_view, url);
    } else if (!verde_browser_linux_direct_surface_active()) {
        verde_browser_linux_request_snapshot(browser);
    }
    return 1;
}

int verde_browser_linux_hide(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (browser->visible) {
        browser->visible = FALSE;
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_CLOSED, NULL);
    }
    if (verde_browser_linux_visible_helper_enabled()) {
        gtk_widget_set_visible(browser->window, FALSE);
    }
    return 1;
}

int verde_browser_linux_set_bounds(struct verde_browser_linux *browser, int x, int y, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return 0;
    const gboolean visible_helper = verde_browser_linux_visible_helper_enabled();
    const gboolean size_changed = verde_browser_linux_apply_size(browser, width, height);
    if (visible_helper) {
        verde_browser_linux_apply_host_window(browser);
    }
    (void)x;
    (void)y;
    if (size_changed && !verde_browser_linux_direct_surface_active()) {
        verde_browser_linux_request_snapshot(browser);
    }
    return 1;
}

int verde_browser_linux_resize(struct verde_browser_linux *browser, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return 0;
    if (verde_browser_linux_apply_size(browser, width, height) && !verde_browser_linux_direct_surface_active()) {
        verde_browser_linux_request_snapshot(browser);
    }
    return 1;
}

int verde_browser_linux_navigate(struct verde_browser_linux *browser, const char *url) {
    if (browser == NULL || url == NULL) return 0;
    webkit_web_view_load_uri(browser->web_view, url);
    return 1;
}

int verde_browser_linux_eval(struct verde_browser_linux *browser, const char *js) {
    if (browser == NULL || js == NULL) return 0;
    webkit_web_view_evaluate_javascript(
        browser->web_view,
        js,
        -1,
        NULL,
        "app://verde-eval.js",
        NULL,
        verde_browser_linux_on_eval_finished,
        browser
    );
    return 1;
}

int verde_browser_linux_post_json(struct verde_browser_linux *browser, const char *json) {
    if (browser == NULL || json == NULL) return 0;

    char *script = g_strdup_printf(
        "(function(){const payload=%s;window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})()",
        json
    );
    webkit_web_view_evaluate_javascript(
        browser->web_view,
        script,
        -1,
        NULL,
        "app://verde-post-json.js",
        NULL,
        verde_browser_linux_on_post_json_finished,
        browser
    );
    g_free(script);
    return 1;
}

int verde_browser_linux_go_back(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (webkit_web_view_can_go_back(browser->web_view)) {
        webkit_web_view_go_back(browser->web_view);
    }
    return 1;
}

int verde_browser_linux_go_forward(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (webkit_web_view_can_go_forward(browser->web_view)) {
        webkit_web_view_go_forward(browser->web_view);
    }
    return 1;
}

int verde_browser_linux_reload(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    webkit_web_view_reload(browser->web_view);
    return 1;
}

int verde_browser_linux_focus(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (verde_browser_linux_visible_helper_enabled()) {
        gtk_window_present(GTK_WINDOW(browser->window));
        gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));
    }
    return 1;
}

int verde_browser_linux_blur(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (verde_browser_linux_visible_helper_enabled()) {
        gtk_window_set_focus(GTK_WINDOW(browser->window), NULL);
    }
    return 1;
}

int verde_browser_linux_poll_event(struct verde_browser_linux *browser, int *kind, char **payload) {
    if (browser == NULL || kind == NULL || payload == NULL) return 0;

    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }

    struct verde_browser_linux_event *event = g_queue_pop_head(browser->events);
    if (event == NULL) return 0;

    *kind = event->kind;
    *payload = event->payload;
    g_free(event);
    return 1;
}

int verde_browser_linux_poll_frame(struct verde_browser_linux *browser, char **path, uint64_t *sequence, int *slot, int *width, int *height, size_t *byte_len) {
    if (browser == NULL || path == NULL || sequence == NULL || slot == NULL || width == NULL || height == NULL || byte_len == NULL) return 0;

    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }

    if (!browser->snapshot_dirty || (browser->snapshot_path == NULL && browser->snapshot_ready_slot < 0)) return 0;

    *path = browser->snapshot_path != NULL ? g_strdup(browser->snapshot_path) : NULL;
    *sequence = (uint64_t)browser->snapshot_ready_sequence;
    *slot = browser->snapshot_ready_slot;
    *width = browser->snapshot_width;
    *height = browser->snapshot_height;
    *byte_len = browser->snapshot_byte_len;
    browser->snapshot_dirty = FALSE;
    return 1;
}

int verde_browser_linux_mouse_move(struct verde_browser_linux *browser, double x, double y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    char *script = g_strdup_printf(
        "(function(){const x=%f;const y=%f;const target=document.elementFromPoint(x,y);if(!target)return false;target.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));return true;})()",
        x,
        y
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    return 1;
}

int verde_browser_linux_mouse_button(struct verde_browser_linux *browser, double x, double y, unsigned int button, int down, unsigned int modifiers) {
    if (browser == NULL || button == 0) return 0;
    const char *event_name = down != 0 ? "mousedown" : "mouseup";
    const gboolean emit_click = down == 0 && button == 1;
    char *script = g_strdup_printf(
        "(function(){const x=%f;const y=%f;const button=%u;const target=document.elementFromPoint(x,y);if(!target)return false;const interactive=(target.closest&&target.closest('a[href],button,input,textarea,select,label,summary,[contenteditable=\"true\"],[tabindex]'))||target;if(interactive&&interactive.focus)interactive.focus({preventScroll:true});interactive.dispatchEvent(new MouseEvent('%s',{bubbles:true,cancelable:true,composed:true,view:window,clientX:x,clientY:y,button:button-1,buttons:button===1?1:(button===2?4:2)}));%s return true;})()",
        x,
        y,
        button,
        event_name,
        emit_click ? "interactive.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,composed:true,view:window,clientX:x,clientY:y,button:0,buttons:0}));if(typeof interactive.click==='function')interactive.click();" : ""
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    (void)modifiers;
    return 1;
}

static void verde_browser_linux_dispatch_wheel_script(struct verde_browser_linux *browser, double x, double y, double delta_x, double delta_y) {
    if (browser == NULL) return;
    char *script = g_strdup_printf(
        "(function(){const x=%f;const y=%f;const deltaX=%f;const deltaY=%f;let node=document.elementFromPoint(x,y)||document.scrollingElement||document.documentElement||document.body;function scrollable(el){if(!el||el===document.body||el===document.documentElement)return false;const style=getComputedStyle(el);const oy=style.overflowY||'';const ox=style.overflowX||'';return ((oy==='auto'||oy==='scroll'||oy==='overlay')&&el.scrollHeight>el.clientHeight+1)||((ox==='auto'||ox==='scroll'||ox==='overlay')&&el.scrollWidth>el.clientWidth+1);}while(node&&node!==document.body&&node!==document.documentElement&&!scrollable(node))node=node.parentElement;const scroller=(node&&node!==document.body&&node!==document.documentElement)?node:(document.scrollingElement||document.documentElement||document.body);if(scroller&&typeof scroller.scrollBy==='function')scroller.scrollBy({left:deltaX,top:deltaY,behavior:'instant'});else if(typeof window.scrollBy==='function')window.scrollBy(deltaX,deltaY);return true;})()",
        x,
        y,
        -delta_x * 96.0,
        -delta_y * 96.0
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
}

int verde_browser_linux_mouse_wheel(struct verde_browser_linux *browser, double x, double y, double delta_x, double delta_y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    verde_browser_linux_dispatch_wheel_script(browser, x, y, delta_x, delta_y);
    (void)modifiers;
    return 1;
}

int verde_browser_linux_key_input(struct verde_browser_linux *browser, unsigned int key_code, int down, unsigned int modifiers) {
    if (browser == NULL || key_code == 0) return 0;
    const char *event_name = down != 0 ? "keydown" : "keyup";
    const gboolean shift = (modifiers & VERDE_BROWSER_LINUX_MOD_SHIFT) != 0;
    char *script = g_strdup_printf(
        "(function(){const code=%u;const eventName='%s';const shift=%s;const el=document.activeElement||document.body;let key='';if(code===0xff0d)key='Enter';else if(code===0xff08)key='Backspace';else if(code===0xff09)key='Tab';else if(code===0xff1b)key='Escape';else if(code===0xffff)key='Delete';else if(code===0xff50)key='Home';else if(code===0xff51)key='ArrowLeft';else if(code===0xff52)key='ArrowUp';else if(code===0xff53)key='ArrowRight';else if(code===0xff54)key='ArrowDown';else if(code===0xff57)key='End';else key=String.fromCharCode(code);const evt=new KeyboardEvent(eventName,{key,bubbles:true,cancelable:true,shiftKey:shift});el.dispatchEvent(evt);if(eventName!=='keydown'||evt.defaultPrevented)return true;if((el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement)&&(key==='ArrowLeft'||key==='ArrowRight'||key==='ArrowUp'||key==='ArrowDown'||key==='Home'||key==='End')){const len=el.value.length;const start=el.selectionStart??len;const end=el.selectionEnd??len;let next=(key==='Home'||key==='ArrowUp')?0:(key==='End'||key==='ArrowDown')?len:key==='ArrowLeft'?Math.max(0,start-1):Math.min(len,end+1);if(shift){el.setSelectionRange(Math.min(start,next),Math.max(start,next));}else{el.setSelectionRange(next,next);}return true;}if((el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement)&&key==='Backspace'){const start=el.selectionStart??el.value.length;const end=el.selectionEnd??el.value.length;if(start===end&&start>0){el.value=el.value.slice(0,start-1)+el.value.slice(end);if(el.setSelectionRange)el.setSelectionRange(start-1,start-1);}else{el.value=el.value.slice(0,start)+el.value.slice(end);if(el.setSelectionRange)el.setSelectionRange(start,start);}el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'deleteContentBackward'}));return true;}if(key==='Enter'){if(el instanceof HTMLTextAreaElement){const start=el.selectionStart??el.value.length;const end=el.selectionEnd??el.value.length;el.value=el.value.slice(0,start)+'\\n'+el.value.slice(end);if(el.setSelectionRange)el.setSelectionRange(start+1,start+1);el.dispatchEvent(new InputEvent('input',{bubbles:true,data:'\\n',inputType:'insertLineBreak'}));return true;}if(el instanceof HTMLInputElement&&el.form&&typeof el.form.requestSubmit==='function'){el.form.requestSubmit();return true;}}return true;})()",
        key_code,
        event_name,
        shift ? "true" : "false"
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    (void)modifiers;
    return 1;
}

int verde_browser_linux_text_input(struct verde_browser_linux *browser, const char *text, unsigned int modifiers) {
    if (browser == NULL || text == NULL || text[0] == '\0') return 0;
    char *escaped = g_strescape(text, NULL);
    char *script = g_strdup_printf(
        "(function(){const text='%s';const el=document.activeElement;if(!el)return false;if(el.isContentEditable){document.execCommand('insertText',false,text);return true;}if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){const start=el.selectionStart??el.value.length;const end=el.selectionEnd??el.value.length;const before=el.value.slice(0,start);const after=el.value.slice(end);el.value=before+text+after;const next=start+text.length;if(el.setSelectionRange)el.setSelectionRange(next,next);el.dispatchEvent(new InputEvent('input',{bubbles:true,data:text,inputType:'insertText'}));return true;}el.dispatchEvent(new KeyboardEvent('keypress',{key:text,bubbles:true}));return true;})()",
        escaped
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    g_free(escaped);
    return 1;
}

void verde_browser_linux_free_string(char *payload) {
    g_free(payload);
}
