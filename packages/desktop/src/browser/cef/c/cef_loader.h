#ifndef VERDE_CEF_LOADER_H
#define VERDE_CEF_LOADER_H

#include <string>

// Preloads the CEF runtime before any API use when the platform needs it.
class CefLoader {
 public:
  // Prepares the CEF runtime from the helper executable directory.
  static bool Initialize(const std::string& runtime_dir);

 private:
  static bool initialized_;
};

#endif
