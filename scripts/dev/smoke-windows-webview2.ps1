param(
  [Parameter(Mandatory = $true)]
  [string]$PrefixDir,
  [string]$EvidenceDir = "",
  [ValidateRange(5, 300)]
  [int]$TimeoutSeconds = 45,
  [string]$StartUrl = "about:blank"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if (-not [string]::Equals($env:OS, "Windows_NT", [StringComparison]::OrdinalIgnoreCase)) {
  throw "The Windows WebView2 readiness smoke must run on Windows."
}
if (-not [System.IO.Path]::IsPathRooted($PrefixDir)) {
  $PrefixDir = Join-Path $RepoRoot $PrefixDir
}
$PrefixDir = (Resolve-Path -LiteralPath $PrefixDir).Path
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
  $EvidenceDir = Join-Path $RepoRoot ".zig-cache\windows-smoke\evidence"
} elseif (-not [System.IO.Path]::IsPathRooted($EvidenceDir)) {
  $EvidenceDir = Join-Path $RepoRoot $EvidenceDir
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$AppExe = Join-Path $PrefixDir "bin\Verde.exe"
$CliExe = Join-Path $PrefixDir "bin\cli\verde.exe"
foreach ($Path in @($AppExe, $CliExe)) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Windows WebView2 smoke executable is missing: $Path"
  }
}

function Invoke-VerdeCli {
  param(
    [string]$Executable,
    [string[]]$Arguments
  )

  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = $Executable
  foreach ($Argument in $Arguments) {
    $StartInfo.ArgumentList.Add($Argument)
  }
  $StartInfo.WorkingDirectory = Split-Path -Parent $Executable
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true

  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) {
      throw "Failed to start the Verde CLI readiness probe."
    }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(10000)) {
      $Process.Kill()
      $Process.WaitForExit()
      throw "Verde CLI command '$($Arguments -join ' ')' did not exit within 10 seconds."
    }
    return [pscustomobject]@{
      exit_code = $Process.ExitCode
      stdout = [string]$StdoutTask.Result
      stderr = [string]$StderrTask.Result
    }
  } finally {
    $Process.Dispose()
  }
}

function Invoke-VerdeJson {
  param(
    [string]$Executable,
    [string[]]$Arguments
  )

  $Probe = Invoke-VerdeCli -Executable $Executable -Arguments $Arguments
  if ($Probe.exit_code -ne 0) {
    throw "Verde CLI command '$($Arguments -join ' ')' failed with exit code $($Probe.exit_code): $($Probe.stderr.Trim())"
  }
  try {
    $Payload = $Probe.stdout | ConvertFrom-Json
  } catch {
    throw "Verde CLI command '$($Arguments -join ' ')' returned invalid JSON: $($_.Exception.Message)"
  }
  if ($Payload.ok -ne $true) {
    throw "Verde CLI command '$($Arguments -join ' ')' returned an error: $($Payload.error | ConvertTo-Json -Compress)"
  }
  return $Payload
}

$StartedAt = [DateTime]::UtcNow
$Deadline = $StartedAt.AddSeconds($TimeoutSeconds)
$AppProcess = $null
$AppStarted = $false
$AppPid = $null
$AppStdoutTask = $null
$AppStderrTask = $null
$AppStdout = ""
$AppStderr = ""
$LastPayload = $null
$LastBrowser = $null
$LastCliExitCode = $null
$LastCliStderr = ""
$Attempts = 0
$Passed = $false
$Failure = $null
$CleanupForced = $false
$GracefulCloseRequested = $false
$ProcessExitCode = $null
$CleanupError = $null
$PrefPath = $null
$StatePath = $null
$LegacyStatePath = $null
$PendingOpenPath = $null
$CleanStateVerified = $false
$InitialWorkspaceCount = $null
$SmokeWorkspacePath = Join-Path ([IO.Path]::GetTempPath()) ("verde-webview2-smoke-{0}" -f [Guid]::NewGuid().ToString("N"))
$SmokeWorkspaceCreated = $false
$BrowserOpenRequested = $false
$EvalRequested = $false
$LastWorkspaceCount = $null
$RuntimeLogSource = $null
$RuntimeLogDestination = Join-Path $EvidenceDir "verde.stderr.log"
$RuntimeLogPresent = $false
$RuntimeLogCopied = $false
$RuntimeLogCopyError = $null

