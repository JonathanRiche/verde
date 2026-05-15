# Session Continuation Notes

Working state for the Windows port. Update when the active session ends
in the middle of something so the next session — possibly on a
different host or with a different agent — can resume without
re-discovering context.

If a section here is stale (work has moved past it), prune it. This is
not an append-only log; the session log in [`STATUS.md`](STATUS.md)
serves that role.

---

## Active phase: Phase 1 verification

**Branch:** `claude/setup-verde-project-jtVuM`
(Phase 1 work + roadmap docs are already pushed; see STATUS.md
session log entry dated 2026-05-15.)

**Goal for the next session:** run `zig build -Dtarget=x86_64-windows-msvc
-Dcef-stub-preview=true` (or `mise run build-windows`) on a Windows 11
dev box, fix whatever compile errors surface, then flip Phase 1 to
`done` in `STATUS.md` and start Phase 2.

### Where the user got to in setup

Working on a Windows 11 machine. Status of dependencies the last time
we spoke:

| Tool | Status | Notes |
|------|--------|-------|
| Visual Studio 2026 Community | installed | "Desktop development with C++" workload selected; MSVC + Windows 11 SDK present |
| CMake | installed | `cmake --version` → 4.2.3-msvc3 |
| `cl.exe` (MSVC) | should be on PATH in "Developer PowerShell for VS 2026" | not yet confirmed in user's shell |
| Zig 0.16.0 | **not yet on PATH** | `zig` not recognized in their shell; may not be downloaded/extracted, or PATH update didn't take |
| Bun | **not yet on PATH** | same situation |

Last shell prompt they pasted was sitting in
`C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE`,
which is just where "Developer PowerShell for VS 2026" opens by
default. The actual repo clone hasn't happened yet on Windows.

### Resume checklist for the next session

Tell the user to run the following in **Developer PowerShell for VS
2026** (Start menu → search that exact name; a regular PowerShell
won't have MSVC on PATH):

1. **Verify Zig is downloaded + extracted.**
   ```powershell
   Test-Path "C:\zig\zig-x86_64-windows-0.16.0\zig.exe"
   ```
   - `True` → skip to step 3.
   - `False` → download
     [`zig-x86_64-windows-0.16.0.zip`](https://ziglang.org/download/)
     into `%USERPROFILE%\Downloads`, then:
     ```powershell
     Expand-Archive -Path "$HOME\Downloads\zig-x86_64-windows-0.16.0.zip" -DestinationPath C:\zig -Force
     ```

2. **Put Zig on PATH and reopen the shell.**
   ```powershell
   [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";C:\zig\zig-x86_64-windows-0.16.0", "User")
   ```
   Close the window entirely, reopen "Developer PowerShell for VS
   2026". Then `zig version` should print `0.16.0`. If it still
   doesn't, fall back to the explicit path:
   ```powershell
   & "C:\zig\zig-x86_64-windows-0.16.0\zig.exe" version
   ```
   and either fix PATH or use the full path in step 5.

3. **Install Bun.**
   ```powershell
   powershell -c "irm bun.sh/install.ps1 | iex"
   ```
   Close + reopen the shell again. `bun --version` should work.

4. **Clone (or update) the repo and check out the Phase 1 branch.**
   Stay out of `Program Files`. Pick a normal dev directory:
   ```powershell
   cd $HOME
   mkdir -Force dev | Out-Null
   cd dev
   # one of:
   git clone <verde-remote-url> verde
   # or, if already cloned:
   cd verde
   git fetch origin
   git checkout claude/setup-verde-project-jtVuM
   git pull
   ```

5. **Run the Phase 1 build.**
   From the repo root:
   ```powershell
   zig build -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true
   ```
   First run downloads ghostty/zsdl/palette/etc. into the local Zig
   cache; expect several minutes.

6. **Report results.**
   - Success: `Test-Path zig-out\bin\verde.exe` → `True`. Don't try
     to launch it; Phase 2 wires SDL3.dll.
   - Failure: paste the **full** `error:` block (with `file.zig:LINE:COL:`
     prefixes) into chat. The likely culprits and pre-canned fixes are
     listed in
     [`STATUS.md`](STATUS.md) under "Open Questions Backlog":
     - `verde_macos_clipboard_copy_image` linker error → wrap the
       extern in a comptime `if (builtin.os.tag == .macos)` block in
       `packages/desktop/src/utils.zig`.
     - `TERMINAL_WINSIZE_IOCTL` referencing `std.c.T.IOCSWINSZ` →
       replace the top-level `const` with a comptime switch whose
       `.windows => 0` arm short-circuits.
     - `std.c.getenv` not found → swap the offending call to
       `std.process.getEnvVarOwned`.
     - `std.c.environ` referenced on Windows → make sure the comptime
       switch in `currentEnviron` is what Zig actually elaborates;
       worst case, hoist into two functions selected at module scope.

### Once Phase 1 is verified

1. In `docs/windows-port/STATUS.md`:
   - Flip Phase 1 row to `done` with session count `1`.
   - Add a closing session-log entry: `2026-MM-DD · Phase 1 · verified
     on Windows 11 · <commit>`.
   - Strike the "Phase 1 verify" item from the Open Questions Backlog.

2. Start Phase 2 (SDL3 + Palette runtime smoke). Roadmap section is
   `## Phase 2 — SDL3 + Palette Runtime Smoke`. First moves:
   - Add `-Dsdl3-msvc-root=<path>` to both `build.zig` files.
   - Teach `scripts/windows/setup.ps1` to download
     `SDL3-devel-<ver>-VC.zip` and `SDL3_ttf-devel-<ver>-VC.zip`
     from `libsdl-org/SDL` releases into
     `%LOCALAPPDATA%\verde\sdl3`.
   - In `packages/desktop/build.zig`'s `.windows =>` arm, when
     `sdl3_msvc_root` is set: `addLibraryPath(<root>\lib\x64)`,
     `addIncludePath(<root>\include)`, and install `SDL3.dll` +
     `SDL3_ttf.dll` next to `verde.exe`.
   - Pick an SDL3 version. Match what zsdl ships if possible; if
     not, pin and document in STATUS Decision Log.
