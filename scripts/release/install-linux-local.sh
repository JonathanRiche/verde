#!/usr/bin/env bash
set -euo pipefail

PREFIX="${1:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

  for name in "${cef_payload[@]}"; do
    if [[ -e "$prefix/bin/$name" ]]; then
      echo "native webview install unexpectedly contains CEF payload: bin/$name" >&2
      exit 1
    fi
  done
}

wpe_runtime_hint() {
  cat >&2 <<'EOF'
Verde's Linux browser pane uses WPE WebKit.
Install the WPE WebKit runtime packages for your distro if the browser pane does not open:
  Debian 13+: sudo apt install libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1 libjavascriptcoregtk-6.0-1 libegl1 libgles2
  Arch:       sudo pacman -S wpewebkit wpebackend-fdo
  Fedora:     sudo dnf install wpewebkit wpebackend-fdo
EOF
}

warn_missing_wpe_runtime() {
  local helper_path="$1"

  if [[ ! -x "$helper_path" ]]; then
    return
  fi
  if ! command -v ldd >/dev/null 2>&1; then
    return
  fi

  local missing
  missing="$(ldd "$helper_path" 2>/dev/null | awk '/not found/ { print $1 }' | sort -u | tr '\n' ' ')"
  if [[ -n "$missing" ]]; then
    echo "warning: Verde browser helper is missing runtime libraries: $missing" >&2
    wpe_runtime_hint
  fi
}

install -m 755 "$SCRIPT_DIR/bin/verde" "$PREFIX/bin/verde"
cat > "$PREFIX/bin/verde-launch" <<EOF
#!/usr/bin/env sh
script_dir="$PREFIX/bin"
check_wpe_runtime() {
  helper="\$script_dir/verde-browser-linux"
  if [ ! -x "\$helper" ] || ! command -v ldd >/dev/null 2>&1; then
    return
  fi
  missing="\$(ldd "\$helper" 2>/dev/null | awk '/not found/ { print \$1 }' | sort -u | tr '\n' ' ')"
  if [ -z "\$missing" ]; then
    return
  fi
  message="Verde's Linux browser pane needs WPE WebKit runtime libraries. Missing: \$missing"
  echo "\$message" >&2
  echo "Install WPE WebKit packages for your distro, then reopen Verde." >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Verde needs WPE WebKit" "\$message"
  fi
}

check_wpe_runtime
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
warn_missing_wpe_runtime "$PREFIX/bin/verde-browser-linux"

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
echo "Linux browser runtime: WPE WebKit"
