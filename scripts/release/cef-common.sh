#!/usr/bin/env bash

VERDE_CEF_VERSION="146.0.9+g3ca6a87+chromium-146.0.7680.165"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmake() {
  if command -v cmake >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "missing required command: cmake" >&2
    echo "install it first, for example: brew install cmake" >&2
    exit 1
  fi

  echo "missing required command: cmake" >&2
  exit 1
}

verde_cef_normalize_arch() {
  case "$1" in
    x86_64|amd64) printf '%s\n' "x86_64" ;;
    aarch64|arm64) printf '%s\n' "arm64" ;;
    *)
      echo "unsupported architecture for CEF: $1" >&2
      return 1
      ;;
  esac
}

verde_cef_platform_suffix() {
  local os="$1"
  local arch="$2"

  case "$os" in
    linux)
      case "$arch" in
        x86_64) printf '%s\n' "linux64" ;;
        *)
          echo "unsupported Linux CEF architecture: $arch" >&2
          return 1
          ;;
      esac
      ;;
    macos)
      case "$arch" in
        x86_64) printf '%s\n' "macosx64" ;;
        arm64) printf '%s\n' "macosarm64" ;;
        *)
          echo "unsupported macOS CEF architecture: $arch" >&2
          return 1
          ;;
      esac
      ;;
    *)
      echo "unsupported CEF platform: $os" >&2
      return 1
      ;;
  esac
}

verde_cef_default_cache_root() {
  local default_cache_base="${XDG_CACHE_HOME:-$HOME/.cache}"
  if [[ -n "${VERDE_CEF_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$VERDE_CEF_CACHE_DIR"
    return 0
  fi

  if mkdir -p "${default_cache_base}/verde" 2>/dev/null; then
    printf '%s\n' "${default_cache_base}/verde/cef-sdk"
  else
    printf '%s\n' "/tmp/verde/cef-sdk"
  fi
}

verde_cef_prepare() {
  local os="$1"
  local arch
  arch="$(verde_cef_normalize_arch "$2")"
  local suffix
  suffix="$(verde_cef_platform_suffix "$os" "$arch")"

  VERDE_CEF_ARCH="$arch"
  VERDE_CEF_PLATFORM_SUFFIX="$suffix"
  VERDE_CEF_BASENAME="cef_binary_${VERDE_CEF_VERSION}_${suffix}_minimal"
  VERDE_CEF_ARCHIVE="${VERDE_CEF_BASENAME}.tar.bz2"
  VERDE_CEF_CACHE_ROOT="$(verde_cef_default_cache_root)"
  VERDE_CEF_URL_DEFAULT="https://cef-builds.spotifycdn.com/cef_binary_${VERDE_CEF_VERSION//+/%2B}_${suffix}_minimal.tar.bz2"
  VERDE_CEF_URL="${VERDE_CEF_URL:-$VERDE_CEF_URL_DEFAULT}"
  VERDE_CEF_SDK_PATH_RESOLVED="${VERDE_CEF_SDK_PATH:-$VERDE_CEF_CACHE_ROOT/$VERDE_CEF_BASENAME}"
}

verde_cef_ensure_sdk() {
  local os="$1"
  local arch="$2"
  verde_cef_prepare "$os" "$arch"

  need_cmd curl
  need_cmd tar
  mkdir -p "$VERDE_CEF_CACHE_ROOT"

  if [[ -d "$VERDE_CEF_SDK_PATH_RESOLVED" ]]; then
    return 0
  fi

  local archive_path="$VERDE_CEF_CACHE_ROOT/$VERDE_CEF_ARCHIVE"
  if [[ ! -f "$archive_path" ]]; then
    echo "Downloading CEF into $VERDE_CEF_CACHE_ROOT"
    curl -fL --retry 3 --output "$archive_path" "$VERDE_CEF_URL"
  fi

  echo "Extracting CEF into $VERDE_CEF_CACHE_ROOT"
  tar -xjf "$archive_path" -C "$VERDE_CEF_CACHE_ROOT"
}
