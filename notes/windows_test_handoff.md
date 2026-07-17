# Verde Windows preview test handoff

This handoff is for the first x86-64 Windows preview. It is a preview release,
not a declaration of stable Windows support. The purpose of this round is to
find native Windows defects in rendering, WebView2, ConPTY, provider process
management, local named-pipe control, paths, and packaging before the port is
called stable.

## What the tester should receive

- `verde-<version>-windows-x86_64.zip`
- `verde-<version>-windows-x86_64.zip.sha256`
- the signing state from the person who produced the archive: either a valid
  Authenticode identity or an explicit statement that this is an unsigned
  Windows preview

After extraction, the package manifest and `SHA256SUMS.txt` are authoritative
for its contents. The desktop entry point is `app\Verde.exe`; the console entry
point is `bin\verde.exe`. Runtime DLLs must remain beside the executable that
uses them. Do not move individual EXEs out of the extracted tree.

The preview intentionally uses the installed Microsoft Edge WebView2 Evergreen
Runtime. `WebView2Loader.dll` is included but is not the browser runtime.

## Test machine prerequisites

- Windows 11 x86-64 is the primary target. Windows 10 22H2 is a compatibility
  target and should be reported explicitly if used.
- Install or repair the Microsoft Edge WebView2 Evergreen Runtime if Windows
  does not already provide it.
- PowerShell 7 is preferred for terminal tests. Windows PowerShell and `cmd.exe`
  are also required test profiles.
- For provider tests, install only the provider CLIs you normally trust and
  use. Record their versions and installation method. Native Windows must work
  without WSL; WSL is a separate optional-profile test.
- The Claude provider additionally requires Node.js 18+ on `PATH`, because Verde
  runs its packaged provider bridge (`share\verde\provider_bridge.mjs`) through
  Node to reach Anthropic's Agent SDK. The native Claude CLI alone is not
  sufficient; Claude can succeed in PowerShell while Verde reports `FileNotFound`
  if Node is absent. Other providers and the app shell do not need Node.

No SDL, SDL_ttf, Vulkan, Rust, Zig, Bun, CMake, or Visual Studio install should
be needed to run the extracted preview. Node is a runtime prerequisite only for
the Claude provider, as noted above.

## Windows local control, hooks, and firewall policy

`verde live` and the persistent-session daemon use per-user Windows named
pipes (`\\.\pipe\verde-live-*` and `\\.\pipe\verde-sessionizer-*`). They do
not listen on TCP and need no Windows Firewall rule. The pipe ACL is restricted
to the current logon session and LocalSystem; a remote or different-logon
client must be rejected.

Two provider runtimes do use local TCP: Codex app-server defaults to
`ws://127.0.0.1:4500`, and OpenCode defaults to `http://127.0.0.1:4096`.
Keep both on loopback. A firewall product may still prompt for the provider
executable or enterprise policy may block local traffic; do not work around
that by binding to `0.0.0.0` or adding a public/LAN inbound rule. Permit only
local-loopback traffic as organizational policy allows, or report the policy
block and ask the administrator.

Codex and Claude have project-local and global managed hook installers. On
Windows they generate `.ps1` scripts and invoke them with
`powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File`.
That command-scoped `Bypass` does not change any saved user or machine
execution policy. Group Policy, AppLocker, WDAC, or endpoint security can still
block the unsigned generated script; do not weaken machine policy to make an
optional hook pass. Amp has a global plugin installer. OpenCode and Cursor are
supported chat providers but do not currently have managed hook installers.

## Verify and launch

Open PowerShell in the directory containing the ZIP:

```powershell
$zip = Get-Item .\verde-*-windows-x86_64.zip
$expected = ((Get-Content "$($zip.FullName).sha256" -Raw) -split '\s+')[0]
$actual = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected.ToLowerInvariant()) { throw "ZIP checksum mismatch" }
Expand-Archive $zip.FullName -DestinationPath '.\Verde preview' -Force
```

Use the package's own checksum file to verify every extracted payload:

```powershell
$root = Get-ChildItem '.\Verde preview' -Directory | Select-Object -First 1
foreach ($line in Get-Content (Join-Path $root 'SHA256SUMS.txt')) {
  if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Bad checksum line: $line" }
  $path = Join-Path $root $Matches[2].Replace('/', '\')
  $actual = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Matches[1]) { throw "Checksum mismatch: $($Matches[2])" }
}
```

If the preview is signed, verify both entry points before launch:

```powershell
Get-AuthenticodeSignature (Join-Path $root 'app\Verde.exe') | Format-List
Get-AuthenticodeSignature (Join-Path $root 'bin\verde.exe') | Format-List
```

For an unsigned preview, confirm the ZIP hash through a trusted channel before
accepting the Windows warning. Then run:

