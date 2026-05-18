#include <cairo.h>
#include <gdk/gdkx.h>
#include <gtk/gtk.h>
#include <jsc/jsc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <webkit2/webkit2.h>
#include <X11/Xlib.h>

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
    gtk_window_resize(GTK_WINDOW(browser->window), width, height);
    if (!verde_browser_linux_visible_helper_enabled()) {
        gtk_widget_set_size_request(GTK_WIDGET(browser->web_view), width, height);
        GtkAllocation allocation = { 0, 0, width, height };
        gtk_widget_size_allocate(GTK_WIDGET(browser->web_view), &allocation);
        gtk_widget_size_allocate(GTK_WIDGET(browser->window), &allocation);
    }
    return TRUE;
}

static gboolean verde_browser_linux_visible_helper_enabled(void) {
    if (verde_browser_linux_wayland_diagnostic_helper_enabled()) return TRUE;
    const char *value = getenv("VERDE_BROWSER_LINUX_SHOW_HELPER");
    const char *unsafe_wayland = getenv("VERDE_BROWSER_LINUX_UNSAFE_WAYLAND_HELPER");
    const gboolean allow_wayland_helper = unsafe_wayland != NULL && strcmp(unsafe_wayland, "1") == 0;
    const char *session_type = getenv("XDG_SESSION_TYPE");
    const char *gdk_backend = getenv("GDK_BACKEND");
    const gboolean wayland_session = session_type != NULL && strcmp(session_type, "wayland") == 0;
    const gboolean wayland_backend = gdk_backend != NULL && strstr(gdk_backend, "wayland") != NULL;

    if (value != NULL) {
        if (strcmp(value, "1") == 0) return (!wayland_session && !wayland_backend) || allow_wayland_helper;
        if (strcmp(value, "0") == 0) return FALSE;
    }

    if (session_type != NULL && strcmp(session_type, "x11") == 0) return TRUE;
    if (session_type != NULL && strcmp(session_type, "wayland") == 0) return FALSE;

    return gdk_backend != NULL && strstr(gdk_backend, "x11") != NULL && strstr(gdk_backend, "wayland") == NULL;
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
    if (browser == NULL || browser->host_window == 0 || browser->window == NULL) return;
    GdkWindow *gdk_window = gtk_widget_get_window(browser->window);
    if (gdk_window == NULL) return;
    GdkDisplay *display = gdk_window_get_display(gdk_window);
    if (display == NULL || !GDK_IS_X11_DISPLAY(display) || !GDK_IS_X11_WINDOW(gdk_window)) return;

    Display *xdisplay = gdk_x11_display_get_xdisplay(display);
    Window child = gdk_x11_window_get_xid(gdk_window);
    Window parent = (Window)browser->host_window;
    if (xdisplay == NULL || child == 0 || parent == 0) return;

    XSetTransientForHint(xdisplay, child, parent);
    XFlush(xdisplay);
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

static void verde_browser_linux_on_script_message(WebKitUserContentManager *manager, WebKitJavascriptResult *js_result, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    JSCValue *value = webkit_javascript_result_get_js_value(js_result);
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
    cairo_surface_t *surface = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(object), result, &error);
    browser->snapshot_pending = FALSE;

    if (error != NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
        g_error_free(error);
        return;
    }
    if (surface == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot surface was null.");
        return;
    }
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot surface was invalid.");
        cairo_surface_destroy(surface);
        return;
    }

    cairo_surface_t *output_surface = surface;
    const gint source_width = cairo_image_surface_get_width(surface);
    const gint source_height = cairo_image_surface_get_height(surface);
    const gint target_width = browser->target_width > 0 ? browser->target_width : source_width;
    const gint target_height = browser->target_height > 0 ? browser->target_height : source_height;
    const gint64 scale_started_us = g_get_monotonic_time();

    if (source_width > 0 && source_height > 0 && (source_width != target_width || source_height != target_height)) {
        output_surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, target_width, target_height);
        if (cairo_surface_status(output_surface) != CAIRO_STATUS_SUCCESS) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to allocate scaled Linux snapshot surface.");
            cairo_surface_destroy(surface);
            cairo_surface_destroy(output_surface);
            return;
        }

        cairo_t *cr = cairo_create(output_surface);
        cairo_scale(cr, (double)target_width / (double)source_width, (double)target_height / (double)source_height);
        cairo_set_source_surface(cr, surface, 0, 0);
        cairo_pattern_t *pattern = cairo_get_source(cr);
        cairo_pattern_set_filter(pattern, CAIRO_FILTER_BEST);
        cairo_paint(cr);
        cairo_destroy(cr);
        cairo_surface_flush(output_surface);
    } else {
        cairo_surface_flush(output_surface);
    }
    const gint64 scale_finished_us = g_get_monotonic_time();

    const gint width = cairo_image_surface_get_width(output_surface);
    const gint height = cairo_image_surface_get_height(output_surface);
    const gint stride = cairo_image_surface_get_stride(output_surface);
    unsigned char *data = cairo_image_surface_get_data(output_surface);

    if (width <= 0 || height <= 0 || data == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot surface had no pixel data.");
        if (output_surface != surface) cairo_surface_destroy(output_surface);
        cairo_surface_destroy(surface);
        return;
    }

    const gsize contiguous_len = (gsize)width * (gsize)height * 4;
    gchar *snapshot_path = NULL;
    gint snapshot_slot = -1;
    const gint64 write_started_us = g_get_monotonic_time();

    if (verde_browser_linux_shared_frames_enabled(browser) && contiguous_len <= VERDE_BROWSER_LINUX_FRAME_BYTES_MAX) {
        snapshot_slot = browser->frame_next_slot;
        unsigned char *slot = browser->frame_slots[snapshot_slot];
        for (gint row = 0; row < height; row += 1) {
            unsigned char *row_ptr = data + (gsize)row * (gsize)stride;
            unsigned char *target_row = slot + (gsize)row * (gsize)width * 4;
            for (gint x = 0; x < width; x += 1) {
                row_ptr[(gsize)x * 4 + 3] = 255;
            }
            memcpy(target_row, row_ptr, (gsize)width * 4);
        }
        browser->frame_next_slot = (guint8)((browser->frame_next_slot + 1) % VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT);
    } else {
        snapshot_path = g_strdup_printf("/tmp/verde-browser-linux-frame-%d-%" G_GUINT64_FORMAT ".rgba", getpid(), sequence);
        FILE *file = fopen(snapshot_path, "wb");
        if (file == NULL) {
            g_free(snapshot_path);
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to open Linux snapshot file.");
            if (output_surface != surface) cairo_surface_destroy(output_surface);
            cairo_surface_destroy(surface);
            return;
        }

        for (gint row = 0; row < height; row += 1) {
            unsigned char *row_ptr = data + (gsize)row * (gsize)stride;
            for (gint x = 0; x < width; x += 1) {
                row_ptr[(gsize)x * 4 + 3] = 255;
            }
            if (fwrite(row_ptr, 1, (gsize)width * 4, file) != (gsize)width * 4) {
                fclose(file);
                remove(snapshot_path);
                g_free(snapshot_path);
                verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to write Linux snapshot pixels.");
                if (output_surface != surface) cairo_surface_destroy(output_surface);
                cairo_surface_destroy(surface);
                return;
            }
        }
        fclose(file);
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
            (output_surface != surface) ? 1 : 0,
            snapshot_slot,
            browser->snapshot_requested_while_pending ? 1 : 0
        );
        fflush(stderr);
    }
    if (output_surface != surface) cairo_surface_destroy(output_surface);
    cairo_surface_destroy(surface);
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

