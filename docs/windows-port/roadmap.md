# Windows Port — Phased Roadmap

Working branch: `claude/windows-native-port-*`.

## Ground Rules

- **Target:** `x86_64-windows-msvc`. MinGW is not supported.
- **Dev host:** native Windows 11. Cross-compile from Linux/macOS is a
  non-goal. CI runs on GitHub Actions `windows-latest` (also native).
- **Compile-time conditionals only.** Use `builtin.target.os.tag` /
  `builtin.os.tag`. No runtime `isWindows()` helpers.
- **Don't fork vendored packages.** If a change is unavoidable, add a
  patch under `patches/<pkg>/` with a README explaining the refresh
  flow. The current vendored Ghostty already has Windows support
  upstream — leave it alone.
- **Keep `mise.toml` as the canonical task entry.** Add Windows tasks
  next to the existing Linux/macOS ones; do not replace them.
- **No premature abstraction.** Fix the immediate compile error; don't
  introduce a `platform_*.zig` shim until two callers actually need
  it.

## Order Of Operations

We chose to deviate from the original guess in three places. The
rationale:

- **zig_objc isolation** is not its own phase. It's already
  `.lazy = true` in ghostty's `build.zig.zon` and gated to Darwin in
  `packages/ghostty/src/build/SharedDeps.zig:486` with
  `if (step.rootModuleTarget().os.tag.isDarwin())`. Phase 1 only needs
  to **verify** the gating holds on a fresh Windows build.
- **SDL3 + Palette comes before CEF.** Without SDL3 the binary
  doesn't start; CEF is a pane inside it. `cef-stub-preview` exists
  for exactly this reason — we run the app with no real CEF until
  the SDL3/Palette path is solid.
- **Packaging is split.** Zip first (Phase 7a), MSI later (Phase 7b).
  Each is one session.

Final order:
1. Build orchestration + minimum compile.
2. SDL3 + Palette runtime smoke.
3. Process spawning + provider CLIs.
4. ConPTY glue for libghostty-vt.
5. CEF on Windows.
6. fff (Rust) on Windows MSVC.
7a. Zip packaging + GHA Windows runner.
7b. MSI packaging.

Phase 6 (fff) was originally inside Phase 1 but split out because
cargo + MSVC has its own setup wrinkles that deserve their own
session.

---

## Phase 1 — Build Orchestration + Minimum Compile

**Goal:** `zig build -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true`
completes and produces `verde.exe` on a Windows 11 dev box.
The exe may crash or do nothing useful on launch — Phase 1 ends when
`link.exe` finishes successfully.

**Files touched:**
- `mise.toml` — add Windows tasks (`dev-windows`, `build-windows`,
  `setup-windows`) with `shell = "pwsh"`. Don't modify existing tasks.
- `scripts/windows/` (new) — `setup.ps1`, `dev.ps1`, `build.ps1`,
  `check-build-deps.ps1`. PowerShell counterparts to
  `scripts/dev/check-desktop-build-deps.sh` and
  `scripts/release/install-linux-local-cef.sh`. Document the VS Build
  Tools version + components required (MSVC v143, Windows 11 SDK,
  CMake, Ninja).
- `packages/desktop/build.zig` — extend the `.windows =>` arm to wire
  the SDL3 import lib (path TBD in Phase 2) and install the SDL3 DLL
  next to `verde.exe`. Skip the macOS clipboard `.m` file, skip
  `patchelf`, skip `verde-browser-linux`. Verify that `zig_objc` is
  not pulled in (build should succeed without it being fetched).
- `packages/desktop/src/process_env.zig` — replace
  `std.c.getenv`/`std.c.access`/`std.c.environ` with cross-platform
  equivalents (or split into `_posix.zig`/`_windows.zig` peers only
  if necessary). Just enough to compile; full PATH augmentation logic
  is Phase 3.
- `packages/desktop/src/runtime_log.zig` — already gated for
  `.windows => {}` on the stderr `dup2` path. Audit the rest of the
  file for unsuspected `std.c.*` calls.
