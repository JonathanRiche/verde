#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p \
  "$PREFIX/bin" \
  "$PREFIX/share/verde" \
  "$PREFIX/share/applications" \
  "$PREFIX/share/pixmaps"

copy_if_present() {
  local source_path="$1"
  local dest_path="$2"
  if [[ -e "$source_path" ]]; then
    install -m 755 "$source_path" "$dest_path"
  fi
}

copy_glob_if_present() {
  local pattern="$1"
  local dest_dir="$2"
  if compgen -G "$pattern" >/dev/null; then
    cp -a $pattern "$dest_dir/"
  fi
}

install -m 755 "$SCRIPT_DIR/bin/verde" "$PREFIX/bin/verde"
install -m 755 "$SCRIPT_DIR/bin/libfff_c.so" "$PREFIX/bin/libfff_c.so"
copy_if_present "$SCRIPT_DIR/bin/libSDL3.so" "$PREFIX/bin/libSDL3.so"
copy_glob_if_present "$SCRIPT_DIR/bin/libSDL3_ttf.so*" "$PREFIX/bin"
copy_if_present "$SCRIPT_DIR/bin/verde-browser-cef" "$PREFIX/bin/verde-browser-cef"
copy_if_present "$SCRIPT_DIR/bin/verde-browser-cef-process" "$PREFIX/bin/verde-browser-cef-process"
copy_if_present "$SCRIPT_DIR/bin/libcef.so" "$PREFIX/bin/libcef.so"
copy_if_present "$SCRIPT_DIR/bin/libEGL.so" "$PREFIX/bin/libEGL.so"
copy_if_present "$SCRIPT_DIR/bin/libGLESv2.so" "$PREFIX/bin/libGLESv2.so"
copy_if_present "$SCRIPT_DIR/bin/libvk_swiftshader.so" "$PREFIX/bin/libvk_swiftshader.so"
copy_if_present "$SCRIPT_DIR/bin/libvulkan.so.1" "$PREFIX/bin/libvulkan.so.1"
copy_if_present "$SCRIPT_DIR/bin/v8_context_snapshot.bin" "$PREFIX/bin/v8_context_snapshot.bin"
copy_if_present "$SCRIPT_DIR/bin/vk_swiftshader_icd.json" "$PREFIX/bin/vk_swiftshader_icd.json"
copy_if_present "$SCRIPT_DIR/bin/chrome-sandbox" "$PREFIX/bin/chrome-sandbox"
copy_if_present "$SCRIPT_DIR/bin/chrome_100_percent.pak" "$PREFIX/bin/chrome_100_percent.pak"
copy_if_present "$SCRIPT_DIR/bin/chrome_200_percent.pak" "$PREFIX/bin/chrome_200_percent.pak"
copy_if_present "$SCRIPT_DIR/bin/resources.pak" "$PREFIX/bin/resources.pak"
copy_if_present "$SCRIPT_DIR/bin/icudtl.dat" "$PREFIX/bin/icudtl.dat"
if [[ -d "$SCRIPT_DIR/bin/locales" ]]; then
  mkdir -p "$PREFIX/bin/locales"
  cp -a "$SCRIPT_DIR/bin/locales/." "$PREFIX/bin/locales/"
fi
install -m 644 "$SCRIPT_DIR/share/applications/verde.desktop" "$PREFIX/share/applications/verde.desktop"
install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/pixmaps/verde.png"
if [[ -e "$SCRIPT_DIR/share/verde/VERSION" ]]; then
  install -m 644 "$SCRIPT_DIR/share/verde/VERSION" "$PREFIX/share/verde/VERSION"
fi

echo "Installed Verde into $PREFIX"
echo "Binary: $PREFIX/bin/verde"
echo "Desktop entry: $PREFIX/share/applications/verde.desktop"
