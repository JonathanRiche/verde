# Windows onboarding gotchas

Status: internal Windows preview. Chat, browser, Codex, Claude, and the native
terminal were validated through `0.1.36-internal-20260711` on Windows 11
x86-64. `0.1.37-internal-20260711` adds terminal responsiveness improvements
and still needs its VM confirmation pass.

This is a staging note for future Windows onboarding. It records the setup and
diagnostic details that were easy to miss during the first VM validation pass.
It is not a replacement for `windows_test_handoff.md` or final user-facing
installation documentation.

## VM file transfer

- On the Omarchy host, `~/Windows` is shared into the Windows VM as the
  `Shared` folder on the Windows desktop.
- Put the Windows ZIP and its `.sha256` file in `~/Windows`. The VM cannot see
  files elsewhere on the Linux host.
- Docker does not need to be restarted after copying a file. Refresh Explorer
  or reopen `Shared` if a newly copied artifact is not immediately visible.
- Extract the ZIP before running anything. Do not launch executables or
  `install.ps1` from inside Explorer's compressed-folder view.
- Use a normal local directory such as `Desktop\sandbox` for provider/workspace
  tests. The shared directory is best treated as artifact transport rather than
  as the test project itself.

## Install and update

The package has two entry points and both must remain in the installed tree:

- `app\Verde.exe`: GUI-subsystem desktop application.
- `bin\verde.exe`: console CLI and session-daemon executable.

Do not move either executable out of the package by itself. Runtime DLLs and
`share\verde\provider_bridge.mjs` are resolved relative to the installed tree.

For a current-user install, close Verde, open PowerShell in the extracted
package root, and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Notes:

- Administrator elevation is not required or recommended. The default install
  root is `%LOCALAPPDATA%\Programs\Verde`.
- Updating does not normally require an uninstall. Close the running app and
  run the newer package's `install.ps1`.
- `-ExecutionPolicy Bypass` above is scoped to that process; it does not change
  the saved user or machine policy.
- Launch the installed Start Menu shortcut after installation instead of
  continuing to launch the copy in the extracted directory.
- Windows Search/Start may retain an old shortcut icon briefly. Verify the
  installed version and executable before treating a stale search icon as an
  application-code regression.

Verify the installed build with:

```powershell
& "$env:LOCALAPPDATA\Programs\Verde\bin\verde.exe" version --json
```

When troubleshooting, record this output first. Several early preview failures
look identical in the UI but were already fixed in later packages.

## PATH changes and GUI launches

A provider command working in one PowerShell window does not guarantee that a
Start Menu application can resolve it.

- Install and authenticate provider CLIs from a regular, non-administrator
  PowerShell session whenever possible.
- Persist additions in the Windows **user PATH**. A temporary assignment such
  as `$env:PATH += ...` affects only that PowerShell process and its children;
  Verde launched from Start will not inherit it.
- Fully close and reopen Verde after installing a runtime or changing PATH.
- If a new PowerShell sees the command but Start-launched Verde still does not,
  sign out/in or restart the VM so Explorer receives the updated environment.
- Use `Get-Command` to capture the actual command type and executable path:

```powershell
Get-Command codex, claude, node -ErrorAction SilentlyContinue |
  Format-List Name, CommandType, Source, Path
```

Command shims (`.cmd`/`.bat`) and native `.exe` files are not interchangeable
at the Windows process boundary. Onboarding diagnostics should always record
which kind was found.

## Windows terminal architecture

The Windows terminal is a hybrid native stack; “ConPTY” and “Ghostty” describe
different layers rather than competing implementations:

- Microsoft ConPTY owns the Windows pseudoconsole and process I/O.
- Verde compiles Ghostty's `ghostty-vt` Zig module directly for VT parsing,
  terminal state, keyboard encoding, and render-state generation. There is no
  separate `libghostty` DLL and Verde does not use Ghostty's window or GPU
  renderer.
- Verde's Palette/SDL GPU path draws the Ghostty render state into the desktop
  workspace.

Terminal sessions live in Verde's session daemon so a shell can survive a GUI
restart. The GUI sends input and tails output over the authenticated local
session protocol; ConPTY itself remains daemon-owned.

## Codex prerequisite

Install Codex CLI and authenticate it before opening a Codex thread:

```powershell
codex --version
codex login
```

The Windows Codex distribution tested here is a native `codex.exe`. Verde
starts `codex app-server` from that executable. A successful `codex --version`
from a regular PowerShell plus a full Verde restart is the minimum smoke check.

## Claude has two separate prerequisites

`claude --version` succeeding is necessary but is not sufficient for Verde's
Claude chat provider.

1. The native Claude Code CLI must be installed, on PATH, and authenticated.
2. Node.js 18 or newer must also be on PATH.

