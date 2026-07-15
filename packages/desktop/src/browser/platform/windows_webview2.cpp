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
#include <functional>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;

template <typename Interface>
struct VerdeWinCallbackIid;

#define VERDE_WIN_CALLBACK_IID(interface_name)                 \
    template <>                                                \
    struct VerdeWinCallbackIid<interface_name> {               \
        static REFIID value() { return IID_##interface_name; } \
    }

VERDE_WIN_CALLBACK_IID(ICoreWebView2ExecuteScriptCompletedHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2SourceChangedEventHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2DocumentTitleChangedEventHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2NavigationCompletedEventHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2WebMessageReceivedEventHandler);
VERDE_WIN_CALLBACK_IID(ICoreWebView2NewWindowRequestedEventHandler);

#undef VERDE_WIN_CALLBACK_IID

// MinGW's compact WRL headers intentionally omit Microsoft::WRL::Callback.
// This small, conventional COM adapter keeps the backend buildable with both
// the MSVC and Zig/MinGW toolchains without changing callback ownership.
template <typename Interface, typename... Args>
class VerdeWinCallback final : public Interface {
    public:
    using Function = std::function<HRESULT(Args...)>;

    explicit VerdeWinCallback(Function function)
        : function_(std::move(function)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (object == nullptr)
            return E_POINTER;
        *object = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, VerdeWinCallbackIid<Interface>::value())) {
            *object = static_cast<Interface *>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return refs_.fetch_add(1, std::memory_order_relaxed) + 1;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = refs_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (remaining == 0)
            delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE Invoke(Args... args) override {
        return function_(args...);
    }

    private:
    std::atomic<ULONG> refs_{1};
    Function function_;
};

using ExecuteScriptCallback =
        VerdeWinCallback<ICoreWebView2ExecuteScriptCompletedHandler, HRESULT,
                         LPCWSTR>;
using EnvironmentCreatedCallback =
        VerdeWinCallback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
                         HRESULT, ICoreWebView2Environment *>;
using ControllerCreatedCallback =
        VerdeWinCallback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
                         HRESULT, ICoreWebView2Controller *>;
using SourceChangedCallback =
        VerdeWinCallback<ICoreWebView2SourceChangedEventHandler, ICoreWebView2 *,
                         ICoreWebView2SourceChangedEventArgs *>;
using TitleChangedCallback =
        VerdeWinCallback<ICoreWebView2DocumentTitleChangedEventHandler,
                         ICoreWebView2 *, IUnknown *>;
using NavigationCompletedCallback =
        VerdeWinCallback<ICoreWebView2NavigationCompletedEventHandler,
                         ICoreWebView2 *,
                         ICoreWebView2NavigationCompletedEventArgs *>;
using WebMessageCallback =
        VerdeWinCallback<ICoreWebView2WebMessageReceivedEventHandler,
                         ICoreWebView2 *,
                         ICoreWebView2WebMessageReceivedEventArgs *>;
using NewWindowCallback =
        VerdeWinCallback<ICoreWebView2NewWindowRequestedEventHandler,
                         ICoreWebView2 *,
                         ICoreWebView2NewWindowRequestedEventArgs *>;

template <typename Callback, typename Function>
static Callback *verde_win_make_callback(Function &&function) {
    return new (std::nothrow)
            Callback(typename Callback::Function(std::forward<Function>(function)));
}

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
    bool source_changed_registered = false;
    bool title_changed_registered = false;
    bool navigation_completed_registered = false;
    bool web_message_registered = false;
    bool new_window_registered = false;
    EventRegistrationToken source_changed_token{};
    EventRegistrationToken title_changed_token{};
    EventRegistrationToken navigation_completed_token{};
    EventRegistrationToken web_message_token{};
    EventRegistrationToken new_window_token{};
    RECT pending_bounds = {0, 0, 1280, 720};
    std::wstring pending_url;
    std::wstring user_data_dir;
};

using CreateCoreWebView2EnvironmentWithOptionsFn = HRESULT(STDAPICALLTYPE *)(
        PCWSTR browserExecutableFolder, PCWSTR userDataFolder,
        ICoreWebView2EnvironmentOptions *environmentOptions,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
                *environmentCreatedHandler);

static void verde_win_queue_event(VerdeWinWebView *browser, int kind,
                                  const std::string &payload = std::string()) {
    if (browser == nullptr || browser->destroying)
        return;
    std::lock_guard<std::mutex> lock(browser->events_mutex);
    browser->events.push_back({kind, payload});
}

