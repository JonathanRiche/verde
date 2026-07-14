# Windows port implementation audit

Status: internal-preview implementation complete; physical Windows validation pending
Audited: 2026-07-10
Target: Windows 11 x86-64, with Windows 10 22H2 retained as a test target

This document maps `notes/windows_plan.md` to the implementation that is ready
for teammate testing. It deliberately separates evidence obtainable from the
Arch development host from behavior that can only be signed off on Windows.
The preview is not a stable Windows release until the physical-machine matrix
in `WINDOWS-TESTING.md` passes.

## Delivery status

- The Windows application and compile-only test artifacts cross-link as x86-64
  PE images from Arch.
- The preview contains separate GUI and console entry points, adjacent runtime
  DLLs, the provider bridge, licenses, dependency provenance, checksums, and a
  deterministic package manifest.
- Native Windows runtime paths are implemented for D3D12, WebView2, named-pipe
  IPC, ConPTY terminals, provider/process ownership, shell integration,
  notifications, clipboard images, paths, hooks, and PowerShell completion.
- The package is an internal-preview ZIP. Signing is supported when both
  release secrets are configured, but tag and local tester ZIPs may explicitly
  be unsigned and must be authenticated by their adjacent SHA-256 files.
- DPI/IME/GPU, WebView2 behavior beyond automated startup readiness, ConPTY,
  provider, and clean-machine claims remain external validation because
  Windows executables cannot be run on this Arch host.

## Phase 0 — build lane and platform boundaries

Implemented:

- `.github/workflows/windows-smoke.yml` installs pinned Zig, Rust, Bun, Python,
  MSVC, and Windows SDK tooling, then compiles tests, builds, verifies, and
  packages on `windows-latest`.
- `mise run build-windows` is the supported GNU cross-build entry point on
  Linux/macOS. `scripts/dev/build-windows.ps1` is the native MSVC entry point.
- `terminal_backend`, `local_ipc`, and `windows_integrations` are explicit build
  options. A Windows install build rejects a disabled production backend.
- `src/platform/runtime.zig`, `paths.zig`, `process.zig`, `ipc.zig`, and
  `live_endpoint.zig` centralize portable time, PID, executable identity,
  process ownership, paths, and local transport behavior.
- Windows compile-only roots cover the application, terminal/ConPTY boundary,
  provider modules, browser contract, Palette, and console CLI. Foreign tests
  are linked but never accidentally invoked through Wine or binfmt.

Arch-verifiable evidence:

- Native ReleaseSafe build passes through `mise run build`.
- A full `x86_64-windows-gnu` ReleaseSafe link produces both PE entry points.
- The foreign `test-compile` step links three x86-64 Windows test executables.

## Phase 1 — native dependencies, resources, and D3D12

Implemented:

- `scripts/windows-dependencies.json` pins SDL3, SDL3_ttf, WebView2, and DXC
  inputs with SHA-256 provenance. Python and PowerShell bootstrappers stage
  headers, GNU/MSVC import libraries, runtime DLLs, notices, and a manifest.
- The vendored Rust `fff-c` build receives the actual Windows Cargo target; the
  matching import library and `fff_c.dll` are installed beside both entry
  points. The cross-host lane builds the real Rust DLL with the pinned Rust
  toolchain and rejects compile-only stub markers before packaging.
- Palette selects committed DXIL packages for Windows D3D12. Vertex, solid,
  text, and image shaders are separate, and
  `scripts/dev/compile-windows-shaders.py --check` validates deterministic DXC
  output against the committed bytes.
- Both PEs embed a Verde icon, version metadata, `asInvoker`, long-path
  awareness, and Per-Monitor-V2 DPI awareness.
- Package verification rejects missing runtime DLLs, unexpected DLLs, CEF or
  development artifacts, incorrect PE architecture/subsystems, missing
  resources, or a broken provider-bridge layout.

External validation:

- Actual D3D12 device creation, text/image rendering, resize, teardown, and
  100/125/150/200% or mixed-monitor DPI behavior.
