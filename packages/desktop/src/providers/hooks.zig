const std = @import("std");
const builtin = @import("builtin");
const platform_paths = @import("platform_paths");

const CODEX_HOOK_MARKER = "verde-codex-notify-hook";
const CODEX_PROJECT_HOOK_NEEDLE = "codex-notify-hook.";
const CODEX_HOOK_REL_PATH = ".verde/hooks/codex-notify-hook.sh";
const CODEX_WINDOWS_HOOK_REL_PATH = ".verde/hooks/codex-notify-hook.ps1";
const CODEX_HOOKS_JSON_REL_PATH = ".codex/hooks.json";

// Global (all-projects) Codex hooks live in ~/.codex/hooks.json with the hook
// script at an absolute path, mirroring the global Claude integration. Codex
// merges global and project hooks, so we merge our entries in while preserving
// any hooks the user already runs (e.g. their own notify-stop.sh).
const CODEX_GLOBAL_HOOK_REL = ".codex/verde-codex-notify-hook.sh";
const CODEX_WINDOWS_GLOBAL_HOOK_REL = ".codex/verde-codex-notify-hook.ps1";
const CODEX_GLOBAL_HOOKS_JSON_REL = ".codex/hooks.json";
const CODEX_GLOBAL_HOOK_NEEDLE = "verde-codex-notify-hook";
const CodexHookEvent = struct { name: []const u8, status_message: []const u8 };
const CODEX_HOOK_EVENTS = [_]CodexHookEvent{
    .{ .name = "SessionStart", .status_message = "Syncing Verde session" },
    .{ .name = "UserPromptSubmit", .status_message = "Marking Verde agent busy" },
    .{ .name = "PreToolUse", .status_message = "Syncing Verde agent title" },
    .{ .name = "PermissionRequest", .status_message = "Marking Verde agent waiting" },
    .{ .name = "SubagentStart", .status_message = "Tracking Verde subagent" },
    .{ .name = "SubagentStop", .status_message = "Updating Verde subagent status" },
    .{ .name = "Stop", .status_message = "Marking Verde agent done" },
};

const CURSOR_HOOK_MARKER = "verde-cursor-notify-hook";
const CURSOR_PROJECT_HOOK_REL_PATH = ".cursor/hooks/verde-cursor-notify-hook.sh";
const CURSOR_WINDOWS_PROJECT_HOOK_REL_PATH = ".cursor/hooks/verde-cursor-notify-hook.ps1";
const CURSOR_HOOKS_JSON_REL_PATH = ".cursor/hooks.json";
const CURSOR_HOOK_EVENTS = [_][]const u8{ "sessionStart", "beforeSubmitPrompt", "preToolUse", "subagentStart", "subagentStop", "stop" };

const PI_GLOBAL_PLUGIN_REL = ".pi/agent/extensions/verde-notify.ts";
const PI_GLOBAL_PLUGIN_NEEDLE = "verde-pi-notify-extension";

// Command hooks run in separate processes and can overlap. This state machine
// serializes updates by Verde pane, deduplicates hooks merged at both global
// and project scope, and keeps the parent status authoritative while children
// run. Each provider script maps its native event names to these activities.
const POSIX_AGENT_ACTIVITY_STATE =
    \\update_agent_status() {
    \\  provider="$1"
    \\  activity="$2"
    \\  initial_status="$3"
    \\  [ -n "$VERDE_SESSION_ID" ] || return 1
    \\  session_key="$(printf '%s' "$VERDE_SESSION_ID" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
    \\  [ -n "$session_key" ] || return 1
    \\  state_root="${TMPDIR:-/tmp}/verde-agent-status"
    \\  state_dir="$state_root/$provider-$session_key"
    \\  lock_dir="$state_dir.lock"
    \\  mkdir -p "$state_root" 2>/dev/null || return 1
    \\  attempts=0
    \\  while ! mkdir "$lock_dir" 2>/dev/null; do
    \\    attempts=$((attempts + 1))
    \\    [ "$attempts" -lt 100 ] || return 1
    \\    sleep 0.01
    \\  done
    \\  if [ "$activity" = "session-start" ]; then
    \\    rm -rf "$state_dir"
    \\  fi
    \\  children_dir="$state_dir/children"
    \\  stops_dir="$state_dir/stops"
    \\  mkdir -p "$children_dir" "$stops_dir" 2>/dev/null || { rmdir "$lock_dir" 2>/dev/null; return 1; }
    \\  parent="$(cat "$state_dir/parent" 2>/dev/null)"
    \\  [ -n "$parent" ] || parent="idle"
    \\  case "$activity" in
    \\    session-start)
    \\      parent="$initial_status"
    \\      ;;
    \\    parent-working|parent-waiting|parent-error)
    \\      parent="${activity#parent-}"
    \\      ;;
    \\    parent-idle)
    \\      parent="idle"
    \\      ;;
    \\    child-start|child-stop)
    \\      child_id=""
    \\      case "$provider" in
    \\        cursor) child_fields="subagent_id tool_call_id task" ;;
    \\        grok) child_fields="subagentId subagent_id" ;;
    \\        *) child_fields="agent_id subagent_id agentId subagentId tool_call_id toolCallId task" ;;
    \\      esac
    \\      for field in $child_fields; do
    \\        if command -v jq >/dev/null 2>&1; then
    \\          child_id="$(jq -r --arg field "$field" '.[$field] // empty' "$payload" 2>/dev/null)"
    \\        else
    \\          child_id="$(sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$payload" | head -n 1)"
    \\        fi
    \\        [ -z "$child_id" ] || break
    \\      done
    \\      [ -n "$child_id" ] || child_id="$(cat "$payload" 2>/dev/null)"
    \\      fingerprint="$(printf '%s' "$child_id" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
    \\      [ -n "$fingerprint" ] || fingerprint="$$"
    \\      child_path="$children_dir/$fingerprint"
    \\      stop_path="$stops_dir/$fingerprint"
    \\      if [ "$provider" = "cursor" ]; then
    \\        task=""
    \\        if command -v jq >/dev/null 2>&1; then
    \\          task="$(jq -r '.task // empty' "$payload" 2>/dev/null)"
    \\        else
    \\          task="$(sed -n 's/.*"task"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
    \\        fi
    \\        task_fingerprint="$(printf '%s' "$task" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
    \\        task_stop_path=""
    \\        [ -z "$task" ] || task_stop_path="$stops_dir/task-$task_fingerprint"
    \\        if [ "$activity" = "child-start" ]; then
    \\          stopped=false
    \\          [ ! -f "$stop_path" ] || stopped=true
    \\          [ -z "$task_stop_path" ] || [ ! -f "$task_stop_path" ] || stopped=true
    \\          [ "$stopped" = true ] || printf '%s' "$task_fingerprint" > "$child_path"
    \\        elif [ ! -f "$stop_path" ]; then
    \\          : > "$stop_path"
    \\          [ -z "$task_stop_path" ] || : > "$task_stop_path"
    \\          if [ -f "$child_path" ]; then
    \\            rm -f "$child_path"
    \\          elif [ -n "$task" ]; then
    \\              for candidate in "$children_dir"/*; do
    \\                [ -f "$candidate" ] || continue
    \\                [ "$(cat "$candidate" 2>/dev/null)" = "$task_fingerprint" ] || continue
    \\                rm -f "$candidate"
    \\                break
    \\              done
    \\          fi
    \\        fi
    \\      elif [ "$activity" = "child-start" ]; then
    \\        [ -f "$stop_path" ] || : > "$child_path"
    \\      elif [ ! -f "$stop_path" ]; then
    \\        : > "$stop_path"
    \\        rm -f "$child_path"
    \\      fi
    \\      ;;
    \\  esac
    \\  count="$(find "$children_dir" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')"
    \\  case "$count" in ""|*[!0-9]*) count=0 ;; esac
    \\  printf '%s' "$parent" > "$state_dir/parent"
    \\  if [ "$activity" = "session-start" ]; then
    \\    status="$initial_status"
    \\  else
    \\    case "$parent" in
    \\      working|waiting|error) status="$parent" ;;
    \\      *) if [ "$count" -gt 0 ]; then status="waiting"; else status="done"; fi ;;
    \\    esac
    \\  fi
    \\  rmdir "$lock_dir" 2>/dev/null
    \\  printf '%s' "$status"
    \\}
    \\
;

const POWERSHELL_AGENT_ACTIVITY_STATE =
    \\function Update-AgentStatus {
    \\  param([string]$Provider, [string]$Activity, [string]$InitialStatus, [string]$PayloadText)
    \\  if ([string]::IsNullOrWhiteSpace($env:VERDE_SESSION_ID)) { return '' }
    \\  $sessionBytes = [Text.Encoding]::UTF8.GetBytes($env:VERDE_SESSION_ID)
    \\  $sessionSha = [Security.Cryptography.SHA256]::Create()
    \\  try { $sessionFingerprint = [BitConverter]::ToString($sessionSha.ComputeHash($sessionBytes)).Replace('-', '') } finally { $sessionSha.Dispose() }
    \\  $stateRoot = Join-Path ([IO.Path]::GetTempPath()) 'verde-agent-status'
    \\  $stateDir = Join-Path $stateRoot ($Provider + '-' + $sessionFingerprint)
    \\  $lockDir = $stateDir + '.lock'
    \\  New-Item -ItemType Directory -Path $stateRoot -Force -ErrorAction SilentlyContinue | Out-Null
    \\  $locked = $false
    \\  for ($attempt = 0; $attempt -lt 100 -and -not $locked; $attempt++) {
    \\    try { New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null; $locked = $true }
    \\    catch { Start-Sleep -Milliseconds 10 }
    \\  }
    \\  if (-not $locked) { return '' }
    \\  try {
    \\    if ($Activity -eq 'session-start') { Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue }
    \\    $childrenDir = Join-Path $stateDir 'children'
    \\    $stopsDir = Join-Path $stateDir 'stops'
    \\    New-Item -ItemType Directory -Path $childrenDir -Force -ErrorAction SilentlyContinue | Out-Null
    \\    New-Item -ItemType Directory -Path $stopsDir -Force -ErrorAction SilentlyContinue | Out-Null
    \\    $parentPath = Join-Path $stateDir 'parent'
    \\    $parent = if (Test-Path -LiteralPath $parentPath) { (Get-Content -LiteralPath $parentPath -Raw) } else { 'idle' }
    \\    switch ($Activity) {
    \\      'session-start' { $parent = $InitialStatus }
    \\      'parent-working' { $parent = 'working' }
    \\      'parent-waiting' { $parent = 'waiting' }
    \\      'parent-error' { $parent = 'error' }
    \\      'parent-idle' { $parent = 'idle' }
    \\      { $_ -in 'child-start', 'child-stop' } {
    \\        $childId = ''
    \\        try {
    \\          $childPayload = ConvertFrom-Json -InputObject $PayloadText
    \\          $childFields = switch ($Provider) {
    \\            'cursor' { @('subagent_id', 'tool_call_id', 'task'); break }
    \\            'grok' { @('subagentId', 'subagent_id'); break }
    \\            default { @('agent_id', 'subagent_id', 'agentId', 'subagentId', 'tool_call_id', 'toolCallId', 'task'); break }
    \\          }
    \\          foreach ($field in $childFields) {
    \\            if ($null -ne $childPayload.$field -and -not [string]::IsNullOrWhiteSpace([string]$childPayload.$field)) {
    \\              $childId = [string]$childPayload.$field
    \\              break
    \\            }
    \\          }
    \\        } catch {}
    \\        if ([string]::IsNullOrWhiteSpace($childId)) { $childId = $PayloadText }
    \\        $bytes = [Text.Encoding]::UTF8.GetBytes($childId)
    \\        $sha = [Security.Cryptography.SHA256]::Create()
    \\        try { $fingerprint = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    \\        $childPath = Join-Path $childrenDir $fingerprint
    \\        $stopPath = Join-Path $stopsDir $fingerprint
    \\        if ($Provider -eq 'cursor') {
    \\          $task = if ($null -ne $childPayload -and $null -ne $childPayload.task) { [string]$childPayload.task } else { '' }
    \\          $taskBytes = [Text.Encoding]::UTF8.GetBytes($task)
    \\          $taskSha = [Security.Cryptography.SHA256]::Create()
    \\          try { $taskFingerprint = [BitConverter]::ToString($taskSha.ComputeHash($taskBytes)).Replace('-', '') } finally { $taskSha.Dispose() }
    \\          $taskStopPath = if ([string]::IsNullOrWhiteSpace($task)) { $null } else { Join-Path $stopsDir ('task-' + $taskFingerprint) }
    \\          if ($Activity -eq 'child-start') {
    \\            $stopped = (Test-Path -LiteralPath $stopPath) -or ($null -ne $taskStopPath -and (Test-Path -LiteralPath $taskStopPath))
    \\            if (-not $stopped) { Set-Content -LiteralPath $childPath -Value $taskFingerprint -NoNewline }
    \\          } elseif (-not (Test-Path -LiteralPath $stopPath)) {
    \\            New-Item -ItemType File -Path $stopPath -Force -ErrorAction SilentlyContinue | Out-Null
    \\            if ($null -ne $taskStopPath) { New-Item -ItemType File -Path $taskStopPath -Force -ErrorAction SilentlyContinue | Out-Null }
    \\            if (Test-Path -LiteralPath $childPath) {
    \\              Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    \\            } elseif (-not [string]::IsNullOrWhiteSpace($task)) {
    \\                $match = Get-ChildItem -LiteralPath $childrenDir -File -ErrorAction SilentlyContinue | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq $taskFingerprint } | Select-Object -First 1
    \\                if ($null -ne $match) { Remove-Item -LiteralPath $match.FullName -Force -ErrorAction SilentlyContinue }
    \\            }
    \\          }
    \\        } elseif ($Activity -eq 'child-start') {
    \\          if (-not (Test-Path -LiteralPath $stopPath)) { New-Item -ItemType File -Path $childPath -Force -ErrorAction SilentlyContinue | Out-Null }
    \\        } elseif (-not (Test-Path -LiteralPath $stopPath)) {
    \\          New-Item -ItemType File -Path $stopPath -Force -ErrorAction SilentlyContinue | Out-Null
    \\          Remove-Item -LiteralPath $childPath -Force -ErrorAction SilentlyContinue
    \\        }
    \\      }
    \\    }
    \\    $count = @(Get-ChildItem -LiteralPath $childrenDir -File -ErrorAction SilentlyContinue).Count
    \\    Set-Content -LiteralPath $parentPath -Value $parent -NoNewline
    \\    if ($Activity -eq 'session-start') { return $InitialStatus }
    \\    if ($parent -in 'working', 'waiting', 'error') { return $parent }
    \\    return $(if ($count -gt 0) { 'waiting' } else { 'done' })
    \\  } finally {
    \\    Remove-Item -LiteralPath $lockDir -Force -ErrorAction SilentlyContinue
    \\  }
    \\}
    \\
;

pub fn ensureCodexProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const hook_rel_path = codexProjectHookRelPathForOs(builtin.os.tag);
    const hook_path = try std.fs.path.join(allocator, &.{ project_path, hook_rel_path });
    defer allocator.free(hook_path);
    const hooks_json_path = try std.fs.path.join(allocator, &.{ project_path, CODEX_HOOKS_JSON_REL_PATH });
    defer allocator.free(hooks_json_path);

    const io = threaded.io();

    try ensureParentDir(io, hook_path);
    try writeCodexHookScript(allocator, io, hook_path);
    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);

    if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_json_path, allocator, .limited(256 * 1024))) |existing| {
        defer allocator.free(existing);
        if (!codexHooksJsonIsManaged(existing)) return error.CodexHooksJsonExists;
        const merged = try mergeCodexHooks(allocator, existing, hook_command);
        defer if (merged) |content| allocator.free(content);
        if (merged) |content| try writeFileAtomic(allocator, io, hooks_json_path, content, .default_file);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try ensureParentDir(io, hooks_json_path);
    const hooks_json = try codexHooksJsonAlloc(allocator, hook_command);
    defer allocator.free(hooks_json);
    try writeFileAtomic(allocator, io, hooks_json_path, hooks_json, .default_file);
}

/// Removes Verde's legacy project-scoped Codex entries while preserving any
/// unrelated project hooks. Managed TUI launches use the global hook now;
/// keeping both scopes makes Codex execute every lifecycle event twice.
pub fn removeCodexProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ project_path, codexProjectHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_json_path = try std.fs.path.join(allocator, &.{ project_path, CODEX_HOOKS_JSON_REL_PATH });
    defer allocator.free(hooks_json_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_json_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const updated = try removeCodexHooksFromJson(allocator, existing, hook_command);
    defer if (updated) |content| allocator.free(content);
    if (updated) |content| try writeFileAtomic(allocator, io, hooks_json_path, content, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn codexHooksJsonIsManaged(content: []const u8) bool {
    return std.mem.indexOf(u8, content, CODEX_HOOK_MARKER) != null or
        std.mem.indexOf(u8, content, CODEX_PROJECT_HOOK_NEEDLE) != null;
}

fn writeCodexHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const script = if (builtin.os.tag == .windows) codexPowerShellHookScript() else
        \\#!/bin/sh
        \\# verde-codex-notify-hook
        \\[ "${VERDE:-}" = "1" ] || exit 0
        \\[ -n "${VERDE_SESSION_ID:-}" ] || exit 0
        \\
        \\payload="${TMPDIR:-/tmp}/verde-codex-hook.$$"
        \\cat > "$payload" 2>/dev/null || true
        \\
        \\event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\[ -n "$event" ] || event="$(sed -n 's/.*"event"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\[ -n "$event" ] || event="${1:-}"
        \\
    ++ POSIX_AGENT_ACTIVITY_STATE ++
        \\session_key="$(printf '%s' "$VERDE_SESSION_ID" | cksum 2>/dev/null | awk '{print $1 "-" $2}')"
        \\state_dir="${TMPDIR:-/tmp}/verde-agent-status/codex-$session_key"
        \\if command -v jq >/dev/null 2>&1; then
        \\  provider_session_id="$(jq -r '.session_id // empty' "$payload" 2>/dev/null)"
        \\else
        \\  provider_session_id="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^" ]*\)".*/\1/p' "$payload" | head -n 1)"
        \\fi
        \\bound_session="$(cat "$state_dir/provider_session_id" 2>/dev/null)"
        \\# Subagent tool hooks inherit the pane environment, but own a different thread.
        \\if [ "$event" != "SessionStart" ] && [ -n "$bound_session" ] && [ -n "$provider_session_id" ] && [ "$bound_session" != "$provider_session_id" ]; then
        \\  rm -f "$payload"; exit 0
        \\fi
        \\activity=""
        \\title=""
        \\case "$event" in
        \\  SessionStart) activity="session-start" ;;
        \\  UserPromptSubmit)
        \\    activity="parent-working"
        \\    # Use the first prompt until Codex saves its generated session name.
        \\    # Derive a temporary pane label from the prompt:
        \\    # prefer jq for correct JSON decoding, else a best-effort sed fallback;
        \\    # collapse whitespace and truncate to a sidebar-friendly length.
        \\    if command -v jq >/dev/null 2>&1; then
        \\      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    ;;
        \\  PreToolUse) activity="parent-working" ;;
        \\  PermissionRequest) activity="parent-waiting" ;;
        \\  SubagentStart) activity="child-start" ;;
        \\  SubagentStop) activity="child-stop" ;;
        \\  Stop) activity="parent-idle" ;;
        \\  *)
        \\    rm -f "$payload"; exit 0 ;;
        \\esac
        \\status="$(update_agent_status codex "$activity" working)"
        \\[ -n "$status" ] || { rm -f "$payload"; exit 0; }
        \\[ -z "$provider_session_id" ] || printf '%s' "$provider_session_id" > "$state_dir/provider_session_id"
        \\title_path="$state_dir/title"
        \\# Names are appended to Codex's index after UserPromptSubmit. Refresh
        \\# at the next tool boundary (or Stop for a reply without tools).
        \\provider_title=""
        \\if command -v jq >/dev/null 2>&1; then
        \\  if [ -n "$provider_session_id" ]; then
        \\    provider_title="$(jq -Rnr --arg id "$provider_session_id" 'reduce inputs as $line (""; (try ($line | fromjson) catch null) as $row | if ($row | type) == "object" and $row.id == $id and ($row.thread_name | type) == "string" and ($row.thread_name | length) > 0 then $row.thread_name else . end)' "${CODEX_HOME:-${HOME:-}/.codex}/session_index.jsonl" 2>/dev/null)"
        \\  fi
        \\fi
        \\if [ -n "$provider_session_id" ]; then export VERDE_PROVIDER_THREAD_ID="$provider_session_id"; else unset VERDE_PROVIDER_THREAD_ID; fi
        \\if [ -n "$provider_title" ]; then
        \\  title="$provider_title"
        \\elif [ -s "$title_path" ]; then
        \\  title="$(cat "$title_path" 2>/dev/null)"
        \\fi
        \\[ -z "$title" ] || printf '%s' "$title" > "$title_path"
        \\
        \\cli="${VERDE_CLI:-verde}"
        \\if ! command -v "$cli" >/dev/null 2>&1; then
        \\  if [ -x "./zig-out/bin/verde" ]; then
        \\    cli="./zig-out/bin/verde"
        \\  else
        \\    cli="verde"
        \\  fi
        \\fi
        \\
        \\if [ -n "$title" ]; then
        \\  "$cli" notify --quiet --status "$status" --title "$title" --provider codex >/dev/null 2>&1 || true
        \\else
        \\  "$cli" notify --quiet --status "$status" --provider codex >/dev/null 2>&1 || true
        \\fi
        \\rm -f "$payload"
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, hookPermissionsForOs(builtin.os.tag));
}

