#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSER_BACKEND="${VERDE_BROWSER_BACKEND:-native_webview}"

mkdir -p \
  "$PREFIX/bin" \
  "$PREFIX/share/verde" \
  "$PREFIX/share/applications" \
  "$PREFIX/share/pixmaps" \
  "$PREFIX/share/icons/hicolor/256x256/apps"

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

assert_no_cef_payload() {
  local prefix="$1"
  local cef_payload=(
    "verde-browser-cef"
    "verde-browser-cef-process"
    "libcef.so"
    "chrome-sandbox"
    "chrome_100_percent.pak"
    "chrome_200_percent.pak"
    "resources.pak"
    "icudtl.dat"
    "v8_context_snapshot.bin"
    "vk_swiftshader_icd.json"
    "locales"
  )

  if [[ "$BROWSER_BACKEND" == "cef" ]]; then
    return
  fi

  for name in "${cef_payload[@]}"; do
    if [[ -e "$prefix/bin/$name" ]]; then
      echo "native webview install unexpectedly contains CEF payload: bin/$name" >&2
      exit 1
    fi
  done
}

install -m 755 "$SCRIPT_DIR/bin/verde" "$PREFIX/bin/verde"
cat > "$PREFIX/bin/verde-launch" <<EOF
#!/usr/bin/env sh
if command -v setsid >/dev/null 2>&1; then
  setsid "$PREFIX/bin/verde" >/dev/null 2>&1 &
else
  "$PREFIX/bin/verde" >/dev/null 2>&1 &
fi
EOF
chmod 755 "$PREFIX/bin/verde-launch"
install -m 755 "$SCRIPT_DIR/bin/libfff_c.so" "$PREFIX/bin/libfff_c.so"
copy_if_present "$SCRIPT_DIR/bin/libSDL3.so" "$PREFIX/bin/libSDL3.so"
copy_glob_if_present "$SCRIPT_DIR/bin/libSDL3_ttf.so*" "$PREFIX/bin"
copy_if_present "$SCRIPT_DIR/bin/verde-browser-linux" "$PREFIX/bin/verde-browser-linux"
copy_if_present "$SCRIPT_DIR/bin/verde-browser-linux-wpe" "$PREFIX/bin/verde-browser-linux-wpe"
if [[ "$BROWSER_BACKEND" == "cef" ]]; then
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
fi
install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/pixmaps/verde.png"
if [[ -e "$SCRIPT_DIR/share/icons/hicolor/256x256/apps/verde.png" ]]; then
  install -m 644 "$SCRIPT_DIR/share/icons/hicolor/256x256/apps/verde.png" "$PREFIX/share/icons/hicolor/256x256/apps/verde.png"
else
  install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/icons/hicolor/256x256/apps/verde.png"
fi
cat > "$PREFIX/share/applications/verde.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Verde
Comment=Desktop chat app for Codex and OpenCode
Exec=$PREFIX/bin/verde-launch
Icon=verde
Terminal=false
Categories=Development;
StartupNotify=false
StartupWMClass=com.verde.native
EOF
if [[ -e "$SCRIPT_DIR/share/verde/VERSION" ]]; then
  install -m 644 "$SCRIPT_DIR/share/verde/VERSION" "$PREFIX/share/verde/VERSION"
fi
rm -rf "$PREFIX/share/verde/node_modules"
if [[ -e "$SCRIPT_DIR/share/verde/provider_bridge.mjs" ]]; then
  install -m 644 "$SCRIPT_DIR/share/verde/provider_bridge.mjs" "$PREFIX/share/verde/provider_bridge.mjs"
fi
assert_no_cef_payload "$PREFIX"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t -f "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q "$PREFIX/share/applications" >/dev/null 2>&1 || true
fi
if command -v xdg-desktop-menu >/dev/null 2>&1; then
  xdg-desktop-menu forceupdate >/dev/null 2>&1 || true
fi

echo "Installed Verde into $PREFIX"
echo "Binary: $PREFIX/bin/verde"
echo "Desktop entry: $PREFIX/share/applications/verde.desktop"
