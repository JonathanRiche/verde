#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${1:-/Users/jhonellebriche/Applications/Verde.app}"
APP_BIN="$APP_DIR/Contents/MacOS/verde"
manual_helpers=(
  scripts/dev/capture-macos-wkwebview-input-evidence.sh
  scripts/dev/capture-macos-wkwebview-status-evidence.sh
  scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh
  scripts/dev/open-macos-wkwebview-input-smoke.sh
  scripts/dev/run-macos-wkwebview-manual-input-checklist.sh
  scripts/dev/run-macos-wkwebview-manual-input-step.sh
  scripts/dev/run-macos-wkwebview-manual-signoff.sh
  scripts/dev/run-macos-wkwebview-manual-status-checklist.sh
  scripts/dev/summarize-macos-wkwebview-manual-evidence.sh
  scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh
  scripts/dev/validate-macos-wkwebview-input-evidence.sh
  scripts/dev/validate-macos-wkwebview-status-evidence.sh
)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS WKWebView readiness check must run on macOS" >&2
  exit 1
fi

(
  cd "$REPO_ROOT"
  bash -n "${manual_helpers[@]}"
  for helper in "${manual_helpers[@]}"; do
    if [[ ! -x "$helper" ]]; then
      echo "macOS WKWebView helper is not executable: $helper" >&2
      exit 1
    fi
  done
  if ! grep -q '^\[tasks\.check-mac-webview-manual\]$' mise.toml; then
    echo "missing mise task: check-mac-webview-manual" >&2
    exit 1
  fi
  if ! grep -q '^\[tasks\.mac-webview-manual-signoff\]$' mise.toml; then
    echo "missing mise task: mac-webview-manual-signoff" >&2
    exit 1
  fi
  if ! grep -q 'scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh' mise.toml; then
    echo "check-mac-webview-manual does not run the manual evidence completion checker" >&2
    exit 1
  fi
  if ! grep -q 'scripts/dev/run-macos-wkwebview-manual-signoff.sh' mise.toml; then
    echo "mac-webview-manual-signoff does not run the manual signoff script" >&2
    exit 1
  fi
  if grep -q 'scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh notes/mac-webview-smoke/manual-evidence/\*\.json' mise.toml; then
    echo "check-mac-webview-manual still points at stale root-level manual evidence" >&2
    exit 1
  fi
  scripts/dev/run-macos-wkwebview-manual-signoff.sh --dry-run >/dev/null
  scripts/dev/test-macos-wkwebview-manual-evidence-tools.sh >/dev/null
  zig build test --release=safe -Dbrowser-backend=stub
  scripts/release/install-macos-local.sh
)
"$REPO_ROOT/scripts/dev/check-macos-wkwebview.sh" "$APP_DIR"
# LaunchServices/code signing can lag the just-replaced app bundle briefly.
sleep 2
"$REPO_ROOT/scripts/dev/smoke-macos-wkwebview-runtime.sh" "$APP_BIN" || {
  sleep 2
  "$REPO_ROOT/scripts/dev/smoke-macos-wkwebview-runtime.sh" "$APP_BIN"
}

cat <<'EOF'
macOS WKWebView automated readiness checks passed.
Manual physical input parity is still required before final sign-off:
- real keypress text input
- Command+A/C/X/V
- editing keys
- modifier click/wheel
- IME/composed text
- physical inspector gestures
- mouse back/forward buttons if the test device has them

Run notes/mac-webview-smoke/manual-input-checklist.md or:
  mise run mac-webview-manual-signoff
Or:
  scripts/dev/run-macos-wkwebview-manual-signoff.sh
For just the guided input portion:
  scripts/dev/run-macos-wkwebview-manual-input-checklist.sh
For just the guided inspector/back-forward portion:
  scripts/dev/run-macos-wkwebview-manual-status-checklist.sh
The one-command signoff prints the run-specific summary and completion-check
commands for its timestamped evidence directory.
EOF
