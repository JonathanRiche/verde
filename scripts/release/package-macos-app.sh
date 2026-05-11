#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <version> <output-dir>" >&2
  exit 1
fi

VERSION="$1"
OUTPUT_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CALLER_ROOT="$(pwd)"
if [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$CALLER_ROOT/$OUTPUT_DIR"
fi
ARCH="$(uname -m)"

case "$ARCH" in
  x86_64) ARCH="x86_64" ;;
  arm64) ARCH="arm64" ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

MACOS_MIN_VERSION="${VERDE_MACOS_MIN_VERSION:-13.0}"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PREFIX_DIR="$WORK_DIR/prefix"
APP_DIR="$WORK_DIR/Verde.app"
DMG_DIR="$WORK_DIR/dmg"
ICON_FILE="$APP_DIR/Contents/Resources/verde.icns"

source "$SCRIPT_DIR/cef-common.sh"
need_cmd zig
need_cmake
need_cmd bash
need_cmd xcrun

set_macos_build_version() {
  local binary="$1"
  local patched="$binary.patched"

  xcrun vtool \
    -set-build-version macos "$MACOS_MIN_VERSION" "$MACOS_SDK_VERSION" \
    -replace \
    -output "$patched" \
    "$binary" >/dev/null
  mv "$patched" "$binary"
  chmod 755 "$binary"
}

mkdir -p "$OUTPUT_DIR"

cd "$REPO_ROOT/packages/desktop"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$MACOS_MIN_VERSION}"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
BUILD_ARGS=(zig build --release=safe -p "$PREFIX_DIR")
if [[ "${VERDE_CEF_DISABLE_DOWNLOAD:-0}" != "1" ]]; then
  verde_cef_ensure_sdk macos "$ARCH"
  BUILD_ARGS+=("-Dcef-sdk-path=$VERDE_CEF_SDK_PATH_RESOLVED")
elif [[ -n "${VERDE_CEF_SDK_PATH:-}" ]]; then
  BUILD_ARGS+=("-Dcef-sdk-path=$VERDE_CEF_SDK_PATH")
fi
"${BUILD_ARGS[@]}"

mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources"

install -m 755 "$PREFIX_DIR/bin/verde" "$APP_DIR/Contents/MacOS/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.dylib" "$APP_DIR/Contents/MacOS/libfff_c.dylib"
ditto "$PREFIX_DIR/bin/SDL3.framework" "$APP_DIR/Contents/MacOS/SDL3.framework"
if [[ -x "$PREFIX_DIR/bin/verde-browser-cef" ]]; then
  install -m 755 "$PREFIX_DIR/bin/verde-browser-cef" "$APP_DIR/Contents/MacOS/verde-browser-cef"
fi
if [[ -x "$PREFIX_DIR/bin/verde-browser-cef-process" ]]; then
  install -m 755 "$PREFIX_DIR/bin/verde-browser-cef-process" "$APP_DIR/Contents/MacOS/verde-browser-cef-process"
fi
if [[ -d "$PREFIX_DIR/bin/Chromium Embedded Framework.framework" ]]; then
  ditto "$PREFIX_DIR/bin/Chromium Embedded Framework.framework" \
    "$APP_DIR/Contents/MacOS/Chromium Embedded Framework.framework"
fi
set_macos_build_version "$APP_DIR/Contents/MacOS/verde"

bash "$SCRIPT_DIR/fixup-macos-app.sh" "$APP_DIR"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Verde</string>
  <key>CFBundleExecutable</key>
  <string>verde</string>
  <key>CFBundleIconFile</key>
  <string>verde</string>
  <key>CFBundleIdentifier</key>
  <string>com.verde.native</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Verde</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MACOS_MIN_VERSION}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

bash "$SCRIPT_DIR/create-macos-icon.sh" \
  "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" \
  "$ICON_FILE"

ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$OUTPUT_DIR/verde-${VERSION}-macos-${ARCH}.zip"

mkdir -p "$DMG_DIR"
ditto "$APP_DIR" "$DMG_DIR/Verde.app"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create \
  -volname "Verde" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT_DIR/verde-${VERSION}-macos-${ARCH}.dmg" >/dev/null