fn codexHooksJsonAlloc(allocator: std.mem.Allocator, hook_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();
    for (CODEX_HOOK_EVENTS) |event| try writeCodexHookEvent(&s, event.name, hook_path, event.status_message);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeCodexHookEvent(s: *std.json.Stringify, event: []const u8, hook_path: []const u8, status_message: []const u8) !void {
    try s.objectField(event);
    try s.beginArray();
    try s.beginObject();
    try s.objectField("matcher");
    try s.write("*");
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(hook_path);
    try s.objectField("timeout");
    try s.write(5);
    try s.objectField("statusMessage");
    try s.write(status_message);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();
}

const CLAUDE_HOOK_MARKER = "verde-claude-notify-hook";
const CLAUDE_PROJECT_HOOK_NEEDLE = "claude-notify-hook.";
const CLAUDE_HOOK_REL_PATH = ".verde/hooks/claude-notify-hook.sh";
const CLAUDE_WINDOWS_HOOK_REL_PATH = ".verde/hooks/claude-notify-hook.ps1";
// Claude Code merges hooks across settings files, so we target the personal,
// usually-gitignored settings.local.json to avoid touching shared settings.json.
const CLAUDE_SETTINGS_REL_PATH = ".claude/settings.local.json";

pub fn ensureClaudeProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const hook_rel_path = claudeProjectHookRelPathForOs(builtin.os.tag);
    const hook_path = try std.fs.path.join(allocator, &.{ project_path, hook_rel_path });
    defer allocator.free(hook_path);
    const settings_path = try std.fs.path.join(allocator, &.{ project_path, CLAUDE_SETTINGS_REL_PATH });
    defer allocator.free(settings_path);

    const io = threaded.io();

    try ensureParentDir(io, hook_path);
    try writeClaudeHookScript(allocator, io, hook_path);
    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);

    if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), settings_path, allocator, .limited(1024 * 1024))) |existing| {
        defer allocator.free(existing);
        if (!claudeSettingsIsManaged(existing)) return error.ClaudeSettingsExist;
        const merged = try mergeClaudeHooks(allocator, existing, hook_command);
        defer if (merged) |content| allocator.free(content);
        if (merged) |content| try writeFileAtomic(allocator, io, settings_path, content, .default_file);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try ensureParentDir(io, settings_path);
    const settings_json = try claudeSettingsJsonAlloc(allocator, hook_command);
    defer allocator.free(settings_json);
    try writeFileAtomic(allocator, io, settings_path, settings_json, .default_file);
}

fn claudeSettingsIsManaged(content: []const u8) bool {
    return std.mem.indexOf(u8, content, CLAUDE_HOOK_MARKER) != null or
        std.mem.indexOf(u8, content, CLAUDE_PROJECT_HOOK_NEEDLE) != null;
}

fn writeClaudeHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    // Drives Verde surface status and supplies a stable prompt-derived title;
    // Claude's OSC title is often only the generic "Claude Code" label.
    const script = if (builtin.os.tag == .windows) claudePowerShellHookScript() else
        \\#!/bin/sh
        \\# verde-claude-notify-hook
        \\[ "${VERDE:-}" = "1" ] || exit 0
        \\[ -n "${VERDE_SESSION_ID:-}" ] || exit 0
        \\
        \\payload="${TMPDIR:-/tmp}/verde-claude-hook.$$"
        \\cat > "$payload" 2>/dev/null || true
        \\
        \\event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\[ -n "$event" ] || event="${1:-}"
        \\
    ++ POSIX_AGENT_ACTIVITY_STATE ++
        \\activity=""
        \\title=""
        \\case "$event" in
        \\  SessionStart)
        \\    if command -v jq >/dev/null 2>&1; then
        \\      source="$(jq -r '.source // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      source="$(sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    # Compaction preserves the previous lifecycle; manual /compact
        \\    # can run at an idle prompt without starting an agentic turn.
        \\    if [ "$source" = "compact" ]; then rm -f "$payload"; exit 0; else activity="session-start"; fi
        \\    ;;
        \\  UserPromptSubmit)
        \\    activity="parent-working"
        \\    if command -v jq >/dev/null 2>&1; then
        \\      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    ;;
        \\  Notification)
        \\    # An idle nudge reconciles a missed Stop/interrupt; permission
        \\    # notifications still represent waiting on the user.
        \\    msg="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    kind="$(sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    case "$kind:$msg" in
        \\      idle_prompt:*|*"waiting for your input"*|*"is idle"*) activity="parent-idle" ;;
        \\      *) activity="parent-waiting" ;;
        \\    esac ;;
        \\  SubagentStart) activity="child-start" ;;
        \\  SubagentStop) activity="child-stop" ;;
        \\  Stop) activity="parent-idle" ;;
        \\  *)
        \\    rm -f "$payload"; exit 0 ;;
        \\esac
        \\status="$(update_agent_status claude "$activity" idle)"
        \\[ -n "$status" ] || { rm -f "$payload"; exit 0; }
        \\
        \\cli="${VERDE_CLI:-verde}"
        \\case "$cli" in
        \\  *" (deleted)") cli="${cli% (deleted)}" ;;
        \\esac
        \\if ! command -v "$cli" >/dev/null 2>&1; then
        \\  if [ -x "./zig-out/bin/verde" ]; then
        \\    cli="./zig-out/bin/verde"
        \\  else
        \\    cli="verde"
        \\  fi
        \\fi
        \\
        \\if [ -n "$title" ]; then
        \\  "$cli" notify --quiet --status "$status" --title "$title" --provider claude >/dev/null 2>&1 || true
        \\else
        \\  "$cli" notify --quiet --status "$status" --provider claude >/dev/null 2>&1 || true
        \\fi
        \\rm -f "$payload"
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, hookPermissionsForOs(builtin.os.tag));
}

fn claudeSettingsJsonAlloc(allocator: std.mem.Allocator, hook_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();
    for (CLAUDE_HOOK_EVENTS) |event| try writeClaudeHookEvent(&s, event, hook_path);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeClaudeHookEvent(s: *std.json.Stringify, event: []const u8, hook_path: []const u8) !void {
    try s.objectField(event);
    try s.beginArray();
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(hook_path);
    try s.objectField("timeout");
    try s.write(5);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();
}

/// Installs Cursor Agent hooks for one project. Cursor uses the same
/// `.cursor/hooks.json` file in its terminal agent and desktop Agent UI, so the
/// generated entries intentionally use Cursor's native lower-camel event names.
pub fn ensureCursorProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const hook_rel_path = cursorProjectHookRelPathForOs(builtin.os.tag);
    const hook_path = try std.fs.path.join(allocator, &.{ project_path, hook_rel_path });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ project_path, CURSOR_HOOKS_JSON_REL_PATH });
    defer allocator.free(hooks_path);
    const io = threaded.io();

    try ensureParentDir(io, hook_path);
    try writeCursorHookScript(allocator, io, hook_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(existing);

    // Cursor runs project hooks from the project root. Keep this command
    // canonical and checkout-independent because `.cursor/hooks.json` is often
    // committed and the same file is consumed by the terminal and desktop UI.
    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_rel_path);
    defer allocator.free(hook_command);
    const merged = try mergeCursorHooks(allocator, existing, hook_command);
    defer if (merged) |content| allocator.free(content);
    if (merged) |content| {
        try ensureParentDir(io, hooks_path);
        try writeFileAtomic(allocator, io, hooks_path, content, .default_file);
    }
}