- File search/watching against real drive, long, Unicode, and UNC paths.

## Phase 2 — WebView2

Implemented:

- The build stages the pinned WebView2 SDK and architecture-matched loader DLL.
  The runtime policy is Evergreen prerequisite, and missing-runtime errors name
  the Microsoft installer/repair URL.
- `windows_webview2.cpp` owns COM initialization, asynchronous environment and
  controller callbacks, callback-safe destruction, locked event delivery,
  UTF-8/UTF-16 conversion, native child bounds, focus, navigation, title/load
  events, eval results, bridge messages, history actions, popup policy, and
  teardown.
- WebView2 data is rooted under Verde's per-user local-data path.
- The controller supports the shared bundled DOM inspector through evaluated
  JavaScript and the restricted host bridge; it does not advertise an
  unrelated Chromium developer-tools API.
- Browser visibility and bounds are synchronized with Palette overlays and
  layout ownership, including modal/menu suppression.
- `smoke-windows-webview2.ps1` launches the native GUI on Windows, polls browser
  state through the console CLI, requires WebView2 native-child initialization,
  creates a disposable workspace so the native child has a real browser-pane
  layout, and requires successful `about:blank` navigation plus JavaScript eval.
  The smoke verifies zero workspaces before that setup, then cleans up only the
  process and temporary directory it created and records structured evidence.
  It also preserves the pref-directory runtime log when present without treating
  an absent log as a browser failure. This is startup readiness, not a substitute
  for physical input/DPI validation.

External validation:

- Child-HWND z-order, focus, IME, downloads, clipboard, external links, popup
  behavior, live DPI movement, repeated open/close, and Evergreen
  present/absent/repair-needed states.

## Phase 3 — providers and process ownership

Implemented:

- The shared process layer supports cwd, environment, hidden-window launch,
  current process identity, Windows Job Objects, graceful stop, forced
  process-tree cleanup, and explicit `.cmd`/`.bat` shell handling.
- `process_env.zig` augments GUI-launch PATH, resolves case-insensitively with
  `PATHEXT`, and treats PE executables and command shims according to Windows
  `CreateProcessW` rules.
- Codex, Claude, OpenCode, and Cursor migrated off unguarded POSIX lifecycle
  behavior. Claude resolves packaged `provider_bridge.mjs` relative to either
  installed entry point; cancellation uses descendant-tree cleanup.
- Provider-neutral prompt images remain mapped through the shared send request,
  including multiple images and the legacy single-image compatibility field.
- Structured provider hooks avoid shell interpolation and have Windows quoting
  fixtures.
- Normal persistent diagnostics retain categories, status, paths, and byte
  lengths without recording provider error bodies, prompts, transcript text,
  clipboard contents, browser input, or provider thread/session identifiers.
  The separately requested `VERDE_DUMP_OPENCODE_PROVIDERS` file remains an
  explicit developer opt-in and is not part of routine runtime logging.

Arch-verifiable evidence:

- Provider-hook, executable/path, platform-process, Claude bridge, Codex,
  OpenCode, Cursor, and Herdr-focused unit tests pass.
- The provider bridge bundles successfully with Bun.

External validation:

- Authentication, GUI-launch PATH discovery, text/multi-image streams,
  approvals, errors, cancellation, restart, and orphan-tree checks against
  real Windows provider installations.

## Phase 4 — named-pipe live control and console CLI

Implemented:

- Protocol dispatch is independent from transport ownership. Unix sockets stay
  unchanged; Windows uses overlapped byte-mode named pipes with newline JSON,
  separately bounded requests and responses, deadlines, cancellation, shutdown
  wakeup, and stale-instance detection. Live transcript serialization performs
  a conservative response-size preflight and directs oversized callers to the
  offline transcript command instead of truncating JSON.
- Pipe ACLs grant access only to the current logon SID and LocalSystem, and
  reject remote clients. A different login or terminal session is not granted
  access merely because it has the same account owner SID.
