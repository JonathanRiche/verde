# Desktop chat turn timing and frame profiling

Two low-overhead diagnostics for "why did that feel slow" questions in the
native GUI. Neither adds per-frame or per-poll work: turn lines fire on
lifecycle transitions that already happen, and the frame profiler is off
unless its environment variable is set.

## Where the logs are

The GUI redirects its stderr to `~/.local/share/verde/Native/logs/verde.stderr.log`
at startup (`runtime_log.init`). The session daemon is spawned by the GUI
and inherits that stderr, so daemon `std.log` lines land in the same file.
A daemon started by hand (`verde-daemon serve`) logs to the terminal it was
started from instead.

## Chat turn phase lines (daemon)

Every daemon-run chat turn emits one `info(sessionizer): chat turn phase`
line per transition, keyed by `turn_id`:

| phase | when | extra fields |
| --- | --- | --- |
| `accepted` | turn object created after the request was validated | `provider`, `prompt_bytes`, `images` |
| `first_delta` | first streamed assistant text arrived | `since_accept_ms` |
| `answer_ready` | host published the visible answer early (Muse-style) | see below |
| `provider_done` | provider process returned a result | see below |
| `provider_drained` | provider returned after `answer_ready` already published | see below |
| `provider_failed` / `provider_aborted` | provider errored or the turn was cancelled | see below |
| `committed` | durable store commit acknowledged | `commit_ms`, `store_revision`, `title_applied` |

The "see below" phases carry `status`, `since_accept_ms`, `first_delta_ms`
(-1 when nothing streamed), `deltas`, `delta_bytes`, and `events`.

Reading a turn:

```
grep 'chat turn phase turn_id=<id>' ~/.local/share/verde/Native/logs/verde.stderr.log
```

- `first_delta_ms` is the provider start latency (bridge spawn plus model
  time to first token).
- `provider_done.since_accept_ms - first_delta_ms` is streaming time.
- `committed.commit_ms` is how long the durable write took after the
  provider finished; if the GUI shows "Waiting for streamed output..."
  well past `provider_done`, compare against the GUI's tail poll cadence
  rather than the daemon.

## Frame profile (GUI)

Launch the GUI with `VERDE_FRAME_PROFILE_LOG=1` in its environment. Once a
second it writes a `frame-profile` diagnostic line with sample count,
average and max frame time, slow/hitch counts, and per-section averages
(`render_root`, `draw_backend`, `poll_send`, `poll_terminals`,
`poll_config`). Independently of the flag, any frame whose active time
crosses the stall threshold logs
`SDL thread stall operation=frame slowest=<section> elapsed_ms=...`.

To chase a specific stall (for example a popover that seems to linger after
a selection):

1. Start the GUI with the variable set and reproduce the action once.
2. `grep -n 'frame-profile\|SDL thread stall' verde.stderr.log | tail`.
3. A `max_ms` spike or a stall line in the second of the action names the
   slow section; no spike means the delay is not a slow frame but a missing
   wake (nothing asked for a redraw), which is a pacing bug instead.

The profiler only samples timings; it does not change frame pacing.
