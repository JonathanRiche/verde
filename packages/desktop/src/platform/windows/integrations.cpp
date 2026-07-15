#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>

#include <climits>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

std::wstring utf8_to_wide(const char *value) {
    if (value == nullptr || value[0] == '\0') return {};
    const int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
    if (len <= 0) return {};
    std::wstring output(static_cast<size_t>(len), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, output.data(), len) <= 0) return {};
    output.resize(static_cast<size_t>(len - 1));
    return output;
}

std::string wide_to_utf8(const wchar_t *value) {
    if (value == nullptr || value[0] == L'\0') return {};
    const int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string output(static_cast<size_t>(len), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, output.data(), len, nullptr, nullptr) <= 0) return {};
    output.resize(static_cast<size_t>(len - 1));
    return output;
}

std::string wide_to_utf8(const wchar_t *value, size_t length) {
    if (value == nullptr || length == 0 || length > static_cast<size_t>(INT_MAX)) return {};
    const int input_len = static_cast<int>(length);
    const int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, input_len, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string output(static_cast<size_t>(len), '\0');
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, input_len, output.data(), len, nullptr, nullptr) <= 0) return {};
    return output;
}

class ComScope {
  public:
    ComScope() : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
    ~ComScope() {
        if (SUCCEEDED(result_)) CoUninitialize();
    }
    bool usable() const { return SUCCEEDED(result_) || result_ == RPC_E_CHANGED_MODE; }

  private:
    HRESULT result_;
};

bool open_clipboard_with_retry() {
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        if (OpenClipboard(nullptr)) return true;
        Sleep(8);
    }
    return false;
}

bool copy_global_bytes(HANDLE handle, size_t max_bytes, unsigned char **bytes, size_t *len) {
    if (handle == nullptr) return false;
    const SIZE_T size = GlobalSize(handle);
    if (size == 0 || size > max_bytes) return false;
    const void *source = GlobalLock(handle);
    if (source == nullptr) return false;
    auto *copy = static_cast<unsigned char *>(std::malloc(size));
    if (copy != nullptr) std::memcpy(copy, source, size);
    GlobalUnlock(handle);
    if (copy == nullptr) return false;
    *bytes = copy;
    *len = static_cast<size_t>(size);
    return true;
}

size_t dib_pixel_offset(const unsigned char *dib, size_t size) {
    if (size < sizeof(BITMAPINFOHEADER)) return 0;
    const auto *header = reinterpret_cast<const BITMAPINFOHEADER *>(dib);
    if (header->biSize < sizeof(BITMAPINFOHEADER) || header->biSize > size) return 0;
    size_t extra_masks = 0;
    if (header->biSize == sizeof(BITMAPINFOHEADER)) {
        if (header->biCompression == BI_BITFIELDS) extra_masks = 3 * sizeof(DWORD);
#ifdef BI_ALPHABITFIELDS
        if (header->biCompression == BI_ALPHABITFIELDS) extra_masks = 4 * sizeof(DWORD);
#endif
    }
    size_t color_count = header->biClrUsed;
    if (color_count == 0 && header->biBitCount <= 8) color_count = static_cast<size_t>(1) << header->biBitCount;
    const size_t offset = static_cast<size_t>(header->biSize) + extra_masks + color_count * sizeof(RGBQUAD);
    return offset <= size ? offset : 0;
}

bool copy_dib_as_bmp(HANDLE handle, size_t max_bytes, unsigned char **bytes, size_t *len) {
    if (handle == nullptr) return false;
    const SIZE_T dib_size = GlobalSize(handle);
    if (dib_size == 0 || dib_size > max_bytes || dib_size + sizeof(BITMAPFILEHEADER) > max_bytes) return false;
    const auto *dib = static_cast<const unsigned char *>(GlobalLock(handle));
    if (dib == nullptr) return false;
    const size_t pixel_offset = dib_pixel_offset(dib, static_cast<size_t>(dib_size));
    if (pixel_offset == 0) {
        GlobalUnlock(handle);
        return false;
    }

    const size_t file_size = sizeof(BITMAPFILEHEADER) + static_cast<size_t>(dib_size);
    auto *copy = static_cast<unsigned char *>(std::malloc(file_size));
    if (copy == nullptr) {
        GlobalUnlock(handle);
        return false;
    }
    BITMAPFILEHEADER file_header{};
    file_header.bfType = 0x4D42;
    file_header.bfSize = static_cast<DWORD>(file_size);
    file_header.bfOffBits = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + pixel_offset);
    static_assert(sizeof(BITMAPFILEHEADER) == 14, "Windows BMP file header must remain packed");
    std::memcpy(copy, &file_header, sizeof(file_header));
    std::memcpy(copy + sizeof(file_header), dib, static_cast<size_t>(dib_size));
    GlobalUnlock(handle);
    *bytes = copy;
    *len = file_size;
    return true;
}

} // namespace

extern "C" int verde_windows_set_app_user_model_id(const char *value) {
    const std::wstring value_w = utf8_to_wide(value);
    if (value_w.empty()) return 0;
    return SUCCEEDED(SetCurrentProcessExplicitAppUserModelID(value_w.c_str())) ? 1 : 0;
}

