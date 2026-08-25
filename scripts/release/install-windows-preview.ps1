param(
  [string]$PackageRoot = $PSScriptRoot,
  [string]$Destination = (Join-Path $env:LOCALAPPDATA "Programs\Verde"),
  [string]$ShortcutPath = (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Verde.lnk"),
  [switch]$NoCopy,
  [switch]$NoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RunningOnWindows = [string]::Equals($env:OS, "Windows_NT", [StringComparison]::OrdinalIgnoreCase)
if (-not $RunningOnWindows) {
  throw "The Verde preview installer must run on Windows."
}

$AppUserModelId = "Verde.Desktop"
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not [System.IO.Path]::IsPathRooted($Destination)) {
  throw "Destination must be an absolute path."
}
if (-not [System.IO.Path]::IsPathRooted($ShortcutPath)) {
  throw "ShortcutPath must be an absolute path."
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
$PackageRootKey = $PackageRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$DestinationKey = $Destination.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$SameInstallRoot = [string]::Equals($PackageRootKey, $DestinationKey, [StringComparison]::OrdinalIgnoreCase)
$NestedDestinationPrefix = $PackageRootKey + [System.IO.Path]::DirectorySeparatorChar
if (-not $SameInstallRoot -and $DestinationKey.StartsWith($NestedDestinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Destination must not be nested inside the extracted package root."
}

$SourceExecutable = Join-Path $PackageRoot "app\Verde.exe"
if (-not (Test-Path -LiteralPath $SourceExecutable -PathType Leaf)) {
  throw "The package does not contain app\Verde.exe: $PackageRoot"
}

$ShouldCopy = -not $NoCopy -and -not $SameInstallRoot
$InstallRoot = if ($ShouldCopy) { $Destination } else { $PackageRoot }
if ($ShouldCopy) {
  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  foreach ($Entry in (Get-ChildItem -LiteralPath $PackageRoot -Force)) {
    if ($Entry.FullName -eq $InstallRoot) {
      continue
    }
    Copy-Item -LiteralPath $Entry.FullName -Destination $InstallRoot -Recurse -Force
  }
}

$InstalledExecutable = Join-Path $InstallRoot "app\Verde.exe"
if (-not (Test-Path -LiteralPath $InstalledExecutable -PathType Leaf)) {
  throw "Installed GUI executable is missing: $InstalledExecutable"
}
$CliDirectory = Join-Path $InstallRoot "bin"
$CliExecutable = Join-Path $CliDirectory "verde.exe"
if (-not (Test-Path -LiteralPath $CliExecutable -PathType Leaf)) {
  throw "Installed CLI executable is missing: $CliExecutable"
}

$ShortcutParent = Split-Path -Parent $ShortcutPath
New-Item -ItemType Directory -Force -Path $ShortcutParent | Out-Null
$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)
$Shortcut.TargetPath = $InstalledExecutable
$Shortcut.WorkingDirectory = Split-Path -Parent $InstalledExecutable
$Shortcut.IconLocation = "$InstalledExecutable,0"
$Shortcut.Description = "Verde desktop application"
$Shortcut.Save()
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($Shortcut) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($Shell) | Out-Null

if (-not ("Verde.WindowsShortcutIdentity" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Verde {
    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLink { }

    [ComImport]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPersistFile {
        [PreserveSig] int GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey {
        internal Guid FormatId;
        internal uint PropertyId;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct PropVariant {
        [FieldOffset(0)] internal ushort ValueType;
        [FieldOffset(8)] internal IntPtr PointerValue;
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class WindowsShortcutIdentity {
        private const ushort VT_LPWSTR = 31;
        private static PropertyKey AppUserModelIdKey = new PropertyKey {
            FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            PropertyId = 5
        };

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        public static void Set(string shortcutPath, string appUserModelId) {
            object link = new ShellLink();
            try {
                IPersistFile persist = (IPersistFile)link;
                Marshal.ThrowExceptionForHR(persist.Load(shortcutPath, 2));
                IPropertyStore properties = (IPropertyStore)link;
                PropVariant value = new PropVariant {
                    ValueType = VT_LPWSTR,
                    PointerValue = Marshal.StringToCoTaskMemUni(appUserModelId)
                };
                try {
                    Marshal.ThrowExceptionForHR(properties.SetValue(ref AppUserModelIdKey, ref value));
                    Marshal.ThrowExceptionForHR(properties.Commit());
                    Marshal.ThrowExceptionForHR(persist.Save(shortcutPath, true));
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(link);
            }
        }

        public static string Get(string shortcutPath) {
            object link = new ShellLink();
            try {
                IPersistFile persist = (IPersistFile)link;
                Marshal.ThrowExceptionForHR(persist.Load(shortcutPath, 0));
                IPropertyStore properties = (IPropertyStore)link;
                PropVariant value;
                Marshal.ThrowExceptionForHR(properties.GetValue(ref AppUserModelIdKey, out value));
                try {
                    if (value.ValueType != VT_LPWSTR || value.PointerValue == IntPtr.Zero) return null;
                    return Marshal.PtrToStringUni(value.PointerValue);
                } finally {
                    PropVariantClear(ref value);
                }
            } finally {
                Marshal.FinalReleaseComObject(link);
            }
        }
    }
}
'@
}

[Verde.WindowsShortcutIdentity]::Set($ShortcutPath, $AppUserModelId)
$StoredIdentity = [Verde.WindowsShortcutIdentity]::Get($ShortcutPath)
if ($StoredIdentity -ne $AppUserModelId) {
  throw "Start Menu shortcut identity mismatch: expected $AppUserModelId, got $StoredIdentity"
}

$PathUpdated = $false
if (-not $NoPath) {
  $CliDirectoryKey = $CliDirectory.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
  )
  $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $PathContainsCli = $false
  foreach ($Entry in @($UserPath -split ";")) {
    if ([string]::IsNullOrWhiteSpace($Entry)) {
      continue
    }
    $EntryKey = [Environment]::ExpandEnvironmentVariables($Entry.Trim()).TrimEnd(
      [System.IO.Path]::DirectorySeparatorChar,
      [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ([string]::Equals($EntryKey, $CliDirectoryKey, [StringComparison]::OrdinalIgnoreCase)) {
      $PathContainsCli = $true
      break
    }
  }
  if (-not $PathContainsCli) {
    $UpdatedUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) {
      $CliDirectory
    } else {
      $UserPath.TrimEnd(";") + ";" + $CliDirectory
    }
    [Environment]::SetEnvironmentVariable("Path", $UpdatedUserPath, "User")
    $PathUpdated = $true
  }
}

$Evidence = [ordered]@{
  schema_version = 1
  install_root = $InstallRoot
  executable = $InstalledExecutable
  shortcut = $ShortcutPath
  app_user_model_id = $StoredIdentity
  cli = $CliExecutable
  cli_path_added = $PathUpdated
}
$EvidencePath = Join-Path $InstallRoot "share\verde\windows-installation.json"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $EvidencePath) | Out-Null
$Evidence | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $EvidencePath -Encoding UTF8
$Evidence | ConvertTo-Json -Depth 4
