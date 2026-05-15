# Windows dev setup. Phase 1 is a stub: it only validates the toolchain and
# prepares the local CEF cache directory. Phase 2 will download SDL3 here;
# Phase 5 will download the CEF SDK; Phase 6 will ensure the Rust MSVC
# target is installed for fff.

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$here\check-build-deps.ps1"

$cefCacheDir = Join-Path $env:LOCALAPPDATA "verde\cef-sdk"
if (-not (Test-Path $cefCacheDir)) {
    New-Item -ItemType Directory -Path $cefCacheDir -Force | Out-Null
}

Write-Host "[setup-windows] toolchain check passed"
Write-Host "[setup-windows] CEF cache dir: $cefCacheDir"
Write-Host "[setup-windows] Phase 2 will add SDL3 download here."