fn writeCursorHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const script = if (builtin.os.tag == .windows) cursorPowerShellHookScript() else
        \\#!/bin/sh
        \\# verde-cursor-notify-hook
        \\[ "${VERDE:-}" = "1" ] || exit 0
        \\[ -n "${VERDE_SESSION_ID:-}" ] || exit 0
        \\
        \\payload="${TMPDIR:-/tmp}/verde-cursor-hook.$$"
        \\cat > "$payload" 2>/dev/null || true
        \\event="$(sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\
    ++ POSIX_AGENT_ACTIVITY_STATE ++
        \\activity=""
        \\title=""
        \\case "$event" in
        \\  sessionStart) activity="session-start" ;;
        \\  beforeSubmitPrompt)
        \\    activity="parent-working"
        \\    if command -v jq >/dev/null 2>&1; then
        \\      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    ;;
        \\  preToolUse) activity="parent-working" ;;
        \\  subagentStart) activity="child-start" ;;
        \\  subagentStop) activity="child-stop" ;;
        \\  stop)
        \\    result="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    if [ "$result" = "error" ]; then activity="parent-error"; else activity="parent-idle"; fi
        \\    ;;
        \\  *) rm -f "$payload"; exit 0 ;;
        \\esac
        \\status="$(update_agent_status cursor "$activity" idle)"
        \\[ -n "$status" ] || { rm -f "$payload"; exit 0; }
        \\
        \\cli="${VERDE_CLI:-verde}"
        \\case "$cli" in
        \\  *" (deleted)") cli="${cli% (deleted)}" ;;
        \\esac
        \\if ! command -v "$cli" >/dev/null 2>&1; then
        \\  if [ -x "./zig-out/bin/verde" ]; then cli="./zig-out/bin/verde"; else cli="verde"; fi
        \\fi
        \\if [ -n "$title" ]; then
        \\  "$cli" notify --quiet --status "$status" --title "$title" --provider cursor >/dev/null 2>&1 || true
        \\else
        \\  "$cli" notify --quiet --status "$status" --provider cursor >/dev/null 2>&1 || true
        \\fi
        \\rm -f "$payload"
        \\printf '{}\n'
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, hookPermissionsForOs(builtin.os.tag));
}

fn codexProjectHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CODEX_WINDOWS_HOOK_REL_PATH else CODEX_HOOK_REL_PATH;
}

fn claudeProjectHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CLAUDE_WINDOWS_HOOK_REL_PATH else CLAUDE_HOOK_REL_PATH;
}

fn cursorProjectHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CURSOR_WINDOWS_PROJECT_HOOK_REL_PATH else CURSOR_PROJECT_HOOK_REL_PATH;
}

fn codexGlobalHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CODEX_WINDOWS_GLOBAL_HOOK_REL else CODEX_GLOBAL_HOOK_REL;
}

fn claudeGlobalHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CLAUDE_WINDOWS_GLOBAL_HOOK_REL else CLAUDE_GLOBAL_HOOK_REL;
}

fn cursorGlobalHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) CURSOR_WINDOWS_GLOBAL_HOOK_REL else CURSOR_GLOBAL_HOOK_REL;
}

fn grokGlobalHookRelPathForOs(comptime os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) GROK_WINDOWS_GLOBAL_HOOK_REL else GROK_GLOBAL_HOOK_REL;
}

fn hookPermissionsForOs(comptime os_tag: std.Target.Os.Tag) std.Io.File.Permissions {
    return if (os_tag == .windows) .default_file else .executable_file;
}

fn hookCommandAllocForOs(
    allocator: std.mem.Allocator,
    comptime os_tag: std.Target.Os.Tag,
    hook_path: []const u8,
) ![]u8 {
    if (os_tag != .windows) return allocator.dupe(u8, hook_path);
    // Windows filenames cannot contain a quote. Rejecting one here also keeps
    // the provider's string command unambiguous if a non-filesystem test path
    // reaches this boundary.
    if (std.mem.indexOfScalar(u8, hook_path, '"') != null) return error.InvalidWindowsHookPath;
    return std.fmt.allocPrint(
        allocator,
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{s}\"",
        .{hook_path},
    );
}

fn codexPowerShellHookScript() []const u8 {
    return
    \\# verde-codex-notify-hook
    \\if ($env:VERDE -ne '1' -or [string]::IsNullOrWhiteSpace($env:VERDE_SESSION_ID)) { exit 0 }
    \\$payload = $null
    \\$payloadText = ''
    \\try {
    \\  $payloadText = [Console]::In.ReadToEnd()
    \\  if (-not [string]::IsNullOrWhiteSpace($payloadText)) { $payload = ConvertFrom-Json -InputObject $payloadText }
    \\} catch {}
    \\
    ++ POWERSHELL_AGENT_ACTIVITY_STATE ++
        \\$eventName = if ($null -ne $payload -and $null -ne $payload.hook_event_name) { [string]$payload.hook_event_name } elseif ($null -ne $payload -and $null -ne $payload.event) { [string]$payload.event } elseif ($args.Count -gt 0) { [string]$args[0] } else { '' }
        \\$sessionBytes = [Text.Encoding]::UTF8.GetBytes($env:VERDE_SESSION_ID)
        \\$sessionSha = [Security.Cryptography.SHA256]::Create()
        \\try { $sessionFingerprint = [BitConverter]::ToString($sessionSha.ComputeHash($sessionBytes)).Replace('-', '') } finally { $sessionSha.Dispose() }
        \\$titlePath = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'verde-agent-status') ('codex-' + $sessionFingerprint + [IO.Path]::DirectorySeparatorChar + 'title')
        \\$providerSessionId = if ($null -ne $payload -and $null -ne $payload.session_id) { [string]$payload.session_id } else { '' }
        \\$sessionPath = Join-Path (Split-Path $titlePath) 'provider_session_id'
        \\$boundSession = if (Test-Path -LiteralPath $sessionPath) { Get-Content -LiteralPath $sessionPath -Raw -ErrorAction SilentlyContinue } else { '' }
        \\if ($eventName -ne 'SessionStart' -and -not [string]::IsNullOrWhiteSpace($boundSession) -and -not [string]::IsNullOrWhiteSpace($providerSessionId) -and $boundSession -ne $providerSessionId) { exit 0 }
        \\$activity = ''
        \\$title = ''
        \\switch ($eventName) {
        \\  'SessionStart' { $activity = 'session-start' }
        \\  'UserPromptSubmit' {
        \\    $activity = 'parent-working'
        \\    if ($null -ne $payload -and $null -ne $payload.prompt) {
        \\      $title = [regex]::Replace([string]$payload.prompt, '\s+', ' ').Trim()
        \\      if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
        \\    }
        \\  }
        \\  'PreToolUse' { $activity = 'parent-working' }
        \\  'PermissionRequest' { $activity = 'parent-waiting' }
        \\  'SubagentStart' { $activity = 'child-start' }
        \\  'SubagentStop' { $activity = 'child-stop' }
        \\  'Stop' { $activity = 'parent-idle' }
        \\  default { exit 0 }
        \\}
        \\$status = Update-AgentStatus -Provider 'codex' -Activity $activity -InitialStatus 'working' -PayloadText $payloadText
        \\if ([string]::IsNullOrWhiteSpace($status)) { exit 0 }
        \\$providerTitle = ''
        \\if (-not [string]::IsNullOrWhiteSpace($providerSessionId)) { Set-Content -LiteralPath $sessionPath -Value $providerSessionId -NoNewline -ErrorAction SilentlyContinue }
        \\$env:VERDE_PROVIDER_THREAD_ID = $providerSessionId
        \\$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $env:USERPROFILE '.codex' } else { $env:CODEX_HOME }
        \\$indexPath = Join-Path $codexHome 'session_index.jsonl'
        \\if (-not [string]::IsNullOrWhiteSpace($providerSessionId) -and (Test-Path -LiteralPath $indexPath)) {
        \\  foreach ($line in [IO.File]::ReadLines($indexPath)) {
        \\    try {
        \\      $row = ConvertFrom-Json -InputObject $line
        \\      if ($row.id -eq $providerSessionId -and $row.thread_name -is [string] -and -not [string]::IsNullOrWhiteSpace($row.thread_name)) { $providerTitle = $row.thread_name }
        \\    } catch {}
        \\  }
        \\}
        \\if (-not [string]::IsNullOrWhiteSpace($providerTitle)) {
        \\  $title = $providerTitle
        \\} elseif (Test-Path -LiteralPath $titlePath) {
        \\  $cachedTitle = Get-Content -LiteralPath $titlePath -Raw -ErrorAction SilentlyContinue
        \\  if (-not [string]::IsNullOrWhiteSpace($cachedTitle)) { $title = $cachedTitle }
        \\}
        \\if (-not [string]::IsNullOrWhiteSpace($title)) { Set-Content -LiteralPath $titlePath -Value $title -NoNewline -ErrorAction SilentlyContinue }
        \\$cli = if ([string]::IsNullOrWhiteSpace($env:VERDE_CLI)) { 'verde.exe' } else { $env:VERDE_CLI }
        \\if ($cli.EndsWith(' (deleted)')) { $cli = $cli.Substring(0, $cli.Length - 10) }
        \\$notifyArgs = @('notify', '--quiet', '--status', $status, '--provider', 'codex')
        \\if (-not [string]::IsNullOrWhiteSpace($title)) { $notifyArgs += @('--title', $title) }
        \\# $env:VERDE_LIVE_ENDPOINT is inherited, so the CLI targets the exact named pipe advertised by Verde.
        \\try { & $cli @notifyArgs *> $null } catch {}
        \\exit 0
        \\
    ;
}

fn claudePowerShellHookScript() []const u8 {
    return
    \\# verde-claude-notify-hook
    \\if ($env:VERDE -ne '1' -or [string]::IsNullOrWhiteSpace($env:VERDE_SESSION_ID)) { exit 0 }
    \\$payload = $null
    \\$payloadText = ''
    \\try {
    \\  $payloadText = [Console]::In.ReadToEnd()
    \\  if (-not [string]::IsNullOrWhiteSpace($payloadText)) { $payload = ConvertFrom-Json -InputObject $payloadText }
    \\} catch {}
    \\
    ++ POWERSHELL_AGENT_ACTIVITY_STATE ++
        \\$eventName = if ($null -ne $payload -and $null -ne $payload.hook_event_name) { [string]$payload.hook_event_name } elseif ($args.Count -gt 0) { [string]$args[0] } else { '' }
        \\$activity = ''
        \\$title = ''
        \\switch ($eventName) {
        \\  'SessionStart' {
        \\    $source = if ($null -ne $payload -and $null -ne $payload.source) { [string]$payload.source } else { '' }
        \\    # Compaction preserves the previous lifecycle; manual /compact
        \\    # can run at an idle prompt without starting an agentic turn.
        \\    if ($source -eq 'compact') { exit 0 }
        \\    $activity = 'session-start'
        \\  }
        \\  'UserPromptSubmit' {
        \\    $activity = 'parent-working'
        \\    if ($null -ne $payload -and $null -ne $payload.prompt) {
        \\      $title = [regex]::Replace([string]$payload.prompt, '\s+', ' ').Trim()
        \\      if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
        \\    }
        \\  }
        \\  'Notification' {
        \\    $message = if ($null -ne $payload -and $null -ne $payload.message) { [string]$payload.message } else { '' }
        \\    $kind = if ($null -ne $payload -and $null -ne $payload.notification_type) { [string]$payload.notification_type } else { '' }
        \\    $activity = if ($kind -eq 'idle_prompt' -or $message -match 'waiting for your input|is idle') { 'parent-idle' } else { 'parent-waiting' }
        \\  }
        \\  'SubagentStart' { $activity = 'child-start' }
        \\  'SubagentStop' { $activity = 'child-stop' }
        \\  'Stop' { $activity = 'parent-idle' }
        \\  default { exit 0 }
        \\}
        \\$status = Update-AgentStatus -Provider 'claude' -Activity $activity -InitialStatus 'idle' -PayloadText $payloadText
        \\if ([string]::IsNullOrWhiteSpace($status)) { exit 0 }
        \\$cli = if ([string]::IsNullOrWhiteSpace($env:VERDE_CLI)) { 'verde.exe' } else { $env:VERDE_CLI }
        \\if ($cli.EndsWith(' (deleted)')) { $cli = $cli.Substring(0, $cli.Length - 10) }
        \\$notifyArgs = @('notify', '--quiet', '--status', $status, '--provider', 'claude')
        \\if (-not [string]::IsNullOrWhiteSpace($title)) { $notifyArgs += @('--title', $title) }
        \\# $env:VERDE_LIVE_ENDPOINT is inherited, so the CLI targets the exact named pipe advertised by Verde.
        \\try { & $cli @notifyArgs *> $null } catch {}
        \\exit 0
        \\
    ;
}

fn cursorPowerShellHookScript() []const u8 {
    return
    \\# verde-cursor-notify-hook
    \\if ($env:VERDE -ne '1' -or [string]::IsNullOrWhiteSpace($env:VERDE_SESSION_ID)) { exit 0 }
    \\$payload = $null
    \\$payloadText = ''
    \\try {
    \\  $payloadText = [Console]::In.ReadToEnd()
    \\  if (-not [string]::IsNullOrWhiteSpace($payloadText)) { $payload = ConvertFrom-Json -InputObject $payloadText }
    \\} catch {}
    \\
    ++ POWERSHELL_AGENT_ACTIVITY_STATE ++
        \\$eventName = if ($null -ne $payload -and $null -ne $payload.hook_event_name) { [string]$payload.hook_event_name } else { '' }
        \\$activity = ''
        \\$title = ''
        \\switch ($eventName) {
        \\  'sessionStart' { $activity = 'session-start' }
        \\  'beforeSubmitPrompt' {
        \\    $activity = 'parent-working'
        \\    if ($null -ne $payload -and $null -ne $payload.prompt) {
        \\      $title = [regex]::Replace([string]$payload.prompt, '\s+', ' ').Trim()
        \\      if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
        \\    }
        \\  }
        \\  'preToolUse' { $activity = 'parent-working' }
        \\  'subagentStart' { $activity = 'child-start' }
        \\  'subagentStop' { $activity = 'child-stop' }
        \\  'stop' {
        \\    $result = if ($null -ne $payload -and $null -ne $payload.status) { [string]$payload.status } else { '' }
        \\    $activity = if ($result -eq 'error') { 'parent-error' } else { 'parent-idle' }
        \\  }
        \\  default { exit 0 }
        \\}
        \\$status = Update-AgentStatus -Provider 'cursor' -Activity $activity -InitialStatus 'idle' -PayloadText $payloadText
        \\if ([string]::IsNullOrWhiteSpace($status)) { exit 0 }
        \\$cli = if ([string]::IsNullOrWhiteSpace($env:VERDE_CLI)) { 'verde.exe' } else { $env:VERDE_CLI }
        \\if ($cli.EndsWith(' (deleted)')) { $cli = $cli.Substring(0, $cli.Length - 10) }
        \\$notifyArgs = @('notify', '--quiet', '--status', $status, '--provider', 'cursor')
        \\if (-not [string]::IsNullOrWhiteSpace($title)) { $notifyArgs += @('--title', $title) }
        \\# $env:VERDE_LIVE_ENDPOINT is inherited, so the CLI reaches the owning Verde pane.
        \\try { & $cli @notifyArgs *> $null } catch {}
        \\[Console]::Out.WriteLine('{}')
        \\exit 0
        \\
    ;
}

