# macOS WKWebView Manual Input Checklist

Use this checklist for the remaining `mac_webview.md` manual input parity pass.

## Setup

From the repo root:

```bash
mise run mac-webview-manual-signoff
```

This wraps:

```bash
scripts/dev/run-macos-wkwebview-manual-signoff.sh
```

This starts the localhost smoke server when needed, launches the installed app
against `input-regression.html`, runs the guided input checklist, and prints the
manual evidence summary table. It also runs the guided status checklist for
physical inspector gestures and optional hardware mouse back/forward buttons.
Each full signoff run writes to a fresh timestamped directory under
`notes/mac-webview-smoke/manual-evidence/runs/` unless
`VERDE_MAC_WEBVIEW_EVIDENCE_DIR` is set.

To verify the signoff prerequisites without launching Verde or waiting for
physical input:

```bash
scripts/dev/run-macos-wkwebview-manual-signoff.sh --dry-run
```

Dry-run prints the planned run directory but does not create it. Only a real
signoff run creates a timestamped evidence directory.

To run the setup pieces manually instead, start the smoke server:

```bash
cd notes/mac-webview-smoke
python3 -m http.server 8879 --bind 127.0.0.1
```

In another terminal:

```bash
scripts/dev/open-macos-wkwebview-input-smoke.sh
```

Run the launcher from the repo root. It uses `open` to launch the `.app` bundle
as a foreground macOS application with the smoke URL environment variables set.
Do not run `Contents/MacOS/verde` directly from the terminal for physical input
testing; macOS can leave the terminal as the frontmost app, which means physical
keystrokes never reach WKWebView.

After each manual action, capture state with:

```bash
/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde \
  live browser eval --script 'verdeInputSmokeResult()' --json

/Users/jhonellebriche/Applications/Verde.app/Contents/MacOS/verde \
  live status --json
```

Or use the helper to write both commands into a timestamped JSON file:

```bash
scripts/dev/capture-macos-wkwebview-input-evidence.sh text-input-abc123
```

Run the helper from the repo root. For final signoff, set
`VERDE_MAC_WEBVIEW_EVIDENCE_DIR` to the run-specific directory printed by
`scripts/dev/run-macos-wkwebview-manual-signoff.sh`, or run the one-command
signoff script and let it set that directory for you. Standalone helper
captures without that variable are treated as debug captures only.
Each capture tags the page eval with a UTC stamp and waits until live status
reports the matching `browser.last_eval_result`, so the saved JSON contains the
actual `verdeInputSmokeResult()` payload for that manual step.
The capture helpers refuse to write evidence unless Verde was frontmost either
immediately before capture or at capture time. Set
`VERDE_MAC_WEBVIEW_ALLOW_NONFRONTMOST_CAPTURE=1` only for local debugging; that
output is not valid sign-off evidence.

For physical-keyboard checks, prefer the interactive helper because returning to
the terminal before capture makes macOS report the terminal as frontmost:

```bash
scripts/dev/run-macos-wkwebview-manual-input-step.sh text-input-abc123
```

When prompted, click Verde, click the browser input, and type the requested
text. The saved JSON records `macos_frontmost_before_capture`, which should be
`verde` or `Verde` for valid physical input evidence.

To run the text, textarea, editing-key, clipboard, modifier-click,
modifier-wheel, and optional IME checks as one guided sequence, use:

```bash
scripts/dev/run-macos-wkwebview-manual-input-checklist.sh
```

The checklist runner waits for Verde to become frontmost before each step,
captures a timestamped evidence JSON file, validates it with the matching mode,
and prints the evidence file list for the audit. Set
`VERDE_MAC_WEBVIEW_MANUAL_STEP_SECONDS=30` if you need a longer input window for
each step.

Validate saved evidence with the mode that matches the manual action:

```bash
scripts/dev/validate-macos-wkwebview-input-evidence.sh \
  text \
  notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/<capture>-text-input-abc123.json \
  abc123
```

The validator prints a compact summary and fails unless Verde was recorded as
frontmost, the expected page state is present, and the page logged matching DOM
events. Supported modes are:

```bash
scripts/dev/validate-macos-wkwebview-input-evidence.sh text <evidence.json> abc123
scripts/dev/validate-macos-wkwebview-input-evidence.sh textarea <evidence.json> $'line one\nline two'
scripts/dev/validate-macos-wkwebview-input-evidence.sh editing <evidence.json>
scripts/dev/validate-macos-wkwebview-input-evidence.sh clipboard <evidence.json> CopySeed
scripts/dev/validate-macos-wkwebview-input-evidence.sh modifier-click <evidence.json>
scripts/dev/validate-macos-wkwebview-input-evidence.sh modifier-wheel <evidence.json>
scripts/dev/validate-macos-wkwebview-input-evidence.sh ime <evidence.json> '<expected composed text>'
```

For physical inspector gestures and hardware back/forward buttons, capture live
status instead of `verdeInputSmokeResult()`:

```bash
scripts/dev/capture-macos-wkwebview-status-evidence.sh inspector-point
scripts/dev/validate-macos-wkwebview-status-evidence.sh inspector-point \
  notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/<capture>-inspector-point.json

scripts/dev/capture-macos-wkwebview-status-evidence.sh mouse-back
scripts/dev/validate-macos-wkwebview-status-evidence.sh url-contains \
  notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/<capture>-mouse-back.json \
  /one
```

