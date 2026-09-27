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
