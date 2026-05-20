#define GL_GLEXT_PROTOTYPES

#include <EGL/egl.h>
#include <gio/gio.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <glib-object.h>
#include <glib.h>
#include <jsc/jsc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wpe/fdo.h>
#include <wpe/fdo-egl.h>
#include <wpe/webkit.h>

#define VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT 3
#define VERDE_BROWSER_LINUX_FRAME_BYTES_MAX (4096u * 2160u * 4u)
#define VERDE_BROWSER_LINUX_ACTIVE_FRAME_MIN_INTERVAL_US 16666
#define VERDE_BROWSER_LINUX_IDLE_FRAME_MIN_INTERVAL_US 100000
#define VERDE_BROWSER_LINUX_ACTIVE_AFTER_INPUT_US 400000
#define VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US 2000000
#define VERDE_BROWSER_LINUX_CONTEXT_MENU_ITEM_MAX 96

#if WEBKIT_CHECK_VERSION(2, 52, 0)
#define VERDE_BROWSER_LINUX_HAS_CONTEXT_MENU_DETAILS 1
#else
#define VERDE_BROWSER_LINUX_HAS_CONTEXT_MENU_DETAILS 0
#endif

enum verde_browser_linux_event_kind {
    VERDE_BROWSER_LINUX_EVENT_OPENED = 1,
    VERDE_BROWSER_LINUX_EVENT_CLOSED = 2,
    VERDE_BROWSER_LINUX_EVENT_NAVIGATED = 3,
    VERDE_BROWSER_LINUX_EVENT_TITLE_CHANGED = 4,
    VERDE_BROWSER_LINUX_EVENT_DOCUMENT_LOADED = 5,
    VERDE_BROWSER_LINUX_EVENT_JS_MESSAGE = 6,
    VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT = 7,
    VERDE_BROWSER_LINUX_EVENT_FAILED = 8,
    VERDE_BROWSER_LINUX_EVENT_CONTEXT_MENU = 9,
    VERDE_BROWSER_LINUX_EVENT_CONTEXT_MENU_DISMISSED = 10,
};

enum verde_browser_linux_modifier_bits {
    VERDE_BROWSER_LINUX_MOD_SHIFT = 1 << 0,
    VERDE_BROWSER_LINUX_MOD_CTRL = 1 << 1,
    VERDE_BROWSER_LINUX_MOD_ALT = 1 << 2,
    VERDE_BROWSER_LINUX_MOD_SUPER = 1 << 3,
};

struct verde_browser_linux_event {
    int kind;
    char *payload;
};

struct verde_browser_linux_context_menu_item {
    char *label;
    WebKitContextMenuAction stock_action;
    GAction *action;
    GVariant *target;
    gboolean enabled;
    gboolean separator;
    gboolean submenu;
};

struct verde_browser_linux {
    struct wpe_view_backend_exportable_fdo *exportable;
    struct wpe_view_backend_exportable_fdo_egl_client export_client;
    struct wpe_view_backend *view_backend;
    WebKitWebViewBackend *webkit_backend;
    WebKitWebView *web_view;
    WebKitUserContentManager *content_manager;
    WebKitContextMenu *context_menu;
    struct verde_browser_linux_context_menu_item context_items[VERDE_BROWSER_LINUX_CONTEXT_MENU_ITEM_MAX];
    guint context_item_count;
    GQueue *events;

    EGLDisplay egl_display;
    EGLContext egl_context;
    EGLSurface egl_surface;
    GLuint texture;
    GLuint framebuffer;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC gl_egl_image_target_texture_2d;
    unsigned char *rgba_scratch;
    size_t rgba_scratch_len;

    unsigned char *frame_slots[VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT];
    gboolean frame_slots_ready[VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT];
    guint8 frame_next_slot;
    guint64 frame_next_sequence;
    guint64 frame_ready_sequence;
    gint frame_ready_slot;
    gint frame_width;
    gint frame_height;
    gsize frame_byte_len;
    gboolean frame_dirty;
    gboolean frame_slots_failure_reported;
    gboolean frame_import_failure_reported;
    gint64 last_frame_published_us;
    gint64 active_until_us;
    guint frame_complete_timer_id;

    gboolean visible;
    gint target_width;
    gint target_height;
    gdouble device_scale;
    guint pointer_modifiers;
};

int verde_browser_linux_set_bounds(struct verde_browser_linux *browser, int x, int y, int width, int height);

static gboolean verde_browser_linux_frame_log_enabled(void);

static void verde_browser_linux_mark_active_for(struct verde_browser_linux *browser, gint64 duration_us) {
    if (browser == NULL) return;
    const gint64 active_until_us = g_get_monotonic_time() + duration_us;
    if (active_until_us > browser->active_until_us) browser->active_until_us = active_until_us;
}

static void verde_browser_linux_mark_active(struct verde_browser_linux *browser) {
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_INPUT_US);
}

static gint64 verde_browser_linux_frame_min_interval_us(struct verde_browser_linux *browser, gint64 now_us) {
    if (browser != NULL && now_us <= browser->active_until_us) return VERDE_BROWSER_LINUX_ACTIVE_FRAME_MIN_INTERVAL_US;
    return VERDE_BROWSER_LINUX_IDLE_FRAME_MIN_INTERVAL_US;
}

static void verde_browser_linux_dispatch_frame_complete(struct verde_browser_linux *browser) {
    if (browser == NULL || browser->exportable == NULL) return;
    wpe_view_backend_exportable_fdo_dispatch_frame_complete(browser->exportable);
}

static gboolean verde_browser_linux_frame_complete_timer(gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    if (browser != NULL) {
        browser->frame_complete_timer_id = 0;
        verde_browser_linux_dispatch_frame_complete(browser);
    }
    return G_SOURCE_REMOVE;
}

static void verde_browser_linux_schedule_frame_complete(struct verde_browser_linux *browser, gint64 delay_us) {
    if (browser == NULL || browser->frame_complete_timer_id != 0) return;
    guint delay_ms = (guint)((delay_us + 999) / 1000);
    if (delay_ms == 0) delay_ms = 1;
    browser->frame_complete_timer_id = g_timeout_add(delay_ms, verde_browser_linux_frame_complete_timer, browser);
}

static void verde_browser_linux_queue_event(struct verde_browser_linux *browser, int kind, const char *payload) {
    struct verde_browser_linux_event *event = g_new0(struct verde_browser_linux_event, 1);
    event->kind = kind;
    event->payload = payload != NULL ? g_strdup(payload) : NULL;
    g_queue_push_tail(browser->events, event);
}

