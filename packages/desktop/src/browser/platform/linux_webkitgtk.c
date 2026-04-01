#include <cairo.h>
#include <gtk/gtk.h>
#include <jsc/jsc.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <webkit2/webkit2.h>

enum verde_browser_linux_event_kind {
    VERDE_BROWSER_LINUX_EVENT_OPENED = 1,
    VERDE_BROWSER_LINUX_EVENT_CLOSED = 2,
    VERDE_BROWSER_LINUX_EVENT_NAVIGATED = 3,
    VERDE_BROWSER_LINUX_EVENT_JS_MESSAGE = 4,
    VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT = 5,
    VERDE_BROWSER_LINUX_EVENT_FAILED = 6,
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
    gboolean snapshot_dirty;
    gchar *snapshot_path;
    gint snapshot_width;
    gint snapshot_height;
    gsize snapshot_byte_len;
    guint modifier_state;
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

static char *verde_browser_linux_value_to_json_or_string(JSCValue *value) {
    char *json = jsc_value_to_json(value, 0);
    if (json != NULL) return json;
    return jsc_value_to_string(value);
}

static void verde_browser_linux_request_snapshot(struct verde_browser_linux *browser);

static void verde_browser_linux_on_uri_changed(GObject *object, GParamSpec *pspec, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    const char *uri = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(object));
    (void)pspec;
    if (uri == NULL) return;
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_NAVIGATED, uri);
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

    cairo_surface_flush(surface);
    const gint width = cairo_image_surface_get_width(surface);
    const gint height = cairo_image_surface_get_height(surface);
    const gint stride = cairo_image_surface_get_stride(surface);
    unsigned char *data = cairo_image_surface_get_data(surface);

    if (width <= 0 || height <= 0 || data == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Snapshot surface had no pixel data.");
        cairo_surface_destroy(surface);
        return;
    }

    const gsize contiguous_len = (gsize)width * (gsize)height * 4;
    FILE *file = fopen(browser->snapshot_path, "wb");
    if (file == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to open Linux snapshot file.");
        cairo_surface_destroy(surface);
        return;
    }

    for (gint row = 0; row < height; row += 1) {
        const unsigned char *row_ptr = data + (gsize)row * (gsize)stride;
        if (fwrite(row_ptr, 1, (gsize)width * 4, file) != (gsize)width * 4) {
            fclose(file);
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to write Linux snapshot pixels.");
            cairo_surface_destroy(surface);
            return;
        }
    }
    fclose(file);

    browser->snapshot_width = width;
    browser->snapshot_height = height;
    browser->snapshot_byte_len = contiguous_len;
    browser->snapshot_dirty = TRUE;
    cairo_surface_destroy(surface);
}

static void verde_browser_linux_request_snapshot(struct verde_browser_linux *browser) {
    if (browser == NULL || browser->snapshot_pending) return;
    browser->snapshot_pending = TRUE;
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
    gtk_main_do_event(event);
    const gboolean handled = gtk_widget_event(widget, event);
    gdk_event_free(event);
    return handled;
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
        verde_browser_linux_request_snapshot(browser);
        return;
    }

    char *payload = verde_browser_linux_value_to_json_or_string(value);
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT, payload);
    g_free(payload);
    g_object_unref(value);
    verde_browser_linux_request_snapshot(browser);
}

struct verde_browser_linux *verde_browser_linux_create(void) {
    if (!gtk_init_check(0, NULL)) {
        return NULL;
    }

    struct verde_browser_linux *browser = g_new0(struct verde_browser_linux, 1);
    browser->events = g_queue_new();
    browser->snapshot_path = g_strdup_printf("/tmp/verde-browser-linux-frame-%d.rgba", getpid());
    browser->content_manager = webkit_user_content_manager_new();
    if (!webkit_user_content_manager_register_script_message_handler(browser->content_manager, "verde")) {
        g_free(browser->snapshot_path);
        g_queue_free(browser->events);
        g_object_unref(browser->content_manager);
        g_free(browser);
        return NULL;
    }

