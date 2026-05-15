# Verifies the host has the toolchain needed for the desktop build on Windows.
# Counterpart to scripts/dev/check-desktop-build-deps.sh; called by the Windows
# dev tasks in mise.toml. Phase 1 only checks bun + the MSVC toolchain;
# Phase 2 adds SDL3, Phase 5 adds CEF, Phase 6 adds cargo.

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string] $Name, [string] $Hint = "")
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "missing required command: $Name`n$Hint"
        exit 1
    }
}

Require-Command bun "install Bun first: https://bun.sh/docs/installation"
Require-Command zig "install Zig 0.16.0 (mise install or https://ziglang.org/download/)"
Require-Command cmake "install CMake from https://cmake.org/download/ or 'winget install Kitware.CMake'"

# MSVC must be visible. The Windows port targets x86_64-windows-msvc, so the
# Visual Studio Build Tools 2022 with the "Desktop development with C++"
# workload (MSVC v143, Windows 11 SDK >= 10.0.22621.0) must be installed and
# either already activated in this shell, or discoverable via vswhere.
$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Write-Error @"
MSVC toolchain not found. Install Visual Studio Build Tools 2022 with the
"Desktop development with C++" workload, then re-run from a "Developer
PowerShell for VS 2022" prompt (or run scripts/windows/setup.ps1 which sets
the environment up for you).
"@
        exit 1
    }
}

Write-Host "[check-build-deps] bun, zig, cmake, MSVC: OK"