static gboolean verde_browser_linux_env_has_value(const char *name) {
    const char *value = getenv(name);
    return value != NULL && value[0] != '\0';
}

static gboolean verde_browser_linux_remote_inspector_configured(void) {
    return verde_browser_linux_env_has_value("WEBKIT_INSPECTOR_SERVER") ||
        verde_browser_linux_env_has_value("WEBKIT_INSPECTOR_HTTP_SERVER");
}

static char *verde_browser_linux_remote_inspector_uri(void) {
    const char *http_server = getenv("WEBKIT_INSPECTOR_HTTP_SERVER");
    if (http_server != NULL && http_server[0] != '\0') {
        return g_strdup_printf("http://%s", http_server);
    }

    const char *inspector_server = getenv("WEBKIT_INSPECTOR_SERVER");
    if (inspector_server != NULL && inspector_server[0] != '\0') {
        return g_strdup_printf("inspector://%s", inspector_server);
    }

    return NULL;
}

static void verde_browser_linux_open_remote_inspector(struct verde_browser_linux *browser) {
    char *uri = verde_browser_linux_remote_inspector_uri();
    if (uri == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "WPE remote inspector server is not configured.");
        return;
    }

    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(stderr, "verde-browser-linux opening WPE inspector uri=%s\n", uri);
        fflush(stderr);
    }

    char *argv[] = { "xdg-open", uri, NULL };
    GError *error = NULL;
    if (!g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, &error)) {
        if (verde_browser_linux_frame_log_enabled() && error != NULL) {
            fprintf(stderr, "verde-browser-linux WPE inspector open failed: %s\n", error->message);
            fflush(stderr);
        }
        if (error != NULL) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, error->message);
            g_error_free(error);
        } else {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to open WPE remote inspector.");
        }
    }
    g_free(uri);
}

static void verde_browser_linux_clear_context_items(struct verde_browser_linux *browser) {
    if (browser == NULL) return;
    for (guint index = 0; index < browser->context_item_count; index += 1) {
        struct verde_browser_linux_context_menu_item *item = &browser->context_items[index];
        g_clear_pointer(&item->label, g_free);
        if (item->action != NULL) {
            g_object_unref(item->action);
            item->action = NULL;
        }
        if (item->target != NULL) {
            g_variant_unref(item->target);
            item->target = NULL;
        }
    }
    browser->context_item_count = 0;
}

static void verde_browser_linux_clear_context_menu(struct verde_browser_linux *browser, gboolean notify) {
    if (browser == NULL) return;
    const gboolean had_menu = browser->context_menu != NULL || browser->context_item_count > 0;
    g_clear_object(&browser->context_menu);
    verde_browser_linux_clear_context_items(browser);
    if (!had_menu) return;
    if (notify) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_CONTEXT_MENU_DISMISSED, NULL);
    }
}

static void verde_browser_linux_json_append_string(GString *json, const char *value) {
    g_string_append_c(json, '"');
    if (value != NULL) {
        for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; cursor += 1) {
            switch (*cursor) {
            case '"':
                g_string_append(json, "\\\"");
                break;
            case '\\':
                g_string_append(json, "\\\\");
                break;
            case '\b':
                g_string_append(json, "\\b");
                break;
            case '\f':
                g_string_append(json, "\\f");
                break;
            case '\n':
                g_string_append(json, "\\n");
                break;
            case '\r':
                g_string_append(json, "\\r");
                break;
            case '\t':
                g_string_append(json, "\\t");
                break;
            default:
                if (*cursor < 0x20) {
                    g_string_append_printf(json, "\\u%04x", *cursor);
                } else {
                    g_string_append_c(json, (gchar)*cursor);
                }
                break;
            }
        }
    }
    g_string_append_c(json, '"');
}

static void verde_browser_linux_json_append_menu_label(GString *json, const char *value) {
    g_string_append_c(json, '"');
    if (value != NULL) {
        for (const unsigned char *cursor = (const unsigned char *)value; *cursor != '\0'; cursor += 1) {
            if (*cursor == '_') continue;
            switch (*cursor) {
            case '"':
                g_string_append(json, "\\\"");
                break;
            case '\\':
                g_string_append(json, "\\\\");
                break;
            case '\b':
                g_string_append(json, "\\b");
                break;
            case '\f':
                g_string_append(json, "\\f");
                break;
            case '\n':
                g_string_append(json, "\\n");
                break;
            case '\r':
                g_string_append(json, "\\r");
                break;
            case '\t':
                g_string_append(json, "\\t");
                break;
            default:
                if (*cursor < 0x20) {
                    g_string_append_printf(json, "\\u%04x", *cursor);
                } else {
                    g_string_append_c(json, (gchar)*cursor);
                }
                break;
            }
        }
    }
    g_string_append_c(json, '"');
}

static const char *verde_browser_linux_context_action_label(WebKitContextMenuAction action) {
    switch (action) {
    case WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK: return "Open Link";
    case WEBKIT_CONTEXT_MENU_ACTION_OPEN_LINK_IN_NEW_WINDOW: return "Open Link in New Window";
    case WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_LINK_TO_DISK: return "Download Linked File";
    case WEBKIT_CONTEXT_MENU_ACTION_COPY_LINK_TO_CLIPBOARD: return "Copy Link";
    case WEBKIT_CONTEXT_MENU_ACTION_OPEN_IMAGE_IN_NEW_WINDOW: return "Open Image";
    case WEBKIT_CONTEXT_MENU_ACTION_DOWNLOAD_IMAGE_TO_DISK: return "Download Image";
    case WEBKIT_CONTEXT_MENU_ACTION_COPY_IMAGE_TO_CLIPBOARD: return "Copy Image";
    case WEBKIT_CONTEXT_MENU_ACTION_GO_BACK: return "Back";
    case WEBKIT_CONTEXT_MENU_ACTION_GO_FORWARD: return "Forward";
    case WEBKIT_CONTEXT_MENU_ACTION_STOP: return "Stop";
    case WEBKIT_CONTEXT_MENU_ACTION_RELOAD: return "Reload";
    case WEBKIT_CONTEXT_MENU_ACTION_COPY: return "Copy";
    case WEBKIT_CONTEXT_MENU_ACTION_CUT: return "Cut";
    case WEBKIT_CONTEXT_MENU_ACTION_PASTE: return "Paste";
    case WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT: return "Inspect Element";
    default: return "Context Action";
    }
}

