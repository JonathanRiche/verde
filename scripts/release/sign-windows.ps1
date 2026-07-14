param(
  [Parameter(Mandatory = $true)]
  [string[]]$Path,
  [string]$CertificateThumbprint = $env:VERDE_WINDOWS_CERTIFICATE_THUMBPRINT,
  [string]$CertificatePath = $env:VERDE_WINDOWS_CERTIFICATE_PATH,
  [string]$CertificatePassword = $env:VERDE_WINDOWS_CERTIFICATE_PASSWORD,
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$RequireSignature,
  [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $IsWindows) {
  throw "Authenticode signing and verification require a Windows host."
}

function Find-SignTool {
  $Command = Get-Command signtool.exe -ErrorAction SilentlyContinue
  if ($null -ne $Command) {
    return $Command.Source
  }
  $KitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
  if (Test-Path -LiteralPath $KitsRoot -PathType Container) {
    return Get-ChildItem -LiteralPath $KitsRoot -Filter "signtool.exe" -File -Recurse |
      Where-Object FullName -Match "\\x64\\" |
      Sort-Object FullName -Descending |
      Select-Object -First 1 -ExpandProperty FullName
  }
  return $null
}

$ResolvedPaths = @()
foreach ($Candidate in $Path) {
  if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "missing Windows file to sign or verify: $Candidate"
  }
  $ResolvedPaths += (Resolve-Path -LiteralPath $Candidate).Path
}

$HasThumbprint = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
$HasCertificateFile = -not [string]::IsNullOrWhiteSpace($CertificatePath)
if ($HasThumbprint -and $HasCertificateFile) {
  throw "choose either a certificate thumbprint or a PFX certificate path, not both."
}
if ($HasCertificateFile -and -not (Test-Path -LiteralPath $CertificatePath -PathType Leaf)) {
  throw "Authenticode PFX does not exist: $CertificatePath"
}

$SignTool = Find-SignTool
$ShouldSign = (-not $VerifyOnly) -and ($HasThumbprint -or $HasCertificateFile)
if (($ShouldSign -or $RequireSignature) -and [string]::IsNullOrWhiteSpace($SignTool)) {
  throw "signtool.exe is required for requested Authenticode signing/verification."
}

if ($ShouldSign) {
  foreach ($ResolvedPath in $ResolvedPaths) {
    $SignArguments = @("sign", "/fd", "SHA256")
    if ($HasThumbprint) {
      $SignArguments += @("/sha1", $CertificateThumbprint)
    } else {
      $SignArguments += @("/f", (Resolve-Path -LiteralPath $CertificatePath).Path)
      if (-not [string]::IsNullOrWhiteSpace($CertificatePassword)) {
        $SignArguments += @("/p", $CertificatePassword)
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($TimestampUrl)) {
      $SignArguments += @("/tr", $TimestampUrl, "/td", "SHA256")
    }
    $SignArguments += $ResolvedPath
    & $SignTool @SignArguments
    if ($LASTEXITCODE -ne 0) {
      throw "signtool failed to sign $ResolvedPath with exit code $LASTEXITCODE."
    }
  }
}

$Results = @()
foreach ($ResolvedPath in $ResolvedPaths) {
  $Signature = Get-AuthenticodeSignature -LiteralPath $ResolvedPath
  if ($RequireSignature -and $Signature.Status -ne "Valid") {
    throw "invalid or missing Authenticode signature on $ResolvedPath`: $($Signature.Status)"
  }
  if ($Signature.Status -eq "Valid") {
    & $SignTool verify /pa /all /v $ResolvedPath
    if ($LASTEXITCODE -ne 0) {
      throw "signtool verification failed for $ResolvedPath with exit code $LASTEXITCODE."
    }
  }
  $Results += [ordered]@{
    path = $ResolvedPath
    status = $Signature.Status.ToString()
    signer = if ($null -ne $Signature.SignerCertificate) { $Signature.SignerCertificate.Subject } else { $null }
    timestamp = if ($null -ne $Signature.TimeStamperCertificate) { $Signature.TimeStamperCertificate.Subject } else { $null }
  }
}

[ordered]@{
  schema_version = 1
  signed_this_run = [bool]$ShouldSign
  timestamp_url = if ($ShouldSign) { $TimestampUrl } else { $null }
  files = $Results
} | ConvertTo-Json -Depth 5
