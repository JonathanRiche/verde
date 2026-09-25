#!/usr/bin/env bash
set -euo pipefail
mode=$1
shift
while (($#)); do
  generated=$1
  committed=$2
  shift 2
  case "$mode" in
    generate) mkdir -p "$(dirname "$committed")"; cp "$generated" "$committed" ;;
    check)
      if ! cmp -s "$generated" "$committed"; then
        echo "Stale native model: $committed; run mise run mobile-models-generate" >&2
        exit 1
      fi ;;
    *) exit 2 ;;
  esac
done
