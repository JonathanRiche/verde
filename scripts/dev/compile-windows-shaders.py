#!/usr/bin/env python3
"""Regenerate or verify Palette's committed D3D12 DXIL shaders."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SHADER_DIR = ROOT / "packages" / "palette" / "src" / "shaders"
DXC_VERSION_MARKER = "1.9.0.5191"
DXC_RELEASE = "v1.9.2602.24"
SHADERS = (
    ("vs_6_0", "ui.vert.hlsl", "ui.vert.dxil"),
    ("ps_6_0", "ui.solid.frag.hlsl", "ui.solid.frag.dxil"),
    ("ps_6_0", "ui.text.frag.hlsl", "ui.text.frag.dxil"),
    ("ps_6_0", "ui.image.frag.hlsl", "ui.image.frag.dxil"),
)


def compiler_path(explicit: str | None) -> str:
    candidate = explicit or os.environ.get("DXC") or shutil.which("dxc")
    if candidate:
        return candidate
    raise SystemExit(
        "dxc was not found. Install Microsoft DirectXShaderCompiler "
        f"{DXC_RELEASE}, or pass --dxc /path/to/dxc."
    )


def verify_compiler(dxc: str) -> None:
    result = subprocess.run(
        [dxc, "--version"],
        check=True,
        capture_output=True,
        text=True,
    )
    version = result.stdout + result.stderr
    if DXC_VERSION_MARKER not in version:
        raise SystemExit(
            f"unsupported dxc version; expected {DXC_VERSION_MARKER} from "
            f"{DXC_RELEASE}, got:\n{version.strip()}"
        )


def compile_all(dxc: str, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    common = (
        "-E",
        "main",
        "-HV",
        "2021",
        "-Ges",
        "-WX",
        "-O3",
        "-Qstrip_debug",
        "-Qstrip_reflect",
    )
    for profile, source_name, output_name in SHADERS:
        subprocess.run(
            [
                dxc,
                "-T",
                profile,
                *common,
                str(SHADER_DIR / source_name),
                "-Fo",
                str(output_dir / output_name),
            ],
            check=True,
        )


def verify_committed(generated_dir: Path) -> None:
    mismatches: list[str] = []
    for _, _, output_name in SHADERS:
        generated = (generated_dir / output_name).read_bytes()
        committed_path = SHADER_DIR / output_name
        committed = committed_path.read_bytes() if committed_path.exists() else b""
        if generated != committed:
            mismatches.append(output_name)
    if mismatches:
        joined = ", ".join(mismatches)
        raise SystemExit(
            f"committed DXIL is stale: {joined}; run this script without --check"
        )


def print_digests() -> None:
    for _, _, output_name in SHADERS:
        digest = hashlib.sha256((SHADER_DIR / output_name).read_bytes()).hexdigest()
        print(f"{digest}  {output_name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed outputs")
    parser.add_argument("--dxc", help="path to the pinned dxc executable")
    args = parser.parse_args()

    dxc = compiler_path(args.dxc)
    verify_compiler(dxc)
    if args.check:
        with tempfile.TemporaryDirectory(prefix="verde-dxil-") as temp:
            generated_dir = Path(temp)
            compile_all(dxc, generated_dir)
            verify_committed(generated_dir)
    else:
        compile_all(dxc, SHADER_DIR)
    print_digests()
    return 0


if __name__ == "__main__":
    sys.exit(main())
