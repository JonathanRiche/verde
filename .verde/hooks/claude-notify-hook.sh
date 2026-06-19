#!/bin/sh
# verde-claude-notify-hook
[ "${VERDE:-}" = "1" ] || exit 0
[ -n "${VERDE_SESSION_ID:-}" ] || exit 0

payload="${TMPDIR:-/tmp}/verde-claude-hook.$$"
cat > "$payload" 2>/dev/null || true

event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
[ -n "$event" ] || event="${1:-}"

status=""
case "$event" in
  SessionStart) status="working" ;;
  UserPromptSubmit) status="working" ;;
  Notification)
    # Claude fires Notification for both permission requests and the
    # idle "waiting for your input" nudge. Only the former needs you.
    msg="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    case "$msg" in
      *"waiting for your input"*|*"is idle"*) rm -f "$payload"; exit 0 ;;
      *) status="waiting" ;;
    esac ;;
  Stop) status="done" ;;
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

"$cli" notify --quiet --status "$status" --provider claude >/dev/null 2>&1 || true
rm -f "$payload"
exit 0
