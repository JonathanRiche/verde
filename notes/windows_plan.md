# Verde Desktop Windows Port Plan

Status: implemented for internal preview; physical Windows validation pending
Last reviewed: 2026-07-10
Target: Windows 11 x86-64 first, with Windows 10 22H2 as a compatibility target if WebView2, SDL3, and ConPTY smoke tests pass.

Implementation mapping and remaining external gates are recorded in
`notes/windows_implementation_audit.md`; the teammate runbook and bug template
are in `notes/windows_test_handoff.md`. “Implemented” here means the first
usable preview is ready to build and hand off, not that the stable-release
physical Windows matrix has been pre-emptively marked as passing.
The audit and implementation-plan sections below intentionally preserve the
original pre-port baseline language so the rationale and acceptance criteria
remain reviewable; use the implementation mapping for current status.

## Executive summary

Verde is not starting from zero on Windows. The codebase already has:

- a native WebView2 backend and an SDL Win32 `HWND` handoff;
- Windows branches in the Zig build;
- SDL3 Windows artifacts available through `zsdl`;
- HLSL shader source files;
- Windows-aware pieces in Ghostty VT, `fff`, environment handling, and keybinds;
- provider transports that mostly use portable TCP/HTTP and `std.process` APIs.

Those pieces do not yet form a buildable or usable Windows product. The main blockers are architectural rather than cosmetic:

1. The embedded terminal and terminal-session daemon are POSIX implementations built around `forkpty`, file descriptors, signals, process groups, `/proc`, and Unix sockets. Windows needs a ConPTY backend and Windows process-tree management.
2. Live control and session IPC expose only Unix-domain sockets. Windows needs a local transport, preferably current-user named pipes, while preserving the existing newline-delimited JSON protocol.
3. Providers and managed processes still contain unguarded POSIX types/calls, Unix shell commands, and Unix-only executable discovery.
4. Palette can only supply SPIR-V or Metal shader packages. Windows needs committed DXIL/DXBC packages for SDL_GPU's D3D12 backend, or an explicit Vulkan prerequisite as a short-lived bootstrap.
5. The build mentions Windows but does not acquire/include WebView2, package `WebView2Loader.dll`, provide SDL3_ttf, install all runtime DLLs, or create a Windows release artifact.
6. Paths, clocks, notifications, folder picking, clipboard images, editor/file-manager launch, hooks, and CLI terminal handling have Windows gaps.

The recommended strategy is to make platform boundaries explicit, get a GUI-only Windows skeleton compiling early, then implement process/IPC and ConPTY underneath the existing provider-neutral and terminal-emulation layers. Do not fork the application into a separate Windows UI. Palette, state, database, workspace layout, transcript rendering, provider request contracts, and Ghostty VT parsing should remain shared.

## Audit scope and current state

This plan was produced from a repository-wide survey of the desktop build graph, approximately 79,000 lines under `packages/desktop/src`, the shared Palette/SDL packages, vendored `fff` and Ghostty build support, the root `mise` tasks, release scripts, npm launcher packages, and GitHub release workflows.

### Subsystem readiness

| Area | Current Windows state | Port implication |
| --- | --- | --- |
| SDL window/events | Mostly portable; Win32 `HWND` retrieval exists in `main.zig` | Validate DPI, IME, text input, drag/drop, and window lifecycle on real Windows |
| Palette UI | Shared render/layout code is suitable | Add D3D12-compatible precompiled shaders and fix portable clocks |
| Browser | WebView2 Zig/C++ backend exists but is not packaged or tested | Finish SDK acquisition, loader/runtime policy, DPI/focus, overlay, and teardown testing |
| Persistence | SDL pref path + SQLite are conceptually portable | Verify zqlite/SQLite build, locking, UTF-8/WTF-8 paths, migration, and backups |
| Embedded terminal | Windows is explicitly unsupported (`SESSION_SUPPORTED`) | Implement ConPTY; keep Ghostty VT parser/rendering shared |
| Persistent terminal daemon | Entirely POSIX and Unix-socket based | Split transport/process backend and add named-pipe + ConPTY daemon |
| Live CLI IPC | Unix socket only | Add named-pipe client/server and endpoint discovery |
| CLI interactive attach | `termios`, `ioctl`, `poll`, POSIX stdio | Add Windows console input/output/raw-mode implementation |
| Providers | Protocol code is largely portable; lifecycle code is not | Centralize spawning, executable lookup, time, cancellation, and process-tree teardown |
| Managed processes | Hard-coded `/bin/sh -lc` | Define Windows command semantics and launch through the platform process layer |
| File search (`fff`) | Upstream code contains Windows branches | Build and runtime verification still required; package `fff_c.dll` correctly |
| Config/path discovery | XDG/HOME-centric | Add Known Folder/`LOCALAPPDATA`/`APPDATA` behavior and preserve overrides |
| Native integration | macOS/Linux implementations only | Add Windows picker, ShellExecute/reveal, notifications, clipboard image, and hook scripts |
| Packaging/release | Linux/macOS only | Add Windows dependency staging, ZIP/MSIX or installer, signing, npm package, and CI |

