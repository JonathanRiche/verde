#include <new>
#include <string_view>

#include "textselect.hpp"

extern "C" {
struct zgui_text_select_slice {
    const char* ptr;
    size_t len;
};

typedef zgui_text_select_slice (*zgui_text_select_get_line_fn)(void* context, size_t index);
typedef size_t (*zgui_text_select_get_num_lines_fn)(void* context);

struct zgui_text_select_callbacks {
    void* context;
    zgui_text_select_get_line_fn get_line;
    zgui_text_select_get_num_lines_fn get_num_lines;
};
}

struct zgui_text_select {
    explicit zgui_text_select(zgui_text_select_callbacks callbacks, bool enable_word_wrap)
        : callbacks(callbacks),
          select(
              [this](size_t index) -> std::string_view {
                  if (this->callbacks.get_line == nullptr) {
                      return {};
                  }
                  zgui_text_select_slice slice = this->callbacks.get_line(this->callbacks.context, index);
                  return slice.ptr != nullptr ? std::string_view(slice.ptr, slice.len) : std::string_view{};
              },
              [this]() -> size_t {
                  return this->callbacks.get_num_lines != nullptr ? this->callbacks.get_num_lines(this->callbacks.context)
                                                                  : 0;
              },
              enable_word_wrap) {}

    zgui_text_select_callbacks callbacks;
    TextSelect select;
};

extern "C" zgui_text_select* zgui_text_select_create(
    zgui_text_select_callbacks callbacks,
    bool enable_word_wrap
) {
    if (callbacks.get_line == nullptr || callbacks.get_num_lines == nullptr) {
        return nullptr;
    }
    return new (std::nothrow) zgui_text_select(callbacks, enable_word_wrap);
}

extern "C" void zgui_text_select_destroy(zgui_text_select* selector) {
    delete selector;
}

extern "C" void zgui_text_select_update(zgui_text_select* selector) {
    if (selector == nullptr) {
        return;
    }
    selector->select.update();
}

extern "C" bool zgui_text_select_has_selection(zgui_text_select* selector) {
    return selector != nullptr && selector->select.hasSelection();
}

extern "C" void zgui_text_select_copy(zgui_text_select* selector) {
    if (selector == nullptr) {
        return;
    }
    selector->select.copy();
}

extern "C" void zgui_text_select_select_all(zgui_text_select* selector) {
    if (selector == nullptr) {
        return;
    }
    selector->select.selectAll();
}

extern "C" void zgui_text_select_clear_selection(zgui_text_select* selector) {
    if (selector == nullptr) {
        return;
    }
    selector->select.clearSelection();
}