static gboolean verde_browser_linux_context_stock_action_is_supported(WebKitContextMenuAction action) {
    switch (action) {
    case WEBKIT_CONTEXT_MENU_ACTION_GO_BACK:
    case WEBKIT_CONTEXT_MENU_ACTION_GO_FORWARD:
    case WEBKIT_CONTEXT_MENU_ACTION_STOP:
    case WEBKIT_CONTEXT_MENU_ACTION_RELOAD:
    case WEBKIT_CONTEXT_MENU_ACTION_COPY:
    case WEBKIT_CONTEXT_MENU_ACTION_CUT:
    case WEBKIT_CONTEXT_MENU_ACTION_PASTE:
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT:
        return verde_browser_linux_remote_inspector_configured();
    default:
        return FALSE;
    }
}

static void verde_browser_linux_context_menu_get_position_compat(WebKitContextMenu *menu, gint *x, gint *y) {
    if (x != NULL) *x = 0;
    if (y != NULL) *y = 0;
#if VERDE_BROWSER_LINUX_HAS_CONTEXT_MENU_DETAILS
    (void)webkit_context_menu_get_position(menu, x, y);
#else
    (void)menu;
#endif
}

static const gchar *verde_browser_linux_context_menu_item_get_title_compat(WebKitContextMenuItem *item, WebKitContextMenuAction stock_action) {
#if VERDE_BROWSER_LINUX_HAS_CONTEXT_MENU_DETAILS
    const gchar *title = webkit_context_menu_item_get_title(item);
    if (title != NULL && title[0] != '\0') return title;
#else
    (void)item;
#endif
    return verde_browser_linux_context_action_label(stock_action);
}

static GVariant *verde_browser_linux_context_menu_item_get_target_compat(WebKitContextMenuItem *item) {
#if VERDE_BROWSER_LINUX_HAS_CONTEXT_MENU_DETAILS
    return webkit_context_menu_item_get_gaction_target(item);
#else
    (void)item;
    return NULL;
#endif
}

static void verde_browser_linux_toggle_inspector_compat(WebKitWebView *web_view) {
#if WEBKIT_CHECK_VERSION(2, 52, 0)
    webkit_web_view_toggle_inspector(web_view);
#else
    (void)web_view;
#endif
}

static char *verde_browser_linux_context_menu_to_json(struct verde_browser_linux *browser, WebKitContextMenu *menu) {
    if (browser != NULL) verde_browser_linux_clear_context_items(browser);
    if (menu == NULL) return g_strdup("{\"x\":0,\"y\":0,\"items\":[]}");
    gint x = 0;
    gint y = 0;
    verde_browser_linux_context_menu_get_position_compat(menu, &x, &y);
    GString *json = g_string_new(NULL);
    g_string_append_printf(json, "{\"x\":%d,\"y\":%d,\"items\":[", x, y);

    GList *items = webkit_context_menu_get_items(menu);
    guint index = 0;
    gboolean first = TRUE;
    for (GList *node = items; node != NULL; node = node->next, index += 1) {
        WebKitContextMenuItem *item = WEBKIT_CONTEXT_MENU_ITEM(node->data);
        if (item == NULL) continue;
        if (!first) g_string_append_c(json, ',');
        first = FALSE;

        const gboolean separator = webkit_context_menu_item_is_separator(item);
        WebKitContextMenu *submenu = webkit_context_menu_item_get_submenu(item);
        GAction *action = webkit_context_menu_item_get_gaction(item);
        WebKitContextMenuAction stock_action = webkit_context_menu_item_get_stock_action(item);
        const gchar *title = verde_browser_linux_context_menu_item_get_title_compat(item, stock_action);
        if (stock_action == WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT &&
            !verde_browser_linux_remote_inspector_configured()) {
            continue;
        }
        const gboolean action_enabled = action != NULL && g_action_get_enabled(action);
        const gboolean enabled = !separator && submenu == NULL && (action_enabled || verde_browser_linux_context_stock_action_is_supported(stock_action));
        if (browser != NULL && index < VERDE_BROWSER_LINUX_CONTEXT_MENU_ITEM_MAX) {
            struct verde_browser_linux_context_menu_item *stored = &browser->context_items[index];
            stored->label = g_strdup(title);
            stored->stock_action = stock_action;
            stored->action = action != NULL ? g_object_ref(action) : NULL;
            stored->target = verde_browser_linux_context_menu_item_get_target_compat(item);
            if (stored->target != NULL) stored->target = g_variant_ref(stored->target);
            stored->enabled = enabled;
            stored->separator = separator;
            stored->submenu = submenu != NULL;
            if (index >= browser->context_item_count) browser->context_item_count = index + 1;
        }

        g_string_append_printf(json, "{\"index\":%u,\"separator\":%s,\"enabled\":%s,\"submenu\":%s,\"label\":",
            index,
            separator ? "true" : "false",
            enabled ? "true" : "false",
            submenu != NULL ? "true" : "false");
        verde_browser_linux_json_append_menu_label(json, title);
        g_string_append_c(json, '}');
    }
    g_string_append(json, "]}");
    return g_string_free(json, FALSE);
}

static gboolean verde_browser_linux_frame_log_enabled(void) {
    const char *value = getenv("VERDE_BROWSER_FRAME_LOG");
    return value != NULL && strcmp(value, "1") == 0;
}

static gboolean verde_browser_linux_prefer_dark_scheme_enabled(void) {
    const char *value = getenv("VERDE_BROWSER_LINUX_WPE_PREFER_DARK");
    if (value == NULL || value[0] == '\0') return TRUE;
    return g_ascii_strcasecmp(value, "0") != 0 &&
        g_ascii_strcasecmp(value, "false") != 0 &&
        g_ascii_strcasecmp(value, "off") != 0 &&
        g_ascii_strcasecmp(value, "light") != 0;
}

static void verde_browser_linux_add_prefer_dark_scheme_script(WebKitUserContentManager *manager) {
    if (manager == NULL || !verde_browser_linux_prefer_dark_scheme_enabled()) return;
    WebKitUserScript *scheme_script = webkit_user_script_new(
        "(function(){"
        "document.documentElement.style.colorScheme='dark';"
        "document.documentElement.setAttribute('data-theme','dark');"
        "document.documentElement.classList.add('dark');"
        "const originalMatchMedia=window.matchMedia&&window.matchMedia.bind(window);"
        "if(originalMatchMedia){"
        "window.matchMedia=function(query){"
        "const result=originalMatchMedia(query);"
        "const text=String(query);"
        "if(text.indexOf('prefers-color-scheme')!==-1){"
        "const wantsDark=text.indexOf('dark')!==-1;"
        "try{Object.defineProperty(result,'matches',{value:wantsDark,configurable:true});}catch(e){}"
        "}"
        "return result;"
        "};"
        "}"
        "})();",
        WEBKIT_USER_CONTENT_INJECT_ALL_FRAMES,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        NULL,
        NULL
    );
    webkit_user_content_manager_add_script(manager, scheme_script);
    webkit_user_script_unref(scheme_script);
}

