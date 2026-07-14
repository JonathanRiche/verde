#!/usr/bin/env python3
"""Create a byte-reproducible ZIP from an already validated package tree."""

from __future__ import annotations

import argparse
from pathlib import Path
import zipfile


ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
REGULAR_FILE_MODE = 0o100644


def add_file(archive: zipfile.ZipFile, source: Path, archive_name: str) -> None:
    info = zipfile.ZipInfo(archive_name, ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = REGULAR_FILE_MODE << 16
    info.flag_bits |= 0x800  # UTF-8 filenames.
    archive.writestr(info, source.read_bytes(), compresslevel=9)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--archive-root", required=True)
    args = parser.parse_args()

    source_root = args.source_root.resolve()
    if not source_root.is_dir():
        raise RuntimeError(f"package source root does not exist: {source_root}")
    if not args.archive_root or "/" in args.archive_root or "\\" in args.archive_root:
        raise RuntimeError("archive root must be one directory name")

    archive_path = args.archive.resolve()
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    archive_path.unlink(missing_ok=True)
    files = sorted(path for path in source_root.rglob("*") if path.is_file())
    if not files:
        raise RuntimeError(f"package source root is empty: {source_root}")

    with zipfile.ZipFile(archive_path, "w", allowZip64=True) as archive:
        for source in files:
            relative = source.relative_to(source_root).as_posix()
            add_file(archive, source, f"{args.archive_root}/{relative}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
