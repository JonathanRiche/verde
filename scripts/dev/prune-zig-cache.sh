#!/usr/bin/env bash
# Deletes the repo's local Zig build caches (every `.zig-cache` directory).
#
# Zig never garbage-collects `.zig-cache`; every edit-and-rebuild of the
# ~100 MB desktop test binary leaves another copy behind, so the desktop
# cache alone reaches tens of gigabytes. Dependency sources live in
# `zig-pkg/` and `~/.cache/zig`, which this script leaves alone, so the only
# cost is one cold rebuild.
#
# Deleting a cache that a build is writing breaks that build, so the script
# refuses while any `zig build`/`zig test` process is running.
#
# Usage: scripts/dev/prune-zig-cache.sh [--dry-run] [--min-gb N]
#   --min-gb N  only prune when the caches total at least N GiB (default 0)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dry_run=0
min_gb=0
while (($#)); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --min-gb) min_gb="${2:?--min-gb needs a value}"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

mapfile -t caches < <(find "$repo_root" -type d -name .zig-cache -prune \
    -not -path '*/node_modules/*' -not -path '*/target/*' 2>/dev/null | sort)
if ((${#caches[@]} == 0)); then
    echo "no .zig-cache directories under $repo_root"
    exit 0
fi

total_kb="$(du -sk "${caches[@]}" 2>/dev/null | awk '{s += $1} END {print s + 0}')"
total_gb=$((total_kb / 1024 / 1024))
du -sh "${caches[@]}" 2>/dev/null | sort -h
echo "total: ${total_gb} GiB"

if ((total_gb < min_gb)); then
    echo "below --min-gb ${min_gb}; nothing to do"
    exit 0
fi

if pgrep -af '(^|/)zig (build|test|build-exe|build-lib|build-obj)( |$)' >/dev/null; then
    echo "refusing: a Zig build is running (pgrep -af 'zig (build|test)'); retry when idle" >&2
    exit 1
fi

if ((dry_run)); then
    echo "dry run: would delete ${#caches[@]} cache directories"
    exit 0
fi

rm -rf -- "${caches[@]}"
echo "deleted ${#caches[@]} cache directories (${total_gb} GiB)"