Verde currently runs its bundled
`share\verde\provider_bridge.mjs` through Node, then that bridge uses
Anthropic's TypeScript Agent SDK and the local Claude Code runtime. Anthropic's
native Claude installer can provide `claude.exe` without installing Node, so it
is possible for Claude to work in PowerShell while Verde still shows
`FileNotFound`.

Check both independently:

```powershell
claude --version
node --version
```

If Node is missing, install the LTS release and then fully restart Verde:

```powershell
winget install --id OpenJS.NodeJS.LTS -e
```

Anthropic Agent SDK reference:
<https://code.claude.com/docs/en/agent-sdk/quickstart>

The tested native Claude installer places the CLI under
`%USERPROFILE%\.local\bin`; Verde adds that common directory to its provider
search path. If Claude was installed elsewhere, persist that directory in the
user PATH rather than only modifying the current terminal.

## Recognizing the failure signatures

### Prompt remains in the composer and `Send failed` appears

This means Verde could not start the send. The retained prompt is intentional
so it is safe to retry after fixing the prerequisite.

For builds through 0.1.32, a common cause was the Windows session daemon
exiting before its named pipe was created. The 0.1.33 fix explicitly passes the
desktop environment to `bin\verde.exe __session-daemon`, allowing it to resolve
`APPDATA`, `LOCALAPPDATA`, and `USERPROFILE`.

### Claude produces a brown `System / FileNotFound` row

If the runtime log also contains:

```text
failed to load Claude models: FileNotFound
```

and contains no later `claude.runBridge spawning ...` line, the failure occurs
before Claude Code is invoked. In 0.1.33 this specifically identified an
unresolved `node` executable.

### Stale or unexpected application icon

Confirm the installed version and reinstall the current package before
debugging icon resources. Windows Search can cache an older shortcut icon even
after the application binary has changed.

### Terminal pane is black except for a caret

Leave Verde running and collect diagnostics before closing the pane. A visible
caret only proves that the terminal renderer is alive; it does not prove that
the ConPTY session is still attached to a shell.

Two independent startup/liveness bugs produced this symptom in early previews.
The first let output-reader EOF override the child process's real liveness and
recreated stopped wrappers repeatedly. The second let the detached session
daemon inherit unusable standard handles when starting ConPTY, so PowerShell
exited cleanly before a usable prompt appeared. The fixes make the child
process handle authoritative, retain worker completion diagnostics, add
restart backoff, and explicitly replace the daemon's detached standard handles
before launching ConPTY. The complete shell/write/read path was confirmed in
the Windows VM with 0.1.36.

Version 0.1.37 also starts a short display-rate polling window as soon as input
is accepted (not only after output is observed), caps redundant tail RPCs from
high-rate SDL events, and wakes the ConPTY writer with a Win32 event instead of
checking its input queue every millisecond.

When updating a terminal-related preview, close Verde before running
`install.ps1`. If a stale daemon survives, stop Verde processes and reinstall:

```powershell
Get-Process Verde -ErrorAction SilentlyContinue | Stop-Process -Force
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

## Collecting diagnostics

Reproduce the problem once, leave Verde open, and then run the collector from
the VM's `Shared` directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\collect-verde-windows-diagnostics.ps1
```

The report is written back to:

```text
Shared\verde-windows-diagnostics.txt
```

That makes it immediately readable on the host at:

```text
~/Windows/verde-windows-diagnostics.txt
```

The authoritative state/log directory can also be found with:

```powershell
& "$env:LOCALAPPDATA\Programs\Verde\bin\verde.exe" state path --json
```

The useful Windows logs are below that pref path:

- `logs\verde.stderr.log`
- `logs\last-crash.log`

For terminal failures, the current collector also reports the session PID,
whether Windows still sees that process, terminal screen lengths, and the
session daemon's input-writer/output-reader status and raw Win32 error codes.

The current collector deeply probes Codex and the Verde session daemon, but it
does not yet prove Node or Claude resolution. Until it is extended, include the
`Get-Command` and `--version` output from the PATH section above with Claude
reports.

## Product/documentation follow-ups before broad onboarding

- Decide whether Windows packages should bundle a pinned Node runtime or a
  standalone compiled Claude bridge. Until then, Node 18+ must be an explicit
  Windows runtime prerequisite.
- Replace the raw Claude `FileNotFound` transcript row with an actionable
  message naming the missing Node runtime.
- Extend `collect-verde-windows-diagnostics.ps1` to probe `node`, `claude`, and
  the packaged provider bridge in addition to Codex.
- Update `windows_test_handoff.md`: it currently says Node is not required to
  run the preview, which conflicts with the current Claude Agent SDK bridge.
- Keep the installed GUI-to-console mapping covered: `app\Verde.exe` must spawn
  the sibling `bin\verde.exe` for the persistent session daemon.
