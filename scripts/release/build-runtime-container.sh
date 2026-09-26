#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
image_tag="${VERDE_CONTAINER_TAG:-verde-runtime:local}"
container_cli="${VERDE_CONTAINER_CLI:-docker}"

case "${VERDE_CONTAINER_ARCH:-$(uname -m)}" in
    x86_64|amd64)
        zig_target=x86_64-linux-gnu.2.36
        platform=linux/amd64
        rust_target=x86_64-unknown-linux-gnu
        ;;
    aarch64|arm64)
        zig_target=aarch64-linux-gnu.2.36
        platform=linux/arm64
        rust_target=aarch64-unknown-linux-gnu
        ;;
    *)
        printf 'unsupported container architecture: %s\n' "${VERDE_CONTAINER_ARCH:-$(uname -m)}" >&2
        exit 1
        ;;
esac

command -v zig >/dev/null || { printf 'zig is required\n' >&2; exit 1; }
command -v cargo-zigbuild >/dev/null || { printf 'cargo-zigbuild is required for the target-pinned fff runtime\n' >&2; exit 1; }
command -v patchelf >/dev/null || { printf 'patchelf is required for the fff runtime SONAME\n' >&2; exit 1; }
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

# Match the container's glibc floor as well as its CPU architecture. Never
# copy the host-built desktop library into a cross-target runtime image.
(
    cd "$repo_root/vendor/fff"
    cargo zigbuild --release --package fff-c --features zlob --target "${rust_target}.2.36"
)
install -d "$rootfs/fff-lib"
install -m 755 "$repo_root/vendor/fff/target/$rust_target/release/libfff_c.so" "$rootfs/fff-lib/libfff_c.so"
patchelf --set-soname libfff_c.so "$rootfs/fff-lib/libfff_c.so"

(
    cd "$repo_root"
    zig build daemon \
        -Dbuild-fff=false \
        -Dfff-lib-dir="$rootfs/fff-lib" \
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