```powershell
& (Join-Path $root 'bin\verde.exe') version --json
& (Join-Path $root 'bin\verde.exe') capabilities --json
& (Join-Path $root 'bin\verde.exe') state path --json
& (Join-Path $root 'app\Verde.exe')
```

To establish the same `Verde.Desktop` identity for the Start Menu shortcut and
the running GUI, install the preview for the current user and launch it from
Start:

```powershell
& (Join-Path $root 'install.ps1')
```

The script defaults to `%LOCALAPPDATA%\Programs\Verde`; it does not require
administrator elevation. Keep the extracted tree until testing is complete so
the original checksums remain available for comparison.

Before opening a terminal pane, run the packaged default-shell smoke. It waits
for the same persistent-session backend used by the GUI, sends two markers, and
fails if PowerShell or `cmd.exe` exits early. Its JSON evidence path is printed
at completion:

```powershell
& (Join-Path $root 'test-terminal.ps1')
```

Repeat one launch after moving the extracted directory below a path containing
spaces and non-ASCII text, for example `C:\Users\<you>\Desktop\Verde 预览`.

## Required physical-Windows matrix

Record pass, fail, or not-tested for every row. A failure in one row does not
block testing the others unless continuing would risk data loss.

### Package and desktop shell

1. The ZIP extracts without case-collision or missing-file errors.
2. `app\Verde.exe` opens without a console window; `bin\verde.exe` behaves as a
   normal console program with correct JSON and exit codes.
3. The app uses D3D12 and opens without a separately installed Vulkan runtime.
4. Fonts, icons, embedded images, and all panels render; no area is black,
   top-left-only, clipped, or scaled twice.
5. Resize, maximize, minimize/restore, rapid close/reopen, sleep/wake, and
   lock/unlock do not hang or lose state.
6. Repeat at 100%, 125%, 150%, and 200% display scale. If possible, move the
   live window between mixed-DPI monitors and report both scales.
7. Test Intel or AMD graphics and record the GPU/driver. A VM GPU result is
   useful as a separate run.

### Native text and desktop integration

1. Composer, browser address bar, rename/import modals, and other text fields
   support caret placement, drag selection, double/triple click, Shift+arrows,
   Home/End, select/copy/cut/paste, Backspace, and Delete.
2. Enter emoji, CJK, a dead-key sequence, and AltGr text. Test an IME composition
   flow if an IME is available.
3. Paste text and at least two images into one prompt. Test PNG and a screenshot
   copied as DIB/DIBV5.
4. Drag a file into the app. Import a project with the native folder picker.
5. Open a project in the configured editor, reveal a file in Explorer, and open
   an external URL. Use paths containing spaces, emoji/CJK, a long path, a
   drive root, and a UNC path where available.
6. Trigger a completed-agent notification and confirm the toast opens under the
   Verde identity rather than silently disappearing.

### WebView2 browser pane

1. Open, close, and reopen a browser pane repeatedly.
2. Navigate to a non-ASCII URL/title, then test back, forward, reload, address
   editing, inspector, clipboard, a download, an external link, and a popup.
3. Tile/split and resize browser panes at each tested DPI. Move the window to a
   monitor with another DPI while the pane is visible.
4. Open every Palette overlay (command palette, menus, settings, dialogs) over
   the browser region. The native child view must hide/clip instead of covering
   the overlay.
5. Move focus among browser content, address bar, transcript, terminal, and app
   shortcuts. Each key must be handled once; IME text must not duplicate.
6. If possible, separately test WebView2 present, absent, and repair-needed.
   Missing runtime must produce an actionable, non-crashing error.

### ConPTY terminal and persistence

1. Create panes using PowerShell 7, Windows PowerShell, and `cmd.exe`; use a WSL
   profile only as an additional test.
2. Verify Unicode/emoji/wide characters, Ctrl+C, Ctrl+Break where applicable,
   multiline and bracketed paste, mouse reporting, scrolling, and resize.
3. Run a full-screen TUI and each installed provider TUI. Resize splits and the
   top-level window while alternate-screen content is active.
4. Produce at least 10 MiB of output and confirm the pane remains responsive
   and tail replay is not truncated incorrectly.
5. Close only the GUI while a terminal command remains active. Relaunch
   `app\Verde.exe`; the pane must reconnect to the daemon with usable screen/tail
   state. Also test explicit pane close and process stop.
6. Run `Get-Process Verde,verde -ErrorAction SilentlyContinue` after cleanup.
   Report orphan daemon/provider/shell processes instead of force-killing them
   before evidence is collected.

### Providers and project workflows

For Codex, Claude, OpenCode, and Cursor, mark either pass or an explicit
unsupported/not-installed reason. For every claimed provider:

1. Confirm GUI-launch PATH discovery and a missing-install error.
2. Send a text prompt; observe streaming, command rows, approvals, completion,
   and an error path.
3. Send more than one image if the provider supports local images. Unsupported
   image input must fail visibly rather than disappear.
4. Cancel an active turn, restart the provider, and close the app during a send.
   Check for orphan process trees.
5. Repeat from a project path containing spaces and non-ASCII text.

Create a `verde.yml` test project containing structured `argv`,
`command_windows`, and a restartable process. Confirm PowerShell semantics,
stop/restart cleanup, PowerShell hook installation, and a hook notification.
In a disposable project, run `verde integrations list`, `doctor`, and the
Claude/Codex installers; inspect the generated `.ps1`, and compare
`Get-ExecutionPolicy -List` before and after invocation to confirm Verde did not
persist a policy change. If organizational policy blocks the hook, record that
explicitly while continuing the provider chat tests.
If Herdr is used, verify native Windows OpenSSH discovery while commands sent to
a Unix remote host retain POSIX quoting.

### Offline and live CLI

With the app closed, run the offline commands and save their JSON:

```powershell
$verde = Join-Path $root 'bin\verde.exe'
& $verde version --json
& $verde capabilities --json
& $verde state path --json
& $verde state projects --json
& $verde state panes --project current --json
& $verde state threads --project current --json
& $verde completion powershell
```

With the app running, wait for `live status` and then exercise the read-only
surface:

```powershell
& $verde live status --json
& $verde live capabilities --json
& $verde live projects --json
& $verde live active --json
& $verde live panes --project current --json
& $verde live threads --project current --json
& $verde live terminals --project current --json
& $verde live browser status --json
& $verde live palette list --json
& $verde live processes --json
```

`live capabilities --json` must report `windows_named_pipe` in
`ipc.transport`. None of the live commands should cause a Windows Firewall
prompt. A prompt from Codex or OpenCode belongs to that provider's separate
loopback listener, not Verde live IPC.

Use deterministic pane IDs to run the terminal split/write/move/close smoke in
`AGENTS.md`. Test `verde session attach`, resize the console, send Ctrl+C, and
force one error path; the console mode and UTF-8 code page must be restored.
Check JSON bodies for `ok: false` even when the process exit code is zero.

If a second Windows user account is available, attempt to connect to the live
and sessionizer named pipes from that account. Access must be denied. App exit
and stale endpoint recovery must not hang.

### Persistence and recovery

1. Import/rename/archive projects, create chat/browser/terminal splits, change
   settings, quit cleanly, and relaunch. Confirm state survives.
2. Relaunch after an intentional app termination and confirm the SQLite state
   is readable and persistent terminals recover.
3. Preserve user data while replacing the preview with a newer or older build;
   report migration or downgrade failures. Never send the state database
   without first checking it for private data.

## Bug report template

Create one report per distinct defect. Attach screenshots/video when visual or
input timing matters, and include the smallest safe log excerpt.

```text
Title:
Severity: crash/data-loss/blocking/major/minor/cosmetic
Area: package/rendering/DPI/input/WebView2/terminal/provider/CLI/IPC/path/integration/state

Verde version:
ZIP SHA-256:
Signature status and signer:
Windows edition, version, and OS build:
Physical machine or VM:
CPU/GPU and graphics-driver version:
Display scales and monitor arrangement:
Shell/terminal host:
WebView2 runtime version:
Provider name/version/install method (if relevant):
Project path shape (redacted, but note spaces/CJK/emoji/long/UNC):

Steps to reproduce:
1.
2.
3.

Expected:
Actual:
Reproduction rate:
Regression from another build:
Workaround:

Command output / exit code (redact tokens and prompt content):
Relevant log excerpt (redact tokens, paths if sensitive, and prompt content):
Screenshot/video:
Crash dump or Windows Event Viewer entry:
```

Use `bin\verde.exe state path --json` to locate the authoritative state/pref
directory. Runtime diagnostics are below its `logs` directory. Never include
API keys, credentials, complete prompts/transcripts, clipboard contents, or an
unreviewed state database in a report.

Routine diagnostics record provider categories, status, paths, and content
lengths rather than raw provider responses or user input. The developer-only
`VERDE_DUMP_OPENCODE_PROVIDERS` override deliberately writes an upstream
provider payload to a separate file; do not enable or share that file during
ordinary testing.

## Completion report

Return the filled pass/fail/not-tested matrix, all bug reports, and a short
summary containing:

- configurations tested (OS/GPU/DPI/shells/providers);
- blockers that prevented rows from running;
- orphan processes or handle/resource symptoms;
- whether the build is suitable for another preview only, or is ready
  to advance toward signed installer/stable-release validation.
