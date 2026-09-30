# Android parity audit (September 28, 2026)

Branch: `mobile/ios-parity`, based on `mobile/android-steer-delivery` at
`81d828e7`. This branch must travel with its Android/shared-core ancestors;
it does not replace or rewrite the Android branch.

| Android change | iOS disposition |
| --- | --- |
| `81d828e7` bounded network C ABI envelopes | Inherited core; `NativeHostCore` already calls `vc_host_handle` with the full Data length. Added a linked Swift/native regression for >1 MiB HTTP and WebSocket envelopes. HTTP byte caps and WebSocket maximumMessageSize remain effect-controlled. |
| `9e551a4c` parked HTTP deadlines | Already in `SessionTransport` (`6f081e58`, `ed865ae1`): per-request timeout plus an independent total deadline; the shared session has a long resource lifetime. Added a pooled 120-second request regression. |
| `e746d286` safe failure diagnostics | Added opt-in `CoreDiagnostics`: native event byte count, elapsed native time, numeric status and fixed error categories only. |
| `b1549d80` delivered steer card | Ported in `Composer`: hide only sent_inline + accepted. Uncertain delivery and queued-next-turn remain visible. |
| `1d4a811c`, `0425b9b0`, `38ec19e3` Git | Extended `a2e1eb02` with operation receipts, route-arrival/reconnect status refresh, running-turn fallback and mine-only initial selection. Existing core owns retained exact-request retries; the UI never constructs another commit for uncertain delivery. Existing Push/ahead label, generated new branch, main confirmation, rejected-push recovery and quiet system/git notice remain. |
| `3353ecf4` transient TLS probe failure | Ported transport error into EventTlsPeer; network failures use shared-core retry while real certificate failures remain TLS failures. |
| `abcb1651` streaming/input latency | Inherited narrowed core invalidations. Transcript decoding/grouping moved off main actor, one decode at a time with latest-only publication. Markdown completes its current parse before consuming the latest requested text. No measured iPhone speedup claimed. |
| `3445b636` machine cards/nicknames | Added local persistent nickname, ellipsis actions, failure-safe selection and save. Renaming preserves the core session and pairing. |
| `e0e8a29a` terminal composing input | Ported immediate composition deltas, common-prefix correction and no duplicate commit/unmark. Remote grid owns the echo. |
| `4fda5580` socket audit | Existing `ed865ae1` separates the socket lifetime from the connection deadline; existing empty-close test covers 1005. Added opt-in open/close age/code metadata. No new socket policy. Physical long-lived connection check remains pending. |
| `b0b19ee1` terminal backlog | Inherited direct arena state copies and scoped core invalidation. Swift already queries only state_changed.scopes in CoreHost; added regression that terminal-only changes never query chat/workspace views. |
| `b4532261` header actions | Already present in `68d7d6ac` / `78f67540`: ChatActionsMenu in ManageScreens and transcript shell, Rename/Sync/Close with permissions and confirmation. |
| Recent chats/timestamps | Already `f718fd0e` (live workspace catalog) plus inherited `d0bfd4c6` timestamp normalization. |
| Composer layout, resizing, instant settings | Already `87d9d41f`; actual-value/default picker labels in `47542bc7`, inherited host-setting reconciliation `7489d236`. |
| Images and externally started turns | Inherited shared-core `ecacb80f` and `b79db2e4`; no separate platform protocol implementation. |

## Diagnostics

Off by default. For a local diagnostic launch, add Xcode launch arguments
`-verde.connectionDiagnostics YES`; remove the arguments afterward. Read only
subsystem `dev.verdeai.app`, category `connection`. These records contain no
URLs, host/chat identifiers, terminal input, payloads, token values, error
messages, diffs or commit contents. They do not log the core's arbitrary log
effect. Diagnostics do not change retry behavior.

## Verification boundary

Run the standard Mac `mobile-ios-build` and `mobile-ios-test` tasks from an
isolated Git checkout at the pushed branch SHA. They rebuild the xcframework
and create/delete a test simulator. Tests use synthetic fixtures only.

The physical iPhone was listed by `devicectl` as unavailable during this pass.
No installation, signing changes, background/resume, steering, large live chat,
terminal latency measurement or live Git commit was performed. Those checks
require the phone to be reachable. Git device checks additionally require the
new daemon protocol to be running and must use a scratch repository, never a
real remote. No daemon restart is performed by this branch.

Final code verification: `c0bdf552`, Mac build passed and **139 tests passed**.
No client_core or generated-model source was changed in this port, so no new
Linux core or Android test run was required. The inherited core was rebuilt for
both iOS slices by the Mac task and exercised through the linked ABI test.
