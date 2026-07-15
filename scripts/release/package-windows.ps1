param(
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [string]$OutputDir = "dist",
  [string]$PrefixDir = "",
  [string]$CertificateThumbprint = $env:VERDE_WINDOWS_CERTIFICATE_THUMBPRINT,
  [string]$CertificatePath = $env:VERDE_WINDOWS_CERTIFICATE_PATH,
  [string]$CertificatePassword = $env:VERDE_WINDOWS_CERTIFICATE_PASSWORD,
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$RequireSignature,
  [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Version -notmatch "^[0-9A-Za-z][0-9A-Za-z._+-]*$") {
  throw "Version may contain only ASCII letters, digits, dot, underscore, plus, and dash."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
  $OutputDir = Join-Path $RepoRoot $OutputDir
}
if ([string]::IsNullOrWhiteSpace($PrefixDir)) {
  $PrefixDir = Join-Path $RepoRoot ".zig-cache\windows-package\prefix"
} elseif (-not [System.IO.Path]::IsPathRooted($PrefixDir)) {
  $PrefixDir = Join-Path $RepoRoot $PrefixDir
}

& (Join-Path $RepoRoot "scripts\dev\bootstrap-windows-deps.ps1") -Toolchain msvc | Out-Host
$DependencyRoot = Split-Path -Parent $env:VERDE_SDL3_INCLUDE_DIR

if (-not $SkipBuild) {
  Remove-Item -LiteralPath $PrefixDir -Recurse -Force -ErrorAction SilentlyContinue
  & (Join-Path $RepoRoot "scripts\dev\build-windows.ps1") `
    -PrefixDir $PrefixDir `
    -Version $Version `
    -SkipBootstrap
}

$BuildVersionPath = Join-Path $PrefixDir "share\verde\BUILD_VERSION"
if (-not (Test-Path -LiteralPath $BuildVersionPath -PathType Leaf)) {
  throw "Windows build prefix is missing share/verde/BUILD_VERSION: $PrefixDir"
}
$BuiltVersion = (Get-Content -LiteralPath $BuildVersionPath -Raw).Trim()
if ($BuiltVersion -ne $Version) {
  throw "Windows build prefix version is '$BuiltVersion', expected '$Version'"
}

$PackageName = "verde-$Version-windows-x86_64"
$WorkRoot = Join-Path $RepoRoot ".zig-cache\windows-package"
$PackageRoot = Join-Path $WorkRoot $PackageName
$ExtractionRoot = Join-Path $WorkRoot "extract-check"
$ZipPath = Join-Path $OutputDir "$PackageName.zip"

Remove-Item -LiteralPath $PackageRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ExtractionRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $PackageRoot, $OutputDir | Out-Null

function Copy-RequiredFile([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "missing required Windows package input: $Source"
  }
  $DestinationParent = Split-Path -Parent $Destination
  if (-not [string]::IsNullOrWhiteSpace($DestinationParent)) {
    New-Item -ItemType Directory -Force -Path $DestinationParent | Out-Null
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

$RequiredRuntimeFiles = @(
  "fff_c.dll",
  "SDL3.dll",
  "SDL3_ttf.dll",
  "WebView2Loader.dll"
)
Copy-RequiredFile (Join-Path $PrefixDir "bin\Verde.exe") (Join-Path $PackageRoot "app\Verde.exe")
Copy-RequiredFile (Join-Path $PrefixDir "bin\cli\verde.exe") (Join-Path $PackageRoot "bin\verde.exe")
foreach ($Name in $RequiredRuntimeFiles) {
  Copy-RequiredFile (Join-Path $PrefixDir "bin\$Name") (Join-Path $PackageRoot "app\$Name")
  Copy-RequiredFile (Join-Path $PrefixDir "bin\cli\$Name") (Join-Path $PackageRoot "bin\$Name")
}
Copy-RequiredFile (Join-Path $PrefixDir "share\verde\provider_bridge.mjs") (Join-Path $PackageRoot "share\verde\provider_bridge.mjs")
Copy-RequiredFile (Join-Path $PrefixDir "share\verde\BUILD_VERSION") (Join-Path $PackageRoot "share\verde\BUILD_VERSION")
Copy-RequiredFile (Join-Path $RepoRoot "README.md") (Join-Path $PackageRoot "README.md")
Copy-RequiredFile (Join-Path $RepoRoot "LICENSE") (Join-Path $PackageRoot "LICENSE")
Copy-RequiredFile (Join-Path $RepoRoot "notes\windows_test_handoff.md") (Join-Path $PackageRoot "WINDOWS-TESTING.md")
Copy-RequiredFile (Join-Path $RepoRoot "notes\windows-preview-release.md") (Join-Path $PackageRoot "WINDOWS-PREVIEW.md")
Copy-RequiredFile (Join-Path $RepoRoot "notes\windows_implementation_audit.md") (Join-Path $PackageRoot "WINDOWS-IMPLEMENTATION.md")
Copy-RequiredFile (Join-Path $RepoRoot "scripts\release\install-windows-preview.ps1") (Join-Path $PackageRoot "install.ps1")
Copy-RequiredFile (Join-Path $RepoRoot "scripts\dev\smoke-windows-terminal.ps1") (Join-Path $PackageRoot "test-terminal.ps1")
Copy-RequiredFile (Join-Path $RepoRoot "scripts\windows-dependencies.json") (Join-Path $PackageRoot "share\verde\windows-dependencies.json")
Copy-RequiredFile (Join-Path $DependencyRoot "manifest.json") (Join-Path $PackageRoot "share\verde\windows-dependency-manifest.json")

$LicenseDir = Join-Path $PackageRoot "share\verde\licenses"
Copy-RequiredFile (Join-Path $RepoRoot "vendor\fff\LICENSE") (Join-Path $LicenseDir "fff-LICENSE.txt")
foreach ($License in (Get-ChildItem -LiteralPath (Join-Path $DependencyRoot "licenses") -File)) {
  Copy-RequiredFile $License.FullName (Join-Path $LicenseDir $License.Name)
}

Set-Content -LiteralPath (Join-Path $PackageRoot "share\verde\VERSION") -Value $Version -Encoding UTF8
Set-Content -LiteralPath (Join-Path $PackageRoot "WINDOWS-RUNTIME.txt") -Encoding UTF8 -Value @"
Verde requires the Microsoft Edge WebView2 Evergreen Runtime.
WebView2Loader.dll is the application loader, not the browser runtime.
Install or repair the Evergreen Runtime before reporting browser startup failures.
"@

$HasSigningIdentity = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -or
  -not [string]::IsNullOrWhiteSpace($CertificatePath)
$SignablePaths = @(
  (Join-Path $PackageRoot "app\Verde.exe"),
  (Join-Path $PackageRoot "bin\verde.exe"),
  (Join-Path $PackageRoot "app\fff_c.dll"),
  (Join-Path $PackageRoot "bin\fff_c.dll")
)
$SignedPackage = $false
if ($HasSigningIdentity -or $RequireSignature) {
  if (-not $IsWindows) {
    throw "Authenticode signing or required verification must run on Windows."
  }
  $SigningArguments = @{
    Path = $SignablePaths
    CertificateThumbprint = $CertificateThumbprint
    CertificatePath = $CertificatePath
    CertificatePassword = $CertificatePassword
    TimestampUrl = $TimestampUrl
    RequireSignature = $true
  }
  if (-not $HasSigningIdentity) {
    $SigningArguments.VerifyOnly = $true
  }
  & (Join-Path $ScriptDir "sign-windows.ps1") @SigningArguments | Out-Host
  $SignedPackage = $true
}

$SigningNotice = [ordered]@{
  schema_version = 1
  signed = $SignedPackage
  policy = if ($SignedPackage) { "authenticode-rfc3161" } else { "unsigned-first-preview-zip" }
  timestamp_url = if ($SignedPackage) { $TimestampUrl } else { $null }
  note = if ($SignedPackage) {
    "Verde-owned PE files were Authenticode-signed and verified before packaging."
  } else {
    "This first-preview ZIP is unsigned. Verify the adjacent release checksum before use."
  }
}
$SigningNotice | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $PackageRoot "WINDOWS-SIGNING.json") -Encoding UTF8

$VerificationEvidence = Join-Path $WorkRoot "package-verification.json"
$VerifyArguments = @{
  PackageRoot = $PackageRoot
  EvidencePath = $VerificationEvidence
  ExpectedVersion = $Version
}
if ($IsWindows) {
  $VerifyArguments.RequireManifestTool = $true
}
if ($RequireSignature) {
  $VerifyArguments.RequireSignature = $true
}
& (Join-Path $RepoRoot "scripts\dev\verify-windows-package.ps1") @VerifyArguments | Out-Host
Copy-RequiredFile $VerificationEvidence (Join-Path $PackageRoot "share\verde\windows-package-verification.json")

function Get-PackageFiles {
  return Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | Sort-Object FullName
}

function Get-PackageRelativePath([string]$FullName) {
  return $FullName.Substring($PackageRoot.Length).TrimStart("\", "/").Replace("\", "/")
}

$ManifestFiles = @(
  Get-PackageFiles | ForEach-Object {
    [ordered]@{
      path = Get-PackageRelativePath $_.FullName
      size = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
)
$Manifest = [ordered]@{
  schema_version = 1
  package_name = $PackageName
  version = $Version
  target = "x86_64-windows-msvc"
  webview2_runtime_policy = "evergreen-prerequisite"
  signing_policy = $SigningNotice.policy
  files = $ManifestFiles
}
$Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PackageRoot "PACKAGE-MANIFEST.json") -Encoding UTF8

$ChecksumLines = @(
  Get-PackageFiles | ForEach-Object {
    $Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $(Get-PackageRelativePath $_.FullName)"
  }
)
Set-Content -LiteralPath (Join-Path $PackageRoot "SHA256SUMS.txt") -Value $ChecksumLines -Encoding UTF8

$ForbiddenNames = @(
  "libcef.dll",
  "verde-browser-cef.exe",
  "verde-browser-cef-process.exe",
  "chrome_100_percent.pak",
  "chrome_200_percent.pak",
  "resources.pak",
  "icudtl.dat"
)
foreach ($Entry in (Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force)) {
  if ($Entry.Extension -in @(".pdb", ".lib", ".a")) {
    throw "Windows package unexpectedly contains a development artifact: $($Entry.FullName)"
  }
  if ($Entry.Name -in $ForbiddenNames) {
    throw "Windows native package unexpectedly contains CEF payload: $($Entry.FullName)"
  }
}

Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
$Python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $Python) {
  $Python = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $Python) {
  throw "Python 3 is required to create the deterministic Windows package archive."
}
& $Python.Source (Join-Path $ScriptDir "create_deterministic_zip.py") `
  --source-root $PackageRoot `
  --archive $ZipPath `
  --archive-root $PackageName
if ($LASTEXITCODE -ne 0) {
  throw "deterministic Windows ZIP creation failed with exit code $LASTEXITCODE."
}
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
  throw "Windows package archive was not created: $ZipPath"
}

New-Item -ItemType Directory -Force -Path $ExtractionRoot | Out-Null
Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractionRoot -Force
$ExtractedRoot = Join-Path $ExtractionRoot $PackageName
foreach ($RelativePath in @(
  "app\Verde.exe",
  "app\fff_c.dll",
  "app\SDL3.dll",
  "app\SDL3_ttf.dll",
  "app\WebView2Loader.dll",
  "bin\verde.exe",
  "bin\fff_c.dll",
  "bin\SDL3.dll",
  "bin\SDL3_ttf.dll",
  "bin\WebView2Loader.dll",
  "share\verde\provider_bridge.mjs",
  "share\verde\windows-package-verification.json",
  "PACKAGE-MANIFEST.json",
  "SHA256SUMS.txt",
  "WINDOWS-SIGNING.json",
  "WINDOWS-TESTING.md",
  "WINDOWS-PREVIEW.md",
  "WINDOWS-IMPLEMENTATION.md",
  "test-terminal.ps1",
  "install.ps1"
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $ExtractedRoot $RelativePath) -PathType Leaf)) {
    throw "extracted Windows package is missing $RelativePath"
  }
}