### Concrete code blockers found

The first compilation pass should expect failures in these places rather than treating them as isolated surprises:

- `packages/desktop/src/terminal/terminal.zig` and `terminal/sessionizer.zig` expose `std.posix` types, `forkpty`, `ioctl`, `fcntl`, `waitpid`, signals, `/proc`, and Unix sockets throughout their implementations.
- `packages/desktop/src/ipc/server.zig` and the live client in `cli.zig` construct `std.Io.net.UnixAddress` directly.
- `cli.zig` has Unix-only raw terminal, window-size, polling, stdin/stdout, and PID code.
- `providers/claude.zig`, `providers/opencode.zig`, and `providers/cursor.zig` contain POSIX process-group types or calls. Codex has some Windows guards but still uses POSIX polling and clocks in shared paths.
- `state.zig` uses POSIX PIDs/signals for background tasks and hard-codes `/bin/sh -lc` for `verde.yml` processes.
- `process_env.zig` calls POSIX `access(X_OK)`, appends only Unix/macOS PATH locations, uses `HOME`, and does not implement Windows `PATHEXT` resolution for `.exe`, `.cmd`, and `.bat`.
- many shared files call `clock_gettime`, `nanosleep`, `gettimeofday`, or `getpid`. Zig 0.16 provides cross-platform `std.Io.Clock`, `std.Io.sleep`, and process APIs and these should replace shared libc calls.
- `config.zig`, `provider_hooks.zig`, `herdr.zig`, and several state helpers assume `HOME` and `~/` semantics.
- `utils.zig` has no Windows implementation for folder picking, Explorer/browser launch, file reveal, terminal-editor launch, notifications, or clipboard images.
- Claude's `providerBridgePathAlloc` cannot find the executable on Windows because its local executable-path helper only implements Linux/macOS. Use `std.process.executablePathAlloc`.
- project hooks are generated only as `#!/bin/sh` files. They cannot be the default integration on native Windows.
- `packages/palette/src/renderer.zig` embeds HLSL but does not create a Windows shader package. `packagesForTarget(.windows)` currently returns SPIR-V, effectively requiring Vulkan and bypassing the normal D3D12 path.
- `packages/desktop/build.zig` invokes `sh -c`, assumes a host-native Cargo output without an explicit target, links SDL libraries without installing their Windows DLLs, and includes `WebView2.h` without establishing an SDK include path.
- the release workflow, npm optional dependencies, launcher map, and package scripts contain no Windows target.
- runtime logging intentionally skips stderr redirection on Windows and returns PID 0, while timestamp functions still use POSIX clocks.

## Product and architecture decisions

Make these decisions before broad implementation so the port does not accumulate incompatible one-off fixes.

### 1. Supported shell semantics

Recommended policy:

- The default embedded terminal launches PowerShell 7 (`pwsh.exe`) when present, then Windows PowerShell (`powershell.exe`) as the fallback.
- `verde.yml` should support a structured `argv` form and optional platform-specific commands, for example `command_windows` and `command_unix`. Keep the existing Unix string behavior unchanged.
- If a Windows process has only a string command, run it through the selected Windows shell with documented semantics. Do not silently feed Bash syntax to `cmd.exe`.
- Treat WSL as an optional profile/integration, not as the foundation of Windows support. Native Codex/Claude/OpenCode/Cursor and native project paths must work without WSL.

### 2. Local IPC transport

Use current-user Windows named pipes:

- live server: `\\.\pipe\verde-live-<user-identity>`;
- session daemon: `\\.\pipe\verde-sessionizer-<user-identity>`;
- retain the current newline-delimited JSON request/response payloads and protocol version;
- create an ACL limited to the current user and local system;
- store endpoint metadata/version in the SDL pref directory when useful, but never use a world-accessible unauthenticated TCP port.

