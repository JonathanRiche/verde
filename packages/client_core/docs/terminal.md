# K-12 terminal handles and session pump

`terminal.zig` wraps the exact desktop Ghostty pin. It has no network, file,
thread or clock effects. C exports and JNI methods cover new/write/resize/
scroll/snapshot/free; Kotlin declarations live in `Native`. Each handle needs
its own serialized executor. Freeing a VT never kills a daemon session.

Register wire models in `model_registry.zig`; `TerminalConfig`,
`TerminalSnapshot`, cells/cursor and `TerminalView`/`TerminalQuery` are generated
for both native clients. Snapshot colors are resolved RGB; renderers apply the
cell's inverse flag. Default colors already include reverse-video mode (do not
swap them twice). Snapshot replies are consumed only after C/JVM output
allocation succeeds. Submit them once as `terminal_reply`; never log them.

The host uses **session RPCs only**, per A-02. There is no `terminal.open`
fallback and no desktop-mirror dependency. `terminal_create` allocates a
nonce-scoped session ID and creates the daemon's default shell. A null cwd resolves from the workspace snapshot path; if unavailable, creation
fails visibly instead of using the daemon working directory. Creation does
not retry on uncertain delivery. Attach to a known session ID from the workspace
projection; attach always requests a fresh replay because the VT may have been
recreated. On reset, the adapter queries the terminal view for the current
cols/rows before recreating its VT. `terminal:<percent-encoded-session-id>` queries decode exactly once.
Terminal selectors are included in the coalesced `state_changed` notification.

`session.tail` has one outstanding request and one unacknowledged output per
terminal. Only `terminal_applied` advances its daemon byte offset. Initial and
truncated replays reset the emulator and use the web's `alignPtyStream` trimming
rules, with an extra UTF-8 boundary guard. The recorded daemon does not emit
`truncated`; a response `offset` beyond the requested offset or a regressed
`next_offset` also triggers reset. Offsets come from the daemon, never from the
trimmed text length. Polling waits 160 ms after output, 1 s when idle, and stops
in the background. Reconnection retains acknowledged offsets; an unacknowledged
batch forces reset/replay. Apply failure retries with reset after 1 s.

Input writes serialize per terminal, including device replies, so paste chunks
cannot race. Chunks are at most 4096 bytes and preserve UTF-8 boundaries.
Bracketed paste wraps the whole paste once. Cursor-key mode selects SS3/CSI;
Ctrl/Alt/Shift named keys use standard escape encodings. Remaining queued input
is discarded on a failed/uncertain write or transport invalidation. No ambiguous
input is automatically retried. Pending unsent resize requests coalesce.

Every keystroke is an intent, so terminal receipts rely on the host's rolling
receipt limit ([host-skeleton.md](host-skeleton.md)): settled (`succeeded`/
`failed`) receipts of every kind share one 256-entry window and evict oldest
first, while pending and uncertain input never leaves. IDs therefore
deduplicate only within that window. Platforms mint a fresh ID for every
keystroke and never resubmit input.

Limits: 32 host terminal records, 256 queued actions per terminal, 1 MiB total
queued text, 512 per grid dimension and 65,536 total cells, 10,000 configured
scrollback rows with a 16 MiB byte ceiling, and 64 KiB queued device replies.
Ghostty prunes history by whole pages, so the actual row count can exceed the
requested row limit by a page (zero disables history). A VT parser/allocation
failure or reply overflow poisons the VT: report apply failure, then recreate
on the next reset. Do not acknowledge a failed write. Snapshot allocation
failure leaves device replies queued. Upstream parser logs are suppressed at
the library root so escape payloads never reach platform logs.

Fixtures in `src/fixtures/terminal` come from `record.py` and the recorded binary
hash. The recorder uses a temporary HOME, config/state and private Unix socket;
it runs a synthetic shell with fixed output, kills its session and terminates
its owned daemon with finite deadlines. It never contacts the user daemon or
any network service. `terminal_test.zig` adds adversarial schedules and VT tests;
`tests/abi_smoke.c` calls all six terminal exports.
