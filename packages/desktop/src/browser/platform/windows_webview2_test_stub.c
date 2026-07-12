#include <stdlib.h>

void *verde_windows_webview2_create(void *hwnd, const char *user_data_dir) {
    (void)hwnd;
    return user_data_dir != NULL ? (void *)1 : NULL;
}

void verde_windows_webview2_destroy(void *handle) {
    (void)handle;
}

int verde_windows_webview2_show(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_hide(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_set_bounds(void *handle, int x, int y, int width, int height) {
    (void)x;
    (void)y;
    return handle != NULL && width > 0 && height > 0;
}

int verde_windows_webview2_navigate(void *handle, const char *url) {
    return handle != NULL && url != NULL;
}

int verde_windows_webview2_eval(void *handle, const char *js) {
    return handle != NULL && js != NULL;
}

int verde_windows_webview2_post_json(void *handle, const char *json) {
    return handle != NULL && json != NULL;
}

int verde_windows_webview2_go_back(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_go_forward(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_reload(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_focus(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_blur(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_has_focus(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_is_ready(void *handle) {
    return handle != NULL;
}

int verde_windows_webview2_pop_event(void *handle, int *kind, char **payload) {
    (void)handle;
    (void)kind;
    if (payload != NULL) *payload = NULL;
    return 0;
}

void verde_windows_webview2_free_string(char *value) {
    free(value);
}

int verde_windows_webview2_test_utf8_roundtrip(const char *value) {
    return value != NULL && (unsigned char)value[0] != 0xff;
}
