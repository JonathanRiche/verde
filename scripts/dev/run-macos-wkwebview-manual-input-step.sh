#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-macos-wkwebview-manual-input-step.sh must be run on macOS" >&2
  exit 1
fi

LABEL="${1:-manual-input-step}"
EXPECTED_FRONTMOST_RE='^(verde|Verde)$'

frontmost_process() {
  osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true
}

echo "Manual macOS WKWebView input step: $LABEL"
echo "1. Click the Verde app window."
echo "2. Click the browser-pane smoke input."
echo "3. Type the requested test text."
echo
echo "Waiting for Verde to become the frontmost macOS app..."

frontmost=""
for _ in {1..300}; do
  frontmost="$(frontmost_process)"
  if [[ "$frontmost" =~ $EXPECTED_FRONTMOST_RE ]]; then
    break
  fi
  sleep 0.2
done

if [[ ! "$frontmost" =~ $EXPECTED_FRONTMOST_RE ]]; then
  echo "Timed out waiting for Verde to become frontmost; current frontmost app is: ${frontmost:-unknown}" >&2
  exit 1
fi

echo "Verde is frontmost. You have 10 seconds to complete the physical input..."
sleep 10

before_capture_frontmost="$(frontmost_process)"
out_file="$(VERDE_MAC_WEBVIEW_FRONTMOST_BEFORE_CAPTURE="$before_capture_frontmost" scripts/dev/capture-macos-wkwebview-input-evidence.sh "$LABEL")"
echo "$out_file"