- Clients open pipes with identification-only security quality of service,
  obtain the actual server PID from the connected handle, and require that
  process token's logon SID to match before sending a request. Session-daemon
  replacement trusts that authenticated peer PID rather than a PID supplied in
  JSON.
- `VERDE_LIVE_ENDPOINT` is the transport-neutral environment variable;
  `VERDE_LIVE_SOCKET` remains a Unix compatibility alias.
- Offline state and non-interactive live commands share the console-subsystem
  `bin\verde.exe`. JSON bodies and documented exit-code semantics are retained.
- Bash, zsh, fish, and native PowerShell completions cover the same static
  command tree.

External validation:

- PowerShell/cmd UTF-8 output and the complete live/state smoke surface.
- Negative cross-user pipe access, stale endpoint recovery, and shutdown under
  blocked or malicious clients.

## Phase 5 — ConPTY and persistent terminal sessions

Implemented:

- Windows UI terminals are daemon-owned sessions; the local `forkpty` fallback
  is never selected on Windows.
- `terminal/platform/windows_conpty.zig` creates pipes and a pseudoconsole,
  launches with `STARTUPINFOEXW`, assigns the child to a Job Object, resizes,
  reads/writes on cancellable worker operations, captures exit status, and
  closes every process/thread/pipe/pseudoconsole/job handle. Teardown always
  terminates the full job before closing the pseudoconsole, including when the
  direct shell has already exited, so descendants cannot strand cleanup.
- Shell selection prefers PowerShell 7, falls back to Windows PowerShell, then
  `cmd.exe`. Explicit argv profiles cover provider TUIs and optional WSL use.
- The existing Ghostty VT parser, render state, replay, input encoding,
  bracketed paste, mouse reporting, alternate-screen state, and resize
  protocol remain shared.
- Session RPC uses the same named-pipe transport and retains create, attach,
  detach, write, resize, tail, screen, kill, cleanup, replay bounds, snapshots,
  and idle shutdown. The daemon, rather than the GUI, owns persistent ConPTY
  jobs.
- Interactive `verde session attach` has a Windows console implementation that
  saves and restores input/output modes and UTF-8 code pages, forwards console
  control input, detects resize, and propagates attach failures.
- Unsupported POSIX-style foreground process-group detail is returned as absent
  rather than synthesized on Windows.

Arch-verifiable evidence:

- Terminal/session protocol tests pass natively.
- ConPTY and sessionizer Windows roots pass x86-64 GNU semantic analysis and
  link in the complete application/test build.

External validation:

- PowerShell/cmd/provider TUI input, 10 MiB output, Unicode/wide cells,
  Ctrl+C/Ctrl+Break, mouse/paste/resize, 24-hour stability, GUI restart and
  reattach, daemon recovery, and leak/orphan inspection.

## Phase 6 — Windows desktop integrations and workflows

Implemented:

- State/cache/config/temp paths use per-user Windows locations while preserving
  documented overrides. Path helpers handle drive roots, UNC, separators,
  case-insensitive identity, `~`, `%USERPROFILE%`, spaces, and non-ASCII text.
- Native C++ integration wraps `IFileDialog`, `ShellExecuteExW`,
  `SHOpenFolderAndSelectItems`, Explorer/default-browser/editor launch,
  DIB/DIBV5 clipboard image conversion, and process AppUserModelID setup.
- Toast notifications use the unpackaged WinRT API with `Verde.Desktop`; the
  per-user installer creates a Start Menu shortcut carrying the same property
  through the Windows property store.
- Windows PowerShell provider hooks call the console CLI through the generic
  named-pipe endpoint. User-controlled notification text is passed in the
  environment, not interpolated into PowerShell source. Claude/Codex generate
  `.ps1` hooks and use child-process `-ExecutionPolicy Bypass` without changing
  saved policy; enterprise script controls can still block the optional hook.
- `verde.yml` supports structured `argv`, `argv_windows`, `argv_unix`,
  `command_windows`, and `command_unix`; legacy Windows strings use documented
  PowerShell semantics. Managed processes use Job Objects for cleanup.
