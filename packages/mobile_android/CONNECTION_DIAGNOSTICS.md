# Android connection investigation

Android uses OkHttp 4.12.0. Its WebSocket upgrade path calls
`Exchange.newWebSocketStreams() -> RealCall.timeoutEarlyExit()`; the connection
also clears the socket read timeout. The 30-second call timeout in
`EffectExecutor.websocket` therefore bounds establishment, not the upgraded
socket lifetime. Do not copy the iOS URLSession resource-lifetime fix to Android
without evidence.

The regression test
`upgradedWebsocketOutlivesThirtySecondCallTimeoutAndStillClosesLocally` uses the
production transport settings, leaves an upgraded TLS loopback socket idle for
35 seconds, exchanges a message, and verifies a local close. Existing tests
cover pin mismatch, trust changes, the empty-close-frame sentinel 1005, and
WebSocket protocol/transport behavior.

## Opt-in metadata trace

Record the current property before enabling and restore it afterwards:

```sh
adb shell getprop log.tag.VerdeConnection
adb shell setprop log.tag.VerdeConnection INFO
adb logcat -v monotonic -s VerdeConnection:I '*:S'
```

Setting the property to an empty value disables the trace when that was its
original value. Never clear the whole logcat buffer for this investigation.

The trace includes only:

- Process-local socket sequence, fixed event kind, age, received-message count,
  numeric close code and an allowlisted transport failure enum.
- Foreground state, network availability and whether the route changed.
- Ready/synced/refreshing/cached/busy-banner booleans.

It excludes host/thread identifiers, URLs, tokens, protocol headers, close
reasons, exception text, pair codes and all message content. Traffic metadata is
sampled at most once per ten seconds per socket. Raw core log effects remain
disabled. The trace is diagnostic only; it changes no timeouts or reconnect
policy.

## Findings from the owner's Pixel 9

After installing the diagnostic build, one socket remained open for 193.9
seconds with 51 incoming messages. There were no unsolicited closures during
that interval. Foreground UI inspection found no Connecting, Updating or
Loading workspaces message after initial synchronization.

A deliberate background action produced a local code-1000 close. Resuming
opened a new socket and returned to ready/synced without a busy banner.
Daemon and gateway processes had more than four hours of uptime; neither was
restarted or changed for this investigation.

These observations establish current stability and rule out applying
Android's 30-second call timeout to an already-upgraded socket. They do **not**
identify the owner's earlier intermittent Android cause, prove it is fixed,
or attribute Android's recovery to the separate iOS fix.

If the issue recurs, correlate:

1. `LocalClose` with foreground or route changes (or core auth renewal).
2. `PeerClose` / `Failure` with the close code and classified error.
3. Busy-banner transitions without a socket close (cached data or loading UI).
4. Simultaneous failures on other clients, which may implicate shared gateway
   or network conditions even when server uptime is unchanged.

The existing intermittent
`TranscriptTest.offlineFocusIsRetriedOnceWhenTheHostBecomesReady` timeout is a
separate unresolved test issue; do not equate its occurrence with a device
WebSocket failure.

## Terminal latency

The terminal previously retained IME composing text until commit/finish. A
keyboard can keep a word composing indefinitely, so characters never reached
the core during that interval. `TerminalInputTest` now checks immediate
incremental delivery, replacement/deletion by Unicode code point, and no replay
on commit or finish. This proves removal of that buffering path; it does not
establish that every reported delay came from the keyboard.

With `VerdeConnection` enabled **before opening the host**, the trace also
records `terminal_stage` and `elapsed_ms` for input dispatch, VT output apply,
and HTTP `session.write`/`session.tail` completion (including failures). It
contains no terminal/session identifiers, commands, response bodies, or URLs.
HTTP timing spans enqueue through response consumption; it is not a pure
network RTT. Input dispatch excludes time waiting for the core executor.
No per-request timing is emitted when the trace is disabled at host creation.

Compare these durations while typing to distinguish keyboard buffering, core
processing, transport/host latency, and local VT rendering. A short write time
alone does not prove fast visible echo: the subsequent tail and VT apply also
have to complete. Do not label the owner's end-to-end latency fixed without a
fresh device observation.

