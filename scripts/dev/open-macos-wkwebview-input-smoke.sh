#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "open-macos-wkwebview-input-smoke.sh must be run on macOS" >&2
  exit 1
fi

APP_PATH="${1:-/Users/jhonellebriche/Applications/Verde.app}"
START_URL="${VERDE_BROWSER_START_URL:-http://127.0.0.1:8879/input-regression.html}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Verde.app not found at $APP_PATH" >&2
  exit 1
fi

open -n -F "$APP_PATH" \
  --env VERDE_OPEN_BROWSER_ON_START=1 \
  --env "VERDE_BROWSER_START_URL=$START_URL"

echo "Launched $APP_PATH as a foreground macOS app."
echo "Startup URL: $START_URL"
echo "Click the browser-pane input and type abc123, then run:"
echo "  scripts/dev/capture-macos-wkwebview-input-evidence.sh text-input-abc123"