static void verde_win_retain(VerdeWinWebView *browser) {
    if (browser == nullptr)
        return;
    browser->refs.fetch_add(1, std::memory_order_relaxed);
}

static void verde_win_release(VerdeWinWebView *browser) {
    if (browser == nullptr)
        return;
    if (browser->refs.fetch_sub(1, std::memory_order_acq_rel) != 1)
        return;
    if (browser->loader != nullptr)
        FreeLibrary(browser->loader);
    const bool com_initialized = browser->com_initialized;
    delete browser;
    if (com_initialized)
        CoUninitialize();
}

static void verde_win_queue_failed(VerdeWinWebView *browser,
                                   const std::string &payload, bool fatal) {
    if (browser == nullptr)
        return;
    if (fatal)
        browser->init_failed = true;
    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_FAILED, payload);
}

static std::string verde_win_format_hresult(const char *context, HRESULT hr) {
    char buffer[192];
    std::snprintf(buffer, sizeof(buffer), "%s HRESULT=0x%08lx.", context,
                  static_cast<unsigned long>(hr));
    return std::string(buffer);
}

static std::string verde_win_format_last_error(const char *context,
                                               DWORD error_code) {
    char buffer[192];
    std::snprintf(buffer, sizeof(buffer), "%s GetLastError=%lu.", context,
                  static_cast<unsigned long>(error_code));
    return std::string(buffer);
}

static void verde_win_queue_opened_if_ready(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->visible || !browser->ready ||
        browser->opened_sent)
        return;
    browser->opened_sent = true;
    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_OPENED);
}

static std::wstring verde_win_utf8_to_wide(const char *value) {
    if (value == nullptr || value[0] == '\0')
        return std::wstring();
    int len =
            MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (len <= 0)
        return std::wstring();
    // Win32 includes the trailing NUL in `len`; reserve it before conversion
    // and remove it from the logical C++ string afterwards.
    std::wstring result(static_cast<size_t>(len), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1,
                            result.data(), len) <= 0)
        return std::wstring();
    result.resize(static_cast<size_t>(len - 1));
    return result;
}

static std::string verde_win_wide_to_utf8(const wchar_t *value) {
    if (value == nullptr || value[0] == L'\0')
        return std::string();
    int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                                  nullptr, 0, nullptr, nullptr);
    if (len <= 0)
        return std::string();
    std::string result(static_cast<size_t>(len), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1,
                            result.data(), len, nullptr, nullptr) <= 0)
        return std::string();
    result.resize(static_cast<size_t>(len - 1));
    return result;
}

static void verde_win_apply_bounds(VerdeWinWebView *browser) {
    if (browser == nullptr || browser->host == nullptr)
        return;
    const RECT bounds = browser->pending_bounds;
    SetWindowPos(browser->host, nullptr, bounds.left, bounds.top,
                 bounds.right - bounds.left, bounds.bottom - bounds.top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    if (browser->controller) {
        RECT webview_bounds = {0, 0, bounds.right - bounds.left,
                               bounds.bottom - bounds.top};
        browser->controller->put_Bounds(webview_bounds);
    }
}

static void verde_win_install_bridge(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->webview)
        return;
    static constexpr wchar_t bridge_script[] =
            L"(function(){"
            L"const "
            L"bridge={postMessage:function(payload){window.chrome.webview."
            L"postMessage(String(payload));}};"
            L"window.__VERDE_BROWSER_IPC__=bridge;"
            L"window.__VERDE_CEF_IPC__=bridge;"
            L"window.verde=bridge;"
            L"})();";
    browser->webview->AddScriptToExecuteOnDocumentCreated(bridge_script, nullptr);
}

static int verde_win_execute_eval(VerdeWinWebView *browser,
                                  const std::wstring &script) {
    if (browser == nullptr || !browser->webview || script.empty())
        return 0;
    verde_win_retain(browser);
    auto *callback = verde_win_make_callback<ExecuteScriptCallback>(
            [browser](HRESULT result, LPCWSTR result_json) -> HRESULT {
                if (browser->destroying) {
                    verde_win_release(browser);
                    return S_OK;
                }
                if (FAILED(result)) {
                    verde_win_queue_failed(
                            browser, "WebView2 JavaScript evaluation failed.", false);
                } else {
                    verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_EVAL_RESULT,
                                          verde_win_wide_to_utf8(result_json != nullptr
                                                                         ? result_json
                                                                         : L"null"));
                }
                verde_win_release(browser);
                return S_OK;
            });
    if (callback == nullptr) {
        verde_win_release(browser);
        return 0;
    }
    HRESULT hr = browser->webview->ExecuteScript(script.c_str(), callback);
    callback->Release();
    if (FAILED(hr))
        verde_win_release(browser);
    return SUCCEEDED(hr) ? 1 : 0;
}

