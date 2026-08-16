#!/usr/bin/env bash
# Launch an agent-driven live acceptance suite against the current binary.
# Usage: qa/agent-acceptance/run.sh [suite]   (default: smoke)
# Env:   QA_OUT_DIR=/tmp/verde-qa  QA_NO_HERDR=1  QA_MODEL_EFFORT=high
set -euo pipefail

SUITE="${1:-smoke}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUITE_FILE="$SCRIPT_DIR/suites/$SUITE.md"
if [ ! -f "$SUITE_FILE" ]; then
    echo "unknown suite: $SUITE" >&2
    echo "available:" >&2
    ls "$SCRIPT_DIR/suites/" | sed 's/\.md$//' >&2
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${QA_OUT_DIR:-/tmp/verde-qa}/$TS-$SUITE"
mkdir -p "$OUT_DIR/shots"

HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
BIN_MTIME="$(stat -c '%y' "$REPO/zig-out/bin/verde")"

PROMPT="Read $SCRIPT_DIR/charter.md, $SCRIPT_DIR/expectations.md, and $SUITE_FILE fully, then execute the suite from repo $REPO. Environment pin: HEAD $HEAD_SHA, binary mtime $BIN_MTIME. Save screenshots to $OUT_DIR/shots/. Your FINAL MESSAGE must be the complete report per the charter."

ARGS=(codex exec --approve-for-me
    --add-dir "$OUT_DIR"
    --add-dir "$HOME/.local/share/verde/Native/logs"
    -c "model_reasoning_effort=${QA_MODEL_EFFORT:-high}"
    --skip-git-repo-check
    -o "$OUT_DIR/report.md"
    "$PROMPT")

echo "suite:  $SUITE"
echo "report: $OUT_DIR/report.md"
if command -v herdr >/dev/null 2>&1 && [ -z "${QA_NO_HERDR:-}" ]; then
    herdr agent start "verde-qa-$SUITE-$TS" --cwd "$REPO" --no-focus -- "${ARGS[@]}"
    echo "running in herdr pane verde-qa-$SUITE-$TS; watch there or wait for the report file."
else
    (cd "$REPO" && "${ARGS[@]}")
fi