static guint32 verde_browser_linux_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (guint32)((ts.tv_sec * 1000u) + (ts.tv_nsec / 1000000u));
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

static gboolean verde_browser_linux_init_egl(struct verde_browser_linux *browser) {
    browser->egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (browser->egl_display == EGL_NO_DISPLAY) return FALSE;
    if (!eglInitialize(browser->egl_display, NULL, NULL)) return FALSE;
    if (!wpe_fdo_initialize_for_egl_display(browser->egl_display)) return FALSE;

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = NULL;
    EGLint config_count = 0;
    if (!eglChooseConfig(browser->egl_display, config_attributes, &config, 1, &config_count) || config_count == 0) return FALSE;

    const EGLint surface_attributes[] = {
        EGL_WIDTH, 1,
        EGL_HEIGHT, 1,
        EGL_NONE,
    };
    browser->egl_surface = eglCreatePbufferSurface(browser->egl_display, config, surface_attributes);
    if (browser->egl_surface == EGL_NO_SURFACE) return FALSE;

    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };
    browser->egl_context = eglCreateContext(browser->egl_display, config, EGL_NO_CONTEXT, context_attributes);
    if (browser->egl_context == EGL_NO_CONTEXT) return FALSE;
    if (!eglMakeCurrent(browser->egl_display, browser->egl_surface, browser->egl_surface, browser->egl_context)) return FALSE;

    glGenTextures(1, &browser->texture);
    browser->gl_egl_image_target_texture_2d = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    if (browser->gl_egl_image_target_texture_2d == NULL) return FALSE;
    glBindTexture(GL_TEXTURE_2D, browser->texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &browser->framebuffer);
    return browser->texture != 0 && browser->framebuffer != 0;
}

static void verde_browser_linux_deinit_egl(struct verde_browser_linux *browser) {
    if (browser == NULL || browser->egl_display == EGL_NO_DISPLAY) return;
    eglMakeCurrent(browser->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (browser->framebuffer != 0) glDeleteFramebuffers(1, &browser->framebuffer);
    if (browser->texture != 0) glDeleteTextures(1, &browser->texture);
    if (browser->egl_context != EGL_NO_CONTEXT) eglDestroyContext(browser->egl_display, browser->egl_context);
    if (browser->egl_surface != EGL_NO_SURFACE) eglDestroySurface(browser->egl_display, browser->egl_surface);
    eglTerminate(browser->egl_display);
    browser->egl_display = EGL_NO_DISPLAY;
    browser->egl_context = EGL_NO_CONTEXT;
    browser->egl_surface = EGL_NO_SURFACE;
}

static gboolean verde_browser_linux_publish_pixels(struct verde_browser_linux *browser, guint32 width, guint32 height, const unsigned char *rgba) {
    if (browser == NULL || width == 0 || height == 0 || rgba == NULL) return FALSE;
    const size_t byte_len = (size_t)width * (size_t)height * 4u;
    if (!verde_browser_linux_shared_frames_enabled(browser) || byte_len > VERDE_BROWSER_LINUX_FRAME_BYTES_MAX) {
        if (!browser->frame_slots_failure_reported) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "WPE frame slots are unavailable or too small.");
            browser->frame_slots_failure_reported = TRUE;
        }
        return FALSE;
    }
    browser->frame_slots_failure_reported = FALSE;
    browser->frame_import_failure_reported = FALSE;

    const gint frame_slot = browser->frame_next_slot;
    unsigned char *bgra = browser->frame_slots[frame_slot];
    for (size_t index = 0; index < (size_t)width * (size_t)height; index += 1) {
        const size_t offset = index * 4u;
        bgra[offset + 0] = rgba[offset + 2];
        bgra[offset + 1] = rgba[offset + 1];
        bgra[offset + 2] = rgba[offset + 0];
        bgra[offset + 3] = 255;
    }

    browser->frame_next_slot = (guint8)((browser->frame_next_slot + 1) % VERDE_BROWSER_LINUX_FRAME_SLOT_COUNT);
    browser->frame_ready_sequence = ++browser->frame_next_sequence;
    browser->frame_ready_slot = frame_slot;
    browser->frame_width = (gint)width;
    browser->frame_height = (gint)height;
    browser->frame_byte_len = byte_len;
    browser->frame_dirty = TRUE;
    return TRUE;
}

static gboolean verde_browser_linux_export_egl_image(struct verde_browser_linux *browser, struct wpe_fdo_egl_exported_image *image) {
    if (browser == NULL || image == NULL) return FALSE;
    const guint32 width = wpe_fdo_egl_exported_image_get_width(image);
    const guint32 height = wpe_fdo_egl_exported_image_get_height(image);
    const size_t byte_len = (size_t)width * (size_t)height * 4u;
    if (width == 0 || height == 0 || byte_len > VERDE_BROWSER_LINUX_FRAME_BYTES_MAX) return FALSE;
    if (browser->rgba_scratch_len < byte_len) {
        unsigned char *next = g_realloc(browser->rgba_scratch, byte_len);
        if (next == NULL) return FALSE;
        browser->rgba_scratch = next;
        browser->rgba_scratch_len = byte_len;
    }

    if (!eglMakeCurrent(browser->egl_display, browser->egl_surface, browser->egl_surface, browser->egl_context)) return FALSE;
    glBindTexture(GL_TEXTURE_2D, browser->texture);
    browser->gl_egl_image_target_texture_2d(GL_TEXTURE_2D, wpe_fdo_egl_exported_image_get_egl_image(image));
    glBindFramebuffer(GL_FRAMEBUFFER, browser->framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, browser->texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return FALSE;
    glViewport(0, 0, (GLsizei)width, (GLsizei)height);
    glReadPixels(0, 0, (GLsizei)width, (GLsizei)height, GL_RGBA, GL_UNSIGNED_BYTE, browser->rgba_scratch);

    return verde_browser_linux_publish_pixels(browser, width, height, browser->rgba_scratch);
}

static void verde_browser_linux_export_raw_egl_image(void *data, EGLImageKHR image) {
    struct verde_browser_linux *browser = data;
    (void)browser;
    (void)image;
}

static void verde_browser_linux_export_fdo_egl_image(void *data, struct wpe_fdo_egl_exported_image *image) {
    struct verde_browser_linux *browser = data;
    if (browser == NULL || image == NULL) return;
    const gint64 now_us = g_get_monotonic_time();
    const gint64 min_interval_us = verde_browser_linux_frame_min_interval_us(browser, now_us);
    const gint64 elapsed_us = now_us - browser->last_frame_published_us;
    if (browser->last_frame_published_us > 0 && elapsed_us < min_interval_us) {
        wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(browser->exportable, image);
        verde_browser_linux_schedule_frame_complete(browser, min_interval_us - elapsed_us);
        return;
    }
    const gboolean ok = verde_browser_linux_export_egl_image(browser, image);
    wpe_view_backend_exportable_fdo_egl_dispatch_release_exported_image(browser->exportable, image);
    verde_browser_linux_dispatch_frame_complete(browser);
    if (!ok) {
        if (!browser->frame_import_failure_reported) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to import WPE EGL frame.");
            browser->frame_import_failure_reported = TRUE;
        }
        return;
    }
    browser->last_frame_published_us = now_us;
    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(stderr, "verde-browser-linux WPE frame seq=%" G_GUINT64_FORMAT " shared_slot=%d size=%dx%d bytes=%zu\n",
            browser->frame_ready_sequence,
            browser->frame_ready_slot,
            browser->frame_width,
            browser->frame_height,
            (size_t)browser->frame_byte_len);
        fflush(stderr);
    }
}

