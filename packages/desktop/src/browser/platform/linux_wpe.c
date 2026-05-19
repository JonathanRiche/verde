#define GL_GLEXT_PROTOTYPES

#include <EGL/egl.h>
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

struct verde_browser_linux {
    struct wpe_view_backend_exportable_fdo *exportable;
    struct wpe_view_backend_exportable_fdo_egl_client export_client;
    struct wpe_view_backend *view_backend;
    WebKitWebViewBackend *webkit_backend;
    WebKitWebView *web_view;
    WebKitUserContentManager *content_manager;
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
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "WPE frame slots are unavailable or too small.");
        return FALSE;
    }

    const gint frame_slot = browser->frame_next_slot;
    unsigned char *bgra = browser->frame_slots[frame_slot];
    for (size_t index = 0; index < (size_t)width * (size_t)height; index += 1) {
        const size_t offset = index * 4u;
        bgra[offset + 0] = rgba[offset + 2];
        bgra[offset + 1] = rgba[offset + 1];
        bgra[offset + 2] = rgba[offset + 0];
        bgra[offset + 3] = rgba[offset + 3];
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
        verde_browser_linux_queue_event(browser, VERDE_BROWSER_LINUX_EVENT_FAILED, "Failed to import WPE EGL frame.");
        return;
    }
    browser->last_frame_published_us = now_us;
    if (verde_browser_linux_frame_log_enabled()) {
        fprintf(stderr, "verde-browser-linux-wpe frame seq=%" G_GUINT64_FORMAT " shared_slot=%d size=%dx%d bytes=%zu\n",
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
    const guint32 button_modifier = verde_browser_linux_pointer_button_modifier(button);
    if (down != 0) browser->pointer_modifiers |= button_modifier;
    else browser->pointer_modifiers &= ~button_modifier;
    struct wpe_input_pointer_event event = {
        .type = wpe_input_pointer_event_type_button,
        .time = verde_browser_linux_now_ms(),
        .x = (int)x,
        .y = (int)y,
        .button = button,
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

void verde_browser_linux_free_string(char *payload) {
    g_free(payload);
}
