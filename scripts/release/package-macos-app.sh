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

mkdir -p "$OUTPUT_DIR"

cd "$REPO_ROOT/packages/desktop"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$MACOS_MIN_VERSION}"
if [[ -n "${SDKROOT:-}" ]]; then
  export SDKROOT
fi

BUILD_ARGS=(zig build --release=safe -p "$PREFIX_DIR" -Dbrowser-backend=native_webview -Dversion="$VERSION")
"${BUILD_ARGS[@]}"

cd "$REPO_ROOT"
zig build daemon server --release=safe -Dversion="$VERSION" --prefix "$PREFIX_DIR"
(
  cd "$REPO_ROOT/packages/web_app"
  zig build --release=safe --prefix "$PREFIX_DIR"
  bun install --frozen-lockfile
  bun run build
)
rm -rf "$PREFIX_DIR/share/verde/web"
cp -a "$REPO_ROOT/packages/web_app/dist" "$PREFIX_DIR/share/verde/web"

mkdir -p \
  "$APP_DIR/Contents/MacOS" \
  "$APP_DIR/Contents/Resources" \
  "$APP_DIR/Contents/share/verde"

install -m 755 "$PREFIX_DIR/bin/verde" "$APP_DIR/Contents/MacOS/verde"
install -m 755 "$PREFIX_DIR/bin/verde-gui" "$APP_DIR/Contents/MacOS/verde-gui"
install -m 755 "$PREFIX_DIR/bin/verde-server" "$APP_DIR/Contents/MacOS/verde-server"
install -m 755 "$PREFIX_DIR/bin/verde-daemon" "$APP_DIR/Contents/MacOS/verde-daemon"
install -m 755 "$PREFIX_DIR/bin/verde-web" "$APP_DIR/Contents/MacOS/verde-web"
install -m 755 "$PREFIX_DIR/bin/libfff_c.dylib" "$APP_DIR/Contents/MacOS/libfff_c.dylib"
install -m 644 "$PREFIX_DIR/share/verde/provider_bridge.mjs" "$APP_DIR/Contents/Resources/provider_bridge.mjs"
install -m 644 "$PREFIX_DIR/share/verde/provider_bridge.mjs" "$APP_DIR/Contents/share/verde/provider_bridge.mjs"
cp -a "$PREFIX_DIR/share/verde/web" "$APP_DIR/Contents/share/verde/web"
if [[ -e "$APP_DIR/Contents/Resources/node_modules" ]]; then
  echo "app unexpectedly contains Contents/Resources/node_modules" >&2
  exit 1
fi
set_macos_build_version "$APP_DIR/Contents/MacOS/verde"
set_macos_build_version "$APP_DIR/Contents/MacOS/verde-gui"

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

# Notarization runs only when CI (or a developer) supplies an App Store
# Connect API key and a real signing identity; ad-hoc builds skip it.
NOTARIZE=0
if [[ -n "${VERDE_NOTARY_KEY_PATH:-}" ]]; then
  if [[ "${VERDE_CODESIGN_IDENTITY:--}" == "-" ]]; then
    echo "VERDE_NOTARY_KEY_PATH is set but VERDE_CODESIGN_IDENTITY is ad-hoc; cannot notarize" >&2
    exit 1
  fi
  : "${VERDE_NOTARY_KEY_ID:?VERDE_NOTARY_KEY_ID is required with VERDE_NOTARY_KEY_PATH}"
  : "${VERDE_NOTARY_ISSUER_ID:?VERDE_NOTARY_ISSUER_ID is required with VERDE_NOTARY_KEY_PATH}"
  NOTARIZE=1
fi

notarize() {
  local artifact="$1"
  local result_json="$WORK_DIR/notary-$(basename "$artifact").json"
  xcrun notarytool submit "$artifact" \
    --key "$VERDE_NOTARY_KEY_PATH" \
    --key-id "$VERDE_NOTARY_KEY_ID" \
    --issuer "$VERDE_NOTARY_ISSUER_ID" \
    --wait --timeout 45m \
    --output-format json >"$result_json" || true
  local status submission_id
  status="$(plutil -extract status raw -o - "$result_json" 2>/dev/null || echo unknown)"
  submission_id="$(plutil -extract id raw -o - "$result_json" 2>/dev/null || echo "")"
  echo "notarization of $(basename "$artifact"): $status (submission ${submission_id:-none})"
  if [[ "$status" != "Accepted" ]]; then
    cat "$result_json" >&2 || true
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$VERDE_NOTARY_KEY_PATH" \
        --key-id "$VERDE_NOTARY_KEY_ID" \
        --issuer "$VERDE_NOTARY_ISSUER_ID" >&2 || true
    fi
    return 1
  fi
}

if [[ "$NOTARIZE" -eq 1 ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$WORK_DIR/notarize-app.zip"
  notarize "$WORK_DIR/notarize-app.zip"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl --assess --type execute --verbose=2 "$APP_DIR"
fi

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

if [[ "$NOTARIZE" -eq 1 ]]; then
  DMG_PATH="$OUTPUT_DIR/verde-${VERSION}-macos-${ARCH}.dmg"
  codesign --force --timestamp --sign "$VERDE_CODESIGN_IDENTITY" "$DMG_PATH"
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi
