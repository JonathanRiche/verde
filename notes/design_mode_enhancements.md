# Design mode enhancements — feature research

Sources: Factory AI announcement thread, 2026-07-08
(https://x.com/FactoryAI/status/2074886112695517373 — 6 tweets, 4 videos)
and the companion blog post
https://factory.ai/news/working-with-droid-in-the-desktop-app
("Working with Droid in the Desktop App"). Neither docs.factory.ai nor
their changelog documents the feature further; the blog post is the
canonical write-up.

Purpose of this doc: catalog what the feature actually does (from a
frame-by-frame review of all four videos) so we can decide which elements
to adopt in Verde.

## Thread summary (verbatim intent, paraphrased copy)

1. **Root**: "Live-edit documents, websites, and code diffs directly in the
   Factory Desktop App with design mode." (57s main demo video)
2. **Preview surfaces**: "Reviewing Droid's output shouldn't mean leaving the
   app. Preview outputs directly where you're already working: documents,
   decks, spreadsheets & PDFs · live websites in the in-app browser · full
   code diffs, file by file." (16s video)
3. **Design mode**: "Click the exact element, section, or file you want
   changed and comment on it. Droid picks up the context and makes the edit
   directly." (13s video)
4. **Diff review**: "For code, comment directly on the diff, line by line,
   just like reviewing a teammate's PR. Droid takes your feedback and keeps
   going." (no video)
5. **Sidebar org**: "Filter, group, and organize your sessions in the sidebar
   so the app matches how you actually work." (12s video)
6. **Availability**: today on macOS & Windows, all Factory plans.

Blog post framing: **Preview → Refine → Ship**. Design mode is the "Refine"
step and works on three surfaces: the in-app browser (live sites), generated
files (PDF/deck/spreadsheet — comment anchored to an area of the document),
and code diffs (line-by-line PR-style comments). In every case the comment +
its anchor context is fed to the agent, which makes the edit — there is **no
manual WYSIWYG property editing**; "live-edit" means comment-driven agent
edits.

## The main demo storyline (57s root video)

1. Agent session titled "Designing the launch landing page" in project
   `factory-web`. User prompt: *"Polish the launch landing page, then get it
   building and passing tests."*
2. Agent explores the repo (search chips for `app/(site)/page.tsx`,
   `components/site/Hero.tsx`, `components/site/DeployChart.tsx`), then says:
   *"Live preview is up at localhost:3000 with Design Mode on — click any
   element and tell me what to change."*
3. User opens the side panel switcher: **Browser (⇧⌘B) / Changes (⌘E) /
   Terminal (⌘J) / Side chat (⌥⌘S)** — the Changes row already shows a live
   `+7 -3` diffstat.
4. In the embedded browser (`localhost:3000`), a cursor-with-sparkle icon in
   the toolbar toggles **Design Mode** (tooltip on hover).
5. User hovers the hero headline → element gets a blue selection outline.
   Click → an inline prompt bubble appears anchored directly below the
   element. User types "make the headline bigger", submits.
6. Agent edits real source (`app/(site)/page.tsx +12 -4`), replies "Bumped
   the title to text-5xl font-semibold for more presence." Preview hot-reloads.
7. User drag/multi-selects **both CTA buttons** as a group, prompts "make the
   buttons orange" → agent edits `app/(site)/page.tsx +7 -6` **and**
   `tailwind.config.ts +3`, replies "DOWNLOAD and CONTACT SALES now use brand
   orange (#ee6018)." (It added a proper brand token rather than inlining a hex.)
8. User flips to the **Changes** panel: unified diff view, "2 Uncommitted
   Changes" header, per-file diffstat, syntax-highlighted hunks with
   old/new line numbers.
9. **Terminal** panel: runs `pnpm build` (Next.js build output streams in).
   The agent separately runs build + tests itself — transcript shows tool
   chips "Run the production build" → "Compiled successfully; 24 static pages
   generated." and "Run tests and verify everything passes" → "42 tests
   passed. Ready to commit."
10. **Side chat** panel: a second, parallel Q&A thread ("Ask questions on the
    side without interrupting the main conversation"). User asks "Where does
    the deploy throughput chart get its data?" — agent answers with a file
    chip (`lib/metrics.ts`) plus a short explanation, while the main thread
    keeps its own state.

## Functionality inventory

### 1. Design Mode toggle in the embedded browser

- Lives in the browser pane toolbar next to fullscreen/kebab buttons; icon is
  a cursor with a small `+`/sparkle; hover tooltip "Design Mode"; active state
  is a filled/accent button.
- It's a **mode**: while on, mouse input over the page is intercepted for
  element inspection instead of normal page interaction.
- The agent can apparently turn it on itself and advertise it ("Live preview
  is up … with Design Mode on").

### 2. Element selection

- Hover: light blue outline around the DOM element under the cursor
  (DevTools-inspect-like affordance).
- Click: selection is pinned with a stronger blue border + subtle tint.
- **Multi-element selection**: a group (both CTA buttons + surrounding row)
  can be selected as one region; the outline wraps the union rect. One prompt
  then applies to the whole selection.

### 3. Inline prompt bubble (the core interaction)

- A floating dark pill appears anchored directly beneath the selected
  element: `[cursor icon] [text field] [submit →] [close ×]`.
- Empty-state placeholder: **"What should Droid do with this?"** — frames the
  bubble as an instruction to the agent, not a caption.
- Free-form natural-language instruction ("make the headline bigger",
  "make the buttons orange") — no style panels, no property editors. The
  element selection supplies the *what*, the text supplies the *how*.
- Pending state: on submit, the submit button becomes an orange spinner and
  the bubble dims/grays until the edit lands; selection outline persists.
- Result: source code is edited, dev server hot-reloads, the change is
  visible in place. The bubble can be dismissed or reused for another prompt.

### 4. Transcript integration (what the chat shows for a design edit)

- Each design-mode prompt becomes a user message rendered as a **card**: a
  small screenshot crop of the selected element on white background, with the
  prompt text as the caption below it.
- Agent turn shows: "Thought for 1s" disclosure → **file-edit chips** with
  per-file diffstat (`app/(site)/page.tsx +7 -6`, `tailwind.config.ts +3`) →
  a one-line natural-language summary of what changed.
- Tool runs render as compact chips too ("Run the production build") with a
  one-line result underneath.
- Composer details visible: placeholder "Send follow-up · Ctrl+Enter to queue
  for later" (queueing follow-ups while the agent works), `+` attach, mic,
  `Auto Model` and `Auto High` (effort) pickers with meter glyphs, `MCP (9)`
  status pill, `?` help.

### 5. Panel system (right-side surfaces over one session)

Quick switcher listing four surfaces with shortcuts, each also an icon in a
compact rail at the top of the right pane:

| Surface   | Shortcut | Notes |
|-----------|----------|-------|
| Browser   | ⇧⌘B      | embedded browser w/ URL bar, back/forward/reload, fullscreen, Design Mode toggle |
| Changes   | ⌘E       | git working-tree diff viewer; live `+N -N` badge in the switcher itself |
| Terminal  | ⌘J       | real shell (`zsh · factory-web`), tabs (`+`), kebab menu |
| Side chat | ⌥⌘S      | secondary chat thread parallel to the main one |

- Chat transcript stays on the left; the right pane swaps between these
  surfaces. Switching is instant and stateful (terminal scrollback, browser
  page, diff scroll position all persist).

### 6. Changes panel (live diff viewer)

- Header: branch + repo (`main · factory-web`), refresh, kebab.
- Collapsible "2 Uncommitted Changes" section with total diffstat on the right.
- Per-file blocks: `M` status badge, path, per-file `+N -N`; unified diff with
  hunk headers (`@@ -38,5 +38,5 @@ export function Hero() {`), old/new line
  number gutters, red/green row tinting, syntax highlighting.
- The diffstat badge in the panel switcher updates live as the agent edits —
  you can see churn without opening the panel.
- (Per the tweet, diffs are also live-*editable* in the desktop app, though
  the video only shows viewing.)

### 7. Side chat

- Empty-state copy: *"Ask questions on the side without interrupting the main
  conversation."*
- Own composer ("Ask a question…"), own transcript; answers include file
  chips (e.g. `lib/metrics.ts`) like the main thread.
- Use case shown: codebase Q&A while the main thread is mid-task — keeps the
  main context/timeline clean.

### 8. Document/file preview surface (video 2)

- Layout: left sidebar (navigation + projects/sessions), chat transcript in
  the middle, preview pane on the right — transcript and output side by side.
- The agent generates a PDF whitepaper; the transcript shows it as a **file
  chip**: file icon, `software-factory-whitepaper.pdf +28`, subtitle
  `PDF · 28 KB`, and an **"Open in ▾"** split button (open in preview pane /
  external app).
- The preview pane renders the PDF natively: filename breadcrumb, back
  button, fullscreen and download icons; page scrolls like a document viewer.
- Per the blog post, the same surface handles decks, spreadsheets, and other
  generated files, and design-mode comments can anchor to an **area of the
  document** the same way they anchor to DOM elements in the browser.
- Composer shows a "Normal Mode" pill in this session (mode selector distinct
  from model/effort pickers).

### 9. Diff line-comments (tweet 4, no video)

- The Changes/diff surface accepts **PR-style line-by-line comments**;
  the agent "takes your feedback and keeps going." Same comment→agent loop
  as the browser and document surfaces, anchored to diff lines instead of
  elements. This is the third leg of design mode.

### 10. Sidebar session organization (video 5)

- "Projects" section header has a filter icon (tooltip "Customize Sidebar")
  opening a popover with rows: **Last activity** (e.g. 30 days), **Type**
  (multi-select, "2 selected"), **Project** (All / per-repo), **Computer**
  (All computers / This Mac / prod-3 / my-droid-computer — sessions can live
  on remote machines), **Group by** (Project), **Sort by** (Recent).
- Filtering by computer collapses the list and suffixes group headers with
  the machine name (`pixel-forge · my-droid-computer`).
- Session rows: title (truncated), relative age (`1h`, `3d`, `2w`), orange
  dot for the active/running session, "Show more" per group.

## Design details worth stealing

- **Selection → anchored prompt** beats a generic "describe the change" box:
  the screenshot crop + element identity gives the agent precise context, and
  the user never has to describe *where*.
- **The prompt-card transcript representation**: design edits read back as
  "picture of the thing + what I asked" — instantly scannable history.
- **Live diffstat badge on the Changes switcher row** — ambient awareness of
  agent churn with zero clicks.
- **Multi-select before prompting** — one instruction over N elements.
- **Agent closes the loop**: after visual tweaks it runs build + tests
  unprompted (part of the original instruction) and reports "Ready to commit."
- **Side chat** as a first-class second thread, not a modal — questions don't
  pollute the working thread's context.
- **Queue follow-ups**: composer explicitly supports queuing the next message
  while a send is in flight (Ctrl+Enter).
- Pending-state affordance on the inline bubble (spinner + dim) keeps the
  browser overlay honest about in-flight work.
- **One mental model, three surfaces**: "select a thing, comment on it, the
  agent edits" is identical for web elements, document regions, and diff
  lines. The anchor type changes; the interaction doesn't.
- Sidebar filter popover (activity window / type / project / computer /
  group / sort) scales the session list without forcing folders on users.

## Mapping to Verde (initial thoughts, not commitments)

- Verde already has: embedded browser pane, terminal panes, chat threads,
  panel splitting, a changed-files card concept in the transcript contract.
- The likely Verde translation of design mode:
  1. A toggle on the browser pane toolbar that injects an inspect script
     (hover outline + click-to-select via `elementFromPoint`, union rects for
     drag multi-select) into the webview.
  2. Selection produces: element screenshot crop + CSS selector/DOM path +
     bounding rect, packaged as a prompt attachment (fits the existing
     provider-neutral image attachment contract in `SendPromptRequest.images`).
  3. An anchored native overlay input (Palette-drawn, positioned over the
     webview at the selection rect) that submits to the pane's associated
     chat thread.
  4. Transcript rendering: reuse the image-card pathway for the
     "element crop + caption" user message; file-edit chips already map to
     our diff/changed-files card direction.
- Side chat ≈ a lightweight second thread bound to the same project/worktree;
  Verde's thread model may already cover this — the UI affordance (split
  beside the main transcript with its own composer) is the new part.
- Changes panel with live diffstat badge would hang off the existing git
  state the daemon can already query.
- Diff line-comments would be the cheapest surface to start with: no webview
  injection needed — a native diff viewer where clicking a line opens the
  same anchored input, and the send packages `file:line + hunk context +
  comment` into the prompt.
- Sidebar filter popover maps onto Verde's project/thread sidebar; "Computer"
  has an analog if/when threads can live on remote daemons.

## Implementation status (Verde, 2026-07-11)

### Completed in this pass — inspector core loop

The full "select → comment → agent edits" loop now works in the embedded
browser via the bundled inspector:

- **Auto-send from the inline bubble.** `prompt:submitted` no longer just
  appends to the composer draft: when the current thread is idle and the
  composer is clean, the prompt + selection context is sent straight to the
  active chat thread (`handleInspectorPromptSubmitted` in
  `packages/desktop/src/state.zig`). If a send is already running or the user
  has an in-progress draft, the prompt falls back to a draft append (with the
  capture attached) and the bubble reports "drafted".
- **Element screenshot crop as an image attachment.** On submit the JS bundle
  hides the overlay for two frames, reports viewport metrics
  (size + devicePixelRatio), and the Zig side crops the latest CPU-side
  browser frame (BGRA, Linux WPE path) at the selection rect + 12 CSS px of
  context, encodes it as PNG (new `packages/desktop/src/browser/screenshot.zig`,
  zlib via `std.compress.flate`), stores it under
  `{pref_path}/inspector-captures/`, and attaches it through the existing
  multi-image prompt contract. Backends without a CPU frame gracefully send
  text-only context (`copyFramePixels` is null on macOS/Windows/CEF/stub).
- **Pending state on the bubble.** Submit disables the input, dims the panel,
  and shows a spinner; the host acks via a new
  `InspectorHandle.notifyPromptResult("sent" | "drafted" | "failed", message)`
  API (evaled back into the page), with a 30 s timeout fallback.
- **Bubble UX polish.** The prompt panel is now anchored directly below the
  selection (flips above near the bottom edge, clamped to the viewport)
  instead of pinned bottom-right; Enter submits (Shift+Enter for newline);
  placeholder is "What should the agent do with this?".
- **Transcript card.** The auto-sent user message carries the crop as a normal
  image attachment, so the existing transcript pathway renders it as
  "prompt text + selection context + crop thumbnail".
- Multi-element selection already existed (draw-box / draw-freeform union
  regions) and now flows through the same auto-send + capture path.
- **Thread targeting.** Prompts go to the project's last-focused chat thread
  (`selected_thread_index`; focusing the browser pane does not change it).
  When a selection is captured, the host pushes the visible chat panes into
  the bubble (`setPromptTargets`): with one open chat pane nothing is shown
  (the destination is unambiguous), with two or more the bubble shows a
  "Send to" selector defaulting to the last-focused thread, and the submit
  payload carries the chosen pane id so the host routes the send there.

### TODOs — not in this pass

- **Agent/CLI arming of design mode** (`verde live browser inspector
  enable/disable/mode`) so the agent can turn it on and advertise it.
- **Changes panel**: native git working-tree diff viewer pane with a live
  `+N -N` diffstat badge in the pane switcher.
- **Diff line-comments**: PR-style comment-on-a-line → same anchored prompt →
  send loop, on the (future) Changes surface.
- **Side chat**: lightweight second thread beside the main transcript with its
  own composer.
- **Sidebar filter popover** (activity window / type / project / group /
  sort).
- **Queue follow-ups from the bubble**: when a send is in flight we currently
  fall back to draft-append; a "queue as follow-up" path
  (`queueOrSteerDraftDuringSend`) could keep the loop hands-free, but it
  cannot carry image attachments today.
- **Compact transcript rendering** for design-mode messages: collapse the
  selection-context block so the card reads "crop + caption" like Factory's,
  instead of showing the full context text.
- **Screenshot capture on macOS/Windows/CEF** backends (needs a per-backend
  snapshot API; only the Linux WPE offscreen path has CPU frames today).
- **Capture race hardening**: the overlay hides for two rAFs before submit,
  which in practice yields a clean frame, but the host captures "latest frame"
  rather than a guaranteed post-hide frame; a frame-sequence handshake would
  make it deterministic.

## Open questions

- How Factory captures element context (selector? React fiber? screenshot
  only?) — not visible in any video or the blog post.
- Exact activation mechanics (shortcut? per-surface toggle naming) — the
  browser toolbar toggle is the only activation shown; docs don't cover it.
- Whether design-mode prompts run in the main thread (they appear in the main
  transcript in the demo) or can target a side thread.
- How diff line-comments are batched — one comment per send, or collect
  several then submit (PR-review style)? Tweet copy implies the latter but
  nothing is shown.