static void verde_browser_linux_export_shm_buffer(void *data, struct wpe_fdo_shm_exported_buffer *buffer) {
    struct verde_browser_linux *browser = data;
    wpe_view_backend_exportable_fdo_egl_dispatch_release_shm_exported_buffer(browser->exportable, buffer);
    verde_browser_linux_dispatch_frame_complete(browser);
}

static char *verde_browser_linux_value_to_json_or_string(JSCValue *value) {
    if (jsc_value_is_string(value)) return jsc_value_to_string(value);
    char *json = jsc_value_to_json(value, 0);
    if (json != NULL) return json;
    return jsc_value_to_string(value);
}

static void verde_browser_linux_on_script_message(WebKitUserContentManager *manager, JSCValue *value, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    char *payload = verde_browser_linux_value_to_json_or_string(value);
    (void)manager;
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_JS_MESSAGE, payload);
    g_free(payload);
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

static void verde_browser_linux_on_load_changed(WebKitWebView *web_view, WebKitLoadEvent load_event, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    (void)web_view;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    if (load_event == WEBKIT_LOAD_FINISHED) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_DOCUMENT_LOADED, NULL);
    }
}

static void verde_browser_linux_on_web_process_terminated(WebKitWebView *web_view, WebKitWebProcessTerminationReason reason, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    const char *message = "WPE web process terminated.";
    (void)web_view;
    switch (reason) {
    case WEBKIT_WEB_PROCESS_CRASHED:
        message = "WPE web process crashed.";
        break;
    case WEBKIT_WEB_PROCESS_EXCEEDED_MEMORY_LIMIT:
        message = "WPE web process exceeded its memory limit.";
        break;
    case WEBKIT_WEB_PROCESS_TERMINATED_BY_API:
        message = "WPE web process was terminated by API request.";
        break;
    default:
        break;
    }
    fprintf(stderr, "verde-browser-linux WPE: %s\n", message);
    fflush(stderr);
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, message);
}

static gboolean verde_browser_linux_on_context_menu(WebKitWebView *web_view, WebKitContextMenu *menu, WebKitHitTestResult *hit_test, gpointer user_data) {
    struct verde_browser_linux *browser = user_data;
    (void)web_view;
    (void)hit_test;
    if (browser == NULL || menu == NULL) return FALSE;

    verde_browser_linux_clear_context_menu(browser, FALSE);
    browser->context_menu = g_object_ref(menu);
    char *payload = verde_browser_linux_context_menu_to_json(browser, menu);
    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(stderr, "verde-browser-linux WPE context-menu items=%u\n", browser->context_item_count);
        fflush(stderr);
    }
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_CONTEXT_MENU, payload);
    g_free(payload);
    return TRUE;
}

static void verde_browser_linux_on_context_menu_dismissed(WebKitWebView *web_view, gpointer user_data) {
    (void)web_view;
    (void)user_data;
    // WPE emits this for the suppressed native menu. Verde owns the visible
    // menu, so the action handles must remain alive until the app sends an
    // explicit activate or dismiss command.
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
        return;
    }
    char *payload = verde_browser_linux_value_to_json_or_string(value);
    verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_EVAL_RESULT, payload);
    g_free(payload);
    g_object_unref(value);
}

static void verde_browser_linux_on_internal_script_finished(GObject *object, GAsyncResult *result, gpointer user_data) {
    GError *error = NULL;
    JSCValue *value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), result, &error);
    if (error != NULL) {
        g_error_free(error);
        return;
    }
    if (value != NULL) g_object_unref(value);
    (void)user_data;
}

static void verde_browser_linux_run_internal_script(struct verde_browser_linux *browser, const char *script) {
    if (browser == NULL || script == NULL) return;
    webkit_web_view_evaluate_javascript(browser->web_view, script, -1, NULL, "app://verde-browser-input.js", NULL, verde_browser_linux_on_internal_script_finished, browser);
}

static guint32 verde_browser_linux_encode_modifiers(unsigned int modifiers) {
    guint32 mask = 0;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_CTRL) != 0) mask |= wpe_input_keyboard_modifier_control;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_SHIFT) != 0) mask |= wpe_input_keyboard_modifier_shift;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_ALT) != 0) mask |= wpe_input_keyboard_modifier_alt;
    if ((modifiers & VERDE_BROWSER_LINUX_MOD_SUPER) != 0) mask |= wpe_input_keyboard_modifier_meta;
    return mask;
}

static guint32 verde_browser_linux_pointer_button_modifier(unsigned int button) {
    switch (button) {
    case 1: return wpe_input_pointer_modifier_button1;
    case 2: return wpe_input_pointer_modifier_button2;
    case 3: return wpe_input_pointer_modifier_button3;
    case 4: return wpe_input_pointer_modifier_button4;
    case 5: return wpe_input_pointer_modifier_button5;
    default: return 0;
    }
}

