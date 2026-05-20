#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <WebView2.h>
#include <windows.h>
#include <wrl.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

enum VerdeWinBrowserEventKind {
    VERDE_WIN_BROWSER_EVENT_OPENED = 1,
    VERDE_WIN_BROWSER_EVENT_CLOSED = 2,
    VERDE_WIN_BROWSER_EVENT_NAVIGATED = 3,
    VERDE_WIN_BROWSER_EVENT_TITLE_CHANGED = 4,
    VERDE_WIN_BROWSER_EVENT_DOCUMENT_LOADED = 5,
    VERDE_WIN_BROWSER_EVENT_JS_MESSAGE = 6,
    VERDE_WIN_BROWSER_EVENT_EVAL_RESULT = 7,
    VERDE_WIN_BROWSER_EVENT_FAILED = 8,
};

struct VerdeWinBrowserEvent {
    int kind;
    std::string payload;
};

enum VerdeWinPendingCommandKind {
    VERDE_WIN_PENDING_EVAL = 1,
    VERDE_WIN_PENDING_POST_JSON = 2,
};

struct VerdeWinPendingCommand {
    int kind;
    std::wstring payload;
};

struct VerdeWinWebView {
    std::atomic<unsigned long> refs{1};
    HWND parent = nullptr;
    HWND host = nullptr;
    HMODULE loader = nullptr;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    std::vector<VerdeWinBrowserEvent> events;
    std::vector<VerdeWinPendingCommand> pending_commands;
    std::mutex events_mutex;
    bool visible = false;
    bool ready = false;
    bool document_ready = false;
    bool init_failed = false;
    bool opened_sent = false;
    bool com_initialized = false;
    bool destroying = false;
    RECT pending_bounds = {0, 0, 1280, 720};
    std::wstring pending_url;
};

using CreateCoreWebView2EnvironmentWithOptionsFn = HRESULT(STDAPICALLTYPE *)(
    PCWSTR browserExecutableFolder,
    PCWSTR userDataFolder,
    ICoreWebView2EnvironmentOptions *environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *environmentCreatedHandler);

static void verde_win_queue_event(VerdeWinWebView *browser, int kind, const std::string &payload = std::string()) {
    if (browser == nullptr || browser->destroying) return;
    std::lock_guard<std::mutex> lock(browser->events_mutex);
    browser->events.push_back({kind, payload});
}

static void verde_win_retain(VerdeWinWebView *browser) {
    if (browser == nullptr) return;
    browser->refs.fetch_add(1, std::memory_order_relaxed);
}

static void verde_win_release(VerdeWinWebView *browser) {
    if (browser == nullptr) return;
    if (browser->refs.fetch_sub(1, std::memory_order_acq_rel) != 1) return;
    if (browser->loader != nullptr) FreeLibrary(browser->loader);
    const bool com_initialized = browser->com_initialized;
    delete browser;
    if (com_initialized) CoUninitialize();
}

static void verde_win_queue_failed(VerdeWinWebView *browser, const std::string &payload, bool fatal) {
    if (browser == nullptr) return;
    if (fatal) browser->init_failed = true;
    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_FAILED, payload);
}

static std::string verde_win_format_hresult(const char *context, HRESULT hr) {
    char buffer[192];
    std::snprintf(buffer, sizeof(buffer), "%s HRESULT=0x%08lx.", context, static_cast<unsigned long>(hr));
    return std::string(buffer);
}

static std::string verde_win_format_last_error(const char *context, DWORD error_code) {
    char buffer[192];
    std::snprintf(buffer, sizeof(buffer), "%s GetLastError=%lu.", context, static_cast<unsigned long>(error_code));
    return std::string(buffer);
}

static void verde_win_queue_opened_if_ready(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->visible || !browser->ready || browser->opened_sent) return;
    browser->opened_sent = true;
    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_OPENED);
}

static std::wstring verde_win_utf8_to_wide(const char *value) {
    if (value == nullptr || value[0] == '\0') return std::wstring();
    int len = MultiByteToWideChar(CP_UTF8, 0, value, -1, nullptr, 0);
    if (len <= 0) return std::wstring();
    std::wstring result(static_cast<size_t>(len - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value, -1, result.data(), len);
    return result;
}

static std::string verde_win_wide_to_utf8(const wchar_t *value) {
    if (value == nullptr || value[0] == L'\0') return std::string();
    int len = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return std::string();
    std::string result(static_cast<size_t>(len - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), len, nullptr, nullptr);
    return result;
}

static void verde_win_apply_bounds(VerdeWinWebView *browser) {
    if (browser == nullptr || browser->host == nullptr) return;
    const RECT bounds = browser->pending_bounds;
    SetWindowPos(
        browser->host,
        nullptr,
        bounds.left,
        bounds.top,
        bounds.right - bounds.left,
        bounds.bottom - bounds.top,
        SWP_NOZORDER | SWP_NOACTIVATE);
    if (browser->controller) {
        RECT webview_bounds = {0, 0, bounds.right - bounds.left, bounds.bottom - bounds.top};
        browser->controller->put_Bounds(webview_bounds);
    }
}

static void verde_win_install_bridge(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->webview) return;
    static constexpr wchar_t bridge_script[] =
        L"(function(){"
        L"const bridge={postMessage:function(payload){window.chrome.webview.postMessage(String(payload));}};"
        L"window.__VERDE_BROWSER_IPC__=bridge;"
        L"window.__VERDE_CEF_IPC__=bridge;"
        L"window.verde=bridge;"
        L"})();";
    browser->webview->AddScriptToExecuteOnDocumentCreated(bridge_script, nullptr);
}

