#!/usr/bin/env bash
# Installs desktop build dependencies, then runs the same check the build tasks use.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEBVIEW_PKG_CONFIG=(wpe-webkit-2.0 wpebackend-fdo-1.0 egl glesv2 javascriptcoregtk-6.0)

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_native_webview_deps() {
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "${WEBVIEW_PKG_CONFIG[@]}"; then
    return
  fi

  echo "installing native webview build dependencies (WPE WebKit, WPEBackend-fdo, EGL, GLESv2, JavaScriptCoreGTK 6.0)"
  if command -v pacman >/dev/null 2>&1; then
    as_root pacman -S --needed --noconfirm pkgconf wpewebkit wpebackend-fdo webkitgtk-6.0 libglvnd
  elif command -v apt-get >/dev/null 2>&1; then
    as_root apt-get install -y pkg-config libwpewebkit-2.0-dev libwpebackend-fdo-1.0-dev \
      libjavascriptcoregtk-6.0-dev libegl-dev libgles-dev
  elif command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y pkgconf-pkg-config wpewebkit-devel wpebackend-fdo-devel \
      javascriptcoregtk6.0-devel libglvnd-devel
  else
    echo "unsupported package manager; install the WPE WebKit development packages for your distro" >&2
    exit 1
  fi
}

if [[ "$(uname -s)" == "Linux" && "${VERDE_BROWSER_BACKEND:-native_webview}" == "native_webview" ]]; then
  install_native_webview_deps
fi

if command -v bun >/dev/null 2>&1 && [[ ! -d "$REPO_ROOT/node_modules/@anthropic-ai/claude-agent-sdk" ]]; then
  mkdir -p /tmp/verde-bun-tmp
  (cd "$REPO_ROOT" && BUN_TMPDIR=/tmp/verde-bun-tmp bun install --production)
fi

exec bash "$REPO_ROOT/scripts/dev/check-desktop-build-deps.sh"
