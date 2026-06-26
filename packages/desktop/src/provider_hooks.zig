const std = @import("std");

const CODEX_HOOK_MARKER = "verde-codex-notify-hook";
const CODEX_HOOK_REL_PATH = ".verde/hooks/codex-notify-hook.sh";
const CODEX_HOOKS_JSON_REL_PATH = ".codex/hooks.json";

// Global (all-projects) Codex hooks live in ~/.codex/hooks.json with the hook
// script at an absolute path, mirroring the global Claude integration. Codex
// merges global and project hooks, so we merge our entries in while preserving
// any hooks the user already runs (e.g. their own notify-stop.sh).
const CODEX_GLOBAL_HOOK_REL = ".codex/verde-codex-notify-hook.sh";
const CODEX_GLOBAL_HOOKS_JSON_REL = ".codex/hooks.json";
const CODEX_GLOBAL_HOOK_NEEDLE = "verde-codex-notify-hook";
const CodexHookEvent = struct { name: []const u8, status_message: []const u8 };
const CODEX_HOOK_EVENTS = [_]CodexHookEvent{
    .{ .name = "SessionStart", .status_message = "Syncing Verde session" },
    .{ .name = "UserPromptSubmit", .status_message = "Marking Verde agent busy" },
    .{ .name = "PermissionRequest", .status_message = "Marking Verde agent waiting" },
    .{ .name = "Stop", .status_message = "Marking Verde agent done" },
};

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
        \\title=""
        \\case "$event" in
        \\  SessionStart) status="working" ;;
        \\  UserPromptSubmit)
        \\    status="working"
        \\    # Codex has no session-title field, but UserPromptSubmit carries the
        \\    # prompt text. Derive a pane label from it (like a chat thread title):
        \\    # prefer jq for correct JSON decoding, else a best-effort sed fallback;
        \\    # collapse whitespace and truncate to a sidebar-friendly length.
        \\    if command -v jq >/dev/null 2>&1; then
        \\      title="$(jq -r '.prompt // empty' "$payload" 2>/dev/null)"
        \\    else
        \\      title="$(sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    fi
        \\    title="$(printf '%s' "$title" | tr '\n\t' '  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]][[:space:]]*/ /g' | cut -c1-72)"
        \\    ;;
        \\  PermissionRequest) status="waiting" ;;
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
        \\if [ -n "$title" ]; then
        \\  "$cli" notify --quiet --status "$status" --title "$title" --provider codex >/dev/null 2>&1 || true
        \\else
        \\  "$cli" notify --quiet --status "$status" --provider codex >/dev/null 2>&1 || true
        \\fi
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
        \\  SessionStart) status="idle" ;;
        \\  UserPromptSubmit) status="working" ;;
        \\  Notification)
        \\    # Claude fires Notification for both permission requests and the
        \\    # idle "waiting for your input" nudge. Only the former needs you.
        \\    msg="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$payload" | head -n 1)"
        \\    case "$msg" in
        \\      *"waiting for your input"*|*"is idle"*) rm -f "$payload"; exit 0 ;;
        \\      *) status="waiting" ;;
        \\    esac ;;
        \\  Stop) status="done" ;;
        \\  *)
        \\    rm -f "$payload"; exit 0 ;;
        \\esac
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
        \\"$cli" notify --quiet --status "$status" --provider claude >/dev/null 2>&1 || true
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

// Global (all-projects) Claude hooks live in ~/.claude/settings.json with the
// hook script at an absolute path so it resolves from any working directory.
const CLAUDE_GLOBAL_HOOK_REL = ".claude/verde-claude-notify-hook.sh";
const CLAUDE_GLOBAL_SETTINGS_REL = ".claude/settings.json";
const CLAUDE_GLOBAL_HOOK_NEEDLE = "verde-claude-notify-hook";
const CLAUDE_HOOK_EVENTS = [_][]const u8{ "SessionStart", "UserPromptSubmit", "Notification", "Stop" };

const AMP_GLOBAL_PLUGIN_REL = ".config/amp/plugins/verde-notify.ts";
const AMP_GLOBAL_PLUGIN_NEEDLE = "verde-amp-notify-plugin";

