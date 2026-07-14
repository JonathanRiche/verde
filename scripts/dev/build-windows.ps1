param(
  [ValidateSet("native_webview", "stub")]
  [string]$BrowserBackend = "native_webview",
  [string]$PrefixDir = "",
  [string]$Version = "0.0.0",
  [switch]$CompileTests,
  [switch]$SkipBootstrap,
  [string[]]$AdditionalZigArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Version -notmatch "^[0-9A-Za-z][0-9A-Za-z._+-]*$") {
  throw "Version may contain only ASCII letters, digits, dot, underscore, plus, and dash."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$RequiredRustToolchain = "1.95.0"
if ([string]::IsNullOrWhiteSpace($env:VERDE_FFF_RUST_TOOLCHAIN)) {
  $env:VERDE_FFF_RUST_TOOLCHAIN = $RequiredRustToolchain
}
$env:RUSTUP_TOOLCHAIN = $env:VERDE_FFF_RUST_TOOLCHAIN

if (-not $SkipBootstrap) {
  & (Join-Path $ScriptDir "bootstrap-windows-deps.ps1") -Toolchain msvc | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Windows dependency bootstrap failed with exit code $LASTEXITCODE."
  }
}

foreach ($Command in @("zig", "cargo", "rustc", "bun")) {
  if ($null -eq (Get-Command $Command -ErrorAction SilentlyContinue)) {
    throw "$Command is required for the native Windows build."
  }
}
$RustVersion = (& rustc --version | Out-String).Trim()
if (-not $RustVersion.StartsWith("rustc $RequiredRustToolchain ")) {
  throw "Rust $RequiredRustToolchain is required for native Windows builds; found: $RustVersion"
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "node_modules\@anthropic-ai\claude-agent-sdk") -PathType Container)) {
  Push-Location $RepoRoot
  try {
    & bun install --frozen-lockfile --production
    if ($LASTEXITCODE -ne 0) {
      throw "bun install failed with exit code $LASTEXITCODE."
    }
  } finally {
    Pop-Location
  }
}

$ZigArguments = @()
if ($CompileTests) {
  $ZigArguments += "test-compile"
}
$ZigArguments += @(
  "--release=safe",
  "-Dtarget=x86_64-windows-msvc",
  "-Dversion=$Version",
  "-Dbrowser-backend=$BrowserBackend",
  "-Dterminal_backend=true",
  "-Dlocal_ipc=true",
  "-Dwindows_integrations=true",
  "-Dfff-cargo-target=x86_64-pc-windows-msvc",
  "-Dsdl3-include-dir=$env:VERDE_SDL3_INCLUDE_DIR",
  "-Dsdl3-lib-dir=$env:VERDE_SDL3_LIB_DIR",
  "-Dsdl3-runtime-lib=$env:VERDE_SDL3_RUNTIME_LIB",
  "-Dsdl3-ttf-include-dir=$env:VERDE_SDL3_TTF_INCLUDE_DIR",
  "-Dsdl3-ttf-lib-dir=$env:VERDE_SDL3_TTF_LIB_DIR",
  "-Dsdl3-ttf-runtime-lib=$env:VERDE_SDL3_TTF_RUNTIME_LIB",
  "-Dwebview2-include-dir=$env:WEBVIEW2_INCLUDE_DIR",
  "-Dwebview2-loader-lib=$env:WEBVIEW2_LOADER_LIB",
  "-Dwebview2-loader-dll=$env:WEBVIEW2_LOADER_DLL"
)
if (-not [string]::IsNullOrWhiteSpace($PrefixDir)) {
  $ZigArguments += @("-p", $PrefixDir)
}
$ZigArguments += $AdditionalZigArgs

Push-Location $RepoRoot
try {
  & zig build @ZigArguments
  if ($LASTEXITCODE -ne 0) {
    throw "native Windows Zig build failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}
