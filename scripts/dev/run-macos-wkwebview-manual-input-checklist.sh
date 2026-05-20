#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-macos-wkwebview-manual-input-checklist.sh must be run on macOS" >&2
  exit 1
fi

EXPECTED_FRONTMOST_RE='^(verde|Verde)$'
CAPTURE_SCRIPT="scripts/dev/capture-macos-wkwebview-input-evidence.sh"
VALIDATE_SCRIPT="scripts/dev/validate-macos-wkwebview-input-evidence.sh"
WAIT_SECONDS="${VERDE_MAC_WEBVIEW_MANUAL_STEP_SECONDS:-15}"

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

run_step() {
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
macOS WKWebView manual input checklist

Before continuing:
1. Start the smoke server:
   cd notes/mac-webview-smoke && python3 -m http.server 8879 --bind 127.0.0.1
2. Launch the installed app smoke:
   scripts/dev/open-macos-wkwebview-input-smoke.sh
3. Keep this terminal visible enough to read prompts, but perform each action in Verde.

This runner captures and validates each step. Set
VERDE_MAC_WEBVIEW_MANUAL_STEP_SECONDS to change the per-step input window.
EOF

read -r -p "Press Enter when the smoke page is open in Verde..."

run_step \
  "text" \
  "text-input-abc123" \
  "abc123" \
  $'Click Reset log, click the Input field, then type exactly: abc123'

run_step \
  "textarea" \
  "textarea-line-one-line-two" \
  $'line one\nline two' \
  $'Click Reset log, click the Textarea, type "line one", press Enter, then type "line two".'

run_step \
  "editing" \
  "editing-keys-input" \
  "" \
  $'Click Reset log, click the Input field, then press these physical keys once each: ArrowLeft, ArrowRight, Home, End, Backspace, Delete, Enter, Tab, Escape.'

run_step \
  "clipboard" \
  "clipboard-command-a-c-x-v" \
  "CopySeed" \
  $'Click Reset log, click Set copy seed, then use physical Command+A, Command+C, Command+X, and Command+V in the Input field. Final input value must be CopySeed.'

run_step \
  "modifier-click" \
  "modifier-click-shift-option-control-command" \
  "" \
  $'Click Reset log, then click the click target with Shift, Option, Control, and Command held at least once each.'

run_step \
  "modifier-wheel" \
  "modifier-wheel-shift-option-control-command" \
  "" \
  $'Click Reset log, click the scroll target, then wheel/trackpad scroll with Shift, Option, Control, and Command held at least once each.'

echo
echo "IME/composition varies by configured macOS input method."
read -r -p "Enter the exact composed text you will type for the IME step, or leave blank to skip: " ime_expected
if [[ -n "$ime_expected" ]]; then
  run_step \
    "ime" \
    "ime-composed-text" \
    "$ime_expected" \
    "Click Reset log, click the Input field or Textarea, then enter the composed text exactly: $ime_expected"
else
  echo "Skipped IME/composition validation."
fi

echo
echo "Manual evidence files:"
for item in "${EVIDENCE_FILES[@]}"; do
  IFS='|' read -r mode label path <<<"$item"
  printf -- '- %s (%s): %s\n' "$label" "$mode" "$path"
done

echo
echo "Paste these evidence paths and validator PASS results into notes/webview_migration_audit.md."
