#include <atomic>
#include <array>
#include <cstdarg>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <iostream>
#include <mutex>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "cef_loader.h"

extern "C" int verde_cef_execute_subprocess(int argc, const char* const* argv);
extern "C" int verde_cef_initialize(int argc,
                                     const char* const* argv,
                                     const char* subprocess_path,
                                     const char* framework_dir,
                                     const char* main_bundle_path,
                                     const char* resources_dir,
                                     const char* locales_dir);
extern "C" void verde_cef_shutdown();
extern "C" void verde_cef_do_message_loop_work();
extern "C" int verde_cef_has_browser();
extern "C" int verde_cef_create_browser(int width, int height, const char* url);
extern "C" void verde_cef_resize_browser(int width, int height);
extern "C" int verde_cef_navigate(const char* url);
extern "C" int verde_cef_eval(const char* js);
extern "C" int verde_cef_post_json(const char* json);
extern "C" int verde_cef_go_back();
extern "C" int verde_cef_go_forward();
extern "C" int verde_cef_reload();
extern "C" int verde_cef_send_mouse_move(double x, double y, unsigned int modifiers);
extern "C" int verde_cef_send_mouse_click(double x,
                                           double y,
                                           unsigned int button,
                                           int mouse_up,
                                           unsigned int modifiers);
extern "C" int verde_cef_send_mouse_wheel(double x,
                                           double y,
                                           double delta_x,
                                           double delta_y,
                                           unsigned int modifiers);
extern "C" int verde_cef_send_key_event(unsigned int key_code,
                                         int pressed,
                                         unsigned int modifiers);
extern "C" int verde_cef_send_text_input(const char* text, unsigned int modifiers);
extern "C" int verde_cef_copy_frame(void* dest,
                                     size_t cap,
                                     size_t* out_len,
                                     int* width,
                                     int* height);
extern "C" int verde_cef_pop_event(int* kind, char* buffer, size_t cap, size_t* out_len);

namespace {

constexpr size_t kMaxNativeEventBytes = 64 * 1024;
constexpr unsigned kModShift = 1u << 0;
constexpr unsigned kModCtrl = 1u << 1;
constexpr unsigned kModAlt = 1u << 2;
constexpr unsigned kModSuper = 1u << 3;
constexpr size_t kFrameSlotCount = 3;
constexpr size_t kFrameBytesMax = 4096u * 2160u * 4u;
FILE* g_event_output = nullptr;

bool inputDebugEnabled() {
  static const bool enabled = []() {
    const char* value = std::getenv("VERDE_CEF_INPUT_DEBUG");
    return value != nullptr && value[0] != '\0' && std::strcmp(value, "0") != 0;
  }();
  return enabled;
}

void inputDebugLog(const char* format, ...) {
  if (!inputDebugEnabled()) {
    return;
  }

  std::fprintf(stderr, "verde-cef-helper[input]: ");
  va_list args;
  va_start(args, format);
  std::vfprintf(stderr, format, args);
  va_end(args);
  std::fprintf(stderr, "\n");
  std::fflush(stderr);
}

struct Command {
  std::string kind;
  uint32_t width = 0;
  uint32_t height = 0;
  double x = 0.0;
  double y = 0.0;
  double wheel_x = 0.0;
  double wheel_y = 0.0;
  unsigned button = 0;
  bool pressed = false;
  uint32_t key_code = 0;
  bool ctrl = false;
  bool shift = false;
  bool alt = false;
  bool super = false;
  std::string payload;
  bool has_payload = false;
};

struct CommandQueue {
  std::mutex mutex;
  std::deque<Command> items;
  bool closed = false;

  void push(Command command) {
    std::lock_guard<std::mutex> lock(mutex);
    items.push_back(std::move(command));
  }

  bool pop(Command& out) {
    std::lock_guard<std::mutex> lock(mutex);
    if (items.empty()) return false;
    out = std::move(items.front());
    items.pop_front();
    return true;
  }

  void markClosed() {
    std::lock_guard<std::mutex> lock(mutex);
    closed = true;
  }

