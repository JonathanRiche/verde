#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <Verde.app>" >&2
  exit 1
fi

APP_DIR="$1"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FFF_LIB="$MACOS_DIR/libfff_c.dylib"
DESIRED_FFF_REF="@executable_path/libfff_c.dylib"

find_cmd() {
  local primary="$1"
  local fallback="$2"

  if command -v "$primary" >/dev/null 2>&1; then
    command -v "$primary"
    return 0
  fi

  if command -v "$fallback" >/dev/null 2>&1; then
    command -v "$fallback"
    return 0
  fi

  return 1
}

INSTALL_NAME_TOOL="$(find_cmd install_name_tool llvm-install-name-tool || true)"
OTOOL="$(find_cmd otool llvm-otool || true)"

if [[ -z "$INSTALL_NAME_TOOL" ]]; then
  echo "install_name_tool or llvm-install-name-tool is required" >&2
  exit 1
fi

if [[ -z "$OTOOL" ]]; then
  echo "otool or llvm-otool is required" >&2
  exit 1
fi

if [[ ! -f "$FFF_LIB" ]]; then
  echo "missing bundled libfff_c.dylib at $FFF_LIB" >&2
  exit 1
fi

"$INSTALL_NAME_TOOL" -id "$DESIRED_FFF_REF" "$FFF_LIB"

while IFS= read -r -d '' candidate; do
  if ! "$OTOOL" -L "$candidate" >/tmp/verde-macos-otool.$$ 2>/dev/null; then
    continue
  fi

  current_ref="$(awk '/libfff_c\.dylib/ { print $1; exit }' /tmp/verde-macos-otool.$$)"
  if [[ -z "$current_ref" || "$current_ref" == "$DESIRED_FFF_REF" ]]; then
    continue
  fi

  "$INSTALL_NAME_TOOL" -change "$current_ref" "$DESIRED_FFF_REF" "$candidate"
done < <(find "$MACOS_DIR" -maxdepth 1 -type f -print0)

rm -f /tmp/verde-macos-otool.$$
