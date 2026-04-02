#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <mutex>
#include <signal.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string>
#include <sys/syscall.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_load_handler.h"
#include "include/internal/cef_linux.h"
#include "include/wrapper/cef_helpers.h"

namespace {

bool isOomAdjustPath(const char* pathname) {
  if (pathname == nullptr) {
    return false;
  }

  const size_t length = std::strlen(pathname);
  if (length <= 6 || std::strncmp(pathname, "/proc/", 6) != 0) {
    return false;
  }
  if (length >= std::strlen("/oom_score_adj") &&
      std::strcmp(pathname + length - std::strlen("/oom_score_adj"),
                  "/oom_score_adj") == 0) {
    return true;
  }
  return length >= std::strlen("/oom_adj") &&
         std::strcmp(pathname + length - std::strlen("/oom_adj"), "/oom_adj") ==
             0;
}

int openViaSyscall(int dirfd, const char* pathname, int flags, mode_t mode) {
  return static_cast<int>(syscall(SYS_openat, dirfd, pathname, flags, mode));
}

int closeViaSyscall(int fd) {
  return static_cast<int>(syscall(SYS_close, fd));
}

uint32_t eventFlagsFromModifiers(unsigned int modifiers) {
  uint32_t flags = EVENTFLAG_NONE;
  if ((modifiers & (1u << 0)) != 0) flags |= EVENTFLAG_SHIFT_DOWN;
  if ((modifiers & (1u << 1)) != 0) flags |= EVENTFLAG_CONTROL_DOWN;
  if ((modifiers & (1u << 2)) != 0) flags |= EVENTFLAG_ALT_DOWN;
  if ((modifiers & (1u << 3)) != 0) flags |= EVENTFLAG_COMMAND_DOWN;
  return flags;
}

CefBrowserHost::MouseButtonType mouseButtonType(unsigned int button) {
  switch (button) {
    case 1:
      return MBT_LEFT;
    case 2:
      return MBT_MIDDLE;
    case 3:
      return MBT_RIGHT;
    default:
      return MBT_LEFT;
  }
}

uint32_t mouseButtonFlag(unsigned int button) {
  switch (button) {
    case 1:
      return EVENTFLAG_LEFT_MOUSE_BUTTON;
    case 2:
      return EVENTFLAG_MIDDLE_MOUSE_BUTTON;
    case 3:
      return EVENTFLAG_RIGHT_MOUSE_BUTTON;
    default:
      return EVENTFLAG_NONE;
  }
}

CefMouseEvent makeMouseEvent(double x, double y, unsigned int modifiers) {
  CefMouseEvent event{};
  event.x = static_cast<int>(x);
  event.y = static_cast<int>(y);
  event.modifiers = eventFlagsFromModifiers(modifiers);
  return event;
}

enum VerdeEventKind {
  VERDE_EVENT_NONE = 0,
  VERDE_EVENT_OPENED = 1,
  VERDE_EVENT_CLOSED = 2,
  VERDE_EVENT_NAVIGATED = 3,
  VERDE_EVENT_TITLE_CHANGED = 4,
  VERDE_EVENT_FAILED = 5,
};

struct VerdeEvent {
  int kind = VERDE_EVENT_NONE;
  std::string payload;
};

class VerdeApp;
class VerdeClient;

struct VerdeRuntime {
  bool initialized = false;
  int width = 1;
  int height = 1;
  int frame_width = 0;
  int frame_height = 0;
  bool frame_dirty = false;
  std::mutex frame_mutex;
  std::vector<unsigned char> frame;
  std::deque<VerdeEvent> events;
  CefRefPtr<VerdeApp> app;
  CefRefPtr<VerdeClient> client;
  CefRefPtr<CefBrowser> browser;
};

VerdeRuntime g_runtime;

void pushEvent(int kind, const std::string& payload) {
  g_runtime.events.push_back(VerdeEvent{kind, payload});
}

void pushFailure(const std::string& message) {
  pushEvent(VERDE_EVENT_FAILED, message);
}

void appendSwitchIfMissing(CefRefPtr<CefCommandLine> command_line,
                           const char* name) {
  if (!command_line || name == nullptr) {
    return;
  }
  if (!command_line->HasSwitch(name)) {
    command_line->AppendSwitch(name);
  }
}

class VerdeApp final : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    (void)process_type;
    appendSwitchIfMissing(command_line, "no-sandbox");
  }

 private:
  IMPLEMENT_REFCOUNTING(VerdeApp);
};

