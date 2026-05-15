# Runs the desktop app under the Windows-MSVC target with the CEF pane stubbed.
# Phase 1: this is expected to produce verde.exe but the runtime may fail on
# missing SDL3.dll. Phase 2 wires SDL3 so the window actually opens.

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$here\check-build-deps.ps1"

$repoRoot = Resolve-Path (Join-Path $here "..\..")
Push-Location $repoRoot
try {
    & zig build run `
        -Dtarget=x86_64-windows-msvc `
        -Dcef-stub-preview=true `
        @args
    if ($LASTEXITCODE -ne 0) {
        Write-Error "zig build run failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}
