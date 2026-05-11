#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <version> <output-dir>" >&2
  exit 1
fi

VERSION="$1"
OUTPUT_DIR="$2"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESKTOP_ROOT="$REPO_ROOT/packages/desktop"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALLER_ROOT="$(pwd)"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$CALLER_ROOT/$OUTPUT_DIR"
fi
ARCH="$(uname -m)"
source "$SCRIPT_DIR/cef-common.sh"

case "$ARCH" in
  x86_64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PREFIX_DIR="$WORK_DIR/prefix"
PACKAGE_ROOT="$WORK_DIR/verde-${VERSION}-linux-${ARCH}"

strip_debug_symbols() {
  local path="$1"

  if [[ ! -f "$path" ]]; then
    return
  fi

  strip --strip-debug "$path"
}

normalize_fff_dependency() {
  local path="$1"
  local original_needed="$2"
  local replacement_needed="$3"

  if [[ ! -f "$path" ]]; then
    return
  fi

  if ! command -v patchelf >/dev/null 2>&1; then
    echo "warning: patchelf was not found; packaged verde may retain an absolute libfff_c.so dependency" >&2
    return
  fi

  if ! readelf -d "$path" | grep -Fq "$original_needed"; then
    return
  fi

  patchelf --replace-needed "$original_needed" "$replacement_needed" "$path"
}

copy_runtime_library() {
  local library_name="$1"
  local destination_dir="$2"
  local library_path=""

  if command -v ldconfig >/dev/null 2>&1; then
    library_path="$(ldconfig -p | awk -v name="$library_name" '$1 == name { print $NF; exit }')"
  fi

  if [[ -z "$library_path" && -e "/usr/lib/x86_64-linux-gnu/$library_name" ]]; then
    library_path="/usr/lib/x86_64-linux-gnu/$library_name"
  fi

  if [[ -z "$library_path" || ! -e "$library_path" ]]; then
    echo "missing required runtime library: $library_name" >&2
    exit 1
  fi

  cp -a "$(readlink -f "$library_path")" "$destination_dir/"
  local real_name
  real_name="$(basename "$(readlink -f "$library_path")")"
  if [[ "$real_name" != "$library_name" ]]; then
    ln -sfn "$real_name" "$destination_dir/$library_name"
  fi
  if command -v readelf >/dev/null 2>&1; then
    local soname
    soname="$(readelf -d "$(readlink -f "$library_path")" | awk '/SONAME/ { gsub(/[\[\]]/, "", $5); print $5; exit }')"
    if [[ -n "$soname" && "$soname" != "$real_name" ]]; then
      ln -sfn "$real_name" "$destination_dir/$soname"
    fi
  fi
}

mkdir -p "$OUTPUT_DIR"
need_cmake
verde_cef_ensure_sdk linux "$ARCH"

cd "$DESKTOP_ROOT"
zig build --release=safe -p "$PREFIX_DIR" -Dcef-sdk-path="$VERDE_CEF_SDK_PATH_RESOLVED"

mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/share/applications" \
  "$PACKAGE_ROOT/share/pixmaps"

install -m 755 "$PREFIX_DIR/bin/verde" "$PACKAGE_ROOT/bin/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.so" "$PACKAGE_ROOT/bin/libfff_c.so"
install -m 755 "$PREFIX_DIR/bin/libSDL3.so" "$PACKAGE_ROOT/bin/libSDL3.so"
copy_runtime_library "libSDL3_ttf.so" "$PACKAGE_ROOT/bin"
install -m 755 "$PREFIX_DIR/bin/verde-browser-cef" "$PACKAGE_ROOT/bin/verde-browser-cef"
install -m 755 "$PREFIX_DIR/bin/verde-browser-cef-process" "$PACKAGE_ROOT/bin/verde-browser-cef-process"
install -m 755 "$PREFIX_DIR/bin/libcef.so" "$PACKAGE_ROOT/bin/libcef.so"
install -m 755 "$PREFIX_DIR/bin/libEGL.so" "$PACKAGE_ROOT/bin/libEGL.so"
install -m 755 "$PREFIX_DIR/bin/libGLESv2.so" "$PACKAGE_ROOT/bin/libGLESv2.so"
install -m 755 "$PREFIX_DIR/bin/libvk_swiftshader.so" "$PACKAGE_ROOT/bin/libvk_swiftshader.so"
install -m 755 "$PREFIX_DIR/bin/libvulkan.so.1" "$PACKAGE_ROOT/bin/libvulkan.so.1"
install -m 755 "$PREFIX_DIR/bin/v8_context_snapshot.bin" "$PACKAGE_ROOT/bin/v8_context_snapshot.bin"
install -m 755 "$PREFIX_DIR/bin/vk_swiftshader_icd.json" "$PACKAGE_ROOT/bin/vk_swiftshader_icd.json"
install -m 755 "$PREFIX_DIR/bin/chrome-sandbox" "$PACKAGE_ROOT/bin/chrome-sandbox"
install -m 644 "$PREFIX_DIR/bin/chrome_100_percent.pak" "$PACKAGE_ROOT/bin/chrome_100_percent.pak"
install -m 644 "$PREFIX_DIR/bin/chrome_200_percent.pak" "$PACKAGE_ROOT/bin/chrome_200_percent.pak"
install -m 644 "$PREFIX_DIR/bin/resources.pak" "$PACKAGE_ROOT/bin/resources.pak"
install -m 644 "$PREFIX_DIR/bin/icudtl.dat" "$PACKAGE_ROOT/bin/icudtl.dat"
cp -a "$PREFIX_DIR/bin/locales" "$PACKAGE_ROOT/bin/locales"
install -m 644 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" "$PACKAGE_ROOT/share/pixmaps/verde.png"
install -m 755 "$REPO_ROOT/scripts/release/install-linux-local.sh" "$PACKAGE_ROOT/install-local.sh"
install -m 644 "$REPO_ROOT/README.md" "$PACKAGE_ROOT/README.md"

normalize_fff_dependency \
  "$PACKAGE_ROOT/bin/verde" \
  "$REPO_ROOT/vendor/fff/target/release/libfff_c.so" \
  "libfff_c.so"

strip_debug_symbols "$PACKAGE_ROOT/bin/verde"
strip_debug_symbols "$PACKAGE_ROOT/bin/libSDL3.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libSDL3_ttf.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/verde-browser-cef"
strip_debug_symbols "$PACKAGE_ROOT/bin/verde-browser-cef-process"
strip_debug_symbols "$PACKAGE_ROOT/bin/libfff_c.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libcef.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libEGL.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libGLESv2.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libvk_swiftshader.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libvulkan.so.1"
strip_debug_symbols "$PACKAGE_ROOT/bin/chrome-sandbox"

cat > "$PACKAGE_ROOT/share/applications/verde.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Verde
Comment=Desktop chat app for Codex and OpenCode
Exec=verde
Icon=verde
Terminal=false
Categories=Development;
StartupNotify=true
EOF

tar -C "$WORK_DIR" -czf "$OUTPUT_DIR/verde-${VERSION}-linux-${ARCH}.tar.gz" "$(basename "$PACKAGE_ROOT")"