- `packages/desktop/src/utils.zig` — guard `verde_macos_clipboard_*`
  externs behind `if (builtin.os.tag == .macos)`. Stub the
  `pickDirectory*`, `launchConfiguredEditor*`,
  `captureClipboard*` paths with `error.UnsupportedOperatingSystem`
  on Windows.
- `packages/desktop/src/state.zig` — `std.c.getenv("HOME")` calls
  (lines ~7384, ~7490) need a Windows fallback to `%USERPROFILE%`.

**Dependencies:** none.

**Known unknowns:**
- Will `std.process.Environ.createMap` work cleanly under Windows-MSVC
  in Zig 0.16? The current code uses
  `.{ .block = .{ .slice = std.mem.span(std.c.environ) } }` for non-
  Windows and `.{ .block = .global }` for Windows — verify the
  Windows arm round-trips correctly.
- Does the build evaluate any of ghostty's GTK/Wayland lazy deps when
  only `ghostty-vt` is needed? Spot-check by running with
  `--summary all` and grepping for `gtk`, `wayland`, `gobject` in
  the fetched set.
- `embedFile`-d shader bytes are big; check link.exe handles them
  without `/BIGOBJ` tuning.

**Definition of done:**
- `zig build -Dtarget=x86_64-windows-msvc -Dcef-stub-preview=true`
  on Windows 11 produces `zig-out\bin\verde.exe` + `SDL3.dll`.
- The exe can be launched and exits with a non-crash error (SDL init
  failure is acceptable here — Phase 2 fixes runtime).
- `mise run dev-windows` is wired and invokes the right `.ps1`.
- Linux and macOS builds via the existing `mise run dev` /
  `mise run build` still work — no regressions.

**Risks:**
- ⚠️ `link.exe` and Zig's MSVC integration sometimes need
  `-Dcpu=baseline` or specific `--subsystem` flags. May need to add
  `subsystem = .windows` to the exe to suppress the console window —
  but only after we've seen a successful console build first.

---

## Phase 2 — SDL3 + Palette Runtime Smoke

**Goal:** `verde.exe` opens an SDL3 window, initializes SDL_GPU with
Vulkan, loads Palette's SPIR-V shaders, and renders an empty frame
without crashing. CEF is still stubbed; terminal is still
`UnsupportedSession`.

**Files touched:**
- `packages/zsdl/build.zig.zon` — add an MSVC SDL3 prebuilt
  dependency, or document that the project supplies its own SDL3
  DLL/`.lib` outside zsdl. **Preferred:** keep zsdl unmodified and
  add a `-Dsdl3-msvc-root=<path>` flag in
  `packages/desktop/build.zig` that points at a downloaded SDL3
  release. The Phase-1 `setup-windows.ps1` becomes responsible for
  downloading `SDL3-devel-*-VC.zip` from libsdl-org/SDL releases.
- `packages/desktop/build.zig` — the `.windows =>` arm:
  - `addLibraryPath(sdl3_msvc_root/lib/x64)`,
    `addIncludePath(sdl3_msvc_root/include)`.
  - Install `SDL3.dll` + `SDL3_ttf.dll` next to the exe.
  - Same for the test target.
- `scripts/windows/setup.ps1` — download SDL3 + SDL3_ttf MSVC dev
  archives, extract into `%LOCALAPPDATA%\verde\sdl3` or similar.
- `packages/palette/build.zig` — verify the example targets don't
  break when `target.os.tag == .windows`; Palette itself doesn't
  build a Windows-specific artifact beyond shaders so this is mostly
  a sanity pass.
- `packages/desktop/src/ui/palette_frame_renderer.zig` — already
  uses `ShaderFormat.defaultForTarget(builtin.os.tag)` and
  `ShaderSource.packagesForTarget(...)`, both of which fall through
  to `vulkanPackages()` for non-Darwin/non-WASM. No code changes
  expected — but verify Vulkan loader is found at runtime.

**Dependencies:** Phase 1.