static unsigned int verde_browser_linux_protocol_to_wpe_button(unsigned int button) {
    switch (button) {
    case 2: return 3;
    case 3: return 2;
    default: return button;
    }
}

static guint32 verde_browser_linux_key_code_to_hardware(unsigned int key_code) {
    if (key_code >= 0xff00u) return key_code;
    return wpe_unicode_to_key_code(key_code);
}

static void verde_browser_linux_destroy_exportable(gpointer user_data) {
    struct wpe_view_backend_exportable_fdo *exportable = user_data;
    if (exportable != NULL) wpe_view_backend_exportable_fdo_destroy(exportable);
}

struct verde_browser_linux *verde_browser_linux_create(void) {
    struct verde_browser_linux *browser = g_new0(struct verde_browser_linux, 1);
    browser->events = g_queue_new();
    browser->target_width = 1280;
    browser->target_height = 720;
    browser->device_scale = 1.0;
    browser->frame_ready_slot = -1;
    browser->egl_display = EGL_NO_DISPLAY;
    browser->egl_context = EGL_NO_CONTEXT;
    browser->egl_surface = EGL_NO_SURFACE;
    verde_browser_linux_map_frame_slots(browser);

    if (!wpe_loader_init("libWPEBackend-fdo-1.0.so")) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to initialize WPEBackend-fdo.");
        return browser;
    }
    if (!verde_browser_linux_init_egl(browser)) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to initialize WPE EGL rendering.");
        return browser;
    }

    browser->export_client = (struct wpe_view_backend_exportable_fdo_egl_client){
        .export_egl_image = verde_browser_linux_export_raw_egl_image,
        .export_fdo_egl_image = verde_browser_linux_export_fdo_egl_image,
        .export_shm_buffer = verde_browser_linux_export_shm_buffer,
    };
    browser->exportable = wpe_view_backend_exportable_fdo_egl_create(&browser->export_client, browser, browser->target_width, browser->target_height);
    if (browser->exportable == NULL) {
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to create WPE exportable backend.");
        return browser;
    }
    browser->view_backend = wpe_view_backend_exportable_fdo_get_view_backend(browser->exportable);
    wpe_view_backend_dispatch_set_size(browser->view_backend, browser->target_width, browser->target_height);
    wpe_view_backend_dispatch_set_device_scale_factor(browser->view_backend, (float)browser->device_scale);
    wpe_view_backend_set_target_refresh_rate(browser->view_backend, 60000);
    wpe_view_backend_add_activity_state(browser->view_backend, wpe_view_activity_state_visible | wpe_view_activity_state_in_window);

    browser->webkit_backend = webkit_web_view_backend_new(browser->view_backend, verde_browser_linux_destroy_exportable, browser->exportable);
    browser->web_view = WEBKIT_WEB_VIEW(webkit_web_view_new(browser->webkit_backend));
    browser->content_manager = webkit_web_view_get_user_content_manager(browser->web_view);
    g_object_ref(browser->content_manager);

    WebKitColor background = { 1.0, 1.0, 1.0, 1.0 };
    webkit_web_view_set_background_color(browser->web_view, &background);
    WebKitSettings *settings = webkit_web_view_get_settings(browser->web_view);
    webkit_settings_set_enable_developer_extras(settings, TRUE);

    verde_browser_linux_add_prefer_dark_scheme_script(browser->content_manager);

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
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to register WPE script message handler.");
    }

    g_signal_connect(browser->web_view, "notify::uri", G_CALLBACK(verde_browser_linux_on_uri_changed), browser);
    g_signal_connect(browser->web_view, "notify::title", G_CALLBACK(verde_browser_linux_on_title_changed), browser);
    g_signal_connect(browser->web_view, "load-changed", G_CALLBACK(verde_browser_linux_on_load_changed), browser);
    g_signal_connect(browser->web_view, "web-process-terminated", G_CALLBACK(verde_browser_linux_on_web_process_terminated), browser);
    g_signal_connect(browser->web_view, "context-menu", G_CALLBACK(verde_browser_linux_on_context_menu), browser);
    g_signal_connect(browser->web_view, "context-menu-dismissed", G_CALLBACK(verde_browser_linux_on_context_menu_dismissed), browser);
    webkit_web_view_load_uri(browser->web_view, "about:blank");
    return browser;
}

void verde_browser_linux_destroy(struct verde_browser_linux *browser) {
    if (browser == NULL) return;
    if (browser->frame_complete_timer_id != 0) {
        g_source_remove(browser->frame_complete_timer_id);
        browser->frame_complete_timer_id = 0;
    }
    if (browser->content_manager != NULL) {
        webkit_user_content_manager_unregister_script_message_handler(browser->content_manager, "verde", NULL);
        g_object_unref(browser->content_manager);
    }
    verde_browser_linux_clear_context_menu(browser, FALSE);
    while (!g_queue_is_empty(browser->events)) {
        struct verde_browser_linux_event *event = g_queue_pop_head(browser->events);
        if (event != NULL) {
            g_free(event->payload);
            g_free(event);
        }
    }
    if (browser->web_view != NULL) g_object_unref(browser->web_view);
    if (browser->webkit_backend != NULL) g_object_unref(browser->webkit_backend);
    g_free(browser->rgba_scratch);
    verde_browser_linux_deinit_egl(browser);
    verde_browser_linux_unmap_frame_slots(browser);
    g_queue_free(browser->events);
    g_free(browser);
}

int verde_browser_linux_set_host_window(struct verde_browser_linux *browser, size_t host_window) {
    (void)browser;
    (void)host_window;
    return 1;
}

int verde_browser_linux_set_device_scale(struct verde_browser_linux *browser, double scale) {
    if (browser == NULL) return 0;
    if (!(scale >= 0.05 && scale <= 5.0)) scale = 1.0;
    const double diff = browser->device_scale > scale ? browser->device_scale - scale : scale - browser->device_scale;
    if (diff <= 0.001) return 1;
    browser->device_scale = scale;
    verde_browser_linux_mark_active(browser);
    if (browser->view_backend != NULL) {
        wpe_view_backend_dispatch_set_device_scale_factor(browser->view_backend, (float)browser->device_scale);
    }
    return 1;
}

int verde_browser_linux_show(struct verde_browser_linux *browser, int width, int height, const char *url) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    if (width > 0 && height > 0) {
        verde_browser_linux_set_bounds(browser, 0, 0, width, height);
    }
    if (!browser->visible) {
        browser->visible = TRUE;
        wpe_view_backend_add_activity_state(browser->view_backend, wpe_view_activity_state_visible | wpe_view_activity_state_in_window);
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_OPENED, NULL);
    }
    if (url != NULL) webkit_web_view_load_uri(browser->web_view, url);
    return 1;
}

