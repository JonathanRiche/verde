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

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need_cmd zig
need_cmd bash
need_cmd xcrun

set_macos_build_version() {
  local binary="$1"
  local patched="$binary.patched"

  # Zig 0.16 emits LC_BUILD_VERSION when MACOSX_DEPLOYMENT_TARGET is set
  # (which we export above), so the binary already advertises the right
  # platform/SDK at link time. `vtool -replace` requires extra Mach-O
  # header padding that Zig does not always reserve — notably on x86_64
  # macOS — and fails with "not enough space to hold load commands".
  # Treat the rewrite as best-effort: if it fails we keep Zig's own
  # build-version, which is correct.
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

  for name in "${cef_payload[@]}"; do
    if [[ -e "$macos_dir/$name" ]]; then
      echo "native webview app unexpectedly contains CEF payload: Contents/MacOS/$name" >&2
      exit 1
    fi
  done
}

mkdir -p "$OUTPUT_DIR"

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

BUILD_ARGS=(zig build --release=safe -p "$PREFIX_DIR" -Dbrowser-backend=native_webview)
"${BUILD_ARGS[@]}"

mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources"

install -m 755 "$PREFIX_DIR/bin/verde" "$APP_DIR/Contents/MacOS/verde"
install -m 755 "$PREFIX_DIR/bin/libfff_c.dylib" "$APP_DIR/Contents/MacOS/libfff_c.dylib"
ditto "$PREFIX_DIR/bin/SDL3.framework" "$APP_DIR/Contents/MacOS/SDL3.framework"
assert_no_cef_payload "$APP_DIR"
install -m 644 "$PREFIX_DIR/share/verde/provider_bridge.mjs" "$APP_DIR/Contents/Resources/provider_bridge.mjs"
if [[ -e "$APP_DIR/Contents/Resources/node_modules" ]]; then
  echo "app unexpectedly contains Contents/Resources/node_modules" >&2
  exit 1
fi
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
