param(
  [Parameter(Mandatory = $true)]
  [string]$PackageRoot,
  [string]$EvidencePath = "",
  [string]$ExpectedVersion = "",
  [switch]$RequireSignature,
  [switch]$RequireManifestTool
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path

$VersionPath = Join-Path $PackageRoot "share\verde\VERSION"
if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
  throw "Windows package is missing share/verde/VERSION"
}
$PackageVersion = (Get-Content -LiteralPath $VersionPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
  $ExpectedVersion = $PackageVersion
}
if ($PackageVersion -ne $ExpectedVersion) {
  throw "package VERSION is '$PackageVersion', expected '$ExpectedVersion'"
}
if ($ExpectedVersion -notmatch "^[0-9A-Za-z][0-9A-Za-z._+-]*$") {
  throw "package VERSION contains characters that cannot be embedded safely: $ExpectedVersion"
}
$BuildVersionPath = Join-Path $PackageRoot "share\verde\BUILD_VERSION"
if (-not (Test-Path -LiteralPath $BuildVersionPath -PathType Leaf)) {
  throw "Windows package is missing share/verde/BUILD_VERSION"
}
$BuildVersion = (Get-Content -LiteralPath $BuildVersionPath -Raw).Trim()
if ($BuildVersion -ne $ExpectedVersion) {
  throw "package BUILD_VERSION is '$BuildVersion', expected '$ExpectedVersion'"
}

