# Living baselines — update when a fix or acceptance round establishes new numbers

Last updated: 2026-08-09, HEAD 553e4002 (post issue-#116 field campaign,
rounds 1-7). Numbers measured on the user's machine with real ~136MiB state.

| Area | Metric | Baseline | FAIL threshold |
|---|---|---|---|
| Headless CLI | `core status` / `capabilities` / `changes` / scoped snapshot | ~7-10 ms | >100 ms, or any `DaemonReplacementBlocked` |
| Headless CLI | unscoped `core snapshot` on large state | exit 4 `response_too_large` ~750 ms | anything else (this is by design) |
| MCP | stdio initialize + tools/list, zero GUI | ~14 ms, 37 tools | error, missing tools, or GUI required |
| Launch | spawn → window mapped | 70-95 ms (+ themed loading frame) | >1 s |
| Launch | mapped → fully restored UI | ~4.0 s (known residual) | >6 s |
| Attach | persistence banner | none; attaches read-write to existing daemon | any "persistence unavailable" banner |
| Attach | daemon count | exactly one `__session-daemon` for the real XDG dir | a second daemon appears |
| Close | WM closewindow → window gone (any focus/occlusion state) | ~9 ms | >1 s, or close ignored |
| Close | window gone → process exit | 0.4-4.7 s (durability in hidden process) | >15 s, or window re-shows (report handoff elapsed_ms) |
| Switching | Alt+number, repeat visit | <300 ms visual, no post-switch freeze | >300 ms, or any frozen interval >200 ms after the switched frame |
| Switching | Alt+number, first visit to heavy workspace | <1 s target (incremental layout) | >2 s |
| Switching | `SDL thread stall` markers during a burst | none >200 ms after restore completes | any hit >200 ms (name the operation) |
| Persistence | QATEST- entity survives close + relaunch | yes | data loss |
| Second instance | coexists with first, same daemon, no corruption, no banner | yes | rejection, corruption, or second daemon |
| Daemon | survives every GUI exit | yes | daemon dies or restarts |

Known residuals (tracked, not FAILs unless they regress past the threshold):
- Fully restored UI ~4.0 s behind the loading frame (needs lazy transcript
  ownership/materialization — dedicated lane).
- Background durability handoff ~3.4 s post-hide even for no-edit sessions.
- Cross-scale monitor move (1.0x <-> 1.67x) can leave a partially rendered
  window until relaunch (P2).