fn grokPowerShellHookScript() []const u8 {
    return
    \\# verde-grok-notify-hook
    \\if ($env:VERDE -ne '1' -or [string]::IsNullOrWhiteSpace($env:VERDE_SESSION_ID)) { exit 0 }
    \\$cli = if ([string]::IsNullOrWhiteSpace($env:VERDE_CLI)) { 'verde.exe' } else { $env:VERDE_CLI }
    \\if ($cli.EndsWith(' (deleted)')) { $cli = $cli.Substring(0, $cli.Length - 10) }
    \\if (-not [string]::IsNullOrWhiteSpace($env:VERDE_GROK_TITLE_SESSION_ID)) {
    \\  $sessionId = $env:VERDE_GROK_TITLE_SESSION_ID
    \\  if ($sessionId -notmatch '^[A-Za-z0-9-]+$') { exit 0 }
    \\  $status = if ([string]::IsNullOrWhiteSpace($env:VERDE_GROK_TITLE_STATUS)) { 'done' } else { $env:VERDE_GROK_TITLE_STATUS }
    \\  $userHome = [Environment]::GetFolderPath('UserProfile')
    \\  $grokHome = if ([string]::IsNullOrWhiteSpace($env:GROK_HOME)) { Join-Path $userHome '.grok' } else { $env:GROK_HOME }
    \\  $sessionsRoot = Join-Path $grokHome 'sessions'
    \\  $title = ''
    \\  for ($attempt = 0; $attempt -lt 20 -and [string]::IsNullOrWhiteSpace($title); $attempt++) {
    \\    $summaryPath = Get-ChildItem -LiteralPath $sessionsRoot -Directory -ErrorAction SilentlyContinue |
    \\      ForEach-Object { Join-Path $_.FullName (Join-Path $sessionId 'summary.json') } |
    \\      Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    \\      Select-Object -First 1
    \\    if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
    \\      try {
    \\        $summary = Get-Content -LiteralPath $summaryPath -Raw -ErrorAction Stop | ConvertFrom-Json
    \\        if ($null -ne $summary.generated_title) { $title = [string]$summary.generated_title }
    \\        elseif ($null -ne $summary.session_summary) { $title = [string]$summary.session_summary }
    \\      } catch {}
    \\    }
    \\    if ([string]::IsNullOrWhiteSpace($title)) { Start-Sleep -Milliseconds 50 }
    \\  }
    \\  if (-not [string]::IsNullOrWhiteSpace($title)) {
    \\    $title = [regex]::Replace($title, '\s+', ' ').Trim()
    \\    if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
    \\    try { & $cli notify --quiet --status $status --title $title --provider grok *> $null } catch {}
    \\  }
    \\  exit 0
    \\}
    \\$payload = $null
    \\$payloadText = ''
    \\try {
    \\  $payloadText = [Console]::In.ReadToEnd()
    \\  if (-not [string]::IsNullOrWhiteSpace($payloadText)) { $payload = ConvertFrom-Json -InputObject $payloadText }
    \\} catch {}
    \\
    ++ POWERSHELL_AGENT_ACTIVITY_STATE ++
        \\$eventName = if ($null -ne $payload -and $null -ne $payload.hookEventName) { [string]$payload.hookEventName } elseif (-not [string]::IsNullOrWhiteSpace($env:GROK_HOOK_EVENT)) { $env:GROK_HOOK_EVENT } else { '' }
        \\$activity = ''
        \\$title = ''
        \\$sessionId = ''
        \\switch ($eventName) {
        \\  { $_ -in 'session_start', 'SessionStart' } { $activity = 'session-start'; break }
        \\  { $_ -in 'user_prompt_submit', 'UserPromptSubmit' } {
        \\    $activity = 'parent-working'
        \\    if ($null -ne $payload -and $null -ne $payload.prompt) {
        \\      $title = [regex]::Replace([string]$payload.prompt, '^\s*<user_query>\s*', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        \\      $title = [regex]::Replace($title, '\s*</user_query>\s*$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        \\      $title = [regex]::Replace($title, '\s+', ' ').Trim()
        \\      if ($title.Length -gt 72) { $title = $title.Substring(0, 72) }
        \\    }
        \\    break
        \\  }
        \\  { $_ -in 'pre_tool_use', 'PreToolUse' } { $activity = 'parent-working'; break }
        \\  { $_ -in 'notification', 'Notification' } {
        \\    $notificationType = if ($null -ne $payload -and $null -ne $payload.notificationType) { [string]$payload.notificationType } else { '' }
        \\    $message = if ($null -ne $payload -and $null -ne $payload.message) { [string]$payload.message } else { '' }
        \\    $notification = ($notificationType + ' ' + $message).ToLowerInvariant()
        \\    if ($notification -notmatch 'permission|approval|confirm|action.required|input.required|user.input|elicitation') { exit 0 }
        \\    $activity = 'parent-waiting'
        \\    break
        \\  }
        \\  { $_ -in 'subagent_start', 'SubagentStart' } { $activity = 'child-start'; break }
        \\  { $_ -in 'subagent_stop', 'SubagentStop' } { $activity = 'child-stop'; break }
        \\  { $_ -in 'stop', 'Stop' } {
        \\    $activity = 'parent-idle'
        \\    $sessionId = if ($null -ne $payload -and $null -ne $payload.sessionId) { [string]$payload.sessionId } else { '' }
        \\    break
        \\  }
        \\  { $_ -in 'stop_failure', 'StopFailure' } { $activity = 'parent-error'; break }
        \\  default { exit 0 }
        \\}
        \\$status = Update-AgentStatus -Provider 'grok' -Activity $activity -InitialStatus 'idle' -PayloadText $payloadText
        \\if ([string]::IsNullOrWhiteSpace($status)) { exit 0 }
        \\if ($sessionId -match '^[A-Za-z0-9-]+$' -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        \\  $env:VERDE_GROK_TITLE_SESSION_ID = $sessionId
        \\  $env:VERDE_GROK_TITLE_STATUS = $status
        \\  $quotedScriptPath = '"' + $PSCommandPath + '"'
        \\  try {
        \\    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $quotedScriptPath) -WindowStyle Hidden | Out-Null
        \\  } catch {}
        \\  Remove-Item Env:VERDE_GROK_TITLE_SESSION_ID -ErrorAction SilentlyContinue
        \\  Remove-Item Env:VERDE_GROK_TITLE_STATUS -ErrorAction SilentlyContinue
        \\}
        \\$notifyArgs = @('notify', '--quiet', '--status', $status, '--provider', 'grok')
        \\if (-not [string]::IsNullOrWhiteSpace($title)) { $notifyArgs += @('--title', $title) }
        \\# $env:VERDE_LIVE_ENDPOINT is inherited, so the CLI reaches the owning Verde pane.
        \\try { & $cli @notifyArgs *> $null } catch {}
        \\exit 0
        \\
    ;
}

// Global (all-projects) Claude hooks live in ~/.claude/settings.json with the
// hook script at an absolute path so it resolves from any working directory.
const CLAUDE_GLOBAL_HOOK_REL = ".claude/verde-claude-notify-hook.sh";
const CLAUDE_WINDOWS_GLOBAL_HOOK_REL = ".claude/verde-claude-notify-hook.ps1";
const CLAUDE_GLOBAL_SETTINGS_REL = ".claude/settings.json";
const CLAUDE_GLOBAL_HOOK_NEEDLE = "verde-claude-notify-hook";
const CLAUDE_HOOK_EVENTS = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Notification", "SubagentStart", "SubagentStop", "Stop" };

const CURSOR_GLOBAL_HOOK_REL = ".cursor/hooks/verde-cursor-notify-hook.sh";
const CURSOR_WINDOWS_GLOBAL_HOOK_REL = ".cursor/hooks/verde-cursor-notify-hook.ps1";
const CURSOR_GLOBAL_HOOKS_JSON_REL = ".cursor/hooks.json";
const CURSOR_GLOBAL_HOOK_NEEDLE = "verde-cursor-notify-hook";

// Grok loads every JSON file in ~/.grok/hooks, so Verde owns a standalone file
// instead of merging into the user's config. Personal hooks do not require the
// project trust prompt that repository-local Grok hooks do.
const GROK_GLOBAL_HOOK_REL = "verde-grok-notify-hook.sh";
const GROK_WINDOWS_GLOBAL_HOOK_REL = "verde-grok-notify-hook.ps1";
const GROK_GLOBAL_HOOKS_JSON_REL = "hooks/verde-notify.json";
const GROK_GLOBAL_HOOK_NEEDLE = "verde-grok-notify-hook";
const GROK_HOOK_EVENTS = [_][]const u8{ "SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure" };

const AMP_GLOBAL_PLUGIN_REL = ".config/amp/plugins/verde-notify.ts";
const AMP_GLOBAL_PLUGIN_NEEDLE = "verde-amp-notify-plugin";
const OPENCODE_GLOBAL_PLUGIN_REL = ".config/opencode/plugin/verde-notify.ts";
const OPENCODE_GLOBAL_PLUGIN_NEEDLE = "verde-opencode-notify-plugin";

fn homeDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    return platform_paths.userHome(allocator);
}

fn grokHomeDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    const environ: std.process.Environ = if (builtin.os.tag == .windows)
        .{ .block = .global }
    else
        .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    if (environ.getAlloc(allocator, "GROK_HOME")) |configured| {
        if (configured.len > 0) return configured;
        allocator.free(configured);
    } else |err| switch (err) {
        error.EnvironmentVariableMissing => {},
        else => return err,
    }
    const home = try homeDirAlloc(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".grok" });
}

/// True when our managed hook is present in the global Claude settings.
pub fn claudeGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const settings_path = std.fs.path.join(allocator, &.{ home, CLAUDE_GLOBAL_SETTINGS_REL }) catch return false;
    defer allocator.free(settings_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), settings_path, allocator, .limited(8 * 1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, CLAUDE_GLOBAL_HOOK_NEEDLE) != null;
}

/// Installs the Claude notify hook globally by merging our events into the
/// existing ~/.claude/settings.json (preserving all other settings and hooks).
pub fn ensureClaudeGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, claudeGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const settings_path = try std.fs.path.join(allocator, &.{ home, CLAUDE_GLOBAL_SETTINGS_REL });
    defer allocator.free(settings_path);

    try ensureParentDir(io, hook_path);
    try writeClaudeHookScript(allocator, io, hook_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const merged = try mergeClaudeHooks(allocator, existing, hook_command);
    defer if (merged) |m| allocator.free(m);
    if (merged) |m| {
        try ensureParentDir(io, settings_path);
        try writeFileAtomic(allocator, io, settings_path, m, .default_file);
    }
}

/// Removes our managed hook entries from the global Claude settings and deletes
/// the hook script. Idempotent.
pub fn removeClaudeGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, claudeGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const settings_path = try std.fs.path.join(allocator, &.{ home, CLAUDE_GLOBAL_SETTINGS_REL });
    defer allocator.free(settings_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, settings_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const updated = try removeClaudeHooksFromJson(allocator, existing, hook_command);
    defer if (updated) |u| allocator.free(u);
    if (updated) |u| try writeFileAtomic(allocator, io, settings_path, u, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
}

/// True when our managed hook is present in the global Codex hooks file.
pub fn codexGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const hooks_path = std.fs.path.join(allocator, &.{ home, CODEX_GLOBAL_HOOKS_JSON_REL }) catch return false;
    defer allocator.free(hooks_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_path, allocator, .limited(8 * 1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, CODEX_GLOBAL_HOOK_NEEDLE) != null;
}

/// Installs the Codex notify hook globally by merging our events into the
/// existing ~/.codex/hooks.json (preserving any hooks the user already runs).
pub fn ensureCodexGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, codexGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ home, CODEX_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);

    try ensureParentDir(io, hook_path);
    try writeCodexHookScript(allocator, io, hook_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const merged = try mergeCodexHooks(allocator, existing, hook_command);
    defer if (merged) |m| allocator.free(m);
    if (merged) |m| {
        try ensureParentDir(io, hooks_path);
        try writeFileAtomic(allocator, io, hooks_path, m, .default_file);
    }
}

/// Removes our managed hook entries from the global Codex hooks file and deletes
/// the hook script, leaving any user-owned hooks intact. Idempotent.
pub fn removeCodexGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, codexGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ home, CODEX_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const updated = try removeCodexHooksFromJson(allocator, existing, hook_command);
    defer if (updated) |u| allocator.free(u);
    if (updated) |u| try writeFileAtomic(allocator, io, hooks_path, u, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
}

/// True when Verde's managed Cursor hook is present in the user hook file
/// shared by Cursor's desktop Agent UI and terminal agent.
pub fn cursorGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const hooks_path = std.fs.path.join(allocator, &.{ home, CURSOR_GLOBAL_HOOKS_JSON_REL }) catch return false;
    defer allocator.free(hooks_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_path, allocator, .limited(8 * 1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, CURSOR_GLOBAL_HOOK_NEEDLE) != null;
}

/// Installs the Cursor notify hook globally while preserving existing user
/// hooks. Cursor reloads this file for both its GUI and CLI agent surfaces.
pub fn ensureCursorGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, cursorGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ home, CURSOR_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);

    try ensureParentDir(io, hook_path);
    try writeCursorHookScript(allocator, io, hook_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const merged = try mergeCursorHooks(allocator, existing, hook_command);
    defer if (merged) |content| allocator.free(content);
    if (merged) |content| {
        try ensureParentDir(io, hooks_path);
        try writeFileAtomic(allocator, io, hooks_path, content, .default_file);
    }
}

/// Removes only Verde's Cursor entries and managed script. Idempotent.
pub fn removeCursorGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, cursorGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ home, CURSOR_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, hooks_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const updated = try removeCursorHooksFromJson(allocator, existing, hook_command);
    defer if (updated) |content| allocator.free(content);
    if (updated) |content| try writeFileAtomic(allocator, io, hooks_path, content, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
}

