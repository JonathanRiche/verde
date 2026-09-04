#!/usr/bin/env bash
set -euo pipefail

label="${1:-manual}"
shift || true

if (( $# == 0 )); then
  command=(mise run dev-build)
else
  command=("$@")
fi

start_ns=$(date +%s%N)
"${command[@]}" &
build_pid=$!

terminate_build() {
  kill -TERM "$build_pid" 2>/dev/null || true
}
trap terminate_build INT TERM

peak_zig_rss_kib=0
while kill -0 "$build_pid" 2>/dev/null; do
  current_zig_rss_kib=$(
    ps -eo pid=,ppid=,rss=,comm= | awk -v root="$build_pid" '
      {
        parent[$1] = $2
        rss[$1] = $3
        command[$1] = $4
      }
      END {
        for (pid in parent) {
          cursor = pid
          for (depth = 0; depth < 64; depth++) {
            if (cursor == root) {
              if (command[pid] ~ /^zig/ && rss[pid] > maximum) maximum = rss[pid]
              break
            }
            if (!(cursor in parent)) break
            cursor = parent[cursor]
          }
        }
        print maximum + 0
      }
    '
  )
  if (( current_zig_rss_kib > peak_zig_rss_kib )); then
    peak_zig_rss_kib=$current_zig_rss_kib
  fi
  sleep 0.05
done

set +e
wait "$build_pid"
status=$?
set -e
end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

printf 'BENCH label=%s status=%d elapsed_ms=%d peak_zig_rss_kib=%d\n' \
  "$label" "$status" "$elapsed_ms" "$peak_zig_rss_kib"
exit "$status"