Introduce a transport interface so Unix sockets remain unchanged on Linux/macOS. The protocol handlers should not know which transport accepted the stream.

### 3. Terminal backend

Use Windows ConPTY, not winpty and not an external terminal window:

- create input/output pipes and `CreatePseudoConsole`;
- launch the shell/agent with `STARTUPINFOEXW` and `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`;
- resize with `ResizePseudoConsole`;
- feed output to the existing Ghostty VT stream and render state;
- preserve the session-daemon model so terminal panes survive GUI restarts;
- own launched processes in Windows Job Objects and define explicit graceful-stop/force-stop behavior;
- replace Unix foreground process-group inspection with a Windows capability model. Where foreground-child identity is unavailable, return `null` rather than fabricating POSIX semantics.

The reusable boundary should be operations such as create, attach, detach, read, write, resize, stop, snapshot, and process summary. `terminal.zig` should render/emulate; platform files should own PTY/process handles.

### 4. Windows executable layout

Prefer two installed entry points sharing the same Zig modules:

- `Verde.exe`: Windows GUI subsystem application, no surprise console window;
- `verde.exe`: console subsystem CLI for `state`, `live`, `session`, completions, and scripting.

This avoids the poor command-prompt behavior of a single GUI-subsystem CLI and the flashing console window of a single console-subsystem desktop executable. If maintaining two artifacts proves too costly, validate an explicit console attach/stdio strategy before choosing one executable.

### 5. Rendering backend

Ship D3D12 as the supported Windows renderer:

- compile the solid/text/image shaders to committed DXIL (and optionally DXBC fallback) artifacts;
- give each pipeline the correct entry point and SDL shader format;
- add deterministic shader regeneration/validation tooling;
- make the initial Windows smoke prove D3D12 works on a clean GitHub runner and physical Windows machine.

Vulkan may be allowed behind a development option, but requiring a separately installed Vulkan runtime is not an acceptable release dependency.

## Implementation plan

### Phase 0: establish a Windows build lane and feature inventory

Goal: obtain a repeatable native Windows compile with intentional stubs, so every subsequent change has fast feedback.

Tasks:

1. Add a `windows-latest` compile job and a developer task such as `mise run build-windows` that uses the repository's supported build entry point.
2. Pin a native x86-64 toolchain: Zig 0.16, Rust stable/MSVC, Bun/Node, CMake/Ninja, Windows SDK, and MSVC C++ tools.
3. Add explicit build feature flags for `terminal_backend`, `local_ipc`, and Windows integrations. Default them correctly by OS; use stubs only in the bootstrap lane.
4. Move platform-only declarations into platform files or compile-time-selected structs so Windows does not analyze POSIX constants/types.
5. Replace shared direct libc time/sleep/PID calls with a small portable platform/runtime module using Zig 0.16 `std.Io.Clock`, `std.Io.sleep`, and the appropriate process API. `zigdoc` should remain the source of truth while implementing this.
6. Replace local `/proc/self/exe` and `_NSGetExecutablePath` copies with `std.process.executablePathAlloc(io, allocator)` unless a platform-specific reason is documented.
7. Add compile-only tests for `main.zig`, browser contract, provider modules, Palette, and the CLI on Windows. Do not require GUI execution in this first gate.

Exit criteria:

- the Windows job compiles the application and unit-test artifacts with terminal/live IPC temporarily disabled or stubbed;
- no shared module has an unguarded POSIX type solely because it is imported by Windows;
- Linux and macOS builds remain green.

### Phase 1: make the build and renderer genuinely native

Goal: launch the shared Palette UI on Windows with correct text and GPU rendering.

Tasks:

1. Create a Windows dependency staging script/module that provides:
   - SDL3 headers/import library/runtime DLL;
   - SDL3_ttf headers/import library/runtime DLL and all required runtime dependencies;
   - WebView2 SDK headers and the architecture-matched `WebView2Loader.dll`;
   - the built `fff_c.dll` and matching import library;
   - `provider_bridge.mjs` and required notices/licenses.
