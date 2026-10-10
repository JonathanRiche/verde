#!/usr/bin/env python3
"""Isolated safety tests; no real compositor, VNC server, TCP or user state."""

import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("omarchy.py")
spec = importlib.util.spec_from_file_location("omarchy", SCRIPT)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostTests(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(host.listener_arguments("wayvnc: 0.9.1", "/a"), ["--unix-socket", "/a"])
        self.assertEqual(host.listener_arguments("wayvnc: v0.10.1", "/a"), ["unix:/a"])
        for version in ("0.8.0", "0.9.0", "1.0.0", "unknown", ""):
            with self.assertRaises(ValueError):
                host.listener_arguments(version, "/a")

    def test_private_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            host.private_directory(path)
            path.chmod(0o755)
            with self.assertRaises(ValueError):
                host.private_directory(path)
            path.chmod(0o700)
            link = path / "link"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                host.private_directory(link)

    def test_existing_endpoint_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            endpoint = path / "vnc.sock"
            endpoint.write_text("do not remove")
            with self.assertRaises(ValueError):
                host.serve(path, "TEST", False, [], -1)
            self.assertEqual(endpoint.read_text(), "do not remove")

    def test_lock_exclusion(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fd = host.lock_directory(path)
            try:
                with self.assertRaises(ValueError):
                    host.lock_directory(path)
            finally:
                os.close(fd)

    def test_launch_failure_removes_config(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fd = host.lock_directory(path)
            try:
                with patch.object(host.subprocess, "Popen", side_effect=FileNotFoundError("fixture")):
                    with self.assertRaises(FileNotFoundError):
                        host.serve(path, "TEST", False, [f"unix:{path}/vnc.sock"], fd)
                self.assertEqual(list(path.glob("*.conf")), [])
            finally:
                os.close(fd)

    @unittest.skipIf(os.getuid() == 0, "helper intentionally refuses root")
    def test_foreground_signal_cleanup(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            wayland = socket.socket(socket.AF_UNIX)
            wayland.bind(str(path / "wayland-test"))
            self.addCleanup(wayland.close)
            binaries = path / "bin"
            binaries.mkdir()
            hyprctl = binaries / "hyprctl"
            hyprctl.write_text("#!/bin/sh\nif [ \"$1\" = -j ]; then echo '[{\"name\":\"TEST\"}]'; else echo test; fi\n")
            wayvnc = binaries / "wayvnc"
            wayvnc.write_text(f"#!{sys.executable}\n" + '''import os, signal, socket, sys
if '--version' in sys.argv:
    print('wayvnc: 0.10.1')
    sys.exit(0)
assert '--disable-resizing' in sys.argv
assert '--disable-input' in sys.argv
assert '--output=TEST' in sys.argv
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[-1].removeprefix('unix:'))
s.listen(1)
signal.pause()
''')
            hyprctl.chmod(0o700)
            wayvnc.chmod(0o700)
            env = dict(os.environ, XDG_RUNTIME_DIR=temp, WAYLAND_DISPLAY="wayland-test",
                       HYPRLAND_INSTANCE_SIGNATURE="fixture", XDG_SESSION_TYPE="wayland",
                       PATH=f"{binaries}:{os.environ['PATH']}")
            subprocess.run([sys.executable, SCRIPT, "setup"], env=env, check=True, capture_output=True, timeout=5)
            process = subprocess.Popen([sys.executable, SCRIPT, "run", "--output", "TEST", "--view-only"],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            endpoint = path / "verde-remote-desktop" / "vnc.sock"
            try:
                deadline = time.monotonic() + 5
                while not endpoint.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(endpoint.is_socket())
                self.assertEqual(endpoint.stat().st_mode & 0o077, 0)
                process.terminate()
                stdout, stderr = process.communicate(timeout=7)
                self.assertEqual(process.returncode, 143, (stdout, stderr))
                self.assertFalse(endpoint.exists())
                self.assertEqual(list(endpoint.parent.glob('*.conf')), [])
                fd = host.lock_directory(endpoint.parent)
                os.close(fd)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.communicate(timeout=7)


if __name__ == "__main__":
    unittest.main()
