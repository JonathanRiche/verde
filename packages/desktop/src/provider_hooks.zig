const std = @import("std");

const CODEX_HOOK_MARKER = "verde-codex-notify-hook";
const CODEX_HOOK_REL_PATH = ".verde/hooks/codex-notify-hook.sh";
const CODEX_HOOKS_JSON_REL_PATH = ".codex/hooks.json";

pub fn ensureCodexProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const hook_path = try std.fs.path.join(allocator, &.{ project_path, CODEX_HOOK_REL_PATH });
    defer allocator.free(hook_path);
    const hooks_json_path = try std.fs.path.join(allocator, &.{ project_path, CODEX_HOOKS_JSON_REL_PATH });
    defer allocator.free(hooks_json_path);

    const io = threaded.io();

    try ensureParentDir(io, hook_path);
    try writeCodexHookScript(allocator, io, hook_path);

    if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), hooks_json_path, allocator, .limited(256 * 1024))) |existing| {
        defer allocator.free(existing);
        if (codexHooksJsonIsManaged(existing)) return;
        return error.CodexHooksJsonExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try ensureParentDir(io, hooks_json_path);
    const hooks_json = try codexHooksJsonAlloc(allocator, hook_path);
    defer allocator.free(hooks_json);
    try writeFileAtomic(allocator, io, hooks_json_path, hooks_json, .default_file);
}

fn codexHooksJsonIsManaged(content: []const u8) bool {
    return std.mem.indexOf(u8, content, CODEX_HOOK_MARKER) != null or
        std.mem.indexOf(u8, content, CODEX_HOOK_REL_PATH) != null;
}

fn writeCodexHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const script =
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
        \\status=""
        \\title="Codex"
        \\body=""
        \\case "$event" in
        \\  SessionStart)
        \\    status="working"; title="Codex started"; body="Session started." ;;
        \\  UserPromptSubmit)
        \\    status="working"; title="Codex working"; body="Prompt submitted." ;;
        \\  PermissionRequest)
        \\    status="waiting"; title="Codex needs approval"; body="Review the pending approval in the terminal." ;;
        \\  Stop)
        \\    status="done"; title="Codex done"; body="Turn complete." ;;
        \\  *)
        \\    rm -f "$payload"; exit 0 ;;
        \\esac
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
        \\"$cli" notify --quiet --status "$status" --title "$title" --body "$body" >/dev/null 2>&1 || true
        \\rm -f "$payload"
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, .executable_file);
}

fn codexHooksJsonAlloc(allocator: std.mem.Allocator, hook_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();
    try writeCodexHookEvent(&s, "SessionStart", hook_path, "Syncing Verde session");
    try writeCodexHookEvent(&s, "UserPromptSubmit", hook_path, "Marking Verde agent busy");
    try writeCodexHookEvent(&s, "PermissionRequest", hook_path, "Marking Verde agent waiting");
    try writeCodexHookEvent(&s, "Stop", hook_path, "Marking Verde agent done");
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
const CLAUDE_HOOK_REL_PATH = ".verde/hooks/claude-notify-hook.sh";
// Claude Code merges hooks across settings files, so we target the personal,
// usually-gitignored settings.local.json to avoid touching shared settings.json.
const CLAUDE_SETTINGS_REL_PATH = ".claude/settings.local.json";

pub fn ensureClaudeProjectHooks(allocator: std.mem.Allocator, project_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const hook_path = try std.fs.path.join(allocator, &.{ project_path, CLAUDE_HOOK_REL_PATH });
    defer allocator.free(hook_path);
    const settings_path = try std.fs.path.join(allocator, &.{ project_path, CLAUDE_SETTINGS_REL_PATH });
    defer allocator.free(settings_path);

    const io = threaded.io();

    try ensureParentDir(io, hook_path);
    try writeClaudeHookScript(allocator, io, hook_path);

    if (std.Io.Dir.cwd().readFileAlloc(threaded.io(), settings_path, allocator, .limited(1024 * 1024))) |existing| {
        defer allocator.free(existing);
        if (claudeSettingsIsManaged(existing)) return;
        return error.ClaudeSettingsExist;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try ensureParentDir(io, settings_path);
    const settings_json = try claudeSettingsJsonAlloc(allocator, hook_path);
    defer allocator.free(settings_json);
    try writeFileAtomic(allocator, io, settings_path, settings_json, .default_file);
}

fn claudeSettingsIsManaged(content: []const u8) bool {
    return std.mem.indexOf(u8, content, CLAUDE_HOOK_MARKER) != null or
        std.mem.indexOf(u8, content, CLAUDE_HOOK_REL_PATH) != null;
}

fn writeClaudeHookScript(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    // Drives Verde surface status (working/waiting/done) for the pips. It does
    // not set a title, so the live OSC session summary remains the pane label.
    const script =
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
        \\status=""
        \\case "$event" in
        \\  SessionStart) status="working" ;;
        \\  UserPromptSubmit) status="working" ;;
        \\  Notification) status="waiting" ;;
        \\  Stop) status="done" ;;
        \\  *)
        \\    rm -f "$payload"; exit 0 ;;
        \\esac
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
        \\"$cli" notify --quiet --status "$status" >/dev/null 2>&1 || true
        \\rm -f "$payload"
        \\exit 0
        \\
    ;
    try writeFileAtomic(allocator, io, path, script, .executable_file);
}

fn claudeSettingsJsonAlloc(allocator: std.mem.Allocator, hook_path: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var s: std.json.Stringify = .{ .writer = &writer.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("hooks");
    try s.beginObject();
    try writeClaudeHookEvent(&s, "SessionStart", hook_path);
    try writeClaudeHookEvent(&s, "UserPromptSubmit", hook_path);
    try writeClaudeHookEvent(&s, "Notification", hook_path);
    try writeClaudeHookEvent(&s, "Stop", hook_path);
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
