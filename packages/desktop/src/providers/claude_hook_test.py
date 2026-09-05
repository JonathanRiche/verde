"""Exercise generated Claude hooks with isolated lifecycle fixtures."""
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
with tempfile.TemporaryDirectory(prefix="verde-claude-hook-test-") as directory:
    root = Path(directory)
    log = root / "notifications.jsonl"
    cli = root / "verde-stub"
    cli.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                   "with open(os.environ['HOOK_TEST_LOG'], 'a') as f:\n"
                   "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n")
    cli.chmod(0o700)
    env = dict(os.environ, VERDE="1", VERDE_SESSION_ID="fixture:claude/pane:1",
               TMPDIR=str(root), VERDE_CLI=str(cli), HOOK_TEST_LOG=str(log))

    def event(name, **fields):
        before = log.read_text() if log.exists() else ""
        result = subprocess.run(command, input=json.dumps(dict(
            session_id="fixture-session", hook_event_name=name, **fields)),
            text=True, capture_output=True, env=env, timeout=10)
        assert result.returncode == 0, result.stderr
        after = log.read_text() if log.exists() else ""
        if after == before:
            return None
        args = json.loads(after.splitlines()[-1])
        return args[args.index("--status") + 1]

    assert event("SessionStart", source="startup") == "idle"
    assert event("SessionStart", source="compact") is None
    assert event("UserPromptSubmit", prompt="Work") == "working"
    assert event("SessionStart", source="compact") is None
    assert event("SubagentStart", agent_id="child") == "working"
    assert event("Stop") == "waiting"
    assert event("SessionStart", source="compact") is None
    assert event("SubagentStop", agent_id="child") == "done"
    assert event("SessionStart", source="compact") is None
    assert event("UserPromptSubmit", prompt="Interrupted work") == "working"
    assert event("Notification", message="Ready", notification_type="idle_prompt") == "done"
    assert event("Notification", message="Permission needed", notification_type="permission_prompt") == "waiting"
print("Claude compaction and idle lifecycle fixtures passed")
