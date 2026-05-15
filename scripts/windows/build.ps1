# Builds the desktop app for x86_64-windows-msvc with the CEF pane stubbed.
# Phase 1: link succeeds, exe is produced. Phase 2 wires SDL3 so the exe
# can actually open a window.

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$here\check-build-deps.ps1"

$repoRoot = Resolve-Path (Join-Path $here "..\..")
Push-Location $repoRoot
try {
    & zig build `
        -Dtarget=x86_64-windows-msvc `
        -Dcef-stub-preview=true `
        @args
    if ($LASTEXITCODE -ne 0) {
        Write-Error "zig build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

Write-Host "[build-windows] zig-out\bin\verde.exe produced"
