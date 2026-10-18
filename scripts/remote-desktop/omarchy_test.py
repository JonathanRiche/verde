#!/usr/bin/env python3
"""Isolated safety tests; no real compositor, VNC server, TCP or user state."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("omarchy.py")
spec = importlib.util.spec_from_file_location("omarchy", SCRIPT)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class HostTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
