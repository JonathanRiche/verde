#include <stdlib.h>

void *verde_macos_webview_create(void *ns_window) {
    (void)ns_window;
    return NULL;
}

void verde_macos_app_configure_foreground(void) {
}

void verde_macos_webview_destroy(void *handle) {
    (void)handle;
}

int verde_macos_webview_show(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_hide(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_set_bounds(void *handle, int x, int y, int width, int height) {
    (void)handle;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    return 0;
}

int verde_macos_webview_navigate(void *handle, const char *url) {
    (void)handle;
    (void)url;
    return 0;
}

int verde_macos_webview_eval(void *handle, const char *js) {
    (void)handle;
    (void)js;
    return 0;
}

int verde_macos_webview_post_json(void *handle, const char *json) {
    (void)handle;
    (void)json;
    return 0;
}

int verde_macos_webview_go_back(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_go_forward(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_reload(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_focus(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_blur(void *handle) {
    (void)handle;
    return 0;
}

int verde_macos_webview_has_focus(void *handle) {
    (void)handle;
    return 0;
}

char *verde_macos_webview_appkit_diagnostics(void *handle) {
    (void)handle;
    return NULL;
}

int verde_macos_webview_pop_event(void *handle, int *kind, char **payload) {
    (void)handle;
    (void)kind;
    (void)payload;
    return 0;
}

void verde_macos_webview_free_string(char *value) {
    free(value);
}