class VerdeClient final : public CefClient,
                          public CefRenderHandler,
                          public CefContextMenuHandler,
                          public CefDisplayHandler,
                          public CefLoadHandler,
                          public CefLifeSpanHandler {
 public:
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    (void)browser;
    (void)frame;
    (void)params;
    model->Clear();
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    (void)browser;
    (void)frame;
    (void)source_process;
    (void)message;
    return false;
  }

  bool GetRootScreenRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    (void)browser;
    rect = CefRect(0, 0, std::max(g_runtime.width, 1), std::max(g_runtime.height, 1));
    return true;
  }

  void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
    (void)browser;
    rect = CefRect(0, 0, std::max(g_runtime.width, 1), std::max(g_runtime.height, 1));
  }

  bool GetScreenPoint(CefRefPtr<CefBrowser> browser,
                      int view_x,
                      int view_y,
                      int& screen_x,
                      int& screen_y) override {
    (void)browser;
    screen_x = view_x;
    screen_y = view_y;
    return true;
  }

  bool GetScreenInfo(CefRefPtr<CefBrowser> browser,
                     CefScreenInfo& screen_info) override {
    (void)browser;
    const CefRect rect(0, 0, std::max(g_runtime.width, 1), std::max(g_runtime.height, 1));
    screen_info.Set(1.0f, 32, 8, false, rect, rect);
    return true;
  }

  void OnPaint(CefRefPtr<CefBrowser> browser,
               PaintElementType type,
               const RectList& dirty_rects,
               const void* buffer,
               int width,
               int height) override {
    (void)browser;
    (void)dirty_rects;
    if (type != PET_VIEW || buffer == nullptr || width <= 0 || height <= 0) {
      return;
    }

    const size_t pixel_len =
        static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    std::lock_guard<std::mutex> lock(g_runtime.frame_mutex);
    g_runtime.frame.resize(pixel_len);
    std::memcpy(g_runtime.frame.data(), buffer, pixel_len);
    g_runtime.frame_width = width;
    g_runtime.frame_height = height;
    g_runtime.frame_dirty = true;
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    (void)browser;
    if (frame && frame->IsMain()) {
      pushEvent(VERDE_EVENT_NAVIGATED, url.ToString());
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    (void)browser;
    pushEvent(VERDE_EVENT_TITLE_CHANGED, title.ToString());
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode error_code,
                   const CefString& error_text,
                   const CefString& failed_url) override {
    (void)browser;
    (void)frame;
    (void)error_code;
    pushFailure(error_text.ToString() + " (" + failed_url.ToString() + ")");
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popup_features,
                     CefWindowInfo& window_info,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    (void)browser;
    (void)frame;
    (void)popup_id;
    (void)target_url;
    (void)target_frame_name;
    (void)target_disposition;
    (void)user_gesture;
    (void)popup_features;
    (void)window_info;
    (void)client;
    (void)settings;
    (void)extra_info;
    (void)no_javascript_access;
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    if (!g_runtime.browser) {
      g_runtime.browser = browser;
    }
    pushEvent(VERDE_EVENT_OPENED, {});
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    (void)browser;
    return false;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    if (g_runtime.browser && g_runtime.browser->IsSame(browser)) {
      g_runtime.browser = nullptr;
    }
    pushEvent(VERDE_EVENT_CLOSED, {});
  }

 private:
  IMPLEMENT_REFCOUNTING(VerdeClient);
};

void sendFocusToBrowser() {
  if (!g_runtime.browser) {
    return;
  }
  auto host = g_runtime.browser->GetHost();
  if (!host) {
    return;
  }
  host->SetFocus(true);
}

}  // namespace

extern "C" int open(const char* pathname, int flags, ...) {
  mode_t mode = 0;
  if ((flags & O_CREAT) != 0) {
    va_list args;
    va_start(args, flags);
    mode = static_cast<mode_t>(va_arg(args, int));
    va_end(args);
  }
  const char* target = isOomAdjustPath(pathname) ? "/dev/null" : pathname;
  return openViaSyscall(AT_FDCWD, target, flags, mode);
}

