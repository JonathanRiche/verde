#!/usr/bin/env python3
"""Opt-in WayVNC host for an existing Hyprland session; standard library only."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def private_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Expected an owned, non-symlink directory: {path}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise ValueError(f"Expected mode 0700 (will not change it): {path}")


def runtime_directory():
    value = os.environ.get("XDG_RUNTIME_DIR", "")
    if not value or not Path(value).is_absolute():
        raise ValueError("XDG_RUNTIME_DIR must be the absolute runtime directory of your session")
    runtime = Path(value)
    if runtime.resolve() != runtime:
        raise ValueError("XDG_RUNTIME_DIR must not contain symlinks or '..'")
    private_directory(runtime)
    directory = runtime / "verde-remote-desktop"
    if len(os.fsencode(directory / "control.sock")) >= 108:
        raise ValueError("Runtime path is too long for a Linux Unix socket")
    return directory


def capture(command):
    return subprocess.run(command, check=True, text=True, capture_output=True,
                          timeout=5).stdout.strip()


def session():
    if os.environ.get("XDG_SESSION_TYPE", "wayland") != "wayland":
        raise ValueError("Run from the existing Wayland graphical session")
    display = os.environ.get("WAYLAND_DISPLAY", "")
    if not display or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        raise ValueError("WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE must come from your Hyprland session")
    path = Path(display)
    if not path.is_absolute():
        path = Path(os.environ["XDG_RUNTIME_DIR"]) / path
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("WAYLAND_DISPLAY must name an owned, non-symlink Wayland socket")
    for command in ("hyprctl", "wayvnc"):
        if not shutil.which(command):
            raise ValueError(f"Missing {command}; install it separately, then retry")
    monitors = json.loads(capture(["hyprctl", "-j", "monitors"]))
    return [item["name"] for item in monitors if not item.get("disabled", False)]


def listener_arguments(version, endpoint):
    match = re.search(r"\bv?(\d+)\.(\d+)\.(\d+)\b", version.partition("\n")[0])
    if not match:
        raise ValueError(f"Cannot identify WayVNC version: {version}")
    major, minor, patch = map(int, match.groups())
    if (major, minor, patch) >= (0, 9, 1) and (major, minor) == (0, 9):
        return ["--unix-socket", str(endpoint)]
    if (major, minor) == (0, 10):
        return [f"unix:{endpoint}"]
    raise ValueError("Supported WayVNC interfaces: 0.9.1+ in 0.9.x, or 0.10.x; review newer versions before using")


def lock_directory(directory):
    fd = os.open(directory / "run.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe run.lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ValueError("Another helper owns this endpoint; stop it first") from exc
    except BaseException:
        os.close(fd)
        raise
    return fd


def serve(directory, output, view_only, listener, lock_fd):
    endpoints = [directory / "vnc.sock", directory / "control.sock"]
    for path in endpoints:
        if os.path.lexists(path):
            raise ValueError(f"Refusing existing endpoint {path}; inspect it before manual cleanup")
    config_fd, config_name = tempfile.mkstemp(prefix="wayvnc-", suffix=".conf", dir=directory)
    child = None
    old_handlers = {}

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    try:
        with os.fdopen(config_fd, "w") as config:
            config.write("enable_auth=false\n")
        command = ["wayvnc", f"--config={config_name}",
                   f"--socket={endpoints[1]}", "--disable-resizing", f"--output={output}"]
        if view_only:
            command.append("--disable-input")
        command += listener
        print(f"RFB endpoint (available after WayVNC binds): {endpoints[0]}", flush=True)
        print(shlex.join(command), flush=True)
        # Block termination during spawn so cleanup cannot miss a newly created child.
        signals = {signal.SIGINT, signal.SIGTERM, signal.SIGHUP}
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, signals)
        try:
            for sig in signals:
                old_handlers[sig] = signal.signal(sig, interrupted)
            # Inherit the lock so SIGKILL of the wrapper cannot permit a second host.
            child = subprocess.Popen(command, pass_fds=(lock_fd,),
                                     restore_signals=True,
                                     preexec_fn=lambda: signal.pthread_sigmask(
                                         signal.SIG_SETMASK, previous_mask))
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        returncode = child.wait()
        return returncode if returncode >= 0 else 128 - returncode
    finally:
        for sig in old_handlers:
            signal.signal(sig, signal.SIG_IGN)
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            for path in endpoints:
                try:
                    info = path.lstat()
                    if stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid():
                        path.unlink()
                except FileNotFoundError:
                    pass
        Path(config_name).unlink(missing_ok=True)
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("setup", help="Create only a private runtime directory; start nothing")
    commands.add_parser("doctor", help="Read-only session, dependency and endpoint checks")
    run = commands.add_parser("run", help="Explicitly start WayVNC in the foreground")
    run.add_argument("--output", required=True, help="Existing monitor name from doctor")
    run.add_argument("--view-only", action="store_true", help="Disable remote keyboard and pointer input")
    args = parser.parse_args()
    if sys.platform != "linux" or os.getuid() == 0:
        raise ValueError("Run as the graphical session owner on Linux, never as root")
    os.umask(0o077)
    directory = runtime_directory()
    if args.command == "setup":
        directory.mkdir(mode=0o700, exist_ok=True)
        private_directory(directory)
        print(f"Prepared {directory}; nothing started. RFB path: {directory / 'vnc.sock'}")
        return 0
    outputs = session()
    version = capture(["wayvnc", "--version"])
    listener = listener_arguments(version, directory / "vnc.sock")
    if args.command == "doctor":
        print(version)
        print(capture(["hyprctl", "version"]))
        print("Active outputs: " + ", ".join(outputs))
        if os.path.lexists(directory):
            private_directory(directory)
            endpoint = directory / "vnc.sock"
            if os.path.lexists(endpoint):
                info = endpoint.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise ValueError(f"Unsafe endpoint: {endpoint}")
                print(f"Private socket exists: {endpoint} (existence does not prove liveness)")
            else:
                print("No RFB socket; helper is not listening here")
        else:
            print("Run setup to prepare the private endpoint directory")
        print("Checks passed; capture/input permissions and RFB handshake still require a manual run")
        return 0
    private_directory(directory)
    if args.output not in outputs:
        raise ValueError(f"Output {args.output!r} is not active; choose from {outputs}")
    fd = lock_directory(directory)
    try:
        return serve(directory, args.output, args.view_only, listener, fd)
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"omarchy remote desktop: {error}", file=sys.stderr)
        sys.exit(1)
