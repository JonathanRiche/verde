#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" && -z "${HOME:-}" ]]; then
  echo "install-local.sh: HOME is not set; pass an install prefix, e.g. ./install-local.sh /opt/verde" >&2
  exit 1
fi
PREFIX="${1:-$HOME/.local}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p \
  "$PREFIX/bin" \
  "$PREFIX/share/verde" \
  "$PREFIX/share/applications" \
  "$PREFIX/share/pixmaps" \
  "$PREFIX/share/icons/hicolor/256x256/apps"
# The launcher and desktop entry embed this path, so a relative prefix must not
# leak into them.
PREFIX="$(CDPATH= cd -- "$PREFIX" && pwd)"

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
    # Keep libraries mapped by a running Verde intact until it restarts.
    cp -a --remove-destination $pattern "$dest_dir/"
  fi
}

wpe_runtime_hint() {
  cat >&2 <<'EOF'
Verde's Linux browser pane uses WPE WebKit.
Install the WPE WebKit runtime package for your distro if the browser pane does not open:
  Debian 13+/Ubuntu: sudo apt install libwpewebkit-2.0-1
  Arch:              sudo pacman -S wpewebkit
  Fedora:            sudo dnf install wpewebkit
  openSUSE:          sudo zypper install libWPEWebKit-2_0-1
EOF
}

# Quote a value as one single-quoted POSIX shell word.
sh_single_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Quote one Desktop Entry Exec argument: escape \ " ` $ inside double quotes,
# apply the string-value escape on top (so a literal \ becomes \\\\), and
# write % as %%.
desktop_exec_arg() {
  local escaped
  escaped="$(printf '%s' "$1" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g' -e 's/%/%%/g')"
  printf '"%s"' "$escaped"
}

# Sets wpe_runtime_status to ok, missing, or unchecked.
wpe_runtime_status="unchecked"
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
    wpe_runtime_status="missing"
    echo "warning: Verde browser helper is missing runtime libraries: $missing" >&2
    wpe_runtime_hint
  else
    wpe_runtime_status="ok"
  fi
}

install -m 755 "$SCRIPT_DIR/bin/verde" "$PREFIX/bin/verde"
install -m 755 "$SCRIPT_DIR/bin/verde-gui" "$PREFIX/bin/verde-gui"
for runtime_binary in verde-server verde-daemon verde-web; do
  if [[ -x "$SCRIPT_DIR/bin/$runtime_binary" ]]; then
    install -m 755 "$SCRIPT_DIR/bin/$runtime_binary" "$PREFIX/bin/$runtime_binary"
  fi
done
{
  printf '#!/usr/bin/env sh\n'
  # Single-quote the install path so quotes, $, and backticks stay literal.
  printf 'script_dir=%s\n' "$(sh_single_quote "$PREFIX/bin")"
  cat <<'EOF'
check_wpe_runtime() {
  helper="$script_dir/verde-browser-linux"
  if [ ! -x "$helper" ] || ! command -v ldd >/dev/null 2>&1; then
    return
  fi
  missing="$(ldd "$helper" 2>/dev/null | awk '/not found/ { print $1 }' | sort -u | tr '\n' ' ')"
  if [ -z "$missing" ]; then
    return
  fi
  message="Verde's Linux browser pane needs WPE WebKit runtime libraries. Missing: $missing"
  echo "$message" >&2
  echo "Install WPE WebKit packages for your distro, then reopen Verde." >&2
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Verde needs WPE WebKit" "$message"
  fi
}

check_wpe_runtime
if command -v setsid >/dev/null 2>&1; then
  setsid "$script_dir/verde" >/dev/null 2>&1 &
else
  "$script_dir/verde" >/dev/null 2>&1 &
fi
EOF
} > "$PREFIX/bin/verde-launch"
chmod 755 "$PREFIX/bin/verde-launch"
install -m 755 "$SCRIPT_DIR/bin/libfff_c.so" "$PREFIX/bin/libfff_c.so"
# Pre-Palette releases shipped SDL3 next to the binaries; drop the stale copies.
rm -f "$PREFIX/bin/libSDL3.so" "$PREFIX"/bin/libSDL3_ttf.so*
copy_if_present "$SCRIPT_DIR/bin/verde-browser-linux" "$PREFIX/bin/verde-browser-linux"
install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/pixmaps/verde.png"
if [[ -e "$SCRIPT_DIR/share/icons/hicolor/256x256/apps/verde.png" ]]; then
  install -m 644 "$SCRIPT_DIR/share/icons/hicolor/256x256/apps/verde.png" "$PREFIX/share/icons/hicolor/256x256/apps/verde.png"
else
  install -m 644 "$SCRIPT_DIR/share/pixmaps/verde.png" "$PREFIX/share/icons/hicolor/256x256/apps/verde.png"
fi
desktop_exec="$(desktop_exec_arg "$PREFIX/bin/verde-launch")"
cat > "$PREFIX/share/applications/verde.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Verde
Comment=Run coding agents side by side
Exec=$desktop_exec
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
if [[ -d "$SCRIPT_DIR/share/verde/web" ]]; then
  rm -rf "$PREFIX/share/verde/web"
  cp -a "$SCRIPT_DIR/share/verde/web" "$PREFIX/share/verde/web"
fi
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
case "$wpe_runtime_status" in
  ok) echo "Linux browser runtime: WPE WebKit (found)" ;;
  missing) echo "Linux browser runtime: WPE WebKit is missing; install it to use the browser pane (see warning above)" ;;
  *) echo "Linux browser runtime: WPE WebKit (not checked)" ;;
esac