static int verde_win_execute_post_json(VerdeWinWebView *browser,
                                       const std::wstring &payload) {
    if (browser == nullptr || !browser->webview || payload.empty())
        return 0;
    std::wstring script =
            L"(function(){const payload=" + payload +
            L";window.dispatchEvent(new "
            L"MessageEvent('verde-host-message',{data:payload}));})()";
    verde_win_retain(browser);
    auto *callback = verde_win_make_callback<ExecuteScriptCallback>(
            [browser](HRESULT result, LPCWSTR) -> HRESULT {
                if (browser->destroying) {
                    verde_win_release(browser);
                    return S_OK;
                }
                if (FAILED(result)) {
                    verde_win_queue_failed(browser, "WebView2 JSON dispatch failed.",
                                           false);
                }
                verde_win_release(browser);
                return S_OK;
            });
    if (callback == nullptr) {
        verde_win_release(browser);
        return 0;
    }
    HRESULT hr = browser->webview->ExecuteScript(script.c_str(), callback);
    callback->Release();
    if (FAILED(hr))
        verde_win_release(browser);
    return SUCCEEDED(hr) ? 1 : 0;
}

static void verde_win_flush_pending_commands(VerdeWinWebView *browser) {
    if (browser == nullptr || !browser->webview || !browser->document_ready ||
        browser->pending_commands.empty())
        return;
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
    if (browser == nullptr)
        return;
    browser->loader = LoadLibraryW(L"WebView2Loader.dll");
    if (browser->loader == nullptr) {
        verde_win_queue_failed(
                browser,
                verde_win_format_last_error(
                        "WebView2Loader.dll was not found. Reinstall Verde or install the "
                        "Microsoft WebView2 Runtime from "
                        "https://go.microsoft.com/fwlink/p/?LinkId=2124703.",
                        GetLastError()),
                true);
        return;
    }

    auto create_environment =
            reinterpret_cast<CreateCoreWebView2EnvironmentWithOptionsFn>(
                    GetProcAddress(browser->loader,
                                   "CreateCoreWebView2EnvironmentWithOptions"));
    if (create_environment == nullptr) {
        verde_win_queue_failed(browser,
                               "WebView2 loader does not expose "
                               "CreateCoreWebView2EnvironmentWithOptions.",
                               true);
        return;
    }

    verde_win_retain(browser);
    auto *environment_created = verde_win_make_callback<
            EnvironmentCreatedCallback>([browser](HRESULT result,
                                                  ICoreWebView2Environment
                                                          *environment) -> HRESULT {
        if (browser->destroying) {
            verde_win_release(browser);
            return S_OK;
        }
        if (FAILED(result) || environment == nullptr) {
            verde_win_queue_failed(
                    browser,
                    verde_win_format_hresult(
                            "Failed to initialize WebView2 environment. Install or repair "
                            "the Microsoft WebView2 Runtime from "
                            "https://go.microsoft.com/fwlink/p/?LinkId=2124703.",
                            result),
                    true);
            verde_win_release(browser);
            return S_OK;
        }
        verde_win_retain(browser);
        auto *controller_created = verde_win_make_callback<
                ControllerCreatedCallback>([browser](HRESULT controller_result,
                                                     ICoreWebView2Controller
                                                             *controller) -> HRESULT {
            if (browser->destroying) {
                verde_win_release(browser);
                return S_OK;
            }
            if (FAILED(controller_result) || controller == nullptr) {
                verde_win_queue_failed(
                        browser,
                        verde_win_format_hresult("Failed to create WebView2 controller.",
                                                 controller_result),
                        true);
                verde_win_release(browser);
                return S_OK;
            }
            browser->controller = controller;
            controller->get_CoreWebView2(&browser->webview);
            if (!browser->webview) {
                verde_win_queue_failed(
                        browser, "WebView2 controller had no CoreWebView2.", true);
                verde_win_release(browser);
                return S_OK;
            }

            auto *source_changed = verde_win_make_callback<SourceChangedCallback>(
                    [browser](ICoreWebView2 *sender,
                              ICoreWebView2SourceChangedEventArgs *) -> HRESULT {
                        LPWSTR source = nullptr;
                        if (sender != nullptr && SUCCEEDED(sender->get_Source(&source)) &&
                            source != nullptr) {
                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_NAVIGATED,
                                                  verde_win_wide_to_utf8(source));
                            CoTaskMemFree(source);
                        }
                        return S_OK;
                    });
            if (source_changed != nullptr) {
                const HRESULT event_hr = browser->webview->add_SourceChanged(
                        source_changed, &browser->source_changed_token);
                source_changed->Release();
                browser->source_changed_registered = SUCCEEDED(event_hr);
            }

            auto *title_changed = verde_win_make_callback<TitleChangedCallback>(
                    [browser](ICoreWebView2 *sender, IUnknown *) -> HRESULT {
                        LPWSTR title = nullptr;
                        if (sender != nullptr &&
                            SUCCEEDED(sender->get_DocumentTitle(&title)) &&
                            title != nullptr) {
                            verde_win_queue_event(browser,
                                                  VERDE_WIN_BROWSER_EVENT_TITLE_CHANGED,
                                                  verde_win_wide_to_utf8(title));
                            CoTaskMemFree(title);
                        }
                        return S_OK;
                    });
            if (title_changed != nullptr) {
                const HRESULT event_hr = browser->webview->add_DocumentTitleChanged(
                        title_changed, &browser->title_changed_token);
                title_changed->Release();
                browser->title_changed_registered = SUCCEEDED(event_hr);
            }

            auto *navigation_completed =
                    verde_win_make_callback<NavigationCompletedCallback>(
                            [browser](
                                    ICoreWebView2 *,
                                    ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
                                BOOL success = FALSE;
                                if (args != nullptr)
                                    args->get_IsSuccess(&success);
                                if (success) {
                                    browser->document_ready = true;
                                    verde_win_queue_event(
                                            browser, VERDE_WIN_BROWSER_EVENT_DOCUMENT_LOADED);
                                    verde_win_flush_pending_commands(browser);
                                } else {
                                    browser->document_ready = false;
                                    verde_win_queue_failed(browser, "WebView2 navigation failed.",
                                                           false);
                                }
                                return S_OK;
                            });
            if (navigation_completed != nullptr) {
                const HRESULT event_hr = browser->webview->add_NavigationCompleted(
                        navigation_completed, &browser->navigation_completed_token);
                navigation_completed->Release();
                browser->navigation_completed_registered = SUCCEEDED(event_hr);
            }

            auto *web_message = verde_win_make_callback<WebMessageCallback>(
                    [browser](ICoreWebView2 *,
                              ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                        LPWSTR message = nullptr;
                        if (args != nullptr &&
                            SUCCEEDED(args->TryGetWebMessageAsString(&message)) &&
                            message != nullptr) {
                            verde_win_queue_event(browser, VERDE_WIN_BROWSER_EVENT_JS_MESSAGE,
                                                  verde_win_wide_to_utf8(message));
                            CoTaskMemFree(message);
                        }
                        return S_OK;
                    });
            if (web_message != nullptr) {
                const HRESULT event_hr = browser->webview->add_WebMessageReceived(
                        web_message, &browser->web_message_token);
                web_message->Release();
                browser->web_message_registered = SUCCEEDED(event_hr);
            }

            auto *new_window = verde_win_make_callback<NewWindowCallback>(
                    [browser](ICoreWebView2 *sender,
                              ICoreWebView2NewWindowRequestedEventArgs *args) -> HRESULT {
                        if (sender == nullptr || args == nullptr)
                            return E_POINTER;
                        LPWSTR uri = nullptr;
                        const HRESULT uri_hr = args->get_Uri(&uri);
                        if (SUCCEEDED(uri_hr) && uri != nullptr && uri[0] != L'\0') {
                            browser->document_ready = false;
                            sender->Navigate(uri);
                        }
                        if (uri != nullptr)
                            CoTaskMemFree(uri);
                        args->put_Handled(TRUE);
                        return S_OK;
                    });
            if (new_window != nullptr) {
                const HRESULT event_hr = browser->webview->add_NewWindowRequested(
                        new_window, &browser->new_window_token);
                new_window->Release();
                browser->new_window_registered = SUCCEEDED(event_hr);
            }

            if (!browser->source_changed_registered ||
                !browser->title_changed_registered ||
                !browser->navigation_completed_registered ||
                !browser->web_message_registered ||
                !browser->new_window_registered) {
                verde_win_queue_failed(
                        browser, "WebView2 failed to register required browser events.",
                        true);
                verde_win_release(browser);
                return S_OK;
            }

            browser->ready = true;
            browser->init_failed = false;
            controller->put_IsVisible(browser->visible ? TRUE : FALSE);
            verde_win_apply_bounds(browser);
            verde_win_install_bridge(browser);
            verde_win_queue_opened_if_ready(browser);

            if (!browser->pending_url.empty()) {
                browser->webview->Navigate(browser->pending_url.c_str());
                browser->pending_url.clear();
            } else {
                browser->webview->Navigate(L"about:blank");
            }
            verde_win_release(browser);
            return S_OK;
        });
        if (controller_created == nullptr) {
            verde_win_queue_failed(
                    browser,
                    "Out of memory while creating the WebView2 controller callback.",
                    true);
            verde_win_release(browser);
        } else {
            const HRESULT controller_hr = environment->CreateCoreWebView2Controller(
                    browser->host, controller_created);
            controller_created->Release();
            if (FAILED(controller_hr)) {
                verde_win_queue_failed(
                        browser,
                        verde_win_format_hresult("CreateCoreWebView2Controller failed.",
                                                 controller_hr),
                        true);
                verde_win_release(browser);
            }
        }
        verde_win_release(browser);
        return S_OK;
    });
    if (environment_created == nullptr) {
        verde_win_queue_failed(
                browser,
                "Out of memory while creating the WebView2 environment callback.",
                true);
        verde_win_release(browser);
        return;
    }
    const HRESULT hr = create_environment(
            nullptr,
            browser->user_data_dir.empty() ? nullptr : browser->user_data_dir.c_str(),
            nullptr, environment_created);
    environment_created->Release();
    if (FAILED(hr)) {
        verde_win_queue_failed(
                browser,
                verde_win_format_hresult(
                        "CreateCoreWebView2EnvironmentWithOptions failed. Install or "
                        "repair the Microsoft WebView2 Runtime from "
                        "https://go.microsoft.com/fwlink/p/?LinkId=2124703.",
                        hr),
                true);
        verde_win_release(browser);
    }
}

