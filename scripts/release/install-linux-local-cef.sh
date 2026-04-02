#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "this installer only works on Linux" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [install-prefix]" >&2
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ;;
  *)
    echo "unsupported architecture for bundled CEF installer: $ARCH" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESKTOP_ROOT="$REPO_ROOT/packages/desktop"
PREFIX="${1:-${VERDE_INSTALL_PREFIX:-$HOME/.local}}"
CACHE_ROOT="${VERDE_CEF_CACHE_DIR:-$HOME/.cache/verde/cef-sdk}"
CEF_BASENAME="cef_binary_146.0.9+g3ca6a87+chromium-146.0.7680.165_linux64_minimal"
CEF_ARCHIVE="$CEF_BASENAME.tar.bz2"
CEF_URL="${VERDE_CEF_URL:-https://cef-builds.spotifycdn.com/cef_binary_146.0.9%2Bg3ca6a87%2Bchromium-146.0.7680.165_linux64_minimal.tar.bz2}"
CEF_SDK_PATH="${VERDE_CEF_SDK_PATH:-$CACHE_ROOT/$CEF_BASENAME}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd zig
need_cmd curl
need_cmd tar

mkdir -p "$CACHE_ROOT"

if [[ ! -d "$CEF_SDK_PATH" ]]; then
  ARCHIVE_PATH="$CACHE_ROOT/$CEF_ARCHIVE"
  if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "Downloading CEF into $CACHE_ROOT"
    curl -fL --retry 3 --output "$ARCHIVE_PATH" "$CEF_URL"
  fi

  echo "Extracting CEF into $CACHE_ROOT"
  tar -xjf "$ARCHIVE_PATH" -C "$CACHE_ROOT"
fi

cd "$DESKTOP_ROOT"
zig build --release=safe -p "$PREFIX" -Dcef-sdk-path="$CEF_SDK_PATH"

echo
echo "Installed Verde into $PREFIX"
echo "Binary: $PREFIX/bin/verde"
echo "CEF SDK cache: $CEF_SDK_PATH"