static guint verde_browser_linux_gdk_modifiers(guint modifiers) {
    guint state = 0;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_SHIFT) != 0) state |= GDK_SHIFT_MASK;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_CTRL) != 0) state |= GDK_CONTROL_MASK;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_ALT) != 0) state |= GDK_MOD1_MASK;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_SUPER) != 0) state |= GDK_SUPER_MASK;
    return state;
}

static GdkWindow *verde_browser_linux_target_window(struct verde_browser_linux *browser) {
    if (browser == NULL) return NULL;
    GdkWindow *target = gtk_widget_get_window(GTK_WIDGET(browser->web_view));
    if (target != NULL) return target;
    return gtk_widget_get_window(browser->window);
}

static void verde_browser_linux_attach_device(struct verde_browser_linux *browser, GdkEvent *event, gboolean keyboard) {
    if (browser == NULL || event == NULL) return;

    GdkDisplay *display = gtk_widget_get_display(browser->window);
    if (display == NULL) return;

    GdkSeat *seat = gdk_display_get_default_seat(display);
    if (seat == NULL) return;

    GdkDevice *device = keyboard ? gdk_seat_get_keyboard(seat) : gdk_seat_get_pointer(seat);
    if (device == NULL) return;
    gdk_event_set_device(event, device);
}

