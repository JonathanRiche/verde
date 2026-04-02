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
CALLER_ROOT="$(pwd)"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$CALLER_ROOT/$OUTPUT_DIR"
fi
ARCH="$(uname -m)"
CACHE_ROOT="${VERDE_CEF_CACHE_DIR:-$HOME/.cache/verde/cef-sdk}"
CEF_BASENAME="cef_binary_146.0.9+g3ca6a87+chromium-146.0.7680.165_linux64_minimal"
CEF_ARCHIVE="$CEF_BASENAME.tar.bz2"
CEF_URL="${VERDE_CEF_URL:-https://cef-builds.spotifycdn.com/cef_binary_146.0.9%2Bg3ca6a87%2Bchromium-146.0.7680.165_linux64_minimal.tar.bz2}"
CEF_SDK_PATH="${VERDE_CEF_SDK_PATH:-$CACHE_ROOT/$CEF_BASENAME}"

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

mkdir -p "$OUTPUT_DIR"
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
zig build --release=safe -p "$PREFIX_DIR" -Dcef-sdk-path="$CEF_SDK_PATH"

mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/share/applications" \
  "$PACKAGE_ROOT/share/pixmaps"

install -m 755 "$PREFIX_DIR/bin/verde" "$PACKAGE_ROOT/bin/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.so" "$PACKAGE_ROOT/bin/libfff_c.so"
install -m 755 "$PREFIX_DIR/bin/libSDL3.so" "$PACKAGE_ROOT/bin/libSDL3.so"
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
