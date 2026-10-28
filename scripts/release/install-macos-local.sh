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
  <key>NSDocumentsFolderUsageDescription</key>
  <string>Verde opens project folders in Documents so you and your agents can work in them.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Verde opens project folders on the Desktop so you and your agents can work in them.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Verde opens project folders in Downloads so you and your agents can work in them.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>Verde opens project folders on network drives so you and your agents can work in them.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>Verde opens project folders on external drives so you and your agents can work in them.</string>
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
echo "Open Verde from Finder or Spotlight, then keep it in the Dock if desired."
