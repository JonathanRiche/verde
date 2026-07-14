$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Repository = "JonathanRiche/verde"
$ReleaseApi = "https://api.github.com/repos/$Repository/releases/latest"
$InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\Verde"
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("verde-install-" + [Guid]::NewGuid().ToString("N"))

function Write-Step([string]$Message) {
  Write-Host "verde install: $Message"
}

if (-not [string]::Equals($env:OS, "Windows_NT", [StringComparison]::OrdinalIgnoreCase)) {
  throw "This installer must run on Windows."
}

$Architectures = @($env:PROCESSOR_ARCHITECTURE, $env:PROCESSOR_ARCHITEW6432)
if ($Architectures -notcontains "AMD64") {
  throw "Verde Windows releases currently support x64 Windows only."
}

# Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Headers = @{
  Accept = "application/vnd.github+json"
  "User-Agent" = "Verde-Web-Installer"
  "X-GitHub-Api-Version" = "2022-11-28"
}

New-Item -ItemType Directory -Force -Path $TemporaryRoot | Out-Null

try {
  Write-Step "Finding the latest release..."
  $Release = Invoke-RestMethod -Uri $ReleaseApi -Headers $Headers
  $Tag = [string]$Release.tag_name
  if ([string]::IsNullOrWhiteSpace($Tag)) {
    throw "The latest GitHub release did not include a tag."
  }

  $ArchiveName = "verde-$Tag-windows-x86_64.zip"
  $ChecksumName = "$ArchiveName.sha256"
  $ArchiveAsset = @($Release.assets) | Where-Object { $_.name -eq $ArchiveName } | Select-Object -First 1
  $ChecksumAsset = @($Release.assets) | Where-Object { $_.name -eq $ChecksumName } | Select-Object -First 1
  if ($null -eq $ArchiveAsset -or $null -eq $ChecksumAsset) {
    throw "Release $Tag does not include the expected Windows x64 package and checksum."
  }

  $ArchivePath = Join-Path $TemporaryRoot $ArchiveName
  $ChecksumPath = Join-Path $TemporaryRoot $ChecksumName
  Write-Step "Downloading Verde $Tag for Windows x64..."
  Invoke-WebRequest -Uri $ArchiveAsset.browser_download_url -OutFile $ArchivePath -UseBasicParsing
  Invoke-WebRequest -Uri $ChecksumAsset.browser_download_url -OutFile $ChecksumPath -UseBasicParsing

  Write-Step "Verifying the package checksum..."
  $ExpectedHash = ((Get-Content -LiteralPath $ChecksumPath -Raw) -split "\s+")[0].ToLowerInvariant()
  if ($ExpectedHash -notmatch "^[0-9a-f]{64}$") {
    throw "The release checksum is not a valid SHA-256 digest."
  }
  $ActualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($ActualHash -ne $ExpectedHash) {
    throw "Package checksum mismatch: expected $ExpectedHash, got $ActualHash."
  }

  $ExtractPath = Join-Path $TemporaryRoot "extracted"
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractPath -Force
  $PackageRoots = @(
    Get-ChildItem -LiteralPath $ExtractPath -Directory |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "install.ps1") -PathType Leaf }
  )
  if ($PackageRoots.Count -ne 1) {
    throw "The release archive did not contain exactly one installable Verde package."
  }
  $PackageRoot = $PackageRoots[0].FullName

  $SigningNoticePath = Join-Path $PackageRoot "WINDOWS-SIGNING.json"
  if (-not (Test-Path -LiteralPath $SigningNoticePath -PathType Leaf)) {
    throw "The release package is missing WINDOWS-SIGNING.json."
  }
  $SigningNotice = Get-Content -LiteralPath $SigningNoticePath -Raw | ConvertFrom-Json
  if ($SigningNotice.signed -eq $true) {
    foreach ($RelativeExecutable in @("app\Verde.exe", "bin\verde.exe")) {
      $ExecutablePath = Join-Path $PackageRoot $RelativeExecutable
      $Signature = Get-AuthenticodeSignature -FilePath $ExecutablePath
      if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Authenticode verification failed for ${RelativeExecutable}: $($Signature.Status)."
      }
    }
    Write-Step "Verified the signed Verde executables."
  } else {
    Write-Warning "This release is unsigned. Its downloaded ZIP passed the published SHA-256 checksum."
  }

  $PackagedInstaller = Join-Path $PackageRoot "install.ps1"
  $WindowsPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  if (-not (Test-Path -LiteralPath $WindowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell was not found at $WindowsPowerShell."
  }

  Write-Step "Installing Verde for the current user..."
  & $WindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PackagedInstaller
  if ($LASTEXITCODE -ne 0) {
    throw "The packaged Verde installer exited with code $LASTEXITCODE."
  }

  $InstalledExecutable = Join-Path $InstallRoot "app\Verde.exe"
  if (-not (Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) {
    throw "Installation completed without creating $InstalledExecutable."
  }

  Write-Step "Installed Verde $Tag."
  Write-Step "CLI: $(Join-Path $InstallRoot 'bin\verde.exe') (not added to PATH)"
  if ($env:VERDE_INSTALL_NO_LAUNCH -ne "1") {
    Write-Step "Launching Verde..."
    Start-Process -FilePath $InstalledExecutable
  }
} finally {
  Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
