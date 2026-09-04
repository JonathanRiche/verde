param(
  [switch]$SkipBuild,
  [switch]$SkipLaunch,
  [string]$PrefixDir = "",
  [string]$Version = "0.0.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "Windows smoke version must not be empty."
}
if ([string]::IsNullOrWhiteSpace($PrefixDir)) {
  $PrefixDir = Join-Path $RepoRoot ".zig-cache\windows-smoke\prefix"
} elseif (-not [System.IO.Path]::IsPathRooted($PrefixDir)) {
  $PrefixDir = Join-Path $RepoRoot $PrefixDir
}
$EvidenceDir = Join-Path $RepoRoot ".zig-cache\windows-smoke\evidence"

& (Join-Path $ScriptDir "bootstrap-windows-deps.ps1") -Toolchain msvc | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "Windows dependency bootstrap failed with exit code $LASTEXITCODE."
}

if (-not $SkipBuild) {
  & (Join-Path $ScriptDir "build-windows.ps1") -CompileTests -SkipBootstrap -Version $Version
  if ($LASTEXITCODE -ne 0) {
    throw "Windows compile-only test build failed with exit code $LASTEXITCODE."
  }
  Remove-Item -LiteralPath $PrefixDir -Recurse -Force -ErrorAction SilentlyContinue
  & (Join-Path $ScriptDir "build-windows.ps1") -PrefixDir $PrefixDir -SkipBootstrap -Version $Version
  if ($LASTEXITCODE -ne 0) {
    throw "Windows smoke build failed with exit code $LASTEXITCODE."
  }
}

$RequiredFiles = @(
  "bin\verde-gui.exe",
  "bin\verde.exe",
  "bin\verde-daemon.exe",
  "bin\fff_c.dll",
  "bin\SDL3.dll",
  "bin\SDL3_ttf.dll",
  "bin\WebView2Loader.dll",
  "share\verde\provider_bridge.mjs"
)
$FileEvidence = @()
foreach ($RelativePath in $RequiredFiles) {
  $Path = Join-Path $PrefixDir $RelativePath
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Windows smoke output is missing $RelativePath"
  }
  $File = Get-Item -LiteralPath $Path
  $FileEvidence += [ordered]@{
    path = $RelativePath.Replace("\", "/")
    size = $File.Length
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  }
}

Remove-Item -LiteralPath $EvidenceDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$RuntimeEvidence = $null
$WebView2Evidence = $null
$TerminalEvidence = $null
if (-not $SkipLaunch) {
  $VerdeExe = Join-Path $PrefixDir "bin\verde.exe"
  $VersionOutput = & $VerdeExe version --json
  if ($LASTEXITCODE -ne 0) {
    throw "verde.exe version --json failed with exit code $LASTEXITCODE."
  }
  $RuntimeEvidence = ($VersionOutput | Out-String).Trim() | ConvertFrom-Json
  if ($RuntimeEvidence.version -ne $Version) {
    throw "verde.exe reports version $($RuntimeEvidence.version), expected $Version"
  }
  $VersionOutput | Set-Content -LiteralPath (Join-Path $EvidenceDir "version.json") -Encoding UTF8

  & (Join-Path $ScriptDir "smoke-windows-webview2.ps1") -PrefixDir $PrefixDir -EvidenceDir $EvidenceDir
  $WebView2Evidence = Get-Content -LiteralPath (Join-Path $EvidenceDir "webview2-smoke.json") -Raw | ConvertFrom-Json

  & (Join-Path $ScriptDir "smoke-windows-terminal.ps1") -PrefixDir $PrefixDir -EvidenceDir $EvidenceDir
  $TerminalEvidence = Get-Content -LiteralPath (Join-Path $EvidenceDir "terminal-smoke.json") -Raw | ConvertFrom-Json
}

$Evidence = [ordered]@{
  schema_version = 1
  target = "x86_64-windows-msvc"
  version_expected = $Version
  compile_only_tests = (-not $SkipBuild)
  runtime_cli_smoke = (-not $SkipLaunch)
  runtime_webview2_smoke = (-not $SkipLaunch)
  runtime_terminal_smoke = (-not $SkipLaunch)
  files = $FileEvidence
  version = $RuntimeEvidence
  webview2 = $WebView2Evidence
  terminal = $TerminalEvidence
}
$Evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceDir "smoke.json") -Encoding UTF8
Write-Host "Windows smoke checks passed; evidence: $EvidenceDir"