    browser->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(browser->window), 1280, 720);
    gtk_window_set_title(GTK_WINDOW(browser->window), "Verde Browser Surface");
    gtk_window_set_decorated(GTK_WINDOW(browser->window), FALSE);
    gtk_window_set_skip_taskbar_hint(GTK_WINDOW(browser->window), TRUE);
    gtk_window_set_skip_pager_hint(GTK_WINDOW(browser->window), TRUE);

    browser->web_view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_user_content_manager(browser->content_manager));
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
    g_signal_connect(browser->web_view, "load-changed", G_CALLBACK(verde_browser_linux_on_load_changed), browser);
    g_signal_connect(browser->content_manager, "script-message-received::verde", G_CALLBACK(verde_browser_linux_on_script_message), browser);

    gtk_widget_show_all(browser->window);
    gtk_widget_hide(browser->window);
    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }

    webkit_web_view_load_uri(browser->web_view, "about:blank");
    return browser;
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
    g_queue_free(browser->events);
    g_free(browser);
}

int verde_browser_linux_show(struct verde_browser_linux *browser, int width, int height, const char *url) {
    if (browser == NULL) return 0;

    if (width > 0 && height > 0) {
        gtk_window_resize(GTK_WINDOW(browser->window), width, height);
        gtk_widget_set_size_request(GTK_WIDGET(browser->web_view), width, height);
    }
    if (!browser->visible) {
        browser->visible = TRUE;
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_OPENED, NULL);
    }
    gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));
    if (url != NULL) {
        webkit_web_view_load_uri(browser->web_view, url);
    } else {
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
    return 1;
}

int verde_browser_linux_resize(struct verde_browser_linux *browser, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return 0;
    gtk_window_resize(GTK_WINDOW(browser->window), width, height);
    gtk_widget_set_size_request(GTK_WIDGET(browser->web_view), width, height);
    verde_browser_linux_request_snapshot(browser);
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
        "(function(){const payload=%s;window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));return JSON.stringify(payload);})()",
        json
    );
    webkit_web_view_evaluate_javascript(
        browser->web_view,
        script,
        -1,
        NULL,
        "app://verde-post-json.js",
        NULL,
        verde_browser_linux_on_eval_finished,
        browser
    );
    g_free(script);
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

int verde_browser_linux_poll_frame(struct verde_browser_linux *browser, char **path, int *width, int *height, size_t *byte_len) {
    if (browser == NULL || path == NULL || width == NULL || height == NULL || byte_len == NULL) return 0;

    while (g_main_context_pending(NULL)) {
        g_main_context_iteration(NULL, FALSE);
    }

    if (!browser->snapshot_dirty || browser->snapshot_path == NULL) return 0;

    *path = g_strdup(browser->snapshot_path);
    *width = browser->snapshot_width;
    *height = browser->snapshot_height;
    *byte_len = browser->snapshot_byte_len;
    browser->snapshot_dirty = FALSE;
    return 1;
}

int verde_browser_linux_mouse_move(struct verde_browser_linux *browser, double x, double y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return 0;

    browser->modifier_state = verde_browser_linux_gdk_modifiers(modifiers);
    GdkEvent *event = gdk_event_new(GDK_MOTION_NOTIFY);
    event->motion.window = g_object_ref(target);
    event->motion.send_event = TRUE;
    event->motion.time = GDK_CURRENT_TIME;
    event->motion.x = x;
    event->motion.y = y;
    event->motion.x_root = x;
    event->motion.y_root = y;
    event->motion.state = browser->modifier_state;
    verde_browser_linux_attach_device(browser, event, FALSE);
    return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 1;
}

int verde_browser_linux_mouse_button(struct verde_browser_linux *browser, double x, double y, unsigned int button, int down, unsigned int modifiers) {
    if (browser == NULL || button == 0) return 0;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return 0;

    browser->modifier_state = verde_browser_linux_gdk_modifiers(modifiers);
    if (down != 0) {
        if (button == 1) browser->modifier_state |= GDK_BUTTON1_MASK;
        if (button == 2) browser->modifier_state |= GDK_BUTTON2_MASK;
        if (button == 3) browser->modifier_state |= GDK_BUTTON3_MASK;
        gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));
    }

    GdkEvent *event = gdk_event_new(down != 0 ? GDK_BUTTON_PRESS : GDK_BUTTON_RELEASE);
    event->button.window = g_object_ref(target);
    event->button.send_event = TRUE;
    event->button.time = GDK_CURRENT_TIME;
    event->button.x = x;
    event->button.y = y;
    event->button.x_root = x;
    event->button.y_root = y;
    event->button.state = browser->modifier_state;
    event->button.button = button;
    verde_browser_linux_attach_device(browser, event, FALSE);
    const int result = verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 1;

    if (down == 0) {
        if (button == 1) browser->modifier_state &= ~GDK_BUTTON1_MASK;
        if (button == 2) browser->modifier_state &= ~GDK_BUTTON2_MASK;
        if (button == 3) browser->modifier_state &= ~GDK_BUTTON3_MASK;
    }
    verde_browser_linux_request_snapshot(browser);
    return result;
}

