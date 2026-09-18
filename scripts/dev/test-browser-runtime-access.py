#!/usr/bin/env python3
"""Run H1 tests with actual runtime/controller/stub code in a temporary source tree.

Extract only browser controller state and retained polling, excluding GUI imports.
Substitute the unused native backend with the real stub; no native browser starts.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "packages/desktop/src"


def declaration(source, prefix, terminator):
    start = source.index(prefix)
    end = source.index(terminator, start) + len(terminator)
    return source[start:end] + "\n"


with tempfile.TemporaryDirectory(prefix="verde-browser-access-") as directory:
    temp = Path(directory)
    shutil.copytree(SRC / "browser", temp / "browser")
    (temp / "state").mkdir()
    for name in ("browser_runtime_access.zig", "browser_background_events.zig", "browser_pane.zig"):
        shutil.copy2(SRC / "state" / name, temp / "state" / name)
    source = (SRC / "state/browser_controller.zig").read_text()
    extracted = '''const std = @import("std");
const browser_runtime = @import("../browser/mod.zig");
const browser_background_events = @import("browser_background_events.zig");
const WorkspacePaneId = u32;
const log = std.log.scoped(.browser_test);
'''
    for name in ("pub const BrowserContextMenuItem", "const RetainedBrowserRuntime", "pub const State"):
        extracted += declaration(source, name + " = struct {", "\n};")
    for name in ("fn adjustedProjectIndexAfterMove", "pub fn pollRetainedBrowserRuntimes", "fn pollBackgroundBrowserRuntime", "pub fn browserBridgePolicyAllowsUntrustedPages"):
        extracted += declaration(source, name + "(", "\n}")
    (temp / "state/browser_controller.zig").write_text(extracted)
    (temp / "browser/native_webview_backend.zig").write_text(
        'pub const Backend = @import("platform/stub_backend.zig").Controller;\n'
    )
    (temp / "options.zig").write_text('pub const browser_backend: enum { native_webview, stub } = .stub;\n')
    (temp / "platform.zig").write_text('pub fn monotonicMs() i64 { return 0; }\n')
    (temp / "root.zig").write_text('comptime { _ = @import("state/browser_runtime_access.zig"); }\n')
    subprocess.run([
        "zig", "test", "-O", "ReleaseSafe", "-fllvm", "--test-filter", "H1",
        "--cache-dir", str(temp / "cache"), "--global-cache-dir", str(temp / "global-cache"),
        "--dep", "build_options", "--dep", "platform_runtime", "-Mroot=" + str(temp / "root.zig"),
        "-Mbuild_options=" + str(temp / "options.zig"), "-Mplatform_runtime=" + str(temp / "platform.zig"),
        "-lc",
    ], cwd=ROOT, check=True, timeout=60)