function Get-RelativePath([string]$Path) {
  return $Path.Substring($PackageRoot.Length).TrimStart("\", "/").Replace("\", "/")
}

function Get-WindowsNumericVersion([string]$Version) {
  if ($Version -match "^[vV](?=\d)") {
    $Version = $Version.Substring(1)
  }
  $Core = ($Version -split "[-+]", 2)[0]
  if ([string]::IsNullOrEmpty($Core) -or $Core -notmatch "^[0-9.]+$") {
    return @(0, 0, 0, 0)
  }
  $Parts = @($Core.Split("."))
  if (@($Parts | Where-Object { [string]::IsNullOrEmpty($_) }).Count -ne 0) {
    return @(0, 0, 0, 0)
  }
  if ($Parts.Count -gt 4) {
    throw "numeric version core may contain at most four components"
  }

  $Values = @()
  foreach ($Part in $Parts) {
    $Value = [UInt64]::Parse($Part, [Globalization.CultureInfo]::InvariantCulture)
    if ($Value -gt [UInt16]::MaxValue) {
      throw "numeric version components must fit in an unsigned 16-bit integer"
    }
    $Values += [int]$Value
  }
  while ($Values.Count -lt 4) {
    $Values += 0
  }
  return $Values
}

function Get-FixedVersionInfoBytes([int[]]$NumericVersion) {
  $VersionMs = [UInt32](([UInt64]$NumericVersion[0] * 65536) + $NumericVersion[1])
  $VersionLs = [UInt32](([UInt64]$NumericVersion[2] * 65536) + $NumericVersion[3])
  $Signature = [Convert]::ToUInt32("feef04bd", 16)
  $Bytes = [Collections.Generic.List[byte]]::new()
  foreach ($Value in @(
    $Signature,
    [UInt32]0x00010000,
    $VersionMs,
    $VersionLs,
    $VersionMs,
    $VersionLs
  )) {
    $Bytes.AddRange([BitConverter]::GetBytes([UInt32]$Value))
  }
  return $Bytes.ToArray()
}

$NumericVersion = @(Get-WindowsNumericVersion $ExpectedVersion)
$NumericVersionText = $NumericVersion -join "."

function Assert-ExactPaths([string]$Kind, [string[]]$Expected, [string[]]$Actual) {
  $Expected = @($Expected | Sort-Object)
  $Actual = @($Actual | Sort-Object)
  $Difference = @(Compare-Object -ReferenceObject $Expected -DifferenceObject $Actual)
  if ($Difference.Count -ne 0) {
    $Missing = @($Difference | Where-Object SideIndicator -eq "<=" | ForEach-Object InputObject)
    $Unexpected = @($Difference | Where-Object SideIndicator -eq "=>" | ForEach-Object InputObject)
    throw "$Kind allowlist mismatch; missing=[$($Missing -join ', ')], unexpected=[$($Unexpected -join ', ')]"
  }
}

function Assert-SafePackagePath([string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      [IO.Path]::IsPathRooted($RelativePath) -or
      $RelativePath -match "^[A-Za-z]:" -or
      $RelativePath.Contains("\")) {
    throw "unsafe package metadata path: $RelativePath"
  }
  foreach ($Segment in $RelativePath.Split("/")) {
    if ([string]::IsNullOrEmpty($Segment) -or $Segment -in @(".", "..")) {
      throw "unsafe package metadata path: $RelativePath"
    }
  }
}

function Test-PackageIntegrityMetadata {
  $ManifestPath = Join-Path $PackageRoot "PACKAGE-MANIFEST.json"
  $ChecksumsPath = Join-Path $PackageRoot "SHA256SUMS.txt"
  $HasManifest = Test-Path -LiteralPath $ManifestPath -PathType Leaf
  $HasChecksums = Test-Path -LiteralPath $ChecksumsPath -PathType Leaf
  if ($HasManifest -ne $HasChecksums) {
    throw "package integrity metadata must contain both PACKAGE-MANIFEST.json and SHA256SUMS.txt"
  }
  if (-not $HasManifest) {
    # Native packaging invokes this verifier once before generating integrity
    # metadata and again after extraction. Only the extracted pass can assert it.
    return $false
  }

  $PackagePaths = @()
  $PackagePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($File in (Get-ChildItem -LiteralPath $PackageRoot -Recurse -File)) {
    $RelativePath = Get-RelativePath $File.FullName
    if (-not $PackagePathSet.Add($RelativePath)) {
      throw "package contains a duplicate or case-colliding path: $RelativePath"
    }
    $PackagePaths += $RelativePath
  }

  $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  if ($null -eq $Manifest.files) {
    throw "package manifest is missing its files array"
  }
  $ManifestPaths = @()
  $ManifestPathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($Entry in @($Manifest.files)) {
    $RelativePath = [string]$Entry.path
    Assert-SafePackagePath $RelativePath
    if (-not $ManifestPathSet.Add($RelativePath)) {
      throw "package manifest contains a duplicate or case-colliding path: $RelativePath"
    }
    $ManifestPaths += $RelativePath
    $Path = Join-Path $PackageRoot $RelativePath.Replace("/", [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw "package manifest references a missing file: $RelativePath"
    }
    $File = Get-Item -LiteralPath $Path
    $ActualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($File.Length -ne [int64]$Entry.size -or $ActualHash -ne ([string]$Entry.sha256).ToLowerInvariant()) {
      throw "package manifest mismatch for $RelativePath"
    }
  }
  $ExpectedManifestPaths = @($PackagePaths | Where-Object { $_ -notin @("PACKAGE-MANIFEST.json", "SHA256SUMS.txt") })
  Assert-ExactPaths "package manifest coverage" $ExpectedManifestPaths $ManifestPaths

  $ChecksumPaths = @()
  $ChecksumPathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($Line in (Get-Content -LiteralPath $ChecksumsPath)) {
    if ($Line -notmatch "^([0-9a-f]{64})  (.+)$") {
      throw "invalid package checksum line: $Line"
    }
    $ExpectedHash = $Matches[1]
    $RelativePath = $Matches[2]
    Assert-SafePackagePath $RelativePath
    if (-not $ChecksumPathSet.Add($RelativePath)) {
      throw "package checksums contain a duplicate or case-colliding path: $RelativePath"
    }
    $ChecksumPaths += $RelativePath
    $Path = Join-Path $PackageRoot $RelativePath.Replace("/", [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
      throw "package checksums reference a missing file: $RelativePath"
    }
    $ActualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash) {
      throw "package checksum mismatch for $RelativePath`: expected $ExpectedHash, got $ActualHash"
    }
  }
  $ExpectedChecksumPaths = @($PackagePaths | Where-Object { $_ -ne "SHA256SUMS.txt" })
  Assert-ExactPaths "package checksum coverage" $ExpectedChecksumPaths $ChecksumPaths
  return $true
}

$ManifestVerified = Test-PackageIntegrityMetadata

function Get-PeMetadata([string]$Path) {
  $Bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($Bytes.Length -lt 256 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) {
    throw "not a valid DOS/PE image: $Path"
  }
  $PeOffset = [BitConverter]::ToInt32($Bytes, 0x3c)
  if ($PeOffset -lt 0 -or ($PeOffset + 136) -gt $Bytes.Length) {
    throw "invalid PE header offset in $Path"
  }
  if ($Bytes[$PeOffset] -ne 0x50 -or $Bytes[$PeOffset + 1] -ne 0x45 -or
      $Bytes[$PeOffset + 2] -ne 0 -or $Bytes[$PeOffset + 3] -ne 0) {
    throw "missing PE signature in $Path"
  }

  $Machine = [BitConverter]::ToUInt16($Bytes, $PeOffset + 4)
  $OptionalHeader = $PeOffset + 24
  $Magic = [BitConverter]::ToUInt16($Bytes, $OptionalHeader)
  if ($Magic -eq 0x20b) {
    $DataDirectory = $OptionalHeader + 112
  } elseif ($Magic -eq 0x10b) {
    $DataDirectory = $OptionalHeader + 96
  } else {
    throw "unsupported PE optional-header magic 0x$('{0:x}' -f $Magic) in $Path"
  }
  $Subsystem = [BitConverter]::ToUInt16($Bytes, $OptionalHeader + 68)
  $ResourceRva = [BitConverter]::ToUInt32($Bytes, $DataDirectory + 16)
  $ResourceSize = [BitConverter]::ToUInt32($Bytes, $DataDirectory + 20)
  if ($ResourceRva -eq 0 -or $ResourceSize -eq 0) {
    throw "PE image has no embedded resource directory: $Path"
  }

  return [ordered]@{
    machine = "0x$('{0:x4}' -f $Machine)"
    optional_header = "0x$('{0:x3}' -f $Magic)"
    subsystem = [int]$Subsystem
    resource_size = [int64]$ResourceSize
  }
}

function Test-BinaryContainsBytes([string]$Path, [byte[]]$Needle) {
  if ($Needle.Length -eq 0) {
    return $true
  }
  $Stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $Buffer = New-Object byte[] 65536
    $Matched = 0
    while (($Count = $Stream.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
      for ($Index = 0; $Index -lt $Count; $Index++) {
        if ($Buffer[$Index] -eq $Needle[$Matched]) {
          $Matched++
          if ($Matched -eq $Needle.Length) {
            return $true
          }
        } else {
          $Matched = if ($Buffer[$Index] -eq $Needle[0]) { 1 } else { 0 }
        }
      }
    }
    return $false
  } finally {
    $Stream.Dispose()
  }
}

function Get-BinaryUtf16Count([string]$Path, [string]$Value) {
  if ([string]::IsNullOrEmpty($Value)) {
    return 0
  }
  $BinaryText = [Text.Encoding]::Unicode.GetString([IO.File]::ReadAllBytes($Path))
  $Count = 0
  $Start = 0
  while (($Start = $BinaryText.IndexOf($Value, $Start, [StringComparison]::Ordinal)) -ge 0) {
    $Count++
    $Start += $Value.Length
  }
  return $Count
}

function Test-BinaryContainsAscii([string]$Path, [string]$Value) {
  return Test-BinaryContainsBytes $Path ([Text.Encoding]::ASCII.GetBytes($Value))
}

function Test-BinaryContainsUtf16([string]$Path, [string]$Value) {
  return Test-BinaryContainsBytes $Path ([Text.Encoding]::Unicode.GetBytes($Value))
}

function Find-WindowsSdkTool([string]$Name) {
  $Command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }
  if (-not $IsWindows) {
    return $null
  }
  $KitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (-not (Test-Path -LiteralPath $KitsRoot -PathType Container)) {
    return $null
  }
  return Get-ChildItem -LiteralPath $KitsRoot -Filter $Name -File -Recurse |
    Where-Object FullName -Match "\\x64\\" |
    Sort-Object FullName -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}

function Test-EmbeddedManifest(
  [string]$ExePath,
  [string]$MtPath,
  [string]$ExpectedNumericVersion
) {
  $ManifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "verde-$([Guid]::NewGuid().ToString('N')).manifest"
  try {
    & $MtPath "-nologo" "-inputresource:$ExePath;#1" "-out:$ManifestPath"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
      throw "mt.exe could not extract the embedded manifest from $ExePath"
    }
    [xml]$Manifest = Get-Content -LiteralPath $ManifestPath -Raw
    $ExecutionLevel = $Manifest.SelectSingleNode("//*[local-name()='requestedExecutionLevel']")
    $AssemblyIdentity = $Manifest.SelectSingleNode("//*[local-name()='assemblyIdentity']")
    $DpiAwareness = $Manifest.SelectSingleNode("//*[local-name()='dpiAwareness']")
    $LongPathAware = $Manifest.SelectSingleNode("//*[local-name()='longPathAware']")
    if ($null -eq $ExecutionLevel -or $ExecutionLevel.level -ne "asInvoker") {
      throw "embedded manifest does not request asInvoker: $ExePath"
    }
    if ($null -eq $AssemblyIdentity -or $AssemblyIdentity.version -ne $ExpectedNumericVersion) {
      throw "embedded manifest version does not match $ExpectedNumericVersion`: $ExePath"
    }
    if ($null -eq $DpiAwareness -or $DpiAwareness.InnerText -ne "PerMonitorV2") {
      throw "embedded manifest does not request PerMonitorV2 DPI awareness: $ExePath"
    }
    if ($null -eq $LongPathAware -or $LongPathAware.InnerText -ne "true") {
      throw "embedded manifest does not enable long paths: $ExePath"
    }
  } finally {
    Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
  }
}

$ExpectedExecutables = @("app/Verde.exe", "bin/verde.exe")
$ExpectedAppUserModelId = "Verde.Desktop"
$ExpectedDlls = @(
  "app/fff_c.dll",
  "app/SDL3.dll",
  "app/SDL3_ttf.dll",
  "app/WebView2Loader.dll",
  "bin/fff_c.dll",
  "bin/SDL3.dll",
  "bin/SDL3_ttf.dll",
  "bin/WebView2Loader.dll"
)
$ActualExecutables = @(Get-ChildItem -LiteralPath $PackageRoot -Filter "*.exe" -File -Recurse | ForEach-Object { Get-RelativePath $_.FullName })
$ActualDlls = @(Get-ChildItem -LiteralPath $PackageRoot -Filter "*.dll" -File -Recurse | ForEach-Object { Get-RelativePath $_.FullName })
Assert-ExactPaths "Windows executable" $ExpectedExecutables $ActualExecutables
Assert-ExactPaths "Windows runtime DLL" $ExpectedDlls $ActualDlls

foreach ($Directory in @("app", "bin")) {
  $FffPath = Join-Path $PackageRoot "$Directory\fff_c.dll"
  if ((Test-BinaryContainsAscii $FffPath "verde_fff_stub") -or
      (Test-BinaryContainsAscii $FffPath "VERDE_FFF_STUB")) {
    throw "refusing to verify temporary fff stub: $FffPath"
  }
}
foreach ($RuntimeName in @("fff_c.dll", "SDL3.dll", "SDL3_ttf.dll", "WebView2Loader.dll")) {
  $AppHash = (Get-FileHash -LiteralPath (Join-Path $PackageRoot "app\$RuntimeName") -Algorithm SHA256).Hash
  $CliHash = (Get-FileHash -LiteralPath (Join-Path $PackageRoot "bin\$RuntimeName") -Algorithm SHA256).Hash
  if ($AppHash -ne $CliHash) {
    throw "app/bin runtime copies differ for $RuntimeName"
  }
}

$InstallerPath = Join-Path $PackageRoot "install.ps1"
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
  throw "Windows package is missing install.ps1"
}
$InstallerSource = Get-Content -LiteralPath $InstallerPath -Raw
if (-not $InstallerSource.Contains($ExpectedAppUserModelId) -or
    -not $InstallerSource.Contains("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3") -or
    -not $InstallerSource.Contains("PropertyId = 5") -or
    -not $InstallerSource.Contains('[Environment]::SetEnvironmentVariable("Path", $UpdatedUserPath, "User")')) {
  throw "install.ps1 is missing the required shortcut identity or user PATH setup"
}
$TerminalSmokePath = Join-Path $PackageRoot "test-terminal.ps1"
if (-not (Test-Path -LiteralPath $TerminalSmokePath -PathType Leaf)) {
  throw "Windows package is missing test-terminal.ps1"
}

