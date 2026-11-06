//! Structured tool-row bodies ("Tool:\n…\n\nInput:\n…\n\nOutput:\n…"), as written by
//! `transcript_apply` and read by the desktop tool row (chat_panel.zig TOOL_BODY_SECTIONS).
const std = @import("std");

/// Known section labels; a section ends at a blank line followed by the next label.
pub const SECTIONS = [_][]const u8{ "Tool:\n", "Input:\n", "Output:\n", "Error:\n", "Locations:\n", "Transcript:\n" };
/// Longest one-line summary, in bytes (cut on a UTF-8 boundary).
pub const MAX_SUMMARY = 240;

pub const Fields = struct { title: ?[]const u8 = null, summary: ?[]const u8 = null, input: ?[]const u8 = null, output: ?[]const u8 = null, @"error": ?[]const u8 = null };

/// Display fields for one tool row. `kind` is the stored tool kind tag; `author` the row
/// author (the tool's display name). Slices borrow `body`/`author` or live in `arena`.
pub fn parse(arena: std.mem.Allocator, kind: []const u8, author: []const u8, body: []const u8) std.mem.Allocator.Error!Fields {
    const tool = section(body, "Tool:\n");
    const input = section(body, "Input:\n");
    const fallback_title = nonEmpty(std.mem.trim(u8, author, " \t\r\n"));
    var title: ?[]const u8 = fallback_title;
    if (tool) |value| if (nonEmpty(try stripTicks(arena, firstLine(value)))) |named| {
        title = named;
    };
    var summary = try summarize(arena, kind, tool, input, section(body, "Locations:\n"));
    if (summary) |line| if (title) |named| {
        // "Edit `src/x.ts`" + "src/x.ts" reads as "Edit" + "src/x.ts"; a title that is only
        // the summary (a command as its own title) falls back to the author.
        if (std.mem.endsWith(u8, named, line)) {
            const rest = std.mem.trim(u8, named[0 .. named.len - line.len], " \t:");
            title = nonEmpty(rest) orelse if (fallback_title) |a| if (!std.mem.eql(u8, a, line)) a else null else null;
        }
    };
    if (title == null) title = fallback_title;
    if (summary != null and title != null and std.mem.eql(u8, summary.?, title.?)) summary = null;
    return .{ .title = title, .summary = summary, .input = input, .output = section(body, "Output:\n"), .@"error" = section(body, "Error:\n") };
}

/// Text of one "Label:\n<value>" section, trimmed; null when absent or empty.
pub fn section(body: []const u8, header: []const u8) ?[]const u8 {
    const start = blk: {
        if (std.mem.startsWith(u8, body, header)) break :blk header.len;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, body, search, "\n\n")) |gap| {
            if (std.mem.startsWith(u8, body[gap + 2 ..], header)) break :blk gap + 2 + header.len;
            search = gap + 1;
        }
        return null;
    };
    var end = body.len;
    var search = start;
    outer: while (std.mem.indexOfPos(u8, body, search, "\n\n")) |gap| {
        for (SECTIONS) |next| if (std.mem.startsWith(u8, body[gap + 2 ..], next)) {
            end = gap;
            break :outer;
        };
        search = gap + 1;
    }
    return nonEmpty(std.mem.trim(u8, body[start..end], " \t\r\n"));
}

/// Input keys that best name what each kind acts on, most telling first.
const COMMAND_KEYS = [_][]const u8{ "command", "cmd" };
const PATH_KEYS = [_][]const u8{ "path", "file_path", "filePath", "file", "notebook_path", "source", "destination" };
const SEARCH_KEYS = [_][]const u8{ "pattern", "query", "regex", "glob" };
const FETCH_KEYS = [_][]const u8{ "url", "uri", "query" };
const NAME_KEYS = [_][]const u8{ "tool", "tool_name", "name" };
/// Any kind: the desktop summary keys.
const GENERIC_KEYS = [_][]const u8{ "command", "cmd", "path", "file_path", "filePath", "file", "query", "pattern", "url", "title", "name", "description", "prompt", "message", "reason", "text" };

fn summarize(arena: std.mem.Allocator, kind: []const u8, tool: ?[]const u8, input: ?[]const u8, locations: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    const eq = std.mem.eql;
    const path_kind = eq(u8, kind, "read") or eq(u8, kind, "edit") or eq(u8, kind, "delete") or eq(u8, kind, "move");
    if (eq(u8, kind, "mcp")) if (tool) |value| if (nonEmpty(try stripTicks(arena, firstLine(value)))) |name| return clip(name);
    const raw = input orelse return if (path_kind) if (locations) |value| clip(firstLine(value)) else null else null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch {
        // Not JSON (a bare command or path): its first line is the argument.
        const line = firstLine(raw);
        if (line.len == 0 or line[0] == '{' or line[0] == '[') return null;
        return clip(line);
    };
    if (parsed == .string) return if (nonEmpty(firstLine(parsed.string))) |line| clip(line) else null;
    if (parsed != .object) return null;
    const object = parsed.object;
    const keys: []const []const u8 = if (eq(u8, kind, "execute")) &COMMAND_KEYS else if (path_kind) &PATH_KEYS else if (eq(u8, kind, "search")) &SEARCH_KEYS else if (eq(u8, kind, "fetch")) &FETCH_KEYS else if (eq(u8, kind, "mcp")) &NAME_KEYS else &.{};
    if (try pick(arena, object, keys)) |line| return line;
    if (path_kind) if (locations) |value| return clip(firstLine(value));
    return pick(arena, object, &GENERIC_KEYS);
}

fn pick(arena: std.mem.Allocator, object: std.json.ObjectMap, keys: []const []const u8) std.mem.Allocator.Error!?[]const u8 {
    for (keys) |key| {
        const field = object.get(key) orelse continue;
        switch (field) {
            .string => |text| if (nonEmpty(firstLine(text))) |line| return clip(line),
            // `["bash","-lc","bun test"]` is the script; other argv arrays read as their words.
            .array => |items| {
                if (items.items.len == 3 and items.items[1] == .string and items.items[2] == .string and
                    (std.mem.eql(u8, items.items[1].string, "-c") or std.mem.eql(u8, items.items[1].string, "-lc")))
                {
                    if (nonEmpty(firstLine(items.items[2].string))) |line| return clip(line);
                }
                var joined: std.ArrayList(u8) = .empty;
                for (items.items) |item| if (item == .string) {
                    if (joined.items.len > 0) try joined.append(arena, ' ');
                    try joined.appendSlice(arena, item.string);
                    if (joined.items.len > MAX_SUMMARY) break;
                };
                if (nonEmpty(firstLine(joined.items))) |line| return clip(line);
            },
            else => {},
        }
    }
    return null;
}

/// First non-blank line, trimmed.
fn firstLine(text: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return "";
}

fn stripTicks(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '`') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| if (byte != '`') try out.append(arena, byte);
    return std.mem.trim(u8, out.items, " \t");
}

fn clip(text: []const u8) []const u8 {
    if (text.len <= MAX_SUMMARY) return text;
    var end: usize = MAX_SUMMARY;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.mem.trimEnd(u8, text[0..end], " \t");
}

fn nonEmpty(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}
