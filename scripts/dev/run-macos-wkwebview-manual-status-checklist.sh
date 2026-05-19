#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-macos-wkwebview-manual-status-checklist.sh must be run on macOS" >&2
  exit 1
fi

EXPECTED_FRONTMOST_RE='^(verde|Verde)$'
CAPTURE_SCRIPT="scripts/dev/capture-macos-wkwebview-status-evidence.sh"
VALIDATE_SCRIPT="scripts/dev/validate-macos-wkwebview-status-evidence.sh"
WAIT_SECONDS="${VERDE_MAC_WEBVIEW_MANUAL_STATUS_STEP_SECONDS:-15}"
EVIDENCE_DIR="${VERDE_MAC_WEBVIEW_EVIDENCE_DIR:-notes/mac-webview-smoke/manual-evidence}"

frontmost_process() {
  osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true
}

wait_for_verde_frontmost() {
  local frontmost=""
  for _ in {1..300}; do
    frontmost="$(frontmost_process)"
    if [[ "$frontmost" =~ $EXPECTED_FRONTMOST_RE ]]; then
      printf '%s' "$frontmost"
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for Verde to become frontmost; current frontmost app is: ${frontmost:-unknown}" >&2
  return 1
}

run_status_step() {
  local mode="$1"
  local label="$2"
  local expected="$3"
  local instructions="$4"
  local out_file=""
  local before_capture_frontmost=""

  echo
  echo "== $label =="
  printf '%s\n' "$instructions"
  echo
  echo "Click/focus Verde now. Waiting for Verde to become frontmost..."
  wait_for_verde_frontmost >/dev/null
  echo "Verde is frontmost. You have ${WAIT_SECONDS}s to complete this step."
  sleep "$WAIT_SECONDS"
  before_capture_frontmost="$(frontmost_process)"
  out_file="$(VERDE_MAC_WEBVIEW_FRONTMOST_BEFORE_CAPTURE="$before_capture_frontmost" "$CAPTURE_SCRIPT" "$label")"
  echo "Captured: $out_file"
  "$VALIDATE_SCRIPT" "$mode" "$out_file" "$expected"
  EVIDENCE_FILES+=("$mode|$label|$out_file")
}

record_unavailable() {
  local label="$1"
  local reason="$2"
  local safe_label=""
  local stamp=""
  local out_file=""

  mkdir -p "$EVIDENCE_DIR"
  safe_label="$(printf '%s' "$label" | tr -c '[:alnum:]_.-' '-')"
  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  out_file="$EVIDENCE_DIR/${stamp}-${safe_label}-unavailable.json"
  LABEL="$label" REASON="$reason" STAMP="$stamp" python3 - "$out_file" <<'PY'
import json
import os
import sys

payload = {
    "label": os.environ["LABEL"],
    "stamp": os.environ["STAMP"],
    "unavailable": True,
    "reason": os.environ["REASON"],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  echo "Recorded unavailable: $out_file"
  EVIDENCE_FILES+=("unavailable|$label|$out_file")
}

if [[ ! -x "$CAPTURE_SCRIPT" ]]; then
  echo "missing executable capture helper: $CAPTURE_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
  echo "missing executable validator: $VALIDATE_SCRIPT" >&2
  exit 1
fi

declare -a EVIDENCE_FILES=()

cat <<'EOF'
macOS WKWebView manual status checklist

Use this after the browser smoke page is open in Verde. It captures and
validates live-status evidence for the remaining physical inspector and optional
hardware back/forward items.
EOF

read -r -p "Run physical inspector Point gesture? [y/N] " run_point
if [[ "$run_point" =~ ^[Yy]$ ]]; then
  run_status_step \
    "inspector-point" \
    "inspector-point" \
    "" \
    $'Enable inspector Point mode, then use a physical pointer/trackpad click to select an element in the WKWebView page.'
fi

read -r -p "Run physical inspector Draw Box gesture? [y/N] " run_box
if [[ "$run_box" =~ ^[Yy]$ ]]; then
  run_status_step \
    "inspector-draw-box" \
    "inspector-draw-box" \
    "" \
    $'Enable inspector Draw Box mode, then use a physical pointer/trackpad drag to draw a box over page content.'
fi

read -r -p "Run physical inspector Draw Freeform gesture? [y/N] " run_freeform
if [[ "$run_freeform" =~ ^[Yy]$ ]]; then
  run_status_step \
    "inspector-draw-freeform" \
    "inspector-draw-freeform" \
    "" \
    $'Enable inspector Draw Freeform mode, then use a physical pointer/trackpad drag path over page content.'
fi

echo
read -r -p "Does this test device have hardware browser Back/Forward buttons? [y/N] " has_back_forward
if [[ "$has_back_forward" =~ ^[Yy]$ ]]; then
  read -r -p "Enter expected URL substring after hardware mouse Back: " back_substring
  if [[ -z "$back_substring" ]]; then
    echo "hardware mouse Back expected substring is required when testing back/forward buttons" >&2
    exit 1
  fi
  run_status_step \
    "url-contains" \
    "mouse-back" \
    "$back_substring" \
    "Use the hardware mouse Back button now. Expected URL/address substring after capture: $back_substring"

  read -r -p "Enter expected URL substring after hardware mouse Forward: " forward_substring
  if [[ -z "$forward_substring" ]]; then
    echo "hardware mouse Forward expected substring is required when testing back/forward buttons" >&2
    exit 1
  fi
  run_status_step \
    "url-contains" \
    "mouse-forward" \
    "$forward_substring" \
    "Use the hardware mouse Forward button now. Expected URL/address substring after capture: $forward_substring"
else
  record_unavailable \
    "mouse-back-forward" \
    "test device has no hardware browser back/forward buttons"
fi

echo
echo "Manual status evidence files:"
for item in "${EVIDENCE_FILES[@]}"; do
  IFS='|' read -r mode label path <<<"$item"
  printf -- '- %s (%s): %s\n' "$label" "$mode" "$path"
done