$ShortcutRuntimeVerified = $false
if ($IsWindows) {
  $ShortcutPath = Join-Path ([IO.Path]::GetTempPath()) "verde-$([Guid]::NewGuid().ToString('N')).lnk"
  $InstallationEvidencePath = Join-Path $PackageRoot "share\verde\windows-installation.json"
  try {
    $InstallationResult = & $InstallerPath -PackageRoot $PackageRoot -NoCopy -NoPath -ShortcutPath $ShortcutPath |
      Out-String |
      ConvertFrom-Json
    $ExpectedShortcutTarget = (Resolve-Path -LiteralPath (Join-Path $PackageRoot "app\Verde.exe")).Path
    if ($InstallationResult.app_user_model_id -ne $ExpectedAppUserModelId -or
        $InstallationResult.executable -ne $ExpectedShortcutTarget -or
        -not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
      throw "installed shortcut did not retain System.AppUserModel.ID=$ExpectedAppUserModelId"
    }
    $ShortcutRuntimeVerified = $true
  } finally {
    Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallationEvidencePath -Force -ErrorAction SilentlyContinue
  }
}

$MtPath = Find-WindowsSdkTool "mt.exe"
if ($RequireManifestTool -and [string]::IsNullOrWhiteSpace($MtPath)) {
  throw "mt.exe is required to verify embedded Windows manifests."
}

