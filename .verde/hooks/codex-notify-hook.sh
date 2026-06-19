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
title=""
case "$event" in
  SessionStart) status="working" ;;
  UserPromptSubmit)
    status="working"
    # Codex has no session-title field, but UserPromptSubmit carries the
    # prompt text. Derive a pane label from it (like a chat thread title):
    # prefer jq for correct JSON decoding, else a best-effort sed fallback;
    # collapse whitespace and truncate to a sidebar-friendly length.
    if command -v jq >/dev/null 2>&1; then
      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
    else
      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    fi
    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
    ;;
  PermissionRequest) status="waiting" ;;
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

if [ -n "$title" ]; then
  "$cli" notify --quiet --status "$status" --title "$title" --provider codex >/dev/null 2>&1 || true
else
  "$cli" notify --quiet --status "$status" --provider codex >/dev/null 2>&1 || true
fi
rm -f "$payload"
exit 0
