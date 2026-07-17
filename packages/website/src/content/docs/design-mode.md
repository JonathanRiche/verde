---
title: Design Mode
description: Select elements or regions in the embedded browser and route visual feedback to a Verde chat or terminal agent.
section: Workspace
order: 4
slug: design-mode
---

## Start Design Mode

Open your app in Verde's browser pane, then click the inspector button beside
the address bar. Design Mode overlays the page so you can turn a visual target
into an agent-ready prompt without describing its location by hand.

Use the inspector's dropdown to choose a selection mode:

- **Point** — click one DOM element.
- **Draw Box** — drag a rectangular region.
- **Draw Freeform** — draw around an irregular region.

Design Mode works on `app://` content and HTTP(S) pages, including localhost
preview servers. It is unavailable on restricted URL schemes such as `file:`,
`data:`, and `about:`.

## Describe the change

After making a selection, type the requested change in the prompt bubble. Verde
adds selection context such as the page URL, element details, and selected
geometry. This gives the agent both your instruction and a stable description
of what you pointed at.

The selection overlay belongs to the page preview; it does not edit the page
or source files by itself. The receiving agent still decides what code to
inspect and change.

## Choose where to send it

When more than one compatible agent pane is open, **Send to** lets you choose a
chat thread or terminal TUI. With only one target, Verde selects it
automatically.

- An idle chat with a clean composer sends immediately.
- A working chat can receive the request as a queued follow-up.
- If the chat already has an unsent draft, Verde preserves it and places the
  Design Mode request in the composer instead of overwriting or unexpectedly
  sending the draft.
- A terminal TUI receives the prompt as pasted input but does not submit it.
  Review or edit the text in the TUI, then press `Enter` yourself.

## Screenshots and platform support

All native browser backends support the selection overlay and text context:
WPE WebKit on Linux, WKWebView on macOS, and WebView2 on Windows.

Selection screenshots currently require the Linux WPE backend's frame-copy
support. On macOS and Windows, Design Mode still sends the instruction and DOM
selection context without an image. If a screenshot is captured, chat targets
receive it as an attachment; terminal targets receive its local file path in
the pasted prompt.

## Control Design Mode from the CLI

The live CLI can enable the inspector and select its mode:

```bash
verde live browser inspector-enable
verde live browser inspector-mode --mode point
verde live browser inspector-mode --mode draw-box
verde live browser inspector-mode --mode draw-freeform
verde live browser inspector-disable
```

`inspector-toggle` is also available. Add `--json` for automation, and use the
other browser commands to open or navigate the preview first. See
[CLI reference](/docs/cli#browser-control).