fn homeDir() ?[]const u8 {
    const ptr = std.c.getenv("HOME") orelse return null;
    return std.mem.span(ptr);
}

/// True when our managed hook is present in the global Claude settings.
pub fn claudeGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDir() orelse return false;
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
    const home = homeDir() orelse return error.NoHomeDir;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, CLAUDE_GLOBAL_HOOK_REL });
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

    const merged = try mergeClaudeHooks(allocator, existing, hook_path);
    defer if (merged) |m| allocator.free(m);
    if (merged) |m| {
        try ensureParentDir(io, settings_path);
        try writeFileAtomic(allocator, io, settings_path, m, .default_file);
    }
}

/// Removes our managed hook entries from the global Claude settings and deletes
/// the hook script. Idempotent.
pub fn removeClaudeGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDir() orelse return error.NoHomeDir;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, CLAUDE_GLOBAL_HOOK_REL });
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

    const updated = try removeClaudeHooksFromJson(allocator, existing, hook_path);
    defer if (updated) |u| allocator.free(u);
    if (updated) |u| try writeFileAtomic(allocator, io, settings_path, u, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
}

/// True when our managed hook is present in the global Codex hooks file.
pub fn codexGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDir() orelse return false;
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
    const home = homeDir() orelse return error.NoHomeDir;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, CODEX_GLOBAL_HOOK_REL });
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

    const merged = try mergeCodexHooks(allocator, existing, hook_path);
    defer if (merged) |m| allocator.free(m);
    if (merged) |m| {
        try ensureParentDir(io, hooks_path);
        try writeFileAtomic(allocator, io, hooks_path, m, .default_file);
    }
}

/// Removes our managed hook entries from the global Codex hooks file and deletes
/// the hook script, leaving any user-owned hooks intact. Idempotent.
pub fn removeCodexGlobalHooks(allocator: std.mem.Allocator) !void {
    const home = homeDir() orelse return error.NoHomeDir;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const hook_path = try std.fs.path.join(allocator, &.{ home, CODEX_GLOBAL_HOOK_REL });
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

    const updated = try removeCodexHooksFromJson(allocator, existing, hook_path);
    defer if (updated) |u| allocator.free(u);
    if (updated) |u| try writeFileAtomic(allocator, io, hooks_path, u, .default_file);
    std.Io.Dir.cwd().deleteFile(io, hook_path) catch {};
}

/// True when our managed Amp plugin is present in the global Amp plugin dir.
pub fn ampGlobalHooksInstalled(allocator: std.mem.Allocator) bool {
    const home = homeDir() orelse return false;
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
    const home = homeDir() orelse return error.NoHomeDir;
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
    const home = homeDir() orelse return error.NoHomeDir;
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
        \\import type { PluginAPI } from '@ampcode/plugin';
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
        \\async function notify(amp: PluginAPI, shell: PluginAPI['$'], status: 'idle' | 'working' | 'done' | 'waiting' | 'error'): Promise<void> {
        \\  if (!inVerdePane()) return;
        \\  const cli = verdeCli();
        \\  try {
        \\    await shell`${cli} notify --quiet --status ${status}`;
        \\  } catch (err) {
        \\    // Best-effort only: Amp should never fail because Verde is absent.
        \\    amp.logger.log(`Verde notify failed: ${err instanceof Error ? err.message : String(err)}`);
        \\  }
        \\}
        \\
        \\export default function (amp: PluginAPI) {
        \\  amp.logger.log('Verde notify plugin initialized');
        \\
        \\  amp.on('session.start', async (_event, ctx) => {
        \\    await notify(amp, ctx.$, 'idle');
        \\  });
        \\
        \\  amp.on('agent.start', async (_event, ctx) => {
        \\    await notify(amp, ctx.$, 'working');
        \\  });
        \\
        \\  amp.on('agent.end', async (event, ctx) => {
        \\    await notify(amp, ctx.$, event?.status === 'error' ? 'error' : 'done');
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
