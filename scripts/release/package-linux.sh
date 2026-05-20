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

  local needed_entries
  needed_entries="$(readelf -d "$path")"
  if ! grep -Fq "$original_needed" <<<"$needed_entries"; then
    return
  fi

  patchelf --replace-needed "$original_needed" "$replacement_needed" "$path"
}

copy_runtime_library() {
  local library_name="$1"
  local destination_dir="$2"
  local library_path=""

  if command -v ldconfig >/dev/null 2>&1; then
    library_path="$(ldconfig -p | awk -v name="$library_name" '$1 == name && path == "" { path = $NF } END { print path }')"
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
    soname="$(readelf -d "$(readlink -f "$library_path")" | awk '/SONAME/ && soname == "" { gsub(/[\[\]]/, "", $5); soname = $5 } END { print soname }')"
    if [[ -n "$soname" && "$soname" != "$real_name" ]]; then
      ln -sfn "$real_name" "$destination_dir/$soname"
    fi
  fi
}

assert_no_cef_payload() {
  local root_dir="$1"
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
    if [[ -e "$root_dir/bin/$name" ]]; then
      echo "native webview package unexpectedly contains CEF payload: bin/$name" >&2
      exit 1
    fi
  done
}

write_linux_launcher() {
  local launcher_path="$1"

  cat > "$launcher_path" <<'EOF'
#!/usr/bin/env sh
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

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
  chmod 755 "$launcher_path"
}

mkdir -p "$OUTPUT_DIR"
BUILD_ARGS=(zig build --release=safe -p "$PREFIX_DIR" -Dbrowser-backend=native_webview)

cd "$DESKTOP_ROOT"
"${BUILD_ARGS[@]}"

mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/share/verde" \
  "$PACKAGE_ROOT/share/applications" \
  "$PACKAGE_ROOT/share/pixmaps" \
  "$PACKAGE_ROOT/share/icons/hicolor/256x256/apps"

install -m 755 "$PREFIX_DIR/bin/verde" "$PACKAGE_ROOT/bin/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.so" "$PACKAGE_ROOT/bin/libfff_c.so"
install -m 755 "$PREFIX_DIR/bin/libSDL3.so" "$PACKAGE_ROOT/bin/libSDL3.so"
copy_runtime_library "libSDL3_ttf.so" "$PACKAGE_ROOT/bin"
if [[ -x "$PREFIX_DIR/bin/verde-browser-linux" ]]; then
  install -m 755 "$PREFIX_DIR/bin/verde-browser-linux" "$PACKAGE_ROOT/bin/verde-browser-linux"
fi
assert_no_cef_payload "$PACKAGE_ROOT"
write_linux_launcher "$PACKAGE_ROOT/bin/verde-launch"
install -m 644 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" "$PACKAGE_ROOT/share/pixmaps/verde.png"
install -m 644 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" "$PACKAGE_ROOT/share/icons/hicolor/256x256/apps/verde.png"
printf '%s\n' "$VERSION" > "$PACKAGE_ROOT/share/verde/VERSION"
install -m 644 "$PREFIX_DIR/share/verde/provider_bridge.mjs" "$PACKAGE_ROOT/share/verde/provider_bridge.mjs"
install -m 755 "$REPO_ROOT/scripts/release/install-linux-local.sh" "$PACKAGE_ROOT/install-local.sh"
install -m 644 "$REPO_ROOT/README.md" "$PACKAGE_ROOT/README.md"

if [[ -e "$PACKAGE_ROOT/share/verde/node_modules" ]]; then
  echo "package unexpectedly contains share/verde/node_modules" >&2
  exit 1
fi

normalize_fff_dependency \
  "$PACKAGE_ROOT/bin/verde" \
  "$REPO_ROOT/vendor/fff/target/release/libfff_c.so" \
  "libfff_c.so"

strip_debug_symbols "$PACKAGE_ROOT/bin/verde"
strip_debug_symbols "$PACKAGE_ROOT/bin/libSDL3.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/libSDL3_ttf.so"
strip_debug_symbols "$PACKAGE_ROOT/bin/verde-browser-linux"
strip_debug_symbols "$PACKAGE_ROOT/bin/libfff_c.so"

cat > "$PACKAGE_ROOT/share/applications/verde.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Verde
Comment=Desktop chat app for Codex and OpenCode
Exec=verde-launch
Icon=verde
Terminal=false
Categories=Development;
StartupNotify=false
StartupWMClass=com.verde.native
EOF

tar -C "$WORK_DIR" -czf "$OUTPUT_DIR/verde-${VERSION}-linux-${ARCH}.tar.gz" "$(basename "$PACKAGE_ROOT")"