**Known unknowns:**
- **SDL_GPU on Windows backend selection.** SDL_GPU on Windows can
  use Vulkan or D3D12. SPIR-V shaders work with Vulkan; D3D12 needs
  DXIL (which Palette doesn't currently ship — only HLSL source in
  `packages/palette/src/shaders/ui.frag.hlsl` and `ui.vert.hlsl`,
  but no compiled `.dxil`). Force Vulkan via `SDL_HINT_GPU_DRIVER` or
  ensure `shader_formats` advertises only SPIR-V. Compiling HLSL→DXIL
  via `dxc` is a stretch goal, not a Phase 2 requirement.
- **Vulkan loader presence.** Most Windows 11 boxes ship a Vulkan
  loader via GPU drivers, but headless CI runners may not. Phase 2
  succeeds on a developer GPU box; Phase 7a's CI revisits this.
- **DPI scaling.** Verde's `initial_window_frame()` math may assume
  Linux/macOS DPI behavior. Watch for blurry/tiny windows on
  high-DPI Windows displays.

**Definition of done:**
- `mise run dev-windows` opens a verde window, renders the Palette
  retained UI with the actual project sidebar (no chat threads
  loaded yet because no PTY/provider work), and accepts mouse + key
  input without crashing.
- `zig build test` (Windows arm) runs and either passes or fails on
  test logic — not on platform compile errors.
- The browser pane shows the stub-preview placeholder (because
  `-Dcef-stub-preview=true`).
- The terminal dock shows the `UnsupportedSession` "embedding only on
  Linux/macOS" message — replaced in Phase 4.

**Risks:**
- ⚠️ SDL_GPU's Vulkan path is the youngest backend; expect some
  flickering/swapchain issues. If insurmountable, fall back plan is
  to compile HLSL→DXIL during Phase 2 and use D3D12 — costs ~1
  session.

---

## Phase 3 — Process Spawning + Provider CLIs

**Goal:** All four providers (Codex, Claude Code, OpenCode, Cursor)
spawn correctly on Windows. `claude`, `codex`, `opencode` CLIs
resolve from PATH; their subprocesses get the same augmented
environment Verde provides on Linux/macOS today.

**Files touched:**
- `packages/desktop/src/process_env.zig` — full Windows pass:
  - `SYSTEM_PATH_DIRS` Windows variant: `%SystemRoot%\System32`,
    `%SystemRoot%`, `%ProgramFiles%\nodejs`, etc.
  - `HOME_PATH_SUFFIXES` Windows variant:
    `%LOCALAPPDATA%\Programs\…`, `%APPDATA%\npm`,
    `%USERPROFILE%\.cargo\bin`, `%USERPROFILE%\.bun\bin`,
    `%LOCALAPPDATA%\mise\shims`.
  - `commandExists` / `resolveExecutableInEnvMapAlloc` — try the bare
    name plus `.exe`, `.cmd`, `.bat` extensions in PATHEXT order.
  - `isQualifiedExecutablePath` — already handles `\\` but not drive
    letters (`C:\…`). Add the drive-letter check.
- `packages/desktop/src/providers/{codex,claude,opencode,cursor}.zig`
  — verify each path:
  - Process spawn via `std.process.spawn` works with `.exe`/`.cmd`
    targets.
  - Process group termination (the providers currently call
    `std.posix.kill(-pgid, SIG.TERM)` for process-group SIGTERM) —
    no equivalent on Windows. Use `TerminateProcess` on the root
    PID, or attach a Job Object at spawn time so the children die
    with the parent. Job Object is the right Windows-idiomatic
    answer.
  - `claude_bridge.mjs` line ~214 hardcodes
    `@anthropic-ai/claude-agent-sdk-linux-${arch}` — add a Windows
    arm. Verify the SDK ships a Windows package.
- `packages/desktop/src/utils.zig` — `commandExecutableName`
  on Windows should normalize `.exe`/`.cmd` suffixes (the
  `resolvedPathLooksLikeCursorIdeBinary` branch already half-does
  this).
- `packages/desktop/src/state.zig` — replace `std.c.getenv("HOME")`
  with `std.process.getEnvVarOwned(allocator, "USERPROFILE")` on
  Windows. Same for `VERDE_OPEN_BROWSER_ON_START`.
