# Verde CPU investigation

Continuation of the workspace's **Profile Verde CPU Usage** thread, 2026-09-05.

## Current baseline

Sampled existing processes through `/proc/<pid>/stat` for 15 seconds,
14:17:27–14:17:42 UTC. CPU percentages use one logical CPU as 100%.

| Process | Average CPU | One-second range |
| --- | ---: | ---: |
| `verde-daemon` | 60.5% | 58–64% |
| `verde-gui` | 16.5% | 15–19% |

Read-only receipt inspection found **15 `state.snapshot.replace` requests**
in that window. The GUI log showed corresponding batches of **1,016 journal
entries**, classified `skip_self_echo`. The repeated writes remain expensive
even though the cursor now skips rebuilding its own echoed projection.
Other agent work and a compiler were active: this is an observed workload,
not an isolated before/after benchmark. Raw samples are in
`/tmp/verde-cpu-takeover-baseline.json` for this machine/session.

## Follow-up changes

- Sidebar notices wake the render loop without marking persistent state dirty.
- Timeline batches append projected messages without an implicit global dirty
  mark. The batch's `persist_projection` flag controls persistence, including
  partial local batches on failure. Existing unrelated local dirtiness survives
  daemon projection updates. Locally synthesized background-task completion
  rows retain their existing persistence path.
- Flush scheduling/acknowledgement diagnostics record generation numbers and
  the latest global `markDirty` caller address, without message contents.
  Caller capture is allocation-free; logging happens at flush boundaries.

These changes close confirmed redundant-save paths. They do **not yet prove**
the cause of the steady once-per-second loop or its removal in a running GUI.

The focused ReleaseSafe/LLVM run passed all 16 tests (the new projection
regression plus lifecycle coverage). It used a temporary filtered build wrapper
around the existing desktop test artifact, removed after execution. The new
test covers message identity, both image attachment slots, and retention of
unrelated local dirtiness. Lifecycle tests include stale acknowledgements,
selection/workspace dirtiness, and failure/spool handling.

The shared workspace's `mise run dev-build` completed with exit code 0 at
14:36:02 UTC. The installed GUI contains both the new projected-message helper
and flush diagnostics. Reused that completed verification rather than starting
another overlapping build. Formatting/diff checks passed; owned temporary
files, test processes, and leases were cleaned up. No live restart was performed.

## Next live verification

After the user relaunches the rebuilt GUI, inspect
`~/.local/share/verde/Native/logs/verde.stderr.log` for
`persistence flush scheduled` and `persistence flush acknowledged`.
An acknowledgement with `dirty=true` records the newer generation and caller
that kept it dirty. Resolve the address against the exact running executable;
for the current Linux non-PIE build:

```sh
addr2line -f -i -e /proc/GUI_PID/exe CALLER_ADDRESS
```

The recorded address is a return address; subtract one byte when it resolves
to the instruction after a source boundary. If the executable changes to PIE,
account for its load bias first. Re-sample CPU and receipt counts during an
active turn and again when idle. Do not restart either process from a
Verde-hosted session.