Status validator modes are `inspector-point`, `inspector-draw-box`,
`inspector-draw-freeform`, `url-contains`, and `any`.

To run just the physical inspector and hardware back/forward status checklist:

```bash
scripts/dev/run-macos-wkwebview-manual-status-checklist.sh
```

## Required Passes

- Text input: click the input and type `abc123`. Expected `input` is exactly
  `abc123`, with no doubled letters or mirrored URL-field text.
- Textarea input: click the textarea and type `line one`, Enter, then
  `line two`. Expected textarea value has one newline and no doubled text.
- Editing keys: verify ArrowLeft/ArrowRight, Home, End, Backspace, Delete,
  Enter, Tab, and Escape produce expected DOM events and editable behavior.
- Clipboard shortcuts: in the input, type `CopySeed`, then verify Command+A
  selects it, Command+C copies it, Command+X cuts it, and Command+V pastes it
  once.
- Modifier click: click the click target normally and with Shift, Option,
  Control, and Command held. Expected recent events show the matching modifier
  flags.
- Wheel/trackpad: scroll inside the scroll target normally and with Shift,
  Option, Control, and Command held. Expected `scrollTop` changes and recent
  wheel events show the matching modifier flags.
- IME/composition: enter composed text with a macOS input method. Expected
  composition events are logged and final text appears exactly once.
- Inspector physical gestures: enable inspector, then use actual pointer/trackpad
  gestures for Point, Draw Box, and Draw Freeform. Expected live status receives
  the corresponding `element:selected` or `region:selected` bridge messages.
- Mouse back/forward buttons: navigate to two different localhost pages, use the
  hardware back button, capture status and validate `url-contains` for the first
  page, then use the hardware forward button, capture status and validate
  `url-contains` for the second page. Mark unavailable if the test device has no
  browser back/forward hardware buttons; the guided status checklist records the
  unavailable evidence file when you answer that the device has no hardware
  browser buttons.

## Completion Evidence

Paste the relevant `verdeInputSmokeResult()` JSON snippets and live-status
snippets into `notes/webview_migration_audit.md`. Do not close the macOS goal
until every item above has concrete evidence or is explicitly declared
unavailable for the test device.

The validators intentionally fail evidence where Verde's browser address field
is still focused or where exact expected text appears doubled, such as
`aabbcc112233` instead of `abc123`.

For device-dependent unavailable items, the summary accepts a JSON record like
the one generated by `run-macos-wkwebview-manual-status-checklist.sh`:

```json
{
  "label": "mouse-back-forward",
  "unavailable": true,
  "reason": "test device has no hardware browser back/forward buttons"
}
```

After collecting evidence, generate the summary table with the evidence
directory printed by the signoff script:

```bash
scripts/dev/summarize-macos-wkwebview-manual-evidence.sh \
  notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/*.json
```

To make the final pass/fail status machine-checkable, run:

```bash
scripts/dev/check-macos-wkwebview-manual-evidence-complete.sh \
  notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/*.json
```

The same final check is available as:

```bash
mise run check-mac-webview-manual
```

`mise run check-mac-webview-manual` checks the latest timestamped run directory.
For an older or custom run, use the explicit
`check-macos-wkwebview-manual-evidence-complete.sh <evidence.json>...` command.
Root-level JSON files directly under `notes/mac-webview-smoke/manual-evidence/`
are legacy debug captures and are ignored by the default final checker. A valid
final run must be under
`notes/mac-webview-smoke/manual-evidence/runs/<timestamp>/`.

Review the generated table before pasting it into
`notes/webview_migration_audit.md`; rows marked `missing` or `fail` are not
sign-off evidence.

Use this summary block when updating the audit:

```markdown
### macOS WKWebView Manual Input Pass - YYYY-MM-DD

Tester/device:
App build:
Startup URL: http://127.0.0.1:8879/input-regression.html

| Item | Result | Evidence |
| --- | --- | --- |
| Text input `abc123` | pass/fail/unavailable | `verdeInputSmokeResult()` JSON showing exact `input` value and recent events. |
| Textarea multiline input | pass/fail/unavailable | JSON showing exact `textarea` value and recent events. |
| Editing keys | pass/fail/unavailable | JSON snippets for arrows, Home/End, Backspace/Delete, Enter, Tab, Escape. |
| Command+A/C/X/V | pass/fail/unavailable | JSON showing selection, copy/cut/paste events, and final value. |
| Modifier click | pass/fail/unavailable | Recent events showing Shift/Option/Control/Command modifier flags. |
| Modifier wheel/trackpad | pass/fail/unavailable | Recent wheel events plus changed `scrollTop`. |
| IME/composed text | pass/fail/unavailable | Composition events and final exact text. |
| Inspector physical Point | pass/fail/unavailable | Live status `last_js_message` with `element:selected`. |
| Inspector physical Draw Box | pass/fail/unavailable | Live status `last_js_message` with `region:selected`. |
| Inspector physical Draw Freeform | pass/fail/unavailable | Live status `last_js_message` with `region:selected`. |
| Mouse back/forward buttons | pass/fail/unavailable | Live URL/address before and after hardware button use. |
```
