#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

if [[ ! -d "$REPO_ROOT/node_modules/@anthropic-ai/claude-agent-sdk" ]]; then
  echo "missing provider bridge build dependencies in node_modules" >&2
  echo "run: BUN_TMPDIR=/tmp/verde-bun-tmp bun install --production" >&2
  exit 1
fi

if [[ "$(uname -s)" == "Linux" && "${VERDE_BROWSER_BACKEND:-native_webview}" == "native_webview" ]]; then
  if ! pkg-config --exists gtk+-3.0 webkit2gtk-4.1; then
    echo "missing native webview build dependencies: gtk+-3.0 and webkit2gtk-4.1" >&2
    echo "install the GTK 3 and WebKitGTK 4.1 development packages for your distro" >&2
    exit 1
  fi
fi
