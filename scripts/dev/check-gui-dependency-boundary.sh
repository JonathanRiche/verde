#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/../.." && pwd)
artifact=${1:-"$repo_root/zig-out/bin/verde-gui"}

if [[ ! -f "$artifact" ]]; then
  printf 'GUI dependency boundary check: artifact not found: %s\n' "$artifact" >&2
  printf 'Build verde-gui first, or pass its path as the first argument.\n' >&2
  exit 2
fi

for tool in nm readelf strings; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'GUI dependency boundary check: required tool is unavailable: %s\n' "$tool" >&2
    exit 2
  fi
done

audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/verde-gui-boundary.XXXXXX")
cleanup() {
  rm -rf -- "$audit_dir"
}
trap cleanup EXIT

if ! LC_ALL=C readelf --wide --sections "$artifact" >"$audit_dir/sections.txt" 2>"$audit_dir/readelf-sections.err"; then
  printf 'GUI dependency boundary check: expected an ELF artifact readable by readelf: %s\n' "$artifact" >&2
  sed -n '1,8p' "$audit_dir/readelf-sections.err" >&2
  exit 2
fi
if ! grep -q '\.symtab' "$audit_dir/sections.txt"; then
  printf 'GUI dependency boundary check: %s has no ELF symbol table; absence of forbidden Zig modules cannot be audited.\n' "$artifact" >&2
  exit 2
fi

if ! LC_ALL=C nm -C --defined-only "$artifact" >"$audit_dir/nm.txt" 2>"$audit_dir/nm.err"; then
  printf 'GUI dependency boundary check: nm could not inspect %s\n' "$artifact" >&2
  sed -n '1,8p' "$audit_dir/nm.err" >&2
  exit 2
fi
LC_ALL=C readelf --wide --syms --demangle "$artifact" >"$audit_dir/readelf-symbols.txt" 2>/dev/null || true
LC_ALL=C readelf -p .debug_str "$artifact" >"$audit_dir/readelf-debug.txt" 2>/dev/null || true
LC_ALL=C strings -a "$artifact" >"$audit_dir/strings.txt"

{
  awk '{ print "[nm] " $0 }' "$audit_dir/nm.txt"
  awk '{ print "[readelf-symbol] " $0 }' "$audit_dir/readelf-symbols.txt"
  awk '{ print "[readelf-debug] " $0 }' "$audit_dir/readelf-debug.txt"
  awk '{ print "[string] " $0 }' "$audit_dir/strings.txt"
} >"$audit_dir/evidence.txt"

failures=0
check_boundary() {
  local label=$1
  local pattern=$2
  local matches_file="$audit_dir/matches-$failures.txt"
  if LC_ALL=C grep -E "$pattern" "$audit_dir/evidence.txt" >"$matches_file"; then
    local count
    count=$(wc -l <"$matches_file")
    printf 'FAIL: forbidden %s evidence (%d matches)\n' "$label" "$count" >&2
    sed -n '1,12p' "$matches_file" >&2
    if (( count > 12 )); then
      printf '  ... %d additional matches omitted\n' "$((count - 12))" >&2
    fi
    failures=$((failures + 1))
  else
    printf 'PASS: no forbidden %s evidence\n' "$label"
  fi
}

# These are implementation-specific Zig module and source names. Deliberately
# avoid generic words such as "daemon", "store", "provider", or "client".
check_boundary \
  'sessionizer server' \
  'terminal\.sessionizer\.|sessionizer\.Daemon(\.|$)|packages/desktop/src/terminal/sessionizer\.zig'
check_boundary \
  'daemon store' \
  'daemon\.store\.|packages/desktop/src/daemon/store\.zig'
check_boundary \
  'SQLite/database implementation' \
  '(^|[[:space:]])sqlite3_[[:alnum:]_]*|zqlite\.|db\.(client|schema)\.|packages/desktop/src/db/(client|schema)\.zig'
check_boundary \
  'concrete native provider implementation' \
  'providers\.(codex|claude|cursor|opencode|pi|fx|grok|muse)\.|packages/desktop/src/providers/(codex|claude|cursor|opencode|pi|fx|grok|muse)\.zig'
check_boundary \
  'provider process ownership' \
  'providers\.harness\.(ProviderClient|ProviderConfig|connect|shutdownOwnedProviderProcesses|releaseOwnedCodexServer)(\.|$)|providers\.acp\.Process\.|providers\.(codex|claude|cursor|opencode|pi|fx|grok|muse)\.(active_process_state|shared_server_state|service_launch_mutex|Client\.spawn|registerActiveChild|terminateBridgeChild)'

if (( failures > 0 )); then
  printf 'GUI dependency boundary check failed for %s (%d forbidden categories).\n' "$artifact" "$failures" >&2
  exit 1
fi

printf 'GUI dependency boundary check passed: %s\n' "$artifact"
