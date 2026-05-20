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

linux_wpe_runtime_packages() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' "wpewebkit wpebackend-fdo"
  elif command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1 libjavascriptcoregtk-6.0-1 libegl1 libgles2"
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' "wpewebkit wpebackend-fdo"
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' "libWPEWebKit-2_0-1 libwpebackend-fdo-1_0-1 libjavascriptcoregtk-6_0-1 libEGL1 libGLESv2-2"
  fi
}

linux_wpe_runtime_install_cmd() {
  packages="$(linux_wpe_runtime_packages || true)"
  [ -n "$packages" ] || return 1

  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' "sudo pacman -S $packages"
  elif command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "sudo apt-get update && sudo apt-get install $packages"
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' "sudo dnf install $packages"
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' "sudo zypper install $packages"
  else
    return 1
  fi
}

linux_has_library() {
  library="$1"

  if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -F "$library" >/dev/null 2>&1
    return $?
  fi

  for dir in \
    /lib /usr/lib /usr/local/lib \
    /lib64 /usr/lib64 /usr/local/lib64 \
    /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
    /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu
  do
    [ -e "$dir/$library" ] && return 0
  done
  return 1
}

linux_missing_wpe_runtime() {
  missing=""
  for library in \
    libWPEWebKit-2.0.so \
    libWPEBackend-fdo-1.0.so \
    libjavascriptcoregtk-6.0.so \
    libEGL.so.1 \
    libGLESv2.so.2
  do
    if ! linux_has_library "$library"; then
      missing="$missing $library"
    fi
  done

  [ -n "$missing" ] || return 1
  printf '%s\n' "$missing" | sed 's/^ //'
}

linux_wpe_runtime_hint() {
  missing="$1"
  say "Linux browser support uses the system WPE WebKit runtime."
  say "Missing browser runtime libraries: $missing"
  if install_cmd="$(linux_wpe_runtime_install_cmd 2>/dev/null)"; then
    say "Install them with:"
    say "  $install_cmd"
    say "Set VERDE_INSTALL_BROWSER_DEPS=1 before running this installer to let it run that command for you."
  else
    say "Install WPE WebKit and WPEBackend-fdo packages for your Linux distribution."
  fi
}

linux_install_wpe_runtime_if_requested() {
  missing="$(linux_missing_wpe_runtime || true)"
  [ -n "$missing" ] || return

  if [ "${'${'}VERDE_INSTALL_BROWSER_DEPS:-0}" != "1" ]; then
    linux_wpe_runtime_hint "$missing"
    return
  fi

  packages="$(linux_wpe_runtime_packages || true)"
  [ -n "$packages" ] || {
    linux_wpe_runtime_hint "$missing"
    return
  }

  say "Installing Linux browser runtime dependencies..."
  if command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed $packages
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y $packages
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y $packages
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y $packages
  else
    linux_wpe_runtime_hint "$missing"
  fi
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
  printf '%s\n' "$RELEASE_JSON" |
    sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' |
    grep -E "$pattern" |
    head -n 1
}

latest_tag_from_json() {
  printf '%s\n' "$RELEASE_JSON" |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

normalize_version() {
  printf '%s\n' "$1" | sed 's/^v//'
}

linux_installed_version() {
  version_file="$PREFIX/share/verde/VERSION"
  if [ -r "$version_file" ]; then
    sed -n '1p' "$version_file"
  fi
}

macos_installed_version() {
  info_plist="$MACOS_APP_DIR/Verde.app/Contents/Info.plist"
  if [ -r "$info_plist" ]; then
    sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s/.*<string>\([^<]*\)<\/string>.*/\1/p;q;}' "$info_plist"
  fi
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

if [ "$platform" = "macos" ] && [ -z "$MACOS_APP_DIR" ]; then
  if [ -d "$HOME/Applications/Verde.app" ]; then
    MACOS_APP_DIR="$HOME/Applications"
  elif [ -d /Applications/Verde.app ]; then
    MACOS_APP_DIR="/Applications"
  elif [ -w /Applications ]; then
    MACOS_APP_DIR="/Applications"
  else
    MACOS_APP_DIR="$HOME/Applications"
  fi
fi

RELEASE_JSON="$(latest_release_json)"
latest_tag="$(latest_tag_from_json)"
[ -n "$latest_tag" ] || fail "could not determine latest release version"
latest_version="$(normalize_version "$latest_tag")"
installed_version=""
if [ "$platform" = "linux" ]; then
  installed_version="$(linux_installed_version || true)"
else
  installed_version="$(macos_installed_version || true)"
fi

if [ "$platform" = "linux" ]; then
  linux_install_wpe_runtime_if_requested
fi

if [ -n "$installed_version" ] && [ "$(normalize_version "$installed_version")" = "$latest_version" ]; then
  say "Verde $latest_version is already installed. Nothing to do."
  exit 0
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
