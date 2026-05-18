#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    case "$1" in
      bun)
        echo "install Bun first: https://bun.sh/docs/installation" >&2
        ;;
    esac
    exit 1
  fi
}

need_cmd bun

if [[ "$(uname -s)" == "Linux" && "${VERDE_BROWSER_BACKEND:-native_webview}" == "native_webview" ]]; then
  if ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1; then
    echo "missing native webview build dependencies: gtk+-3.0 and webkit2gtk-4.1" >&2
    echo "install the GTK 3 and WebKitGTK 4.1 development packages for your distro" >&2
    exit 1
  fi
fi
