#!/usr/bin/env python3
"""Acquire and normalize the pinned Windows SDK/runtime dependencies."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import urllib.request
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = REPO_ROOT / "scripts" / "windows-dependencies.json"
SCRIPT_PATH = Path(__file__).resolve()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, expected_sha256: str, destination: Path, offline: bool) -> None:
    if destination.is_file() and sha256_file(destination) == expected_sha256:
        return
    if offline:
        raise RuntimeError(f"offline cache miss or hash mismatch: {destination}")

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.unlink(missing_ok=True)
    last_error: Exception | None = None
    for attempt in range(1, 4):
        temporary = destination.with_suffix(destination.suffix + ".part")
        temporary.unlink(missing_ok=True)
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "verde-windows-bootstrap/1"})
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            actual = sha256_file(temporary)
            if actual != expected_sha256:
                raise RuntimeError(
                    f"SHA-256 mismatch for {url}: expected {expected_sha256}, got {actual}"
                )
            temporary.replace(destination)
            return
        except Exception as error:  # urllib exposes several transport exception types.
            last_error = error
            temporary.unlink(missing_ok=True)
            if attempt < 3:
                time.sleep(attempt)
    raise RuntimeError(f"failed to download {url}: {last_error}")


def extract_zip_safely(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            resolved = (destination / member.filename).resolve()
            if os.path.commonpath((root, resolved)) != str(root):
                raise RuntimeError(f"archive entry escapes extraction root: {member.filename}")
        package.extractall(destination)


def copy_tree(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise RuntimeError(f"missing expected dependency directory: {source}")
    shutil.copytree(source, destination, dirs_exist_ok=True)


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise RuntimeError(f"missing expected dependency file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def source_artifacts(lock: dict, toolchain: str) -> list[tuple[str, dict]]:
    packages = lock["packages"]
    return [
        ("sdl3", packages["sdl3"][toolchain]),
        ("sdl3_ttf", packages["sdl3_ttf"][toolchain]),
        ("webview2", packages["webview2"]),
        ("event_token", packages["event_token"]),
    ]


def normalize(lock: dict, toolchain: str, extracted: dict[str, Path], output: Path) -> None:
    sdl_version = lock["packages"]["sdl3"]["version"]
    ttf_version = lock["packages"]["sdl3_ttf"]["version"]
    sdl_outer = extracted["sdl3"] / f"SDL3-{sdl_version}"
    ttf_outer = extracted["sdl3_ttf"] / f"SDL3_ttf-{ttf_version}"

    if toolchain == "gnu":
        sdl_root = sdl_outer / "x86_64-w64-mingw32"
        ttf_root = ttf_outer / "x86_64-w64-mingw32"
        copy_tree(sdl_root / "include" / "SDL3", output / "include" / "SDL3")
        copy_tree(ttf_root / "include" / "SDL3_ttf", output / "include" / "SDL3_ttf")
        copy_file(sdl_root / "lib" / "libSDL3.dll.a", output / "lib" / "libSDL3.dll.a")
        copy_file(ttf_root / "lib" / "libSDL3_ttf.dll.a", output / "lib" / "libSDL3_ttf.dll.a")
        # Zig's Windows GNU system-library lookup searches libNAME.a, while SDL's
        # MinGW archives use the more explicit libNAME.dll.a convention.
        copy_file(sdl_root / "lib" / "libSDL3.dll.a", output / "lib" / "libSDL3.a")
        copy_file(ttf_root / "lib" / "libSDL3_ttf.dll.a", output / "lib" / "libSDL3_ttf.a")
        copy_file(sdl_root / "bin" / "SDL3.dll", output / "bin" / "SDL3.dll")
        copy_file(ttf_root / "bin" / "SDL3_ttf.dll", output / "bin" / "SDL3_ttf.dll")
    else:
        copy_tree(sdl_outer / "include" / "SDL3", output / "include" / "SDL3")
        copy_tree(ttf_outer / "include" / "SDL3_ttf", output / "include" / "SDL3_ttf")
        copy_file(sdl_outer / "lib" / "x64" / "SDL3.lib", output / "lib" / "SDL3.lib")
        copy_file(ttf_outer / "lib" / "x64" / "SDL3_ttf.lib", output / "lib" / "SDL3_ttf.lib")
        copy_file(sdl_outer / "lib" / "x64" / "SDL3.dll", output / "bin" / "SDL3.dll")
        copy_file(ttf_outer / "lib" / "x64" / "SDL3_ttf.dll", output / "bin" / "SDL3_ttf.dll")

    webview_root = extracted["webview2"]
    copy_tree(webview_root / "build" / "native" / "include", output / "include")
    # WebView2 imports this Windows SDK header, but Zig's bundled MinGW headers
    # do not currently ship it. Pin the ABI-compatible WIDL header separately.
    copy_file(extracted["event_token"], output / "include" / "EventToken.h")
    loader_root = webview_root / "build" / "native" / "x64"
    loader_name = "libWebView2Loader.a" if toolchain == "gnu" else "WebView2Loader.lib"
    copy_file(loader_root / "WebView2Loader.dll.lib", output / "lib" / loader_name)
    copy_file(loader_root / "WebView2Loader.dll", output / "bin" / "WebView2Loader.dll")

    copy_file(sdl_outer / "LICENSE.txt", output / "licenses" / "SDL3-LICENSE.txt")
    copy_file(ttf_outer / "LICENSE.txt", output / "licenses" / "SDL3_ttf-LICENSE.txt")
    copy_file(webview_root / "LICENSE.txt", output / "licenses" / "WebView2-LICENSE.txt")
    copy_file(webview_root / "NOTICE.txt", output / "licenses" / "WebView2-NOTICE.txt")


def required_paths(toolchain: str) -> list[str]:
    libraries = (
        [
            "lib/libSDL3.dll.a",
            "lib/libSDL3_ttf.dll.a",
            "lib/libSDL3.a",
            "lib/libSDL3_ttf.a",
            "lib/libWebView2Loader.a",
        ]
        if toolchain == "gnu"
        else ["lib/SDL3.lib", "lib/SDL3_ttf.lib", "lib/WebView2Loader.lib"]
    )
    return [
        "include/SDL3/SDL.h",
        "include/SDL3_ttf/SDL_ttf.h",
        "include/WebView2.h",
        "include/EventToken.h",
        *libraries,
        "bin/SDL3.dll",
        "bin/SDL3_ttf.dll",
        "bin/WebView2Loader.dll",
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolchain", choices=("gnu", "msvc"), required=True)
    parser.add_argument("--cache-root", type=Path, default=REPO_ROOT / ".zig-cache" / "windows-deps")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    lock_bytes = LOCK_PATH.read_bytes()
    lock = json.loads(lock_bytes)
    lock_sha256 = hashlib.sha256(lock_bytes).hexdigest()
    normalizer_sha256 = sha256_file(SCRIPT_PATH)
    cache_root = args.cache_root.resolve()
    output = cache_root / args.toolchain
    manifest_path = output / "manifest.json"
    if manifest_path.is_file():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        expected_files = manifest.get("files", {})
        if (
            manifest.get("lock_sha256") == lock_sha256
            and manifest.get("normalizer_sha256") == normalizer_sha256
            and all(
                (output / path).is_file()
                and expected_files.get(path) == sha256_file(output / path)
                for path in required_paths(args.toolchain)
            )
        ):
            print(output)
            return 0

    downloads = cache_root / "downloads"
    extracted: dict[str, Path] = {}
    for name, artifact in source_artifacts(lock, args.toolchain):
        archive_name = artifact["url"].rsplit("/", 1)[-1]
        archive = downloads / f"{name}-{artifact['sha256'][:12]}-{archive_name}"
        download(artifact["url"], artifact["sha256"], archive, args.offline)
        if artifact.get("kind") == "file":
            extracted[name] = archive
            continue
        extract_dir = cache_root / "extract" / f"{name}-{artifact['sha256'][:12]}"
        if not extract_dir.is_dir():
            temporary = Path(tempfile.mkdtemp(prefix=f"{name}-", dir=cache_root))
            try:
                extract_zip_safely(archive, temporary)
                extract_dir.parent.mkdir(parents=True, exist_ok=True)
                temporary.replace(extract_dir)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
        extracted[name] = extract_dir

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary_output = Path(tempfile.mkdtemp(prefix=f"{args.toolchain}-", dir=cache_root))
    try:
        normalize(lock, args.toolchain, extracted, temporary_output)
        file_hashes = {
            path: sha256_file(temporary_output / path) for path in required_paths(args.toolchain)
        }
        manifest = {
            "schema_version": 2,
            "toolchain": args.toolchain,
            "architecture": lock["architecture"],
            "lock_sha256": lock_sha256,
            "normalizer_sha256": normalizer_sha256,
            "sources": {
                name: {
                    "version": lock["packages"][name]["version"],
                    "url": artifact["url"],
                    "sha256": artifact["sha256"],
                }
                for name, artifact in source_artifacts(lock, args.toolchain)
            },
            "files": file_hashes,
        }
        (temporary_output / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        if output.exists():
            shutil.rmtree(output)
        temporary_output.replace(output)
    finally:
        if temporary_output.exists():
            shutil.rmtree(temporary_output)

    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
