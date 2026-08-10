# Living baselines — update when a fix or acceptance round establishes new numbers

Last updated: 2026-08-10, HEAD 62c53792 (issue #116 final performance/state
campaign). Numbers were measured on the user's machine against real state or
in explicitly isolated/hermetic campaign environments, as noted.

## Automated release gates

- Desktop suite: **935/940 passed**, with exactly five skips and zero
  failures (36/36 build steps succeeded).
- Headless daemon integration: **23/23 passed**, with exactly four known
  `DebugAllocator` reports.
- Zig format/AST checks and the full release-safe `mise run build` passed.

## Headless, attach, and lifecycle baseline

| Area | Metric | Baseline | FAIL threshold |
|---|---|---|---|
| Headless CLI | `core status` / `capabilities` / `changes` / scoped snapshot | ~7-10 ms | >100 ms, or any `DaemonReplacementBlocked` |
| Headless CLI | unscoped `core snapshot` on large state | exit 4 `response_too_large` ~750 ms | anything else (this is by design; scoped snapshot is the supported path) |
| MCP | stdio initialize + tools/list, zero GUI | ~14 ms, 37 tools | error, missing tools, or GUI required |
| Launch | dispatch → window mapped | initial 112.70 ms; relaunch 82.35 ms | >1 s |
| Launch | mapped → fully restored UI | initial <=5.31 s; relaunch with exact draft <=2.96 s | >6 s |
| Attach | persistence banner | none; attaches read-write to existing daemon | any "persistence unavailable" banner |
| Attach | daemon count | exactly one `__session-daemon` for the real XDG dir | a second daemon appears |
| Close | WM closewindow → window gone (any focus/occlusion state) | ~9-18 ms | >1 s, or close ignored |
| Close | window gone → process exit | ~0.4-2.73 s in final runs; durability occurs in the hidden process | >15 s, or window re-shows (report handoff `elapsed_ms`) |
| Persistence | QATEST entity and unsent draft survive close + relaunch exactly | yes | data loss, draft mutation, or unintended send |
| Second instance | coexists with first, same daemon, no corruption, no banner | yes | rejection, corruption, or second daemon |
| Daemon | survives every GUI exit | yes | daemon dies or restarts |

## Switching acceptance

- Initial dispatch-to-map was **112.70 ms**, with full restore within **5.31
  s** of map. Relaunch dispatch-to-map was **82.35 ms**, with the exact unsent
  draft restored within **2.96 s**.
- The sustained run completed **18 switches over 29 s**. Screenshot-derived
  first visual change was **5.9-115.8 ms** and the maximum traced presentation
  was **102.13 ms**. No post-presentation freeze over 200 ms was confirmed.
- Six immediate dirty-draft switches completed without loss. The exact unsent
  `QATEST-switching` draft survived normal close/relaunch and remained unsent.

| Metric | Baseline | FAIL threshold |
|---|---|---|
| Repeat or sustained Alt+number switch | first visual change <=115.8 ms in the accepted run; no post-switch freeze | >300 ms to visual change, or any confirmed frozen interval >200 ms after the changed frame |
| First visit to a heavy workspace | <1 s target; the final run did not distinctly capture the heaviest target's first presentation because it was superseded after ~130 ms | >2 s |
| Switching diagnostics after restore | traced presentation <=102.13 ms; no active-test SDL stall >200 ms | any operation or post-presentation stall >200 ms (name the operation) |
| Dirty-draft switching and relaunch | six immediate switches; exact unsent draft restored | loss/mutation, unintended send, or failure to restore exactly |

## State-fidelity acceptance

The isolated real-GUI campaign passed the relevant normal relaunch, sidebar
activation, maximize/unmaximize, resize, and away/back paths:

- Sidebar reveal remained bounded to the minimal viewport stride, without a
  collapsed pane or trailing black void.
- Nested pane IDs/tree, horizontal and vertical ratios, viewport, focused pane,
  and maximized pane survived relaunch and away/back activation.
- Browser pane ownership, ready runtime, URL, title/content, and natural
  history survived relaunch.
- Terminal pane, dock, running session, and CWD survived relaunch.
- The friendly surface label survived, with **exactly one** eligible `ACTIVE`
  surface; clear reduced the count to zero without a duplicate or raw-ID row.

| Metric | Baseline | FAIL threshold |
|---|---|---|
| Sidebar reveal | minimal bounded stride; target panes fully visible | overscroll, collapsed/blank pane, trailing void, or target not revealed |
| Layout persistence | exact pane IDs/tree/ratios/viewport/focus/maximize | any structural, ratio, viewport, focus, or maximize mismatch after a relevant restore |
| Browser persistence | same pane/runtime/owner/URL/title/history, visible when selected | missing/wrong pane or owner, runtime not ready, URL/title/history loss, or corrupt surface |
| Terminal persistence | same pane/dock/running session/CWD | missing or duplicate pane/session, stopped session, wrong dock, or CWD loss |
| Surface identity | friendly label and exactly one `ACTIVE` surface | raw ID, wrong label, zero while working, duplicate ACTIVE rows, or failure to clear |

## Final exact-stage hermetic/isolated real-GUI profile

Across ten valid cycles, the observed maxima were:

| Stage | Maximum |
|---|---:|
| Command-buffer acquire | 0.07 ms |
| Swapchain-texture acquire | 6.89 ms |
| Submit/present | 0.85 ms |
| Renderer browser upload | 2.25 ms |
| Browser shared-memory read | 0.000 ms |
| Browser frame upload | 2.762 ms |
| Workspace render-root/cursor | 7.07 ms |
| Pre-render poll | 0.03 ms |

The ten cycles had **zero generic SDL-thread stalls, zero slow frames, and zero
main-loop gaps**.

### Conservative acquisition caveat

The historical intermittent **804-1160 ms combined command-buffer+swapchain
measurement was not reproduced** in the ten valid final cycles. This does not
establish a GPU behavior fix, identify either acquire call as the historical
cause, or prove that the historical event cannot recur. The final change only
split the exact-stage diagnostics so a future recurrence can be attributed
without speculative behavior changes.

## Remaining known residual

- Cross-scale monitor movement (1.0x <-> 1.67x) can leave a partially rendered
  window until relaunch (P2). This was not superseded by the final campaign.
