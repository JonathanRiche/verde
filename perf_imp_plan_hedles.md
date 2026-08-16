# Verde Desktop Performance + Transcript/Transition Polish Plan

Status: investigation complete, implementation not started.
Scope: `packages/desktop` only. **No Git view, Git sidebar, commit history, diff,
working-tree UI, or Git-related interaction may be planned or modified by this work.**

Motion/interaction reference: X post `https://x.com/winglee/status/2088325135422173226`.
The video could not be fetched from this environment (X requires authentication);
the motion sections below implement the written specification supplied with this
plan (fade-based transcript swaps, stable shell, 150–250 ms restrained transitions).
An implementer with access to the video should sanity-check timings against it but
must not expand scope beyond this document.

All file references are under `packages/desktop/src/` unless noted.

---

## 1. Measured problem and confirmed root causes

Symptom: Kohl & Frisch workspace laggy with browser + chat panes; main SDL/UI
thread 35–54% CPU; `render root` span 25–47 ms/frame (~734 commands, ~365 text
draws); two chat turns `send_pending`. The `render root` span (main.zig:717)
covers only CPU-side `ui_layout.renderRoot()` command building; GPU submission is
the separate `draw_backend` span.

Ranked root causes (evidence-backed):

1. **Pending sends force app-wide continuous rendering, promoted to ~60 fps.**
   - `pendingSendCount()` is a single global counter (state/chat_controller.zig:464,
     inc `beginSend` :476–478, dec only in `pollSend` terminal handling :3980,
     exposed :5910). It stays >0 for the entire duration of a turn, including
     daemon-owned background turns (:2185, :2250). No workspace scoping
     (projection rebuild counts all projects, state.zig:9599–9626).
   - `continuousFrameIntervalMs` (main.zig:1648–1655) requests 33 ms continuous
     frames whenever `sidebar_pulse_animating or pendingSendCount() > 0 or
     hasPendingSlashCommand()`.
   - Tier inversion: `activeContinuousFrames` (main.zig:1619–1632) includes
     `isPaneStatusAnimating()` (main.zig:1626), which workspace_panes.zig:1950
     re-arms every frame while any visible pane's `paneAgentVisualStatus`
     (workspace_panes.zig:667) is non-idle (`.working`/`.waiting`/`.done`; `.done`
     pulses 2800 ms, :45). That returns `ACTIVE_WAIT_TIMEOUT_MS = 16`
     (main.zig:78, :1649), so the intended 33 ms pending tier at :1651 is
     unreachable while a working pane is visible → ~60 fps full-root rebuilds.
2. **Per-frame markdown re-render for replay-cache-ineligible messages.**
   Per-message render-command replay cache exists (chat_panel.zig:5766, translated
   re-emit :5804) but is disabled for messages intersecting a selection or
   containing fenced code with copy buttons (:5746–5751). Agent transcripts are
   code-heavy, so many visible messages re-run `chat_markdown.renderPaletteBody`
   every frame. Prime suspect for the 25–47 ms magnitude.
3. **Sidebar slide relayouts the transcript every animation frame.**
   `computeRootLayout` animates workspace width per frame
   (ui/layout.zig:229–262); `ensureTranscriptLayout`'s fast path requires width
   stable within 0.5 px (chat_panel.zig:2534–2542) → full transcript relayout +
   rewrap on every frame of the sidebar open/close animation. Cost and visible
   jitter source.
