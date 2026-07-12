#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

for command in zig cargo rustc bun python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "error: $command is required for the Windows cross-build" >&2
    exit 1
  fi
done

rust_target="x86_64-pc-windows-gnu"
required_rust_toolchain="1.95.0"
export RUSTUP_TOOLCHAIN="${VERDE_FFF_RUST_TOOLCHAIN:-$required_rust_toolchain}"
if [[ "$(rustc --version)" != rustc\ "$required_rust_toolchain"* ]]; then
  cat >&2 <<EOF
error: Rust $required_rust_toolchain is required for the pinned Windows fff-c build.
Install it with:
  rustup toolchain install $required_rust_toolchain --profile minimal --target $rust_target
EOF
  exit 1
fi
required_zigbuild_version="cargo-zigbuild 0.20.1"
zigbuild_install="$(cargo install --list 2>/dev/null | awk '/^cargo-zigbuild v/{print $1 " " substr($2, 2, length($2) - 2); exit}')"
if [[ "$zigbuild_install" != "$required_zigbuild_version" ]] ||
  ! cargo zigbuild --help >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: cargo-zigbuild 0.20.1 is required to build vendored fff-c from a non-Windows host.
Install or replace the helper with the pinned version:
  cargo install --locked cargo-zigbuild --version 0.20.1
EOF
  if [[ -n "$zigbuild_install" ]]; then
    echo "found: $zigbuild_install" >&2
  fi
  exit 1
fi

rust_target_libdir="$(rustc --print target-libdir --target "$rust_target" 2>/dev/null || true)"
if [[ -z "$rust_target_libdir" || ! -d "$rust_target_libdir" ]] ||
  ! compgen -G "$rust_target_libdir/libstd-*.rlib" >/dev/null; then
  cat >&2 <<EOF
error: the Rust standard library for $rust_target is not installed.
Use a rustup-managed toolchain, then run:
  rustup target add $rust_target
EOF
  exit 1
fi

deps_root="$(python3 scripts/dev/bootstrap_windows_deps.py --toolchain gnu)"

if [[ ! -d node_modules/@anthropic-ai/claude-agent-sdk ]]; then
  BUN_TMPDIR="${BUN_TMPDIR:-/tmp/verde-bun-tmp}" bun install --frozen-lockfile --production
fi

zig build --release=safe \
  -Dtarget=x86_64-windows-gnu \
  -Dbrowser-backend=native_webview \
  -Dterminal_backend=true \
  -Dlocal_ipc=true \
  -Dwindows_integrations=true \
  -Dfff-cargo-target="$rust_target" \
  -Dsdl3-include-dir="$deps_root/include" \
  -Dsdl3-lib-dir="$deps_root/lib" \
  -Dsdl3-runtime-lib="$deps_root/bin/SDL3.dll" \
  -Dsdl3-ttf-include-dir="$deps_root/include" \
  -Dsdl3-ttf-lib-dir="$deps_root/lib" \
  -Dsdl3-ttf-runtime-lib="$deps_root/bin/SDL3_ttf.dll" \
  -Dwebview2-include-dir="$deps_root/include" \
  -Dwebview2-loader-lib="$deps_root/lib/libWebView2Loader.a" \
  -Dwebview2-loader-dll="$deps_root/bin/WebView2Loader.dll" \
  "$@"
