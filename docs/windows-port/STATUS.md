# Windows Port — Status

One row per phase. Update at the end of each session. Phases are
defined in [`roadmap.md`](roadmap.md).

Status values: `not started` · `in progress` · `blocked` · `done`.

## Phase Tracker

| # | Phase | Status | Sessions | Open Questions |
|---|---|---|---|---|
| 1 | Build orchestration + minimum compile | in progress (pending Windows verify) | 1 | Does `zig build -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true` finish on a real Windows 11 dev host? |
| 2 | SDL3 + Palette runtime smoke | not started | — | — |
| 3 | Process spawning + provider CLIs | not started | — | — |
| 4 | ConPTY glue for libghostty-vt | not started | — | — |
| 5 | CEF on Windows | not started | — | — |
| 6 | fff (Rust) on Windows MSVC | not started | — | — |
| 7a | Zip packaging + CI | not started | — | — |
| 7b | MSI packaging | not started | — | — |

## Session Log

Format: `YYYY-MM-DD · Phase N · short summary · branch/commit`.

- **2026-05-15 · Phase 1 · scaffold + Windows compile fixes · `claude/setup-verde-project-jtVuM`**
  - Added `mise.toml` tasks `setup-windows`, `build-windows`, `dev-windows`
    (all `shell = "pwsh"`); existing Linux/macOS tasks untouched.
  - Added `scripts/windows/{check-build-deps,setup,build,dev}.ps1`.
    `setup.ps1` is a stub for Phase 1 (validates the toolchain + creates
    the local CEF cache dir). Phase 2 fills in the SDL3 download.
  - `packages/desktop/build.zig`: `.windows =>` arm now optionally
    installs SDL3.dll alongside the exe when `-Dsdl3-runtime-lib=<path>`
    is supplied. CEF helper build + runtime install paths remain gated
    by `cef_supported` (Linux/macOS only) so `-Dcef-stub-preview=true`
    is a clean Windows path with no CEF SDK on disk.
  - `process_env.zig`: switched the POSIX-only `std.c.environ`,
    `std.c.getenv("HOME")`, and `std.c.access` calls onto comptime
    branches; Windows uses `std.process.Environ.block = .global`,
    `USERPROFILE`, and `std.Io.Dir.cwd().access`. `SYSTEM_PATH_DIRS`/
    `HOME_PATH_SUFFIXES` are empty on Windows (Phase 3 fills them).
    `isQualifiedExecutablePath` now also recognizes drive-letter paths.
  - `runtime_log.zig`: replaced `std.c.clock_gettime`/`timespec` with
    `std.time.milliTimestamp`. Existing `.windows => {}` arm on the
    `dup2` stderr-redirect path is unchanged (Phase 3 wires
    `SetStdHandle`).
  - `state.zig`: replaced `std.c.getenv("HOME")` at `resolveProjectPath`
    and the "current working dir for new project" fallback with
    `std.process.getEnvVarOwned` keyed on `USERPROFILE` (Windows) or
    `HOME` (POSIX). Same for `VERDE_OPEN_BROWSER_ON_START`.
    `unixTimestampMs` switched to `std.time.milliTimestamp`.
  - `utils.zig`: documented that the `verde_macos_clipboard_copy_image`
    extern is reached only from the comptime `.macos` arm of
    `captureClipboardImage`, so lazy analysis should keep it out of
    Windows builds. `pickDirectory`, `launchConfiguredEditorInTerminal`,
    `canLaunchConfiguredEditorTerminal`, `captureClipboardImage`,
    `captureClipboardText` were already gated with
    `else => error.UnsupportedOperatingSystem` / `else => null` /
    `else => false`; no further changes.
  - `profiler.zig`, `ui/sidebar.zig`, `ui/chat_panel.zig`: same
    `clock_gettime` → `std.time.{nano,milli}Timestamp` swap. Not
    enumerated in the roadmap but needed for Windows compile.
  - **Not verified on Windows.** This session ran in a Linux container
    without a Zig 0.16.0 install and without outbound access to
    `ziglang.org`, so `zig build -Dtarget=x86_64-windows-msvc
    -Dcef-stub-preview=true` has not been executed. The work is staged
    on the branch for the next Windows-host session to verify; any
    compile errors that surface get fixed before Phase 1 is marked
    `done`.

## Open Questions Backlog

Questions raised during a phase that didn't block forward progress
but need an answer eventually. When answered, move into the
relevant phase's session notes and strike here.

- **Phase 1 verify.** Run `mise run build-windows` (or `zig build
  -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true`) on a real
  Windows 11 dev box. Expected outcome: `zig-out\bin\verde.exe`
  produced; runtime may fail without SDL3.dll (that's Phase 2).
- **Lazy-analysis assumption for `extern fn
  verde_macos_clipboard_copy_image` in `utils.zig`.** Top-level extern
  only referenced from the comptime `.macos` arm of
  `captureClipboardImage`. Expected to be DCE'd on Windows. If the
  verify pass shows a linker error pulling this symbol, wrap the decl
  in a comptime block keyed on `builtin.os.tag == .macos`.
- **`terminal.zig` `TERMINAL_WINSIZE_IOCTL`.** Top-level const whose
  `else =>` arm hits `std.c.T.IOCSWINSZ` (POSIX-only). Only referenced
  from `UnixSession`, which is not selected when `Session =
  UnsupportedSession` on Windows, so lazy analysis should skip it. If
  the Windows verify complains, replace with a comptime switch whose
  `.windows => 0` arm short-circuits.
- **`std.c.getenv` in `utils.zig::preferredEditorEnv`,
  `utils.zig::preferredLinuxTerminalLauncher`,
  `utils.zig::macApplicationExists`.** Call sites sit behind
  Linux/macOS-only switch arms but the references are at module scope.
  msvcrt does ship `getenv`, so compile is expected to succeed; if
  Windows verify says otherwise, swap to `std.process.getEnvVarOwned`.
- **`config.zig` `XDG_CONFIG_HOME`/`HOME` lookup.** Still uses
  `std.c.getenv`. Phase 3 owns the proper Windows fallback to
  `%APPDATA%\verde\verde.json`; Phase 1 compile is expected to work
  because `std.c.getenv` exists in msvcrt.

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
- **2026-05-15 · Timestamp helpers:** Per-file `unixTimestampMs`
  helpers now delegate to `std.time.milliTimestamp` /
  `std.time.nanoTimestamp` instead of `std.c.clock_gettime`.
  Cross-platform, zero behavior change on POSIX. Don't reintroduce
  `std.c.clock_gettime` — it doesn't exist on Windows-MSVC.