- Herdr discovers native Windows OpenSSH/PATHEXT executables while keeping
  remote Unix commands explicitly POSIX-quoted.

External validation:

- Picker, Explorer/editor launch, drag/drop, clipboard screenshots, toasts,
  project persistence/import/rename/archive, hooks, managed process restart,
  and Herdr against real Windows paths and OpenSSH.

## Phase 7 — package, signing, CI, and npm

Implemented:

- `scripts/release/package-windows.ps1` supports native Windows packaging and
  Authenticode. The cross-host Python packaging entry point produces the same
  deterministic preview layout from an Arch-built prefix without requiring
  PowerShell.
- The ZIP contains `app\Verde.exe` (GUI), `bin\verde.exe` (console), each DLL
  set, provider bridge, dependency manifests/licenses, install helper, tester
  handoff, implementation audit, manifest, signing notice, and per-file hashes.
- One build-version value is compiled into both executables and their Windows
  VERSIONINFO, written to `share\verde\BUILD_VERSION`, and required to match the
  requested package version. Skip-build packaging therefore cannot relabel a
  stale prefix.
- Package verification requires exact manifest and checksum coverage for every
  regular file, rejects duplicate or injected paths, and re-verifies the
  extracted ZIP tree.
- `install.ps1` performs a per-user install under
  `%LOCALAPPDATA%\Programs\Verde` and creates/verifies the Start Menu identity.
- Release CI has a Windows build/package job, signs and timestamps tags when
  both certificate secrets are configured, and otherwise publishes an
  explicitly unsigned ZIP. Publishing depends on the Windows job either way.
- `verde-windows-x64` is an npm optional dependency. The JavaScript launcher
  selects the GUI entry point for a no-argument desktop launch and the console
  entry point for CLI arguments. The npm assembler accepts
  `--platform windows-x64` for a Windows-preview package plus the root launcher;
  omitting the selector retains all-platform release assembly.
- Packaged Windows notes distinguish current-logon named-pipe IPC from the
  loopback-only Codex/OpenCode provider listeners, document firewall policy,
  PowerShell hook execution-policy behavior, and the hook/chat-provider support
  boundary.

External validation:

- Authenticode/SmartScreen display, actual install shortcut and toast identity,
  upgrade/downgrade/uninstall, clean VM launch, and npm installation on Windows.
- A stable MSI/MSIX/WiX/Inno artifact is intentionally deferred until those
  preview behaviors and certificate ownership are proven.

## Phase 8 — release gates

Automated gates available in the tree:

- native ReleaseSafe build and focused platform/provider/terminal tests;
- Windows native CI compile, linked test artifacts, dependency staging, package
  verification, extraction verification, WebView2 startup readiness with
  failure evidence, and artifact upload;
- deterministic shader regeneration check;
- package file/DLL allowlists, PE architecture/subsystem/resource checks,
  provider-bridge resolution, exact version-stamp validation, and complete
  manifest/checksum coverage with injected-file regressions;
- content-safe provider-diagnostic sentinel coverage;
- npm launcher/platform-selection and Windows payload-integrity tests, plus the
  provider bridge bundle check.

Still required from the Windows tester:

- every applicable row in `WINDOWS-TESTING.md`, including physical GPU/DPI/IME,
  browser child-window behavior, providers, persistent ConPTY sessions, IPC
  security, OS integration, recovery, and process/handle cleanup;
- exact bug reports using the included template;
- a final recommendation of internal-preview-only versus advancement toward a
  signed installer and stable-release validation.

## Release claim

This tree satisfies the plan's **first usable preview** scope. It does not yet
satisfy the plan's **stable-release definition of done**, because those gates
explicitly require Windows execution, physical hardware, installed providers,
signature reputation, and install/upgrade/uninstall evidence. Any failure in
that external matrix is a port bug to fix before stable release, not a reason to
reinterpret an untested row as passing.
