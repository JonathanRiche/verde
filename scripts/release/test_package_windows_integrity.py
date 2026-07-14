#!/usr/bin/env python3
"""Focused tests for Windows package manifest and checksum coverage."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("package-windows.py")
SPEC = importlib.util.spec_from_file_location("verde_package_windows", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
PACKAGE_WINDOWS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_WINDOWS)


def write_integrity_metadata(
    root: Path,
    manifest_names: list[str],
    checksum_names: list[str] | None = None,
) -> None:
    entries = []
    for name in manifest_names:
        path = root / name
        entries.append(
            {
                "path": name,
                "size": path.stat().st_size,
                "sha256": PACKAGE_WINDOWS.sha256_file(path),
            }
        )
    PACKAGE_WINDOWS.write_json(
        root / "PACKAGE-MANIFEST.json",
        {"schema_version": 1, "files": entries},
    )

    covered_names = (
        manifest_names + ["PACKAGE-MANIFEST.json"]
        if checksum_names is None
        else checksum_names
    )
    PACKAGE_WINDOWS.write_text(
        root / "SHA256SUMS.txt",
        "".join(
            f"{PACKAGE_WINDOWS.sha256_file(root / name)}  {name}\n"
            for name in covered_names
        ),
    )


class WindowsIntegrityCoverageTests(unittest.TestCase):
    def test_complete_manifest_and_checksums_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            PACKAGE_WINDOWS.write_text(root / "payload.txt", "payload\n")
            write_integrity_metadata(root, ["payload.txt"])

            PACKAGE_WINDOWS.verify_manifest_and_checksums(root)

    def test_injected_file_missing_from_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            PACKAGE_WINDOWS.write_text(root / "payload.txt", "payload\n")
            write_integrity_metadata(root, ["payload.txt"])
            PACKAGE_WINDOWS.write_text(root / "injected.txt", "not listed\n")

            with self.assertRaisesRegex(
                RuntimeError,
                r"manifest coverage mismatch.*injected\.txt",
            ):
                PACKAGE_WINDOWS.verify_manifest_and_checksums(root)

    def test_manifest_content_mismatch_remains_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            PACKAGE_WINDOWS.write_text(root / "payload.txt", "payload\n")
            write_integrity_metadata(root, ["payload.txt"])
            PACKAGE_WINDOWS.write_text(root / "payload.txt", "corrupt\n")

            with self.assertRaisesRegex(
                RuntimeError,
                r"package manifest mismatch for payload\.txt",
            ):
                PACKAGE_WINDOWS.verify_manifest_and_checksums(root)

    def test_manifested_file_missing_from_checksums_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            PACKAGE_WINDOWS.write_text(root / "payload.txt", "payload\n")
            PACKAGE_WINDOWS.write_text(root / "injected.txt", "manifest only\n")
            write_integrity_metadata(
                root,
                ["injected.txt", "payload.txt"],
                ["payload.txt", "PACKAGE-MANIFEST.json"],
            )

            with self.assertRaisesRegex(
                RuntimeError,
                r"checksum coverage mismatch.*injected\.txt",
            ):
                PACKAGE_WINDOWS.verify_manifest_and_checksums(root)


if __name__ == "__main__":
    unittest.main()