  bool isDrained() {
    std::lock_guard<std::mutex> lock(mutex);
    return closed && items.empty();
  }
};

struct RuntimeState {
  std::array<unsigned char*, kFrameSlotCount> frame_slots = {nullptr, nullptr};
  uint32_t pane_width = 1280;
  uint32_t pane_height = 720;
  uint8_t next_frame_slot = 0;
};

bool startsWith(std::string_view value, std::string_view prefix) {
  return value.substr(0, prefix.size()) == prefix;
}

bool isChromiumSubprocess(int argc, char** argv) {
  for (int index = 1; index < argc; index += 1) {
    if (startsWith(argv[index], "--type=")) return true;
  }
  return false;
}

std::string selfExePath() {
#if defined(__APPLE__)
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  if (size == 0) return {};
  std::vector<char> buffer(size + 1, '\0');
  if (_NSGetExecutablePath(buffer.data(), &size) != 0) return {};
  return std::string(buffer.data());
#else
  std::vector<char> buffer(4096);
  const ssize_t len = readlink("/proc/self/exe", buffer.data(), buffer.size() - 1);
  if (len <= 0) return {};
  buffer[static_cast<size_t>(len)] = '\0';
  return std::string(buffer.data(), static_cast<size_t>(len));
#endif
}

std::string dirnameOf(const std::string& path) {
  const size_t slash = path.find_last_of('/');
  if (slash == std::string::npos) return ".";
  return path.substr(0, slash);
}

std::string joinPath(const std::string& left, const std::string& right) {
  if (left.empty() || left == ".") return right;
  if (left.back() == '/') return left + right;
  return left + "/" + right;
}

void appendUtf8(std::string& out, uint32_t codepoint) {
  if (codepoint <= 0x7f) {
    out.push_back(static_cast<char>(codepoint));
  } else if (codepoint <= 0x7ff) {
    out.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    out.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else {
    out.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  }
}

bool parseJsonString(const std::string& line, size_t quote_index, std::string& out, size_t& end_index) {
  if (quote_index >= line.size() || line[quote_index] != '"') return false;
  out.clear();
  for (size_t index = quote_index + 1; index < line.size(); index += 1) {
    const char current = line[index];
    if (current == '"') {
      end_index = index + 1;
      return true;
    }
    if (current != '\\') {
      out.push_back(current);
      continue;
    }
    index += 1;
    if (index >= line.size()) return false;
    const char escaped = line[index];
    switch (escaped) {
      case '"':
      case '\\':
      case '/':
        out.push_back(escaped);
        break;
      case 'b':
        out.push_back('\b');
        break;
      case 'f':
        out.push_back('\f');
        break;
      case 'n':
        out.push_back('\n');
        break;
      case 'r':
        out.push_back('\r');
        break;
      case 't':
        out.push_back('\t');
        break;
      case 'u': {
        if (index + 4 >= line.size()) return false;
        uint32_t codepoint = 0;
        for (size_t digit_index = 0; digit_index < 4; digit_index += 1) {
          const char hex = line[index + 1 + digit_index];
          codepoint <<= 4;
          if (hex >= '0' && hex <= '9') {
            codepoint |= static_cast<uint32_t>(hex - '0');
          } else if (hex >= 'a' && hex <= 'f') {
            codepoint |= static_cast<uint32_t>(10 + (hex - 'a'));
          } else if (hex >= 'A' && hex <= 'F') {
            codepoint |= static_cast<uint32_t>(10 + (hex - 'A'));
          } else {
            return false;
          }
        }
        appendUtf8(out, codepoint);
        index += 4;
        break;
      }
      default:
        return false;
    }
  }
  return false;
}

size_t findFieldValue(const std::string& line, const char* field_name) {
  const std::string needle = "\"" + std::string(field_name) + "\"";
  const size_t field = line.find(needle);
  if (field == std::string::npos) return std::string::npos;
  const size_t colon = line.find(':', field + needle.size());
  if (colon == std::string::npos) return std::string::npos;
  size_t value = colon + 1;
  while (value < line.size() && (line[value] == ' ' || line[value] == '\t')) value += 1;
  return value;
}

bool parseStringField(const std::string& line, const char* field_name, std::string& out) {
  const size_t value = findFieldValue(line, field_name);
  if (value == std::string::npos || value >= line.size()) return false;
  size_t end = 0;
  return parseJsonString(line, value, out, end);
}

bool parseOptionalStringField(const std::string& line, const char* field_name, std::string& out) {
  const size_t value = findFieldValue(line, field_name);
  if (value == std::string::npos || value >= line.size()) return false;
  if (line.compare(value, 4, "null") == 0) {
    out.clear();
    return false;
  }
  size_t end = 0;
  return parseJsonString(line, value, out, end);
}

template <typename Number>
bool parseNumberField(const std::string& line, const char* field_name, Number& out) {
  const size_t value = findFieldValue(line, field_name);
  if (value == std::string::npos || value >= line.size()) return false;
  char* end_ptr = nullptr;
  errno = 0;
  if constexpr (std::is_same_v<Number, double>) {
    const double parsed = std::strtod(line.c_str() + value, &end_ptr);
    if (errno != 0 || end_ptr == line.c_str() + value) return false;
    out = parsed;
  } else {
    const unsigned long parsed = std::strtoul(line.c_str() + value, &end_ptr, 10);
    if (errno != 0 || end_ptr == line.c_str() + value) return false;
    out = static_cast<Number>(parsed);
  }
  return true;
}

bool parseBoolField(const std::string& line, const char* field_name, bool& out) {
  const size_t value = findFieldValue(line, field_name);
  if (value == std::string::npos || value >= line.size()) return false;
  if (line.compare(value, 4, "true") == 0) {
    out = true;
    return true;
  }
  if (line.compare(value, 5, "false") == 0) {
    out = false;
    return true;
  }
  return false;
}

bool parseCommand(const std::string& line, Command& command) {
  if (!parseStringField(line, "kind", command.kind)) return false;
  parseNumberField(line, "width", command.width);
  parseNumberField(line, "height", command.height);
  parseNumberField(line, "x", command.x);
  parseNumberField(line, "y", command.y);
  parseNumberField(line, "wheel_x", command.wheel_x);
  parseNumberField(line, "wheel_y", command.wheel_y);
  parseNumberField(line, "button", command.button);
  parseNumberField(line, "key_code", command.key_code);
  parseBoolField(line, "pressed", command.pressed);
  parseBoolField(line, "ctrl", command.ctrl);
  parseBoolField(line, "shift", command.shift);
  parseBoolField(line, "alt", command.alt);
  parseBoolField(line, "super", command.super);
  command.has_payload = parseOptionalStringField(line, "payload", command.payload);
  return true;
}

void writeEscapedJsonString(FILE* file, const std::string& value) {
  std::fputc('"', file);
  for (unsigned char current : value) {
    switch (current) {
      case '"':
        std::fputs("\\\"", file);
        break;
      case '\\':
        std::fputs("\\\\", file);
        break;
      case '\b':
        std::fputs("\\b", file);
        break;
      case '\f':
        std::fputs("\\f", file);
        break;
      case '\n':
        std::fputs("\\n", file);
        break;
      case '\r':
        std::fputs("\\r", file);
        break;
      case '\t':
        std::fputs("\\t", file);
        break;
      default:
        if (current < 0x20) {
          std::fprintf(file, "\\u%04x", current);
        } else {
          std::fputc(static_cast<int>(current), file);
        }
        break;
    }
  }
  std::fputc('"', file);
}

void emitEvent(const char* kind,
               const std::string* payload = nullptr,
               uint32_t width = 0,
               uint32_t height = 0,
               size_t byte_len = 0,
               uint8_t frame_slot = 0) {
  FILE* out = g_event_output != nullptr ? g_event_output : stdout;
  std::fputs("{\"kind\":\"", out);
  std::fputs(kind, out);
  std::fputs("\",\"session_id\":0,\"width\":", out);
  std::fprintf(out, "%u", width);
  std::fputs(",\"height\":", out);
  std::fprintf(out, "%u", height);
  std::fputs(",\"byte_len\":", out);
  std::fprintf(out, "%zu", byte_len);
  std::fputs(",\"frame_slot\":", out);
  std::fprintf(out, "%u", static_cast<unsigned>(frame_slot));
  std::fputs(",\"payload\":", out);
  if (payload != nullptr) {
    writeEscapedJsonString(out, *payload);
  } else {
    std::fputs("null", out);
  }
  std::fputs("}\n", out);
  std::fflush(out);
}

unsigned encodeModifierMask(const Command& command) {
  unsigned mask = 0;
  if (command.shift) mask |= kModShift;
  if (command.ctrl) mask |= kModCtrl;
  if (command.alt) mask |= kModAlt;
  if (command.super) mask |= kModSuper;
  return mask;
}

void commandReaderMain(CommandQueue* queue, FILE* input) {
  if (input == nullptr) {
    queue->markClosed();
    return;
  }

  char* line = nullptr;
  size_t cap = 0;
  while (getline(&line, &cap, input) != -1) {
    std::string owned(line);
    if (!owned.empty() && owned.back() == '\n') {
      owned.pop_back();
    }
    if (!owned.empty() && owned.back() == '\r') {
      owned.pop_back();
    }
    if (owned.empty()) continue;

    Command command;
    if (!parseCommand(owned, command)) {
      const std::string message = "Failed to parse helper command JSON.";
      emitEvent("failed", &message);
      continue;
    }
    queue->push(std::move(command));
  }

  if (line != nullptr) {
    free(line);
  }
  fclose(input);
  queue->markClosed();
}

int parseHelperFd(const char* value) {
  if (value == nullptr || value[0] == '\0') return -1;
  char* end_ptr = nullptr;
  errno = 0;
  const long parsed = std::strtol(value, &end_ptr, 10);
  if (errno != 0 || end_ptr == value || parsed < 0 || parsed > INT32_MAX) return -1;
  return static_cast<int>(parsed);
}

void setCloseOnExec(int fd) {
  if (fd < 0) return;
  const int flags = fcntl(fd, F_GETFD);
  if (flags < 0) return;
  (void)fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

bool ensureBrowserCreated(RuntimeState& state, const std::string& url) {
  if (verde_cef_has_browser() != 0) {
    verde_cef_resize_browser(static_cast<int>(std::max(state.pane_width, 1u)),
                             static_cast<int>(std::max(state.pane_height, 1u)));
    return true;
  }
  return verde_cef_create_browser(static_cast<int>(std::max(state.pane_width, 1u)),
                                  static_cast<int>(std::max(state.pane_height, 1u)),
                                  url.c_str()) != 0;
}

void flushNativeEvents() {
  char buffer[kMaxNativeEventBytes] = {};
  while (true) {
    int kind = 0;
    size_t len = 0;
    if (verde_cef_pop_event(&kind, buffer, sizeof(buffer), &len) == 0) break;
    const std::string payload(buffer, std::min(len, sizeof(buffer) - 1));
    switch (kind) {
      case 1:
        emitEvent("opened");
        break;
      case 2:
        emitEvent("closed");
        break;
      case 3:
        emitEvent("navigated", &payload);
        break;
      case 4:
        emitEvent("title_changed", &payload);
        break;
      case 5:
        emitEvent("document_loaded");
        break;
      case 6:
        emitEvent("js_message", &payload);
        break;
      case 7:
        emitEvent("failed", &payload);
        break;
      default:
        break;
    }
  }
}

void publishLatestFrame(RuntimeState& state) {
  size_t len = 0;
  int width = 0;
  int height = 0;
  const uint8_t slot = state.next_frame_slot;
  const int copied = verde_cef_copy_frame(state.frame_slots[slot], kFrameBytesMax, &len, &width, &height);
  if (copied == 0) return;
  if (copied < 0) {
    const std::string message = "CEF frame copy into shared memory failed.";
    emitEvent("failed", &message);
    return;
  }
  if (width <= 0 || height <= 0) return;

  const size_t expected_len = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
  if (len < expected_len) {
    const std::string message = "CEF frame was shorter than expected.";
    emitEvent("failed", &message);
    return;
  }
  if (expected_len > kFrameBytesMax) {
    const std::string message = "CEF frame exceeded shared memory capacity.";
    emitEvent("failed", &message);
    return;
  }

  state.next_frame_slot = static_cast<uint8_t>((slot + 1) % kFrameSlotCount);
  emitEvent("frame_ready", nullptr, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
            expected_len, slot);
}

bool mapFrameSlots(RuntimeState& state, int frame0_fd, int frame1_fd, int frame2_fd) {
  const int frame_fds[kFrameSlotCount] = {frame0_fd, frame1_fd, frame2_fd};
  for (size_t index = 0; index < kFrameSlotCount; index += 1) {
    if (frame_fds[index] < 0) return false;
    void* mapping = mmap(nullptr, kFrameBytesMax, PROT_READ | PROT_WRITE, MAP_SHARED, frame_fds[index], 0);
    if (mapping == MAP_FAILED) return false;
    state.frame_slots[index] = static_cast<unsigned char*>(mapping);
  }
  return true;
}

void unmapFrameSlots(RuntimeState& state) {
  for (size_t index = 0; index < kFrameSlotCount; index += 1) {
    if (state.frame_slots[index] == nullptr) continue;
    munmap(state.frame_slots[index], kFrameBytesMax);
    state.frame_slots[index] = nullptr;
  }
}

bool applyCommand(RuntimeState& state, const Command& command) {
  if (command.kind == "show") {
    state.pane_width = std::max(command.width, 1u);
    state.pane_height = std::max(command.height, 1u);
    const std::string url = command.has_payload ? command.payload : std::string("about:blank");
    if (!ensureBrowserCreated(state, url)) {
      const std::string message = "CEF failed to create the off-screen browser.";
      emitEvent("failed", &message);
    }
    return true;
  }
  if (command.kind == "hide") {
    emitEvent("closed");
    return true;
  }
  if (command.kind == "resize_pane") {
    state.pane_width = std::max(command.width, 1u);
    state.pane_height = std::max(command.height, 1u);
    if (verde_cef_has_browser() != 0) {
      verde_cef_resize_browser(static_cast<int>(state.pane_width), static_cast<int>(state.pane_height));
    }
    return true;
  }
  if (command.kind == "navigate") {
    state.pane_width = std::max(command.width, 1u);
    state.pane_height = std::max(command.height, 1u);
    if (!command.has_payload) return true;
    if (!ensureBrowserCreated(state, command.payload) || !verde_cef_navigate(command.payload.c_str())) {
      const std::string message = "CEF navigation failed.";
      emitEvent("failed", &message);
    }
    return true;
  }
  if (command.kind == "eval") {
    if (!command.has_payload || !verde_cef_eval(command.payload.c_str())) {
      const std::string message = "CEF JavaScript evaluation failed.";
      emitEvent("failed", &message);
    } else {
      const std::string result = "{\"status\":\"dispatched\"}";
      emitEvent("eval_result", &result);
    }
    return true;
  }
  if (command.kind == "post_json") {
    if (!command.has_payload || !verde_cef_post_json(command.payload.c_str())) {
      const std::string message = "CEF host JSON dispatch failed.";
      emitEvent("failed", &message);
    } else {
      emitEvent("js_message", &command.payload);
    }
    return true;
  }
  if (command.kind == "go_back") {
    if (!verde_cef_go_back()) {
      const std::string message = "CEF back navigation failed.";
      emitEvent("failed", &message);
    }
    return true;
  }
  if (command.kind == "go_forward") {
    if (!verde_cef_go_forward()) {
      const std::string message = "CEF forward navigation failed.";
      emitEvent("failed", &message);
    }
    return true;
  }
  if (command.kind == "reload") {
    if (!verde_cef_reload()) {
      const std::string message = "CEF reload failed.";
      emitEvent("failed", &message);
    }
    return true;
  }
  if (command.kind == "mouse_move") {
    (void)verde_cef_send_mouse_move(command.x, command.y, encodeModifierMask(command));
    return true;
  }
  if (command.kind == "mouse_button") {
    inputDebugLog("dispatch mouse_button x=%.1f y=%.1f button=%u pressed=%d",
                  command.x,
                  command.y,
                  command.button,
                  command.pressed ? 1 : 0);
    (void)verde_cef_send_mouse_click(command.x,
                                     command.y,
                                     command.button,
                                     command.pressed ? 0 : 1,
                                     encodeModifierMask(command));
    return true;
  }
  if (command.kind == "mouse_wheel") {
    inputDebugLog("dispatch mouse_wheel x=%.1f y=%.1f dx=%.2f dy=%.2f",
                  command.x,
                  command.y,
                  command.wheel_x,
                  command.wheel_y);
    (void)verde_cef_send_mouse_wheel(command.x,
                                     command.y,
                                     command.wheel_x,
                                     command.wheel_y,
                                     encodeModifierMask(command));
    return true;
  }
  if (command.kind == "key_input") {
    inputDebugLog("dispatch key_input key=0x%x pressed=%d modifiers=0x%x",
                  command.key_code,
                  command.pressed ? 1 : 0,
                  encodeModifierMask(command));
    (void)verde_cef_send_key_event(command.key_code, command.pressed ? 1 : 0, encodeModifierMask(command));
    return true;
  }
  if (command.kind == "text_input") {
    if (command.has_payload) {
      inputDebugLog("dispatch text_input text=\"%s\" modifiers=0x%x",
                    command.payload.c_str(),
                    encodeModifierMask(command));
      (void)verde_cef_send_text_input(command.payload.c_str(), encodeModifierMask(command));
    }
    return true;
  }
  if (command.kind == "quit") {
    return false;
  }

  const std::string message = "Unknown CEF helper command.";
  emitEvent("failed", &message);
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string exe_path = selfExePath();
  const std::string exe_dir = dirnameOf(exe_path);
#if defined(__APPLE__)
  const std::string contents_dir = dirnameOf(exe_dir);
  const std::string main_bundle_path = dirnameOf(contents_dir);
  const std::string framework_dir =
      exe_dir + "/Chromium Embedded Framework.framework";
  const std::string resources_dir =
      exe_dir + "/Chromium Embedded Framework.framework/Resources";
  const std::string locales_dir = resources_dir + "/locales";
#else
  const std::string framework_dir;
  const std::string main_bundle_path;
  const std::string resources_dir = exe_dir;
  const std::string locales_dir = exe_dir + "/locales";
#endif
  const std::string process_helper_path = joinPath(exe_dir, "verde-browser-cef-process");
  const int command_fd = parseHelperFd(std::getenv("VERDE_CEF_CMD_FD"));
  const int event_fd = parseHelperFd(std::getenv("VERDE_CEF_EVENT_FD"));
  const int frame0_fd = parseHelperFd(std::getenv("VERDE_CEF_FRAME0_FD"));
  const int frame1_fd = parseHelperFd(std::getenv("VERDE_CEF_FRAME1_FD"));
  const int frame2_fd = parseHelperFd(std::getenv("VERDE_CEF_FRAME2_FD"));

  if (chdir(exe_dir.c_str()) != 0) {
    return 1;
  }
  if (!CefLoader::Initialize(exe_dir)) {
    return 1;
  }

  if (isChromiumSubprocess(argc, argv)) {
    return verde_cef_execute_subprocess(argc, const_cast<const char* const*>(argv));
  }
  if (command_fd < 0 || event_fd < 0 || frame0_fd < 0 || frame1_fd < 0 || frame2_fd < 0) {
    return 1;
  }
  setCloseOnExec(command_fd);
  setCloseOnExec(event_fd);
  setCloseOnExec(frame0_fd);
  setCloseOnExec(frame1_fd);
  setCloseOnExec(frame2_fd);

  g_event_output = fdopen(event_fd, "w");
  if (g_event_output == nullptr) {
    return 1;
  }
  setvbuf(g_event_output, nullptr, _IOLBF, 0);

  if (!verde_cef_initialize(
          argc,
          const_cast<const char* const*>(argv),
          process_helper_path.c_str(),
          framework_dir.empty() ? nullptr : framework_dir.c_str(),
          main_bundle_path.empty() ? nullptr : main_bundle_path.c_str(),
          resources_dir.c_str(),
          locales_dir.c_str())) {
    fclose(g_event_output);
    g_event_output = nullptr;
    return 1;
  }

  RuntimeState state;
  if (!mapFrameSlots(state, frame0_fd, frame1_fd, frame2_fd)) {
    verde_cef_shutdown();
    fclose(g_event_output);
    g_event_output = nullptr;
    return 1;
  }

  FILE* command_input = fdopen(command_fd, "r");
  if (command_input == nullptr) {
    unmapFrameSlots(state);
    verde_cef_shutdown();
    fclose(g_event_output);
    g_event_output = nullptr;
    return 1;
  }

  CommandQueue queue;
  std::thread reader(commandReaderMain, &queue, command_input);

  bool running = true;
  while (running) {
    Command command;
    while (queue.pop(command)) {
      running = applyCommand(state, command);
      if (!running) break;
    }

    verde_cef_do_message_loop_work();
    flushNativeEvents();
    publishLatestFrame(state);

    if (!running || queue.isDrained()) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(4));
  }

  queue.markClosed();
  if (reader.joinable()) reader.join();
  unmapFrameSlots(state);
  verde_cef_shutdown();
  fclose(g_event_output);
  g_event_output = nullptr;
  return 0;
}