extern "C" int openat(int dirfd, const char* pathname, int flags, ...) {
  mode_t mode = 0;
  if ((flags & O_CREAT) != 0) {
    va_list args;
    va_start(args, flags);
    mode = static_cast<mode_t>(va_arg(args, int));
    va_end(args);
  }
  const char* target = isOomAdjustPath(pathname) ? "/dev/null" : pathname;
  return openViaSyscall(dirfd, target, flags, mode);
}

extern "C" int close(int fd) {
  return closeViaSyscall(fd);
}

extern "C" bool _ZN4base14AdjustOOMScoreEii(int process, int score) {
  (void)process;
  (void)score;
  return true;
}

extern "C" int verde_cef_execute_subprocess(int argc,
                                             const char* const* argv) {
  std::fprintf(stderr, "verde-cef: execute_subprocess start argc=%d\n", argc);
  std::fflush(stderr);
  CefMainArgs main_args(argc, const_cast<char**>(argv));
  CefRefPtr<VerdeApp> app(new VerdeApp());
  const int result = CefExecuteProcess(main_args, app, nullptr);
  std::fprintf(stderr, "verde-cef: execute_subprocess result=%d\n", result);
  std::fflush(stderr);
  return result;
}

extern "C" int verde_cef_initialize(int argc,
                                     const char* const* argv,
                                     const char* subprocess_path,
                                     const char* resources_dir,
                                     const char* locales_dir) {
  if (g_runtime.initialized) {
    return 1;
  }

  std::fprintf(stderr,
               "verde-cef: initialize start subprocess=%s resources=%s locales=%s\n",
               subprocess_path != nullptr ? subprocess_path : "(null)",
               resources_dir != nullptr ? resources_dir : "(null)",
               locales_dir != nullptr ? locales_dir : "(null)");
  std::fflush(stderr);

  CefMainArgs main_args(argc, const_cast<char**>(argv));
  CefSettings settings;
  settings.no_sandbox = true;
  settings.multi_threaded_message_loop = false;
  settings.external_message_pump = false;
  settings.windowless_rendering_enabled = true;
  settings.log_severity = LOGSEVERITY_INFO;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  const std::string cache_root =
      std::string(resources_dir != nullptr ? resources_dir : "/tmp") + "/verde-cef-cache";
  const std::string cache_path = cache_root + "/profile";
  CefString(&settings.browser_subprocess_path) = subprocess_path != nullptr ? subprocess_path : "";
  CefString(&settings.resources_dir_path) = resources_dir != nullptr ? resources_dir : "";
  CefString(&settings.locales_dir_path) = locales_dir != nullptr ? locales_dir : "";
  CefString(&settings.root_cache_path) = cache_root;
  CefString(&settings.cache_path) = cache_path;
  CefString(&settings.log_file) = "/tmp/verde-browser-cef.log";

  CefRefPtr<VerdeApp> app(new VerdeApp());
  const bool ok = CefInitialize(main_args, settings, app, nullptr);

  std::fprintf(stderr, "verde-cef: initialize result=%d\n", ok ? 1 : 0);
  std::fflush(stderr);

  if (!ok) {
    return 0;
  }

  g_runtime.initialized = true;
  g_runtime.app = app;
  g_runtime.client = new VerdeClient();
  return 1;
}

extern "C" int verde_cef_is_initialized() {
  return g_runtime.initialized ? 1 : 0;
}