extern "C" void *verde_windows_webview2_create(void *hwnd,
                                               const char *user_data_dir) {
    if (hwnd == nullptr || user_data_dir == nullptr)
        return nullptr;
    HRESULT co_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(co_result) && co_result != RPC_E_CHANGED_MODE)
        return nullptr;

    auto *browser = new VerdeWinWebView();
    browser->com_initialized = SUCCEEDED(co_result);
    browser->parent = static_cast<HWND>(hwnd);
    browser->user_data_dir = verde_win_utf8_to_wide(user_data_dir);
    if (browser->user_data_dir.empty()) {
        verde_win_release(browser);
        return nullptr;
    }
    browser->host = CreateWindowExW(0, L"STATIC", L"Verde WebView2 Host",
                                    WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                                    0, 0, 1280, 720, browser->parent, nullptr,
                                    GetModuleHandleW(nullptr), nullptr);
    if (browser->host == nullptr) {
        verde_win_release(browser);
        return nullptr;
    }
    verde_win_start_webview(browser);
    return browser;
}

extern "C" void verde_windows_webview2_destroy(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr)
        return;
    browser->destroying = true;
    if (browser->webview) {
        if (browser->source_changed_registered)
            browser->webview->remove_SourceChanged(browser->source_changed_token);
        if (browser->title_changed_registered)
            browser->webview->remove_DocumentTitleChanged(
                    browser->title_changed_token);
        if (browser->navigation_completed_registered)
            browser->webview->remove_NavigationCompleted(
                    browser->navigation_completed_token);
        if (browser->web_message_registered)
            browser->webview->remove_WebMessageReceived(browser->web_message_token);
        if (browser->new_window_registered)
            browser->webview->remove_NewWindowRequested(browser->new_window_token);
    }
    browser->source_changed_registered = false;
    browser->title_changed_registered = false;
    browser->navigation_completed_registered = false;
    browser->web_message_registered = false;
    browser->new_window_registered = false;
    if (browser->controller)
        browser->controller->Close();
    browser->webview.Reset();
    browser->controller.Reset();
    if (browser->host != nullptr)
        DestroyWindow(browser->host);
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
    if (browser == nullptr)
        return 0;
    if (browser->init_failed)
        return 0;
    browser->visible = true;
    ShowWindow(browser->host, SW_SHOW);
    if (browser->controller)
        browser->controller->put_IsVisible(TRUE);
    verde_win_queue_opened_if_ready(browser);
    return 1;
}

