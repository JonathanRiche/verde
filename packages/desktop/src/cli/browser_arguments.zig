//! Strict browser MCP addressing shared by stdio and daemon HTTP requests.
const std = @import("std");

pub fn fields(tool: []const u8) ?[]const []const u8 {
    const Entry = struct { name: []const u8, keys: []const []const u8 };
    const entries = [_]Entry{
        .{ .name = "browser_status", .keys = &.{} },
        .{ .name = "open_browser", .keys = &.{"url"} },
        .{ .name = "navigate_browser", .keys = &.{"url"} },
        .{ .name = "restart_browser", .keys = &.{} },
        .{ .name = "reset_browser", .keys = &.{} },
        .{ .name = "capture_browser_screenshot", .keys = &.{} },
        .{ .name = "evaluate_browser_js", .keys = &.{ "script", "timeout_ms" } },
        .{ .name = "inspect_browser_page", .keys = &.{ "max_elements", "text_limit" } },
        .{ .name = "click_browser_element", .keys = &.{ "selector", "ref", "role", "name", "label", "confirmed" } },
        .{ .name = "type_browser_text", .keys = &.{ "selector", "ref", "role", "name", "label", "confirmed", "text", "submit" } },
        .{ .name = "browser_pointer_input", .keys = &.{ "action", "x", "y", "button", "ctrl", "shift", "alt", "super" } },
    };
    for (entries) |entry| if (std.mem.eql(u8, tool, entry.name)) return entry.keys;
    return null;
}

/// Never fall back to desktop selection when an agent has no workspace context.
pub fn workspace(arguments: std.json.Value, allowed: []const []const u8, default: ?[]const u8) ![]const u8 {
    if (arguments != .object and arguments != .null) return error.InvalidBrowserArguments;
    var selected: ?[]const u8 = null;
    if (arguments == .object) {
        var it = arguments.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "workspace") or std.mem.eql(u8, key, "workspace_id") or std.mem.eql(u8, key, "project")) {
                const value = entry.value_ptr.*;
                if (value != .string or std.mem.trim(u8, value.string, &std.ascii.whitespace).len == 0) return error.InvalidBrowserWorkspace;
                if (selected) |previous| if (!std.mem.eql(u8, previous, value.string)) return error.ConflictingBrowserWorkspaces;
                selected = value.string;
            } else {
                var found = false;
                for (allowed) |field| if (std.mem.eql(u8, key, field)) {
                    found = true;
                    break;
                };
                if (!found) return error.UnknownBrowserArgument;
            }
        }
    }
    const result = selected orelse default orelse return error.BrowserWorkspaceRequired;
    if (std.mem.trim(u8, result, &std.ascii.whitespace).len == 0) return error.InvalidBrowserWorkspace;
    return result;
}

test "browser aliases select the requested workspace rather than a default" {
    inline for (.{ "workspace", "workspace_id", "project" }) |key| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"" ++ key ++ "\":\"kohl\"}", .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("kohl", try workspace(parsed.value, &.{}, "mirage"));
    }
    try std.testing.expectEqualStrings("agent", try workspace(.null, &.{}, "agent"));
    try std.testing.expectError(error.BrowserWorkspaceRequired, workspace(.null, &.{}, null));
}

test "browser invalid explicit addressing never falls back" {
    const Case = struct { input: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .input = "{\"workspace_id\":null}", .expected = error.InvalidBrowserWorkspace },
        .{ .input = "{\"workspace_id\":42}", .expected = error.InvalidBrowserWorkspace },
        .{ .input = "{\"workspace_id\":\" \"}", .expected = error.InvalidBrowserWorkspace },
        .{ .input = "{\"workspace\":\"a\",\"workspace_id\":\"b\"}", .expected = error.ConflictingBrowserWorkspaces },
        .{ .input = "{\"workpace\":\"a\"}", .expected = error.UnknownBrowserArgument },
        .{ .input = "{\"workspace\":\"a\",\"code\":\"return 1\"}", .expected = error.UnknownBrowserArgument },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.input, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, workspace(parsed.value, fields("evaluate_browser_js").?, "mirage"));
    }
}