$ExecutableEvidence = @()
foreach ($RelativePath in $ExpectedExecutables) {
  $Path = Join-Path $PackageRoot $RelativePath.Replace("/", "\")
  $Pe = Get-PeMetadata $Path
  if ($Pe.machine -ne "0x8664") {
    throw "$RelativePath is not an x86-64 PE image: $($Pe.machine)"
  }
  $ExpectedSubsystem = if ($RelativePath -eq "app/Verde.exe") { 2 } else { 3 }
  if ($Pe.subsystem -ne $ExpectedSubsystem) {
    throw "$RelativePath has PE subsystem $($Pe.subsystem), expected $ExpectedSubsystem"
  }
  if (-not (Test-BinaryContainsAscii $Path $ExpectedAppUserModelId)) {
    throw "$RelativePath does not carry the explicit process identity $ExpectedAppUserModelId"
  }
  foreach ($ManifestSetting in @("asInvoker", "PerMonitorV2", "longPathAware")) {
    if (-not (Test-BinaryContainsAscii $Path $ManifestSetting)) {
      throw "$RelativePath is missing embedded manifest setting $ManifestSetting"
    }
  }

  $ExpectedOriginalFilename = Split-Path -Leaf $Path
  if (-not (Test-BinaryContainsUtf16 $Path $ExpectedOriginalFilename)) {
    throw "$RelativePath VERSIONINFO does not name $ExpectedOriginalFilename as OriginalFilename"
  }
  if ((Get-BinaryUtf16Count $Path $ExpectedVersion) -lt 2) {
    throw "$RelativePath VERSIONINFO does not contain FileVersion and ProductVersion $ExpectedVersion"
  }
  $BuildVersionBytes = [Text.Encoding]::ASCII.GetBytes($ExpectedVersion + [char]0)
  if (-not (Test-BinaryContainsBytes $Path $BuildVersionBytes)) {
    throw "$RelativePath does not embed CLI/SDL build version $ExpectedVersion"
  }
  if (-not (Test-BinaryContainsBytes $Path (Get-FixedVersionInfoBytes $NumericVersion))) {
    throw "$RelativePath does not contain numeric VERSIONINFO $NumericVersionText"
  }
  if (-not (Test-BinaryContainsAscii $Path $NumericVersionText)) {
    throw "$RelativePath embedded manifest does not contain version $NumericVersionText"
  }
  if ($ExpectedVersion -ne "0.0.0-preview" -and
      (Test-BinaryContainsUtf16 $Path "0.0.0-preview")) {
    throw "$RelativePath still contains the stale 0.0.0-preview VERSIONINFO value"
  }

  $VersionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
  $ProductName = $VersionInfo.ProductName
  $FileDescription = $VersionInfo.FileDescription
  $FileVersion = $VersionInfo.FileVersion
  $ProductVersion = $VersionInfo.ProductVersion
  if ($ProductName -ne "Verde" -or [string]::IsNullOrWhiteSpace($FileDescription)) {
    # FileVersionInfo does not decode PE resources on every non-Windows .NET
    # host. The resource directory was validated above, so check the exact
    # UTF-16 VERSIONINFO keys/values in that directory's backing image.
    if (-not (Test-BinaryContainsUtf16 $Path "ProductName") -or
        -not (Test-BinaryContainsUtf16 $Path "Verde") -or
        -not (Test-BinaryContainsUtf16 $Path "FileDescription") -or
        -not (Test-BinaryContainsUtf16 $Path "Verde native desktop workspace")) {
      throw "$RelativePath is missing Verde VERSIONINFO metadata"
    }
    $ProductName = "Verde"
    $FileDescription = "Verde native desktop workspace"
  }
  if ($IsWindows) {
    if ($FileVersion -ne $ExpectedVersion -or $ProductVersion -ne $ExpectedVersion) {
      throw "$RelativePath FileVersion/ProductVersion do not match package VERSION $ExpectedVersion"
    }
  } else {
    # Static UTF-16 and fixed-field checks above are authoritative cross-host.
    $FileVersion = $ExpectedVersion
    $ProductVersion = $ExpectedVersion
  }
  if (-not [string]::IsNullOrWhiteSpace($MtPath)) {
    Test-EmbeddedManifest $Path $MtPath $NumericVersionText
  }

  $BridgePath = Join-Path (Split-Path -Parent $Path) "..\share\verde\provider_bridge.mjs"
  if (-not (Test-Path -LiteralPath $BridgePath -PathType Leaf)) {
    throw "$RelativePath cannot resolve ../share/verde/provider_bridge.mjs in the package layout"
  }

  $SignatureStatus = "Unavailable"
  if ($IsWindows) {
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $SignatureStatus = $Signature.Status.ToString()
    if ($RequireSignature -and $Signature.Status -ne "Valid") {
      throw "$RelativePath does not have a valid Authenticode signature: $($Signature.Status)"
    }
  } elseif ($RequireSignature) {
    throw "Authenticode verification requires a Windows host."
  }

  $ExecutableEvidence += [ordered]@{
    path = $RelativePath
    size = (Get-Item -LiteralPath $Path).Length
    sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    pe = $Pe
    product_name = $ProductName
    file_description = $FileDescription
    file_version = $FileVersion
    product_version = $ProductVersion
    numeric_version = $NumericVersionText
    signature = $SignatureStatus
  }
}

$CliVersionVerified = $false
$CliCapabilitiesVersionVerified = $false
if ($IsWindows) {
  $CliPath = Join-Path $PackageRoot "bin\verde.exe"
  $CliVersionResult = (& $CliPath version --json | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw "verde version --json failed with exit code $LASTEXITCODE"
  }
  $CliVersionObject = $CliVersionResult | ConvertFrom-Json
  if ($CliVersionObject.version -ne $ExpectedVersion) {
    throw "verde version --json reported '$($CliVersionObject.version)', expected '$ExpectedVersion'"
  }
  $CliVersionVerified = $true

  $CliCapabilitiesResult = (& $CliPath capabilities --json | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw "verde capabilities --json failed with exit code $LASTEXITCODE"
  }
  $CliCapabilitiesObject = $CliCapabilitiesResult | ConvertFrom-Json
  if ($CliCapabilitiesObject.version -ne $ExpectedVersion) {
    throw "verde capabilities --json reported '$($CliCapabilitiesObject.version)', expected '$ExpectedVersion'"
  }
  $CliCapabilitiesVersionVerified = $true
}

$Evidence = [ordered]@{
  schema_version = 1
  target = "x86_64-windows"
  package_version = $ExpectedVersion
  numeric_version = $NumericVersionText
  cli_version_verified = $CliVersionVerified
  cli_capabilities_version_verified = $CliCapabilitiesVersionVerified
  manifest_verified = $ManifestVerified
  manifest_tool_verified = (-not [string]::IsNullOrWhiteSpace($MtPath))
  signature_required = [bool]$RequireSignature
  app_user_model_id = $ExpectedAppUserModelId
  shortcut_property_key = "System.AppUserModel.ID"
  installer_identity_verified = $true
  shortcut_runtime_verified = $ShortcutRuntimeVerified
  executables = $ExecutableEvidence
  dlls = @($ExpectedDlls)
}
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $EvidenceParent = Split-Path -Parent $EvidencePath
  if (-not [string]::IsNullOrWhiteSpace($EvidenceParent)) {
    New-Item -ItemType Directory -Force -Path $EvidenceParent | Out-Null
  }
  $Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
}
$Evidence | ConvertTo-Json -Depth 8
