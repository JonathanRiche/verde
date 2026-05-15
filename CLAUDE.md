# Verde

Desktop GUI for coding agents (Codex, Claude Code, OpenCode, Cursor).
Native Zig app, retained-mode UI, embedded terminal + browser pane.
Currently runs on Linux and macOS; Windows port is in progress on
`claude/windows-native-port-*` branches — see `docs/windows-port/`.

## Tech Stack

- **Zig 0.16.0** — pinned in `mise.toml`. Single source of truth for the
  toolchain. ZLS 0.16.0 alongside it.
- **SDL3** — windowing, input, GPU surface. Linked dynamically. The
  zsdl package vendors prebuilt SDL3 for Linux/macOS/Windows-gnu.
- **SDL_GPU + SDL3_ttf** — used by Palette's renderer. SPIR-V on
  Linux/Windows-Vulkan, Metal on macOS.
- **CEF (Chromium Embedded Framework)** — backs the in-app browser
  pane. Out-of-process: `verde-browser-cef` and
  `verde-browser-cef-process` helpers spawned over IPC. Linux and macOS
  today; Windows is a roadmap phase.
- **libghostty-vt** — the VT/terminal-emulator engine, Zig module
  exported by `packages/ghostty`. VT-only; PTY/process spawn is
  Verde's responsibility.
- **Rust** — only used to build the vendored `fff` crate (file
  indexing + search), linked into Verde as `libfff_c`.

## Workspace Layout

```
packages/
  desktop/             # main app (Zig). Entry: packages/desktop/build.zig
                       # → src/main.zig
  palette/             # in-repo Zig GUI framework. Retained
                       # components, SDL3+SDL_GPU renderer, shader
                       # packages.
  ghostty/             # vendored Ghostty source. Verde uses only the
                       # "ghostty-vt" module (see src/lib_vt.zig). The
                       # rest (UI, apprt, font shaping, GTK) is
                       # present but unbuilt.
  zsdl/                # zig-gamedev Zig bindings for SDL3. Carries
                       # SDL3 prebuilt deps for Linux/macOS/Windows.
  libxev/              # event loop. Pulled in transitively by
                       # ghostty; not directly used by verde.
  vaxis/               # terminal UI lib. Transitive ghostty dep.
  uucode/              # Unicode tables. Used by ghostty-vt for
                       # grapheme break support.
  zig_dif/             # diff rendering (chat markdown).
  zig_markdown/        # markdown parser (chat markdown).
  zig_objc/            # Objective-C runtime bindings. macOS-only;
                       # already lazy + gated to Darwin in ghostty's
                       # SharedDeps.zig. Do not import directly from
                       # Verde.
  zig_treesitter/      # tree-sitter bindings. Not currently linked
                       # into the desktop exe.
  browser_extensions/  # Bun-built JS bundle (inspector.js) embedded
                       # into the exe.
  website/             # marketing site, separate build.
  npm/                 # platform-specific npm launcher packages.
vendor/
  fff/                 # Rust crate, built via cargo. See
                       # patches/fff/ for local diffs reapplied on
                       # vendor refresh.
  stb_image.h          # image decoding (header-only C).
  stb_truetype.h       # font rasterization (header-only C).
patches/fff/           # local patch queue reapplied by
                       # scripts/vendor/update-fff.sh.
scripts/
  dev/                 # build-deps check.
  release/             # install + packaging scripts per platform.
                       # cef-common.sh is the canonical CEF SDK
                       # downloader.
  vendor/              # vendor refresh tooling.
```

## Build Entry Points

The desktop app's build is **rooted at `packages/desktop/build.zig`**.
The repo-root `build.zig` is a forwarder: it just spawns
`zig build` inside `packages/desktop/`. Almost every meaningful build
option (`-Dcef-sdk-path`, `-Dpalette-renderer`, `-Dui-debug`,
`-Dsdl3-runtime-lib`, `-Dcef-stub-preview`) is declared in both files
and threaded through.