int verde_browser_linux_mouse_wheel(struct verde_browser_linux *browser, double x, double y, double delta_x, double delta_y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return 0;

    browser->modifier_state = verde_browser_linux_gdk_modifiers(modifiers);
    GdkEvent *event = gdk_event_new(GDK_SCROLL);
    event->scroll.window = g_object_ref(target);
    event->scroll.send_event = TRUE;
    event->scroll.time = GDK_CURRENT_TIME;
    event->scroll.x = x;
    event->scroll.y = y;
    event->scroll.x_root = x;
    event->scroll.y_root = y;
    event->scroll.state = browser->modifier_state;
    event->scroll.direction = GDK_SCROLL_SMOOTH;
    event->scroll.delta_x = delta_x;
    event->scroll.delta_y = delta_y;
    verde_browser_linux_attach_device(browser, event, FALSE);
    verde_browser_linux_request_snapshot(browser);
    return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 1;
}

int verde_browser_linux_key_input(struct verde_browser_linux *browser, unsigned int key_code, int down, unsigned int modifiers) {
    if (browser == NULL || key_code == 0) return 0;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return 0;

    browser->modifier_state = verde_browser_linux_gdk_modifiers(modifiers);
    gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));

    GdkEvent *event = gdk_event_new(down != 0 ? GDK_KEY_PRESS : GDK_KEY_RELEASE);
    event->key.window = g_object_ref(target);
    event->key.send_event = TRUE;
    event->key.time = GDK_CURRENT_TIME;
    event->key.state = browser->modifier_state;
    event->key.keyval = verde_browser_linux_keyval_from_code(key_code);
    event->key.length = 0;
    event->key.string = NULL;
    event->key.hardware_keycode = 0;
    event->key.group = 0;
    event->key.is_modifier = FALSE;
    verde_browser_linux_attach_device(browser, event, TRUE);
    verde_browser_linux_request_snapshot(browser);
    return verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event) ? 1 : 1;
}

int verde_browser_linux_text_input(struct verde_browser_linux *browser, const char *text, unsigned int modifiers) {
    if (browser == NULL || text == NULL || text[0] == '\0') return 0;
    GdkWindow *target = verde_browser_linux_target_window(browser);
    if (target == NULL) return 0;

    browser->modifier_state = verde_browser_linux_gdk_modifiers(modifiers);
    gtk_widget_grab_focus(GTK_WIDGET(browser->web_view));

    const char *cursor = text;
    while (*cursor != '\0') {
        gunichar codepoint = g_utf8_get_char(cursor);
        const gchar *next = g_utf8_next_char(cursor);
        const gint byte_len = (gint)(next - cursor);
        GdkEvent *event = gdk_event_new(GDK_KEY_PRESS);
        event->key.window = g_object_ref(target);
        event->key.send_event = TRUE;
        event->key.time = GDK_CURRENT_TIME;
        event->key.state = browser->modifier_state;
        event->key.keyval = gdk_unicode_to_keyval(codepoint);
        event->key.length = byte_len;
        event->key.string = g_strndup(cursor, byte_len);
        event->key.hardware_keycode = 0;
        event->key.group = 0;
        event->key.is_modifier = FALSE;
        verde_browser_linux_attach_device(browser, event, TRUE);
        verde_browser_linux_dispatch_event(GTK_WIDGET(browser->web_view), event);
        cursor = next;
    }
    verde_browser_linux_request_snapshot(browser);
    return 1;
}

void verde_browser_linux_free_string(char *payload) {
    g_free(payload);
}
