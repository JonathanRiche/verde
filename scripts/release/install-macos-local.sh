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
ICON_FILE="$APP_DIR/Contents/Resources/verde.icns"
DEST_APP_DIR="$APPLICATIONS_DIR/Verde.app"

ARCH="$(uname -m)"
BROWSER_BACKEND="${VERDE_BROWSER_BACKEND:-native_webview}"
MACOS_MIN_VERSION="${VERDE_MACOS_MIN_VERSION:-13.0}"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd zig
need_cmd bash
need_cmd xcrun
if [[ "$BROWSER_BACKEND" == "cef" ]]; then
  source "$SCRIPT_DIR/cef-common.sh"
  need_cmake
fi

set_macos_build_version() {
  local binary="$1"
  local patched="$binary.patched"

  # See packages/release/package-macos-app.sh for the rationale: Zig's
  # MACOSX_DEPLOYMENT_TARGET already bakes the build-version load command,
  # but `vtool -replace` can fail on x86_64 binaries that lack header
  # padding. Treat the patch as best-effort.
  if ! xcrun vtool \
    -set-build-version macos "$MACOS_MIN_VERSION" "$MACOS_SDK_VERSION" \
    -replace \
    -output "$patched" \
    "$binary" >/dev/null 2>&1; then
    echo "warning: vtool -replace could not patch $binary; keeping linker-emitted build-version" >&2
    rm -f "$patched"
    chmod 755 "$binary"
    return 0
  fi
  mv "$patched" "$binary"
  chmod 755 "$binary"
}

assert_no_cef_payload() {
  local app_dir="$1"
  local macos_dir="$app_dir/Contents/MacOS"
  local cef_payload=(
    "verde-browser-cef"
    "verde-browser-cef-process"
    "Chromium Embedded Framework.framework"
  )

  if [[ "$BROWSER_BACKEND" == "cef" ]]; then
    return
  fi

  for name in "${cef_payload[@]}"; do
    if [[ -e "$macos_dir/$name" ]]; then
      echo "native webview app unexpectedly contains CEF payload: Contents/MacOS/$name" >&2
      exit 1
    fi
  done
}

cd "$REPO_ROOT/packages/desktop"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$MACOS_MIN_VERSION}"
if [[ -n "${SDKROOT:-}" ]]; then
  export SDKROOT
fi

compile_palette_metallib() {
  local shader="$1"
  local air="$WORK_DIR/$(basename "$shader" .msl).air"
  local metallib="${shader%.msl}.metallib"
  if ! xcrun -sdk macosx -find metal >/dev/null 2>&1; then
    if [[ -f "$metallib" ]]; then
      echo "warning: xcrun metal unavailable; using existing $(basename "$metallib")" >&2
      return 0
    fi
    echo "missing required command: xcrun metal" >&2
    exit 1
  fi
  xcrun -sdk macosx metal -x metal -c "$shader" -o "$air"
  xcrun -sdk macosx metallib "$air" -o "$metallib"
}

compile_palette_metallib "$REPO_ROOT/packages/palette/src/shaders/ui.vert.msl"
compile_palette_metallib "$REPO_ROOT/packages/palette/src/shaders/ui.solid.frag.msl"
compile_palette_metallib "$REPO_ROOT/packages/palette/src/shaders/ui.text.frag.msl"
compile_palette_metallib "$REPO_ROOT/packages/palette/src/shaders/ui.image.frag.msl"

BUILD_ARGS=(zig build --release=safe -p "$PREFIX_DIR" "-Dbrowser-backend=$BROWSER_BACKEND")
if [[ "$BROWSER_BACKEND" == "cef" && "${VERDE_CEF_DISABLE_DOWNLOAD:-0}" != "1" ]]; then
  verde_cef_ensure_sdk macos "$ARCH"
  BUILD_ARGS+=("-Dcef-sdk-path=$VERDE_CEF_SDK_PATH_RESOLVED")
elif [[ "$BROWSER_BACKEND" == "cef" && -n "${VERDE_CEF_SDK_PATH:-}" ]]; then
  BUILD_ARGS+=("-Dcef-sdk-path=$VERDE_CEF_SDK_PATH")
fi
"${BUILD_ARGS[@]}"

mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources"

install -m 755 "$PREFIX_DIR/bin/verde" "$APP_DIR/Contents/MacOS/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.dylib" "$APP_DIR/Contents/MacOS/libfff_c.dylib"
ditto "$PREFIX_DIR/bin/SDL3.framework" "$APP_DIR/Contents/MacOS/SDL3.framework"
if [[ "$BROWSER_BACKEND" == "cef" ]]; then
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
fi
assert_no_cef_payload "$APP_DIR"
set_macos_build_version "$APP_DIR/Contents/MacOS/verde"

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
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

bash "$SCRIPT_DIR/create-macos-icon.sh" \
  "$REPO_ROOT/packages/desktop/src/assets/verde_logo.png" \
  "$ICON_FILE"

bash "$SCRIPT_DIR/fixup-macos-app.sh" "$APP_DIR"

mkdir -p "$APPLICATIONS_DIR"
rm -rf "$DEST_APP_DIR"
ditto "$APP_DIR" "$DEST_APP_DIR"

echo "Installed $DEST_APP_DIR"
if [[ "$BROWSER_BACKEND" == "cef" && "${VERDE_CEF_DISABLE_DOWNLOAD:-0}" != "1" ]]; then
  echo "Bundled CEF SDK: ${VERDE_CEF_SDK_PATH_RESOLVED}"
fi
echo "Open Verde from Finder or Spotlight, then keep it in the Dock if desired."