extern "C" int verde_windows_pick_directory(const char *start_path, char **selected_path) {
    if (selected_path == nullptr) return -1;
    *selected_path = nullptr;
    ComScope com;
    if (!com.usable()) return -1;

    IFileDialog *dialog = nullptr;
    HRESULT result = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(result) || dialog == nullptr) return -1;

    DWORD options = 0;
    dialog->GetOptions(&options);
    dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    dialog->SetTitle(L"Select workspace folder");

    const std::wstring start_w = utf8_to_wide(start_path);
    if (!start_w.empty()) {
        IShellItem *start_item = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(start_w.c_str(), nullptr, IID_PPV_ARGS(&start_item))) && start_item != nullptr) {
            dialog->SetFolder(start_item);
            start_item->Release();
        }
    }

    result = dialog->Show(nullptr);
    if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
        dialog->Release();
        return 0;
    }
    if (FAILED(result)) {
        dialog->Release();
        return -1;
    }

    IShellItem *item = nullptr;
    result = dialog->GetResult(&item);
    dialog->Release();
    if (FAILED(result) || item == nullptr) return -1;
    PWSTR path_w = nullptr;
    result = item->GetDisplayName(SIGDN_FILESYSPATH, &path_w);
    item->Release();
    if (FAILED(result) || path_w == nullptr) return -1;
    const std::string path = wide_to_utf8(path_w);
    CoTaskMemFree(path_w);
    if (path.empty()) return -1;
    *selected_path = _strdup(path.c_str());
    return *selected_path != nullptr ? 1 : -1;
}

extern "C" int verde_windows_shell_open(const char *target, const char *working_dir) {
    const std::wstring target_w = utf8_to_wide(target);
    const std::wstring cwd_w = utf8_to_wide(working_dir);
    if (target_w.empty()) return 0;
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOASYNC;
    info.lpVerb = L"open";
    info.lpFile = target_w.c_str();
    info.lpDirectory = cwd_w.empty() ? nullptr : cwd_w.c_str();
    info.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&info) ? 1 : 0;
}

extern "C" int verde_windows_reveal_file(const char *path) {
    const std::wstring path_w = utf8_to_wide(path);
    if (path_w.empty()) return 0;
    PIDLIST_ABSOLUTE item = nullptr;
    if (FAILED(SHParseDisplayName(path_w.c_str(), nullptr, &item, 0, nullptr)) || item == nullptr) return 0;
    PIDLIST_ABSOLUTE parent = ILClone(item);
    if (parent == nullptr || !ILRemoveLastID(parent)) {
        if (parent != nullptr) ILFree(parent);
        ILFree(item);
        return 0;
    }
    PCUITEMID_CHILD child = ILFindLastID(item);
    const HRESULT result = SHOpenFolderAndSelectItems(parent, 1, &child, 0);
    ILFree(parent);
    ILFree(item);
    return SUCCEEDED(result) ? 1 : 0;
}

extern "C" int verde_windows_clipboard_copy_image(
    unsigned char **bytes,
    size_t *len,
    int *format,
    size_t max_bytes) {
    if (bytes == nullptr || len == nullptr || format == nullptr) return -1;
    *bytes = nullptr;
    *len = 0;
    *format = 0;
    if (!open_clipboard_with_retry()) return -1;

    const UINT png_format = RegisterClipboardFormatW(L"PNG");
    if (png_format != 0 && IsClipboardFormatAvailable(png_format)) {
        if (copy_global_bytes(GetClipboardData(png_format), max_bytes, bytes, len)) {
            *format = 1;
            CloseClipboard();
            return 1;
        }
    }
    const UINT dib_format = IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 : CF_DIB;
    if (IsClipboardFormatAvailable(dib_format) && copy_dib_as_bmp(GetClipboardData(dib_format), max_bytes, bytes, len)) {
        *format = 2;
        CloseClipboard();
        return 1;
    }
    CloseClipboard();
    return 0;
}

extern "C" int verde_windows_clipboard_copy_text(unsigned char **bytes, size_t *len, size_t max_bytes) {
    if (bytes == nullptr || len == nullptr) return -1;
    *bytes = nullptr;
    *len = 0;
    if (!open_clipboard_with_retry()) return -1;
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        CloseClipboard();
        return 0;
    }
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    const SIZE_T utf16_bytes = GlobalSize(handle);
    const size_t max_utf16_bytes = max_bytes > SIZE_MAX / sizeof(wchar_t) ? SIZE_MAX : max_bytes * sizeof(wchar_t);
    if (utf16_bytes < sizeof(wchar_t) || utf16_bytes > max_utf16_bytes || utf16_bytes % sizeof(wchar_t) != 0) {
        CloseClipboard();
        return 0;
    }
    const auto *text = static_cast<const wchar_t *>(GlobalLock(handle));
    if (text == nullptr) {
        CloseClipboard();
        return -1;
    }
    const size_t capacity = static_cast<size_t>(utf16_bytes / sizeof(wchar_t));
    size_t text_length = 0;
    while (text_length < capacity && text[text_length] != L'\0') ++text_length;
    const std::string utf8 = text_length < capacity ? wide_to_utf8(text, text_length) : std::string();
    GlobalUnlock(handle);
    if (utf8.empty() || utf8.size() > max_bytes) {
        CloseClipboard();
        return 0;
    }
    auto *copy = static_cast<unsigned char *>(std::malloc(utf8.size()));
    if (copy != nullptr) std::memcpy(copy, utf8.data(), utf8.size());
    CloseClipboard();
    if (copy == nullptr) return -1;
    *bytes = copy;
    *len = utf8.size();
    return 1;
}