/// True when Verde's standalone Grok personal hook is installed.
pub fn grokGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const grok_home = grokHomeDirAlloc(allocator) catch return false;
    defer allocator.free(grok_home);
    return grokGlobalHooksInstalledAt(allocator, grok_home);
}

fn grokGlobalHooksInstalledAt(allocator: std.mem.Allocator, grok_home: []const u8) bool {
    const hooks_path = std.fs.path.join(allocator, &.{ grok_home, GROK_GLOBAL_HOOKS_JSON_REL }) catch return false;
    defer allocator.free(hooks_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, GROK_GLOBAL_HOOK_NEEDLE) != null;
}

/// Installs Grok's personal status hook as an isolated, Verde-owned JSON file.
pub fn ensureGrokGlobalHooks(allocator: std.mem.Allocator) !void {
    const grok_home = try grokHomeDirAlloc(allocator);
    defer allocator.free(grok_home);
    try ensureGrokGlobalHooksAt(allocator, grok_home);
}

fn ensureGrokGlobalHooksAt(allocator: std.mem.Allocator, grok_home: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ grok_home, grokGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ grok_home, GROK_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);

    try ensureParentDir(io, hook_path);
    try writeGrokHookScript(allocator, io, hook_path);
    const hook_command = try hookCommandAllocForOs(allocator, builtin.os.tag, hook_path);
    defer allocator.free(hook_command);
    const hooks_json = try grokHooksJsonAlloc(allocator, hook_command);
    defer allocator.free(hooks_json);
    try ensureParentDir(io, hooks_path);
    try writeFileAtomic(allocator, io, hooks_path, hooks_json, .default_file);
}

/// Removes only Verde's standalone Grok hook files. Idempotent.
pub fn removeGrokGlobalHooks(allocator: std.mem.Allocator) !void {
    const grok_home = try grokHomeDirAlloc(allocator);
    defer allocator.free(grok_home);
    try removeGrokGlobalHooksAt(allocator, grok_home);
}

fn removeGrokGlobalHooksAt(allocator: std.mem.Allocator, grok_home: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ grok_home, grokGlobalHookRelPathForOs(builtin.os.tag) });
    defer allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(allocator, &.{ grok_home, GROK_GLOBAL_HOOKS_JSON_REL });
    defer allocator.free(hooks_path);
    std.Io.Dir.cwd().deleteFile(io, hooks_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeGrokHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const script = if (builtin.os.tag == .windows) grokPowerShellHookScript() else
        \\#!/bin/sh
        \\# verde-grok-notify-hook
        \\[ "${VERDE:-}" = "1" ] || exit 0
        \\[ -n "${VERDE_SESSION_ID:-}" ] || exit 0
        \\
        \\cli="${VERDE_CLI:-verde}"
        \\case "$cli" in
        \\  *" (deleted)") cli="${cli% (deleted)}" ;;
        \\esac
        \\if ! command -v "$cli" >/dev/null 2>&1; then
        \\  if [ -x "./zig-out/bin/verde" ]; then cli="./zig-out/bin/verde"; else cli="verde"; fi
        \\fi
        \\
        \\if [ -n "${VERDE_GROK_TITLE_SESSION_ID:-}" ]; then
        \\  session_id="$VERDE_GROK_TITLE_SESSION_ID"
        \\  case "$session_id" in *[!A-Za-z0-9-]*) exit 0 ;; esac
        \\  status="${VERDE_GROK_TITLE_STATUS:-done}"
        \\  grok_home="${GROK_HOME:-${HOME:-}/.grok}"
        \\  attempts=0
        \\  title=""
        \\  while [ "$attempts" -lt 20 ] && [ -z "$title" ]; do
        \\    summary_path=""
        \\    for candidate in "$grok_home"/sessions/*/"$session_id"/summary.json; do
        \\      if [ -f "$candidate" ]; then summary_path="$candidate"; break; fi
        \\    done
        \\    if [ -n "$summary_path" ]; then
        \\      if command -v jq >/dev/null 2>&1; then
        \\        title="$(jq -r '.generated_title // .session_summary // empty' "$summary_path" 2>/dev/null)"
        \\      else
        \\        title="$(sed -n 's/.*"generated_title"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_path" | head -n 1)"
        \\        [ -n "$title" ] || title="$(sed -n 's/.*"session_summary"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$summary_path" | head -n 1)"
        \\      fi
        \\    fi
        \\    attempts=$((attempts + 1))
        \\    if [ -z "$title" ] && [ "$attempts" -lt 20 ]; then sleep 0.05; fi
        \\  done
        \\  if [ -n "$title" ]; then
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    "$cli" notify --quiet --status "$status" --title "$title" --provider grok >/dev/null 2>&1 || true
        \\  fi
        \\  exit 0
        \\fi
        \\
        \\payload="${TMPDIR:-/tmp}/verde-grok-hook.$$"
        \\cat > "$payload" 2>/dev/null || true
        \\event="$(sed -n 's/.*"hookEventName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\[ -n "$event" ] || event="${GROK_HOOK_EVENT:-}"
        \\
    ++ POSIX_AGENT_ACTIVITY_STATE ++
        \\activity=""
        \\title=""
        \\session_id=""
        \\case "$event" in
        \\  session_start|SessionStart) activity="session-start" ;;
        \\  user_prompt_submit|UserPromptSubmit)
        \\    activity="parent-working"
        \\    if command -v jq >/dev/null 2>&1; then
        \\      title="$(jq -r '.prompt // .userPrompt // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*<user_query>[[:space:]]*//' -e 's/[[:space:]]*<\/user_query>[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    ;;
        \\  pre_tool_use|PreToolUse) activity="parent-working" ;;
        \\  notification|Notification)
        \\    if command -v jq >/dev/null 2>&1; then
        \\      notification="$(jq -r '[(.notificationType // ""), (.message // ""), (.body // ""), (.title // "")] | join(" ") | ascii_downcase' "$payload" 2>/dev/null)"
        \\    else
        \\      notification="$(sed -n 's/.*"notificationType"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1 | tr '[:upper:]' '[:lower:]')"
        \\    fi
        \\    case "$notification" in
        \\      *permission*|*approval*|*confirm*|*"action required"*|*action_required*|*action-required*|*"input required"*|*input_required*|*input-required*|*"user input"*|*user_input*|*user-input*|*elicitation*) activity="parent-waiting" ;;
        \\      *) rm -f "$payload"; exit 0 ;;
        \\    esac
        \\    ;;
        \\  subagent_start|SubagentStart) activity="child-start" ;;
        \\  subagent_stop|SubagentStop) activity="child-stop" ;;
        \\  stop|Stop)
        \\    activity="parent-idle"
        \\    if command -v jq >/dev/null 2>&1; then
        \\      session_id="$(jq -r '.sessionId // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      session_id="$(sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    ;;
        \\  stop_failure|StopFailure) activity="parent-error" ;;
        \\  *) rm -f "$payload"; exit 0 ;;
        \\esac
        \\status="$(update_agent_status grok "$activity" idle)"
        \\[ -n "$status" ] || { rm -f "$payload"; exit 0; }
        \\case "$session_id" in
        \\  ""|*[!A-Za-z0-9-]*) ;;
        \\  *) VERDE_GROK_TITLE_SESSION_ID="$session_id" VERDE_GROK_TITLE_STATUS="$status" "$0" </dev/null >/dev/null 2>&1 & ;;
        \\esac
        \\
        \\if [ -n "$title" ]; then
        \\  "$cli" notify --quiet --status "$status" --title "$title" --provider grok >/dev/null 2>&1 || true
        \\else
        \\  "$cli" notify --quiet --status "$status" --provider grok >/dev/null 2>&1 || true
        \\fi
        \\rm -f "$payload"
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, hookPermissionsForOs(builtin.os.tag));
}

fn grokHooksJsonAlloc(allocator: std.mem.Allocator, hook_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();
    for (GROK_HOOK_EVENTS) |event| try writeGrokHookEvent(&s, event, hook_path);
    try s.endObject();
    try s.endObject();
    return try writer.toOwnedSlice();
}

fn writeGrokHookEvent(s: *std.json.Stringify, event: []const u8, hook_path: []const u8) !void {
    try s.objectField(event);
    try s.beginArray();
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("command");
    try s.objectField("command");
    try s.write(hook_path);
    try s.objectField("timeout");
    try s.write(5);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    try s.endArray();
}

/// True when our managed OpenCode plugin is present in the global plugin dir.
pub fn opencodeGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const plugin_path = std.fs.path.join(allocator, &.{ home, OPENCODE_GLOBAL_PLUGIN_REL }) catch return false;
    defer allocator.free(plugin_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), plugin_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, OPENCODE_GLOBAL_PLUGIN_NEEDLE) != null;
}

/// Installs the OpenCode lifecycle plugin globally. OpenCode 2 discovers
/// TypeScript plugins from ~/.config/opencode/plugin (or /plugins) without
/// modifying user configuration, but only loads them inside the shared
/// background service, so the plugin resolves Verde panes itself.
pub fn ensureOpencodeGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const plugin_path = try std.fs.path.join(allocator, &.{ home, OPENCODE_GLOBAL_PLUGIN_REL });
    defer allocator.free(plugin_path);
    try ensureParentDir(io, plugin_path);
    try writeOpencodePlugin(allocator, io, plugin_path);
}

/// Removes the managed OpenCode lifecycle plugin. Idempotent.
pub fn removeOpencodeGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const plugin_path = try std.fs.path.join(allocator, &.{ home, OPENCODE_GLOBAL_PLUGIN_REL });
    defer allocator.free(plugin_path);
    std.Io.Dir.cwd().deleteFile(threaded.io(), plugin_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeOpencodePlugin(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    // OpenCode 2 loads local plugins only inside the shared background service
    // (the TUI never loads them), so the plugin cannot see pane environment.
    // It subscribes to the service event bus, aggregates session state per
    // directory, resolves matching Verde opencode panes via `verde live
    // surfaces`, and reports through `verde notify --session <pane>`.
    const plugin =
        \\// verde-opencode-notify-plugin (v3 candidate, server-side)
        \\import { spawn } from 'node:child_process';
        \\
        \\type SessionRunState = 'idle' | 'busy' | 'retry';
        \\type VerdeStatus = 'working' | 'done' | 'waiting';
        \\type SessionNode = {
        \\  directory: string;
        \\  parentID?: string;
        \\  status: SessionRunState;
        \\  title: string;
        \\};
        \\
        \\function verdeCli(): string {
        \\  const raw = process.env.VERDE_CLI || (process.platform === 'win32' ? 'verde.exe' : 'verde');
        \\  return raw.endsWith(' (deleted)') ? raw.slice(0, -10) : raw;
        \\}
        \\
        \\const debug = typeof process !== 'undefined' && process.env.VERDE_PLUGIN_DEBUG;
        \\
        \\export default {
        \\  id: 'verde-opencode-notify',
        \\  setup: async (context: unknown) => {
        \\    const host = context as {
        \\      event?: { subscribe?: unknown };
        \\      client?: { event?: { subscribe?: unknown } };
        \\    } | null | undefined;
        \\    const subscribe = host?.event?.subscribe ?? host?.client?.event?.subscribe;
        \\    if (typeof subscribe !== 'function') return;
        \\
        \\    const sessions = new Map<string, SessionNode>();
        \\    const permissionSessions = new Set<string>();
        \\    let disposed = false;
        \\    let pending: Promise<void> = Promise.resolve();
        \\    let surfaces: Array<{ session_id: string; workspace_path: string; provider: string }> = [];
        \\    let surfacesFetchedAt = 0;
        \\    let surfacesFetch: Promise<void> = Promise.resolve();
        \\    const lastReport = new Map<string, string>();
        \\
        \\    const normalizeTitle = (value: unknown): string =>
        \\      typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, 72) : '';
        \\
        \\    // State is aggregated per directory because the shared service serves every
        \\    // Verde pane; a directory with no tracked sessions is never reported.
        \\    const runStatusFor = (directory: string): VerdeStatus | null => {
        \\      let hasTrackedSession = false;
        \\      let hasRootBusy = false;
        \\      let hasChildBusy = false;
        \\      for (const node of sessions.values()) {
        \\        if (node.directory !== directory) continue;
        \\        hasTrackedSession = true;
        \\        if (node.status === 'busy' || node.status === 'retry') {
        \\          if (node.parentID) hasChildBusy = true;
        \\          else hasRootBusy = true;
        \\        }
        \\      }
        \\      if (!hasTrackedSession) return null;
        \\      if (hasRootBusy) return 'working';
        \\      for (const sessionID of permissionSessions) {
        \\        if (sessions.get(sessionID)?.directory === directory) return 'waiting';
        \\      }
        \\      if (hasChildBusy) return 'waiting';
        \\      return 'done';
        \\    };
        \\
        \\    const titleFor = (directory: string): string => {
        \\      for (const node of sessions.values()) {
        \\        if (node.directory === directory && !node.parentID && node.title) return node.title;
        \\      }
        \\      return '';
        \\    };
        \\
        \\    const spawnNotify = (args: string[]): void => {
        \\      try {
        \\        const child = spawn(verdeCli(), args, { stdio: 'ignore' });
        \\        child.on('error', () => {});
        \\        child.on('close', () => {});
        \\      } catch {
        \\        // Status reporting is best-effort and must not interrupt OpenCode.
        \\      }
        \\    };
        \\
        \\    let refreshInFlight = false;
        \\    const refreshSurfaces = (): Promise<void> => {
        \\      if (!refreshInFlight && Date.now() - surfacesFetchedAt < 5000 && surfacesFetchedAt !== 0) {
        \\        return Promise.resolve();
        \\      }
        \\      if (refreshInFlight) return surfacesFetch;
        \\      refreshInFlight = true;
        \\      surfacesFetch = new Promise<void>((resolve) => {
        \\        try {
        \\          const child = spawn(verdeCli(), ['live', 'surfaces', '--json'], { stdio: ['ignore', 'pipe', 'ignore'] });
        \\          let out = '';
        \\          child.stdout?.on('data', (chunk: Buffer) => {
        \\            out += chunk.toString();
        \\          });
        \\          child.on('error', () => resolve());
        \\          child.on('close', () => {
        \\            try {
        \\              const parsed = JSON.parse(out) as { result?: { surfaces?: typeof surfaces } };
        \\              const list = parsed?.result?.surfaces;
        \\              if (Array.isArray(list)) surfaces = list;
        \\              surfacesFetchedAt = Date.now();
        \\            } catch {
        \\              // The daemon may be restarting; keep the previous snapshot.
        \\            }
        \\            refreshInFlight = false;
        \\            resolve();
        \\          });
        \\        } catch {
        \\          refreshInFlight = false;
        \\          resolve();
        \\        }
        \\      });
        \\      return surfacesFetch;
        \\    };
        \\
        \\    const report = (directory: string): void => {
        \\      if (disposed || !directory) return;
        \\      const status = runStatusFor(directory);
        \\      if (status === null) return;
        \\      const title = titleFor(directory);
        \\      const key = `${directory}\u0000${status}\u0000${title}`;
        \\      if (lastReport.get(directory) === key) return;
        \\      lastReport.set(directory, key);
        \\      if (debug) console.log(`[verde-notify] ${directory} -> ${status} ${title}`);
        \\      pending = pending.then(async () => {
        \\        if (disposed) return;
        \\        await refreshSurfaces();
        \\        for (const surface of surfaces) {
        \\          if (surface.workspace_path !== directory) continue;
        \\          // Unclassified panes (provider null) have not been stamped yet; the
        \\          // notify below claims them as opencode on the first report.
        \\          if (surface.provider != null && surface.provider !== 'opencode') continue;
        \\          const args = [
        \\            'notify', '--quiet', '--session', surface.session_id,
        \\            '--status', status, '--provider', 'opencode',
        \\          ];
        \\          if (title) args.push('--title', title);
        \\          spawnNotify(args);
        \\        }
        \\      });
        \\    };
        \\
        \\
        \\    const setSessionStatus = (sessionID: string, status: SessionRunState): void => {
        \\      const node = sessions.get(sessionID);
        \\      if (!node) return;
        \\      node.status = status;
        \\      if (status === 'busy' || status === 'retry') permissionSessions.delete(sessionID);
        \\      report(node.directory);
        \\    };
        \\
        \\    const handleEvent = (event: unknown): void => {
        \\      if (debug) console.log('[ev] ' + (event as any)?.type + ' ' + ((event as any)?.data?.sessionID ?? ''));
        \\      const envelope = event as { type?: string; data?: Record<string, any> } | null | undefined;
        \\      const type = envelope?.type;
        \\      const data = envelope?.data;
        \\      if (!type || !data) return;
        \\
        \\      if (type === 'session.created') {
        \\        const sessionID = typeof data.sessionID === 'string' ? data.sessionID : undefined;
        \\        const directory =
        \\          typeof data.location?.directory === 'string' ? data.location.directory : undefined;
        \\        if (!sessionID || !directory) return;
        \\        sessions.set(sessionID, {
        \\          directory,
        \\          parentID: typeof data.parentID === 'string' ? data.parentID : undefined,
        \\          status: data.parentID ? 'busy' : 'idle',
        \\          title: normalizeTitle(data.title),
        \\        });
        \\        report(directory);
        \\        return;
        \\      }
        \\
        \\      const sessionID =
        \\        typeof data.sessionID === 'string'
        \\          ? data.sessionID
        \\          : typeof data.info?.id === 'string'
        \\            ? data.info.id
        \\            : undefined;
        \\      const node = sessionID ? sessions.get(sessionID) : undefined;
        \\      if (!sessionID || !node) { if (debug) console.log('[ev] dropped ' + type + ' ' + sessionID); return; }
        \\      switch (type) {
        \\        case 'session.renamed':
        \\          node.title = normalizeTitle(data.title);
        \\          report(node.directory);
        \\          break;
        \\        case 'session.status': {
        \\          const runState: SessionRunState =
        \\            data.status?.type === 'busy' ? 'busy' : data.status?.type === 'retry' ? 'retry' : 'idle';
        \\          setSessionStatus(sessionID, runState);
        \\          break;
        \\        }
        \\        case 'session.idle':
        \\          setSessionStatus(sessionID, 'idle');
        \\          break;
        \\        case 'session.deleted':
        \\          sessions.delete(sessionID);
        \\          permissionSessions.delete(sessionID);
        \\          report(node.directory);
        \\          break;
        \\        case 'permission.asked':
        \\          permissionSessions.add(sessionID);
        \\          report(node.directory);
        \\          break;
        \\        case 'permission.replied':
        \\          permissionSessions.delete(sessionID);
        \\          report(node.directory);
        \\          break;
        \\      }
        \\    };
        \\
        \\    const iterator = (subscribe.call(host) as AsyncIterable<unknown>)[Symbol.asyncIterator]();
        \\    void (async () => {
        \\      try {
        \\        while (!disposed) {
        \\          const next = await iterator.next();
        \\          if (next.done || disposed) break;
        \\          try {
        \\            handleEvent(next.value);
        \\          } catch {
        \\            // One malformed event must not stop the subscription.
        \\          }
        \\        }
        \\      } catch {
        \\        // Event streaming is best-effort and must not interrupt OpenCode.
        \\      }
        \\    })();
        \\
        \\    return () => {
        \\      disposed = true;
        \\      try {
        \\        void iterator.return?.();
        \\      } catch {
        \\        // The stream may already be closed; cleanup stays best-effort.
        \\      }
        \\    };
        \\  },
        \\};
    ;
    try writeFileAtomic(allocator, io, path, plugin, .default_file);
}

