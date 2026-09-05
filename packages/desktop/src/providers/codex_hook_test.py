"""Exercise a generated Codex hook against isolated provider and Verde fixtures."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

hook = str(Path(sys.argv[1]).resolve())
if hook.endswith(".ps1"):
    powershell = shutil.which("pwsh")
    if not powershell or subprocess.run([powershell, "-NoLogo", "-NoProfile", "-Command", "exit 0"], capture_output=True, timeout=10).returncode != 0:
        print("PowerShell fixture skipped: pwsh unavailable")
        sys.exit(0)
    command = [powershell, "-NoLogo", "-NoProfile", "-File", hook]
else:
    if shutil.which("jq") is None:
        print("POSIX title fixture skipped: jq unavailable")
        sys.exit(0)
    command = ["sh", hook]
with tempfile.TemporaryDirectory(prefix="verde-codex-hook-test-") as directory:
    root = Path(directory)
    codex_home = root / "codex home"
    codex_home.mkdir()
    log = root / "notifications.jsonl"
    cli = root / "verde-stub"
    cli.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                   "with open(os.environ['HOOK_TEST_LOG'], 'a') as f:\n"
                   "    f.write(json.dumps({'args': sys.argv[1:], 'thread': os.environ.get('VERDE_PROVIDER_THREAD_ID')}) + '\\n')\n")
    cli.chmod(0o700)
    env = dict(os.environ, VERDE="1", VERDE_SESSION_ID="fixture:opaque/pane:1",
               CODEX_HOME=str(codex_home), TMPDIR=str(root), VERDE_CLI=str(cli),
               HOOK_TEST_LOG=str(log))
    thread_id = "fixture-thread"

    def event(name, **fields):
        result = subprocess.run(command, input=json.dumps(dict(
            session_id=thread_id, hook_event_name=name, **fields)),
            text=True, capture_output=True, env=env, timeout=10)
        assert result.returncode == 0, result.stderr
        assert result.stdout == "", result.stdout
        row = json.loads(log.read_text().splitlines()[-1])
        assert row["thread"] == thread_id, row
        args = row["args"]
        return args[args.index("--status") + 1], (args[args.index("--title") + 1] if "--title" in args else None)

    assert event("SessionStart")[0] == "working"
    assert event("UserPromptSubmit", prompt="First prompt about terminal scrolling") == (
        "working", "First prompt about terminal scrolling")
    index = codex_home / "session_index.jsonl"
    generated = 'Fix café scrolling "smoothly" $(do-not-execute)'
    index.write_text(json.dumps({"id": thread_id, "thread_name": "Old name"}) + "\n" +
                     "incomplete JSON\n42\n" +
                     json.dumps({"id": "other-thread", "thread_name": "Wrong thread"}) + "\n" +
                     json.dumps({"id": thread_id, "thread_name": generated}) + "\n")
    assert event("PreToolUse", tool_name="Bash") == ("working", generated)
    before_nested = log.read_text()
    nested = subprocess.run(command, input=json.dumps(dict(session_id="child-thread", hook_event_name="PreToolUse", tool_name="Bash")), text=True, capture_output=True, env=env, timeout=10)
    assert nested.returncode == 0, nested.stderr
    assert log.read_text() == before_nested, "Subagent must not rename or change its parent's pane"
    assert event("PermissionRequest") == ("waiting", generated)
    assert event("PreToolUse", tool_name="Bash") == ("working", generated)
    assert event("Stop") == ("done", generated)
    with index.open("a") as file:
        file.write(json.dumps({"id": thread_id, "thread_name": "Renamed by Codex"}) + "\n")
    assert event("UserPromptSubmit", prompt="Different follow-up prompt") == ("working", "Renamed by Codex")
    index.unlink()
    assert event("UserPromptSubmit", prompt="Another follow-up") == ("working", "Renamed by Codex")
    assert event("Stop") == ("done", "Renamed by Codex")
    thread_id = "second-thread"
    assert event("SessionStart") == ("working", None)
    assert event("UserPromptSubmit", prompt="Fresh session") == ("working", "Fresh session")
print("Codex hook title and lifecycle fixtures passed")
