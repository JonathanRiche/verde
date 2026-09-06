#!/bin/sh
# verde-codex-notify-hook
[ "${VERDE:-}" = "1" ] || exit 0
[ -n "${VERDE_SESSION_ID:-}" ] || exit 0

payload="${TMPDIR:-/tmp}/verde-codex-hook.$$"
cat > "$payload" 2>/dev/null || true

event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
[ -n "$event" ] || event="$(sed -n 's/.*"event"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
[ -n "$event" ] || event="${1:-}"
update_agent_status() {
  provider="$1"
  activity="$2"
  initial_status="$3"
  [ -n "$VERDE_SESSION_ID" ] || return 1
  session_key="$(printf '%s' "$VERDE_SESSION_ID" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
  [ -n "$session_key" ] || return 1
  state_root="${TMPDIR:-/tmp}/verde-agent-status"
  state_dir="$state_root/$provider-$session_key"
  lock_dir="$state_dir.lock"
  mkdir -p "$state_root" 2>/dev/null || return 1
  attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || return 1
    sleep 0.01
  done
  if [ "$activity" = "session-start" ]; then
    rm -rf "$state_dir"
  fi
  children_dir="$state_dir/children"
  stops_dir="$state_dir/stops"
  mkdir -p "$children_dir" "$stops_dir" 2>/dev/null || { rmdir "$lock_dir" 2>/dev/null; return 1; }
  parent="$(cat "$state_dir/parent" 2>/dev/null)"
  [ -n "$parent" ] || parent="idle"
  case "$activity" in
    session-start)
      parent="$initial_status"
      ;;
    parent-working|parent-waiting|parent-error)
      parent="${activity#parent-}"
      ;;
    parent-idle)
      parent="idle"
      ;;
    child-start|child-stop)
      child_id=""
      case "$provider" in
        cursor) child_fields="subagent_id tool_call_id task" ;;
        grok) child_fields="subagentId subagent_id" ;;
        *) child_fields="agent_id subagent_id agentId subagentId tool_call_id toolCallId task" ;;
      esac
      for field in $child_fields; do
        if command -v jq >/dev/null 2>&1; then
          child_id="$(jq -r --arg field "$field" '.[$field] // empty' "$payload" 2>/dev/null)"
        else
          child_id="$(sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$payload" | head -n 1)"
        fi
        [ -z "$child_id" ] || break
      done
      [ -n "$child_id" ] || child_id="$(cat "$payload" 2>/dev/null)"
      fingerprint="$(printf '%s' "$child_id" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
      [ -n "$fingerprint" ] || fingerprint="$$"
      child_path="$children_dir/$fingerprint"
      stop_path="$stops_dir/$fingerprint"
      if [ "$provider" = "cursor" ]; then
        task=""
        if command -v jq >/dev/null 2>&1; then
          task="$(jq -r '.task // empty' "$payload" 2>/dev/null)"
        else
          task="$(sed -n 's/.*"task"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        fi
        task_fingerprint="$(printf '%s' "$task" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
        task_stop_path=""
        [ -z "$task" ] || task_stop_path="$stops_dir/task-$task_fingerprint"
        if [ "$activity" = "child-start" ]; then
          stopped=false
          [ ! -f "$stop_path" ] || stopped=true
          [ -z "$task_stop_path" ] || [ ! -f "$task_stop_path" ] || stopped=true
          [ "$stopped" = true ] || printf '%s' "$task_fingerprint" > "$child_path"
        elif [ ! -f "$stop_path" ]; then
          : > "$stop_path"
          [ -z "$task_stop_path" ] || : > "$task_stop_path"
          if [ -f "$child_path" ]; then
            rm -f "$child_path"
          elif [ -n "$task" ]; then
              for candidate in "$children_dir"/*; do
                [ -f "$candidate" ] || continue
                [ "$(cat "$candidate" 2>/dev/null)" = "$task_fingerprint" ] || continue
                rm -f "$candidate"
                break
              done
          fi
        fi
      elif [ "$activity" = "child-start" ]; then
        [ -f "$stop_path" ] || : > "$child_path"
      elif [ ! -f "$stop_path" ]; then
        : > "$stop_path"
        rm -f "$child_path"
      fi
      ;;
  esac
  count="$(find "$children_dir" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')"
  case "$count" in ""|*[!0-9]*) count=0 ;; esac
  printf '%s' "$parent" > "$state_dir/parent"
  if [ "$activity" = "session-start" ]; then
    status="$initial_status"
  else
    case "$parent" in
      working|waiting|error) status="$parent" ;;
      *) if [ "$count" -gt 0 ]; then status="waiting"; else status="done"; fi ;;
    esac
  fi
  rmdir "$lock_dir" 2>/dev/null
  printf '%s' "$status"
}
session_key="$(printf '%s' "$VERDE_SESSION_ID" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
state_dir="${TMPDIR:-/tmp}/verde-agent-status/codex-$session_key"
if command -v jq >/dev/null 2>&1; then
  provider_session_id="$(jq -r '.session_id // empty' "$payload" 2>/dev/null)"
else
  provider_session_id="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^" ]*\)".*/\1/p' "$payload" | head -n 1)"
