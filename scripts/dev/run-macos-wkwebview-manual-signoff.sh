#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "run-macos-wkwebview-manual-signoff.sh must be run on macOS" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_PATH="${VERDE_APP_PATH:-/Users/jhonellebriche/Applications/Verde.app}"
HOST="${VERDE_MAC_WEBVIEW_SMOKE_HOST:-127.0.0.1}"
PORT="${VERDE_MAC_WEBVIEW_SMOKE_PORT:-8879}"
START_URL="${VERDE_BROWSER_START_URL:-http://$HOST:$PORT/input-regression.html}"
SMOKE_DIR="$REPO_ROOT/notes/mac-webview-smoke"
RUN_STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
EVIDENCE_DIR="${VERDE_MAC_WEBVIEW_EVIDENCE_DIR:-$SMOKE_DIR/manual-evidence/runs/$RUN_STAMP}"
DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: scripts/dev/run-macos-wkwebview-manual-signoff.sh [--dry-run]

Starts the macOS WKWebView manual input smoke server, launches the installed
Verde.app against input-regression.html, runs the guided physical input
checklist, then prints the generated evidence summary.

Options:
  --dry-run   Validate prerequisites and print the planned signoff flow without
              starting a server, launching Verde, or waiting for input.
EOF
  exit 0
elif [[ -n "${1:-}" ]]; then
  echo "unknown argument: $1" >&2
  echo "usage: $0 [--dry-run]" >&2
  exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Verde.app not found at $APP_PATH" >&2
  echo "run: mise run build" >&2
  exit 1
fi

if [[ ! -f "$SMOKE_DIR/input-regression.html" ]]; then
  echo "missing smoke page: $SMOKE_DIR/input-regression.html" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
macOS WKWebView manual signoff dry run passed.
App: $APP_PATH
Smoke page: $SMOKE_DIR/input-regression.html
Startup URL: $START_URL
Evidence directory: $EVIDENCE_DIR
Set VERDE_MAC_WEBVIEW_EVIDENCE_DIR to reuse a specific evidence directory.
Next real run:
  mise run mac-webview-manual-signoff
Or:
  scripts/dev/run-macos-wkwebview-manual-signoff.sh
EOF
  exit 0
fi

mkdir -p "$EVIDENCE_DIR"

server_pid=""
started_server=0

cleanup() {
  if [[ "$started_server" == "1" && -n "$server_pid" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if python3 - "$HOST" "$PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.settimeout(0.2)
    sys.exit(0 if sock.connect_ex((host, port)) == 0 else 1)
PY
then
  echo "Using existing smoke server at http://$HOST:$PORT/"
else
  echo "Starting smoke server at http://$HOST:$PORT/"
  (
    cd "$SMOKE_DIR"
    python3 -m http.server "$PORT" --bind "$HOST"
  ) >/tmp/verde-macos-wkwebview-smoke-server.log 2>&1 &
  server_pid="$!"
  started_server=1
  for _ in {1..50}; do
    if python3 - "$HOST" "$PORT" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.settimeout(0.2)
    sys.exit(0 if sock.connect_ex((host, port)) == 0 else 1)
PY
    then
      break
    fi
    sleep 0.1
  done
fi

echo "Launching $APP_PATH"
open -n -F "$APP_PATH" \
  --env VERDE_OPEN_BROWSER_ON_START=1 \
  --env "VERDE_BROWSER_START_URL=$START_URL"

echo "Startup URL: $START_URL"
echo "Evidence directory: $EVIDENCE_DIR"
echo "Final completion check:"
echo "  mise run check-mac-webview-manual"
echo "Or:"
echo "  scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh \"$EVIDENCE_DIR\"/*.json"
echo

(
  cd "$REPO_ROOT"
  VERDE_BROWSER_START_URL="$START_URL" \
  VERDE_MAC_WEBVIEW_EVIDENCE_DIR="$EVIDENCE_DIR" \
    scripts/dev/run-macos-wkwebview-manual-input-checklist.sh
  VERDE_MAC_WEBVIEW_EVIDENCE_DIR="$EVIDENCE_DIR" \
    scripts/dev/run-macos-wkwebview-manual-status-checklist.sh
)

echo
echo "Generated manual evidence summary:"
(
  cd "$REPO_ROOT"
  shopt -s nullglob
  evidence_files=("$EVIDENCE_DIR"/*.json)
  if [[ "${#evidence_files[@]}" -eq 0 ]]; then
    echo "No evidence JSON files found in $EVIDENCE_DIR" >&2
    exit 1
  fi
  scripts/dev/summarize-macos-wkwebview-manual-evidence.sh "${evidence_files[@]}"
  echo
  echo "Final completion check:"
  echo "  mise run check-mac-webview-manual"
  echo "Or:"
  printf '  scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh %q/*.json\n' "$EVIDENCE_DIR"
)