try {
  $StatePathProbe = Invoke-VerdeCli -Executable $CliExe -Arguments @("state", "path", "--json")
  if ($StatePathProbe.exit_code -ne 0) {
    throw "Unable to discover Verde state paths (exit code $($StatePathProbe.exit_code)): $($StatePathProbe.stderr.Trim())"
  }
  try {
    $StatePaths = $StatePathProbe.stdout | ConvertFrom-Json
    $PrefPath = [string]$StatePaths.pref_path
    $StatePath = [string]$StatePaths.state_path
  } catch {
    throw "Unable to parse Verde state paths: $($_.Exception.Message)"
  }
  if ([string]::IsNullOrWhiteSpace($PrefPath) -or [string]::IsNullOrWhiteSpace($StatePath)) {
    throw "Verde state path discovery returned an empty pref_path or state_path."
  }
  $LegacyStatePath = Join-Path $PrefPath "state.json"
  $PendingOpenPath = Join-Path $PrefPath "herdr\pending-open.json"
  $RuntimeLogSource = Join-Path $PrefPath "logs\verde.stderr.log"
  $ExistingStateArtifacts = @(@($StatePath, $LegacyStatePath, $PendingOpenPath) | Where-Object {
      Test-Path -LiteralPath $_ -PathType Leaf
    })
  if ($ExistingStateArtifacts.Count -ne 0) {
    throw "The WebView2 smoke requires a clean empty Verde project state and will not delete user data. Run it in a disposable Windows account or clean CI runner. Existing state: $($ExistingStateArtifacts -join ', ')"
  }
  $CleanStateVerified = $true

  $Preflight = Invoke-VerdeCli -Executable $CliExe -Arguments @("live", "status", "--json")
  $LastCliExitCode = $Preflight.exit_code
  $LastCliStderr = $Preflight.stderr.Trim()
  if ($Preflight.exit_code -eq 0) {
    throw "A Verde live server is already running for this user. Close it before running the WebView2 smoke."
  }
  if ($Preflight.exit_code -ne 3) {
    throw "Unexpected preflight live-status exit code $($Preflight.exit_code): $($Preflight.stderr.Trim())"
  }

  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = $AppExe
  $StartInfo.WorkingDirectory = Split-Path -Parent $AppExe
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true

  $AppProcess = New-Object System.Diagnostics.Process
  $AppProcess.StartInfo = $StartInfo
  if (-not $AppProcess.Start()) {
    throw "Failed to start the Windows Verde GUI for WebView2 readiness."
  }
  $AppStarted = $true
  $AppPid = $AppProcess.Id
  $AppStdoutTask = $AppProcess.StandardOutput.ReadToEndAsync()
  $AppStderrTask = $AppProcess.StandardError.ReadToEndAsync()

  while ([DateTime]::UtcNow -lt $Deadline) {
    if ($AppProcess.HasExited) {
      throw "Verde exited before WebView2 readiness completed (exit code $($AppProcess.ExitCode))."
    }

    $Attempts += 1
    $Probe = Invoke-VerdeCli -Executable $CliExe -Arguments @("live", "status", "--json")
    $LastCliExitCode = $Probe.exit_code
    $LastCliStderr = $Probe.stderr.Trim()
    if ($Probe.exit_code -eq 0 -and -not [string]::IsNullOrWhiteSpace($Probe.stdout)) {
      try {
        $Payload = $Probe.stdout | ConvertFrom-Json
        $LastPayload = $Payload
        $Browser = if ($null -ne $Payload.result) { $Payload.result.browser } else { $null }
        $LastWorkspaceCount = if ($null -ne $Payload.result) { [int]$Payload.result.workspace_count } else { $null }
        if ($null -ne $Browser) {
          $LastBrowser = $Browser
          if (-not $SmokeWorkspaceCreated) {
            $InitialWorkspaceCount = $LastWorkspaceCount
            if ($InitialWorkspaceCount -ne 0) {
              throw "Clean project state check failed: runtime reported $InitialWorkspaceCount workspaces before smoke setup."
            }
            New-Item -ItemType Directory -Force -Path $SmokeWorkspacePath | Out-Null
            [void](Invoke-VerdeJson -Executable $CliExe -Arguments @("live", "workspace", "create", "--path", $SmokeWorkspacePath, "--json"))
            $SmokeWorkspaceCreated = $true
            [void](Invoke-VerdeJson -Executable $CliExe -Arguments @("live", "browser", "open", "--workspace", "current", "--url", $StartUrl, "--json"))
            $BrowserOpenRequested = $true
            continue
          }
          if ($LastWorkspaceCount -ne 1) {
            throw "Smoke workspace check failed: runtime reported $LastWorkspaceCount workspaces, expected 1."
          }
          if ($Browser.status -eq "Failed" -or $null -ne $Browser.last_error) {
            throw "WebView2 reported a startup failure: $($Browser.last_error)"
          }
          # WebView2 can already be on about:blank when the explicit navigation
          # arrives, so SourceChanged may leave url null. The address records the
          # requested target; the eval result below still proves document readiness.
          $BrowserLocationMatches = $Browser.url -eq $StartUrl -or $Browser.address -eq $StartUrl
          $BrowserReady = $BrowserOpenRequested -and
            $Browser.runtime_kind -eq "native_webview" -and
            $Browser.presentation_kind -eq "native_child_view" -and
            $Browser.runtime_initialized -eq $true -and
            $Browser.status -eq "Ready" -and
            $Browser.visible -eq $true -and
            $Browser.surface_suspended_for_layout -eq $false -and
            $null -ne $Browser.workspace_index -and
            $null -ne $Browser.pane_id -and
            $BrowserLocationMatches
          if ($BrowserReady -and -not $EvalRequested) {
            [void](Invoke-VerdeJson -Executable $CliExe -Arguments @("live", "browser", "eval", "--script", "true", "--json"))
            $EvalRequested = $true
            continue
          }
          $EvalCompleted = ([string]$Browser.last_eval_result) -eq "true"
          if ($BrowserReady -and $EvalRequested -and $EvalCompleted) {
            $Passed = $true
            break
          }
        }
      } catch {
        if ($_.Exception.Message.StartsWith("WebView2 reported a startup failure:") -or
            $_.Exception.Message.StartsWith("Clean project state check failed:") -or
            $_.Exception.Message.StartsWith("Smoke workspace check failed:") -or
            $_.Exception.Message.StartsWith("Verde CLI command '")) {
          throw
        }
        $LastCliStderr = "Invalid live status JSON: $($_.Exception.Message)"
      }
    }
    Start-Sleep -Milliseconds 250
  }

  if (-not $Passed) {
    $Summary = if ($null -ne $LastBrowser) {
      ($LastBrowser | ConvertTo-Json -Compress -Depth 8)
    } else {
      "no valid browser status received"
    }
    throw "Timed out after $TimeoutSeconds seconds waiting for WebView2 readiness; last status: $Summary; CLI: $LastCliStderr"
  }
} catch {
  $Failure = $_.Exception.Message
} finally {
  if ($null -ne $AppProcess) {
    try {
      if ($AppStarted -and -not $AppProcess.HasExited) {
        try {
          $GracefulCloseRequested = $AppProcess.CloseMainWindow()
        } catch {
          $GracefulCloseRequested = $false
        }
        if (-not $AppProcess.WaitForExit(5000)) {
          $CleanupForced = $true
          $AppProcess.Kill()
          $AppProcess.WaitForExit()
        }
      }
      if ($AppStarted -and $AppProcess.HasExited) {
        $ProcessExitCode = $AppProcess.ExitCode
      }
    } catch {
      $CleanupError = $_.Exception.Message
      if ($Passed) {
        $Passed = $false
        $Failure = "WebView2 readiness passed but GUI cleanup failed: $CleanupError"
      } elseif ([string]::IsNullOrWhiteSpace($Failure)) {
        $Failure = "GUI cleanup failed: $CleanupError"
      }
    }
    if ($null -ne $ProcessExitCode -and $null -ne $AppStdoutTask) {
      try { $AppStdout = [string]$AppStdoutTask.Result } catch {}
    }
    if ($null -ne $ProcessExitCode -and $null -ne $AppStderrTask) {
      try { $AppStderr = [string]$AppStderrTask.Result } catch {}
    }
    try { $AppProcess.Dispose() } catch {}
  }

  if (-not [string]::IsNullOrWhiteSpace($RuntimeLogSource)) {
    try {
      $RuntimeLogPresent = Test-Path -LiteralPath $RuntimeLogSource -PathType Leaf
      if ($RuntimeLogPresent) {
        Copy-Item -LiteralPath $RuntimeLogSource -Destination $RuntimeLogDestination -Force
        $RuntimeLogCopied = $true
      }
    } catch {
      # Browser readiness remains authoritative; diagnostics collection is
      # best-effort so a missing or locked log cannot turn a pass into a fail.
      $RuntimeLogCopyError = $_.Exception.Message
    }
  }
  if (Test-Path -LiteralPath $SmokeWorkspacePath -PathType Container) {
    Remove-Item -LiteralPath $SmokeWorkspacePath -Recurse -Force -ErrorAction SilentlyContinue
  }

  $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText((Join-Path $EvidenceDir "webview2-app.stdout.log"), $AppStdout, $Utf8NoBom)
  [System.IO.File]::WriteAllText((Join-Path $EvidenceDir "webview2-app.stderr.log"), $AppStderr, $Utf8NoBom)
  if ($null -ne $LastPayload) {
    $LastPayload | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $EvidenceDir "webview2-status.json") -Encoding UTF8
  }

  $Evidence = [ordered]@{
    schema_version = 1
    target = "x86_64-windows-msvc"
    scope = "automated-webview2-startup-readiness"
    passed = $Passed
    started_at_utc = $StartedAt.ToString("o")
    completed_at_utc = [DateTime]::UtcNow.ToString("o")
    timeout_seconds = $TimeoutSeconds
    attempts = $Attempts
    start_url = $StartUrl
    app_executable = $AppExe
    cli_executable = $CliExe
    pref_path = $PrefPath
    state_path = $StatePath
    clean_project_state = [ordered]@{
      verified_before_launch = $CleanStateVerified
      legacy_state_path = $LegacyStatePath
      pending_open_path = $PendingOpenPath
      initial_runtime_workspace_count = $InitialWorkspaceCount
      smoke_workspace_created = $SmokeWorkspaceCreated
      smoke_workspace_path = $SmokeWorkspacePath
      runtime_workspace_count = $LastWorkspaceCount
    }
    app_pid = $AppPid
    app_exit_code_after_cleanup = $ProcessExitCode
    last_cli_exit_code = $LastCliExitCode
    last_cli_stderr = $LastCliStderr
    browser = $LastBrowser
    cleanup = [ordered]@{
      graceful_close_requested = $GracefulCloseRequested
      forced = $CleanupForced
      process_exited = -not $AppStarted -or $null -ne $ProcessExitCode
      error = $CleanupError
    }
    runtime_diagnostics = [ordered]@{
      source = $RuntimeLogSource
      destination = $RuntimeLogDestination
      present_after_cleanup = $RuntimeLogPresent
      copied = $RuntimeLogCopied
      copy_error = $RuntimeLogCopyError
    }
    physical_validation = [ordered]@{
      performed = $false
      still_required = @(
        "D3D12 visual rendering",
        "100/125/150/200 percent and mixed-monitor DPI",
        "keyboard, pointer, clipboard, and IME input",
        "native-child focus and overlay z-order",
        "downloads, external links, and popup policy",
        "repeated open/close and physical GPU coverage"
      )
    }
    failure = $Failure
  }
  $Evidence | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $EvidenceDir "webview2-smoke.json") -Encoding UTF8
}

if (-not $Passed) {
  throw $Failure
}
Write-Host "Windows WebView2 startup readiness passed; evidence: $EvidenceDir"
