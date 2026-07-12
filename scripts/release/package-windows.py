#!/usr/bin/env python3
"""Build and validate an unsigned Windows preview ZIP on non-Windows hosts."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[2]
APP_USER_MODEL_ID = "Verde.Desktop"
RUNTIME_DLLS = ("fff_c.dll", "SDL3.dll", "SDL3_ttf.dll", "WebView2Loader.dll")
DEPENDENCY_LICENSES = (
    "SDL3-LICENSE.txt",
    "SDL3_ttf-LICENSE.txt",
    "WebView2-LICENSE.txt",
    "WebView2-NOTICE.txt",
)
FORBIDDEN_PACKAGE_NAMES = {
    "chrome_100_percent.pak",
    "chrome_200_percent.pak",
    "icudtl.dat",
    "libcef.dll",
    "resources.pak",
    "verde-browser-cef-process.exe",
    "verde-browser-cef.exe",
}
FORBIDDEN_FFF_MARKERS = (
    b"verde_fff_stub",
    b"VERDE_FFF_STUB",
    b"/tmp/verde_fff_stub.c",
)


def windows_numeric_version(version: str) -> tuple[int, int, int, int]:
    """Map a release version to the four 16-bit fields required by VERSIONINFO."""
    if len(version) > 1 and version[0] in "vV" and "0" <= version[1] <= "9":
        version = version[1:]
    core = re.split(r"[-+]", version, maxsplit=1)[0]
    if not core or any(character not in "0123456789." for character in core):
        return (0, 0, 0, 0)
    parts = core.split(".")
    if any(not part for part in parts):
        return (0, 0, 0, 0)
    if len(parts) > 4:
        raise RuntimeError("numeric version core may contain at most four components")
    values = [int(part) for part in parts]
    if any(value > 0xFFFF for value in values):
        raise RuntimeError(
            "numeric version components must fit in an unsigned 16-bit integer"
        )
    values.extend([0] * (4 - len(values)))
    return values[0], values[1], values[2], values[3]


def fixed_version_info_bytes(version: str) -> bytes:
    major, minor, patch, revision = windows_numeric_version(version)
    version_ms = (major << 16) | minor
    version_ls = (patch << 16) | revision
    return struct.pack(
        "<IIIIII", 0xFEEF04BD, 0x00010000, version_ms, version_ls, version_ms, version_ls
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8", newline="\n")


def write_json(path: Path, value: object) -> None:
    write_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def require_file(path: Path, description: str = "required input") -> Path:
    if not path.is_file():
        raise RuntimeError(f"missing {description}: {path}")
    return path


def verify_build_version(root: Path, expected_version: str) -> None:
    version_path = require_file(
        root / "share" / "verde" / "BUILD_VERSION", "build version stamp"
    )
    actual_version = version_path.read_text(encoding="utf-8-sig").rstrip("\r\n")
    if actual_version != expected_version:
        raise RuntimeError(
            f"build version stamp is {actual_version!r}, expected {expected_version!r}"
        )


def copy_required(source: Path, destination: Path) -> None:
    require_file(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def package_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*") if path.is_file())


def relative_path(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def read_pe_metadata(path: Path, *, require_resources: bool = True) -> dict[str, object]:
    data = path.read_bytes()
    if len(data) < 256 or data[:2] != b"MZ":
        raise RuntimeError(f"not a valid DOS/PE image: {path}")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if pe_offset + 24 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise RuntimeError(f"missing or invalid PE signature: {path}")

    machine, section_count = struct.unpack_from("<HH", data, pe_offset + 4)
    optional_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    optional = pe_offset + 24
    if optional + optional_size > len(data):
        raise RuntimeError(f"truncated PE optional header: {path}")
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic == 0x20B:
        data_directory = optional + 112
    elif magic == 0x10B:
        data_directory = optional + 96
    else:
        raise RuntimeError(f"unsupported PE optional-header magic 0x{magic:x}: {path}")
    if data_directory + 24 > optional + optional_size:
        raise RuntimeError(f"PE optional header has no resource directory: {path}")

    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    resource_rva, resource_size = struct.unpack_from("<II", data, data_directory + 16)
    if require_resources and (resource_rva == 0 or resource_size == 0):
        raise RuntimeError(f"PE image has no embedded resource directory: {path}")

    section_table = optional + optional_size
    resource_is_mapped = resource_rva == 0 and not require_resources
    for index in range(section_count):
        section = section_table + index * 40
        if section + 40 > len(data):
            raise RuntimeError(f"truncated PE section table: {path}")
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from(
            "<IIII", data, section + 8
        )
        mapped_size = max(virtual_size, raw_size)
        if virtual_address <= resource_rva < virtual_address + mapped_size:
            resource_offset = raw_offset + (resource_rva - virtual_address)
            resource_is_mapped = resource_offset < len(data)
            break
    if not resource_is_mapped:
        raise RuntimeError(f"PE resource directory is not mapped by a section: {path}")

    return {
        "machine": f"0x{machine:04x}",
        "optional_header": f"0x{magic:03x}",
        "subsystem": subsystem,
        "resource_size": resource_size,
    }


def verify_executable(
    path: Path, expected_subsystem: int, expected_version: str
) -> dict[str, object]:
    metadata = read_pe_metadata(path)
    if metadata["machine"] != "0x8664" or metadata["optional_header"] != "0x20b":
        raise RuntimeError(f"not an x86-64 PE32+ executable: {path}")
    if metadata["subsystem"] != expected_subsystem:
        raise RuntimeError(
            f"unexpected PE subsystem {metadata['subsystem']} in {path}; "
            f"expected {expected_subsystem}"
        )

    data = path.read_bytes()
    for setting in (APP_USER_MODEL_ID, "asInvoker", "PerMonitorV2", "longPathAware"):
        if setting.encode("ascii") not in data:
            raise RuntimeError(f"{path} is missing embedded setting {setting}")
    for value in ("ProductName", "Verde", "FileDescription", "Verde native desktop workspace"):
        if value.encode("utf-16-le") not in data:
            raise RuntimeError(f"{path} is missing VERSIONINFO value {value}")
    if path.name.encode("utf-16-le") not in data:
        raise RuntimeError(f"{path} VERSIONINFO does not name {path.name} as OriginalFilename")
    encoded_version = expected_version.encode("utf-16-le")
    if data.count(encoded_version) < 2:
        raise RuntimeError(
            f"{path} VERSIONINFO does not contain FileVersion and ProductVersion "
            f"{expected_version}"
        )
    if (expected_version.encode("ascii") + b"\0") not in data:
        raise RuntimeError(f"{path} does not embed CLI/SDL build version {expected_version}")
    if fixed_version_info_bytes(expected_version) not in data:
        numeric = ".".join(str(value) for value in windows_numeric_version(expected_version))
        raise RuntimeError(f"{path} does not contain numeric VERSIONINFO {numeric}")
    if expected_version != "0.0.0-preview" and "0.0.0-preview".encode("utf-16-le") in data:
        raise RuntimeError(f"{path} still contains the stale 0.0.0-preview VERSIONINFO value")
    numeric_text = ".".join(str(value) for value in windows_numeric_version(expected_version))
    if numeric_text.encode("ascii") not in data:
        raise RuntimeError(f"{path} embedded manifest does not contain version {numeric_text}")
    return {
        "path": path.name,
        "size": path.stat().st_size,
        "sha256": sha256_file(path),
        "pe": metadata,
        "embedded_version": expected_version,
        "numeric_version": numeric_text,
    }


def verify_dependency_root(root: Path) -> dict[str, object]:
    manifest_path = require_file(root / "manifest.json", "Windows dependency manifest")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("toolchain") != "gnu" or manifest.get("architecture") != "x86_64":
        raise RuntimeError(f"dependency manifest is not for x86_64-windows-gnu: {manifest_path}")
    expected_lock_hash = sha256_file(REPO_ROOT / "scripts" / "windows-dependencies.json")
    expected_normalizer_hash = sha256_file(
        REPO_ROOT / "scripts" / "dev" / "bootstrap_windows_deps.py"
    )
    if manifest.get("lock_sha256") != expected_lock_hash:
        raise RuntimeError(f"dependency manifest does not match scripts/windows-dependencies.json")
    if manifest.get("normalizer_sha256") != expected_normalizer_hash:
        raise RuntimeError(f"dependency manifest does not match bootstrap_windows_deps.py")
    files = manifest.get("files")
    if not isinstance(files, dict):
        raise RuntimeError(f"dependency manifest has no file hash map: {manifest_path}")
    for name, expected in sorted(files.items()):
        dependency = require_file(root / name, "pinned Windows dependency")
        actual = sha256_file(dependency)
        if actual != expected:
            raise RuntimeError(
                f"Windows dependency hash mismatch for {name}: expected {expected}, got {actual}"
            )
    for name in DEPENDENCY_LICENSES:
        require_file(root / "licenses" / name, "Windows dependency license")
    return manifest


def verify_fff_runtime(path: Path) -> None:
    data = path.read_bytes()
    for marker in FORBIDDEN_FFF_MARKERS:
        if marker in data:
            raise RuntimeError(
                f"refusing to package temporary fff stub {path}; rebuild vendor/fff for Windows"
            )
    for export in (
        "fff_create_instance",
        "fff_destroy",
        "fff_free_result",
        "fff_free_search_result",
        "fff_is_scanning",
        "fff_search",
        "fff_search_result_get_item",
        "fff_track_query",
    ):
        if export.encode("ascii") not in data:
            raise RuntimeError(f"fff runtime is missing required export {export}: {path}")


def verify_package_tree(root: Path, expected_version: str) -> dict[str, object]:
    expected_executables = {"app/Verde.exe", "bin/verde.exe"}
    expected_dlls = {
        f"{directory}/{name}" for directory in ("app", "bin") for name in RUNTIME_DLLS
    }
    actual_executables = {
        relative_path(root, path)
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() == ".exe"
    }
    actual_dlls = {
        relative_path(root, path)
        for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() == ".dll"
    }
    if actual_executables != expected_executables:
        raise RuntimeError(
            "Windows executable allowlist mismatch; "
            f"missing={sorted(expected_executables - actual_executables)}, "
            f"unexpected={sorted(actual_executables - expected_executables)}"
        )
    if actual_dlls != expected_dlls:
        raise RuntimeError(
            "Windows DLL allowlist mismatch; "
            f"missing={sorted(expected_dlls - actual_dlls)}, "
            f"unexpected={sorted(actual_dlls - expected_dlls)}"
        )

    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() in {".a", ".lib", ".pdb"}:
            raise RuntimeError(f"package contains a development artifact: {path}")
        if path.name.lower() in FORBIDDEN_PACKAGE_NAMES:
            raise RuntimeError(f"native Windows package contains a CEF artifact: {path}")

    installer = require_file(root / "install.ps1", "preview installer").read_text(encoding="utf-8")
    for marker in (APP_USER_MODEL_ID, "9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3", "PropertyId = 5"):
        if marker not in installer:
            raise RuntimeError(
                f"install.ps1 does not assign {APP_USER_MODEL_ID} through property store"
            )
    for document in (
        "WINDOWS-TESTING.md",
        "WINDOWS-PREVIEW.md",
        "WINDOWS-IMPLEMENTATION.md",
    ):
        require_file(root / document, "Windows handoff document")
    require_file(root / "test-terminal.ps1", "Windows terminal smoke test")
    require_file(root / "share" / "verde" / "provider_bridge.mjs", "provider bridge")
    verify_build_version(root, expected_version)
    packaged_version = require_file(
        root / "share" / "verde" / "VERSION", "package version marker"
    ).read_text(encoding="utf-8-sig").strip()
    if packaged_version != expected_version:
        raise RuntimeError(
            f"package VERSION is {packaged_version!r}, expected {expected_version!r}"
        )

    app_fff = root / "app" / "fff_c.dll"
    cli_fff = root / "bin" / "fff_c.dll"
    verify_fff_runtime(app_fff)
    verify_fff_runtime(cli_fff)
    for name in RUNTIME_DLLS:
        app_dll = root / "app" / name
        cli_dll = root / "bin" / name
        for dll in (app_dll, cli_dll):
            metadata = read_pe_metadata(dll, require_resources=False)
            if metadata["machine"] != "0x8664" or metadata["optional_header"] != "0x20b":
                raise RuntimeError(f"runtime DLL is not an x86-64 PE32+ image: {dll}")
        app_hash = sha256_file(app_dll)
        cli_hash = sha256_file(cli_dll)
        if app_hash != cli_hash:
            raise RuntimeError(f"app/bin runtime copies differ for {name}")

    app_evidence = verify_executable(
        root / "app" / "Verde.exe", expected_subsystem=2, expected_version=expected_version
    )
    app_evidence["path"] = "app/Verde.exe"
    cli_evidence = verify_executable(
        root / "bin" / "verde.exe", expected_subsystem=3, expected_version=expected_version
    )
    cli_evidence["path"] = "bin/verde.exe"
    return {
        "schema_version": 1,
        "target": "x86_64-windows-gnu",
        "package_version": expected_version,
        "numeric_version": ".".join(
            str(value) for value in windows_numeric_version(expected_version)
        ),
        "cli_version_verification": "embedded-build-option",
        "manifest_verified": True,
        "manifest_tool_verified": False,
        "signature_required": False,
        "app_user_model_id": APP_USER_MODEL_ID,
        "shortcut_property_key": "System.AppUserModel.ID",
        "installer_identity_verified": True,
        "shortcut_runtime_verified": False,
        "fff_stub_rejected": True,
        "executables": [app_evidence, cli_evidence],
        "dlls": sorted(expected_dlls),
    }


def copy_package_payload(prefix: Path, dependency_root: Path, package_root: Path) -> None:
    copy_required(prefix / "bin" / "Verde.exe", package_root / "app" / "Verde.exe")
    copy_required(prefix / "bin" / "cli" / "verde.exe", package_root / "bin" / "verde.exe")
    for name in RUNTIME_DLLS:
        copy_required(prefix / "bin" / name, package_root / "app" / name)
        copy_required(prefix / "bin" / "cli" / name, package_root / "bin" / name)
    copy_required(
        prefix / "share" / "verde" / "provider_bridge.mjs",
        package_root / "share" / "verde" / "provider_bridge.mjs",
    )
    copy_required(
        prefix / "share" / "verde" / "BUILD_VERSION",
        package_root / "share" / "verde" / "BUILD_VERSION",
    )

    sources = {
        REPO_ROOT / "README.md": package_root / "README.md",
        REPO_ROOT / "LICENSE": package_root / "LICENSE",
        REPO_ROOT / "notes" / "windows_test_handoff.md": package_root / "WINDOWS-TESTING.md",
        REPO_ROOT / "notes" / "windows-preview-release.md": package_root / "WINDOWS-PREVIEW.md",
        REPO_ROOT
        / "notes"
        / "windows_implementation_audit.md": package_root / "WINDOWS-IMPLEMENTATION.md",
        REPO_ROOT
        / "scripts"
        / "release"
        / "install-windows-preview.ps1": package_root / "install.ps1",
        REPO_ROOT
        / "scripts"
        / "dev"
        / "smoke-windows-terminal.ps1": package_root / "test-terminal.ps1",
        REPO_ROOT
        / "scripts"
        / "windows-dependencies.json": package_root
        / "share"
        / "verde"
        / "windows-dependencies.json",
        dependency_root
        / "manifest.json": package_root
        / "share"
        / "verde"
        / "windows-dependency-manifest.json",
        REPO_ROOT
        / "vendor"
        / "fff"
        / "LICENSE": package_root / "share" / "verde" / "licenses" / "fff-LICENSE.txt",
    }
    for source, destination in sources.items():
        copy_required(source, destination)
    for name in DEPENDENCY_LICENSES:
        copy_required(
            dependency_root / "licenses" / name,
            package_root / "share" / "verde" / "licenses" / name,
        )


def verify_manifest_and_checksums(root: Path) -> None:
    package_paths = {relative_path(root, path) for path in package_files(root)}
    manifest = json.loads(
        require_file(root / "PACKAGE-MANIFEST.json", "package manifest").read_text(encoding="utf-8")
    )
    manifest_paths: set[str] = set()
    for entry in manifest.get("files", []):
        entry_path = entry["path"]
        if entry_path in manifest_paths:
            raise RuntimeError(f"package manifest contains duplicate path: {entry_path}")
        manifest_paths.add(entry_path)
        path = root / entry_path
        require_file(path, "manifest payload")
        if path.stat().st_size != entry["size"] or sha256_file(path) != entry["sha256"]:
            raise RuntimeError(f"package manifest mismatch for {entry_path}")

    # The manifest describes the complete payload that exists immediately before
    # the manifest and checksum list are generated. Enforcing that exact set also
    # makes extraction verification reject files appended to an otherwise-valid ZIP.
    expected_manifest_paths = package_paths - {
        "PACKAGE-MANIFEST.json",
        "SHA256SUMS.txt",
    }
    if manifest_paths != expected_manifest_paths:
        unlisted = sorted(expected_manifest_paths - manifest_paths)
        unexpected = sorted(manifest_paths - expected_manifest_paths)
        raise RuntimeError(
            "package manifest coverage mismatch; "
            f"unlisted={unlisted}, unexpected={unexpected}"
        )

    checksums = require_file(root / "SHA256SUMS.txt", "package checksums").read_text(
        encoding="utf-8"
    )
    checksum_paths: set[str] = set()
    for line in checksums.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            raise RuntimeError(f"invalid package checksum line: {line}")
        expected, name = match.groups()
        if name in checksum_paths:
            raise RuntimeError(f"package checksums contain duplicate path: {name}")
        checksum_paths.add(name)
        path = require_file(root / name, "checksummed payload")
        actual = sha256_file(path)
        if actual != expected:
            raise RuntimeError(
                f"package checksum mismatch for {name}: expected {expected}, got {actual}"
            )

    # SHA256SUMS cannot hash itself, but every other regular file must be covered.
    expected_checksum_paths = package_paths - {"SHA256SUMS.txt"}
    if checksum_paths != expected_checksum_paths:
        unlisted = sorted(expected_checksum_paths - checksum_paths)
        unexpected = sorted(checksum_paths - expected_checksum_paths)
        raise RuntimeError(
            "package checksum coverage mismatch; "
            f"unlisted={unlisted}, unexpected={unexpected}"
        )


def resolve_dependency_root(explicit: Path | None, offline: bool) -> Path:
    if explicit is not None:
        root = explicit.resolve()
    else:
        command = [
            sys.executable,
            str(REPO_ROOT / "scripts" / "dev" / "bootstrap_windows_deps.py"),
            "--toolchain",
            "gnu",
        ]
        if offline:
            command.append("--offline")
        result = subprocess.run(command, cwd=REPO_ROOT, check=True, text=True, capture_output=True)
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if not lines:
            raise RuntimeError("Windows dependency bootstrap did not report its output directory")
        root = Path(lines[-1]).resolve()
    verify_dependency_root(root)
    return root


def build_prefix(prefix: Path, version: str) -> None:
    if prefix.exists():
        shutil.rmtree(prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "scripts" / "dev" / "build-windows.sh"),
            "--prefix",
            str(prefix),
            f"-Dversion={version}",
        ],
        cwd=REPO_ROOT,
        check=True,
    )


def create_package(
    version: str,
    output_dir: Path,
    prefix: Path,
    dependency_root: Path,
    work_dir: Path,
) -> tuple[Path, str]:
    package_name = f"verde-{version}-windows-x86_64"
    package_root = work_dir / package_name
    extraction_root = work_dir / "extract-check"
    shutil.rmtree(package_root, ignore_errors=True)
    shutil.rmtree(extraction_root, ignore_errors=True)
    package_root.mkdir(parents=True)
    output_dir.mkdir(parents=True, exist_ok=True)

    copy_package_payload(prefix, dependency_root, package_root)
    write_text(package_root / "share" / "verde" / "VERSION", version + "\n")
    write_text(
        package_root / "WINDOWS-RUNTIME.txt",
        "Verde requires the Microsoft Edge WebView2 Evergreen Runtime.\n"
        "WebView2Loader.dll is the application loader, not the browser runtime.\n"
        "Install or repair the Evergreen Runtime before reporting browser startup failures.\n",
    )
    write_json(
        package_root / "WINDOWS-SIGNING.json",
        {
            "schema_version": 1,
            "signed": False,
            "policy": "unsigned-first-preview-zip",
            "timestamp_url": None,
            "note": (
                "This first-preview ZIP is unsigned. Verify the adjacent release checksum "
                "before use."
            ),
        },
    )

    evidence = verify_package_tree(package_root, version)
    write_json(
        package_root / "share" / "verde" / "windows-package-verification.json", evidence
    )
    manifest_entries = [
        {
            "path": relative_path(package_root, path),
            "size": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in package_files(package_root)
    ]
    write_json(
        package_root / "PACKAGE-MANIFEST.json",
        {
            "schema_version": 1,
            "package_name": package_name,
            "version": version,
            "target": "x86_64-windows-gnu",
            "webview2_runtime_policy": "evergreen-prerequisite",
            "signing_policy": "unsigned-first-preview-zip",
            "files": manifest_entries,
        },
    )
    checksum_lines = [
        f"{sha256_file(path)}  {relative_path(package_root, path)}"
        for path in package_files(package_root)
    ]
    write_text(package_root / "SHA256SUMS.txt", "\n".join(checksum_lines) + "\n")
    verify_package_tree(package_root, version)
    verify_manifest_and_checksums(package_root)

    output_zip = (output_dir / f"{package_name}.zip").resolve()
    temporary_zip = work_dir / f"{package_name}.zip.tmp"
    subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts" / "release" / "create_deterministic_zip.py"),
            "--source-root",
            str(package_root),
            "--archive",
            str(temporary_zip),
            "--archive-root",
            package_name,
        ],
        cwd=REPO_ROOT,
        check=True,
    )
    output_zip.unlink(missing_ok=True)
    shutil.move(temporary_zip, output_zip)

    extraction_root.mkdir(parents=True)
    with zipfile.ZipFile(output_zip) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError("Windows preview ZIP contains duplicate paths")
        prefix_name = package_name + "/"
        if not names or any(
            not name.startswith(prefix_name) or ".." in Path(name).parts for name in names
        ):
            raise RuntimeError("Windows preview ZIP contains an entry outside its package root")
        archive.extractall(extraction_root)
    extracted = extraction_root / package_name
    verify_package_tree(extracted, version)
    verify_manifest_and_checksums(extracted)

    zip_hash = sha256_file(output_zip)
    write_text(
        output_zip.with_suffix(output_zip.suffix + ".sha256"),
        f"{zip_hash}  {output_zip.name}\n",
    )
    return output_zip, zip_hash


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build and package an unsigned Windows x86-64 preview from Linux/macOS."
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--output-dir", type=Path, default=REPO_ROOT / "dist")
    parser.add_argument(
        "--prefix-dir", type=Path, default=REPO_ROOT / ".zig-cache" / "windows-package" / "prefix"
    )
    parser.add_argument("--dependency-root", type=Path)
    parser.add_argument(
        "--work-dir", type=Path, default=REPO_ROOT / ".zig-cache" / "windows-package-cross"
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--offline-deps", action="store_true")
    args = parser.parse_args()

    if re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z._+-]*", args.version) is None:
        raise RuntimeError(
            "version may contain only ASCII letters, digits, dot, underscore, plus, and dash"
        )
    prefix = args.prefix_dir.resolve()
    if not args.skip_build:
        build_prefix(prefix, args.version)
    elif not prefix.is_dir():
        raise RuntimeError(f"Windows build prefix does not exist: {prefix}")
    verify_build_version(prefix, args.version)
    dependency_root = resolve_dependency_root(args.dependency_root, args.offline_deps)
    archive, archive_hash = create_package(
        args.version,
        args.output_dir.resolve(),
        prefix,
        dependency_root,
        args.work_dir.resolve(),
    )
    print(f"Windows package created and extraction-verified: {archive}")
    print(f"SHA-256: {archive_hash}")
    print(
        "Signing: unsigned internal preview "
        "(use package-windows.ps1 on Windows for Authenticode)"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