### Terminal processing bottleneck confirmed on the device

The owner's trace showed terminal writes/tails mostly around 15–40 ms while
input dispatch took 400–600 ms. The terminal was waiting for local core work,
not a similarly long HTTP round trip. The IME composition fix did not resolve
this measured backlog.

Two costs were identified:

- Every transaction copied the entire retained state through JSON twice. State
  now uses direct deep copies into separate arenas; it still commits only after
  successful output encoding, retains no event/effect arena, and rolls back on
  allocation failure.
- Terminal state/receipt changes invalidated every cached chat, workspace,
  attention and management view. They now invalidate terminal/operation views
  without rebuilding unrelated projections. Host data and relevant chat/send
  changes still propagate; focused clocks and leaving a terminal refresh views.

`InputHandle` measures native event handling, while `InputDispatch` also includes
projection reads and effect delivery. In a controlled typing burst after only
the first optimization, native handling had a 17 ms median, HTTP writes 21 ms,
and full dispatch 225 ms. This isolated the remaining projection cost. These
are processing-stage durations, not direct key-to-screen latency measurements.

After both optimizations, the same 28-key device burst had a 28 ms median full
input dispatch (20 ms native handling), versus 225 ms after the copy change
alone. Its first-to-last input-dispatch span fell from 15,773 ms to 1,740 ms.
HTTP writes remained about 22 ms median; VT apply/resumption was 32 ms median.
This is a controlled throughput comparison, not a claim of measured display
latency or SSH-equivalent streaming. Both temporary shells were explicitly
exited. No daemon or gateway restart was involved.

### Chat input and streaming projections

When enabled before opening the host, the opt-in trace also records `core_event`, `handle_ms`, `publish_ms`, and query
counts. `query_kind`, `native_ms`, `decode_ms`, and byte counts separate projection
encoding from platform JSON parsing. Labels are fixed categories: no selector,
thread identifier, message body, or request content is emitted. These timings
exclude executor queueing and display latency.

On the same long chat on the owner's phone, an unsent fixture draft took
26 ms handling + 209 ms publication (7 queries) before narrowing invalidation,
and 39 ms + 31 ms (3 queries) afterward. The fixture was removed without sending.
This is a single controlled processing comparison, not a measured end-to-end
send latency or frame-rate claim. Active chat HTTP updates after the change
published in roughly 19–33 ms in the observed sample, versus 197–227 ms before.

Drafts and transcript deltas now invalidate changed chats without re-projecting
unrelated retained chats or browse catalogs. Host, catalog, connectivity, and
send-receipt changes still refresh their dependent views. Android decodes
transcript models off the UI thread, avoids JSON stringify/decode round trips,
and conflates pending markdown updates while allowing the current parse to
finish. A Compose regression exercises a blocked parse followed by multiple
stream updates, checking completion and the final displayed text. The existing
send regression checks the local prompt overlay before any server response.

### Recovery after a failed TLS preflight

Android previously converted every TLS-probe exception into
`system_trusted=false`, including connection refusal, DNS failure, and timeout.
The core interpreted that as a non-retryable certificate rejection and kept
`auth.blocked` in memory across foreground/network changes. Recreating the host
cleared it, explaining one concrete path where restarting the app was necessary.

The probe now reports a typed, content-free transport failure separately from
its trust result. The core backs off and repeats network/timeout failures;
certificate failures still block, and no credential request precedes successful
TLS validation and pinned discovery. Regressions cover paired-session resume,
network/timeout retry, and certificate rejection. This establishes the defect,
not that it caused every reported loop: the observed phone resumed successfully
before the fix, and no trace of the owner's original stuck session was captured.

The updated APK was installed on the connected phone. After about 62 seconds
in the background, the same process reopened its socket and reached ready +
synced about 1.3 seconds after foregrounding. No daemon/gateway restart or test
prompt was needed. This validates normal resume; the transient-failure recovery
is validated with isolated fixtures rather than by interrupting the owner's VPN.