extern "C" int verde_windows_webview2_hide(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr)
        return 0;
    browser->visible = false;
    if (browser->controller)
        browser->controller->put_IsVisible(FALSE);
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

extern "C" int verde_windows_webview2_set_bounds(void *handle, int x, int y,
                                                 int width, int height) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || width <= 0 || height <= 0)
        return 0;
    POINT origin = {x, y};
    ScreenToClient(browser->parent, &origin);
    browser->pending_bounds = {origin.x, origin.y, origin.x + width,
                               origin.y + height};
    verde_win_apply_bounds(browser);
    return 1;
}

extern "C" int verde_windows_webview2_navigate(void *handle, const char *url) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || url == nullptr)
        return 0;
    std::wstring wide_url = verde_win_utf8_to_wide(url);
    if (wide_url.empty())
        return 0;
    if (!browser->webview) {
        browser->pending_url = wide_url;
        return 1;
    }
    browser->document_ready = false;
    return SUCCEEDED(browser->webview->Navigate(wide_url.c_str())) ? 1 : 0;
}

extern "C" int verde_windows_webview2_eval(void *handle, const char *js) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || js == nullptr || browser->init_failed)
        return 0;
    std::wstring script = verde_win_utf8_to_wide(js);
    if (script.empty())
        return 0;
    if (!browser->webview || !browser->document_ready) {
        browser->pending_commands.push_back({VERDE_WIN_PENDING_EVAL, script});
        return 1;
    }
    return verde_win_execute_eval(browser, script);
}