/// True when our managed Amp plugin is present in the global Amp plugin dir.
pub fn ampGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const plugin_path = std.fs.path.join(allocator, &.{ home, AMP_GLOBAL_PLUGIN_REL }) catch return false;
    defer allocator.free(plugin_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), plugin_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, AMP_GLOBAL_PLUGIN_NEEDLE) != null;
}

/// Installs the Amp notify integration globally. Amp exposes lifecycle hooks via
/// TypeScript plugins rather than Claude/Codex-style JSON hook settings, so this
/// writes one managed plugin under ~/.config/amp/plugins.
pub fn ensureAmpGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const plugin_path = try std.fs.path.join(allocator, &.{ home, AMP_GLOBAL_PLUGIN_REL });
    defer allocator.free(plugin_path);

    try ensureParentDir(io, plugin_path);
    try writeAmpPlugin(allocator, io, plugin_path);
}

/// Removes the managed Amp notify plugin. Idempotent.
pub fn removeAmpGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const plugin_path = try std.fs.path.join(allocator, &.{ home, AMP_GLOBAL_PLUGIN_REL });
    defer allocator.free(plugin_path);
    std.Io.Dir.cwd().deleteFile(threaded.io(), plugin_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writeAmpPlugin(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const plugin =
        \\// verde-amp-notify-plugin
        \\import type { PluginAPI, Subscription, ThreadState } from '@ampcode/plugin';
        \\
        \\type ChildWatch = {
        \\  active: boolean;
        \\  revision: number;
        \\  subscription: Subscription | null;
        \\};
        \\
        \\type ThreadWatch = {
        \\  active: boolean;
        \\  children: Map<string, ChildWatch>;
        \\  parentState: ThreadState;
        \\  pending: Promise<void>;
        \\  revision: number;
        \\  subscription: Subscription | null;
        \\  title: string;
        \\  titleRevision: number;
        \\  titleSubscription: Subscription | null;
        \\  lastStatus: 'idle' | 'working' | 'done' | 'waiting' | 'error' | null;
        \\  lastTitle: string;
        \\};
        \\
        \\const threadWatches = new Map<string, ThreadWatch>();
        \\
        \\function inVerdePane(): boolean {
        \\  return process.env.VERDE === '1' && Boolean(process.env.VERDE_SESSION_ID);
        \\}
        \\
        \\function verdeCli(): string {
        \\  const raw = process.env.VERDE_CLI || 'verde';
        \\  // Linux appends this marker when /proc/self/exe points at a binary
        \\  // replaced by a rebuild while Verde is still running.
        \\  return raw.endsWith(' (deleted)') ? raw.slice(0, -10) : raw;
        \\}
        \\
        \\function normalizeTitle(value: string | null): string {
        \\  return (value || '').replace(/\\s+/g, ' ').trim().slice(0, 72);
        \\}
        \\
        \\async function notify(amp: PluginAPI, shell: PluginAPI['$'], status: 'idle' | 'working' | 'done' | 'waiting' | 'error', title: string): Promise<void> {
        \\  if (!inVerdePane()) return;
        \\  const cli = verdeCli();
        \\  try {
        \\    if (title) {
        \\      await shell`${cli} notify --quiet --status ${status} --title ${title} --provider amp`;
        \\    } else {
        \\      await shell`${cli} notify --quiet --status ${status} --provider amp`;
        \\    }
        \\  } catch (err) {
        \\    // Best-effort only: Amp should never fail because Verde is absent.
        \\    amp.logger.log(`Verde notify failed: ${err instanceof Error ? err.message : String(err)}`);
        \\  }
        \\}
        \\
        \\async function notifyThreadStatus(amp: PluginAPI, watch: ThreadWatch): Promise<void> {
        \\  let status: 'idle' | 'working' | 'done' | 'waiting' | 'error';
        \\  switch (watch.parentState) {
        \\    case 'running':
        \\      status = 'working';
        \\      break;
        \\    case 'awaiting-approval':
        \\      status = 'waiting';
        \\      break;
        \\    case 'error':
        \\      status = 'error';
        \\      break;
        \\    case 'idle':
        \\      status = watch.children.size > 0 ? 'waiting' : watch.active ? 'done' : 'idle';
        \\      if (status !== 'waiting') watch.active = false;
        \\      break;
        \\  }
        \\  if (status === watch.lastStatus && watch.title === watch.lastTitle) return;
        \\  watch.lastStatus = status;
        \\  watch.lastTitle = watch.title;
        \\  await notify(amp, amp.$, status, watch.title);
        \\}
        \\
        \\function queueThreadState(amp: PluginAPI, threadId: string, watch: ThreadWatch, state: ThreadState): void {
        \\  watch.pending = watch.pending.then(async () => {
        \\    if (threadWatches.get(threadId) !== watch) return;
        \\    watch.parentState = state;
        \\    switch (state) {
        \\      case 'running':
        \\      case 'awaiting-approval':
        \\      case 'error':
        \\        watch.active = true;
        \\        break;
        \\      case 'idle':
        \\        break;
        \\    }
        \\    await notifyThreadStatus(amp, watch);
        \\  });
        \\}
        \\
        \\function queueThreadTitle(amp: PluginAPI, threadId: string, watch: ThreadWatch, title: string | null): void {
        \\  watch.pending = watch.pending.then(async () => {
        \\    if (threadWatches.get(threadId) !== watch) return;
        \\    watch.title = normalizeTitle(title);
        \\    await notifyThreadStatus(amp, watch);
        \\  });
        \\}
        \\
        \\function queueChildState(amp: PluginAPI, threadId: string, watch: ThreadWatch, childId: string, child: ChildWatch, state: ThreadState): void {
        \\  watch.pending = watch.pending.then(async () => {
        \\    if (threadWatches.get(threadId) !== watch || watch.children.get(childId) !== child) return;
        \\    switch (state) {
        \\      case 'running':
        \\      case 'awaiting-approval':
        \\        child.active = true;
        \\        break;
        \\      case 'error':
        \\        child.subscription?.unsubscribe();
        \\        watch.children.delete(childId);
        \\        break;
        \\      case 'idle':
        \\        // A freshly created thread can be idle before its executor starts.
        \\        if (child.active) {
        \\          child.subscription?.unsubscribe();
        \\          watch.children.delete(childId);
        \\        }
        \\        break;
        \\    }
        \\    await notifyThreadStatus(amp, watch);
        \\  });
        \\}
        \\
        \\function watchChildThread(amp: PluginAPI, threadId: string, watch: ThreadWatch, childId: string): void {
        \\  if (childId === threadId || watch.children.has(childId)) return;
        \\  const child: ChildWatch = {
        \\    active: false,
        \\    revision: 0,
        \\    subscription: null,
        \\  };
        \\  watch.children.set(childId, child);
        \\  const childThread = amp.threads.get(childId as `T-${string}`);
        \\  child.subscription = childThread.state.subscribe((state) => {
        \\    child.revision += 1;
        \\    queueChildState(amp, threadId, watch, childId, child, state);
        \\  });
        \\  void childThread.state.get().then((state) => {
        \\    if (threadWatches.get(threadId) === watch && watch.children.get(childId) === child && child.revision === 0) {
        \\      queueChildState(amp, threadId, watch, childId, child, state);
        \\    }
        \\  }).catch((err) => {
        \\    amp.logger.log(`Verde child thread state failed: ${err instanceof Error ? err.message : String(err)}`);
        \\  });
        \\}
        \\
        \\function threadIdsFromOutput(output: unknown): Set<string> {
        \\  const ids = new Set<string>();
        \\  const seen = new WeakSet<object>();
        \\  const visit = (value: unknown): void => {
        \\    if (typeof value === 'string') {
        \\      for (const match of value.matchAll(/T-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi)) {
        \\        ids.add(match[0]);
        \\      }
        \\      return;
        \\    }
        \\    if (value === null || typeof value !== 'object' || seen.has(value)) return;
        \\    seen.add(value);
        \\    if (Array.isArray(value)) {
        \\      for (const item of value) visit(item);
        \\    } else {
        \\      for (const item of Object.values(value as Record<string, unknown>)) visit(item);
        \\    }
        \\  };
        \\  visit(output);
        \\  return ids;
        \\}
        \\
        \\export default function (amp: PluginAPI) {
        \\  amp.logger.log('Verde notify plugin initialized');
        \\
        \\  amp.on('session.start', async (event, ctx) => {
        \\    const threadId = event.thread.id;
        \\    const previous = threadWatches.get(threadId);
        \\    previous?.subscription?.unsubscribe();
        \\    previous?.titleSubscription?.unsubscribe();
        \\    if (previous) {
        \\      for (const child of previous.children.values()) child.subscription?.unsubscribe();
        \\    }
        \\    const watch: ThreadWatch = {
        \\      active: false,
        \\      children: new Map(),
        \\      parentState: 'idle',
        \\      pending: Promise.resolve(),
        \\      revision: 0,
        \\      subscription: null,
        \\      title: '',
        \\      titleRevision: 0,
        \\      titleSubscription: null,
        \\      lastStatus: null,
        \\      lastTitle: '',
        \\    };
        \\    threadWatches.set(threadId, watch);
        \\    watch.subscription = ctx.thread.state.subscribe((state) => {
        \\      watch.revision += 1;
        \\      queueThreadState(amp, threadId, watch, state);
        \\    });
        \\    watch.titleSubscription = ctx.thread.title.subscribe((title) => {
        \\      watch.titleRevision += 1;
        \\      queueThreadTitle(amp, threadId, watch, title);
        \\    });
        \\    const [state, title] = await Promise.all([ctx.thread.state.get(), ctx.thread.title.get()]);
        \\    if (threadWatches.get(threadId) === watch && watch.revision === 0) {
        \\      queueThreadState(amp, threadId, watch, state);
        \\    }
        \\    if (threadWatches.get(threadId) === watch && watch.titleRevision === 0) {
        \\      queueThreadTitle(amp, threadId, watch, title);
        \\    }
        \\  });
        \\
        \\  amp.on('tool.result', (event) => {
        \\    if (event.tool !== 'create_thread' || event.status !== 'done') return;
        \\    const threadId = event.thread.id;
        \\    const watch = threadWatches.get(threadId);
        \\    if (!watch) return;
        \\    for (const childId of threadIdsFromOutput(event.output)) {
        \\      watchChildThread(amp, threadId, watch, childId);
        \\    }
        \\  });
        \\
        \\  amp.onDispose(() => {
        \\    for (const watch of threadWatches.values()) {
        \\      watch.subscription?.unsubscribe();
        \\      watch.titleSubscription?.unsubscribe();
        \\      for (const child of watch.children.values()) child.subscription?.unsubscribe();
        \\    }
        \\    threadWatches.clear();
        \\  });
        \\}
        \\
    ;
    try writeFileAtomic(allocator, io, path, plugin, .default_file);
}

/// True when the managed Pi lifecycle extension is present globally.
pub fn piGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDirAlloc(allocator) catch return false;
    defer allocator.free(home);
    const extension_path = std.fs.path.join(allocator, &.{ home, PI_GLOBAL_PLUGIN_REL }) catch return false;
    defer allocator.free(extension_path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const content = std.Io.Dir.cwd().readFileAlloc(threaded.io(), extension_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, PI_GLOBAL_PLUGIN_NEEDLE) != null;
}

/// Installs Pi's managed global lifecycle extension. Pi loads extensions from
/// ~/.pi/agent/extensions and exposes settled-state and session-name events.
pub fn ensurePiGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const extension_path = try std.fs.path.join(allocator, &.{ home, PI_GLOBAL_PLUGIN_REL });
    defer allocator.free(extension_path);
    try ensureParentDir(threaded.io(), extension_path);
    try writePiPlugin(allocator, threaded.io(), extension_path);
}

