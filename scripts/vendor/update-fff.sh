#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly UPSTREAM_URL="https://github.com/dmtrKovalenko/fff.nvim"

usage() {
    cat <<'EOF'
Usage:
  scripts/vendor/update-fff.sh [--ref <git-ref>] [--commit <sha>] [--source <path>] [--vendor-dir <path>] [--patch-dir <path>] [--regen-header]

Refreshes Verde's vendored fff snapshot from upstream or from a local checkout.
The synced output is intentionally trimmed to the Rust workspace Verde needs:
  - .cargo/config.toml
  - .gitignore
  - Cargo.toml
  - Cargo.lock
  - LICENSE
  - rust-toolchain.toml
  - crates/fff-c
  - crates/fff-core
  - crates/fff-query-parser
  - crates/fff-grep

Options:
  --ref <git-ref>      Upstream tag, branch, or commit to vendor. Required when
                       cloning from GitHub. Optional when --source points to a
                       local checkout or snapshot.
  --commit <sha>       Explicit upstream commit to record in VERDE_VENDOR.txt.
                       Useful when --source points to a local archive rather
                       than a live git checkout.
  --source <path>      Use a local checkout or snapshot instead of cloning the
                       upstream repository.
  --vendor-dir <path>  Destination directory. Defaults to vendor/fff under the
                       repo root.
  --patch-dir <path>   Directory containing *.patch files to apply in lexical
                       order. Defaults to patches/fff under the repo root.
  --regen-header       Regenerate crates/fff-c/include/fff.h with cbindgen
                       after applying patches.
  -h, --help           Show this help text.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
        return
    fi

    if [[ -d "$path" ]]; then
        (
            cd -- "$path"
            pwd -P
        )
        return
    fi

    local parent
    parent="$(dirname -- "$path")"
    local base
    base="$(basename -- "$path")"
    (
        cd -- "$parent"
        printf '%s/%s\n' "$(pwd -P)" "$base"
    )
}

copy_file() {
    local src="$1"
    local dst="$2"
    [[ -f "$src" ]] || die "missing required file: $src"
    mkdir -p -- "$(dirname -- "$dst")"
    cp -- "$src" "$dst"
}

copy_dir() {
    local src="$1"
    local dst="$2"
    [[ -d "$src" ]] || die "missing required directory: $src"
    mkdir -p -- "$(dirname -- "$dst")"
    cp -R -- "$src" "$dst"
}

rewrite_workspace_members() {
    local cargo_toml="$1"
    perl -0pi -e 's/members = \[\n(?:  "crates\/[^\n]+",\n)+\]/members = [\n  "crates\/fff-c",\n  "crates\/fff-core",\n  "crates\/fff-query-parser",\n  "crates\/fff-grep",\n]/s' "$cargo_toml"

    grep -q '"crates/fff-c"' "$cargo_toml" || die "failed to rewrite workspace members in $cargo_toml"
    if grep -q '"crates/fff-nvim"' "$cargo_toml"; then
        die "workspace rewrite left unexpected members in $cargo_toml"
    fi
}