$ExtractedVerification = Join-Path $WorkRoot "extracted-package-verification.json"
$ExtractedVerifyArguments = @{
  PackageRoot = $ExtractedRoot
  EvidencePath = $ExtractedVerification
  ExpectedVersion = $Version
}
if ($IsWindows) {
  $ExtractedVerifyArguments.RequireManifestTool = $true
}
if ($RequireSignature) {
  $ExtractedVerifyArguments.RequireSignature = $true
}
& (Join-Path $RepoRoot "scripts\dev\verify-windows-package.ps1") @ExtractedVerifyArguments | Out-Host

foreach ($Line in (Get-Content -LiteralPath (Join-Path $ExtractedRoot "SHA256SUMS.txt"))) {
  if ([string]::IsNullOrWhiteSpace($Line)) {
    continue
  }
  if ($Line -notmatch "^([0-9a-f]{64})  (.+)$") {
    throw "invalid package checksum line: $Line"
  }
  $Expected = $Matches[1]
  $CheckedPath = Join-Path $ExtractedRoot $Matches[2].Replace("/", "\")
  $Actual = (Get-FileHash -LiteralPath $CheckedPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) {
    throw "package checksum mismatch for $($Matches[2]): expected $Expected, got $Actual"
  }
}

$ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath "$ZipPath.sha256" -Value "$ZipHash  $(Split-Path -Leaf $ZipPath)" -Encoding UTF8
Write-Host "Windows package created and extraction-verified: $ZipPath"