2. Use the existing `zsdl` Windows prebuilt only where its pinned version matches the runtime. Add an equally deterministic SDL3_ttf source or binary rather than depending on a developer's global PATH.
3. Make Cargo build `fff-c` for the actual Zig target/profile and teach the Zig build where the MSVC/GNU import library and DLL are. Verify Unicode paths and watcher behavior in `fff`, not just link success.
4. Add Windows DXIL/DXBC shader artifacts and select them in `ShaderFormat.defaultForTarget` and `ShaderSource.packagesForTarget`.
5. Replace Palette and desktop profiling `clock_gettime` calls with the portable clock module.
6. Add a Windows resource file with the Verde icon, version metadata, requested execution level, long-path awareness, and Per-Monitor-V2 DPI awareness.
7. Validate SDL logical size, drawable size, and display scale at 100%, 125%, 150%, and mixed-monitor DPI. The root Palette layout and D3D framebuffer must remain in the same coordinate space.
8. Test SDL text input/IME, surrogate pairs/emoji, clipboard text, drag/drop, keyboard modifiers, mouse capture, resizing, minimize/restore, and clean GPU teardown.

Exit criteria:

- `Verde.exe` opens a correctly rendered, resizable Palette UI using D3D12 on a clean Windows machine;
- fonts and embedded images load from packaged paths;
- no external SDL/Vulkan installation is required;
- DPI changes do not produce top-left-only rendering, oversized UI, or WebView misalignment.

### Phase 2: finish and harden WebView2

Goal: make browser panes reach feature parity with the native child-view contract.

Tasks:

1. Add WebView2 SDK acquisition to the build and ship the correct fixed loader DLL. Detect a missing Evergreen runtime with an actionable in-app error and installer link.
2. Audit the existing UTF-8/UTF-16 helpers in `windows_webview2.cpp`; allocate space for the trailing NUL and cover non-ASCII URLs/titles/messages in tests.
3. Use a Verde-specific user-data directory below the Windows local app-data/pref path rather than relying on an opaque process default.
4. Validate COM apartment initialization, asynchronous callback lifetime, event queue locking, destruction while initialization/eval is pending, and repeated open/close cycles.
5. Convert Palette pane bounds to the coordinate space expected by the child `HWND` and WebView2 controller. Re-test after live DPI changes and moving between monitors.
6. Verify native-child z-order around menus, modals, command palette, split panes, maximize/minimize, and browser hide/show. Hide or clip the child view whenever a Palette overlay must own that region.
7. Verify focus transitions: click browser, address bar, transcript, terminal, shortcuts, tab traversal, and IME. Do not route duplicate SDL keyboard input into WebView2.
8. Complete browser features: navigation/title/load events, JS eval, bridge policy, JSON host messages, back/forward/reload, inspector, context menus, clipboard, file downloads, external links, and popup policy.
9. Add a Windows browser smoke script analogous to the macOS WebView readiness checks.

Exit criteria:

- browser panes resize and tile correctly at all tested DPI levels;
- keyboard/mouse/clipboard behavior works without duplicate input;
- bridge restrictions match Linux/macOS;
- missing runtime, navigation failures, and teardown failures are user-visible and non-crashing.

### Phase 3: add a shared platform process layer and port providers

Goal: make all four GUI chat providers usable before the terminal port is complete.

Create platform-neutral helpers for:

- environment lookup and mutation;
- executable resolution including Windows case-insensitivity and `PATHEXT`;
- child spawn with cwd, environment, stdio, and hidden-window options;
- graceful cancel, forced kill, and process-tree ownership via Job Objects;
- monotonic/realtime clocks and sleeps;
- current process/executable identity;
- temporary/cache/config locations.

Then migrate providers:

1. Codex: launch `codex.exe`/shim, connect to app-server over loopback, replace POSIX `poll`, stop the owned tree, test login/error/approval/stream/images/import.
2. OpenCode: remove unguarded `pgid`/signals, launch and stop `opencode serve` through the process layer, replace `nanosleep`, and use a real temp path.
3. Claude: replace POSIX process-group state, locate `node.exe` and packaged `provider_bridge.mjs`, stop the Node tree reliably, and verify SDK resolution from a GUI launch environment.
4. Cursor: guard/remove `setpgid`, resolve `agent.exe` or supported shims, launch ACP without a console window, and preserve cancellation/error reporting.
5. Ensure `.cmd`/`.bat` provider shims are launched correctly. Do not pass them directly to `CreateProcessW` as if they were PE executables.
6. Test text-only prompts, multiple images where supported, streaming deltas, command rows, approvals, interruption, provider restart, authentication errors, and app shutdown during a send.

