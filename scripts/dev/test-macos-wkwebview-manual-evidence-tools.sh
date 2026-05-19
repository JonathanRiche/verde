#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATE_INPUT="$REPO_ROOT/scripts/dev/validate-macos-wkwebview-input-evidence.sh"
VALIDATE_STATUS="$REPO_ROOT/scripts/dev/validate-macos-wkwebview-status-evidence.sh"
SUMMARIZE="$REPO_ROOT/scripts/dev/summarize-macos-wkwebview-manual-evidence.sh"
CHECK_COMPLETE="$REPO_ROOT/scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh"
MANUAL_SIGNOFF="$REPO_ROOT/scripts/dev/run-macos-wkwebview-manual-signoff.sh"
STATUS_CHECKLIST="$REPO_ROOT/scripts/dev/run-macos-wkwebview-manual-status-checklist.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

dry_run_evidence_dir="$tmp_dir/dry-run-should-not-exist"
if ! VERDE_MAC_WEBVIEW_EVIDENCE_DIR="$dry_run_evidence_dir" "$MANUAL_SIGNOFF" --dry-run >/tmp/verde-manual-signoff-dry-run.out 2>&1; then
  echo "manual signoff dry-run failed" >&2
  cat /tmp/verde-manual-signoff-dry-run.out >&2
  exit 1
fi
if [[ -e "$dry_run_evidence_dir" ]]; then
  echo "manual signoff dry-run unexpectedly created an evidence directory: $dry_run_evidence_dir" >&2
  cat /tmp/verde-manual-signoff-dry-run.out >&2
  exit 1
fi

python3 - "$tmp_dir" <<'PY'
import json
import os
import sys

tmp_dir = sys.argv[1]

def compact_json(value):
    return json.dumps(value, separators=(",", ":"))