static gboolean verde_browser_linux_dispatch_event(GtkWidget *widget, GdkEvent *event) {
    if (widget == NULL || event == NULL) return FALSE;
    const gboolean handled = gtk_widget_event(widget, event);
    gdk_event_free(event);
    return handled;
}

static gboolean verde_browser_linux_dispatch_scroll_event(struct verde_browser_linux *browser, double x, double y, double delta_x, double delta_y, unsigned int modifiers) {
    if (browser == NULL) return FALSE;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return FALSE;
    GdkEvent *event = gdk_event_new(GDK_SCROLL);
    event->scroll.window = g_object_ref(target);
    event->scroll.send_event = TRUE;
    event->scroll.time = GDK_CURRENT_TIME;
    event->scroll.x = x;
    event->scroll.y = y;
    event->scroll.x_root = 0;
    event->scroll.y_root = 0;
    event->scroll.state = verde_browser_linux_gdk_modifiers(modifiers);
    event->scroll.direction = GDK_SCROLL_SMOOTH;
    event->scroll.delta_x = -delta_x;
    event->scroll.delta_y = -delta_y;
    verde_browser_linux_attach_device(browser, event, FALSE);
    return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event);
}

static guint verde_browser_linux_keyval_from_code(guint key_code) {
    switch (key_code) {
        case 0xff08:
        case 0xff09:
        case 0xff0d:
        case 0xff1b:
        case 0xffff:
        case 0xff50:
        case 0xff51:
        case 0xff52:
        case 0xff53:
        case 0xff54:
        case 0xff55:
        case 0xff56:
        case 0xff57:
            return key_code;
        default:
            return key_code;
    }
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
    if (!gtk_init_check(0, NULL)) {
        return NULL;
    }

    struct verde_browser_linux *browser = g_new0(struct verde_browser_linux, 1);
    browser->events = g_queue_new();
    browser->target_width = 1280;
    browser->target_height = 720;
    browser->snapshot_ready_slot = -1;
    verde_browser_linux_map_frame_slots(browser);
    browser->content_manager = webkit_user_content_manager_new();
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
    if (!webkit_user_content_manager_register_script_message_handler(browser->content_manager, "verde")) {
        g_free(browser->snapshot_path);
        verde_browser_linux_unmap_frame_slots(browser);
        g_queue_free(browser->events);
        g_object_unref(browser->content_manager);
        g_free(browser);
        return NULL;
    }

    const gboolean visible_helper = verde_browser_linux_visible_helper_enabled();
    browser->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(browser->window), visible_helper ? 1 : 1280, visible_helper ? 1 : 720);
    gtk_window_set_title(GTK_WINDOW(browser->window), "Verde Browser Surface");
    gtk_window_set_decorated(GTK_WINDOW(browser->window), FALSE);
    gtk_window_set_position(GTK_WINDOW(browser->window), GTK_WIN_POS_NONE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(browser->window), TRUE);
    gtk_window_set_skip_pager_hint(GTK_WINDOW(browser->window), TRUE);
    if (visible_helper) {
        gtk_window_set_accept_focus(GTK_WINDOW(browser->window), TRUE);
        gtk_window_set_focus_on_map(GTK_WINDOW(browser->window), TRUE);
        gtk_window_set_type_hint(GTK_WINDOW(browser->window), GDK_WINDOW_TYPE_HINT_UTILITY);
    }

    browser->web_view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_user_content_manager(browser->content_manager));
    GdkRGBA browser_background = { 0.0, 0.0, 0.0, 1.0 };
    webkit_web_view_set_background_color(browser->web_view, &browser_background);
    gtk_container_add(GTK_CONTAINER(browser->window), GTK_WIDGET(browser->web_view));

    WebKitSettings *settings = webkit_web_view_get_settings(browser->web_view);
    webkit_settings_set_enable_developer_extras(settings, TRUE);
    gtk_widget_add_events(
        GTK_WIDGET(browser->web_view),
        GDK_BUTTON_PRESS_MASK |
        GDK_BUTTON_RELEASE_MASK |
        GDK_POINTER_MOTION_MASK |
        GDK_SCROLL_MASK |
        GDK_SMOOTH_SCROLL_MASK |
        GDK_KEY_PRESS_MASK |
        GDK_KEY_RELEASE_MASK
    );
    gtk_widget_set_can_focus(GTK_WIDGET(browser->web_view), TRUE);

    g_signal_connect(browser->web_view, "notify::uri", G_CALLBACK(verde_browser_linux_on_uri_changed), browser);
    g_signal_connect(browser->web_view, "notify::title", G_CALLBACK(verde_browser_linux_on_title_changed), browser);
    g_signal_connect(browser->web_view, "load-changed", G_CALLBACK(verde_browser_linux_on_load_changed), browser);
    g_signal_connect(browser->content_manager, "script-message-received::verde", G_CALLBACK(verde_browser_linux_on_script_message), browser);

    gtk_widget_show_all(browser->window);
    verde_browser_linux_apply_host_window(browser);
    gtk_widget_hide(browser->window);
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

