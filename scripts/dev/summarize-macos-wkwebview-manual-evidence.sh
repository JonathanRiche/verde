#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "missing required command: python3" >&2
  exit 1
fi

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 <evidence.json>..." >&2
  exit 2
fi

python3 - "$@" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

paths = sys.argv[1:]

ITEMS = [
    ("text", "Text input `abc123`"),
    ("textarea", "Textarea multiline input"),
    ("editing", "Editing keys"),
    ("clipboard", "Command+A/C/X/V"),
    ("modifier-click", "Modifier click"),
    ("modifier-wheel", "Modifier wheel/trackpad"),
    ("ime", "IME/composed text"),
    ("inspector-point", "Inspector physical Point"),
    ("inspector-draw-box", "Inspector physical Draw Box"),
    ("inspector-draw-freeform", "Inspector physical Draw Freeform"),
    ("mouse-back-forward", "Mouse back/forward buttons"),
]

def classify(label):
    label = (label or "").lower()
    if "text-input" in label or "abc123" in label or "typing" in label:
        return "text"
    if "textarea" in label:
        return "textarea"
    if "editing" in label or "edit" in label or "arrow" in label or "home-end" in label or "backspace" in label:
        return "editing"
    if "clipboard" in label or "command-a" in label or "copy" in label or "cut" in label or "paste" in label:
        return "clipboard"
    if "modifier-click" in label:
        return "modifier-click"
    if "modifier-wheel" in label or "trackpad" in label:
        return "modifier-wheel"
    if "ime" in label or "composed" in label or "composition" in label:
        return "ime"
    if "inspector-point" in label:
        return "inspector-point"
    if "inspector-draw-box" in label:
        return "inspector-draw-box"
    if "inspector-draw-freeform" in label:
        return "inspector-draw-freeform"
    if "mouse-back" in label or "mouse-forward" in label or "back-forward" in label:
        return "mouse-back-forward"
    return None

def decode_input_result(browser):
    raw = browser.get("last_eval_result")
    if not isinstance(raw, str):
        return None
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return None
    result = decoded.get("result")
    return result if isinstance(result, dict) else None

def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    status = payload.get("status", {}).get("result", {})
    browser = status.get("browser", {})
    focus = status.get("focus", {})
    label = payload.get("label") or os.path.basename(path)
    frontmost_before = payload.get("macos_frontmost_before_capture") or ""
    frontmost_capture = payload.get("macos_frontmost_process") or ""
    frontmost_ok = frontmost_before in {"verde", "Verde"} or frontmost_capture in {"verde", "Verde"}
    runtime_ok = (
        browser.get("runtime_kind") == "native_webview"
        and browser.get("presentation_kind") == "native_child_view"
        and browser.get("status") == "Ready"
        and browser.get("last_error") is None
    )
    input_result = decode_input_result(browser)
    return {
        "path": path,
        "label": label,
        "stamp": payload.get("stamp"),
        "item": classify(label),
        "unavailable": payload.get("unavailable") is True,
        "unavailable_reason": payload.get("reason") or payload.get("unavailable_reason") or "",
        "frontmost_ok": frontmost_ok,
        "runtime_ok": runtime_ok,
        "browser": browser,
        "focus": focus,
        "input_result": input_result,
    }

def recent_events(record):
    result = record.get("input_result") or {}
    events = result.get("recentEvents")
    return events if isinstance(events, list) else []

def has_event(record, event_type, target=None, **mods):
    for event in recent_events(record):
        if event.get("type") != event_type:
            continue
        if target is not None and event.get("target") != target:
            continue
        if all(event.get(key) is value for key, value in mods.items()):
            return True
    return False

def has_any_event(record, types, target=None):
    return any(
        event.get("type") in types and (target is None or event.get("target") == target)
        for event in recent_events(record)
    )

def status_message(record):
    message = record["browser"].get("last_js_message")
    if not isinstance(message, str):
        return None
    try:
        return json.loads(message)
    except json.JSONDecodeError:
        return None

