#!/bin/sh
# verde-claude-notify-hook
[ "${VERDE:-}" = "1" ] || exit 0
[ -n "${VERDE_SESSION_ID:-}" ] || exit 0

payload="${TMPDIR:-/tmp}/verde-claude-hook.$$"
cat > "$payload" 2>/dev/null || true

event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
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
state_dir="${TMPDIR:-/tmp}/verde-agent-status/claude-$session_key"
if command -v jq >/dev/null 2>&1; then
  transcript_path="$(jq -r '.transcript_path // empty' "$payload" 2>/dev/null)"
else
  transcript_path="$(sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
fi
activity=""
title=""
case "$event" in
  SessionStart)
    if command -v jq >/dev/null 2>&1; then
      source="$(jq -r '.source // empty' "$payload" 2>/dev/null)"
    else
      source="$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    fi
    # Compaction preserves the previous lifecycle; manual /compact
    # can run at an idle prompt without starting an agentic turn.
    if [ "$source" = "compact" ]; then rm -f "$payload"; exit 0; else activity="session-start"; fi
    ;;
  UserPromptSubmit)
    activity="parent-working"
    if command -v jq >/dev/null 2>&1; then
      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
    else
      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    fi
    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
    ;;
  PreToolUse)
    # Claude names the session while the first reply streams, after
    # UserPromptSubmit. Poll at tool boundaries only until it is known.
    [ ! -s "$state_dir/provider_title" ] || { rm -f "$payload"; exit 0; }
    activity="parent-working" ;;
  Notification)
    # An idle nudge reconciles a missed Stop/interrupt; permission
    # notifications still represent waiting on the user.
    msg="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    kind="$(sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    case "$kind:$msg" in
      idle_prompt:*|*"waiting for your input"*|*"is idle"*) activity="parent-idle" ;;
      *) activity="parent-waiting" ;;
    esac ;;
  SubagentStart) activity="child-start" ;;
  SubagentStop) activity="child-stop" ;;
  Stop) activity="parent-idle" ;;
  *)
    rm -f "$payload"; exit 0 ;;
esac
status="$(update_agent_status claude "$activity" idle)"
[ -n "$status" ] || { rm -f "$payload"; exit 0; }
title_path="$state_dir/title"
# Claude appends ai-title rows once it names the session and custom-title
# rows on /rename. The user's name wins; both beat the prompt excerpt so
# the sidebar shows the chat title rather than the latest prompt.
provider_title=""
if [ -n "$transcript_path" ] && [ -r "$transcript_path" ]; then
  title_rows="$(grep -E '"type"[[:space:]]*:[[:space:]]*"(ai-title|custom-title)"' "$transcript_path" 2>/dev/null | tail -n 40)"
  if [ -n "$title_rows" ]; then
    if command -v jq >/dev/null 2>&1; then
      provider_title="$(printf '%s\n' "$title_rows" | jq -Rrs 'split("\n") | map(select(length > 0) | (try fromjson catch null)) | map(select(type == "object")) | ((map(select(.type == "custom-title" and (.customTitle | type) == "string" and (.customTitle | length) > 0)) | last | .customTitle) // (map(select(.type == "ai-title" and (.aiTitle | type) == "string" and (.aiTitle | length) > 0)) | last | .aiTitle) // empty)' 2>/dev/null)"
    else
      provider_title="$(printf '%s\n' "$title_rows" | sed -n 's/.*"customTitle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
      [ -n "$provider_title" ] || provider_title="$(printf '%s\n' "$title_rows" | sed -n 's/.*"aiTitle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tail -n 1)"
    fi
  fi
fi
if [ -n "$provider_title" ]; then
  title="$(printf '%s' "$provider_title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
  [ -z "$title" ] || printf '%s' "$title" > "$state_dir/provider_title" 2>/dev/null
elif [ -z "$title" ] && [ -s "$title_path" ]; then
  title="$(cat "$title_path" 2>/dev/null)"
fi
[ -z "$title" ] || printf '%s' "$title" > "$title_path" 2>/dev/null

cli="${VERDE_CLI:-verde}"
case "$cli" in
  *" (deleted)") cli="${cli% (deleted)}" ;;
esac
if ! command -v "$cli" >/dev/null 2>&1; then
  if [ -x "./zig-out/bin/verde" ]; then
    cli="./zig-out/bin/verde"
  else
    cli="verde"
  fi
fi

if [ -n "$title" ]; then
  "$cli" notify --quiet --status "$status" --title "$title" --provider claude >/dev/null 2>&1 || true
else
  "$cli" notify --quiet --status "$status" --provider claude >/dev/null 2>&1 || true
fi
rm -f "$payload"
exit 0

