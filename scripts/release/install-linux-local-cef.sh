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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESKTOP_ROOT="$REPO_ROOT/packages/desktop"
PREFIX="${1:-${VERDE_INSTALL_PREFIX:-$HOME/.local}}"
source "$SCRIPT_DIR/cef-common.sh"

need_cmd zig
need_cmake
verde_cef_ensure_sdk linux "$ARCH"

cd "$DESKTOP_ROOT"
zig build --release=safe -p "$PREFIX" -Dbrowser-backend=cef -Dcef-sdk-path="$VERDE_CEF_SDK_PATH_RESOLVED"

echo
echo "Installed Verde into $PREFIX"
echo "Binary: $PREFIX/bin/verde"
echo "CEF SDK cache: $VERDE_CEF_SDK_PATH_RESOLVED"