static int verde_win_execute_eval(VerdeWinWebView *browser, const std::wstring &script) {
    if (browser == nullptr || !browser->webview || script.empty()) return 0;
    verde_win_retain(browser);
    HRESULT hr = browser->webview->ExecuteScript(
        script.c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [browser](HRESULT result, LPCWSTR result_json) -> HRESULT {
                if (browser->destroying) {
                    verde_win_release(browser);
                    return S_OK;
                }
                if (FAILED(result)) {
                    verde_win_queue_failed(browser, "WebView2 JavaScript evaluation failed.", false);
                } else {
                    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_EVAL_RESULT, verde_win_wide_to_utf8(result_json != nullptr ? result_json : L"null"));
                }
                verde_win_release(browser);
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) verde_win_release(browser);
    return SUCCEEDED(hr) ? 1 : 0;
}

static int verde_win_execute_post_json(VerdeWinWebView *browser, const std::wstring &payload) {
    if (browser == nullptr || !browser->webview || payload.empty()) return 0;
    std::wstring script = L"(function(){const payload=" + payload + L";window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})()";
    verde_win_retain(browser);
    HRESULT hr = browser->webview->ExecuteScript(
        script.c_str(),
        Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
            [browser](HRESULT result, LPCWSTR) -> HRESULT {
                if (browser->destroying) {
                    verde_win_release(browser);
                    return S_OK;
                }
                if (FAILED(result)) {
                    verde_win_queue_failed(browser, "WebView2 JSON dispatch failed.", false);
                }
                verde_win_release(browser);
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) verde_win_release(browser);
    return SUCCEEDED(hr) ? 1 : 0;
}

static void verde_win_flush_pending_commands(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->webview || !browser->document_ready || browser->pending_commands.empty()) return;
    std::vector<VerdeWinPendingCommand> pending;
    pending.swap(browser->pending_commands);
    for (const auto &command : pending) {
        switch (command.kind) {
        case VERDE_WIN_PENDING_EVAL:
            (void)verde_win_execute_eval(browser, command.payload);
            break;
        case VERDE_WIN_PENDING_POST_JSON:
            (void)verde_win_execute_post_json(browser, command.payload);
            break;
        default:
            break;
        }
    }
}

