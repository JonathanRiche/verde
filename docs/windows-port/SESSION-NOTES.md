# Session Continuation Notes

Working state for the Windows port. Update when the active session ends
in the middle of something so the next session — possibly on a
different host or with a different agent — can resume without
re-discovering context.

If a section here is stale (work has moved past it), prune it. This is
not an append-only log; the session log in [`STATUS.md`](STATUS.md)
serves that role.

---

## Active phase: Phase 1 verification (in progress)

**Branch:** `claude/setup-verde-project-jtVuM` (on `origin`).

**State as of 2026-05-15 close-of-day:** The build now gets past
package resolution, the Rust `fff` crate, all of zsdl, and ghostty's
build-time `Config.zig`. The Zig compile of `verde.exe` itself is
in progress — three sets of compile errors have been fixed; another
batch may surface on the next attempt.

**Goal:** `zig build -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true
-Dsdl3-msvc-root=... -Dsdl3-ttf-msvc-root=...` finishes with
`zig-out\bin\verde.exe` produced. Then flip Phase 1 to `done` in
`STATUS.md` and start Phase 2.

### What's already installed on the dev Windows box

Set up during this session (Kyle's machine `kmchu` ~ `C:\Users\kmchu\dev\verde`):

- **Visual Studio 2026 Community** with the "Desktop development with
  C++" workload (MSVC v143 + Windows 11 SDK).
- **Zig 0.16.0** at
  `C:\Users\kmchu\AppData\Local\Microsoft\WinGet\Packages\zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe\zig-x86_64-windows-0.16.0\zig.exe`,
  on PATH.
- **Bun 1.3.14**, on PATH.
- **CMake 4.2.3-msvc3**, on PATH.
- **LLVM** at `C:\Program Files\LLVM` (winget). Needed for the
  Rust `bindgen` step inside `fff`'s `zlob` dep. Set
  `$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"` before each build
  (or persist it via `setx`).
- **SDL3 dev SDK** unpacked at `C:\sdl3\SDL3-3.2.26\` (download
  `SDL3-devel-3.2.26-VC.zip` from libsdl-org/SDL releases).
- **SDL3_ttf dev SDK** unpacked at `C:\sdl3\SDL3_ttf-3.2.2\`
  (download `SDL3_ttf-devel-3.2.2-VC.zip` from libsdl-org/SDL_ttf —
  use the `-devel-*-VC.zip` asset, **not** the runtime-only
  `SDL3_ttf-3.2.2-win32-x64.zip` which doesn't include `lib/x64/*.lib`).

When switching to a new Windows box, redo all of these. On a box
already set up, only step 1 of "Resume checklist" below is needed.

### Resume checklist for the next session

In a **Developer PowerShell for VS 2026** (Start menu → that exact
name; a normal PowerShell does not have MSVC visible):

```powershell
cd $HOME\dev\verde
git fetch origin
git checkout claude/setup-verde-project-jtVuM
git pull

$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$sdl3 = (Get-ChildItem C:\sdl3\SDL3-* -Directory | Select-Object -First 1).FullName
$sdlttf = (Get-ChildItem C:\sdl3\SDL3_ttf-* -Directory | Select-Object -First 1).FullName

zig build `
    -Dtarget=x86_64-windows-msvc `
    -Dcef-stub-preview=true `
    "-Dsdl3-msvc-root=$sdl3" `
    "-Dsdl3-ttf-msvc-root=$sdlttf"
```

The auto-detection picks whatever version folder exists under
`C:\sdl3\`, so a future SDL3 bump just requires re-extracting into
that directory.

### Errors fixed during this session (do not re-introduce)

Patches captured under `patches/<pkg>/`:

1. `patches/ghostty/0001-os-path-expand-stub-on-windows.patch` —
   `expand()` used Zig-0.15 APIs (`std.process.getenvW`,
   `std.fs.cwd().openFile`); only reachable from
   `build/Config.zig`'s pandoc/xcodebuild sniff. Stubbed to
   `return null;` since Verde never needs either tool.
2. `patches/zsdl/0001-skip-windows-prebuilt.patch` — zsdl's
   `prebuilt_sdl3.{addLibraryPathsTo,install}` called
   `lazyDependency("sdl3_prebuilt_x86_64_windows_gnu", ...)`. The
   upstream prebuilt's `build.zig.zon` predates Zig 0.16's mandatory
   `fingerprint` field, so package resolution failed. The Windows
   arms are now no-ops; Verde supplies SDL3 via `-Dsdl3-msvc-root`.

Local code changes (`packages/desktop/src/`):

- `std.process.getEnvVarOwned` doesn't exist in Zig 0.16.
  `process_env.readEnvVarAlloc` is the canonical replacement
  (Environ.createMap → Map.get → allocator.dupe).
- `std.time.milliTimestamp` / `std.time.nanoTimestamp` are gone;
  `std.time` is constants-only in 0.16. The
  `Io.Clock.now` replacement requires an `Io`. Helpers use
  `GetSystemTimeAsFileTime` / `QueryPerformanceCounter` on Windows
  and `std.c.clock_gettime` on POSIX.
- `std.fs.cwd()` is gone too; use
  `std.Io.Dir.cwd().access(io, path, .{})` (already-vetted pattern
  in `providers/claude.zig`).
- `-Dsdl3-msvc-root` and `-Dsdl3-ttf-msvc-root` point at the
  extracted `SDL3-devel-*-VC.zip` / `SDL3_ttf-devel-*-VC.zip`
  layouts. They wire `addIncludePath`, `addLibraryPath`, and
  install `*.dll` next to `verde.exe`. The include path is also
  added to `palette_module` because `palette/src/renderer.zig`
  does its own `@cImport(<SDL3/SDL_gpu.h>)`.

### Likely next compile errors and how to fix

When the next build runs, expect more API-drift errors as Zig's
analyzer reaches code that's only reachable on Windows. Pattern
recognition:

- **`std.fs.<something>` not found** → check
  `providers/claude.zig:483` for the working
  `std.Io.Dir.cwd().access(...)` pattern, replicate.
- **`std.process.<something>` not found** → use
  `process_env.readEnvVarAlloc` for env vars, or
  `process_env.buildAugmentedEnvMap` for the full Map.
- **`std.time.<something>` not found** → in-line the
  GetSystemTimeAsFileTime / clock_gettime pair from
  `runtime_log.zig::realtimeMs` or `profiler.zig::nowNs`.
- **Missing extern symbol on link** (e.g. another
  `verde_macos_clipboard_*`) → wrap the extern decl in a comptime
  `if (builtin.os.tag == .macos)` block.

### Once Phase 1 is verified

1. In `docs/windows-port/STATUS.md`:
   - Flip Phase 1 row to `done` with session count `1` (or
     `2` if the verify session takes more than one).
   - Add a closing session-log entry: `2026-MM-DD · Phase 1 ·
     verified on Windows 11 · <commit>`.
   - Strike the "Phase 1 verify" item from the Open Questions
     Backlog.

2. Start Phase 2 (SDL3 + Palette runtime smoke). First moves:
   - Teach `scripts/windows/setup.ps1` to download
     `SDL3-devel-<ver>-VC.zip` and `SDL3_ttf-devel-<ver>-VC.zip`
     from `libsdl-org/SDL{,_ttf}` releases into
     `%LOCALAPPDATA%\verde\sdl3` (versions stored in a `.ver` file
     so re-runs are idempotent).
   - Have `build.ps1` / `dev.ps1` default `-Dsdl3-msvc-root` and
     `-Dsdl3-ttf-msvc-root` to the auto-detected paths inside that
     dir.
   - Pin matching versions in `STATUS.md` Decision Log
     (currently SDL3 3.2.26 + SDL3_ttf 3.2.2).
