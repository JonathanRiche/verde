#ifndef VERDE_CEF_LOADER_H
#define VERDE_CEF_LOADER_H

#include <string>

// Preloads libcef and related runtime libraries on Linux before any CEF API use.
class CefLoader {
 public:
  // Loads the CEF runtime from the helper executable directory.
  static bool Initialize(const std::string& runtime_dir);

 private:
  static bool initialized_;
};

#endif
