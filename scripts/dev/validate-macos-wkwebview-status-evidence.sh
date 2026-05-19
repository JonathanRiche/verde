#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

mode="${1:-}"
evidence_file="${2:-}"
expected="${3:-}"

if [[ -z "$mode" || -z "$evidence_file" ]]; then
  echo "usage: $0 <mode> <evidence.json> [expected]" >&2
  echo "modes: inspector-point inspector-draw-box inspector-draw-freeform url-contains any" >&2
  exit 2
fi

if [[ ! -f "$evidence_file" ]]; then
  echo "evidence file not found: $evidence_file" >&2
  exit 1
fi

python3 - "$mode" "$evidence_file" "$expected" <<'PY'
import json
import sys

mode = sys.argv[1]
path = sys.argv[2]
expected = sys.argv[3]

with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

status = payload.get("status", {}).get("result", {})
browser = status.get("browser", {})
focus = status.get("focus", {})
last_js_message = browser.get("last_js_message")
url = browser.get("url") or ""
address = browser.get("address") or ""

frontmost_before = payload.get("macos_frontmost_before_capture") or ""
frontmost_capture = payload.get("macos_frontmost_process") or ""
frontmost_ok = frontmost_before in {"verde", "Verde"} or frontmost_capture in {"verde", "Verde"}

summary = {
    "evidence": path,
    "mode": mode,
    "label": payload.get("label"),
    "stamp": payload.get("stamp"),
    "frontmostBeforeCapture": frontmost_before,
    "frontmostAtCapture": frontmost_capture,
    "browserPaneFocused": focus.get("browser_pane_focused"),
    "nativeBrowserSurfaceFocused": focus.get("native_browser_surface_focused"),
    "runtimeKind": browser.get("runtime_kind"),
    "presentationKind": browser.get("presentation_kind"),
    "status": browser.get("status"),
    "visible": browser.get("visible"),
    "url": url,
    "address": address,
    "inspectorEnabled": browser.get("inspector_enabled"),
    "inspectorMode": browser.get("inspector_mode"),
    "lastError": browser.get("last_error"),
    "lastJsMessage": last_js_message,
}
print(json.dumps(summary, indent=2, sort_keys=True))

errors = []
if not frontmost_ok:
    errors.append("Verde was not recorded as frontmost before or during capture")
if browser.get("runtime_kind") != "native_webview":
    errors.append(f"expected native_webview runtime, got {browser.get('runtime_kind')!r}")
if browser.get("presentation_kind") != "native_child_view":
    errors.append(f"expected native_child_view presentation, got {browser.get('presentation_kind')!r}")
if browser.get("status") != "Ready":
    errors.append(f"expected browser status Ready, got {browser.get('status')!r}")
if browser.get("last_error") is not None:
    errors.append(f"expected no browser error, got {browser.get('last_error')!r}")

valid_modes = {"inspector-point", "inspector-draw-box", "inspector-draw-freeform", "url-contains", "any"}
if mode not in valid_modes:
    errors.append(f"unknown mode {mode!r}; expected one of {sorted(valid_modes)}")
elif mode.startswith("inspector-"):
    if not isinstance(last_js_message, str):
        errors.append("expected browser.last_js_message to contain inspector selection JSON")
    else:
        try:
            message = json.loads(last_js_message)
        except json.JSONDecodeError as exc:
            errors.append(f"browser.last_js_message is not JSON: {exc}")
            message = {}
        if message.get("source") != "verde-inspector":
            errors.append(f"expected verde-inspector source, got {message.get('source')!r}")
        expected_type = "element:selected" if mode == "inspector-point" else "region:selected"
        if message.get("type") != expected_type:
            errors.append(f"expected inspector message type {expected_type!r}, got {message.get('type')!r}")
        if mode == "inspector-draw-box" and '"mode":"draw-box"' not in last_js_message:
            errors.append("expected draw-box inspector payload")
        if mode == "inspector-draw-freeform" and '"mode":"draw-freeform"' not in last_js_message:
            errors.append("expected draw-freeform inspector payload")
elif mode == "url-contains":
    if not expected:
        errors.append("url-contains mode requires expected URL substring")
    elif expected not in url and expected not in address:
        errors.append(f"expected URL/address to contain {expected!r}, got url={url!r} address={address!r}")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: physical {mode} status evidence matches expected state")
PY
