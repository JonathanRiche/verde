#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX_DIR="$(mktemp -d /tmp/verde-native-install.XXXXXX)"
SMOKE_CWD="$(mktemp -d /tmp/verde-native-cwd.XXXXXX)"
trap 'rm -rf "$PREFIX_DIR" "$SMOKE_CWD"' EXIT

(
  cd "$REPO_ROOT"
  zig build --release=safe -p "$PREFIX_DIR" -Dbrowser-backend=native_webview
)

required_payload=(
  "verde"
)

if [[ "$(uname -s)" == "Linux" ]]; then
  required_payload+=("verde-browser-linux" "libfff_c.so")
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

if [[ "$(uname -s)" == "Linux" ]]; then
  if ! command -v readelf >/dev/null 2>&1; then
    echo "missing required command for native install verification: readelf" >&2
    exit 1
  fi

  fff_needed="$(
    readelf -d "$PREFIX_DIR/bin/verde" |
      sed -n 's/.*Shared library: \[\([^]]*libfff_c\.so\)\].*/\1/p'
  )"
  if [[ -z "$fff_needed" ]]; then
    echo "native webview install has no libfff_c.so dynamic dependency" >&2
    exit 1
  fi
  if [[ "$fff_needed" == */* ]]; then
    echo "native webview install embeds a path-qualified libfff dependency: $fff_needed" >&2
    exit 1
  fi
fi

(
  cd "$SMOKE_CWD"
  "$PREFIX_DIR/bin/verde" version --json >verde-version.json
)
build_version_path="$PREFIX_DIR/share/verde/BUILD_VERSION"
if [[ ! -f "$build_version_path" ]]; then
  echo "native webview install is missing its BUILD_VERSION stamp" >&2
  exit 1
fi
build_version="$(tr -d '\r\n' <"$build_version_path")"
expected_version_json="{\"name\":\"verde\",\"version\":\"$build_version\"}"
if ! grep -Fqx "$expected_version_json" "$SMOKE_CWD/verde-version.json"; then
  echo "native webview install CLI version does not match BUILD_VERSION" >&2
  exit 1
fi

echo "native webview install payload check passed"
