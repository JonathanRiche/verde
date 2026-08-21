# Issue #86 Terminal Lifecycle Slice Implementation Plan

> **For Hermes:** Implement only after Jonathan approves this slice and its retention policy. Keep the scope separate from broad process-dashboard UI work.

**Goal:** Make the existing workspace process registry reliable for terminal/TUI commands by retaining a completed/cancelled result long enough for MCP waiters and UI consumers, and by immediately releasing leases owned by a terminal session when that session is definitively terminated.

**Architecture:** Preserve the current source-of-truth approach: do not add a second daemon-wide process database. Instead, extend the terminal/session lifecycle with a small, bounded terminal-command history owned by the project/dock, and have the existing `workspace.processes`, conflict, and wait paths serialize both active snapshots and recent terminal outcomes. Session teardown becomes the single place that releases leases for that exact owner/session ID.

**Tech Stack:** Zig 0.16; native desktop state in `packages/desktop/src`; Live CLI/MCP JSON-RPC; existing terminal dock/sessionizer lifecycle.

---

## Why this is the recommended first #86 slice

The foundation already exists:

- `workspace.processes`, `workspace.checkCommand`, `workspace.acquireLease`, and `workspace.releaseLease` are exposed by `packages/desktop/src/ipc/server.zig`.
- Lease ownership and expiry are implemented in `packages/desktop/src/state/workspace_controller.zig`.
- The process registry currently synthesizes terminal records in `writeTerminalWorkspaceProcess` from only `dock.activeRuntimeProcessSnapshot()` (`ipc/server.zig:1946`). Once a terminal command ends or a pane/session disappears, the record disappears; callers cannot distinguish a clean completion, cancellation, crash, or a missing process.
- Existing terminal records advertise `terminal.write Ctrl-C or close the pane` as cancellation (`ipc/server.zig:2008`), but a close must also conclusively terminate the owned session and clean up its owner leases.

This slice directly finishes two explicit #86 gaps without trying to solve every launch path or build a large dashboard at once:

1. retain terminal completion/failure/cancellation state for MCP waiters and process history;
2. clean up terminal-session leases immediately at known owner teardown.

## Product contract for the slice

### Retained terminal outcome

For a terminal command that was previously running, `workspace.processes` continues to return the same stable record identity after it exits, with:

- `status`: `completed`, `failed`, `cancelled`, or `crashed`;
- original workspace, dock/pane, owner/session ID, command, cwd, PID/process group, and start timestamp;
- `finished_at_ms`, exit code/signal where known, and a clear cancellation reason when Verde initiated it;
- no resource conflict contribution after completion;
- bounded retention so old history cannot grow indefinitely.

**Recommended default:** keep the latest 32 terminal outcomes per workspace for 15 minutes, pruning on state polling and terminal lifecycle activity. The exact capacity/TTL should be constants with tests, not exposed as speculative configuration.

### Owner lease cleanup

When a known terminal surface/session exits or is deliberately closed, release only leases whose `owner` exactly equals that terminal session ID. Do not release leases belonging to another pane, agent, MCP client, or arbitrary text prefix.

### Wait semantics

`workspace.wait_for_process` resolves a retained outcome rather than returning `gone` when the command has just completed. It should report the terminal outcome unchanged until retention expires. A process that never existed still returns `not_found`/`gone` according to the existing contract.

## Out of scope

- Automatically intercepting every GUI-agent/TUI/bang/hook/background/managed-process launch before execution.
- Full visual dashboard of every registry source.
- GUI buttons for Wait / Cancel existing / Run anyway / Open owner.
- Cross-restart durable history.
- Global process discovery outside Verde-owned terminal sessions.
- Changing existing CLI/MCP method names or mutating user commands.

---

## Implementation steps

### Task 1: Map the exact terminal lifecycle transition

**Objective:** Locate the one transition path where a terminal session moves from running to exited/closed, before changing state models.

**Files to inspect:**
- `packages/desktop/src/terminal/terminal.zig`
- `packages/desktop/src/state/workspace_controller.zig`
- `packages/desktop/src/state.zig`
- `packages/desktop/src/ipc/server.zig:1946-2012`

**Steps:**
1. Find the active session snapshot API used by `activeRuntimeProcessSnapshot()` and identify where it first observes `running=false` plus exit code/signal.
2. Find the path for pane close and provider terminal/TUI teardown.
3. Confirm that both paths have the stable session ID currently emitted as the terminal process owner.
4. Add a focused failing test around the selected lifecycle seam, before any data-model change.

**Acceptance:** One lifecycle hook owns recording terminal completion and owner-lease cleanup; no polling-only heuristic is used to infer a close.

### Task 2: Add bounded terminal outcome history

**Objective:** Store final terminal outcomes at the project/dock layer without introducing a duplicate live process registry.

**Likely files:**
- Modify: `packages/desktop/src/terminal/terminal.zig`
- Modify: `packages/desktop/src/state/project.zig` or the project terminal-dock state owner discovered in Task 1
- Modify: `packages/desktop/src/state/workspace_controller.zig`
- Test: inline Zig tests beside the owning state type