Exit criteria:

- Codex, Claude, OpenCode, and Cursor can each start, stream a prompt, cancel, and shut down without orphan processes;
- missing CLI/runtime messages are specific and actionable;
- a non-ASCII project path works for every provider that claims Windows support.

### Phase 4: port live control and non-interactive CLI

Goal: restore Verde's automation surface using named pipes.

Tasks:

1. Extract the live JSON protocol handler from Unix transport ownership in `ipc/server.zig`.
2. Implement current-user named-pipe listener/client modules with bounded message sizes, connection deadlines, clean shutdown wakeup, and same-user ACLs.
3. Keep `verde live ... --json` response bodies and exit-code meanings compatible across platforms.
4. Replace socket-path environment assumptions with a generic endpoint identifier. Continue accepting `VERDE_LIVE_SOCKET` on Unix; introduce/document a transport-neutral variable such as `VERDE_LIVE_ENDPOINT`.
5. Port CLI PID/time/output code and ensure stdout/stderr are UTF-8-safe in Windows Terminal, PowerShell, and `cmd.exe`.
6. Keep offline `verde state` commands independent of SDL window startup and verify database access while the app is closed/open.
7. Add PowerShell completion. Existing bash/zsh/fish generation can remain for Git Bash/WSL but is not sufficient as the native Windows completion story.

Exit criteria:

- the read-only live/state command list in `AGENTS.md` passes from PowerShell with `--json`;
- a second user session cannot connect to the pipe;
- app exit and stale endpoint cleanup do not hang.

### Phase 5: implement ConPTY terminals and persistent sessions

Goal: reach parity for embedded terminal panes, including survival across GUI restarts.

Tasks:

1. Refactor `terminal.zig` so terminal emulation/rendering is independent of the PTY implementation. Move the existing POSIX session into `terminal/platform/posix.zig`.
2. Add `terminal/platform/windows_conpty.zig` with UTF-16-safe process launch, overlapped pipe I/O, resize, write, exit-status capture, and handle cleanup.
3. Move session-daemon protocol handling away from Unix-address ownership and add the named-pipe transport.
4. Run the session daemon as a detached console/helper process. Keep ConPTY and child Job Object handles in that daemon so closing `Verde.exe` does not terminate persistent sessions.
5. Define the equivalent of attach/detach/tail offsets, bounded replay, resize repaint kick, stop, snapshot, and idle shutdown. Preserve existing JSON methods where possible.
6. Implement shell selection and profiles: `pwsh`, Windows PowerShell fallback, `cmd`, explicit WSL profile, and provider TUI commands.
7. Map keyboard input, bracketed paste, mouse reporting, resize, OSC title/notification handling, Unicode/emoji/wide characters, and Ctrl+C/Ctrl+Break semantics.
8. Replace Unix process-group/process-tree inspection with Job Object/process APIs. Clearly mark unsupported foreground-process details in the CLI capability response.
9. Add Windows implementations for interactive `verde session attach`: console mode save/restore, resize events, input polling, Ctrl+C forwarding, and guaranteed restoration after errors.
10. Stress test large output, full-screen TUIs, split panes, 24-hour sessions, GUI restart/reconnect, daemon crash/revive, and rapid create/close cycles.

Exit criteria:

- PowerShell, cmd, Codex TUI, Claude TUI, OpenCode TUI, and Cursor TUI render and accept input in a pane;
- sessions persist across GUI restart and reattach without corrupted alternate-screen state;
- resizing and paste work; closing a pane or stopping a process leaves no daemon/child leak;
- the pane/terminal live-control smoke test passes on Windows.

### Phase 6: port desktop integrations and managed workflows

Goal: remove remaining Unix-only UX gaps.

Tasks:

1. Paths/config:
   - state/cache under SDL pref path or `%LOCALAPPDATA%\Verde`;
   - config under `%APPDATA%\Verde\verde.json` with an environment override;
   - use Windows temp APIs and Known Folder APIs;
   - expand `%USERPROFILE%`, `~`, drive roots, and UNC paths deliberately;
   - normalize comparisons without corrupting display spelling; test case-insensitive duplicate project detection.
2. Native shell integration:
   - `IFileDialog` folder picker;
   - `ShellExecuteExW` for Explorer/default browser/editors;
   - `SHOpenFolderAndSelectItems` for reveal;
   - known install locations and PATH resolution for Cursor/VS Code/Zed where applicable.