/// Removes the managed Pi lifecycle extension. Idempotent.
pub fn removePiGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDirAlloc(allocator) catch return error.NoHomeDir;
    defer allocator.free(home);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const extension_path = try std.fs.path.join(allocator, &.{ home, PI_GLOBAL_PLUGIN_REL });
    defer allocator.free(extension_path);
    std.Io.Dir.cwd().deleteFile(threaded.io(), extension_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn writePiPlugin(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const plugin =
        \\// verde-pi-notify-extension
        \\import type { ExtensionAPI } from '@earendil-works/pi-coding-agent';
        \\
        \\type VerdeStatus = 'idle' | 'working' | 'done';
        \\
        \\function inVerdePane(): boolean {
        \\  return process.env.VERDE === '1' && Boolean(process.env.VERDE_SESSION_ID);
        \\}
        \\
        \\function verdeCli(): string {
        \\  const raw = process.env.VERDE_CLI || (process.platform === 'win32' ? 'verde.exe' : 'verde');
        \\  return raw.endsWith(' (deleted)') ? raw.slice(0, -10) : raw;
        \\}
        \\
        \\function normalizeTitle(value: string | undefined): string {
        \\  return (value || '').replace(/\s+/g, ' ').trim().slice(0, 72);
        \\}
        \\
        \\export default function (pi: ExtensionAPI) {
        \\  let status: VerdeStatus = 'idle';
        \\  let title = '';
        \\  let lastStatus: VerdeStatus | null = null;
        \\  let lastTitle = '';
        \\
        \\  const report = async (nextStatus: VerdeStatus, nextTitle?: string): Promise<void> => {
        \\    status = nextStatus;
        \\    if (nextTitle !== undefined) title = normalizeTitle(nextTitle);
        \\    if (!inVerdePane() || (status === lastStatus && title === lastTitle)) return;
        \\    lastStatus = status;
        \\    lastTitle = title;
        \\    const reportedStatus = status;
        \\    const reportedTitle = title;
        \\    const args = ['notify', '--quiet', '--status', reportedStatus, '--provider', 'pi'];
        \\    if (reportedTitle) args.push('--title', reportedTitle);
        \\    try {
        \\      await pi.exec(verdeCli(), args, { timeout: 5000 });
        \\    } catch {
        \\      // Best-effort only: Pi must continue if Verde is unavailable.
        \\    }
        \\  };
        \\
        \\  pi.on('session_start', async () => {
        \\    await report('idle', pi.getSessionName());
        \\  });
        \\  pi.on('session_info_changed', async (event) => {
        \\    await report(status, event.name);
        \\  });
        \\  pi.on('before_agent_start', async (event) => {
        \\    await report('working', pi.getSessionName() || event.prompt);
        \\  });
        \\  pi.on('agent_start', async () => {
        \\    await report('working');
        \\  });
        \\  pi.on('agent_settled', async () => {
        \\    await report('done');
        \\  });
        \\}
        \\
    ;
    try writeFileAtomic(allocator, io, path, plugin, .default_file);
}

fn codexMatcherEntry(arena: std.mem.Allocator, hook_path: []const u8, status_message: []const u8) !std.json.Value {
    var cmd: std.json.ObjectMap = .empty;
    try cmd.put(arena, "type", .{ .string = "command" });
    try cmd.put(arena, "command", .{ .string = try arena.dupe(u8, hook_path) });
    try cmd.put(arena, "timeout", .{ .integer = 5 });
    try cmd.put(arena, "statusMessage", .{ .string = try arena.dupe(u8, status_message) });
    var inner = std.json.Array.init(arena);
    try inner.append(.{ .object = cmd });
    var entry: std.json.ObjectMap = .empty;
    try entry.put(arena, "matcher", .{ .string = "*" });
    try entry.put(arena, "hooks", .{ .array = inner });
    return .{ .object = entry };
}

fn ensureCodexEvent(arena: std.mem.Allocator, hooks: *std.json.ObjectMap, event: CodexHookEvent, hook_path: []const u8) !bool {
    if (hooks.getPtr(event.name)) |ev| {
        if (ev.* != .array) return false;
        for (ev.array.items) |entry| {
            // Reuse the Claude detector: both shapes nest commands under "hooks".
            if (claudeEntryReferencesHook(entry, hook_path)) return false;
        }
        try ev.array.append(try codexMatcherEntry(arena, hook_path, event.status_message));
        return true;
    }
    var arr = std.json.Array.init(arena);
    try arr.append(try codexMatcherEntry(arena, hook_path, event.status_message));
    try hooks.put(arena, event.name, .{ .array = arr });
    return true;
}

fn mergeCodexHooks(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.CodexHooksParse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CodexHooksNotObject;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;

    if (root.getPtr("hooks")) |hv| {
        if (hv.* != .object) return error.CodexHooksHooksNotObject;
    } else {
        try root.put(arena, "hooks", .{ .object = .empty });
    }
    const hooks = &root.getPtr("hooks").?.object;

    var changed = false;
    for (CODEX_HOOK_EVENTS) |event| {
        if (try ensureCodexEvent(arena, hooks, event, hook_path)) changed = true;
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn removeCodexHooksFromJson(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const hooks_val = root.getPtr("hooks") orelse return null;
    if (hooks_val.* != .object) return null;
    const hooks = &hooks_val.object;

    var changed = false;
    for (CODEX_HOOK_EVENTS) |event| {
        const ev = hooks.getPtr(event.name) orelse continue;
        if (ev.* != .array) continue;
        var kept = std.json.Array.init(arena);
        for (ev.array.items) |entry| {
            if (claudeEntryReferencesHook(entry, hook_path)) {
                changed = true;
                continue;
            }
            try kept.append(entry);
        }
        if (kept.items.len == 0) {
            _ = hooks.orderedRemove(event.name);
        } else {
            ev.* = .{ .array = kept };
        }
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn claudeEntryReferencesHook(entry: std.json.Value, hook_path: []const u8) bool {
    if (entry != .object) return false;
    const inner = entry.object.get("hooks") orelse return false;
    if (inner != .array) return false;
    for (inner.array.items) |cmd| {
        if (cmd != .object) continue;
        const command = cmd.object.get("command") orelse continue;
        if (command == .string and std.mem.eql(u8, command.string, hook_path)) return true;
    }
    return false;
}

fn claudeMatcherEntry(arena: std.mem.Allocator, hook_path: []const u8) !std.json.Value {
    var cmd: std.json.ObjectMap = .empty;
    try cmd.put(arena, "type", .{ .string = "command" });
    try cmd.put(arena, "command", .{ .string = try arena.dupe(u8, hook_path) });
    try cmd.put(arena, "timeout", .{ .integer = 5 });
    var inner = std.json.Array.init(arena);
    try inner.append(.{ .object = cmd });
    var entry: std.json.ObjectMap = .empty;
    try entry.put(arena, "hooks", .{ .array = inner });
    return .{ .object = entry };
}

fn ensureClaudeEvent(arena: std.mem.Allocator, hooks: *std.json.ObjectMap, event: []const u8, hook_path: []const u8) !bool {
    if (hooks.getPtr(event)) |ev| {
        if (ev.* != .array) return false;
        for (ev.array.items) |entry| {
            if (claudeEntryReferencesHook(entry, hook_path)) return false;
        }
        try ev.array.append(try claudeMatcherEntry(arena, hook_path));
        return true;
    }
    var arr = std.json.Array.init(arena);
    try arr.append(try claudeMatcherEntry(arena, hook_path));
    try hooks.put(arena, event, .{ .array = arr });
    return true;
}

fn mergeClaudeHooks(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.ClaudeSettingsParse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ClaudeSettingsNotObject;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;

    if (root.getPtr("hooks")) |hv| {
        if (hv.* != .object) return error.ClaudeSettingsHooksNotObject;
    } else {
        try root.put(arena, "hooks", .{ .object = .empty });
    }
    const hooks = &root.getPtr("hooks").?.object;

    var changed = false;
    for (CLAUDE_HOOK_EVENTS) |event| {
        if (try ensureClaudeEvent(arena, hooks, event, hook_path)) changed = true;
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn removeClaudeHooksFromJson(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const hooks_val = root.getPtr("hooks") orelse return null;
    if (hooks_val.* != .object) return null;
    const hooks = &hooks_val.object;

    var changed = false;
    for (CLAUDE_HOOK_EVENTS) |event| {
        const ev = hooks.getPtr(event) orelse continue;
        if (ev.* != .array) continue;
        var kept = std.json.Array.init(arena);
        for (ev.array.items) |entry| {
            if (claudeEntryReferencesHook(entry, hook_path)) {
                changed = true;
                continue;
            }
            try kept.append(entry);
        }
        if (kept.items.len == 0) {
            _ = hooks.orderedRemove(event);
        } else {
            ev.* = .{ .array = kept };
        }
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn cursorEntryReferencesHook(entry: std.json.Value, hook_path: []const u8) bool {
    if (entry != .object) return false;
    const command = entry.object.get("command") orelse return false;
    return command == .string and std.mem.eql(u8, command.string, hook_path);
}

fn cursorHookEntry(arena: std.mem.Allocator, hook_path: []const u8) !std.json.Value {
    var entry: std.json.ObjectMap = .empty;
    try entry.put(arena, "command", .{ .string = try arena.dupe(u8, hook_path) });
    try entry.put(arena, "timeout", .{ .integer = 5 });
    return .{ .object = entry };
}

fn ensureCursorEvent(arena: std.mem.Allocator, hooks: *std.json.ObjectMap, event: []const u8, hook_path: []const u8) !bool {
    if (hooks.getPtr(event)) |value| {
        if (value.* != .array) return error.CursorHooksEventNotArray;
        for (value.array.items) |entry| {
            if (cursorEntryReferencesHook(entry, hook_path)) return false;
        }
        try value.array.append(try cursorHookEntry(arena, hook_path));
        return true;
    }
    var entries = std.json.Array.init(arena);
    try entries.append(try cursorHookEntry(arena, hook_path));
    try hooks.put(arena, event, .{ .array = entries });
    return true;
}

fn mergeCursorHooks(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.CursorHooksParse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CursorHooksNotObject;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;

    var changed = false;
    if (root.get("version") == null) {
        try root.put(arena, "version", .{ .integer = 1 });
        changed = true;
    }
    if (root.getPtr("hooks")) |value| {
        if (value.* != .object) return error.CursorHooksHooksNotObject;
    } else {
        try root.put(arena, "hooks", .{ .object = .empty });
        changed = true;
    }
    const hooks = &root.getPtr("hooks").?.object;
    for (CURSOR_HOOK_EVENTS) |event| {
        if (try ensureCursorEvent(arena, hooks, event, hook_path)) changed = true;
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn removeCursorHooksFromJson(allocator: std.mem.Allocator, content: []const u8, hook_path: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const hooks_value = root.getPtr("hooks") orelse return null;
    if (hooks_value.* != .object) return null;
    const hooks = &hooks_value.object;

    var changed = false;
    for (CURSOR_HOOK_EVENTS) |event| {
        const value = hooks.getPtr(event) orelse continue;
        if (value.* != .array) continue;
        var kept = std.json.Array.init(arena);
        for (value.array.items) |entry| {
            if (cursorEntryReferencesHook(entry, hook_path)) {
                changed = true;
                continue;
            }
            try kept.append(entry);
        }
        if (kept.items.len == 0) {
            _ = hooks.orderedRemove(event);
        } else {
            value.* = .{ .array = kept };
        }
    }
    if (!changed) return null;
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
}

fn writeFileAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, content: []const u8, permissions: std.Io.File.Permissions) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .permissions = permissions });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

test "ensureCodexProjectHooks writes hook script and hooks json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_path);

    try ensureCodexProjectHooks(std.testing.allocator, project_path);

    const hook_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CODEX_HOOK_REL_PATH });
    defer std.testing.allocator.free(hook_path);
    const hooks_json_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CODEX_HOOKS_JSON_REL_PATH });
    defer std.testing.allocator.free(hooks_json_path);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const hook_script = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), hook_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(hook_script);
    try std.testing.expect(std.mem.indexOf(u8, hook_script, CODEX_HOOK_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, hook_script, "PermissionRequest") != null);

    const hooks_json = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_json_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(hooks_json);
    try std.testing.expect(std.mem.indexOf(u8, hooks_json, "PermissionRequest") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks_json, hook_path) != null);
}

test "ensureCodexProjectHooks accepts existing managed hooks json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_path);

    try ensureCodexProjectHooks(std.testing.allocator, project_path);
    try ensureCodexProjectHooks(std.testing.allocator, project_path);
}

