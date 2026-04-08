#include "cef_loader.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

bool CefLoader::initialized_ = false;

namespace {

#if !defined(__APPLE__)
void prependLibraryPath(const std::string& runtime_dir) {
  const char* current = std::getenv("LD_LIBRARY_PATH");
  if (current == nullptr || current[0] == '\0') {
    setenv("LD_LIBRARY_PATH", runtime_dir.c_str(), 1);
    return;
  }

  const std::string current_value(current);
  if (current_value == runtime_dir ||
      current_value.rfind(runtime_dir + ":", 0) == 0) {
    return;
  }

  const std::string updated = runtime_dir + ":" + current_value;
  setenv("LD_LIBRARY_PATH", updated.c_str(), 1);
}

bool loadLibrary(const std::string& path, bool required) {
  void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL);
  if (handle != nullptr) {
    return true;
  }

  if (required) {
    std::cerr << "verde-cef-loader: failed to load " << path << ": "
              << dlerror() << std::endl;
  }
  return !required;
}
#endif

}  // namespace

bool CefLoader::Initialize(const std::string& runtime_dir) {
  if (initialized_) {
    return true;
  }

#if defined(__APPLE__)
  (void)runtime_dir;
  initialized_ = true;
  return true;
#else
  prependLibraryPath(runtime_dir);

  const std::vector<std::pair<const char*, bool>> libraries = {
      {"libcef.so", true},
      {"libEGL.so", false},
      {"libGLESv2.so", false},
      {"libvk_swiftshader.so", false},
      {"libvulkan.so.1", false},
  };

  for (const auto& [name, required] : libraries) {
    if (!loadLibrary(runtime_dir + "/" + name, required)) {
      return false;
    }
  }

  initialized_ = true;
  return true;
#endif
}