extern "C" int verde_windows_webview2_post_json(void *handle,
                                                const char *json) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || json == nullptr || browser->init_failed)
        return 0;
    std::wstring payload = verde_win_utf8_to_wide(json);
    if (payload.empty())
        return 0;
    if (!browser->webview || !browser->document_ready) {
        browser->pending_commands.push_back({VERDE_WIN_PENDING_POST_JSON, payload});
        return 1;
    }
    return verde_win_execute_post_json(browser, payload);
}

extern "C" int verde_windows_webview2_go_back(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview)
        return 0;
    BOOL can_go_back = FALSE;
    browser->webview->get_CanGoBack(&can_go_back);
    if (can_go_back)
        browser->webview->GoBack();
    return 1;
}

extern "C" int verde_windows_webview2_go_forward(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview)
        return 0;
    BOOL can_go_forward = FALSE;
    browser->webview->get_CanGoForward(&can_go_forward);
    if (can_go_forward)
        browser->webview->GoForward();
    return 1;
}

extern "C" int verde_windows_webview2_reload(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || !browser->webview)
        return 0;
    return SUCCEEDED(browser->webview->Reload()) ? 1 : 0;
}

extern "C" int verde_windows_webview2_focus(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr)
        return 0;
    if (browser->controller)
        browser->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    SetFocus(browser->host);
    return 1;
}

extern "C" int verde_windows_webview2_blur(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr)
        return 0;
    SetFocus(browser->parent);
    return 1;
}

extern "C" int verde_windows_webview2_has_focus(void *handle) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || browser->host == nullptr) return 0;
    const HWND focused = GetFocus();
    return focused == browser->host || (focused != nullptr && IsChild(browser->host, focused)) ? 1 : 0;
}

extern "C" int verde_windows_webview2_pop_event(void *handle, int *kind,
                                                char **payload) {
    auto *browser = static_cast<VerdeWinWebView *>(handle);
    if (browser == nullptr || kind == nullptr || payload == nullptr)
        return 0;
    std::lock_guard<std::mutex> lock(browser->events_mutex);
    if (browser->events.empty())
        return 0;
    VerdeWinBrowserEvent event = browser->events.front();
    browser->events.erase(browser->events.begin());
    *kind = event.kind;
    *payload = event.payload.empty() ? nullptr : _strdup(event.payload.c_str());
    return 1;
}

extern "C" void verde_windows_webview2_free_string(char *value) { free(value); }

extern "C" int verde_windows_webview2_test_utf8_roundtrip(const char *value) {
    if (value == nullptr) return 0;
    const std::wstring wide = verde_win_utf8_to_wide(value);
    if (value[0] != '\0' && wide.empty()) return 0;
    return verde_win_wide_to_utf8(wide.c_str()) == value ? 1 : 0;
}