int verde_browser_linux_hide(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    if (browser->visible) {
        browser->visible = FALSE;
        wpe_view_backend_remove_activity_state(browser->view_backend, wpe_view_activity_state_visible);
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_CLOSED, NULL);
    }
    return 1;
}

int verde_browser_linux_set_bounds(struct verde_browser_linux *browser, int x, int y, int width, int height) {
    if (browser == NULL || width <= 0 || height <= 0) return 0;
    (void)x;
    (void)y;
    if (browser->target_width == width && browser->target_height == height) return 1;
    verde_browser_linux_mark_active(browser);
    browser->target_width = width;
    browser->target_height = height;
    wpe_view_backend_dispatch_set_size(browser->view_backend, (uint32_t)width, (uint32_t)height);
    return 1;
}

int verde_browser_linux_resize(struct verde_browser_linux *browser, int width, int height) {
    return verde_browser_linux_set_bounds(browser, 0, 0, width, height);
}

int verde_browser_linux_navigate(struct verde_browser_linux *browser, const char *url) {
    if (browser == NULL || url == NULL) return 0;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    webkit_web_view_load_uri(browser->web_view, url);
    return 1;
}

int verde_browser_linux_eval(struct verde_browser_linux *browser, const char *js) {
    if (browser == NULL || js == NULL) return 0;
    webkit_web_view_evaluate_javascript(browser->web_view, js, -1, NULL, "app://verde-eval.js", NULL, verde_browser_linux_on_eval_finished, browser);
    return 1;
}

int verde_browser_linux_post_json(struct verde_browser_linux *browser, const char *json) {
    if (browser == NULL || json == NULL) return 0;
    char *script = g_strdup_printf("(function(){const payload=%s;window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})()", json);
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    return 1;
}

int verde_browser_linux_go_back(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    if (webkit_web_view_can_go_back(browser->web_view)) webkit_web_view_go_back(browser->web_view);
    return 1;
}

int verde_browser_linux_go_forward(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    if (webkit_web_view_can_go_forward(browser->web_view)) webkit_web_view_go_forward(browser->web_view);
    return 1;
}

int verde_browser_linux_reload(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active_for(browser, VERDE_BROWSER_LINUX_ACTIVE_AFTER_LOAD_US);
    webkit_web_view_reload(browser->web_view);
    return 1;
}

int verde_browser_linux_focus(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    wpe_view_backend_add_activity_state(browser->view_backend, wpe_view_activity_state_focused);
    return 1;
}

int verde_browser_linux_blur(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    wpe_view_backend_remove_activity_state(browser->view_backend, wpe_view_activity_state_focused);
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
    if (!browser->frame_dirty || browser->frame_ready_slot < 0) return 0;
    *path = NULL;
    *sequence = (uint64_t)browser->frame_ready_sequence;
    *slot = browser->frame_ready_slot;
    *width = browser->frame_width;
    *height = browser->frame_height;
    *byte_len = browser->frame_byte_len;
    browser->frame_dirty = FALSE;
    return 1;
}

int verde_browser_linux_mouse_move(struct verde_browser_linux *browser, double x, double y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active(browser);
    struct wpe_input_pointer_event event = {
        .type = wpe_input_pointer_event_type_motion,
        .time = verde_browser_linux_now_ms(),
        .x = (int)x,
        .y = (int)y,
        .button = 0,
        .state = 0,
        .modifiers = verde_browser_linux_encode_modifiers(modifiers) | browser->pointer_modifiers,
    };
    wpe_view_backend_dispatch_pointer_event(browser->view_backend, &event);
    return 1;
}

int verde_browser_linux_mouse_button(struct verde_browser_linux *browser, double x, double y, unsigned int button, int down, unsigned int modifiers) {
    if (browser == NULL || button == 0) return 0;
    verde_browser_linux_mark_active(browser);
    const unsigned int wpe_button = verde_browser_linux_protocol_to_wpe_button(button);
    const guint32 button_modifier = verde_browser_linux_pointer_button_modifier(wpe_button);
    if (down != 0) browser->pointer_modifiers |= button_modifier;
    else browser->pointer_modifiers &= ~button_modifier;
    struct wpe_input_pointer_event event = {
        .type = wpe_input_pointer_event_type_button,
        .time = verde_browser_linux_now_ms(),
        .x = (int)x,
        .y = (int)y,
        .button = wpe_button,
        .state = down != 0 ? 1u : 0u,
        .modifiers = verde_browser_linux_encode_modifiers(modifiers) | browser->pointer_modifiers,
    };
    wpe_view_backend_dispatch_pointer_event(browser->view_backend, &event);
    return 1;
}

int verde_browser_linux_mouse_wheel(struct verde_browser_linux *browser, double x, double y, double delta_x, double delta_y, unsigned int modifiers) {
    if (browser == NULL) return 0;
    verde_browser_linux_mark_active(browser);
    struct wpe_input_axis_2d_event event = {
        .base = {
            .type = wpe_input_axis_event_type_motion_smooth | wpe_input_axis_event_type_mask_2d,
            .time = verde_browser_linux_now_ms(),
            .x = (int)x,
            .y = (int)y,
            .axis = 0,
            .value = 0,
            .modifiers = verde_browser_linux_encode_modifiers(modifiers) | browser->pointer_modifiers,
        },
        .x_axis = delta_x * 96.0,
        .y_axis = delta_y * 96.0,
    };
    wpe_view_backend_dispatch_axis_event(browser->view_backend, &event.base);
    return 1;
}

int verde_browser_linux_key_input(struct verde_browser_linux *browser, unsigned int key_code, int down, unsigned int modifiers) {
    if (browser == NULL || key_code == 0) return 0;
    verde_browser_linux_mark_active(browser);
    struct wpe_input_keyboard_event event = {
        .time = verde_browser_linux_now_ms(),
        .key_code = key_code,
        .hardware_key_code = verde_browser_linux_key_code_to_hardware(key_code),
        .pressed = down != 0,
        .modifiers = verde_browser_linux_encode_modifiers(modifiers),
    };
    wpe_view_backend_dispatch_keyboard_event(browser->view_backend, &event);
    return 1;
}

