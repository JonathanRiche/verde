#!/bin/sh
# verde-codex-notify-hook
[ "${VERDE:-}" = "1" ] || exit 0
[ -n "${VERDE_SESSION_ID:-}" ] || exit 0

payload="${TMPDIR:-/tmp}/verde-codex-hook.$$"
cat > "$payload" 2>/dev/null || true

event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
[ -n "$event" ] || event="$(sed -n 's/.*"event"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
[ -n "$event" ] || event="${1:-}"

status=""
title="Codex"
body=""
case "$event" in
  SessionStart)
    status="working"; title="Codex started"; body="Session started." ;;
  UserPromptSubmit)
    status="working"; title="Codex working"; body="Prompt submitted." ;;
  PermissionRequest)
    status="waiting"; title="Codex needs approval"; body="Review the pending approval in the terminal." ;;
  Stop)
    status="done"; title="Codex done"; body="Turn complete." ;;
  *)
    rm -f "$payload"; exit 0 ;;
esac

cli="${VERDE_CLI:-verde}"
if ! command -v "$cli" >/dev/null 2>&1; then
  if [ -x "./zig-out/bin/verde" ]; then
    cli="./zig-out/bin/verde"
  else
    cli="verde"
  fi
fi

"$cli" notify --quiet --status "$status" --title "$title" --body "$body" >/dev/null 2>&1 || true
rm -f "$payload"
exit 0
