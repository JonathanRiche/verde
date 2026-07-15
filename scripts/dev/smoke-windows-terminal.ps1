param(
  [string]$PrefixDir = "",
  [string]$CliPath = "",
  [string]$EvidenceDir = "",
  [ValidateRange(2, 60)]
  [int]$TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if (-not [string]::Equals($env:OS, "Windows_NT", [StringComparison]::OrdinalIgnoreCase)) {
  throw "The Windows terminal smoke must run on Windows."
}
if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
  $EvidenceDir = Join-Path ([IO.Path]::GetTempPath()) "verde-terminal-smoke"
} elseif (-not [System.IO.Path]::IsPathRooted($EvidenceDir)) {
  $EvidenceDir = Join-Path $RepoRoot $EvidenceDir
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$CliExe = $CliPath
if ([string]::IsNullOrWhiteSpace($CliExe)) {
  if (-not [string]::IsNullOrWhiteSpace($PrefixDir)) {
    if (-not [System.IO.Path]::IsPathRooted($PrefixDir)) {
      $PrefixDir = Join-Path $RepoRoot $PrefixDir
    }
    $PrefixDir = (Resolve-Path -LiteralPath $PrefixDir).Path
    $BuildCli = Join-Path $PrefixDir "bin\cli\verde.exe"
    $PackageCli = Join-Path $PrefixDir "bin\verde.exe"
    $CliExe = if (Test-Path -LiteralPath $BuildCli -PathType Leaf) { $BuildCli } else { $PackageCli }
  } else {
    $AdjacentCli = Join-Path $ScriptDir "bin\verde.exe"
    $CliExe = if (Test-Path -LiteralPath $AdjacentCli -PathType Leaf) {
      $AdjacentCli
    } else {
      Join-Path $env:LOCALAPPDATA "Programs\Verde\bin\verde.exe"
    }
  }
} elseif (-not [System.IO.Path]::IsPathRooted($CliExe)) {
  $CliExe = Join-Path (Get-Location).Path $CliExe
}
if (-not (Test-Path -LiteralPath $CliExe -PathType Leaf)) {
  throw "Windows terminal smoke CLI is missing: $CliExe"
}

function Invoke-VerdeJson {
  param([string[]]$Arguments)

  $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $StartInfo.FileName = $CliExe
  foreach ($Argument in $Arguments) {
    $StartInfo.ArgumentList.Add($Argument)
  }
  $StartInfo.WorkingDirectory = Split-Path -Parent $CliExe
  $StartInfo.UseShellExecute = $false
  $StartInfo.CreateNoWindow = $true
  $StartInfo.RedirectStandardOutput = $true
  $StartInfo.RedirectStandardError = $true

  $Process = New-Object System.Diagnostics.Process
  $Process.StartInfo = $StartInfo
  try {
    if (-not $Process.Start()) {
      throw "Failed to start verde $($Arguments -join ' ')."
    }
    $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
    $StderrTask = $Process.StandardError.ReadToEndAsync()
    if (-not $Process.WaitForExit(10000)) {
      $Process.Kill()
      if (-not $Process.WaitForExit(5000)) {
        throw "verde $($Arguments -join ' ') did not stop after forced termination."
      }
      throw "verde $($Arguments -join ' ') did not exit within 10 seconds."
    }
    if (-not $StdoutTask.Wait(1000) -or -not $StderrTask.Wait(1000)) {
      # The session daemon and ConPTY shell must not keep a foreground CLI
      # invocation alive by retaining inherited diagnostic pipe handles.
      throw "verde $($Arguments -join ' ') left redirected output handles open."
    }
    $ExitCode = $Process.ExitCode
    $Text = ([string]$StdoutTask.Result).Trim()
    $Diagnostics = ([string]$StderrTask.Result).Trim()
  } finally {
    $Process.Dispose()
  }
  if ($ExitCode -ne 0) {
    throw "verde $($Arguments -join ' ') failed with exit code ${ExitCode}: $Diagnostics $Text".Trim()
  }
  if ([string]::IsNullOrWhiteSpace($Text)) {
    throw "verde $($Arguments -join ' ') returned no JSON. Diagnostics: $Diagnostics"
  }
  try {
    $Payload = $Text | ConvertFrom-Json
  } catch {
    throw "verde $($Arguments -join ' ') returned invalid JSON: $Text. Diagnostics: $Diagnostics"
  }
  $ErrorProperty = $Payload.PSObject.Properties["error"]
  if ($null -ne $ErrorProperty -and $null -ne $ErrorProperty.Value) {
    throw "verde $($Arguments -join ' ') returned an error: $($ErrorProperty.Value | ConvertTo-Json -Compress)"
  }
  return $Payload
}

function Write-TerminalInput {
  param(
    [string]$SessionId,
    [string]$Text
  )

  $Response = Invoke-VerdeJson -Arguments @("session", "write", "--id", $SessionId, "--text", $Text, "--json")
  if ($Response.result.accepted -ne $true) {
    throw "The default shell rejected terminal input."
  }
}

function Wait-TerminalMarker {
  param(
    [string]$SessionId,
    [string]$Marker,
    [DateTime]$Deadline
  )

  do {
    $Screen = Invoke-VerdeJson -Arguments @("session", "screen", "--id", $SessionId, "--lines", "80", "--json")
    if ($Screen.result.running -ne $true) {
      throw "The default shell exited before producing marker '$Marker'."
    }
    if ([string]$Screen.result.text -and
        ([string]$Screen.result.text).IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      return
    }
    Start-Sleep -Milliseconds 50
  } while ([DateTime]::UtcNow -lt $Deadline)

  throw "Timed out waiting for the default shell to produce marker '$Marker'."
}

$StartedAt = [DateTime]::UtcNow
$Deadline = $StartedAt.AddSeconds($TimeoutSeconds)
$SessionId = "verde:smoke:terminal:{0}:{1}" -f $PID, [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$Created = $false
$Passed = $false
$Failure = $null
$ShellCommand = $null
$ShellPid = $null
$ShellKind = $null
$CleanupError = $null
$AliveBeforeInput = $false
$AcceptedFirstMarker = $false
$AliveAfterFirstMarker = $false
$AcceptedSecondMarker = $false

try {
  $Create = Invoke-VerdeJson -Arguments @(
    "session", "new",
    "--id", $SessionId,
    "--cwd", $env:USERPROFILE,
    "--cols", "80",
    "--rows", "24",
    "--json"
  )
  $Created = $true
  $ShellCommand = [string]$Create.result.session.command
  $ShellPid = $Create.result.session.pid

  # The regression exits in under half a second after its initial VT frame.
  # Sampling before the first write prevents echoed input from faking success.
  Start-Sleep -Milliseconds 750
  $Inspect = Invoke-VerdeJson -Arguments @("session", "inspect", "--id", $SessionId, "--json")
  if ($Inspect.result.session.running -ne $true) {
    throw "The default shell exited before input (exit_status=$($Inspect.result.session.exit_status), command=$ShellCommand)."
  }
  $AliveBeforeInput = $true

  $IsCommandPrompt = $ShellCommand -match '(?i)(^|[\\/\s])cmd(?:\.exe)?(?:\s|$)'
  $ShellKind = if ($IsCommandPrompt) { "cmd" } else { "powershell" }
  if ($IsCommandPrompt) {
    Write-TerminalInput -SessionId $SessionId -Text ("echo verde-terminal-%VERDE%-ready" + "`r")
  } else {
    Write-TerminalInput -SessionId $SessionId -Text ("Write-Output ('verde-terminal-' + `$env:VERDE + '-ready')" + "`r")
  }
  Wait-TerminalMarker -SessionId $SessionId -Marker "verde-terminal-1-ready" -Deadline $Deadline
  $AcceptedFirstMarker = $true

  Start-Sleep -Milliseconds 500
  $Inspect = Invoke-VerdeJson -Arguments @("session", "inspect", "--id", $SessionId, "--json")
  if ($Inspect.result.session.running -ne $true) {
    throw "The default shell exited after the first marker (exit_status=$($Inspect.result.session.exit_status))."
  }
  $AliveAfterFirstMarker = $true
  $CwdMarker = "verde-terminal-still-running-cwd-$env:USERPROFILE"
  if ($IsCommandPrompt) {
    Write-TerminalInput -SessionId $SessionId -Text ("echo verde-terminal-still-running-cwd-%CD%" + "`r")
  } else {
    Write-TerminalInput -SessionId $SessionId -Text ("Write-Output ('verde-terminal-still-running-cwd-' + (Get-Location).Path)" + "`r")
  }
  Wait-TerminalMarker -SessionId $SessionId -Marker $CwdMarker -Deadline $Deadline
  $AcceptedSecondMarker = $true
  $Passed = $true
} catch {
  $Failure = $_.Exception.Message
} finally {
  if ($Created) {
    try {
      $null = Invoke-VerdeJson -Arguments @("session", "kill", "--id", $SessionId, "--json")
    } catch {
      $CleanupError = $_.Exception.Message
      if ($Passed) {
        $Passed = $false
        $Failure = "Terminal interaction passed but cleanup failed: $CleanupError"
      }
    }
  }
}

$Evidence = [ordered]@{
  schema_version = 1
  passed = $Passed
  started_at_utc = $StartedAt.ToString("o")
  duration_ms = [int]([DateTime]::UtcNow - $StartedAt).TotalMilliseconds
  shell_kind = $ShellKind
  shell_command = $ShellCommand
  shell_pid = $ShellPid
  remained_alive_before_input = $AliveBeforeInput
  child_environment_verified = $AcceptedFirstMarker
  accepted_first_marker = $AcceptedFirstMarker
  remained_alive_after_first_marker = $AliveAfterFirstMarker
  working_directory_verified = $AcceptedSecondMarker
  accepted_second_marker = $AcceptedSecondMarker
  failure = $Failure
  cleanup_error = $CleanupError
}
$EvidencePath = Join-Path $EvidenceDir "terminal-smoke.json"
$Evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8

if (-not $Passed) {
  throw "Windows terminal smoke failed: $Failure (evidence: $EvidencePath)"
}
Write-Host "Windows terminal smoke passed; evidence: $EvidencePath"
