#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_BIN="${1:-/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde}"
START_URL="${VERDE_BROWSER_START_URL:-about:blank}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS WKWebView runtime smoke must run on macOS" >&2
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "installed Verde binary not found or not executable: $APP_BIN" >&2
  echo "run: mise run build" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

if pgrep -f '[V]erde.app/Contents/MacOS/verde' >/dev/null 2>&1; then
  echo "Verde is already running; close it before this smoke so cleanup is safe" >&2
  exit 1
fi

APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" >/dev/null 2>&1; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
        return
      fi
      sleep 0.1
    done
    kill -9 "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$APP_PID" ]]; then
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

assert_no_native_webview_helper_processes() {
  local matches
  matches="$(pgrep -af '[v]erde-browser-cef|[v]erde-browser-cef-process|[l]ibcef|[C]hromium Embedded Framework' || true)"
  if [[ -n "$matches" ]]; then
    echo "native macOS WKWebView smoke found unexpected CEF/helper process:" >&2
    printf '%s\n' "$matches" >&2
    exit 1
  fi
}

VERDE_OPEN_BROWSER_ON_START=1 VERDE_BROWSER_START_URL="$START_URL" \
  "$APP_BIN" >/tmp/verde-macos-wkwebview-runtime.log 2>&1 &
APP_PID="$!"

STATUS_JSON=""
for _ in {1..80}; do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    echo "Verde exited before runtime smoke completed" >&2
    exit 1
  fi
  if STATUS_JSON="$("$APP_BIN" live status --json 2>/dev/null)"; then
    if STATUS_JSON="$STATUS_JSON" START_URL="$START_URL" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["STATUS_JSON"])
browser = payload.get("result", {}).get("browser", {})
if (
    browser.get("runtime_kind") == "native_webview"
    and browser.get("presentation_kind") == "native_child_view"
    and browser.get("runtime_initialized") is True
    and browser.get("status") == "Ready"
    and browser.get("visible") is True
    and browser.get("url") == os.environ.get("START_URL", "about:blank")
    and browser.get("last_error") is None
):
    sys.exit(0)
sys.exit(1)
PY
    then
      break
    fi
  fi
  STATUS_JSON=""
  sleep 0.25
done

if [[ -z "$STATUS_JSON" ]]; then
  echo "timed out waiting for macOS WKWebView runtime readiness" >&2
  exit 1
fi

assert_no_native_webview_helper_processes

STATUS_JSON="$STATUS_JSON" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["STATUS_JSON"])
browser = payload["result"]["browser"]
print(
    "macOS WKWebView runtime smoke passed: "
    f"runtime_kind={browser['runtime_kind']} "
    f"presentation_kind={browser['presentation_kind']} "
    f"status={browser['status']} "
    f"visible={browser['visible']} "
    f"url={browser['url']}"
)
PY

cleanup
APP_PID=""
assert_no_native_webview_helper_processes
