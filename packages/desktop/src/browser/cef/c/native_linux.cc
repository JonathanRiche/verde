#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string>
#include <sys/syscall.h>
#include <thread>
#include <unistd.h>
#include <stdarg.h>
#include <vector>

#include "include/capi/cef_app_capi.h"
#include "include/capi/cef_browser_capi.h"
#include "include/capi/cef_client_capi.h"
#include "include/capi/cef_display_handler_capi.h"
#include "include/capi/cef_frame_capi.h"
#include "include/capi/cef_life_span_handler_capi.h"
#include "include/capi/cef_load_handler_capi.h"
#include "include/capi/cef_render_handler_capi.h"
#include "include/internal/cef_string.h"

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

extern "C" int open64(const char* pathname, int flags, ...) {
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

extern "C" int openat64(int dirfd, const char* pathname, int flags, ...) {
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

extern "C" bool _ZN4base14AdjustOOMScoreEii(int process, int score) {
  (void)process;
  (void)score;
  return true;
}

namespace {

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

struct VerdeRuntime;
struct VerdeClient;
struct VerdeRenderHandler;
struct VerdeDisplayHandler;
struct VerdeLoadHandler;
struct VerdeLifeSpanHandler;
struct VerdeApp;

struct VerdeRenderHandler {
  cef_render_handler_t base{};
  std::atomic<int> ref_count{1};
  VerdeRuntime* runtime = nullptr;
};

struct VerdeDisplayHandler {
  cef_display_handler_t base{};
  std::atomic<int> ref_count{1};
  VerdeRuntime* runtime = nullptr;
};

struct VerdeLoadHandler {
  cef_load_handler_t base{};
  std::atomic<int> ref_count{1};
  VerdeRuntime* runtime = nullptr;
};

struct VerdeLifeSpanHandler {
  cef_life_span_handler_t base{};
  std::atomic<int> ref_count{1};
  VerdeRuntime* runtime = nullptr;
};

struct VerdeClient {
  cef_client_t base{};
  std::atomic<int> ref_count{1};
  VerdeRuntime* runtime = nullptr;
  VerdeRenderHandler* render_handler = nullptr;
  VerdeDisplayHandler* display_handler = nullptr;
  VerdeLoadHandler* load_handler = nullptr;
  VerdeLifeSpanHandler* life_span_handler = nullptr;

  ~VerdeClient() {
    if (render_handler != nullptr) {
      render_handler->base.base.release(&render_handler->base.base);
      render_handler = nullptr;
    }
    if (display_handler != nullptr) {
      display_handler->base.base.release(&display_handler->base.base);
      display_handler = nullptr;
    }
    if (load_handler != nullptr) {
      load_handler->base.base.release(&load_handler->base.base);
      load_handler = nullptr;
    }
    if (life_span_handler != nullptr) {
      life_span_handler->base.base.release(&life_span_handler->base.base);
      life_span_handler = nullptr;
    }
  }
};

struct VerdeApp {
  cef_app_t base{};
  std::atomic<int> ref_count{1};
};

struct VerdeRuntime {
  bool initialized = false;
  bool browser_create_pending = false;
  int width = 1;
  int height = 1;
  int frame_width = 0;
  int frame_height = 0;
  bool frame_dirty = false;
  std::vector<unsigned char> frame;
  std::deque<VerdeEvent> events;
  cef_browser_t* browser = nullptr;
  VerdeClient* client = nullptr;
};

VerdeRuntime g_runtime;

template <typename T>
void CEF_CALLBACK addRef(cef_base_ref_counted_t* base) {
  auto* self = reinterpret_cast<T*>(base);
  self->ref_count.fetch_add(1, std::memory_order_relaxed);
}

template <typename T>
int CEF_CALLBACK releaseRef(cef_base_ref_counted_t* base) {
  auto* self = reinterpret_cast<T*>(base);
  const int next = self->ref_count.fetch_sub(1, std::memory_order_acq_rel) - 1;
  if (next == 0) {
    delete self;
    return 1;
  }
  return 0;
}

template <typename T>
int CEF_CALLBACK hasOneRef(cef_base_ref_counted_t* base) {
  auto* self = reinterpret_cast<T*>(base);
  return self->ref_count.load(std::memory_order_acquire) == 1 ? 1 : 0;
}

template <typename T>
int CEF_CALLBACK hasAtLeastOneRef(cef_base_ref_counted_t* base) {
  auto* self = reinterpret_cast<T*>(base);
  return self->ref_count.load(std::memory_order_acquire) >= 1 ? 1 : 0;
}

template <typename T, typename CefType>
void initializeRefCounted(CefType* value) {
  value->base.size = sizeof(CefType);
  value->base.add_ref = addRef<T>;
  value->base.release = releaseRef<T>;
  value->base.has_one_ref = hasOneRef<T>;
  value->base.has_at_least_one_ref = hasAtLeastOneRef<T>;
}

std::string toUtf8(const cef_string_t* value) {
  if (value == nullptr || value->str == nullptr || value->length == 0) {
    return {};
  }

  cef_string_utf8_t utf8{};
  cef_string_to_utf8(value->str, value->length, &utf8);
  std::string out;
  if (utf8.str != nullptr && utf8.length > 0) {
    out.assign(utf8.str, utf8.length);
  }
  cef_string_utf8_clear(&utf8);
  return out;
}

cef_string_t toCefString(const char* utf8) {
  cef_string_t value{};
  if (utf8 != nullptr) {
    cef_string_from_utf8(utf8, std::strlen(utf8), &value);
  }
  return value;
}

void pushEvent(int kind, const std::string& payload) {
  g_runtime.events.push_back(VerdeEvent{kind, payload});
}

void pushFailure(const std::string& message) {
  pushEvent(VERDE_EVENT_FAILED, message);
}

VerdeClient* createClient();

// Appends a Chromium switch only when it is not already present on the process command line.
void appendSwitchIfMissing(cef_command_line_t* command_line, const char* name) {
  if (command_line == nullptr || name == nullptr) {
    return;
  }

  const cef_string_t switch_name = toCefString(name);
  const int has_switch = command_line->has_switch(command_line, &switch_name);
  if (has_switch == 0) {
    command_line->append_switch(command_line, &switch_name);
  }
  cef_string_clear(const_cast<cef_string_t*>(&switch_name));
}

// Creates the shared app delegate used to customize Chromium startup behavior.
VerdeApp* createApp() {
  auto* app = new VerdeApp();
  initializeRefCounted<VerdeApp>(&app->base);

  app->base.on_before_command_line_processing =
      [](cef_app_t*, const cef_string_t* process_type, cef_command_line_t* command_line) {
        const bool is_browser_process =
            process_type == nullptr || process_type->str == nullptr || process_type->length == 0;
        if (!is_browser_process) {
          return;
        }

        // Linux zygote startup tries to adjust child OOM scores. In restricted
        // desktop environments that can SIGTRAP during CEF initialization, so
        // keep Chromium on the direct child-process path instead.
        appendSwitchIfMissing(command_line, "no-zygote");
      };
  app->base.get_resource_bundle_handler =
      [](cef_app_t*) -> cef_resource_bundle_handler_t* { return nullptr; };
  app->base.get_browser_process_handler =
      [](cef_app_t*) -> cef_browser_process_handler_t* { return nullptr; };
  app->base.get_render_process_handler =
      [](cef_app_t*) -> cef_render_process_handler_t* { return nullptr; };
  app->base.on_register_custom_schemes =
      [](cef_app_t*, cef_scheme_registrar_t*) {};

  return app;
}

VerdeRenderHandler* createRenderHandler(VerdeRuntime* runtime) {
  auto* handler = new VerdeRenderHandler();
  initializeRefCounted<VerdeRenderHandler>(&handler->base);
  handler->runtime = runtime;

  handler->base.get_root_screen_rect =
      [](cef_render_handler_t*, cef_browser_t*, cef_rect_t*) -> int {
    return 0;
  };
  handler->base.get_view_rect =
      [](cef_render_handler_t* self, cef_browser_t*, cef_rect_t* rect) {
        auto* handler = reinterpret_cast<VerdeRenderHandler*>(self);
        rect->x = 0;
        rect->y = 0;
        rect->width = std::max(handler->runtime->width, 1);
        rect->height = std::max(handler->runtime->height, 1);
      };
  handler->base.get_screen_point =
      [](cef_render_handler_t*, cef_browser_t*, int, int, int*, int*) -> int {
    return 0;
  };
  handler->base.get_screen_info =
      [](cef_render_handler_t*, cef_browser_t*, cef_screen_info_t*) -> int {
    return 0;
  };
  handler->base.on_popup_show =
      [](cef_render_handler_t*, cef_browser_t*, int) {};
  handler->base.on_popup_size =
      [](cef_render_handler_t*, cef_browser_t*, const cef_rect_t*) {};
  handler->base.on_paint =
      [](cef_render_handler_t* self,
         cef_browser_t*,
         cef_paint_element_type_t type,
         size_t,
         const cef_rect_t*,
         const void* buffer,
         int width,
         int height) {
        auto* handler = reinterpret_cast<VerdeRenderHandler*>(self);
        if (type != PET_VIEW || buffer == nullptr || width <= 0 || height <= 0) {
          return;
        }

        const size_t pixel_len =
            static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
        handler->runtime->frame.resize(pixel_len);
        std::memcpy(handler->runtime->frame.data(), buffer, pixel_len);
        handler->runtime->frame_width = width;
        handler->runtime->frame_height = height;
        handler->runtime->frame_dirty = true;
      };
  handler->base.on_accelerated_paint =
      [](cef_render_handler_t*,
         cef_browser_t*,
         cef_paint_element_type_t,
         size_t,
         const cef_rect_t*,
         const cef_accelerated_paint_info_t*) {};
  handler->base.start_dragging =
      [](cef_render_handler_t*, cef_browser_t*, cef_drag_data_t*, cef_drag_operations_mask_t, int, int) -> int {
    return 0;
  };
  handler->base.update_drag_cursor =
      [](cef_render_handler_t*, cef_browser_t*, cef_drag_operations_mask_t) {};
  handler->base.on_scroll_offset_changed =
      [](cef_render_handler_t*, cef_browser_t*, double, double) {};
  handler->base.on_ime_composition_range_changed =
      [](cef_render_handler_t*, cef_browser_t*, const cef_range_t*, size_t, const cef_rect_t*) {};
  handler->base.on_text_selection_changed =
      [](cef_render_handler_t*, cef_browser_t*, const cef_string_t*, const cef_range_t*) {};
  handler->base.on_virtual_keyboard_requested =
      [](cef_render_handler_t*, cef_browser_t*, cef_text_input_mode_t) {};
  return handler;
}

VerdeDisplayHandler* createDisplayHandler(VerdeRuntime* runtime) {
  auto* handler = new VerdeDisplayHandler();
  initializeRefCounted<VerdeDisplayHandler>(&handler->base);
  handler->runtime = runtime;

  handler->base.on_address_change =
      [](cef_display_handler_t*, cef_browser_t*, cef_frame_t* frame, const cef_string_t* url) {
        if (frame == nullptr || frame->is_main(frame) == 0) {
          return;
        }
        pushEvent(VERDE_EVENT_NAVIGATED, toUtf8(url));
      };
  handler->base.on_title_change =
      [](cef_display_handler_t*, cef_browser_t*, const cef_string_t* title) {
        pushEvent(VERDE_EVENT_TITLE_CHANGED, toUtf8(title));
      };
  handler->base.on_console_message =
      [](cef_display_handler_t*, cef_browser_t*, cef_log_severity_t, const cef_string_t*, const cef_string_t*, int) -> int {
        return 0;
      };
  return handler;
}

VerdeLoadHandler* createLoadHandler(VerdeRuntime* runtime) {
  auto* handler = new VerdeLoadHandler();
  initializeRefCounted<VerdeLoadHandler>(&handler->base);
  handler->runtime = runtime;

  handler->base.on_loading_state_change =
      [](cef_load_handler_t*, cef_browser_t*, int, int, int) {};
  handler->base.on_load_start =
      [](cef_load_handler_t*, cef_browser_t*, cef_frame_t*, cef_transition_type_t) {};
  handler->base.on_load_end =
      [](cef_load_handler_t*, cef_browser_t*, cef_frame_t*, int) {};
  handler->base.on_load_error =
      [](cef_load_handler_t*, cef_browser_t*, cef_frame_t*, cef_errorcode_t, const cef_string_t* error_text, const cef_string_t* failed_url) {
        const std::string message = toUtf8(error_text) + " (" + toUtf8(failed_url) + ")";
        pushFailure(message);
      };
  return handler;
}

VerdeLifeSpanHandler* createLifeSpanHandler(VerdeRuntime* runtime) {
  auto* handler = new VerdeLifeSpanHandler();
  initializeRefCounted<VerdeLifeSpanHandler>(&handler->base);
  handler->runtime = runtime;

  handler->base.on_before_popup =
      [](cef_life_span_handler_t*,
         cef_browser_t*,
         cef_frame_t*,
         int,
         const cef_string_t*,
         const cef_string_t*,
         cef_window_open_disposition_t,
         int,
         const cef_popup_features_t*,
         cef_window_info_t*,
         cef_client_t**,
         cef_browser_settings_t*,
         cef_dictionary_value_t**,
         int*) -> int {
        return 1;
      };
  handler->base.on_before_popup_aborted =
      [](cef_life_span_handler_t*, cef_browser_t*, int) {};
  handler->base.on_before_dev_tools_popup =
      [](cef_life_span_handler_t*, cef_browser_t*, cef_window_info_t*, cef_client_t**, cef_browser_settings_t*, cef_dictionary_value_t**, int*) {};
  handler->base.on_after_created =
      [](cef_life_span_handler_t* self, cef_browser_t* browser) {
        auto* handler = reinterpret_cast<VerdeLifeSpanHandler*>(self);
        handler->runtime->browser_create_pending = false;
        if (handler->runtime->browser == nullptr) {
          browser->base.add_ref(&browser->base);
          handler->runtime->browser = browser;
        }
        pushEvent(VERDE_EVENT_OPENED, {});
      };
  handler->base.do_close =
      [](cef_life_span_handler_t*, cef_browser_t*) -> int {
        return 0;
      };
  handler->base.on_before_close =
      [](cef_life_span_handler_t* self, cef_browser_t* browser) {
        auto* handler = reinterpret_cast<VerdeLifeSpanHandler*>(self);
        handler->runtime->browser_create_pending = false;
        if (handler->runtime->browser == browser) {
          browser->base.release(&browser->base);
          handler->runtime->browser = nullptr;
        }
        pushEvent(VERDE_EVENT_CLOSED, {});
      };
  return handler;
}

VerdeClient* createClient() {
  auto* client = new VerdeClient();
  initializeRefCounted<VerdeClient>(&client->base);
  client->runtime = &g_runtime;
  client->render_handler = createRenderHandler(&g_runtime);
  client->display_handler = createDisplayHandler(&g_runtime);
  client->load_handler = createLoadHandler(&g_runtime);
  client->life_span_handler = createLifeSpanHandler(&g_runtime);

  client->base.get_render_handler =
      [](cef_client_t* self) -> cef_render_handler_t* {
        auto* client = reinterpret_cast<VerdeClient*>(self);
        client->render_handler->base.base.add_ref(&client->render_handler->base.base);
        return &client->render_handler->base;
      };
  client->base.get_display_handler =
      [](cef_client_t* self) -> cef_display_handler_t* {
        auto* client = reinterpret_cast<VerdeClient*>(self);
        client->display_handler->base.base.add_ref(&client->display_handler->base.base);
        return &client->display_handler->base;
      };
  client->base.get_load_handler =
      [](cef_client_t* self) -> cef_load_handler_t* {
        auto* client = reinterpret_cast<VerdeClient*>(self);
        client->load_handler->base.base.add_ref(&client->load_handler->base.base);
        return &client->load_handler->base;
      };
  client->base.get_life_span_handler =
      [](cef_client_t* self) -> cef_life_span_handler_t* {
        auto* client = reinterpret_cast<VerdeClient*>(self);
        client->life_span_handler->base.base.add_ref(&client->life_span_handler->base.base);
        return &client->life_span_handler->base;
      };
  client->base.on_process_message_received =
      [](cef_client_t*, cef_browser_t*, cef_frame_t*, cef_process_id_t, cef_process_message_t*) -> int {
        return 0;
      };
  return client;
}

}  // namespace

extern "C" int verde_cef_execute_subprocess(int argc,
                                             const char* const* argv) {
  std::fprintf(stderr, "verde-cef: execute_subprocess start argc=%d\n", argc);
  std::fflush(stderr);
  cef_main_args_t main_args{};
  main_args.argc = argc;
  main_args.argv = const_cast<char**>(argv);
  const int result = cef_execute_process(&main_args, nullptr, nullptr);
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

  cef_main_args_t main_args{};
  main_args.argc = argc;
  main_args.argv = const_cast<char**>(argv);

  cef_settings_t settings{};
  settings.size = sizeof(cef_settings_t);
  const char* sandbox_binary = "/usr/lib/chromium/chrome-sandbox";
  if (getenv("CHROME_DEVEL_SANDBOX") == nullptr && access(sandbox_binary, X_OK) == 0) {
    setenv("CHROME_DEVEL_SANDBOX", sandbox_binary, 0);
  }
  settings.no_sandbox = 0;
  settings.multi_threaded_message_loop = 0;
  settings.external_message_pump = 0;
  settings.windowless_rendering_enabled = 1;
  settings.log_severity = LOGSEVERITY_DISABLE;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);

  settings.browser_subprocess_path = toCefString(subprocess_path);
  settings.resources_dir_path = toCefString(resources_dir);
  settings.locales_dir_path = toCefString(locales_dir);

  struct sigaction old_trap{};
  struct sigaction ignore_trap{};
  ignore_trap.sa_handler = SIG_IGN;
  sigemptyset(&ignore_trap.sa_mask);
  ignore_trap.sa_flags = 0;
  sigaction(SIGTRAP, &ignore_trap, &old_trap);
  const int ok = cef_initialize(&main_args, &settings, nullptr, nullptr);
  sigaction(SIGTRAP, &old_trap, nullptr);

  cef_string_clear(&settings.browser_subprocess_path);
  cef_string_clear(&settings.resources_dir_path);
  cef_string_clear(&settings.locales_dir_path);

  std::fprintf(stderr, "verde-cef: initialize result=%d\n", ok);
  std::fflush(stderr);

  if (ok == 0) {
    return 0;
  }

  g_runtime.initialized = true;
  g_runtime.client = createClient();
  return 1;
}

extern "C" int verde_cef_is_initialized() {
  return g_runtime.initialized ? 1 : 0;
}

extern "C" void verde_cef_shutdown() {
  if (!g_runtime.initialized) {
    return;
  }

  if (g_runtime.browser != nullptr) {
    auto* host = g_runtime.browser->get_host(g_runtime.browser);
    if (host != nullptr) {
      host->close_browser(host, 1);
      host->base.release(&host->base);
    }

    for (int iteration = 0; iteration < 100 && g_runtime.browser != nullptr; ++iteration) {
      cef_do_message_loop_work();
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }

  cef_shutdown();

  if (g_runtime.client != nullptr) {
    g_runtime.client->base.base.release(&g_runtime.client->base.base);
    g_runtime.client = nullptr;
  }

  g_runtime.browser = nullptr;
  g_runtime.browser_create_pending = false;
  g_runtime.frame.clear();
  g_runtime.events.clear();
  g_runtime.frame_width = 0;
  g_runtime.frame_height = 0;
  g_runtime.frame_dirty = false;
  g_runtime.initialized = false;
}

extern "C" void verde_cef_do_message_loop_work() {
  if (!g_runtime.initialized) {
    return;
  }
  cef_do_message_loop_work();
}

extern "C" int verde_cef_has_browser() {
  return g_runtime.browser != nullptr ? 1 : 0;
}

extern "C" int verde_cef_create_browser(int width,
                                         int height,
                                         const char* url) {
  if (!g_runtime.initialized || g_runtime.client == nullptr) {
    pushFailure("CEF runtime is not initialized.");
    return 0;
  }

  std::fprintf(stderr, "verde-cef: create_browser start url=%s\n",
               url != nullptr ? url : "(null)");
  std::fflush(stderr);

  if (g_runtime.browser != nullptr) {
    return 1;
  }
  if (g_runtime.browser_create_pending) {
    return 1;
  }

  g_runtime.width = std::max(width, 1);
  g_runtime.height = std::max(height, 1);

  cef_window_info_t window_info{};
  window_info.size = sizeof(cef_window_info_t);
  window_info.windowless_rendering_enabled = 1;
  window_info.bounds.x = 0;
  window_info.bounds.y = 0;
  window_info.bounds.width = g_runtime.width;
  window_info.bounds.height = g_runtime.height;
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  cef_browser_settings_t browser_settings{};
  browser_settings.size = sizeof(cef_browser_settings_t);
  browser_settings.windowless_frame_rate = 30;
  browser_settings.background_color = CefColorSetARGB(255, 255, 255, 255);

  cef_string_t initial_url = toCefString(url != nullptr ? url : "about:blank");
  const int ok = cef_browser_host_create_browser(
      &window_info,
      &g_runtime.client->base,
      &initial_url,
      &browser_settings,
      nullptr,
      nullptr);
  cef_string_clear(&initial_url);

  std::fprintf(stderr, "verde-cef: create_browser queued=%d\n", ok);
  std::fflush(stderr);

  if (ok == 0) {
    pushFailure("CEF failed to create the off-screen browser.");
    return 0;
  }

  g_runtime.browser_create_pending = true;
  return 1;
}

extern "C" void verde_cef_resize_browser(int width, int height) {
  g_runtime.width = std::max(width, 1);
  g_runtime.height = std::max(height, 1);

  if (g_runtime.browser == nullptr) {
    return;
  }

  auto* host = g_runtime.browser->get_host(g_runtime.browser);
  if (host == nullptr) {
    return;
  }

  host->was_resized(host);
  host->base.release(&host->base);
}

extern "C" int verde_cef_navigate(const char* url) {
  if (g_runtime.browser == nullptr || url == nullptr) {
    return 0;
  }

  auto* frame = g_runtime.browser->get_main_frame(g_runtime.browser);
  if (frame == nullptr) {
    return 0;
  }

  cef_string_t target = toCefString(url);
  frame->load_url(frame, &target);
  cef_string_clear(&target);
  frame->base.release(&frame->base);
  return 1;
}

extern "C" int verde_cef_eval(const char* js) {
  if (g_runtime.browser == nullptr || js == nullptr) {
    return 0;
  }

  auto* frame = g_runtime.browser->get_main_frame(g_runtime.browser);
  if (frame == nullptr) {
    return 0;
  }

  cef_string_t code = toCefString(js);
  cef_string_t script_url = toCefString("app://verde-eval.js");
  frame->execute_java_script(frame, &code, &script_url, 1);
  cef_string_clear(&code);
  cef_string_clear(&script_url);
  frame->base.release(&frame->base);
  return 1;
}

extern "C" void verde_cef_get_frame(const unsigned char** pixels,
                                     size_t* len,
                                     int* width,
                                     int* height,
                                     int* dirty) {
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
  g_runtime.frame_dirty = false;
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
