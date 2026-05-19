#!/usr/bin/env bash
set -euo pipefail

SUMMARY_SCRIPT="scripts/dev/summarize-macos-wkwebview-manual-evidence.sh"
DEFAULT_RUNS_DIR="${DEFAULT_RUNS_DIR:-notes/mac-webview-smoke/manual-evidence/runs}"
LEGACY_EVIDENCE_DIR="${LEGACY_EVIDENCE_DIR:-notes/mac-webview-smoke/manual-evidence}"

note_legacy_evidence() {
  if [[ ! -d "$LEGACY_EVIDENCE_DIR" ]]; then
    return
  fi
  shopt -s nullglob
  local legacy_files=("$LEGACY_EVIDENCE_DIR"/*.json)
  shopt -u nullglob
  if [[ "${#legacy_files[@]}" -gt 0 ]]; then
    echo "ignoring ${#legacy_files[@]} legacy root-level evidence file(s) under $LEGACY_EVIDENCE_DIR; final signoff requires an ignored timestamped run under $DEFAULT_RUNS_DIR" >&2
  fi
}

print_signoff_hint() {
  echo "run: mise run mac-webview-manual-signoff" >&2
  echo "or: scripts/dev/run-macos-wkwebview-manual-signoff.sh" >&2
}

if [[ "$#" -lt 1 ]]; then
  if [[ ! -d "$DEFAULT_RUNS_DIR" ]]; then
    echo "no manual evidence run directory found: $DEFAULT_RUNS_DIR" >&2
    note_legacy_evidence
    print_signoff_hint
    exit 1
  fi
  latest_run="$(find "$DEFAULT_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
  if [[ -z "$latest_run" ]]; then
    echo "no manual evidence runs found under $DEFAULT_RUNS_DIR" >&2
    note_legacy_evidence
    print_signoff_hint
    exit 1
  fi
  shopt -s nullglob
  evidence_files=("$latest_run"/*.json)
  shopt -u nullglob
  if [[ "${#evidence_files[@]}" -eq 0 ]]; then
    echo "latest manual evidence run has no JSON files: $latest_run" >&2
    note_legacy_evidence
    print_signoff_hint
    exit 1
  fi
  echo "Using latest macOS WKWebView manual evidence run: $latest_run"
  set -- "${evidence_files[@]}"
fi

if [[ ! -x "$SUMMARY_SCRIPT" ]]; then
  echo "missing executable summary helper: $SUMMARY_SCRIPT" >&2
  exit 1
fi

summary="$("$SUMMARY_SCRIPT" "$@")"
printf '%s\n' "$summary"

if grep -Eq '^\| [^|]+ \| (fail|missing) \|' <<<"$summary"; then
  echo "macOS WKWebView manual evidence is incomplete: at least one row is fail or missing" >&2
  exit 1
fi

echo "macOS WKWebView manual evidence complete"