int verde_browser_linux_text_input(struct verde_browser_linux *browser, const char *text, unsigned int modifiers) {
    if (browser == NULL || text == NULL || text[0] == '\0') return 0;
    verde_browser_linux_mark_active(browser);
    char *escaped = g_strescape(text, NULL);
    char *script = g_strdup_printf(
        "(function(){const text='%s';const el=document.activeElement;if(!el)return false;if(el.isContentEditable){document.execCommand('insertText',false,text);return true;}if(el instanceof HTMLInputElement||el instanceof HTMLTextAreaElement){const start=el.selectionStart??el.value.length;const end=el.selectionEnd??el.value.length;const before=el.value.slice(0,start);const after=el.value.slice(end);el.value=before+text+after;const next=start+text.length;if(el.setSelectionRange)el.setSelectionRange(next,next);el.dispatchEvent(new InputEvent('input',{bubbles:true,data:text,inputType:'insertText'}));return true;}return true;})()",
        escaped
    );
    verde_browser_linux_run_internal_script(browser, script);
    g_free(script);
    g_free(escaped);
    (void)modifiers;
    return 1;
}

static gboolean verde_browser_linux_perform_context_menu_stock_action(struct verde_browser_linux *browser, WebKitContextMenuAction action) {
    if (browser == NULL || browser->web_view == NULL) return FALSE;
    switch (action) {
    case WEBKIT_CONTEXT_MENU_ACTION_GO_BACK:
        if (webkit_web_view_can_go_back(browser->web_view)) webkit_web_view_go_back(browser->web_view);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_GO_FORWARD:
        if (webkit_web_view_can_go_forward(browser->web_view)) webkit_web_view_go_forward(browser->web_view);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_STOP:
        webkit_web_view_stop_loading(browser->web_view);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_RELOAD:
        webkit_web_view_reload(browser->web_view);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_COPY:
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_COPY);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_CUT:
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_CUT);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_PASTE:
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_PASTE);
        return TRUE;
    case WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT:
        if (!verde_browser_linux_remote_inspector_configured()) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "WPE Inspect Element requires WEBKIT_INSPECTOR_SERVER or WEBKIT_INSPECTOR_HTTP_SERVER.");
            return TRUE;
        }
        verde_browser_linux_toggle_inspector_compat(browser->web_view);
        return TRUE;
    default:
        return FALSE;
    }
}

static gboolean verde_browser_linux_context_label_equals(const gchar *label, const char *expected) {
    if (label == NULL || expected == NULL) return FALSE;
    const unsigned char *cursor = (const unsigned char *)label;
    const unsigned char *target = (const unsigned char *)expected;
    while (*cursor != '\0' && *target != '\0') {
        if (*cursor == '_') {
            cursor += 1;
            continue;
        }
        if (g_ascii_tolower(*cursor) != g_ascii_tolower(*target)) return FALSE;
        cursor += 1;
        target += 1;
    }
    while (*cursor == '_') cursor += 1;
    return *cursor == '\0' && *target == '\0';
}

static gboolean verde_browser_linux_perform_context_menu_label_action(struct verde_browser_linux *browser, const gchar *label) {
    if (browser == NULL || browser->web_view == NULL || label == NULL) return FALSE;
    if (verde_browser_linux_context_label_equals(label, "Back")) {
        if (webkit_web_view_can_go_back(browser->web_view)) webkit_web_view_go_back(browser->web_view);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Forward")) {
        if (webkit_web_view_can_go_forward(browser->web_view)) webkit_web_view_go_forward(browser->web_view);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Stop")) {
        webkit_web_view_stop_loading(browser->web_view);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Reload")) {
        webkit_web_view_reload(browser->web_view);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Copy")) {
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_COPY);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Cut")) {
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_CUT);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Paste")) {
        webkit_web_view_execute_editing_command(browser->web_view, WEBKIT_EDITING_COMMAND_PASTE);
        return TRUE;
    }
    if (verde_browser_linux_context_label_equals(label, "Inspect Element")) {
        if (!verde_browser_linux_remote_inspector_configured()) {
            verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "WPE Inspect Element requires WEBKIT_INSPECTOR_SERVER or WEBKIT_INSPECTOR_HTTP_SERVER.");
            return TRUE;
        }
        verde_browser_linux_toggle_inspector_compat(browser->web_view);
        return TRUE;
    }
    return FALSE;
}

int verde_browser_linux_context_menu_activate(struct verde_browser_linux *browser, unsigned int index) {
    if (browser == NULL) return 0;
    if (index >= browser->context_item_count) {
        if (verde_browser_linux_frame_log_enabled()) {
            fprintf(stderr, "verde-browser-linux WPE context-menu activate ignored index=%u count=%u\n", index, browser->context_item_count);
            fflush(stderr);
        }
        return 0;
    }
    struct verde_browser_linux_context_menu_item *item = &browser->context_items[index];
    if (!item->enabled || item->separator || item->submenu) {
        if (verde_browser_linux_frame_log_enabled()) {
            fprintf(stderr, "verde-browser-linux WPE context-menu activate disabled index=%u enabled=%d separator=%d submenu=%d\n",
                index,
                item->enabled,
                item->separator,
                item->submenu
            );
            fflush(stderr);
        }
        return 0;
    }

    gboolean handled = FALSE;
    const gboolean is_inspect = item->stock_action == WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT ||
        verde_browser_linux_context_label_equals(item->label, "Inspect Element");
    if (item->stock_action == WEBKIT_CONTEXT_MENU_ACTION_INSPECT_ELEMENT &&
        item->action != NULL &&
        g_action_get_enabled(item->action)) {
        g_action_activate(item->action, item->target);
        handled = TRUE;
    }
    if (!handled) handled = verde_browser_linux_perform_context_menu_stock_action(browser, item->stock_action);
    if (!handled) handled = verde_browser_linux_perform_context_menu_label_action(browser, item->label);
    if (!handled && item->action != NULL && g_action_get_enabled(item->action)) {
        g_action_activate(item->action, item->target);
    }
    if (is_inspect) verde_browser_linux_open_remote_inspector(browser);
    verde_browser_linux_mark_active(browser);
    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(stderr, "verde-browser-linux WPE context-menu activate index=%u handled=%d label=%s\n",
            index,
            handled,
            item->label != NULL ? item->label : ""
        );
        fflush(stderr);
    }
    verde_browser_linux_clear_context_menu(browser, TRUE);
    return 1;
}

int verde_browser_linux_context_menu_dismiss(struct verde_browser_linux *browser) {
    if (browser == NULL) return 0;
    verde_browser_linux_clear_context_menu(browser, TRUE);
    return 1;
}

void verde_browser_linux_free_string(char *payload) {
    g_free(payload);
}
