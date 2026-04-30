import { createFileRoute } from '@tanstack/solid-router'

const installScript = String.raw`#!/bin/sh
set -eu

REPO="JonathanRiche/verde"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
PREFIX="${'${'}VERDE_INSTALL_PREFIX:-$HOME/.local}"
MACOS_APP_DIR="${'${'}VERDE_MACOS_APP_DIR:-}"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'verde install: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

download() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    fail "missing required command: curl or wget"
  fi
}

latest_release_json() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H "Accept: application/vnd.github+json" "$API_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --header="Accept: application/vnd.github+json" "$API_URL"
  else
    fail "missing required command: curl or wget"
  fi
}

asset_url_for() {
  pattern="$1"
  latest_release_json |
    sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' |
    grep -E "$pattern" |
    head -n 1
}

make_temp_dir() {
  if command -v mktemp >/dev/null 2>&1; then
    mktemp -d 2>/dev/null || mktemp -d -t verde-install
  else
    dir="${'${'}TMPDIR:-/tmp}/verde-install-$$"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
  fi
}

os="$(uname -s)"
machine="$(uname -m)"

case "$os" in
  Linux) platform="linux" ;;
  Darwin) platform="macos" ;;
  *) fail "unsupported operating system: $os" ;;
esac

case "$machine" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) fail "unsupported architecture: $machine" ;;
esac

if [ "$platform" = "linux" ] && [ "$arch" != "x86_64" ]; then
  fail "Linux release artifacts are currently published for x86_64 only"
fi

work_dir="$(make_temp_dir)"
trap 'rm -rf "$work_dir"' EXIT INT TERM

if [ "$platform" = "linux" ]; then
  need_cmd tar
  need_cmd bash
  asset_url="$(asset_url_for "verde-.+-linux-$arch[.]tar[.]gz$")"
  [ -n "$asset_url" ] || fail "could not find latest Linux $arch release asset"

  archive="$work_dir/verde-linux-$arch.tar.gz"
  say "Downloading Verde for Linux $arch..."
  download "$asset_url" "$archive"

  tar -xzf "$archive" -C "$work_dir"
  package_dir="$(find "$work_dir" -maxdepth 1 -type d -name 'verde-*-linux-*' | head -n 1)"
  [ -n "$package_dir" ] || fail "release archive did not contain a Verde package directory"

  say "Installing Verde into $PREFIX..."
  bash "$package_dir/install-local.sh" "$PREFIX"
  say "Done. Run Verde with: $PREFIX/bin/verde"
else
  need_cmd unzip
  asset_url="$(asset_url_for "verde-.+-macos-$arch[.]zip$")"
  [ -n "$asset_url" ] || fail "could not find latest macOS $arch release asset"

  archive="$work_dir/verde-macos-$arch.zip"
  say "Downloading Verde for macOS $arch..."
  download "$asset_url" "$archive"

  unzip -q "$archive" -d "$work_dir/unpacked"
  app_path="$(find "$work_dir/unpacked" -maxdepth 2 -type d -name 'Verde.app' | head -n 1)"
  [ -n "$app_path" ] || fail "release archive did not contain Verde.app"

  if [ -z "$MACOS_APP_DIR" ]; then
    if [ -w /Applications ]; then
      MACOS_APP_DIR="/Applications"
    else
      MACOS_APP_DIR="$HOME/Applications"
    fi
  fi

  mkdir -p "$MACOS_APP_DIR"
  rm -rf "$MACOS_APP_DIR/Verde.app"
  cp -R "$app_path" "$MACOS_APP_DIR/Verde.app"
  say "Done. Installed Verde.app into $MACOS_APP_DIR"
fi
`

export const Route = createFileRoute('/install.sh')({
  server: {
    handlers: {
      GET: async () =>
        new Response(installScript, {
          headers: {
            'Content-Type': 'text/x-shellscript; charset=utf-8',
            'Cache-Control': 'public, max-age=600',
          },
        }),
    },
  },
})