extern "C" void verde_cef_shutdown() {
  if (!g_runtime.initialized) {
    return;
  }

  if (g_runtime.browser) {
    g_runtime.browser->GetHost()->CloseBrowser(true);
    for (int iteration = 0; iteration < 100 && g_runtime.browser; ++iteration) {
      CefDoMessageLoopWork();
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }

  g_runtime.browser = nullptr;
  g_runtime.client = nullptr;
  g_runtime.app = nullptr;
  CefShutdown();

  {
    std::lock_guard<std::mutex> lock(g_runtime.frame_mutex);
    g_runtime.frame.clear();
    g_runtime.frame_width = 0;
    g_runtime.frame_height = 0;
    g_runtime.frame_dirty = false;
  }
  g_runtime.events.clear();
  g_runtime.initialized = false;
}

extern "C" void verde_cef_do_message_loop_work() {
  if (!g_runtime.initialized) {
    return;
  }
  CefDoMessageLoopWork();
}

extern "C" int verde_cef_has_browser() {
  return g_runtime.browser ? 1 : 0;
}

extern "C" int verde_cef_create_browser(int width,
                                         int height,
                                         const char* url) {
  if (!g_runtime.initialized || !g_runtime.client) {
    pushFailure("CEF runtime is not initialized.");
    return 0;
  }

  std::fprintf(stderr, "verde-cef: create_browser start url=%s\n",
               url != nullptr ? url : "(null)");
  std::fflush(stderr);

  if (g_runtime.browser) {
    return 1;
  }

  g_runtime.width = std::max(width, 1);
  g_runtime.height = std::max(height, 1);

  CefWindowInfo window_info;
  window_info.SetAsWindowless(0);
  window_info.bounds = CefRect(0, 0, g_runtime.width, g_runtime.height);

  CefBrowserSettings browser_settings;
  browser_settings.windowless_frame_rate = 60;
  browser_settings.background_color = CefColorSetARGB(255, 255, 255, 255);

  auto browser = CefBrowserHost::CreateBrowserSync(
      window_info,
      g_runtime.client,
      url != nullptr ? url : "about:blank",
      browser_settings,
      nullptr,
      nullptr);
  if (!browser) {
    pushFailure("CEF failed to create the off-screen browser.");
    return 0;
  }

  if (!g_runtime.browser) {
    g_runtime.browser = browser;
  }
  browser->GetHost()->SetWindowlessFrameRate(60);
  browser->GetHost()->WasResized();
  browser->GetHost()->Invalidate(PET_VIEW);

  std::fprintf(stderr, "verde-cef: create_browser ready id=%d\n",
               browser->GetIdentifier());
  std::fflush(stderr);
  return 1;
}

extern "C" void verde_cef_resize_browser(int width, int height) {
  g_runtime.width = std::max(width, 1);
  g_runtime.height = std::max(height, 1);

  if (!g_runtime.browser) {
    return;
  }

  auto host = g_runtime.browser->GetHost();
  host->NotifyScreenInfoChanged();
  host->WasResized();
  host->Invalidate(PET_VIEW);
}

extern "C" int verde_cef_navigate(const char* url) {
  if (!g_runtime.browser || url == nullptr) {
    return 0;
  }
  auto frame = g_runtime.browser->GetMainFrame();
  if (!frame) {
    return 0;
  }
  frame->LoadURL(url);
  return 1;
}

extern "C" int verde_cef_eval(const char* js) {
  if (!g_runtime.browser || js == nullptr) {
    return 0;
  }
  auto frame = g_runtime.browser->GetMainFrame();
  if (!frame) {
    return 0;
  }
  frame->ExecuteJavaScript(js, "app://verde-eval.js", 1);
  return 1;
}

extern "C" int verde_cef_post_json(const char* json) {
  if (!g_runtime.browser || json == nullptr) {
    return 0;
  }

  std::string script =
      "(function(){const payload=" + std::string(json) +
      ";window.dispatchEvent(new MessageEvent('verde-host-message',{data:payload}));})();";
  return verde_cef_eval(script.c_str());
}

extern "C" int verde_cef_send_mouse_move(double x,
                                          double y,
                                          unsigned int modifiers) {
  if (!g_runtime.browser) {
    return 0;
  }

  sendFocusToBrowser();
  const CefMouseEvent event = makeMouseEvent(x, y, modifiers);
  g_runtime.browser->GetHost()->SendMouseMoveEvent(event, false);
  return 1;
}

extern "C" int verde_cef_send_mouse_click(double x,
                                           double y,
                                           unsigned int button,
                                           int mouse_up,
                                           unsigned int modifiers) {
  if (!g_runtime.browser || button == 0) {
    return 0;
  }

  sendFocusToBrowser();
  CefMouseEvent event = makeMouseEvent(x, y, modifiers);
  event.modifiers |= mouseButtonFlag(button);
  g_runtime.browser->GetHost()->SendMouseClickEvent(
      event, mouseButtonType(button), mouse_up != 0, 1);
  return 1;
}

extern "C" int verde_cef_send_mouse_wheel(double x,
                                           double y,
                                           double delta_x,
                                           double delta_y,
                                           unsigned int modifiers) {
  if (!g_runtime.browser) {
    return 0;
  }

  sendFocusToBrowser();
  const CefMouseEvent event = makeMouseEvent(x, y, modifiers);
  const int wheel_x = static_cast<int>(delta_x * 120.0);
  const int wheel_y = static_cast<int>(-delta_y * 120.0);
  g_runtime.browser->GetHost()->SendMouseWheelEvent(event, wheel_x, wheel_y);
  return 1;
}

extern "C" int verde_cef_send_key_event(unsigned int key_code,
                                         int pressed,
                                         unsigned int modifiers) {
  if (!g_runtime.browser || key_code == 0) {
    return 0;
  }

  sendFocusToBrowser();

  CefKeyEvent event;
  event.type = pressed ? KEYEVENT_RAWKEYDOWN : KEYEVENT_KEYUP;
  event.modifiers = eventFlagsFromModifiers(modifiers);
  event.windows_key_code = static_cast<int>(key_code);
  event.native_key_code = static_cast<int>(key_code);
  event.character = static_cast<char16_t>(key_code);
  event.unmodified_character = static_cast<char16_t>(key_code);
  event.focus_on_editable_field = true;
  g_runtime.browser->GetHost()->SendKeyEvent(event);
  return 1;
}

extern "C" int verde_cef_send_text_input(const char* text,
                                          unsigned int modifiers) {
  if (!g_runtime.browser || text == nullptr || text[0] == '\0') {
    return 0;
  }

  sendFocusToBrowser();

  for (const unsigned char* cursor =
           reinterpret_cast<const unsigned char*>(text);
       *cursor != '\0'; cursor += 1) {
    CefKeyEvent event;
    event.type = KEYEVENT_CHAR;
    event.modifiers = eventFlagsFromModifiers(modifiers);
    event.windows_key_code = static_cast<int>(*cursor);
    event.native_key_code = static_cast<int>(*cursor);
    event.character = static_cast<char16_t>(*cursor);
    event.unmodified_character = static_cast<char16_t>(*cursor);
    event.focus_on_editable_field = true;
    g_runtime.browser->GetHost()->SendKeyEvent(event);
  }

  return 1;
}

extern "C" void verde_cef_get_frame(const unsigned char** pixels,
                                     size_t* len,
                                     int* width,
                                     int* height,
                                     int* dirty) {
  std::lock_guard<std::mutex> lock(g_runtime.frame_mutex);
  if (pixels != nullptr) {
    *pixels = g_runtime.frame.empty() ? nullptr : g_runtime.frame.data();
  }
  if (len != nullptr) {
    *len = g_runtime.frame.size();
  }
  if (width != nullptr) {
    *width = g_runtime.frame_width;
  }
  if (height != nullptr) {
    *height = g_runtime.frame_height;
  }
  if (dirty != nullptr) {
    *dirty = g_runtime.frame_dirty ? 1 : 0;
  }
}

extern "C" void verde_cef_clear_frame_dirty() {
  std::lock_guard<std::mutex> lock(g_runtime.frame_mutex);
  g_runtime.frame_dirty = false;
}

extern "C" int verde_cef_copy_frame(void* dest,
                                     size_t cap,
                                     size_t* out_len,
                                     int* width,
                                     int* height) {
  std::lock_guard<std::mutex> lock(g_runtime.frame_mutex);

  if (!g_runtime.frame_dirty || g_runtime.frame.empty()) {
    if (out_len != nullptr) *out_len = 0;
    if (width != nullptr) *width = 0;
    if (height != nullptr) *height = 0;
    return 0;
  }
  if (dest == nullptr || cap < g_runtime.frame.size()) {
    return -1;
  }

  std::memcpy(dest, g_runtime.frame.data(), g_runtime.frame.size());
  if (out_len != nullptr) *out_len = g_runtime.frame.size();
  if (width != nullptr) *width = g_runtime.frame_width;
  if (height != nullptr) *height = g_runtime.frame_height;
  g_runtime.frame_dirty = false;
  return 1;
}

extern "C" int verde_cef_pop_event(int* kind,
                                    char* buffer,
                                    size_t cap,
                                    size_t* out_len) {
  if (g_runtime.events.empty()) {
    return 0;
  }

  VerdeEvent event = std::move(g_runtime.events.front());
  g_runtime.events.pop_front();

  if (kind != nullptr) {
    *kind = event.kind;
  }

  if (out_len != nullptr) {
    *out_len = event.payload.size();
  }

  if (buffer != nullptr && cap > 0) {
    const size_t copy_len = std::min(event.payload.size(), cap - 1);
    if (copy_len > 0) {
      std::memcpy(buffer, event.payload.data(), copy_len);
    }
    buffer[copy_len] = '\0';
  }

  return 1;
}