def write_fixture(name, *, label, input_value, browser_address_focused=False, frontmost="Verde", events=None):
    if events is None:
        events = [
            {"type": "keydown", "target": "smoke-input", "key": "a"},
            {"type": "beforeinput", "target": "smoke-input", "data": "a"},
            {"type": "input", "target": "smoke-input", "data": "a"},
            {"type": "keyup", "target": "smoke-input", "key": "a"},
        ]
    result = {
        "active": "smoke-input",
        "input": input_value,
        "inputSelection": [len(input_value), len(input_value)],
        "textarea": "",
        "textareaSelection": [0, 0],
        "scrollTop": 0,
        "eventCount": len(events),
        "recentEvents": events,
        "url": "http://127.0.0.1:8879/input-regression.html",
    }
    payload = {
        "label": label,
        "stamp": "fixture",
        "macos_frontmost_process": frontmost,
        "macos_frontmost_before_capture": frontmost,
        "status": {
            "result": {
                "browser": {
                    "runtime_kind": "native_webview",
                    "presentation_kind": "native_child_view",
                    "status": "Ready",
                    "visible": True,
                    "url": "http://127.0.0.1:8879/input-regression.html",
                    "address": "http://127.0.0.1:8879/input-regression.html",
                    "last_error": None,
                    "last_eval_result": json.dumps({
                        "captureLabel": label,
                        "captureStamp": "fixture",
                        "result": result,
                    }),
                },
                "focus": {
                    "browser_pane_focused": True,
                    "native_browser_surface_focused": True,
                    "browser_address_focused": browser_address_focused,
                },
            }
        },
    }
    path = os.path.join(tmp_dir, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return path

def write_status_fixture(name, *, label, url="http://127.0.0.1:8879/two", frontmost="Verde", last_js_message=None, last_error=None):
    payload = {
        "label": label,
        "stamp": "fixture",
        "macos_frontmost_process": frontmost,
        "macos_frontmost_before_capture": frontmost,
        "status": {
            "result": {
                "browser": {
                    "runtime_kind": "native_webview",
                    "presentation_kind": "native_child_view",
                    "status": "Ready",
                    "visible": True,
                    "url": url,
                    "address": url,
                    "last_error": last_error,
                    "last_js_message": last_js_message,
                },
                "focus": {
                    "browser_pane_focused": True,
                    "native_browser_surface_focused": True,
                    "browser_address_focused": False,
                },
            }
        },
    }
    path = os.path.join(tmp_dir, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return path

write_fixture("text-pass.json", label="text-input-abc123", input_value="abc123")
write_fixture("text-doubled.json", label="text-input-abc123-doubled", input_value="aabbcc112233")
write_fixture("text-address-focused.json", label="text-input-abc123-address-focused", input_value="abc123", browser_address_focused=True)
write_fixture("text-not-frontmost.json", label="text-input-abc123-not-frontmost", input_value="abc123", frontmost="ghostty")
write_fixture(
    "textarea-pass.json",
    label="textarea-line-one-line-two",
    input_value="",
    events=[
        {"type": "keydown", "target": "smoke-textarea", "key": "l"},
        {"type": "beforeinput", "target": "smoke-textarea", "data": "line one"},
        {"type": "input", "target": "smoke-textarea", "data": "line one"},
        {"type": "keyup", "target": "smoke-textarea", "key": "o"},
    ],
)
with open(os.path.join(tmp_dir, "textarea-pass.json"), "r+", encoding="utf-8") as handle:
    payload = json.load(handle)
    result = json.loads(payload["status"]["result"]["browser"]["last_eval_result"])
    result["result"]["textarea"] = "line one\nline two"
    result["result"]["textareaSelection"] = [17, 17]
    payload["status"]["result"]["browser"]["last_eval_result"] = json.dumps(result)
    handle.seek(0)
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.truncate()
write_fixture(
    "editing-pass.json",
    label="editing-keys-input",
    input_value="",
    events=[{"type": "keydown", "target": "smoke-input", "key": key} for key in ["ArrowLeft", "ArrowRight", "Home", "End", "Backspace", "Delete", "Enter", "Tab", "Escape"]],
)
write_fixture(
    "clipboard-pass.json",
    label="clipboard-command-a-c-x-v",
    input_value="CopySeed",
    events=[
        {"type": "copy", "target": "smoke-input"},
        {"type": "cut", "target": "smoke-input"},
        {"type": "paste", "target": "smoke-input"},
        {"type": "input", "target": "smoke-input", "data": "CopySeed"},
    ],
)
write_fixture(
    "modifier-click-pass.json",
    label="modifier-click-shift-option-control-command",
    input_value="",
    events=[{"type": "click", "target": "click-target", modifier: True} for modifier in ["shiftKey", "altKey", "ctrlKey", "metaKey"]],
)
write_fixture(
    "modifier-wheel-pass.json",
    label="modifier-wheel-shift-option-control-command",
    input_value="",
    events=[{"type": "wheel", "target": "scroll-target", modifier: True} for modifier in ["shiftKey", "altKey", "ctrlKey", "metaKey"]],
)
with open(os.path.join(tmp_dir, "modifier-wheel-pass.json"), "r+", encoding="utf-8") as handle:
    payload = json.load(handle)
    result = json.loads(payload["status"]["result"]["browser"]["last_eval_result"])
    result["result"]["scrollTop"] = 40
    payload["status"]["result"]["browser"]["last_eval_result"] = json.dumps(result)
    handle.seek(0)
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.truncate()
write_fixture(
    "ime-pass.json",
    label="ime-composed-text",
    input_value="かな",
    events=[
        {"type": "compositionstart", "target": "smoke-input"},
        {"type": "compositionupdate", "target": "smoke-input", "data": "か"},
        {"type": "compositionend", "target": "smoke-input", "data": "かな"},
    ],
)

write_status_fixture(
    "inspector-point-pass.json",
    label="inspector-point",
    last_js_message=compact_json({"source": "verde-inspector", "type": "element:selected", "tag": "input"}),
)
write_status_fixture(
    "inspector-draw-box-pass.json",
    label="inspector-draw-box",
    last_js_message=compact_json({"source": "verde-inspector", "type": "region:selected", "mode": "draw-box"}),
)
write_status_fixture(
    "inspector-draw-freeform-pass.json",
    label="inspector-draw-freeform",
    last_js_message=compact_json({"source": "verde-inspector", "type": "region:selected", "mode": "draw-freeform"}),
)
write_status_fixture("mouse-back-pass.json", label="mouse-back", url="http://127.0.0.1:8879/one")
write_status_fixture("mouse-forward-pass.json", label="mouse-forward", url="http://127.0.0.1:8879/two")
write_status_fixture(
    "inspector-wrong-source.json",
    label="inspector-point-wrong-source",
    last_js_message=compact_json({"source": "other", "type": "element:selected"}),
)
write_status_fixture("status-not-frontmost.json", label="mouse-back-forward-not-frontmost", frontmost="ghostty")

with open(os.path.join(tmp_dir, "mouse-back-forward-unavailable.json"), "w", encoding="utf-8") as handle:
    json.dump({
        "label": "mouse-back-forward",
        "stamp": "fixture",
        "unavailable": True,
        "reason": "test device has no hardware browser back/forward buttons",
    }, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

"$VALIDATE_INPUT" text "$tmp_dir/text-pass.json" abc123 >/dev/null

if "$VALIDATE_INPUT" text "$tmp_dir/text-doubled.json" abc123 >/tmp/verde-validator-doubled.out 2>&1; then
  echo "doubled text fixture unexpectedly passed input validator" >&2
  cat /tmp/verde-validator-doubled.out >&2
  exit 1
fi
if ! grep -q "doubled physical key output" /tmp/verde-validator-doubled.out; then
  echo "doubled text fixture failed without the expected diagnostic" >&2
  cat /tmp/verde-validator-doubled.out >&2
  exit 1
fi

if "$VALIDATE_INPUT" text "$tmp_dir/text-address-focused.json" abc123 >/tmp/verde-validator-address.out 2>&1; then
  echo "address-focused fixture unexpectedly passed input validator" >&2
  cat /tmp/verde-validator-address.out >&2
  exit 1
fi
if ! grep -q "browser address field was still focused" /tmp/verde-validator-address.out; then
  echo "address-focused fixture failed without the expected diagnostic" >&2
  cat /tmp/verde-validator-address.out >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/text-pass.json" "$tmp_dir/text-doubled.json" "$tmp_dir/text-address-focused.json" "$tmp_dir/text-not-frontmost.json")"
if ! grep -q "| Text input \`abc123\` | pass |" <<<"$summary"; then
  echo "summary did not mark the valid text fixture as passing" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/text-doubled.json" "$tmp_dir/text-address-focused.json" "$tmp_dir/text-not-frontmost.json" "$tmp_dir/text-pass.json")"
if ! grep -q "| Text input \`abc123\` | pass |" <<<"$summary"; then
  echo "summary did not let fresh valid text evidence override stale failed text evidence" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/text-doubled.json" "$tmp_dir/text-address-focused.json" "$tmp_dir/text-not-frontmost.json")"
if ! grep -q "| Text input \`abc123\` | fail |" <<<"$summary"; then
  echo "summary did not mark invalid text fixtures as failing" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

"$VALIDATE_STATUS" inspector-point "$tmp_dir/inspector-point-pass.json" >/dev/null
"$VALIDATE_STATUS" inspector-draw-box "$tmp_dir/inspector-draw-box-pass.json" >/dev/null
"$VALIDATE_STATUS" inspector-draw-freeform "$tmp_dir/inspector-draw-freeform-pass.json" >/dev/null
"$VALIDATE_STATUS" url-contains "$tmp_dir/mouse-back-pass.json" "/one" >/dev/null
"$VALIDATE_STATUS" url-contains "$tmp_dir/mouse-forward-pass.json" "/two" >/dev/null

if "$VALIDATE_STATUS" inspector-point "$tmp_dir/inspector-wrong-source.json" >/tmp/verde-status-inspector.out 2>&1; then
  echo "wrong-source inspector fixture unexpectedly passed status validator" >&2
  cat /tmp/verde-status-inspector.out >&2
  exit 1
fi
if ! grep -q "expected verde-inspector source" /tmp/verde-status-inspector.out; then
  echo "wrong-source inspector fixture failed without the expected diagnostic" >&2
  cat /tmp/verde-status-inspector.out >&2
  exit 1
fi

if "$VALIDATE_STATUS" url-contains "$tmp_dir/status-not-frontmost.json" "/two" >/tmp/verde-status-frontmost.out 2>&1; then
  echo "not-frontmost status fixture unexpectedly passed status validator" >&2
  cat /tmp/verde-status-frontmost.out >&2
  exit 1
fi
if ! grep -q "Verde was not recorded as frontmost" /tmp/verde-status-frontmost.out; then
  echo "not-frontmost status fixture failed without the expected diagnostic" >&2
  cat /tmp/verde-status-frontmost.out >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/mouse-back-pass.json")"
if ! grep -q "| Mouse back/forward buttons | fail |" <<<"$summary"; then
  echo "summary unexpectedly passed mouse back/forward with only back evidence" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/mouse-back-pass.json" "$tmp_dir/mouse-forward-pass.json")"
if ! grep -q "| Mouse back/forward buttons | pass |" <<<"$summary"; then
  echo "summary did not pass mouse back/forward with both directions" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

summary="$("$SUMMARIZE" "$tmp_dir/mouse-back-forward-unavailable.json")"
if ! grep -q "| Mouse back/forward buttons | unavailable |" <<<"$summary"; then
  echo "summary did not mark explicit mouse back/forward unavailability" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

status_runner_dir="$tmp_dir/status-runner"
mkdir -p "$status_runner_dir"
if ! printf 'n\nn\nn\nn\n' | VERDE_MAC_WEBVIEW_EVIDENCE_DIR="$status_runner_dir" "$STATUS_CHECKLIST" >/tmp/verde-status-runner.out 2>&1; then
  echo "status checklist unavailable path failed" >&2
  cat /tmp/verde-status-runner.out >&2
  exit 1
fi
if ! ls "$status_runner_dir"/*mouse-back-forward-unavailable.json >/dev/null 2>&1; then
  echo "status checklist did not write mouse back/forward unavailable evidence" >&2
  cat /tmp/verde-status-runner.out >&2
  exit 1
fi
summary="$("$SUMMARIZE" "$status_runner_dir"/*.json)"
if ! grep -q "| Mouse back/forward buttons | unavailable |" <<<"$summary"; then
  echo "summary did not mark status-checklist-generated unavailable evidence" >&2
  printf '%s\n' "$summary" >&2
  exit 1
fi

"$CHECK_COMPLETE" \
  "$tmp_dir/text-pass.json" \
  "$tmp_dir/textarea-pass.json" \
  "$tmp_dir/editing-pass.json" \
  "$tmp_dir/clipboard-pass.json" \
  "$tmp_dir/modifier-click-pass.json" \
  "$tmp_dir/modifier-wheel-pass.json" \
  "$tmp_dir/ime-pass.json" \
  "$tmp_dir/inspector-point-pass.json" \
  "$tmp_dir/inspector-draw-box-pass.json" \
  "$tmp_dir/inspector-draw-freeform-pass.json" \
  "$tmp_dir/mouse-back-forward-unavailable.json" >/dev/null

legacy_root_dir="$tmp_dir/legacy-root"
empty_runs_dir="$tmp_dir/empty-runs"
mkdir -p "$legacy_root_dir" "$empty_runs_dir"
cp "$tmp_dir/text-doubled.json" "$legacy_root_dir"/
if DEFAULT_RUNS_DIR="$empty_runs_dir" LEGACY_EVIDENCE_DIR="$legacy_root_dir" "$CHECK_COMPLETE" >/tmp/verde-legacy-root-fail.out 2>&1; then
  echo "manual evidence completion checker unexpectedly accepted legacy root evidence" >&2
  cat /tmp/verde-legacy-root-fail.out >&2
  exit 1
fi
if ! grep -q "ignoring 1 legacy root-level evidence file.*final signoff requires an ignored timestamped run" /tmp/verde-legacy-root-fail.out; then
  echo "manual evidence completion checker did not explain ignored legacy root evidence" >&2
  cat /tmp/verde-legacy-root-fail.out >&2
  exit 1
fi

empty_latest_runs_dir="$tmp_dir/empty-latest-runs"
empty_latest_run="$empty_latest_runs_dir/20260519T000002Z"
mkdir -p "$empty_latest_run"
if DEFAULT_RUNS_DIR="$empty_latest_runs_dir" LEGACY_EVIDENCE_DIR="$legacy_root_dir" "$CHECK_COMPLETE" >/tmp/verde-empty-latest-fail.out 2>&1; then
  echo "manual evidence completion checker unexpectedly accepted an empty latest run" >&2
  cat /tmp/verde-empty-latest-fail.out >&2
  exit 1
fi
if ! grep -q "latest manual evidence run has no JSON files: $empty_latest_run" /tmp/verde-empty-latest-fail.out; then
  echo "manual evidence completion checker did not report the empty latest run" >&2
  cat /tmp/verde-empty-latest-fail.out >&2
  exit 1
fi
if ! grep -q "ignoring 1 legacy root-level evidence file.*final signoff requires an ignored timestamped run" /tmp/verde-empty-latest-fail.out; then
  echo "manual evidence completion checker did not explain ignored legacy evidence for empty latest run" >&2
  cat /tmp/verde-empty-latest-fail.out >&2
  exit 1
fi

latest_runs_dir="$tmp_dir/latest-runs"
older_run="$latest_runs_dir/20260519T000000Z"
newer_run="$latest_runs_dir/20260519T000001Z"
mkdir -p "$older_run" "$newer_run"
cp \
  "$tmp_dir/text-pass.json" \
  "$tmp_dir/textarea-pass.json" \
  "$tmp_dir/editing-pass.json" \
  "$tmp_dir/clipboard-pass.json" \
  "$tmp_dir/modifier-click-pass.json" \
  "$tmp_dir/modifier-wheel-pass.json" \
  "$tmp_dir/ime-pass.json" \
  "$tmp_dir/inspector-point-pass.json" \
  "$tmp_dir/inspector-draw-box-pass.json" \
  "$tmp_dir/inspector-draw-freeform-pass.json" \
  "$tmp_dir/mouse-back-forward-unavailable.json" \
  "$older_run"/
cp "$tmp_dir/text-doubled.json" "$newer_run"/

if DEFAULT_RUNS_DIR="$latest_runs_dir" "$CHECK_COMPLETE" >/tmp/verde-latest-run-fail.out 2>&1; then
  echo "manual evidence completion checker unexpectedly ignored the latest incomplete run" >&2
  cat /tmp/verde-latest-run-fail.out >&2
  exit 1
fi
if ! grep -q "Using latest macOS WKWebView manual evidence run: $newer_run" /tmp/verde-latest-run-fail.out; then
  echo "manual evidence completion checker did not report the latest run directory" >&2
  cat /tmp/verde-latest-run-fail.out >&2
  exit 1
fi

rm "$newer_run/text-doubled.json"
cp "$older_run"/*.json "$newer_run"/
DEFAULT_RUNS_DIR="$latest_runs_dir" "$CHECK_COMPLETE" >/dev/null

if "$CHECK_COMPLETE" "$tmp_dir/text-pass.json" >/tmp/verde-manual-complete-fail.out 2>&1; then
  echo "manual evidence completion checker unexpectedly passed incomplete evidence" >&2
  cat /tmp/verde-manual-complete-fail.out >&2
  exit 1
fi
if ! grep -q "manual evidence is incomplete" /tmp/verde-manual-complete-fail.out; then
  echo "manual evidence completion checker failed without expected diagnostic" >&2
  cat /tmp/verde-manual-complete-fail.out >&2
  exit 1
fi

echo "macOS WKWebView manual evidence tool self-test passed"