- `packages/desktop/src/config.zig` — `XDG_CONFIG_HOME` lookup needs
  a Windows fallback to `%APPDATA%\verde\verde.json`.
- `packages/desktop/src/runtime_log.zig` — wire a Windows
  stderr-redirect via `SetStdHandle(STD_ERROR_HANDLE, file_handle)`,
  matching the `dup2` behavior on POSIX.

**Dependencies:** Phase 1 (compile), Phase 2 (UI to see provider
status).

**Known unknowns:**
- **Claude Agent SDK Windows availability.** The SDK's Linux/macOS
  npm packages are platform-tagged; verify `@anthropic-ai/claude-
  agent-sdk-win32-x64` (or equivalent) exists. If not, providers
  fall back to spawning `claude.exe` directly without the bridge,
  losing some functionality. Flag as risk if missing.
- **PATHEXT semantics.** Some Windows users override PATHEXT; respect
  it via `std.process.getEnvVarOwned("PATHEXT")` rather than
  hardcoding.
- **mise on Windows.** mise has Windows support (per upstream docs)
  but its task runner invokes `bash -lc` for existing tasks; new
  Windows tasks must declare `shell = "pwsh"`. Verify task
  enumeration works and `mise run setup-windows` actually executes.

**Definition of done:**
- Each provider's "auth status" probe runs without crashing on
  Windows 11 with a working Claude/Codex/OpenCode install.
- Closing Verde with an active provider stream cleanly kills the
  child process (no orphaned `node.exe` in Task Manager).
- The augmented PATH includes user-local install dirs so a
  Verde launched from the Start Menu (no inherited terminal env)
  still finds `claude.exe`.

