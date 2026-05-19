#!/usr/bin/env bash
set -euo pipefail

APP_BIN="${VERDE_APP_BIN:-/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde}"
LABEL="${1:-manual-status-step}"
OUT_DIR="${VERDE_MAC_WEBVIEW_EVIDENCE_DIR:-notes/mac-webview-smoke/manual-evidence}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS WKWebView status evidence capture must run on macOS" >&2
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "installed Verde binary not found or not executable: $APP_BIN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
safe_label="$(printf '%s' "$LABEL" | tr -c '[:alnum:]_.-' '-')"
stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
out_file="$OUT_DIR/${stamp}-${safe_label}.json"

is_verde_frontmost_name() {
  [[ "$1" == "Verde" || "$1" == "verde" ]]
}

frontmost_process="$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)"
frontmost_before_capture="${VERDE_MAC_WEBVIEW_FRONTMOST_BEFORE_CAPTURE:-}"
if [[ "${VERDE_MAC_WEBVIEW_ALLOW_NONFRONTMOST_CAPTURE:-0}" != "1" ]] &&
  ! is_verde_frontmost_name "$frontmost_before_capture" &&
  ! is_verde_frontmost_name "$frontmost_process"; then
  echo "refusing to write macOS WKWebView evidence because Verde was not frontmost before or during capture" >&2
  echo "frontmost before capture: ${frontmost_before_capture:-unknown}" >&2
  echo "frontmost at capture: ${frontmost_process:-unknown}" >&2
  exit 1
fi
status_json="$("$APP_BIN" live status --json)"

STATUS_JSON="$status_json" LABEL="$LABEL" STAMP="$stamp" FRONTMOST_PROCESS="$frontmost_process" FRONTMOST_BEFORE_CAPTURE="$frontmost_before_capture" python3 - "$out_file" <<'PY'
import json
import os
import sys

out_file = sys.argv[1]
payload = {
    "label": os.environ["LABEL"],
    "stamp": os.environ["STAMP"],
    "macos_frontmost_process": os.environ["FRONTMOST_PROCESS"],
    "macos_frontmost_before_capture": os.environ["FRONTMOST_BEFORE_CAPTURE"],
    "status": json.loads(os.environ["STATUS_JSON"]),
}
with open(out_file, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "$out_file"
