#!/usr/bin/env python3
"""Focused tests for Windows package version encoding."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("package-windows.py")
SPEC = importlib.util.spec_from_file_location("verde_package_windows", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
PACKAGE_WINDOWS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE_WINDOWS)


class WindowsVersionTests(unittest.TestCase):
    def test_prerelease_uses_numeric_release_core(self) -> None:
        self.assertEqual(
            (0, 1, 27, 0),
            PACKAGE_WINDOWS.windows_numeric_version("0.1.27-internal-20260710"),
        )

    def test_nonnumeric_release_label_uses_zero_tuple(self) -> None:
        self.assertEqual(
            (0, 0, 0, 0), PACKAGE_WINDOWS.windows_numeric_version("ci-123")
        )

    def test_tag_prefix_is_ignored_for_numeric_fields(self) -> None:
        self.assertEqual(
            (0, 1, 27, 0), PACKAGE_WINDOWS.windows_numeric_version("v0.1.27")
        )

    def test_fixed_info_sets_file_and_product_versions(self) -> None:
        fields = struct.unpack(
            "<IIIIII",
            PACKAGE_WINDOWS.fixed_version_info_bytes(
                "0.1.27-internal-20260710"
            ),
        )
        self.assertEqual(
            (0xFEEF04BD, 0x00010000, 1, 27 << 16, 1, 27 << 16), fields
        )

    def test_numeric_component_must_fit_versioninfo(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "unsigned 16-bit"):
            PACKAGE_WINDOWS.windows_numeric_version("1.2.65536")

    def test_build_stamp_prevents_skip_build_relabeling(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stamp = root / "share" / "verde" / "BUILD_VERSION"
            stamp.parent.mkdir(parents=True)
            stamp.write_text("ci-123\n", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "ci-123.*expected '0'"):
                PACKAGE_WINDOWS.verify_build_version(root, "0")


if __name__ == "__main__":
    unittest.main()