**Risks:**
- ⚠️ Cursor SDK uses Node.js; the bridge mechanism may need adjusting
  for Windows pipe semantics (`\\.\pipe\` named pipes vs Unix domain
  sockets). The existing bridge already uses stdio, which is portable;
  flag if any other transport sneaks in.

---

## Phase 4 — ConPTY Glue For libghostty-vt

**Goal:** The embedded terminal dock works on Windows. Opening a
terminal in a project spawns `pwsh.exe` (or `%COMSPEC%`), the prompt
renders, keystrokes are sent, output is displayed and scrolls
correctly.

**Files touched:**
- `packages/desktop/src/terminal/terminal.zig` — bulk of the work:
  - Add `WindowsSession` peer to `UnixSession`. Same public surface
    (`create`, `deinit`, `poll`, `resize`, `displayText`,
    `statusText`, `tabTitle`, `isRunning`, `writeInput`,
    `handleKeyDown`).
  - Replace the `Session = if (SESSION_SUPPORTED) UnixSession else
    UnsupportedSession` switch with a three-arm:
    ```zig
    const Session = switch (builtin.os.tag) {
        .linux, .macos => UnixSession,
        .windows => WindowsSession,
        else => UnsupportedSession,
    };
    ```
  - `WindowsSession.spawnShell`:
    `CreatePseudoConsole(size, in_pipe, out_pipe, 0, &hpc)` →
    `InitializeProcThreadAttributeList` →
    `UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE)`
    → `CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT`. Use
    `pwsh.exe` if present, else `%COMSPEC%`, else `cmd.exe`.
  - `poll`: drain the out_pipe via `ReadFile` (overlapped or
    polling-with-PeekNamedPipe; ConPTY's pipe is a real anonymous
    pipe, not a console handle). Feed bytes into
    `self.stream.feed()` the same way `UnixSession` does today.
  - `writeInput`: `WriteFile` to the in_pipe.
  - `resize`: `ResizePseudoConsole(hpc, COORD{cols, rows})`.
  - **Process-exit detection:** wait on the process handle (or
    `GetExitCodeProcess` with `STILL_ACTIVE` check) at poll time. This
    is the sharp edge ghostty's docs warn about — ConPTY does not
    close the output pipe immediately when the child dies; do the
    exit check explicitly each poll.
  - Strip OSC-133 / CSI cursor sequences only if they cause issues
    (Windows Terminal injects some shell-integration sequences in
    pwsh that may differ from POSIX shells).
- `packages/desktop/src/keybinds.zig` — verify
  `CommandOrControl` maps to Ctrl on Windows (line ~76 currently
  reads `primary_uses_meta = builtin.os.tag == .macos` which already
  does the right thing — sanity check it).

**Dependencies:** Phase 1 (compile), Phase 2 (window).

**Known unknowns:**
- **Renderer wakeup / redraw timing.** Verde's render loop polls
  terminals every frame (`pollTerminals()` in `state.zig`). ConPTY
  output is async; we either poll the pipe every frame
  (`PeekNamedPipe` first to avoid blocking) or use overlapped I/O +
  signal a redraw via SDL custom event. **Recommendation:**
  start with `PeekNamedPipe` + non-blocking `ReadFile`. Overlapped
  I/O is a Phase 4-followup if the polling latency feels bad.
- **ConPTY scroll-region quirks.** ConPTY translates VT sequences to
  console operations and back; some sequences round-trip imperfectly.
  Look at how ghostling and Phantty handle this — they're the
  current reference. Verde uses libghostty-vt directly so we may
  hit fewer issues, but flag any rendering glitches as a known
  ConPTY pathology rather than a Verde bug.
- **libxml2 / symlinks issue (ghostty #11697).** Affects the full
  Ghostty build's dep fetching on Windows. Verde only consumes the
  `ghostty-vt` module, which doesn't transitively pull libxml2 (lib_vt
  only needs `uucode`, `unicode_tables`, `simdutf`, `highway`). **Flag
  as a resync risk:** if we ever bump the vendored ghostty version
  and the new version pulls libxml2 into the vt build graph, we'll
  hit this. Mitigation: pin ghostty version explicitly in
  `packages/ghostty/build.zig.zon` and verify Windows builds before
  bumping.
- **PTY for SSH'd / containerized scenarios.** Out of scope for
  Phase 4. ConPTY on the local box only.

**Definition of done:**
- Open Verde on Windows, focus a project, `Ctrl+J` opens the
  terminal dock, sees a `PS C:\path\to\project>` prompt.
- Typing commands works, scrollback works, `Ctrl+C` interrupts the
  child, exiting the shell shows the "Shell exited" status line
  (mirroring the Unix path).
- Splitting + tabs work (the existing PaneNode logic should be
  platform-agnostic; verify).
- Closing the terminal dock cleanly closes the pseudo-console and
  reaps the child.

**Risks:**
- ⚠️ Renderer wakeup timing — if ConPTY output bursts during a
  build, frame rate could tank. Profile early.
- ⚠️ Some shells (Git Bash via `bash.exe`) misbehave under ConPTY's
  VT translation. Default to `pwsh.exe` for predictability.

---

## Phase 5 — CEF On Windows

**Goal:** Real CEF browser pane on Windows. `-Dcef-sdk-path=<path>`
on Windows builds the helper exes and wires them into the runtime
the same way Linux does today.

**Files touched:**
- `scripts/release/cef-common.sh` — extend `verde_cef_host_os` and
  `verde_cef_platform_suffix` to recognize `MINGW`/`MSYS` hosts (for
  the rare case someone runs from Git Bash) **and** add a
  PowerShell counterpart at `scripts/windows/cef-common.ps1` that
  downloads `cef_binary_<ver>_windows64_minimal.tar.bz2` from
  `cef-builds.spotifycdn.com`.
- `scripts/windows/setup.ps1` — invoke the CEF downloader.
- `packages/desktop/build.zig` —
  - Widen `cef_supported = target.result.os.tag == .linux or .macos`
    to include `.windows`.
  - Add `installWindowsCefRuntime(b, sdk_path)` — copies
    `libcef.dll`, `chrome_elf.dll`, `d3dcompiler_47.dll`,
    `v8_context_snapshot.bin`, `icudtl.dat`, `*.pak`, `locales/`
    next to `verde.exe`. CEF Windows ships under
    `<sdk>/Release/` like Linux.
  - The CMake invocation already uses `cmake -S … -B …`; needs to
    be rewritten to run under PowerShell (no `bash -lc`) when the
    host is Windows.
- `packages/desktop/src/browser/cef/c/CMakeLists.txt` — add a
  Windows arm:
  - `target_sources(verde-browser-cef PRIVATE native_windows.cc
    helper_windows.cc process_helper_windows.cc)`.
  - Link `libcef_lib` (Windows CEF SDK provides `libcef.lib`).
  - `SET_EXECUTABLE_TARGET_PROPERTIES` from CEF's cmake module
    already handles Windows.
  - Mark `verde-browser-cef.exe` as `WIN32` (no console window).
- `packages/desktop/src/browser/cef/c/native_windows.cc` (new) —
  HWND-based equivalent of `native_linux.cc`. CEF on Windows uses
  windowed mode (parent HWND from SDL) or off-screen rendering
  (OSR). **Mirror the existing Linux OSR path** — Verde already
  pipes CEF frames through SDL_GPU as textures, no HWND embedding
  needed. This is the same shape as Linux; primarily a search-and-
  replace from X11/Linux POSIX calls to Win32 equivalents.
- `packages/desktop/src/browser/cef/c/helper_windows.cc` and
  `process_helper_windows.cc` — Windows entry points
  (`wWinMain` / `wmain`).
- `packages/desktop/src/browser/cef/native.zig` — widen
  `const native_api = if (build_options.cef_sdk_configured and
  builtin.os.tag == .linux)` to include `.windows`.
- `packages/desktop/src/browser/controller.zig` — same; `shouldUseCefBackend`
  already returns the same answer regardless of OS once `cef_sdk_configured`
  is true.

**Dependencies:** Phase 1, 2, 3.

**Known unknowns:**
- **CEF SDK size on Windows.** ~600MB extracted. Confirm the cache
  directory under `%LOCALAPPDATA%\verde\cef-sdk` works (Win32 long-
  path limits historically bit CEF; CEF 146+ tested in Windows but
  worth a fresh check).
- **CEF helper exe + main exe ABI.** Both must be MSVC. The main
  Verde build is `x86_64-windows-msvc` per our toolchain choice, so
  this is already consistent.
- **OSR rendering on Windows.** Some integrated GPUs have known
  CEF OSR perf issues. Out of scope unless they're showstoppers.

**Definition of done:**
- `mise run dev-windows -- -Dcef-sdk-path=<path>` (or the
  `setup-windows`/`dev-windows` flow that pre-downloads it) launches
  Verde with the real browser pane.
- Navigation, scroll, keyboard input work.
- Closing Verde reaps the CEF helper exes (Job Object from Phase 3
  helps here).

**Risks:**
- ⚠️ CEF's CMake module changes between CEF major versions. If we
  bump `VERDE_CEF_VERSION` later, expect to revisit this file.

---

## Phase 6 — fff (Rust) On Windows MSVC

**Goal:** `cargo build --release --package fff-c --features zlob`
succeeds for `x86_64-pc-windows-msvc` and produces `fff_c.dll`. The
desktop build copies it next to `verde.exe` and Verde's file
indexer + grep work.

**Files touched:**
- `vendor/fff/.cargo/config.toml` — verify target-specific
  configuration is sane on Windows MSVC. Some workspace deps
  (`mlua`, `mimalloc`) have Windows-specific requirements.
- `packages/desktop/build.zig` — the `fff_lib_name` switch already
  produces `fff_c.dll` on Windows (line ~21). The cargo `build_fff`
  step is already platform-agnostic. Verify the
  `linkSystemLibrary("fff_c", .{})` finds `fff_c.dll.lib` (the
  import lib) — may need to add `addLibraryPath` and switch to
  loading the import lib explicitly on Windows.
- `scripts/windows/setup.ps1` — ensure `cargo` + `rustup target add
  x86_64-pc-windows-msvc` happen as part of dev setup, alongside
  the VS Build Tools dependency.

**Dependencies:** Phase 1 (cargo invocation runs as part of the build).

**Known unknowns:**
- **`mlua` Windows linkage.** `mlua` with the `luajit` feature
  expects to find LuaJIT. Windows MSVC builds typically need a
  prebuilt LuaJIT lib. Check `vendor/fff` Cargo features for whether
  LuaJIT is actually pulled in by `fff-c` or only by other crates
  not built.
- **`mimalloc` Windows.** Generally works; verify with the chosen
  Rust version pinned in `rust-toolchain.toml`.
- **`git2` vendored libgit2.** Builds OK on Windows MSVC but
  notoriously slow.

**Definition of done:**
- `mise run dev-windows` produces a `verde.exe` + `fff_c.dll` pair
  in `zig-out\bin`.
- The file-finder UI (Ctrl+P or equivalent) returns results from a
  Windows project directory.

**Risks:**
- ⚠️ If LuaJIT is required and fails on MSVC, we have to either
  switch `mlua` to a different Lua backend or strip the
  `zlob`/whatever-needs-Lua feature on Windows. Flag if hit.

---

## Phase 7a — Zip Packaging + CI

**Goal:** `mise run package-windows` produces
`verde-<version>-windows-x86_64.zip` containing `verde.exe`,
`SDL3.dll`, `SDL3_ttf.dll`, `fff_c.dll`, CEF runtime, and resources.
A GitHub Actions workflow on `windows-latest` reproduces the build
and uploads the zip as a release artifact.

**Files touched:**
- `mise.toml` — `tasks.package-windows`.
- `scripts/windows/package.ps1` — assemble the zip from `zig-out`.
- `.github/workflows/windows.yml` (new) — `windows-latest` runner,
  installs VS Build Tools, Zig 0.16.0 (via mise or direct
  download), runs `mise run setup-windows` + `mise run
  build-windows` + `mise run package-windows`. Uploads the zip.

**Dependencies:** Phases 1–6 (everything must build).

**Known unknowns:**
- **Code signing.** Out of scope for 7a. Unsigned zip first; signing
  comes with 7b.
- **GHA disk space.** CEF SDK + Rust target dirs are large; the
  default `windows-latest` runner has limited disk. May need to
  cache aggressively or use a self-hosted runner.

**Definition of done:**
- Zip downloads from a release artifact, unpacks anywhere, runs.
- CI green on PRs that touch Windows code.

---

## Phase 7b — MSI Packaging

**Goal:** Optional installer (.msi) for "real" Windows distribution.

**Files touched:**
- `scripts/windows/build-msi.ps1` — invoke WiX Toolset or
  `dotnet wix` to produce an MSI from the Phase 7a zip layout.
- `.wxs` source under `packages/desktop/aur/` peer (or new dir).

**Dependencies:** Phase 7a.

**Known unknowns:**
- WiX v4 vs v3 — pick one. v4 (`dotnet wix`) is the current
  recommendation.
- Code signing certificate. Required for SmartScreen to not
  immediately warn the user. Separate to procure.

**Definition of done:**
- Double-clicking the MSI installs Verde to `Program Files\Verde`,
  creates Start Menu shortcuts, registers an uninstaller.
- `verde.exe` launched from the Start Menu finds CLIs on PATH
  (Phase 3 PATH augmentation does the heavy lifting).

---

## Cross-Phase Risks

- **Vendored Ghostty resync.** Verde pins a specific ghostty commit
  in `packages/desktop/zig-pkg/`. Bumping ghostty may pull
  Windows-incompatible deps (libxml2 / symlinks issue in ghostty
  discussion #11697). Mitigation: any future ghostty bump runs a
  full Windows build before merge.
- **CEF version bumps.** Same pattern: bump `VERDE_CEF_VERSION` in
  `scripts/release/cef-common.sh` requires a Windows test pass.
- **MSVC version drift.** VS Build Tools auto-updates. Pin the
  components (MSVC v143, Windows 11 SDK 10.0.22621.0 or later) in
  `scripts/windows/setup.ps1` and check at build time.
- **Zig 0.16 → 0.17.** When the repo bumps, the Windows-MSVC path
  may regress before Linux/macOS does. Keep `STATUS.md` updated.
