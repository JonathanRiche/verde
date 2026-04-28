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