write_vendor_metadata() {
    local vendor_dir="$1"
    local pinned_ref="$2"
    local pinned_commit="$3"

    cat > "${vendor_dir}/VERDE_VENDOR.txt" <<EOF
Vendored for Verde desktop integration.

Upstream repository: ${UPSTREAM_URL}
Pinned ref: ${pinned_ref}
Pinned commit: ${pinned_commit}

Managed by: scripts/vendor/update-fff.sh
Local patches: patches/fff/*.patch
Contents: minimal Rust workspace needed for Verde's fff-c integration
EOF
}

ref=""
explicit_commit=""
source_dir=""
vendor_dir="${REPO_ROOT}/vendor/fff"
patch_dir="${REPO_ROOT}/patches/fff"
regen_header=0

while (($#)); do
    case "$1" in
        --ref)
            shift
            [[ $# -gt 0 ]] || die "--ref requires a value"
            ref="$1"
            ;;
        --source)
            shift
            [[ $# -gt 0 ]] || die "--source requires a value"
            source_dir="$1"
            ;;
        --commit)
            shift
            [[ $# -gt 0 ]] || die "--commit requires a value"
            explicit_commit="$1"
            ;;
        --vendor-dir)
            shift
            [[ $# -gt 0 ]] || die "--vendor-dir requires a value"
            vendor_dir="$1"
            ;;
        --patch-dir)
            shift
            [[ $# -gt 0 ]] || die "--patch-dir requires a value"
            patch_dir="$1"
            ;;
        --regen-header)
            regen_header=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

if [[ "$vendor_dir" != /* ]]; then
    vendor_dir="${REPO_ROOT}/${vendor_dir}"
fi
if [[ "$patch_dir" != /* ]]; then
    patch_dir="${REPO_ROOT}/${patch_dir}"
fi

require_command git
require_command perl

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/verde-fff-sync.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

export_dir="${tmp_dir}/source"
stage_root="${tmp_dir}/stage"
stage_vendor="${stage_root}/vendor/fff"
mkdir -p -- "$export_dir" "$stage_vendor" "${stage_vendor}/crates"

pinned_ref=""
pinned_commit=""

if [[ -n "$source_dir" ]]; then
    source_dir="$(resolve_path "$source_dir")"
    [[ -d "$source_dir" ]] || die "source directory does not exist: $source_dir"

    if git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        pinned_ref="${ref:-HEAD}"
        pinned_commit="$(git -C "$source_dir" rev-parse "${pinned_ref}^{commit}")"
        git -C "$source_dir" archive --format=tar "$pinned_commit" | tar -xf - -C "$export_dir"
    else
        pinned_ref="${ref:-local-source}"
        pinned_commit="${explicit_commit:-unknown}"
        cp -R -- "${source_dir}/." "$export_dir/"
    fi
else
    [[ -n "$ref" ]] || die "--ref is required when syncing directly from ${UPSTREAM_URL}"
    pinned_ref="$ref"

    upstream_checkout="${tmp_dir}/upstream"
    git clone --quiet "${UPSTREAM_URL}" "$upstream_checkout"
    pinned_commit="$(git -C "$upstream_checkout" rev-parse "${pinned_ref}^{commit}")"
    git -C "$upstream_checkout" archive --format=tar "$pinned_commit" | tar -xf - -C "$export_dir"
fi

if [[ -n "$explicit_commit" ]]; then
    pinned_commit="$explicit_commit"
fi

copy_dir "${export_dir}/.cargo" "${stage_vendor}/.cargo"
copy_file "${export_dir}/.gitignore" "${stage_vendor}/.gitignore"
copy_file "${export_dir}/Cargo.toml" "${stage_vendor}/Cargo.toml"
copy_file "${export_dir}/Cargo.lock" "${stage_vendor}/Cargo.lock"
copy_file "${export_dir}/LICENSE" "${stage_vendor}/LICENSE"
copy_file "${export_dir}/rust-toolchain.toml" "${stage_vendor}/rust-toolchain.toml"

copy_dir "${export_dir}/crates/fff-c" "${stage_vendor}/crates/fff-c"
copy_dir "${export_dir}/crates/fff-core" "${stage_vendor}/crates/fff-core"
copy_dir "${export_dir}/crates/fff-query-parser" "${stage_vendor}/crates/fff-query-parser"
copy_dir "${export_dir}/crates/fff-grep" "${stage_vendor}/crates/fff-grep"

rewrite_workspace_members "${stage_vendor}/Cargo.toml"
write_vendor_metadata "$stage_vendor" "$pinned_ref" "$pinned_commit"

git -C "$stage_root" init --quiet

if [[ -d "$patch_dir" ]]; then
    shopt -s nullglob
    patch_files=("${patch_dir}"/*.patch)
    shopt -u nullglob

    for patch_file in "${patch_files[@]}"; do
        git -C "$stage_root" apply --whitespace=nowarn "$patch_file"
    done
fi

if (( regen_header )); then
    require_command cbindgen
    (
        cd -- "$stage_vendor"
        cbindgen --config crates/fff-c/cbindgen.toml --crate fff-c --output crates/fff-c/include/fff.h
    )
fi

mkdir -p -- "$(dirname -- "$vendor_dir")"
rm -rf -- "$vendor_dir"
mv -- "$stage_vendor" "$vendor_dir"

printf 'Synced fff into %s\n' "$vendor_dir"
printf 'Pinned ref: %s\n' "$pinned_ref"
printf 'Pinned commit: %s\n' "$pinned_commit"