void verde_browser_linux_destroy(struct verde_browser_linux *browser) {
    if (browser == NULL) return;

    if (browser->window != NULL) {
        gtk_widget_destroy(browser->window);
    }
    if (browser->content_manager != NULL) {
        webkit_user_content_manager_unregister_script_message_handler(browser->content_manager, "verde");
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
        gtk_widget_show_all(browser->window);
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
        gtk_widget_hide(browser->window);
    }
    return 1;
}

int verde_browser_linux_set_bounds(struct verde_browser_linux *browser, int x, int y, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return 0;
    const gboolean visible_helper = verde_browser_linux_visible_helper_enabled();
    const gboolean size_changed = verde_browser_linux_apply_size(browser, width, height);
    if (visible_helper) {
        gtk_window_move(GTK_WINDOW(browser->window), x, y);
        verde_browser_linux_apply_host_window(browser);
    }
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
    if (verde_browser_linux_visible_helper_enabled()) {
        GdkWindow *target = verde_browser_linux_target_window(browser);
        if (target == NULL) return 0;
        GdkEvent *event = gdk_event_new(GDK_MOTION_NOTIFY);
        event->motion.window = g_object_ref(target);
        event->motion.send_event = TRUE;
        event->motion.time = GDK_CURRENT_TIME;
        event->motion.x = x;
        event->motion.y = y;
        event->motion.x_root = 0;
        event->motion.y_root = 0;
        event->motion.state = verde_browser_linux_gdk_modifiers(modifiers);
        event->motion.is_hint = FALSE;
        verde_browser_linux_attach_device(browser, event, FALSE);
        return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 0;
    }
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
    if (verde_browser_linux_visible_helper_enabled()) {
        GdkWindow *target = verde_browser_linux_target_window(browser);
        if (target == NULL) return 0;
        GdkEvent *event = gdk_event_new(down != 0 ? GDK_BUTTON_PRESS : GDK_BUTTON_RELEASE);
        event->button.window = g_object_ref(target);
        event->button.send_event = TRUE;
        event->button.time = GDK_CURRENT_TIME;
        event->button.x = x;
        event->button.y = y;
        event->button.x_root = 0;
        event->button.y_root = 0;
        event->button.axes = NULL;
        event->button.state = verde_browser_linux_gdk_modifiers(modifiers);
        event->button.button = button;
        verde_browser_linux_attach_device(browser, event, FALSE);
        gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));
        return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 0;
    }
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
    if (verde_browser_linux_visible_helper_enabled()) {
        return verde_browser_linux_dispatch_scroll_event(browser, x, y, delta_x, delta_y, modifiers) ? 1 : 0;
    }
    verde_browser_linux_dispatch_wheel_script(browser, x, y, delta_x, delta_y);
    (void)modifiers;
    return 1;
}

int verde_browser_linux_key_input(struct verde_browser_linux *browser, unsigned int key_code, int down, unsigned int modifiers) {
    if (browser == NULL || key_code == 0) return 0;
    if (verde_browser_linux_visible_helper_enabled()) {
        GdkWindow *target = verde_browser_linux_target_window(browser);
        if (target == NULL) return 0;
        GdkEvent *event = gdk_event_new(down != 0 ? GDK_KEY_PRESS : GDK_KEY_RELEASE);
        const guint keyval = verde_browser_linux_keyval_from_code(key_code);
        event->key.window = g_object_ref(target);
        event->key.send_event = TRUE;
        event->key.time = GDK_CURRENT_TIME;
        event->key.state = verde_browser_linux_gdk_modifiers(modifiers);
        event->key.keyval = keyval;
        event->key.length = 0;
        event->key.string = NULL;
        event->key.hardware_keycode = 0;
        event->key.group = 0;
        event->key.is_modifier = FALSE;
        verde_browser_linux_attach_device(browser, event, TRUE);
        return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 0;
    }
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