**Steps:**
1. Define an owned `TerminalProcessOutcome` model containing the stable session/process identity, command/cwd snapshot, timestamps, terminal exit classification, exit code/signal, owner ID, and dock/pane metadata needed by the existing JSON schema.
2. On a running → non-running transition, snapshot the final fields exactly once. Do not overwrite a known final result on later polls.
3. On explicit cancellation/close, classify as `cancelled` only when Verde actually initiated termination; otherwise preserve the runtime-reported clean/crashed result.
4. Bound entries by both TTL and maximum count; deinitialize owned strings correctly.
5. Add unit tests for clean exit, non-zero exit, signal/cancel path, duplicate polls, expiry, and maximum-entry eviction.

**Acceptance:** A completed terminal command remains inspectable and does not leave a running process record or a permanent memory leak.

### Task 3: Release terminal-owned leases at definitive teardown

**Objective:** Eliminate lease waits after a known terminal owner goes away.

**Likely files:**
- Modify: `packages/desktop/src/state/workspace_controller.zig`
- Modify: `packages/desktop/src/state.zig`
- Test: existing workspace lease tests in `packages/desktop/src/state.zig:8386+`, expanded for session-owned teardown

**Steps:**
1. Add a narrow helper that releases all workspace leases for an exact owner/session ID, reusing existing lease deinitialization rather than duplicating it.
2. Call it only from the confirmed terminal session exit/close lifecycle hook identified in Task 1.
3. Do not release by command, provider, dock ID, prefix, or workspace-wide wildcard.
4. Add tests with two different owner IDs proving teardown of owner A releases only A’s lease and leaves B’s conflict in place.
5. Verify ordinary TTL expiry and explicit `workspace.releaseLease` behavior stay unchanged.

**Acceptance:** A terminal session close immediately unblocks its own `build`, `deps`, port, or custom resource leases while preserving all other owners.

### Task 4: Expose retained outcomes through current MCP/CLI surfaces

**Objective:** Make the existing process-listing and wait operations useful after terminal completion without adding another command family.

**Likely files:**
- Modify: `packages/desktop/src/ipc/server.zig:1915-2012` and the existing wait handler
- Modify only if schema/capability text changes: `packages/desktop/src/cli/spec.zig`, `packages/desktop/src/cli/main.zig`, `packages/desktop/src/cli/completion.zig`
- Test: inline IPC tests in `packages/desktop/src/ipc/server.zig`

**Steps:**
1. Extend `writeWorkspaceProcessesArray` to append recent terminal outcomes alongside active terminal snapshots, never duplicating the same session while it is active.
2. Make the existing wait path return a retained terminal outcome instead of `gone`.
3. Ensure check-command ignores final outcomes as conflicts.
4. Keep field names and existing active-process JSON unchanged; add only documented final-state fields.
5. Add IPC tests for active → completed, cancelled, process wait after completion, and no conflict from a final record.

**Acceptance:** `workspace.processes` and the equivalent Live CLI output show final terminal result data; `wait_for_process` is deterministic immediately after exit.

### Task 5: Runtime smoke and regression validation

**Objective:** Verify the actual desktop app, not just synthetic state.

**Files:** no product file required unless a failing check exposes a defect.

**Steps:**
1. Run the narrowest new Zig tests first.
2. Run `zig ast-check` on each modified Zig file and `git diff --check`.
3. Acquire a `build` lease only immediately before the required `mise run build`; release it on success/failure.
4. Run `mise run build` from the repository root.
5. From an external shell, relaunch/attach to the development app only if necessary and explicitly authorized. Create one owned disposable terminal command that exits with a known code.
6. Query `workspace.processes`/Live CLI before and after exit; verify the same record transitions to a retained final result.
7. Acquire a short owner-scoped lease from that owned terminal session (or deterministic test harness), terminate the session, and verify the lease disappears immediately while an unrelated lease remains.
8. Close only the disposable test pane/process and verify cleanup. Keep the main Verde app running if requested.

**Expected validation:** focused unit/IPC tests pass, `mise run build` passes, and the live process registry retains a completed terminal result long enough for `wait_for_process` to resolve it.

---

## Risks and decisions before implementation

1. **Retention policy:** recommended 32 records / 15 minutes / memory-only. Confirm this default or choose a different limit.
2. **Cancellation truthfulness:** a closed terminal pane may destroy the shell and provider process at different times; status must be recorded only after the terminal runtime confirms the result.
3. **No cross-owner cleanup:** cleanup must key on the exact session ID; broad process-name cleanup would be unsafe.
4. **Pane close behavior:** the recent disposable Grok smoke showed pane removal alone is not sufficient evidence that the underlying provider/TUI process has exited. This slice must make the lifecycle and registry agree before claiming cleanup.
5. **Testing environment:** use a harmless disposable `/bin/sh -lc 'exit <code>'` or equivalent owned terminal command, never a user pane or shared background task.

## Suggested commit boundary

One coherent commit after all focused tests, build, and live smoke pass:

`feat(desktop): retain terminal command outcomes`

Do not include the untracked coordinator roadmap in the commit.
