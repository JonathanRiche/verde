#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "this installer only works on macOS" >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [applications-dir]" >&2
  exit 1
fi

APPLICATIONS_DIR="${1:-${VERDE_APPLICATIONS_DIR:-$HOME/Applications}}"
VERSION="${VERDE_APP_VERSION:-0.0.0-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

PREFIX_DIR="$WORK_DIR/prefix"
APP_DIR="$WORK_DIR/Verde.app"
ICONSET_DIR="$WORK_DIR/verde.iconset"
ICON_FILE="$APP_DIR/Contents/Resources/verde.icns"
DEST_APP_DIR="$APPLICATIONS_DIR/Verde.app"

source "$SCRIPT_DIR/cef-common.sh"
ARCH="$(uname -m)"
need_cmd zig
need_cmake
need_cmd bash

cd "$REPO_ROOT"
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
  "$APP_DIR/Contents/Resources" \
  "$ICONSET_DIR"

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

"$SCRIPT_DIR/fixup-macos-app.sh" "$APP_DIR"

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
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

sips -z 16 16 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"

mkdir -p "$APPLICATIONS_DIR"
rm -rf "$DEST_APP_DIR"
ditto "$APP_DIR" "$DEST_APP_DIR"

echo "Installed $DEST_APP_DIR"
if [[ "${VERDE_CEF_DISABLE_DOWNLOAD:-0}" != "1" ]]; then
  echo "Bundled CEF SDK: ${VERDE_CEF_SDK_PATH_RESOLVED}"
fi
echo "Open Verde from Finder or Spotlight, then keep it in the Dock if desired."