**mise is the canonical task runner.** `mise.toml` at the repo root
holds all developer tasks; do not duplicate logic into ad-hoc shell
aliases. When adding a new task, add it to `mise.toml`, not a shell
script that mise then calls.

Key tasks (Linux/macOS today; see `docs/windows-port/roadmap.md` for
the Windows path):

- `mise run setup` — download/cache the CEF SDK.
- `mise run dev` — `zig build run --release=safe` with CEF wired up.
- `mise run run` — debug build, runs the app.
- `mise run debug` — debug build with `-Dui-debug=true`.
- `mise run build` — packaged release-style install.
- `mise run dev-sdl-gpu` — `-Dpalette-renderer=sdl_gpu`.

`scripts/release/install-{linux,macos}-local{,-cef}.sh` wrap
`zig build` with the CEF SDK plumbing and produce a
release-style installed tree. Their Windows counterparts live under
`scripts/windows/` once the Windows port phase 1 lands.

## CEF Wiring

CEF is **optional at build time**. `-Dcef-sdk-path=<path>` enables it
and triggers the CMake build in
`packages/desktop/src/browser/cef/c/CMakeLists.txt`, producing two
helper exes (`verde-browser-cef`, `verde-browser-cef-process`) that
the main app spawns. Without `-Dcef-sdk-path`, the desktop falls back
to a per-platform legacy browser backend (WebkitGTK on Linux; nothing
on macOS/Windows) or to a stub when `-Dcef-stub-preview=true`.

`build_options.cef_sdk_configured` is the runtime flag that gates the
CEF code paths. It's set at build time to
`cef_sdk_path != null and (target.os.tag == .linux or .macos)`.
Adding Windows means widening that check **and** adding a
`native_windows.cc` next to the existing Linux/macOS shims.

The `scripts/release/cef-common.sh` script is the canonical CEF SDK
downloader. `VERDE_CEF_VERSION` is pinned at the top of that file.
A Windows path will need to extend `verde_cef_host_os` /
`verde_cef_platform_suffix` to recognize the host and produce the
right archive URL (CEF publishes `windows64`/`windowsarm64` builds at
`cef-builds.spotifycdn.com`).

## Terminal / PTY

`packages/desktop/src/terminal/terminal.zig` runs the VT engine
(libghostty-vt) and the PTY. Today it uses POSIX `forkpty(3)` directly
and gates everything behind:

```zig
const SESSION_SUPPORTED = builtin.os.tag == .linux or builtin.os.tag == .macos;
const Session = if (SESSION_SUPPORTED) UnixSession else UnsupportedSession;
```

`UnsupportedSession` is a stub that surfaces "embedding is only
enabled on Linux and macOS." The Windows port adds a `WindowsSession`
peer to `UnixSession` (ConPTY: `CreatePseudoConsole` + anonymous
pipes + `CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT`).
**Important:** libghostty-vt is VT-only — `lib_vt.zig` does not
re-export ghostty's `Pty`/`Command` modules. Verde owns the PTY layer
on every platform; do not assume `@import("ghostty-vt").Pty` exists.

## Providers (Subprocesses)

Each provider in `packages/desktop/src/providers/` spawns a local CLI:

- `codex.zig` → `codex` (with `codex app-server` auto-started).
- `claude.zig` → `node + claude_bridge.mjs` driving the Claude Agent SDK.
- `opencode.zig` → `opencode` (with `opencode serve` auto-started).
- `cursor.zig` → `node + bridge` driving `@cursor/sdk`.

`process_env.zig` builds the augmented PATH (`~/.local/bin`, mise
shims, `/usr/local/bin`, …) so packaged GUI launches find the
provider binaries. It currently uses `std.c.getenv`, `std.c.access`,
and `std.c.environ` — all POSIX. Windows needs `std.process.getEnvVarOwned`
+ `std.fs.cwd().access`, plus Windows-specific PATH suffixes
(`%LOCALAPPDATA%\Programs`, `%APPDATA%\npm`, etc.) and `.exe`/`.cmd`/`.bat`
suffix resolution (the `commandExists`/`resolveExecutableInEnvMapAlloc`
helpers are the chokepoints).

