import { macosInstallCliScript } from './install-script'

export const installScript = String.raw`#!/bin/sh
set -eu

REPO="JonathanRiche/verde"
API_URL="https://api.github.com/repos/$REPO/releases/latest"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'verde install: %s\n' "$*" >&2
  exit 1
}

[ -n "${'${'}HOME:-}" ] || fail "HOME is not set; set HOME to your home directory and retry"
PREFIX="${'${'}VERDE_INSTALL_PREFIX:-$HOME/.local}"
# The launcher, desktop entry, and PATH hint embed the prefix; keep it absolute.
case "$PREFIX" in
  /*) ;;
  *) PREFIX="$(pwd)/${'${'}PREFIX#./}" ;;
esac
MACOS_APP_DIR="${'${'}VERDE_MACOS_APP_DIR:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

linux_wpe_runtime_packages() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' "wpewebkit"
  elif command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' "libwpewebkit-2.0-1"
  elif command -v dnf >/dev/null 2>&1; then
    printf '%s\n' "wpewebkit"
  elif command -v zypper >/dev/null 2>&1; then
    printf '%s\n' "libWPEWebKit-2_0-1"
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

linux_ldconfig() {
  # Debian and Ubuntu keep ldconfig in /sbin, which a user PATH often omits.
  for candidate in "$(command -v ldconfig 2>/dev/null || true)" /sbin/ldconfig /usr/sbin/ldconfig; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

linux_has_library() {
  library="$1"

  if ldconfig_cmd="$(linux_ldconfig)" &&
    "$ldconfig_cmd" -p 2>/dev/null | grep -F "$library" >/dev/null 2>&1; then
    return 0
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

# Release builds pass -Dbrowser-linux-fdo=false, so verde-browser-linux links only
# WPE WebKit 2.0 (which bundles JavaScriptCore and WPE Platform), libsoup 3 and
# GLib. Check the sonames the helper loads, not the -dev-only unversioned links.
linux_missing_wpe_runtime() {
  missing=""
  for library in \
    libWPEWebKit-2.0.so.1 \
    libsoup-3.0.so.0
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
    say "Install the WPE WebKit 2.0 runtime package for your Linux distribution."
  fi
}

have_tty() {
  # Under curl | sh stdin is the script itself; prompts must read the terminal.
  (: </dev/tty) 2>/dev/null
}

# Run a package-manager command as root. Its stdin is the terminal when there is
# one (never the piped script) and /dev/null otherwise, where sudo must not prompt.
linux_pkg_run() {
  if [ "$(id -u)" = "0" ]; then
    if have_tty; then "$@" </dev/tty; else "$@" </dev/null; fi
  elif command -v sudo >/dev/null 2>&1; then
    if have_tty; then sudo "$@" </dev/tty; else sudo -n "$@" </dev/null; fi
  else
    say "sudo is not available to install packages."
    return 1
  fi
}

# Set -e is suspended inside a function used as a condition, so chain with &&.
linux_install_wpe_packages() {
  packages="$1"
  if command -v pacman >/dev/null 2>&1; then
    if have_tty; then
      linux_pkg_run pacman -S --needed $packages
    else
      linux_pkg_run pacman -S --needed --noconfirm $packages
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    linux_pkg_run apt-get update && linux_pkg_run apt-get install -y $packages
  elif command -v dnf >/dev/null 2>&1; then
    linux_pkg_run dnf install -y $packages
  elif command -v zypper >/dev/null 2>&1; then
    linux_pkg_run zypper --non-interactive install $packages
  else
    return 1
  fi
}

# Browser dependencies are optional: never abort the Verde install over them.
linux_install_wpe_runtime_if_requested() {
  missing="$(linux_missing_wpe_runtime || true)"
  [ -n "$missing" ] || return 0

  if [ "${'${'}VERDE_INSTALL_BROWSER_DEPS:-0}" != "1" ]; then
    linux_wpe_runtime_hint "$missing"
    return 0
  fi

  packages="$(linux_wpe_runtime_packages || true)"
  if [ -z "$packages" ]; then
    linux_wpe_runtime_hint "$missing"
    return 0
  fi

  say "Installing Linux browser runtime dependencies..."
  if ! linux_install_wpe_packages "$packages"; then
    say "Could not install the browser runtime dependencies; continuing without them."
    linux_wpe_runtime_hint "$missing"
    return 0
  fi

  missing="$(linux_missing_wpe_runtime || true)"
  if [ -n "$missing" ]; then
    linux_wpe_runtime_hint "$missing"
  fi
  return 0
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

release_string_values() {
  # GitHub may return compact JSON. Match each field, not the last URL on a line.
  printf '%s\n' "$RELEASE_JSON" |
    tr '\n' ' ' |
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
    sed 's/^[^:]*:[[:space:]]*"//; s/"$//; s#\\/#/#g'
}

asset_url_for() {
  pattern="$1"
  release_string_values browser_download_url |
    grep -E "$pattern" |
    head -n 1
}

latest_tag_from_json() {
  release_string_values tag_name |
    head -n 1
}

normalize_version() {
  printf '%s\n' "$1" | sed 's/^v//'
}

# Print -1, 0, or 1 as dotted version $1 is older than, equal to, or newer than $2.
compare_versions() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); if (m > n) n = m
    for (i = 1; i <= n; i++) {
      if (x[i] + 0 < y[i] + 0) { print -1; exit }
      if (x[i] + 0 > y[i] + 0) { print 1; exit }
    }
    print 0
  }'
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

linux_install_is_complete() {
  [ -x "$PREFIX/bin/verde" ] || return 1
  [ -r "$PREFIX/share/verde/provider_bridge.mjs" ] || return 1
  return 0
}

macos_install_is_complete() {
  app_dir="$MACOS_APP_DIR/Verde.app"
  [ -x "$app_dir/Contents/MacOS/verde" ] || return 1
  [ -r "$app_dir/Contents/Resources/provider_bridge.mjs" ] || return 1
  return 0
}

# Quote a path for copy-paste into a shell only when it needs it.
shell_quote() {
  case "$1" in
    *[!A-Za-z0-9_./:+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
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

${macosInstallCliScript}

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

# Check here: a failure inside $(latest_release_json) would be reported as an API error.
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  fail "missing required command: curl or wget"
fi

RELEASE_JSON="$(latest_release_json)" ||
  fail "could not fetch the latest release from $API_URL (GitHub may be rate limiting this network; wait a few minutes and retry)"
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

if [ "${'${'}VERDE_FORCE_INSTALL:-0}" != "1" ] &&
  [ -n "$installed_version" ] &&
  [ "$(normalize_version "$installed_version")" = "$latest_version" ]; then
  if [ "$platform" = "linux" ]; then
    if linux_install_is_complete; then
      say "Verde $latest_version is already installed. Nothing to do."
      exit 0
    fi
  else
    if macos_install_is_complete; then
      macos_install_cli
      say "Verde $latest_version is already installed. Nothing to do."
      exit 0
    fi
  fi

  say "Verde $latest_version is installed but incomplete. Reinstalling..."
elif [ -n "$installed_version" ]; then
  installed_version="$(normalize_version "$installed_version")"
  if [ "$installed_version" = "$latest_version" ]; then
    say "Reinstalling Verde $latest_version..."
  else
    case "$(compare_versions "$installed_version" "$latest_version")" in
      1) say "Downgrading Verde $installed_version ${'→'} $latest_version..." ;;
      -1) say "Upgrading Verde $installed_version ${'→'} $latest_version..." ;;
      *) say "Replacing Verde $installed_version with $latest_version..." ;;
    esac
  fi
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
  download "$asset_url" "$archive" || fail "could not download $asset_url"

  tar -xzf "$archive" -C "$work_dir" || fail "could not extract $archive"
  package_dir="$(find "$work_dir" -maxdepth 1 -type d -name 'verde-*-linux-*' | head -n 1)"
  [ -n "$package_dir" ] || fail "release archive did not contain a Verde package directory"

  say "Installing Verde into $PREFIX..."
  bash "$package_dir/install-local.sh" "$PREFIX" || fail "the packaged installer failed"
  say "Done. Run Verde with: $(shell_quote "$PREFIX/bin/verde")"
  case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *)
      say "$PREFIX/bin is not on your PATH. To run Verde as: verde, add this to your shell profile:"
      if [ "$(shell_quote "$PREFIX/bin")" = "$PREFIX/bin" ]; then
        say "  export PATH=\"$PREFIX/bin:\$PATH\""
      else
        say "  export PATH=$(shell_quote "$PREFIX/bin"):\"\$PATH\""
      fi
      ;;
  esac
else
  need_cmd unzip
  asset_url="$(asset_url_for "verde-.+-macos-$arch[.]zip$")"
  [ -n "$asset_url" ] || fail "could not find latest macOS $arch release asset"

  archive="$work_dir/verde-macos-$arch.zip"
  say "Downloading Verde for macOS $arch..."
  download "$asset_url" "$archive" || fail "could not download $asset_url"

  unzip -q "$archive" -d "$work_dir/unpacked"
  app_path="$(find "$work_dir/unpacked" -maxdepth 2 -type d -name 'Verde.app' | head -n 1)"
  [ -n "$app_path" ] || fail "release archive did not contain Verde.app"

  mkdir -p "$MACOS_APP_DIR"
  rm -rf "$MACOS_APP_DIR/Verde.app"
  cp -R "$app_path" "$MACOS_APP_DIR/Verde.app"
  say "Done. Installed Verde.app into $MACOS_APP_DIR"
  macos_install_cli
fi
`