fi
bound_session="$(cat "$state_dir/provider_session_id" 2>/dev/null)"
# Subagent tool hooks inherit the pane environment, but own a different thread.
if [ "$event" != "SessionStart" ] && [ -n "$bound_session" ] && [ -n "$provider_session_id" ] && [ "$bound_session" != "$provider_session_id" ]; then
  rm -f "$payload"; exit 0
fi
activity=""
title=""
case "$event" in
  SessionStart) activity="session-start" ;;
  UserPromptSubmit)
    activity="parent-working"
    # Use the first prompt until Codex saves its generated session name.
    # Derive a temporary pane label from the prompt:
    # prefer jq for correct JSON decoding, else a best-effort sed fallback;
    # collapse whitespace and truncate to a sidebar-friendly length.
    if command -v jq >/dev/null 2>&1; then
      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
    else
      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    fi
    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
    ;;
  PreToolUse) activity="parent-working" ;;
  PermissionRequest) activity="parent-waiting" ;;
  SubagentStart) activity="child-start" ;;
  SubagentStop) activity="child-stop" ;;
  Stop) activity="parent-idle" ;;
  *)
    rm -f "$payload"; exit 0 ;;
esac
status="$(update_agent_status codex "$activity" working)"
[ -n "$status" ] || { rm -f "$payload"; exit 0; }
[ -z "$provider_session_id" ] || printf '%s' "$provider_session_id" > "$state_dir/provider_session_id"
title_path="$state_dir/title"
# Names are appended to Codex's index after UserPromptSubmit. Refresh
# at the next tool boundary (or Stop for a reply without tools).
provider_title=""
if command -v jq >/dev/null 2>&1; then
  if [ -n "$provider_session_id" ]; then
    provider_title="$(jq -Rnr --arg id "$provider_session_id" 'reduce inputs as $line (""; (try ($line | fromjson) catch null) as $row | if ($row | type) == "object" and $row.id == $id and ($row.thread_name | type) == "string" and ($row.thread_name | length) > 0 then $row.thread_name else . end)' "${CODEX_HOME:-${HOME:-}/.codex}/session_index.jsonl" 2>/dev/null)"
  fi
fi
if [ -n "$provider_session_id" ]; then export VERDE_PROVIDER_THREAD_ID="$provider_session_id"; else unset VERDE_PROVIDER_THREAD_ID; fi
if [ -n "$provider_title" ]; then
  title="$provider_title"
elif [ -s "$title_path" ]; then
  title="$(cat "$title_path" 2>/dev/null)"
fi
[ -z "$title" ] || printf '%s' "$title" > "$title_path"

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
