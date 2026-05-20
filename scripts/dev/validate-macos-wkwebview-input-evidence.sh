#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

mode="${1:-}"
evidence_file="${2:-}"
expected_value="${3:-}"

if [[ -z "$mode" || -z "$evidence_file" ]]; then
  echo "usage: $0 <mode> <evidence.json> [expected-value]" >&2
  echo "modes: text textarea editing clipboard modifier-click modifier-wheel ime any" >&2
  exit 2
fi

if [[ ! -f "$evidence_file" ]]; then
  echo "evidence file not found: $evidence_file" >&2
  exit 1
fi

python3 - "$mode" "$evidence_file" "$expected_value" <<'PY'
import json
import sys

mode = sys.argv[1]
path = sys.argv[2]
expected = sys.argv[3]

DEFAULT_EXPECTED = {
    "text": "abc123",
    "textarea": "line one\nline two",
    "clipboard": "CopySeed",
}
if not expected:
    expected = DEFAULT_EXPECTED.get(mode, "")

with open(path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

status = payload.get("status", {}).get("result", {})
browser = status.get("browser", {})
focus = status.get("focus", {})
last_eval = browser.get("last_eval_result")
if not isinstance(last_eval, str):
    raise SystemExit("missing browser.last_eval_result in evidence")

try:
    decoded = json.loads(last_eval)
except json.JSONDecodeError as exc:
    raise SystemExit(f"browser.last_eval_result is not JSON: {exc}") from exc

result = decoded.get("result")
if not isinstance(result, dict):
    raise SystemExit("decoded last_eval_result is missing result object")

frontmost_before = payload.get("macos_frontmost_before_capture") or ""
frontmost_capture = payload.get("macos_frontmost_process") or ""
frontmost_ok = frontmost_before in {"verde", "Verde"} or frontmost_capture in {"verde", "Verde"}
input_value = result.get("input")
textarea_value = result.get("textarea")
event_count = result.get("eventCount")
recent_events = result.get("recentEvents")
if not isinstance(recent_events, list):
    recent_events = []

summary = {
    "evidence": path,
    "mode": mode,
    "label": payload.get("label"),
    "captureStamp": decoded.get("captureStamp"),
    "frontmostBeforeCapture": frontmost_before,
    "frontmostAtCapture": frontmost_capture,
    "browserPaneFocused": focus.get("browser_pane_focused"),
    "nativeBrowserSurfaceFocused": focus.get("native_browser_surface_focused"),
    "browserAddressFocused": focus.get("browser_address_focused"),
    "input": input_value,
    "inputSelection": result.get("inputSelection"),
    "textarea": textarea_value,
    "textareaSelection": result.get("textareaSelection"),
    "scrollTop": result.get("scrollTop"),
    "eventCount": event_count,
    "recentEvents": recent_events,
}
print(json.dumps(summary, indent=2, sort_keys=True))

errors = []
if not frontmost_ok:
    errors.append("Verde was not recorded as frontmost before or during capture")
if focus.get("browser_address_focused") is True:
    errors.append("Verde browser address field was still focused; page input focus was not exclusive")
if not isinstance(event_count, int) or event_count <= 0:
    errors.append(f"expected at least one DOM event, got {event_count!r}")

def doubled_text(value):
    return "".join(character * 2 for character in value)

def add_exact_value_error(field_name, actual, expected_value):
    if expected_value and actual == doubled_text(expected_value):
        errors.append(f"{field_name} contains doubled physical key output {actual!r}; expected exactly {expected_value!r}")
    else:
        errors.append(f"expected {field_name} {expected_value!r}, got {actual!r}")

def has_event(event_type, target=None, **mods):
    for event in recent_events:
        if event.get("type") != event_type:
            continue
        if target is not None and event.get("target") != target:
            continue
        matched = True
        for key, value in mods.items():
            if event.get(key) is not value:
                matched = False
                break
        if matched:
            return True
    return False

def has_any_event(types, target=None):
    return any(
        event.get("type") in types and (target is None or event.get("target") == target)
        for event in recent_events
    )

valid_modes = {"text", "textarea", "editing", "clipboard", "modifier-click", "modifier-wheel", "ime", "any"}
if mode not in valid_modes:
    errors.append(f"unknown mode {mode!r}; expected one of {sorted(valid_modes)}")
elif mode == "text":
    if input_value != expected:
        add_exact_value_error("input", input_value, expected)
    if not has_any_event({"beforeinput", "input", "keydown", "keyup"}, "smoke-input"):
        errors.append("expected recent input/key DOM events for smoke-input")
elif mode == "textarea":
    if textarea_value != expected:
        add_exact_value_error("textarea", textarea_value, expected)
    if not has_any_event({"beforeinput", "input", "keydown", "keyup"}, "smoke-textarea"):
        errors.append("expected recent input/key DOM events for smoke-textarea")
elif mode == "editing":
    expected_keys = ["ArrowLeft", "ArrowRight", "Home", "End", "Backspace", "Delete", "Enter", "Tab", "Escape"]
    for key in expected_keys:
        if not any(event.get("type") == "keydown" and event.get("key") == key for event in recent_events):
            errors.append(f"expected recent keydown event for {key}")
    if not has_any_event({"keydown", "keyup", "beforeinput", "input"}, "smoke-input"):
        errors.append("expected recent editing DOM events for smoke-input")
elif mode == "clipboard":
    if input_value != expected:
        add_exact_value_error("input after clipboard pass", input_value, expected)
    if not has_any_event({"copy", "cut", "paste", "input"}, "smoke-input"):
        errors.append("expected recent clipboard or input DOM events for smoke-input")
elif mode == "modifier-click":
    for modifier in ("shiftKey", "altKey", "ctrlKey", "metaKey"):
        if not has_event("click", "click-target", **{modifier: True}):
            errors.append(f"expected recent click-target click with {modifier}=true")
elif mode == "modifier-wheel":
    if not isinstance(result.get("scrollTop"), (int, float)) or result.get("scrollTop") <= 0:
        errors.append(f"expected scrollTop > 0, got {result.get('scrollTop')!r}")
    for modifier in ("shiftKey", "altKey", "ctrlKey", "metaKey"):
        if not has_event("wheel", "scroll-target", **{modifier: True}):
            errors.append(f"expected recent scroll-target wheel with {modifier}=true")
elif mode == "ime":
    if expected and input_value != expected and textarea_value != expected:
        if input_value == doubled_text(expected) or textarea_value == doubled_text(expected):
            errors.append(f"composed text appears doubled; expected exactly {expected!r}")
        else:
            errors.append(f"expected composed text {expected!r} in input or textarea")
    if not has_any_event({"compositionstart", "compositionupdate", "compositionend"}):
        errors.append("expected recent composition DOM events")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"PASS: physical {mode} evidence matches expected state")
PY
