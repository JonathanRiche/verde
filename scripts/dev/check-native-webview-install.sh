#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX_DIR="$(mktemp -d /tmp/verde-native-install.XXXXXX)"
trap 'rm -rf "$PREFIX_DIR"' EXIT

(
  cd "$REPO_ROOT"
  zig build --release=safe -p "$PREFIX_DIR" -Dbrowser-backend=native_webview
)

required_payload=(
  "verde"
)

if [[ "$(uname -s)" == "Linux" ]]; then
  required_payload+=("verde-browser-linux")
  required_payload+=("verde-browser-linux-wpe")
fi

for name in "${required_payload[@]}"; do
  if [[ ! -e "$PREFIX_DIR/bin/$name" ]]; then
    echo "native webview install is missing required payload: bin/$name" >&2
    exit 1
  fi
done

cef_payload=(
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
  "Chromium Embedded Framework.framework"
)

for name in "${cef_payload[@]}"; do
  if [[ -e "$PREFIX_DIR/bin/$name" ]]; then
    echo "native webview install unexpectedly contains CEF payload: bin/$name" >&2
    exit 1
  fi
done

echo "native webview install payload check passed"
