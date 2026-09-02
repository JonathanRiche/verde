#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
image_tag="${VERDE_CONTAINER_TAG:-verde-runtime:local}"
container_cli="${VERDE_CONTAINER_CLI:-docker}"

case "${VERDE_CONTAINER_ARCH:-$(uname -m)}" in
    x86_64|amd64)
        zig_target=x86_64-linux-gnu.2.36
        platform=linux/amd64
        ;;
    aarch64|arm64)
        zig_target=aarch64-linux-gnu.2.36
        platform=linux/arm64
        ;;
    *)
        printf 'unsupported container architecture: %s\n' "${VERDE_CONTAINER_ARCH:-$(uname -m)}" >&2
        exit 1
        ;;
esac

command -v zig >/dev/null || { printf 'zig is required\n' >&2; exit 1; }
command -v bun >/dev/null || { printf 'bun is required\n' >&2; exit 1; }
command -v "$container_cli" >/dev/null || { printf '%s is required\n' "$container_cli" >&2; exit 1; }

rootfs="$repo_root/zig-out/container-rootfs"
[[ "$rootfs" == "${repo_root}/zig-out/container-rootfs" ]] || exit 1
rm -rf -- "$rootfs"
install -d "$rootfs/opt/verde/bin" "$rootfs/opt/verde/share/verde"

(
    cd "$repo_root"
    BUN_TMPDIR="${BUN_TMPDIR:-/tmp/verde-bun-tmp}" \
        bun install --frozen-lockfile --production
)

(
    cd "$repo_root"
    zig build daemon \
        --release=safe \
        -Dtarget="$zig_target" \
        --prefix "$rootfs/opt/verde"

    zig build server \
        --release=safe \
        -Dtarget="$zig_target" \
        --prefix "$rootfs/opt/verde"
)

(
    cd "$repo_root/packages/web_app"
    bun install --frozen-lockfile
    zig build \
        --release=safe \
        -Dtarget="$zig_target" \
        --prefix "$rootfs/opt/verde"
    bun run build
)

cp -a -- "$repo_root/packages/web_app/dist" "$rootfs/opt/verde/share/verde/web"

"$container_cli" build \
    --platform "$platform" \
    --tag "$image_tag" \
    --file "$repo_root/packages/daemon/container/Containerfile" \
    "$repo_root"

printf 'built %s for %s\n' "$image_tag" "$platform"