4. **Synchronous transcript hydration on the render thread.**
   `loadOlderCurrentThreadMessages` (state.zig:5871) performs a blocking SQLite
   page read (`storage.loadMessagePage`, page size
   `TRANSCRIPT_MESSAGE_PAGE_SIZE = 256`, db/client.zig:58) plus per-message
   string dupes and an O(n) prepend — called from inside transcript rendering
   (chat_panel.zig:840, :1025–1027, :2095–2100, and :2129–2143 "one page per
   frame until the pane is filled"). Opening a long historical thread or
   switching workspaces stalls consecutive frames.
5. **Broad shallow per-frame waste.**
   - Every non-replay-cached string duped into `palette_frame_text_arena` per
     frame (chat_panel.zig:6958–6960 via :7008–7023).
   - Renderer-backed text measurement at queue time per frame for centered
     chrome labels (chat_panel.zig:7045, ui/text_measure.zig:39–49).
   - `pendingFollowupSnapshot`/`pendingApprovalSnapshot` alloc+free every frame
     (chat_panel.zig:340–352).
   - `transcriptLayoutVariantHash` iterates the whole `expanded_cards` map every
     frame (chat_panel.zig:2469).
6. **Browser runtime pins the fast wake tier globally.**
   `isBrowserRuntimeActive` (state/browser_controller.zig:1052–1054) is true when
   controls are visible in *any* workspace; main.zig:1668 then forces the 16 ms
   event-wait unconditionally. Wake/poll overhead only — the browser draw with no
   new frame just references the existing GPU texture (ui/browser.zig:1877–1882);
   texture upload was 0 ms in measurements.

Facts that make the fixes safe:

- Streaming deltas already have an event-driven path: `loop_wakeup` →
  `requestWakeRender` (main.zig:664–666), paced by `FramePacer`
  (runtime/loop_pacing.zig:14–34).
- The "Working – mm:ss" label already repaints at ~1 Hz from `pollSend`'s
  `.pending` branch (state/chat_controller.zig:3863–3878, explicit comment).
- Browser frames render immediately via `pollBrowser` → `browser_needs_render`
  (main.zig:613–618, :677).
- Transcript rendering is already visible-rows-only via binary search
  (chat_panel.zig:2670, :2775), and layout rebuilds are incremental with a
  12 ms/slice budget (:71–72, :2540–2541).

Items to confirm during implementation (reads were interrupted during
investigation): `activityStatusForUi()` mapping for `send_pending` turns;
whether every provider stream delta triggers `loop_wakeup`; sidebar pip-pulse
scoping across projects (ui/sidebar.zig:26, cleared ui/layout.zig:188); Palette
package glyph-shaping cache behavior (`packages/palette`, build.zig.zon:11–12);
whether hydrated threads are ever trimmed back out of memory.

---

## 2. Workstreams

Ordering: P1 → P2 → P3 → U1 → U2 → U3. P1/P2 remove the frame-rate multiplier
and per-frame magnitude first, because U1's 60 fps-transition target is only
achievable once a frame is cheap. P3 (async hydration + atomic commit) is a hard
prerequisite for U1's fade-in-complete-content behavior.

### P1 — Frame pacing correctness (main.zig, workspace_panes.zig)

1. **Fix the tier inversion.** Move `isPaneStatusAnimating()` out of
   `activeContinuousFrames` (main.zig:1626) into the 33 ms tier in
   `continuousFrameIntervalMs` (main.zig:1651). The status pulse is pure
   `nowMs()` math (workspace_panes.zig:697) and looks identical at 30 fps.
2. **Scope pending-send continuous rendering to visible activity.** Replace
   `pendingSendCount() > 0` at main.zig:1651 with a visible-activity predicate
   (current workspace shows a pending chat pane, or the sidebar drew a pulsing
   pip last frame). Keep `pendingSendCount()` in `eventWaitBaseTimeoutMs`
   (main.zig:1677) so the 1 Hz clock tick and wake-driven deltas still repaint
   promptly. Decide pip policy explicitly: background-workspace pips step at
   ~1 Hz (driven by the existing `pollSend` repaint) instead of pulsing at 30 fps.
3. **Browser wake tier.** Narrow main.zig:1668 so an idle browser runtime in a
   non-visible workspace does not pin the 16 ms wake; a browser in the current
   workspace keeps it (frame latency must not regress).

UX impact: none visible except background-work pips stepping instead of
smoothly pulsing. CPU drops from 30–60 fps continuous to event-driven when the
pending work isn't on screen.

Tests: unit tests around `continuousFrameIntervalMs`/`eventWaitBaseTimeoutMs`
tier selection (pending in non-visible workspace → interval 0; status-animating
pane → 33 not 16); existing pending-count tests (chat_controller.zig:2531–2569);
`mise run build`; user-relaunch manual check of streaming responsiveness.

### P2 — Render-cost reductions (chat_panel.zig)

1. **Replay cache for code-block messages.** Cache copy-button hit rects
   alongside the cached `RenderBatch` and re-register them during the translated
   replay (:5804 already translates commands; translate rects identically).
   Keep the selection-intersection exclusion (:5746–5751) — selections genuinely
   change the draw.
2. **Memoize chrome-label text widths** keyed on (text, font_size, ui_scale)
   for `queueCenteredChromeLabel` (:7045).
3. **Cache per-frame snapshots on `ui_revision`** instead of alloc+free each
   frame (`pendingFollowupSnapshot`/`pendingApprovalSnapshot`, :340–352).
4. **Stop hashing `expanded_cards` every frame** (:2469): maintain a revision
   counter bumped on card expand/collapse and compare that instead.
5. Degrade the markdown-entry failure path per-page instead of clearing the
   whole cache (state.zig:5931–5940).

UX impact: none — identical pixels; frames get materially cheaper, which
directly shrinks the measured 25–47 ms `render root` span.

Tests: replay-cache hit/miss unit test for a fenced-code message; copy-button
click after scroll; selection over a code block still renders live; existing
transcript tests; `mise run build`.

### P3 — Thread loading and hydration (state.zig, db/client.zig, chat_panel.zig)

1. **Move page hydration off the render thread.** Replace the render-path calls
   to `loadOlderCurrentThreadMessages` (chat_panel.zig:840, :1025, :2095, :2132)
   with a request → background load → commit flow using the existing
   flush-worker pattern (main.zig:749–757 `pollFlushWorker` precedent). The
   render path only *requests* hydration and renders what it has.
2. **Atomic commit with generation guard.** Tag every hydration request with the
   (project id, local_thread_id, selection generation). Bump the generation on
   `selectThreadForProject` (state.zig:4283) / `selectProjectAtIndex` (:3343).
   A completed load whose generation is stale is dropped — this is also the
   stale-result guard U1 requires (acceptance criterion 5).
3. **Right-size the page.** Viewport-sized first page (~48 messages) with
   background prefetch of the remainder, instead of a blocking 256-row page
   (db/client.zig:58). Keep `TRANSCRIPT_MESSAGE_PAGE_SIZE` for bulk prefetch.
4. **Preserve scroll anchoring rules.** Async hydration must keep the
   "never stomp a saved anchor" behavior (chat_panel.zig:2104–2112) and the
   estimate-space rebase of saved offsets (known issue: saved offsets must be
   rebased when estimated heights change). Tail-pinned threads commit hydration
   pinned to the tail; anchored threads rebase the anchor by the prepended
   height, atomically with the message insert.
5. **Optional (measure first): trim non-current threads** back to their tail
   page on switch-away to bound long-session memory. Only if profiling shows
   growth matters; re-entry re-hydrates via the same async path.

UX impact: opening large historical threads and workspace switches stop
hitching; transcripts appear the same but the shell never stalls.

Tests: unit tests for generation-guarded commit (slow old load vs. new
selection), anchor preservation across an async prepend, tail-pin preservation;
hermetic daemon coverage unaffected; `mise run build`; user-relaunch manual
check of tail scrolling and rapid thread switching.

### U1 — Transcript switch transition (fade out → quiet loading → fade in)

Behavior on conversation/thread selection (per the motion spec; shell — header,
sidebar, composer, pane borders — never moves):

1. Selection feedback in the conversation list is immediate (highlight the row
   the same frame the click lands), independent of transcript readiness.
2. The outgoing transcript region fades out fast (ease-in, ~120 ms opacity-only).
3. If the incoming transcript is not ready within a ~90 ms grace window, show a
   minimal low-contrast activity indicator centered in the transcript area — no
   large skeleton, no composition change. If content is ready inside the grace
   window, skip the indicator entirely (no single-frame empty flash).
4. The incoming transcript is prepared off-screen: async hydration (P3) plus
   layout materialization for the initial viewport
   (`ensureTranscriptLayout` incremental path, chat_panel.zig:2522–2622) run to
   "visible region ready" *before* presentation. Content then fades in as one
   complete, stable block (ease-out, ~180 ms, optional ≤8 px upward offset) at
   its final scroll position — tail for new/active threads, saved anchor for
   revisited ones. No line-by-line reveal, no reflow during the fade.
5. Rapid switching: each selection bumps the P3 generation; any in-flight fade
   or load for a stale generation is cancelled — at most one transition active,
   always ending on the latest selection.

Implementation shape (existing patterns only — no animation framework):

- A small transcript-transition state on the transcript controller:
  `{ phase: idle|fading_out|loading|fading_in, started_ms, generation }`,
  advanced in the render path exactly like the sidebar slide
  (ui/layout.zig:229–262) and focus flash (workspace_panes.zig:185, 160 ms)
  advance today.
- Opacity applied at the region level: multiply alpha on the transcript column's
  queued commands (or scissor + a fade overlay rect matching
  `theme.background()`), not per-element animation. Composer, header, pane
  chrome render fully opaque throughout.
- Continuous frames during the transition come from adding the transition phase
  to `activeContinuousFrames` (main.zig:1619) — bounded to the ~300 ms total
  transition, consistent with the existing focus/sidebar animation entries.
  Transitions target 60 fps only because P1/P2 made frames cheap.
- Input stays live: transitions never block event handling; clicks during
  `fading_out`/`loading` retarget the transition rather than queueing.

Constraint respected: transcript scrolling itself stays direct and non-inertial
(CLAUDE.md) — this workstream animates opacity on switch only, adds no scroll
velocity/decay, and clears any pending transition state on thread switch (no
stale pending scroll).

Tests: unit tests for the transition state machine (grace-window skip, stale
generation cancel, retarget mid-fade); manual acceptance pass (section 4) after
user relaunch.

### U2 — Sidebar/layout transition coherence

1. **Stop per-frame transcript rewrap during the sidebar slide.** During
   `sidebar_animating` (ui/layout.zig:236–260), lay the transcript out at the
   *target* workspace width and clip to the animated width (scissor), so text
   wraps once at the destination instead of every frame. On animation end the
   clip equals the layout width — no snap. This fixes root cause 3 and the
   "text rewrapped every frame" jitter in one change.
2. Panes already resize with the eased width; verify chat/terminal/browser panes
   derive from the same animated rect so the workspace moves as one coordinated
   region (workspace_panes.zig:746/:752 layout walk is per-frame and cheap).
3. Keep frequently used controls anchored: composer and pane headers are
   laid out from pane rects, so (1) automatically keeps their *content*
   stable; verify no header text re-centers per frame during the slide.

Tests: manual wide/laptop/short-height/scaled-display sweep (CLAUDE.md UI
checklist); assert via new counters (section 5) that transcript relayouts per
sidebar animation ≈ 1.

### U3 — Motion tokens and reduced motion

1. Centralize the durations/easings this plan introduces as theme-level
   constants (e.g. `MOTION_FAST_MS = 120`, `MOTION_BASE_MS = 180`,
   ease-out-cubic already exists in `computeRootLayout`'s easing,
   ui/layout.zig:247–249) instead of scattering magic numbers. Reuse for the
   existing 160 ms focus/settings animations where trivial — no broad refactor.
2. **Reduced-motion setting** (new, since none exists): an app-config flag
   surfaced in the settings modal. When on: transitions collapse to their end
   state after a single ~80 ms crossfade (state changes stay unmistakable),
   status pulses render as static badges, sidebar slide shortens to ~80 ms.
   Plumb through the same app-config runtime sync path
   (`app_config_runtime_sync_pending`, main.zig:631–634).

Tests: settings persistence round-trip; transition state machine honors the
flag; manual check.

---

## 3. Explicit non-goals / guardrails

- **No Git UI of any kind** (views, sidebars, history, diffs, working tree,
  interactions) — out of scope regardless of what the reference video shows.
- No inertial/velocity transcript scrolling, no continuous-frame rendering
  outside bounded transitions, no stale pending scroll across thread switches
  (CLAUDE.md "Transcript scrolling" rules).
- No new animation framework; extend the existing per-frame eased-state pattern.
- No changes to daemon transport limits (packages/desktop/src/platform/ipc.zig).
- Streaming text, pending indicators, browser frame presentation, terminal
  output cadence (`terminalActivityBurstActive`, main.zig:1673), and
  workspace-switch rendering must remain as responsive as today — every pacing
  change must preserve the event-driven paths listed in section 1.
- Preserve unrelated worktree changes; smallest correct change per item.

## 4. Acceptance criteria (from the motion spec) → verification

1. No harsh full-screen flash on switch → U1 fade + shell stays opaque; manual.
2. Old transcript leaves cleanly, new arrives as a stable block → U1(4) + P3
   atomic commit; manual + reflow counter (section 5) flat during fade-in.
3. Header/composer/persistent controls never jump → shell excluded from fades;
   U2(3); manual.
4. No repeated reflow or scroll oscillation during load → P3(4) anchoring tests
   + layout-rebuild counter.
5. Rapid selection ends on latest, no stale content → P3(2)/U1(5) generation
   guard; unit test.
6. Smooth under realistic transcript sizes → P1+P2 first; frame-profile line
   (main.zig:1171) shows `render_root_avg_ms` well under 16 ms before U1 lands.
7. UI usable during transitions → transitions are render-side only; manual.
8. Reduced motion clear and functional → U3(2) tests.
9. No Git UI modified → enforced by scope; review checklist item.

## 5. Diagnostics to add (small, behind existing frame-profile logging)

- Sub-spans inside `render_root`: sidebar / workspace_panes / transcript /
  modals (extend section enum at runtime/profiler.zig:19, `recordSpan` pattern
  main.zig:717).
- Per-frame counters in the `frame-profile` log line (main.zig:1171): markdown
  replay-cache hits/misses, `renderPaletteBody` invocations, `textWidth` calls,
  transcript full-relayout count, hydration pages loaded + source (sync/async),
  active pacing-tier reason (pending-send vs pane-status vs pulse vs browser).
- These verify P1/P2/U2 empirically and catch regressions in review.

## 6. Verification protocol per phase

- Every Zig change ends with `mise run build` from the repo root (never bare
  `zig build`; approved lower-level fallback:
  `zig build --release=safe -Dbrowser-backend=native_webview`).
- Focused inline tests + `zig ast-check` during iteration only.
- Claude may be running inside a Verde terminal: do not run `mise run dev*`,
  `zig build run`, or `pkill verde` from a Verde pane — build, then ask the user
  to relaunch for the manual passes (motion feel, streaming responsiveness,
  browser frame latency, tail scroll, workspace switching).
- Daemon-adjacent changes (none planned) would require a user-performed restart;
  hermetic coverage via
  `zig build headless-daemon-it --release=safe -Dbrowser-backend=native_webview`.
- Known pre-existing test failures and `LD_LIBRARY_PATH` quirks are documented
  in the project memory (test-suite quirks note); don't chase unrelated reds.

## 7. Daemon store scaling (proposals only — not yet approved for implementation)

Context (2026-08-15 daemon-CPU diagnosis): the sustained 66–113% daemon CPU and
the ~20s GUI persistence flap were driven by unbounded spin locks plus a store
pipeline where every GUI flush is a full-store `state.snapshot.replace`. The
spin locks, redundant request parses, journal wake batching, POSIX client
request deadline, and the budgeted submit probe are fixed. The remaining
structural costs below are design changes, listed in rough value order. Each
keeps the pinned ipc.zig transport limits untouched.

### 7.1 Incremental store mutations instead of full snapshot.replace

Today the GUI's debounced flush serializes every workspace, thread, and full
transcript into one multi-MB `state.snapshot.replace`; the daemon then parses
it (twice pre-fix, once now), fingerprints it, and wipes/reinserts the entire
SQLite projection while holding the store service lock. Proposal: add narrow
mutation RPCs (`state.workspace.upsert`, `state.thread.upsert`,
`state.thread.delete`, plus a small "presentation" record for layout/focus)
keyed by stable ids, and make the GUI flush only dirty entities (it already
tracks dirty generations). `snapshot.replace` remains as the recovery/first-run
path. Store lock hold time becomes proportional to the delta, not the corpus.
This is the single biggest lever: it shrinks flush payloads, daemon CPU, lock
hold, and journal traffic at once. Requires a protocol version bump and a
dual-write/fallback window for old GUIs.

### 7.2 Fingerprint from request bytes, not re-serialization

`mutationFingerprint` re-serializes the entire applied snapshot to hash it.
Proposal: hash the canonical request payload bytes the client already sent
(post-validation), or maintain a per-entity content hash updated on mutation.
Removes a full-corpus serialize per commit with identical dedup semantics as
long as clients send canonical JSON (they do — one serializer). Cheap,
self-contained, testable by asserting equal fingerprints for equal payloads.

### 7.3 Timed-out-flush reconciliation (committed-anyway detection)

The ~20s flap loop: GUI flush hits its 5s RPC timeout, daemon commits anyway,
GUI treats the flush as failed and re-sends the same multi-MB payload forever.
Proposal: before re-sending after `ConnectionTimedOut`, the GUI issues a cheap
probe (`state.snapshot.fingerprint` or the generation/ack cursor it already
tracks) and skips the resend when the daemon already holds the payload's
fingerprint/generation. Pairs naturally with 7.2; independently valuable even
without 7.1. Also consider raising the flush RPC budget above the debounce
(5s timeout vs multi-second worst-case apply) once apply cost is measured
post-fix.

### 7.4 chat.turn.tail scan caching

Each `chat.turn.tail` re-scans the turn's event list from `after_seq`.
Proposal: keep a per-turn ring index (seq → offset) or a per-poller cursor so
tails are O(new events) rather than O(all events); bound memory with the
existing per-turn event cap. Only worth doing if post-fix profiling still shows
tail scans in the daemon profile — measure first.

### 7.5 Submit acceptance off the event thread (only if still needed)

`chat.turn.start` remains a synchronous acceptance receipt on the SDL event
thread (M4-P3 durability contract), now bounded at the 5s request deadline
with idempotent lost-reply recovery. If post-fix usage still shows multi-second
acceptance stalls, move the RPC to a short-lived worker that reports back
through the existing send_state machinery, keeping the draft locked-but-visible
until acceptance resolves. This is a durability-protocol change (acceptance
ordering vs draft clearing) and needs its own design pass; do not fold it into
a perf patch.

