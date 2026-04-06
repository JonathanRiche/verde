#include <string>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "cef_loader.h"

extern "C" int verde_cef_execute_subprocess(int argc, const char* const* argv);

namespace {

bool startsWith(const std::string& value, const char* prefix) {
  return value.rfind(prefix, 0) == 0;
}

bool isChromiumSubprocess(int argc, char** argv) {
  for (int index = 1; index < argc; index += 1) {
    if (startsWith(argv[index], "--type=")) {
      return true;
    }
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

}  // namespace

int main(int argc, char** argv) {
  const std::string exe_dir = dirnameOf(selfExePath());
  if (chdir(exe_dir.c_str()) != 0) {
    return 1;
  }
  if (!CefLoader::Initialize(exe_dir)) {
    return 1;
  }

  if (!isChromiumSubprocess(argc, argv)) {
    return 0;
  }

  return verde_cef_execute_subprocess(argc, const_cast<const char* const*>(argv));
}
