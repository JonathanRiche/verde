# Agent acceptance QA

Automated "real user" regression testing: a CLI coding agent (codex) drives the
actual Verde GUI and headless surfaces on the live machine — launching windows,
sending keyboard input, taking screenshots, timing everything — then writes a
PASS/FAIL report. This replaces manual re-testing of already-working areas.

Born from the issue #116 field-QA campaign (7 rounds, reports archived in the
orchestration hub). The charter + safety rules here are the distilled,
battle-tested versions.

## Run a suite

```sh
qa/agent-acceptance/run.sh smoke        # ~5 min: CLI, MCP, launch, banner, one close
qa/agent-acceptance/run.sh switching    # sustained Alt+number burst + stall markers
qa/agent-acceptance/run.sh close        # close semantics, focused/unfocused, handoff timing
qa/agent-acceptance/run.sh persistence  # restore, second instance, headless->GUI visibility
qa/agent-acceptance/run.sh full         # everything (the classic T1-T8)
```

Reports land in `/tmp/verde-qa/<timestamp>-<suite>/report.md` (override with
`QA_OUT_DIR`). By default the agent runs visibly in a herdr pane so you can
watch; set `QA_NO_HERDR=1` to run it inline in your terminal.

Requirements: codex CLI, Hyprland (`hyprctl`), `grim`, `jq`, `ydotool`
(NOT wtype — it inserts literal characters). The display must be on. Your
terminal should be on Hyprland workspace 1; the agent tests on workspace 2.

## Ground rules baked into the charter

- The live sessionizer daemon (`verde __session-daemon` on the real XDG data
  dir) is NEVER killed or restarted. Destructive daemon tests are out of scope.
- Only entities prefixed `QATEST-` are created/modified; everything else in
  the user's real data is read-only.
- Every GUI the agent spawns is closed before it finishes (escalating to
  exact-PID kill only after a grace period, and reporting that as a finding).
  The report must end with process-list proof.
- No builds, no git mutations, no repo edits. The binary under test is
  whatever `zig-out/bin/verde` currently is — the report pins HEAD + binary
  mtime so results are attributable.

## Keeping it useful

`expectations.md` is the living baseline. When a perf fix or acceptance round
establishes new numbers, update it in the same PR — the next run regression-
checks against it. If a run FAILs, the report's stall markers
(`SDL thread stall operation=... elapsed_ms=...` in
`~/.local/share/verde/Native/logs/verde.stderr.log`) name the guilty
operation.
