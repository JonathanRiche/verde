param(
  [ValidateSet("gnu", "msvc")]
  [string]$Toolchain = "msvc",
  [string]$CacheRoot = "",
  [switch]$Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$Bootstrap = Join-Path $ScriptDir "bootstrap_windows_deps.py"
if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
  $CacheRoot = Join-Path $RepoRoot ".zig-cache\windows-deps"
}

$Python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $Python) {
  $Python = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $Python) {
  throw "Python 3 is required to bootstrap the pinned Windows dependencies."
}

$Arguments = @($Bootstrap, "--toolchain", $Toolchain, "--cache-root", $CacheRoot)
if ($Offline) {
  $Arguments += "--offline"
}
$Output = & $Python.Source @Arguments
if ($LASTEXITCODE -ne 0) {
  throw "Windows dependency bootstrap failed with exit code $LASTEXITCODE."
}
$DependencyRoot = ($Output | Select-Object -Last 1).Trim()
if (-not (Test-Path -LiteralPath $DependencyRoot -PathType Container)) {
  throw "Windows dependency bootstrap did not produce a normalized dependency root: $DependencyRoot"
}

$env:VERDE_SDL3_INCLUDE_DIR = Join-Path $DependencyRoot "include"
$env:VERDE_SDL3_LIB_DIR = Join-Path $DependencyRoot "lib"
$env:VERDE_SDL3_RUNTIME_LIB = Join-Path $DependencyRoot "bin\SDL3.dll"
$env:VERDE_SDL3_TTF_INCLUDE_DIR = Join-Path $DependencyRoot "include"
$env:VERDE_SDL3_TTF_LIB_DIR = Join-Path $DependencyRoot "lib"
$env:VERDE_SDL3_TTF_RUNTIME_LIB = Join-Path $DependencyRoot "bin\SDL3_ttf.dll"
$env:WEBVIEW2_INCLUDE_DIR = Join-Path $DependencyRoot "include"
$LoaderImportRelativePath = if ($Toolchain -eq "gnu") { "lib\libWebView2Loader.a" } else { "lib\WebView2Loader.lib" }
$env:WEBVIEW2_LOADER_LIB = Join-Path $DependencyRoot $LoaderImportRelativePath
$env:WEBVIEW2_LOADER_DLL = Join-Path $DependencyRoot "bin\WebView2Loader.dll"

function Quote-PowerShellLiteral([string]$Value) {
  return "'" + $Value.Replace("'", "''") + "'"
}

$EnvironmentFile = Join-Path $DependencyRoot "env.ps1"
$EnvironmentLines = @(
  "`$env:VERDE_SDL3_INCLUDE_DIR = $(Quote-PowerShellLiteral $env:VERDE_SDL3_INCLUDE_DIR)",
  "`$env:VERDE_SDL3_LIB_DIR = $(Quote-PowerShellLiteral $env:VERDE_SDL3_LIB_DIR)",
  "`$env:VERDE_SDL3_RUNTIME_LIB = $(Quote-PowerShellLiteral $env:VERDE_SDL3_RUNTIME_LIB)",
  "`$env:VERDE_SDL3_TTF_INCLUDE_DIR = $(Quote-PowerShellLiteral $env:VERDE_SDL3_TTF_INCLUDE_DIR)",
  "`$env:VERDE_SDL3_TTF_LIB_DIR = $(Quote-PowerShellLiteral $env:VERDE_SDL3_TTF_LIB_DIR)",
  "`$env:VERDE_SDL3_TTF_RUNTIME_LIB = $(Quote-PowerShellLiteral $env:VERDE_SDL3_TTF_RUNTIME_LIB)",
  "`$env:WEBVIEW2_INCLUDE_DIR = $(Quote-PowerShellLiteral $env:WEBVIEW2_INCLUDE_DIR)",
  "`$env:WEBVIEW2_LOADER_LIB = $(Quote-PowerShellLiteral $env:WEBVIEW2_LOADER_LIB)",
  "`$env:WEBVIEW2_LOADER_DLL = $(Quote-PowerShellLiteral $env:WEBVIEW2_LOADER_DLL)"
)
Set-Content -LiteralPath $EnvironmentFile -Value $EnvironmentLines -Encoding UTF8

Write-Host "Pinned Windows dependencies ready: $DependencyRoot"
Write-Output $DependencyRoot