static void verde_win_start_webview(VerdeWinWebView *browser) {
    if (browser == nullptr) return;
    browser->loader = LoadLibraryW(L"WebView2Loader.dll");
    if (browser->loader == nullptr) {
        verde_win_queue_failed(
            browser,
            verde_win_format_last_error(
                "WebView2Loader.dll was not found. Ship WebView2Loader.dll next to verde.exe or install the Microsoft WebView2 Runtime.",
                GetLastError()),
            true);
        return;
    }

    auto create_environment = reinterpret_cast<CreateCoreWebView2EnvironmentWithOptionsFn>(
        GetProcAddress(browser->loader, "CreateCoreWebView2EnvironmentWithOptions"));
    if (create_environment == nullptr) {
        verde_win_queue_failed(browser, "WebView2 loader does not expose CreateCoreWebView2EnvironmentWithOptions.", true);
        return;
    }

    verde_win_retain(browser);
    HRESULT hr = create_environment(
        nullptr,
        nullptr,
        nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [browser](HRESULT result, ICoreWebView2Environment *environment) -> HRESULT {
                if (browser->destroying) {
                    verde_win_release(browser);
                    return S_OK;
                }
                if (FAILED(result) || environment == nullptr) {
                    verde_win_queue_failed(
                        browser,
                        verde_win_format_hresult(
                            "Failed to initialize WebView2 environment. Install or repair the Microsoft WebView2 Runtime.",
                            result),
                        true);
                    verde_win_release(browser);
                    return S_OK;
                }
                verde_win_retain(browser);
                HRESULT controller_hr = environment->CreateCoreWebView2Controller(
                    browser->host,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [browser](HRESULT controller_result, ICoreWebView2Controller *controller) -> HRESULT {
                            if (browser->destroying) {
                                verde_win_release(browser);
                                return S_OK;
                            }
                            if (FAILED(controller_result) || controller == nullptr) {
                                verde_win_queue_failed(
                                    browser,
                                    verde_win_format_hresult("Failed to create WebView2 controller.", controller_result),
                                    true);
                                verde_win_release(browser);
                                return S_OK;
                            }
                            browser->controller = controller;
                            controller->get_CoreWebView2(&browser->webview);
                            if (!browser->webview) {
                                verde_win_queue_failed(browser, "WebView2 controller had no CoreWebView2.", true);
                                verde_win_release(browser);
                                return S_OK;
                            }

                            browser->ready = true;
                            browser->init_failed = false;
                            controller->put_IsVisible(browser->visible ? TRUE : FALSE);
                            verde_win_apply_bounds(browser);
                            verde_win_install_bridge(browser);
                            verde_win_queue_opened_if_ready(browser);

                            browser->webview->add_SourceChanged(
                                Callback<ICoreWebView2SourceChangedEventHandler>(
                                    [browser](ICoreWebView2 *sender, ICoreWebView2SourceChangedEventArgs *) -> HRESULT {
                                        LPWSTR source = nullptr;
                                        if (sender != nullptr && SUCCEEDED(sender->get_Source(&source)) && source != nullptr) {
                                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_NAVIGATED, verde_win_wide_to_utf8(source));
                                            CoTaskMemFree(source);
                                        }
                                        return S_OK;
                                    })
                                    .Get(),
                                nullptr);
                            browser->webview->add_DocumentTitleChanged(
                                Callback<ICoreWebView2DocumentTitleChangedEventHandler>(
                                    [browser](ICoreWebView2 *sender, IUnknown *) -> HRESULT {
                                        LPWSTR title = nullptr;
                                        if (sender != nullptr && SUCCEEDED(sender->get_DocumentTitle(&title)) && title != nullptr) {
                                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_TITLE_CHANGED, verde_win_wide_to_utf8(title));
                                            CoTaskMemFree(title);
                                        }
                                        return S_OK;
                                    })
                                    .Get(),
                                nullptr);
                            browser->webview->add_NavigationCompleted(
                                Callback<ICoreWebView2NavigationCompletedEventHandler>(
                                    [browser](ICoreWebView2 *, ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                                        BOOL success = FALSE;
                                        if (args != nullptr) args->get_IsSuccess(&success);
                                        if (success) {
                                            browser->document_ready = true;
                                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_DOCUMENT_LOADED);
                                            verde_win_flush_pending_commands(browser);
                                        } else {
                                            browser->document_ready = false;
                                            verde_win_queue_failed(browser, "WebView2 navigation failed.", false);
                                        }
                                        return S_OK;
                                    })
                                    .Get(),
                                nullptr);
                            browser->webview->add_WebMessageReceived(
                                Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                    [browser](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                                        LPWSTR message = nullptr;
                                        if (args != nullptr && SUCCEEDED(args->TryGetWebMessageAsString(&message)) && message != nullptr) {
                                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_JS_MESSAGE, verde_win_wide_to_utf8(message));
                                            CoTaskMemFree(message);
                                        }
                                        return S_OK;
                                    })
                                    .Get(),
                                nullptr);

                            if (!browser->pending_url.empty()) {
                                browser->webview->Navigate(browser->pending_url.c_str());
                                browser->pending_url.clear();
                            } else {
                                browser->webview->Navigate(L"about:blank");
                            }
                            verde_win_release(browser);
                            return S_OK;
                        })
                        .Get());
                if (FAILED(controller_hr)) {
                    verde_win_queue_failed(
                        browser,
                        verde_win_format_hresult("CreateCoreWebView2Controller failed.", controller_hr),
                        true);
                    verde_win_release(browser);
                }
                verde_win_release(browser);
                return S_OK;
            })
            .Get());
    if (FAILED(hr)) {
        verde_win_queue_failed(
            browser,
            verde_win_format_hresult(
                "CreateCoreWebView2EnvironmentWithOptions failed. Install or repair the Microsoft WebView2 Runtime.",
                hr),
            true);
        verde_win_release(browser);
    }
}

extern "C" void *verde_windows_webview2_create(void *hwnd) {
    if (hwnd == nullptr) return nullptr;
    HRESULT co_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(co_result) && co_result != RPC_E_CHANGED_MODE) return nullptr;

    auto *browser = new VerdeWinWebView();
    browser->com_initialized = SUCCEEDED(co_result);
    browser->parent = static_cast<HWND>(hwnd);
    browser->host = CreateWindowExW(
        0,
        L"STATIC",
        L"Verde WebView2 Host",
        WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        0,
        0,
        1280,
        720,
        browser->parent,
        nullptr,
        GetModuleHandleW(nullptr),
        nullptr);
    if (browser->host == nullptr) {
        verde_win_release(browser);
        return nullptr;
    }
    verde_win_start_webview(browser);
    return browser;
}