3. Clipboard:
   - keep SDL for text;
   - add Win32 `OpenClipboard` handling for PNG/DIB/DIBV5 image paste with size limits and no clipboard-content logging.
4. Notifications: add Windows App SDK toast support or a documented WinRT toast implementation with app identity/shortcut setup. A silent no-op is acceptable only for the first preview, not stable release.
5. Hooks:
   - generate PowerShell hook scripts and provider configuration commands on Windows;
   - invoke `verde.exe notify` through the named-pipe endpoint;
   - quote paths safely and support spaces/non-ASCII;
   - preserve existing shell hooks on Unix.
6. Managed processes:
   - implement the selected Windows shell/structured argv rules;
   - replace PID-file/signal liveness checks with process handles or durable task IDs;
   - use Job Objects for stop/restart and child cleanup;
   - document portability rules for `verde.yml`.
7. Herdr/SSH:
   - use Windows OpenSSH when present;
   - use Windows local storage paths while retaining POSIX quoting for commands executed on Unix remote hosts;
   - distinguish local Windows shell quoting from remote Bash quoting in types and helpers.
8. Validate project import, rename/archive, file search, editor open, browser inspector handoff, image attachments, settings, and all command-palette actions.

Exit criteria:

- a user can install Verde, import a workspace with the native picker, open it in an editor/Explorer, run providers/processes, paste images, receive notifications, and restart with state intact;
- spaces, emoji, CJK, long paths, drive-letter paths, and UNC paths have targeted tests.

### Phase 7: package, sign, release, and update distribution

Goal: produce a self-contained, trustworthy Windows artifact.

Recommended first artifact: signed x86-64 ZIP plus a signed installer (MSIX if app identity/notifications fit cleanly; otherwise WiX/MSI or Inno Setup). Do not block the first internal preview on Microsoft Store submission.

Package contents should include:

- `Verde.exe` and `verde.exe`;
- SDL3, SDL3_ttf, `fff_c`, WebView2 loader, and their licensed runtime DLLs;
- `provider_bridge.mjs` and only the Node-side files actually required at runtime;
- embedded fonts/assets or their installed equivalents;
- licenses/notices, README, and optional PowerShell completion;
- no PDBs in the public runtime archive, but archive symbols separately for crash triage.

Tasks:

1. Add `scripts/release/package-windows.*` and a local install/smoke script that work from PowerShell without Bash.
2. Add Authenticode signing for executables, DLLs produced by Verde, and installer. Timestamp signatures.
3. Add `build-windows` to `.github/workflows/release.yml`, upload artifacts, include them in checksums, and require it before publish.
4. Add `packages/npm/verde-windows-x64`, update optional dependencies, package assembly, and `bin/verde.js` runtime mapping.
5. Decide WebView2 distribution policy: Evergreen bootstrap/runtime prerequisite versus Fixed Version runtime. The loader DLL alone is not the browser runtime.
6. Test install, upgrade, downgrade behavior, uninstall with user data preserved, SmartScreen/signature display, and execution from paths containing spaces.
7. Document prerequisites, provider installation, PowerShell execution policy implications for hooks, firewall behavior (loopback provider servers), config/state locations, and diagnostics.

Exit criteria:

- a clean Windows VM can install and launch Verde with no developer tools and no manually installed SDL/Vulkan components;
- signatures verify; uninstall is clean; user state survives upgrade;
- npm and GitHub release installs launch the correct binary.

### Phase 8: parity, reliability, and release sign-off

Run the same behavior contract on Linux, macOS, and Windows. Add a Windows-specific manual matrix where OS integration cannot be automated.

Automated gates:

- Windows native ReleaseSafe build;
- unit tests for platform abstractions, quoting, executable resolution, paths, named-pipe framing/ACL behavior, WebView string conversion, and ConPTY lifecycle;
- CLI offline/live JSON smoke tests;
- provider mock/integration tests for text, multi-image, streaming, cancel, and error paths;
- repeated browser and terminal create/resize/close tests;
- package-content and dependency scan that rejects missing or unexpected DLLs;
- clean-VM installer smoke.

Manual gates on physical Windows hardware:

- Intel/AMD graphics and at least one VM GPU path;
- 100/125/150/200% scaling and mixed-DPI multi-monitor movement;
- Windows 11 plus Windows 10 22H2 if it remains supported;
- Windows Terminal, PowerShell 7, Windows PowerShell, cmd, and optional WSL profile;
- IME composition, dead keys, AltGr, emoji, clipboard text/image, drag/drop;
- sleep/wake, lock/unlock, minimize/restore, rapid shutdown, and app crash/restart;
- WebView2 Evergreen present, absent, and repair-needed states;
- provider installs via common Windows methods and GUI-launch PATH behavior;
- Defender/SmartScreen check on signed release bits.

Stable-release definition of done:

- all four providers pass their supported Windows contract or are explicitly disabled with a clear reason;
- chat, terminal, browser, persistence, live CLI, project processes, picker/editor launch, clipboard, and notifications work;
- no known orphan process, handle leak, cross-user IPC access, or data-loss bug;
- release/install/upgrade/uninstall documentation and recovery instructions are complete.

## Suggested code organization

The port will be easier to review if OS behavior is centralized instead of adding `if (builtin.os.tag == .windows)` throughout large files.

```text
packages/desktop/src/platform/
  mod.zig
  clock.zig
  paths.zig
  process.zig
  ipc.zig
  notifications.zig
  picker.zig
  shell_open.zig
  clipboard.zig
  windows/
    process.zig
    named_pipe.zig
    notifications.zig
    picker.zig
    shell_open.zig
    clipboard.zig

packages/desktop/src/terminal/platform/
  posix.zig
  windows_conpty.zig
```

Keep protocol/state types in shared files. Platform implementations should return the same app-level errors and capability values so UI code does not need OS-specific branching.

## Delivery sequence and pull-request boundaries

Prefer small vertical PRs that always leave existing platforms working:

1. portable clock/executable/environment/path helpers;
2. Windows compile lane with explicit stubs;
3. dependency staging + D3D12 Palette shell;
4. WebView2 completion;
5. provider process abstraction and one provider at a time;
6. named-pipe live CLI;
7. ConPTY local session;
8. named-pipe persistent session daemon and interactive attach;
9. managed processes/hooks/native integrations;
10. packaging/npm/signing/release matrix.

Each PR should include Windows tests for its new boundary and run the normal Linux/macOS build/tests. Avoid combining the first ConPTY implementation, named-pipe server, and packaging work in one change; failures would be too difficult to isolate.

## Primary risks and mitigations

| Risk | Mitigation |
| --- | --- |
| ConPTY/session persistence grows into a second terminal implementation | Share Ghostty VT, render state, protocol, replay, and pane models; isolate only OS handles/process operations |
| Native WebView child covers Palette overlays | Make visibility/clipping/z-order an explicit browser presentation contract and test every overlay |
| D3D12 shader mismatch produces a blank UI | Commit generated shader binaries, validate pipeline formats at build/test time, keep a debug shader regeneration command |
| Provider shims behave differently (`.exe` vs `.cmd`) | Centralize `PATHEXT` resolution and shell-wrapper behavior; add fixture executables/scripts |
| Job Objects accidentally kill persistent terminals when GUI exits | Session daemon, not GUI, must own persistent ConPTY jobs; integration-test GUI restart |
| Named pipes permit cross-user control | Current-user ACL, bounded framing, protocol versioning, and negative security tests |
| Windows path normalization breaks project identity | Preserve original display path, derive a normalized comparison key, test drive/UNC/case/Unicode/long paths |
| Release works only on developer machine | Deterministic dependency staging and clean-VM smoke before every preview |
| WSL becomes an accidental hidden dependency | Native Windows is the acceptance target; expose WSL only as an optional terminal/profile feature |
| Dual GUI/CLI binaries drift | Build both from shared modules with a tiny entrypoint distinction and run protocol tests against both |

## First usable preview scope

An internal preview should not wait for every polish item, but it must be honest about capability. Minimum preview:

- signed/un-signed developer ZIP with all DLLs;
- shared Palette UI on D3D12;
- WebView2 browser;
- persistence and workspace import (native picker or typed path);
- Codex plus at least one second provider through GUI chat;
- named-pipe read-only live/status commands;
- one functional ConPTY PowerShell pane, even if persistence/advanced process inspection is still flagged experimental;
- diagnostics containing paths/lengths/status only, never clipboard or credential content.

Do not call the port stable until persistent terminals, process cleanup, all claimed providers, packaging/signing, DPI/IME, and clean-machine tests pass.