test "removeCodexProjectHooks removes only Verde lifecycle entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_path);

    try ensureCodexProjectHooks(std.testing.allocator, project_path);
    try removeCodexProjectHooks(std.testing.allocator, project_path);

    const hook_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CODEX_HOOK_REL_PATH });
    defer std.testing.allocator.free(hook_path);
    const hooks_json_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CODEX_HOOKS_JSON_REL_PATH });
    defer std.testing.allocator.free(hooks_json_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(threaded.io(), hook_path, .{}));
    const hooks_json = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_json_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(hooks_json);
    try std.testing.expect(std.mem.indexOf(u8, hooks_json, hook_path) == null);
}

test "managed project hooks gain subagent lifecycle events" {
    const codex_hook = "/tmp/verde-codex-notify-hook.sh";
    const codex_legacy =
        \\{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"/tmp/verde-codex-notify-hook.sh"}]}]}}
    ;
    const codex_merged = (try mergeCodexHooks(std.testing.allocator, codex_legacy, codex_hook)).?;
    defer std.testing.allocator.free(codex_merged);
    try std.testing.expect(std.mem.indexOf(u8, codex_merged, "SubagentStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_merged, "SubagentStop") != null);

    const claude_hook = "/tmp/verde-claude-notify-hook.sh";
    const claude_legacy =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/tmp/verde-claude-notify-hook.sh"}]}]}}
    ;
    const claude_merged = (try mergeClaudeHooks(std.testing.allocator, claude_legacy, claude_hook)).?;
    defer std.testing.allocator.free(claude_merged);
    try std.testing.expect(std.mem.indexOf(u8, claude_merged, "SubagentStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_merged, "SubagentStop") != null);
}

test "ensureCodexProjectHooks refuses unmanaged hooks json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_path);

    try tmp.dir.createDirPath(std.testing.io, ".codex");
    {
        var file = try tmp.dir.createFile(std.testing.io, ".codex/hooks.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{\"hooks\":{}}\n");
    }

    try std.testing.expectError(error.CodexHooksJsonExists, ensureCodexProjectHooks(std.testing.allocator, project_path));
}

test "ensureCursorProjectHooks merges lifecycle hooks without replacing user hooks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(project_path);

    try tmp.dir.createDirPath(std.testing.io, ".cursor");
    {
        var file = try tmp.dir.createFile(std.testing.io, ".cursor/hooks.json", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io,
            \\{"version":1,"hooks":{"stop":[{"command":"user-stop-hook"}]},"userSetting":true}
        );
    }

    try ensureCursorProjectHooks(std.testing.allocator, project_path);
    try ensureCursorProjectHooks(std.testing.allocator, project_path);

    const hook_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CURSOR_PROJECT_HOOK_REL_PATH });
    defer std.testing.allocator.free(hook_path);
    const hooks_path = try std.fs.path.join(std.testing.allocator, &.{ project_path, CURSOR_HOOKS_JSON_REL_PATH });
    defer std.testing.allocator.free(hooks_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    const script = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), hook_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, CURSOR_HOOK_MARKER) != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--provider cursor") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "beforeSubmitPrompt") != null);

    const hooks = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(hooks);
    try std.testing.expect(std.mem.indexOf(u8, hooks, "user-stop-hook") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks, "userSetting") != null);
    for (CURSOR_HOOK_EVENTS) |event| {
        try std.testing.expect(std.mem.indexOf(u8, hooks, event) != null);
    }
    try std.testing.expectEqual(CURSOR_HOOK_EVENTS.len, std.mem.count(u8, hooks, CURSOR_PROJECT_HOOK_REL_PATH));
}

test "Cursor hook removal preserves unrelated configuration" {
    const hook_path = "/home/test/.cursor/hooks/verde-cursor-notify-hook.sh";
    const original =
        \\{"version":1,"hooks":{"stop":[{"command":"user-stop-hook"}]},"userSetting":true}
    ;
    const merged = (try mergeCursorHooks(std.testing.allocator, original, hook_path)).?;
    defer std.testing.allocator.free(merged);
    const removed = (try removeCursorHooksFromJson(std.testing.allocator, merged, hook_path)).?;
    defer std.testing.allocator.free(removed);

    try std.testing.expect(std.mem.indexOf(u8, removed, "user-stop-hook") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "userSetting") != null);
    try std.testing.expect(std.mem.indexOf(u8, removed, CURSOR_GLOBAL_HOOK_NEEDLE) == null);
}

test "Windows hook commands quote Unicode paths and select PowerShell scripts" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings(CODEX_WINDOWS_HOOK_REL_PATH, codexProjectHookRelPathForOs(.windows));
    try std.testing.expectEqualStrings(CLAUDE_WINDOWS_HOOK_REL_PATH, claudeProjectHookRelPathForOs(.windows));
    try std.testing.expectEqualStrings(CURSOR_WINDOWS_PROJECT_HOOK_REL_PATH, cursorProjectHookRelPathForOs(.windows));

    const hook_path = "C:\\Users\\Zoë Tester\\Client Repo\\.verde\\hooks\\codex-notify-hook.ps1";
    const command = try hookCommandAllocForOs(allocator, .windows, hook_path);
    defer allocator.free(command);
    try std.testing.expectEqualStrings(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"C:\\Users\\Zoë Tester\\Client Repo\\.verde\\hooks\\codex-notify-hook.ps1\"",
        command,
    );

    const json = try codexHooksJsonAlloc(allocator, command);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "powershell.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Zoë Tester") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, CODEX_PROJECT_HOOK_NEEDLE) != null);
}

test "PowerShell hooks use inherited transport-neutral endpoint and safe invocation" {
    const codex_script = codexPowerShellHookScript();
    try std.testing.expect(std.mem.indexOf(u8, codex_script, "$env:VERDE_LIVE_ENDPOINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_script, "& $cli @notifyArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_script, "@('--title', $title)") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_script, "/bin/sh") == null);

    const claude_script = claudePowerShellHookScript();
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "$env:VERDE_LIVE_ENDPOINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "ConvertFrom-Json") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "@('--title', $title)") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "& $cli @notifyArgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "$source -eq 'compact'") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_script, "'parent-working'") != null);

    const cursor_script = cursorPowerShellHookScript();
    try std.testing.expect(std.mem.indexOf(u8, cursor_script, "$env:VERDE_LIVE_ENDPOINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, cursor_script, "beforeSubmitPrompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, cursor_script, "--provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, cursor_script, "'cursor'") != null);
    try std.testing.expect(std.mem.indexOf(u8, cursor_script, "@('--title', $title)") != null);

    const grok_script = grokPowerShellHookScript();
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "$env:VERDE_LIVE_ENDPOINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "hookEventName") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "SubagentStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "<user_query>") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "</user_query>") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "generated_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "VERDE_GROK_TITLE_SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "Start-Process") != null);
    try std.testing.expect(std.mem.indexOf(u8, grok_script, "'grok'") != null);
}

test "Claude hook reports a prompt-derived title" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/claude-hook.sh", .{tmp.sub_path});
    defer std.testing.allocator.free(script_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try writeClaudeHookScript(std.testing.allocator, threaded.io(), script_path);
    const script = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), script_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, ".prompt // empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--title \"$title\" --provider claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "[ \"$source\" = \"compact\" ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "activity=\"parent-working\"") != null);
    if (builtin.os.tag != .windows) {
        const syntax = try std.process.run(std.testing.allocator, threaded.io(), .{
            .argv = &.{ "sh", "-n", script_path },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(8 * 1024),
        });
        defer std.testing.allocator.free(syntax.stdout);
        defer std.testing.allocator.free(syntax.stderr);
        switch (syntax.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedHookSyntaxCheckTermination,
        }
    }
}

test "OpenCode plugin targets the OpenCode 2 service event contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plugin_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/verde-opencode-notify.ts", .{tmp.sub_path});
    defer std.testing.allocator.free(plugin_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try writeOpencodePlugin(std.testing.allocator, threaded.io(), plugin_path);
    const plugin = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), plugin_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(plugin);
    // v2 plugins load only from a default export; named hook exports are ignored.
    try std.testing.expect(std.mem.indexOf(u8, plugin, "export default {") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "id: 'verde-opencode-notify'") != null);
    // v2 event payloads are flat `{ type, data }`; no v1 `properties.info` reads remain.
    try std.testing.expect(std.mem.indexOf(u8, plugin, "event.properties") == null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "session.created") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "session.renamed") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "permission.asked") != null);
    // Plugins run in the shared service, so panes are resolved through Verde.
    try std.testing.expect(std.mem.indexOf(u8, plugin, "'live', 'surfaces', '--json'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "'--session', surface.session_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "'--provider', 'opencode'") != null);
}

test "Pi extension reports lifecycle and native session titles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plugin_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/verde-pi-notify.ts", .{tmp.sub_path});
    defer std.testing.allocator.free(plugin_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try writePiPlugin(std.testing.allocator, threaded.io(), plugin_path);
    const plugin = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), plugin_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(plugin);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "pi.on('before_agent_start'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "pi.on('agent_settled'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "pi.on('session_info_changed'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "pi.getSessionName() || event.prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "await report('working'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "'--provider', 'pi'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "args.push('--title', reportedTitle)") != null);
}

test "agent activity state accepts opaque Verde session ids" {
    try std.testing.expect(std.mem.indexOf(u8, POSIX_AGENT_ACTIVITY_STATE, "cksum") != null);
    try std.testing.expect(std.mem.indexOf(u8, POSIX_AGENT_ACTIVITY_STATE, "$provider-$session_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, POSIX_AGENT_ACTIVITY_STATE, "*[!A-Za-z0-9._-]*") == null);

    try std.testing.expect(std.mem.indexOf(u8, POWERSHELL_AGENT_ACTIVITY_STATE, "SHA256") != null);
    try std.testing.expect(std.mem.indexOf(u8, POWERSHELL_AGENT_ACTIVITY_STATE, "$Provider + '-' + $sessionFingerprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, POWERSHELL_AGENT_ACTIVITY_STATE, "^[A-Za-z0-9._-]+$") == null);
}

test "Grok hook file registers native lifecycle events" {
    const hook_path = "/home/test/.grok/verde-grok-notify-hook.sh";
    const hooks_json = try grokHooksJsonAlloc(std.testing.allocator, hook_path);
    defer std.testing.allocator.free(hooks_json);

    for (GROK_HOOK_EVENTS) |event| {
        try std.testing.expect(std.mem.indexOf(u8, hooks_json, event) != null);
    }
    try std.testing.expectEqual(GROK_HOOK_EVENTS.len, std.mem.count(u8, hooks_json, hook_path));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/grok-hook.sh", .{tmp.sub_path});
    defer std.testing.allocator.free(script_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try writeGrokHookScript(std.testing.allocator, threaded.io(), script_path);
    const script = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), script_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "hookEventName") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "stop_failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "SubagentStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "<user_query>") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "<\\/user_query>") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "generated_title") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "VERDE_GROK_TITLE_SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "\"$0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "--provider grok") != null);
    if (builtin.os.tag != .windows) {
        const syntax = try std.process.run(std.testing.allocator, threaded.io(), .{
            .argv = &.{ "sh", "-n", script_path },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(8 * 1024),
        });
        defer std.testing.allocator.free(syntax.stdout);
        defer std.testing.allocator.free(syntax.stderr);
        switch (syntax.term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedHookSyntaxCheckTermination,
        }
    }
}

test "Grok hook install and removal stay inside the provider home" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const grok_home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(grok_home);

    try std.testing.expect(!grokGlobalHooksInstalledAt(std.testing.allocator, grok_home));
    try ensureGrokGlobalHooksAt(std.testing.allocator, grok_home);
    try std.testing.expect(grokGlobalHooksInstalledAt(std.testing.allocator, grok_home));
    try removeGrokGlobalHooksAt(std.testing.allocator, grok_home);
    try std.testing.expect(!grokGlobalHooksInstalledAt(std.testing.allocator, grok_home));
}

test "Amp plugin follows thread state across automatic retries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plugin_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/verde-notify.ts", .{tmp.sub_path});
    defer std.testing.allocator.free(plugin_path);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    try writeAmpPlugin(std.testing.allocator, threaded.io(), plugin_path);
    const plugin = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), plugin_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(plugin);

    try std.testing.expect(std.mem.indexOf(u8, plugin, "ctx.thread.state.subscribe") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "ctx.thread.title.subscribe") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "ctx.thread.title.get()") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "--title ${title} --provider amp") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "case 'running':") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "case 'awaiting-approval':") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "case 'error':") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "case 'idle':") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "threadWatches.get(threadId) === watch && watch.revision === 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "amp.on('tool.result'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "event.tool !== 'create_thread'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "watch.children.size > 0 ? 'waiting'") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "childThread.state.subscribe") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin, "amp.on('agent.end'") == null);
}

test "Codex generated hook synchronizes provider names and lifecycle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/codex-hook.sh", .{tmp.sub_path});
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    try writeCodexHookScript(allocator, threaded.io(), path);
    const result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "python3", "-c", @embedFile("codex_hook_test.py"), path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.CodexHookFixtureFailed;
    }
    const ps_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/codex-hook.ps1", .{tmp.sub_path});
    defer allocator.free(ps_path);
    try writeFileAtomic(allocator, threaded.io(), ps_path, codexPowerShellHookScript(), .default_file);
    const ps_result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "python3", "-c", @embedFile("codex_hook_test.py"), ps_path },
    });
    defer allocator.free(ps_result.stdout);
    defer allocator.free(ps_result.stderr);
    if (ps_result.term != .exited or ps_result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ ps_result.stdout, ps_result.stderr });
        return error.CodexPowerShellHookFixtureFailed;
    }
    const config = try codexHooksJsonAlloc(allocator, path);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "PreToolUse") != null);
}

test "Claude generated hook preserves compaction and reconciles idle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/claude-hook.sh", .{tmp.sub_path});
    defer allocator.free(path);
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    try writeClaudeHookScript(allocator, threaded.io(), path);
    const result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "python3", "-c", @embedFile("claude_hook_test.py"), path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.ClaudeHookFixtureFailed;
    }
    const ps_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/claude-hook.ps1", .{tmp.sub_path});
    defer allocator.free(ps_path);
    try writeFileAtomic(allocator, threaded.io(), ps_path, claudePowerShellHookScript(), .default_file);
    const ps_result = try std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "python3", "-c", @embedFile("claude_hook_test.py"), ps_path },
    });
    defer allocator.free(ps_result.stdout);
    defer allocator.free(ps_result.stderr);
    if (ps_result.term != .exited or ps_result.term.exited != 0) {
        std.debug.print("{s}\n{s}\n", .{ ps_result.stdout, ps_result.stderr });
        return error.ClaudePowerShellHookFixtureFailed;
    }
}
