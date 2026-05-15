# Windows Port — Status

One row per phase. Update at the end of each session. Phases are
defined in [`roadmap.md`](roadmap.md).

Status values: `not started` · `in progress` · `blocked` · `done`.

## Phase Tracker

| # | Phase | Status | Sessions | Open Questions |
|---|---|---|---|---|
| 1 | Build orchestration + minimum compile | not started | — | — |
| 2 | SDL3 + Palette runtime smoke | not started | — | — |
| 3 | Process spawning + provider CLIs | not started | — | — |
| 4 | ConPTY glue for libghostty-vt | not started | — | — |
| 5 | CEF on Windows | not started | — | — |
| 6 | fff (Rust) on Windows MSVC | not started | — | — |
| 7a | Zip packaging + CI | not started | — | — |
| 7b | MSI packaging | not started | — | — |

## Session Log

Format: `YYYY-MM-DD · Phase N · short summary · branch/commit`.

(no sessions logged yet)

## Open Questions Backlog

Questions raised during a phase that didn't block forward progress
but need an answer eventually. When answered, move into the
relevant phase's session notes and strike here.

(none yet)

## Decision Log

Architecture choices made during the port that future sessions need
to honor. Don't relitigate without updating this list.

- **2026-05-15 · ABI:** Default Windows target is
  `x86_64-windows-msvc`. MinGW is not supported. Rationale: CEF
  ships MSVC, libghostty-vt upstream embedders are MSVC + CMake,
  ConPTY work is easier in MSVC + WinDbg territory.
- **2026-05-15 · Build host:** Native Windows 11 only.
  Cross-compile from Linux/macOS is a non-goal. CI uses GitHub
  Actions `windows-latest` (also native, not cross-compile).
- **2026-05-15 · Phase order:** Deviated from initial guess —
  zig_objc isolation folded into Phase 1 (already lazy + gated
  upstream); SDL3+Palette runs before CEF; fff/Rust split into its
  own Phase 6; packaging split into 7a (zip+CI) and 7b (MSI).