extern "C" void verde_windows_webview2_destroy(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr) return;
    browser->destroying = true;
    if (browser->controller) browser->controller->Close();
    browser->webview.Reset();
    browser->controller.Reset();
    if (browser->host != nullptr) DestroyWindow(browser->host);
    browser->host = nullptr;
    browser->parent = nullptr;
    browser->ready = false;
    browser->document_ready = false;
    browser->pending_commands.clear();
    browser->pending_url.clear();
    verde_win_release(browser);
}

extern "C" int verde_windows_webview2_show(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr) return 0;
    if (browser->init_failed) return 0;
    browser->visible = true;
    ShowWindow(browser->host, SW_SHOW);
    if (browser->controller) browser->controller->put_IsVisible(TRUE);
    verde_win_queue_opened_if_ready(browser);
    return 1;
}

extern "C" int verde_windows_webview2_hide(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr) return 0;
    browser->visible = false;
    if (browser->controller) browser->controller->put_IsVisible(FALSE);
    ShowWindow(browser->host, SW_HIDE);
    if (browser->opened_sent) {
        browser->opened_sent = false;
        verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_CLOSED);
    }
    return 1;
}

extern "C" int verde_windows_webview2_is_ready(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    return browser != nullptr && browser->ready && !browser->init_failed ? 1 : 0;
}

extern "C" int verde_windows_webview2_set_bounds(void *handle, int x, int y, int width, int height) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || width <= 0 || height <= 0) return 0;
    POINT origin = {x, y};
    ScreenToClient(browser->parent, &origin);
    browser->pending_bounds = {origin.x, origin.y, origin.x + width, origin.y + height};
    verde_win_apply_bounds(browser);
    return 1;
}

extern "C" int verde_windows_webview2_navigate(void *handle, const char *url) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || url == nullptr) return 0;
    std::wstring wide_url = verde_win_utf8_to_wide(url);
    if (wide_url.empty()) return 0;
    if (!browser->webview) {
        browser->pending_url = wide_url;
        return 1;
    }
    browser->document_ready = false;
    return SUCCEEDED(browser->webview->Navigate(wide_url.c_str())) ? 1 : 0;
}

extern "C" int verde_windows_webview2_eval(void *handle, const char *js) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || js == nullptr || browser->init_failed) return 0;
    std::wstring script = verde_win_utf8_to_wide(js);
    if (script.empty()) return 0;
    if (!browser->webview || !browser->document_ready) {
        browser->pending_commands.push_back({VERDE_WIN_PENDING_EVAL, script});
        return 1;
    }
    return verde_win_execute_eval(browser, script);
}

extern "C" int verde_windows_webview2_post_json(void *handle, const char *json) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || json == nullptr || browser->init_failed) return 0;
    std::wstring payload = verde_win_utf8_to_wide(json);
    if (payload.empty()) return 0;
    if (!browser->webview || !browser->document_ready) {
        browser->pending_commands.push_back({VERDE_WIN_PENDING_POST_JSON, payload});
        return 1;
    }
    return verde_win_execute_post_json(browser, payload);
}

extern "C" int verde_windows_webview2_go_back(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview) return 0;
    BOOL can_go_back = FALSE;
    browser->webview->get_CanGoBack(&can_go_back);
    if (can_go_back) browser->webview->GoBack();
    return 1;
}

extern "C" int verde_windows_webview2_go_forward(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview) return 0;
    BOOL can_go_forward = FALSE;
    browser->webview->get_CanGoForward(&can_go_forward);
    if (can_go_forward) browser->webview->GoForward();
    return 1;
}

extern "C" int verde_windows_webview2_reload(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview) return 0;
    return SUCCEEDED(browser->webview->Reload()) ? 1 : 0;
}

extern "C" int verde_windows_webview2_focus(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr) return 0;
    if (browser->controller) browser->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    SetFocus(browser->host);
    return 1;
}

extern "C" int verde_windows_webview2_blur(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr) return 0;
    SetFocus(browser->parent);
    return 1;
}

extern "C" int verde_windows_webview2_pop_event(void *handle, int *kind, char **payload) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || kind == nullptr || payload == nullptr) return 0;
    std::lock_guard<std::mutex> lock(browser->events_mutex);
    if (browser->events.empty()) return 0;
    VerdeWinBrowserEvent event = browser->events.front();
    browser->events.erase(browser->events.begin());
    *kind = event.kind;
    *payload = event.payload.empty() ? nullptr : _strdup(event.payload.c_str());
    return 1;
}

extern "C" void verde_windows_webview2_free_string(char *value) {
    free(value);
}