def record_passes(record, item):
    if not record["frontmost_ok"] or not record["runtime_ok"]:
        return False
    if record["focus"].get("browser_address_focused") is True:
        return False

    result = record.get("input_result")
    browser = record["browser"]

    if item == "text":
        return (
            isinstance(result, dict)
            and result.get("input") == "abc123"
            and isinstance(result.get("eventCount"), int)
            and result.get("eventCount") > 0
            and has_any_event(record, {"beforeinput", "input", "keydown", "keyup"}, "smoke-input")
        )
    if item == "textarea":
        return (
            isinstance(result, dict)
            and result.get("textarea") == "line one\nline two"
            and isinstance(result.get("eventCount"), int)
            and result.get("eventCount") > 0
            and has_any_event(record, {"beforeinput", "input", "keydown", "keyup"}, "smoke-textarea")
        )
    if item == "editing":
        expected_keys = ["ArrowLeft", "ArrowRight", "Home", "End", "Backspace", "Delete", "Enter", "Tab", "Escape"]
        return (
            isinstance(result, dict)
            and isinstance(result.get("eventCount"), int)
            and result.get("eventCount") > 0
            and all(any(event.get("type") == "keydown" and event.get("key") == key for event in recent_events(record)) for key in expected_keys)
            and has_any_event(record, {"keydown", "keyup", "beforeinput", "input"}, "smoke-input")
        )
    if item == "clipboard":
        return (
            isinstance(result, dict)
            and result.get("input") == "CopySeed"
            and isinstance(result.get("eventCount"), int)
            and result.get("eventCount") > 0
            and has_any_event(record, {"copy", "cut", "paste", "input"}, "smoke-input")
        )
    if item == "modifier-click":
        return all(has_event(record, "click", "click-target", **{modifier: True}) for modifier in ("shiftKey", "altKey", "ctrlKey", "metaKey"))
    if item == "modifier-wheel":
        return (
            isinstance(result, dict)
            and isinstance(result.get("scrollTop"), (int, float))
            and result.get("scrollTop") > 0
            and all(has_event(record, "wheel", "scroll-target", **{modifier: True}) for modifier in ("shiftKey", "altKey", "ctrlKey", "metaKey"))
        )
    if item == "ime":
        return isinstance(result, dict) and has_any_event(record, {"compositionstart", "compositionupdate", "compositionend"})
    if item.startswith("inspector-"):
        message = status_message(record)
        if not isinstance(message, dict) or message.get("source") != "verde-inspector":
            return False
        expected_type = "element:selected" if item == "inspector-point" else "region:selected"
        if message.get("type") != expected_type:
            return False
        raw = browser.get("last_js_message") or ""
        if item == "inspector-draw-box":
            return '"mode":"draw-box"' in raw
        if item == "inspector-draw-freeform":
            return '"mode":"draw-freeform"' in raw
        return True
    if item == "mouse-back-forward":
        label = record["label"].lower()
        return "mouse-back" in label or "mouse-forward" in label
    return False

records = [load(path) for path in paths]
by_item = {}
for record in records:
    item = record["item"]
    if item is None:
        continue
    by_item.setdefault(item, []).append(record)

date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
print(f"### macOS WKWebView Manual Input Pass - {date}")
print()
print("Tester/device:")
print("App build: /Users/jhonellebriche/Applications/Verde.app")
print("Startup URL: http://127.0.0.1:8879/input-regression.html")
print()
print("| Item | Result | Evidence |")
print("| --- | --- | --- |")

def evidence_text(record):
    browser = record["browser"]
    result = record["input_result"]
    parts = [f"`{record['path']}`"]
    if record.get("unavailable"):
        reason = record.get("unavailable_reason")
        parts.append(f"unavailable: {reason}" if reason else "unavailable")
        return "; ".join(parts)
    if record["frontmost_ok"]:
        parts.append("frontmost Verde")
    else:
        parts.append("frontmost not proven")
    if result:
        if "input" in result:
            parts.append(f"input={result.get('input')!r}")
        if "textarea" in result:
            text = result.get("textarea")
            if text:
                parts.append(f"textarea={text!r}")
        parts.append(f"events={result.get('eventCount')!r}")
    if browser.get("last_js_message"):
        parts.append("last_js_message present")
    if browser.get("url"):
        parts.append(f"url={browser.get('url')}")
    return "; ".join(parts)

for key, title in ITEMS:
    records_for_item = by_item.get(key, [])
    if not records_for_item:
        print(f"| {title} | missing | No evidence file supplied. |")
        continue
    unavailable = [record for record in records_for_item if record.get("unavailable")]
    passing = [record for record in records_for_item if record_passes(record, key)]
    if key == "mouse-back-forward":
        has_back = any("mouse-back" in record["label"].lower() for record in passing)
        has_forward = any("mouse-forward" in record["label"].lower() for record in passing)
        result = "pass" if has_back and has_forward else ("unavailable" if unavailable else "fail")
    else:
        result = "pass" if passing else ("unavailable" if unavailable else "fail")
    best = passing[-1] if passing else (unavailable[-1] if unavailable else records_for_item[-1])
    print(f"| {title} | {result} | {evidence_text(best)} |")

unknown = [record for record in records if record["item"] is None]
if unknown:
    print()
    print("Unclassified evidence files:")
    for record in unknown:
        print(f"- `{record['path']}` label={record['label']!r}")
PY
