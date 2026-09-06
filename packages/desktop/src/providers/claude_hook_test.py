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

    def titled(name, **fields):
        before = log.read_text() if log.exists() else ""
        result = subprocess.run(command, input=json.dumps(dict(
            session_id="fixture-session", hook_event_name=name, **fields)),
            text=True, capture_output=True, env=env, timeout=10)
        assert result.returncode == 0, result.stderr
        after = log.read_text() if log.exists() else ""
        if after == before:
            return None
        args = json.loads(after.splitlines()[-1])
        title = args[args.index("--title") + 1] if "--title" in args else None
        return args[args.index("--status") + 1], title

    # Claude names the session (ai-title) while the first reply streams and on
    # /rename (custom-title); the sidebar should show that, not the prompt.
    transcript = root / "session.jsonl"
    transcript.write_text(json.dumps(dict(type="user", message="hi")) + "\n")
    tp = str(transcript)
    assert titled("SessionStart", source="startup", transcript_path=tp) == ("idle", None)
    assert titled("UserPromptSubmit", prompt="Speed up the chat UI please", transcript_path=tp) == ("working", "Speed up the chat UI please")
    assert titled("PreToolUse", tool_name="Bash", transcript_path=tp) == ("working", "Speed up the chat UI please")
    with transcript.open("a") as f:
        f.write(json.dumps(dict(type="ai-title", aiTitle="Chat UI performance optimization", sessionId="fixture-session")) + "\n")
        f.write(json.dumps(dict(type="assistant", message="on it")) + "\n")
    assert titled("PreToolUse", tool_name="Bash", transcript_path=tp) == ("working", "Chat UI performance optimization")
    # Once the title is known, tool boundaries stop producing notifications.
    assert titled("PreToolUse", tool_name="Bash", transcript_path=tp) is None
    assert titled("Stop", transcript_path=tp) == ("done", "Chat UI performance optimization")
    # A later prompt keeps the session title instead of reverting to the prompt text.
    assert titled("UserPromptSubmit", prompt="yes b/c we can query", transcript_path=tp) == ("working", "Chat UI performance optimization")
    with transcript.open("a") as f:
        f.write(json.dumps(dict(type="custom-title", customTitle="Chat perf work", sessionId="fixture-session")) + "\n")
    assert titled("Stop", transcript_path=tp) == ("done", "Chat perf work")
    # Without a transcript the cached title still applies.
    assert titled("Stop") == ("done", "Chat perf work")
print("Claude compaction, idle, and session title fixtures passed")