## Windows Toolchain (in progress)

- **Default target: `x86_64-windows-msvc`.** MinGW is not supported.
  CEF ships MSVC binaries officially, libghostty-vt's upstream
  embedders build with MSVC + CMake, and ConPTY work lives in
  Windows.h territory where MSVC + WinDbg is the path of least
  resistance.
- **Dev host: native Windows 11.** Cross-compile from Linux/macOS is
  a non-goal. CI runs on GitHub Actions `windows-latest` runners (also
  native, not cross-compile).
- **SDL3:** zsdl's prebuilt is `_x86_64_windows_gnu` only, so the
  Windows port pulls SDL3's official MSVC release (or vcpkg) and
  installs the DLL next to `verde.exe`.
- **Rust (fff):** cargo target `x86_64-pc-windows-msvc`. Requires the
  same MSVC toolchain.

## Conventions Future Sessions Need

### Platform gating

- Prefer **comptime conditionals** via `builtin.target.os.tag` /
  `builtin.os.tag`. Switch over the tag, fall through with `else => {}`
  or a clear unsupported branch. Don't introduce runtime `if (isWindows)`
  branches when comptime works.
- When a code path is genuinely unsupported on a platform, model it the
  way `terminal.zig` does: a typed stub (`UnsupportedSession`) that
  returns a known error, not a panic.
- The single canonical compile-time switch lives next to the data it
  controls. Don't add a second `IS_WINDOWS` const in another file —
  re-derive from `builtin` there too.

### Don't fork vendored packages

- `packages/ghostty`, `packages/libxev`, `packages/vaxis`,
  `packages/uucode`, etc. are intended to track upstream. If a
  change is unavoidable, capture it as a patch under `patches/<pkg>/`
  and document the refresh flow (see `patches/fff/README.md` for the
  pattern).
- `zig_objc` is a Darwin-only transitive ghostty dep, already declared
  `.lazy = true` and gated with `if (os.tag.isDarwin())` in ghostty's
  `SharedDeps.zig`. **Do not import it from Verde directly** — that
  pulls Apple SDK assumptions into non-Apple builds.

### mise tasks

- `mise.toml` is the canonical task entry. Add new Windows tasks
  **alongside** the existing Linux/macOS ones, don't rewrite the
  existing ones to be cross-platform.
- The existing tasks use `bash -lc '…'`; Windows tasks should set
  `shell = "pwsh"` on the task (or live as a separate
  `tasks.dev-windows`) and call `scripts/windows/*.ps1`. Don't shell
  out to PowerShell from a bash task.

### Build options live in two places

`build.zig` (repo root) and `packages/desktop/build.zig` both declare
the same `-D` flags. When adding a new option, add it in both files
and thread it through the `addDesktopCommand` argv builder in the
root.

### Testing

- `zig build test` from `packages/desktop/` runs unit tests and a
  formatter check. The same suite runs from the repo root.
- For UI changes, manually run `mise run dev` and verify in the
  window — type-check passes do not imply the UI works.

### Logs

Runtime stderr is redirected through `runtime_log.zig` into SDL's pref
path: `~/.local/share/verde/Native/logs/verde.stderr.log` on Linux,
the equivalent on each platform. The `stderr_log_path` + `dup2`
redirect is gated for Windows (currently no-op) and is one of the
files the port will touch.

### Don't add abstractions for the port

The Windows port is a porting effort, not a refactor. If a function
already uses `std.c.getenv` and the rest of the file uses `std.posix`,
fix the immediate compile error — don't introduce a `platform_env.zig`
abstraction layer until at least two callers need it.
