# Verde orchestration roadmap

**Coordinator:** Volt (Jonathan Riche's delegated coordinator)  
**Repository:** `JonathanRiche/verde`  
**Scope:** `/home/rtg/development/verde`  
**Live workspace:** `baaa819e66d8f3be` (`verde`)

This is the coordinator-owned execution reference for work requested in this workspace. It links GitHub issues to active lanes, verification, and next actions. Agents may read it, but must report factual progress to the coordinator rather than changing status or sequencing themselves.

## Operating rules

- Preserve unrelated work in the shared worktree; do not overwrite or revert another lane's changes.
- One active implementation owner per overlapping module. In particular, do not concurrently assign work that touches the same `state.zig`/desktop integration path.
- Before starting a shared build, dev server, browser, dependency change, or other long-lived process: inspect tracked work, check conflicts, acquire the matching resource lease, clean up owned resources, and report the outcome.
- A build passing is not runtime UI proof. Native/UI changes need a real-app visual check when it is safe and explicitly authorized.
- Verde normally runs on this machine in the Hyprland/Omarchy workspace **3**. Use the Verde MCP/live development CLI for **all Verde control**; target its stable workspace ID rather than desktop focus or virtual-workspace switching.
- Computer Use is evidence-only for this project, never a Verde-control fallback: use it only when pixel-level desktop/compositor proof is needed and MCP cannot provide it (for example native-window rendering, OS dialogs, or non-browser UI). Use Verde MCP browser screenshots/inspection for embedded-browser proof first.
- Commits, pushes, deployments, pane closure, and GitHub mutations require separate explicit authorization unless Jonathan requests them.

## Current live state

| Lane | GitHub issue | Owner / pane | State | Evidence / gate |
|---|---|---:|---|---|
| Grok TUI activity integration and reported ACTIVE/pip regression | [#92](https://github.com/JonathanRiche/verde/issues/92) | Codex GUI chat, pane `677` | **Committed; session open for follow-up** | Commit `84a8fed8` landed the source integration. Jonathan confirmed the ACTIVE/pip/pane path after enabling the disabled user-scoped Grok hook. |
| Independent product/code review of the Grok WIP | [#92](https://github.com/JonathanRiche/verde/issues/92) | Grok TUI, historical pane `686` | **Completed; pane closed** | The review recommended a focused Grok-hooks landing, then clear ownership seams for further state work. |
| Independent implementation review / process dashboard slice | Related: [#86](https://github.com/JonathanRiche/verde/issues/86), [#111](https://github.com/JonathanRiche/verde/issues/111) | Amp TUI, pane `606` | **Completed review; pane remains open** | Reported focused validation/build results. It explicitly excluded runtime relaunch validation and a dedicated workspace process dashboard. |

## Immediate queue

1. **#92 — Grok TUI activity visibility.**
   - Status: **implemented and committed** in `84a8fed8`.
   - Follow-up only: keep pane `677` for small verified regressions; no additional overlapping implementation lane.
   - Evidence: focused hook tests and `mise run build` were reported; Jonathan confirmed the live ACTIVE/pip/pane visibility after the user-scoped hook was enabled.

2. **#111 — pane-targeted terminal submit/key action.**
   - Status: **completed and closed** — commit `aefd6104` (`feat: add pane-targeted terminal key actions`); GitHub issue closed with validation comment.
   - Evidence: focused routing/protocol tests, formatting/AST/diff checks, and `mise run build`; a post-relaunch Grok TUI smoke proved compose → pane-targeted Enter → `user_prompt_submit` → expected response.
   - Compatibility: restored the original raw/restart-on-write `terminal.write` contract; discrete key submission remains exclusively on the new key/submit APIs.

3. **#86 — workspace command coordination: terminal lifecycle slice.**
   - Status: **completed and pushed** — corrective commit `bef7b877` (`fix(desktop): preserve terminal lifecycle outcomes`) is on `origin/master`. The broader dashboard/coordination scope remains open.
   - Evidence: independent read-only pane `692` approved the fixed diff; focused lifecycle regressions, formatting/AST/diff checks, and `mise run build` passed. After an authorized relaunch, an owned ordinary terminal ran `sleep 2; exit 7`: the same ID was observed `running`, then retained as `failed` with exit code `7`; public `wait_for_process` returned that retained result. The terminal owner lease was automatically removed after confirmed exit, while an unrelated lease remained until explicitly released.
   - Scope: bounded terminal completion/cancellation history, exact session-owner lease cleanup, existing process/wait serialization, and focused tests. This slice does not expand into the dashboard, global launch interception, or cross-restart persistence.
   - Acceptance delivered: retain up to 32 outcomes per workspace for 15 minutes, make retained outcomes non-conflicting and waitable, release only exact *confirmed-terminated* session-owner leases across teardown routes, and validate through review, focused checks, build, and the owned live terminal smoke.

4. **#106 — continue the `state.zig` refactor only through owned seams.**
   - Status: **sequenced / no current dispatch.**
   - Constraint: coordinate around #92 and any active provider/terminal integration changes; do not mechanically split or create competing owners of state/lifecycle modules.
   - Candidate next seams from review: lifecycle, persistence, or surface ownership, followed by a targeted multi-workspace/browser/pane/provider/IPC smoke pass.

4. **#112 — non-destructive workspace instruction bootstrap.**
   - Status: **backlog / planning-ready.**
   - Constraint: it must not overwrite existing `AGENTS.md`/`CLAUDE.md`; companion guidance must be demonstrably delivered to Verde-managed agents.

## Related backlog (not active)

- [#86](https://github.com/JonathanRiche/verde/issues/86) — workspace command coordination.
- [#100](https://github.com/JonathanRiche/verde/issues/100) — scheduled agent/chat runs.
- [#78](https://github.com/JonathanRiche/verde/issues/78) — end-to-end GUI chat provider test suite.
- [#90](https://github.com/JonathanRiche/verde/issues/90) — cross-provider chat handoffs.

## Coordination handoff format

Every implementation result must state: exact files changed, exclusive ownership boundary, focused tests/checks run and their result, full-build result when required, runtime/UI evidence if applicable, remaining risk, and whether any commit/push/deploy/approval is needed. The coordinator updates this roadmap after independently checking the result.
