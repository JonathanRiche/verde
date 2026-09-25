//! Detached workspace projection, ported from web store.ts. No desktop mirrors.
const std = @import("std");
const host = @import("host.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
const eq = host.eq;
pub const Pane = struct {
    id: []const u8,
    workspace_id: []const u8,
    kind: []const u8,
    title: []const u8,
    thread_id: ?[]const u8 = null,
    terminal_id: ?[]const u8 = null,
    status: []const u8 = "idle",
    attention: bool = false,
    started_at_ms: ?i64 = null,
    can_stop: bool = false,
};
pub const ThreadSummary = struct {
    workspace_id: []const u8,
    thread_id: []const u8,
    title: []const u8,
    provider: []const u8,
    model: ?[]const u8,
    cwd: ?[]const u8,
    open: bool,
    archived: bool,
    last_activity_at_ms: ?i64,
    status: []const u8,
    history_bucket: []const u8,
};
pub const Workspace = struct {
    workspace_id: []const u8,
    label: []const u8,
    path: []const u8,
    open: bool,
    panes: []const Pane,
    threads: []const ThreadSummary,
};
pub const Models = struct {
    workspaces: []const Workspace,
    active: []const Pane,
    history: []const ThreadSummary,
};
pub fn get(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn s(v: V, key: []const u8) []const u8 {
    return str(get(v, key));
}
pub fn rows(v: V) []const V {
    return if (v == .array) v.array.items else &.{};
}
pub fn num(v: V) ?i64 {
    return if (v == .integer) v.integer else null;
}
pub fn uint(v: V) ?u64 {
    return switch (v) {
        .integer => if (v.integer >= 0) @intCast(v.integer) else null,
        .number_string => std.fmt.parseInt(u64, v.number_string, 10) catch null,
        else => null,
    };
}
pub fn yes(v: V) bool {
    return v == .bool and v.bool;
}
fn nullable(v: V) ?[]const u8 {
    return if (v == .string) v.string else null;
}
fn fallback(v: []const u8, other: []const u8) []const u8 {
    return if (v.len != 0) v else other;
}
fn active(status: []const u8) bool {
    for ([_][]const u8{ "working", "waiting", "accepted", "running", "waiting_approval" }) |item| {
        if (eq(status, item)) return true;
    }
    return false;
}
fn turnFor(turns: V, ws: []const u8, id: []const u8) V {
    var result: V = .null;
    for (rows(turns)) |turn| {
        if (eq(s(turn, "workspace_id"), ws) and eq(s(turn, "local_thread_id"), id) and (result == .null or (num(get(turn, "started_at_ms")) orelse 0) > (num(get(result, "started_at_ms")) orelse 0))) result = turn;
    }
    return result;
}
fn summary(ws: []const u8, t: V, turns: V, now: i64) ThreadSummary {
    const sec = num(get(t, "last_activity_at"));
    const ms = if (sec) |n| std.math.mul(i64, n, 1000) catch null else null;
    const age = @as(i128, now) - @as(i128, ms orelse 0);
    return .{ .workspace_id = ws, .thread_id = s(t, "local_thread_id"), .title = fallback(s(t, "title"), "Chat"), .provider = fallback(s(t, "provider"), "opencode"), .model = nullable(get(t, "model_ref")), .cwd = nullable(get(t, "cwd")), .open = !eqFalse(get(t, "open")), .archived = yes(get(t, "archived")), .last_activity_at_ms = ms, .status = fallback(s(turnFor(turns, ws, s(t, "local_thread_id")), "status"), "idle"), .history_bucket = if (age < 86_400_000) "Today" else if (age < 604_800_000) "This week" else "Older" };
}
fn eqFalse(v: V) bool {
    return v == .bool and !v.bool;
}
pub fn parseWorkspaceLayout(a: A, json: V) host.ApiError!V {
    if (json != .string or json.string.len == 0) return .null;
    const value = host.parse(a, json.string) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .null;
    };
    return if (get(value, "panes") == .array) value else .null;
}
/// Preserve omitted controls, including explicit nulls, from snapshot then previous catalog.
pub fn mergeThreadCatalogSettings(a: A, listed: V, snapshot: V, previous: V) host.ApiError!V {
    var out = listed;
    if (out != .object) return error.InvalidArgument;
    inline for (.{ "reasoning_effort", "reasoning_variant", "fast_mode", "access_mode" }) |key| {
        if (!out.object.contains(key)) {
            const source = if (snapshot != .null) snapshot else previous;
            if (source == .object) {
                if (source.object.get(key)) |value| try out.object.put(a, key, value);
            }
        }
    }
    return out;
}
fn chat(a: A, ws: []const u8, t: V, turns: V) !Pane {
    const id = s(t, "local_thread_id");
    const turn = turnFor(turns, ws, id);
    const status = fallback(s(turn, "status"), "idle");
    return .{ .id = try std.fmt.allocPrint(a, "{s}:chat:{s}", .{ ws, id }), .workspace_id = ws, .kind = "chat", .title = fallback(s(t, "title"), "Chat"), .thread_id = id, .status = status, .attention = eq(status, "waiting_approval"), .started_at_ms = num(get(turn, "started_at_ms")), .can_stop = active(status) };
}
fn sessionMatches(session: V, ws: V) bool {
    const path = if (get(session, "workspace_path") != .null) s(session, "workspace_path") else s(session, "cwd");
    if (std.mem.startsWith(u8, path, "/")) {
        var buffer: [16]u8 = undefined;
        const hashed = std.fmt.bufPrint(&buffer, "{x}", .{std.hash.Wyhash.hash(0, path)}) catch unreachable;
        if (eq(hashed, s(ws, "workspace_id"))) return true;
    } else if (eq(s(session, "workspace_id"), s(ws, "workspace_id"))) return true;
    return path.len > 0 and eq(path, s(ws, "path"));
}
fn sessionId(session: V) []const u8 {
    return fallback(s(session, "session_id"), s(session, "id"));
}
fn sessionTitle(session: V) []const u8 {
    const label = std.mem.trim(u8, s(session, "label"), " \t\r\n");
    const command = std.mem.trim(u8, s(session, "command"), " \t\r\n");
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const binary = std.fs.path.basename(words.next() orelse "");
    if (label.len != 0 and !eq(label, "Shell") and !eq(label, "Terminal")) return label;
    if (binary.len != 0 and !eq(binary, "fish") and !eq(binary, "bash") and !eq(binary, "zsh") and !eq(binary, "sh")) return binary;
    return fallback(label, fallback(binary, "Terminal"));
}
fn terminal(a: A, ws: []const u8, session: V) !Pane {
    const working = eq(s(session, "status"), "working");
    return .{ .id = try std.fmt.allocPrint(a, "{s}:term:{s}", .{ ws, sessionId(session) }), .workspace_id = ws, .kind = "terminal", .title = sessionTitle(session), .terminal_id = sessionId(session), .status = if (working) "working" else if (yes(get(session, "running"))) "idle" else "exited", .attention = working };
}
fn hasThread(panes: []const Pane, id: []const u8) bool {
    for (panes) |p| {
        if (p.thread_id) |t| {
            if (eq(t, id)) return true;
        }
    }
    return false;
}
fn hasSession(panes: []const Pane, id: []const u8) bool {
    for (panes) |p| {
        if (p.terminal_id) |t| {
            if (eq(t, id)) return true;
        }
    }
    return false;
}
fn subagent(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "subagent:");
}
fn recent(_: void, l: V, r: V) bool {
    const x = num(get(l, "last_activity_at")) orelse 0;
    const y = num(get(r, "last_activity_at")) orelse 0;
    return if (x == y) std.mem.lessThan(u8, s(l, "local_thread_id"), s(r, "local_thread_id")) else x > y;
}
pub fn panesForWorkspace(a: A, ws: V, threads: []const V, sessions: V, turns: V) host.ApiError![]const Pane {
    const wid = s(ws, "workspace_id");
    var panes: std.ArrayList(Pane) = .empty;
    const layout = try parseWorkspaceLayout(a, get(ws, "workspace_layout_json"));
    if (layout != .null) {
        for (rows(get(layout, "panes")), 0..) |p, index| {
            const kind = s(p, "kind");
            if (eq(kind, "chat") and num(get(p, "thread")) != null) {
                var found: V = .null;
                // Persisted layout binding: identity, provider identity, title+ordinal, title, ordinal.
                for (0..5) |pass| {
                    for (threads) |t| {
                        const match = switch (pass) {
                            0 => s(p, "local_thread_id").len > 0 and eq(s(p, "local_thread_id"), s(t, "local_thread_id")),
                            1 => s(p, "provider_thread_id").len > 0 and eq(s(p, "provider_thread_id"), s(t, "provider_thread_id")),
                            2 => s(p, "title").len > 0 and eq(s(p, "title"), s(t, "title")) and num(get(p, "thread")) == num(get(t, "sort_index")),
                            3 => s(p, "title").len > 0 and eq(s(p, "title"), s(t, "title")),
                            else => s(p, "title").len == 0 and num(get(p, "thread")) == num(get(t, "sort_index")),
                        };
                        if (match) {
                            found = t;
                            break;
                        }
                    }
                    if (found != .null) break;
                }
                if (found != .null and (!yes(get(found, "archived")) or s(p, "title").len > 0)) {
                    if (!hasThread(panes.items, s(found, "local_thread_id"))) {
                        var projected = try chat(a, wid, found, turns);
                        const title = s(p, "title");
                        const placeholder = eq(title, "New Chat") or eq(title, "New chat") or eq(title, "New thread");
                        if (title.len > 0 and !placeholder) projected.title = title;
                        try panes.append(a, projected);
                    }
                } else if (s(p, "title").len > 0) try panes.append(a, .{ .id = try std.fmt.allocPrint(a, "{s}:chat:placeholder:{d}", .{ wid, num(get(p, "id")) orelse @as(i64, @intCast(index)) }), .workspace_id = wid, .kind = "chat", .title = s(p, "title") });
            } else if (eq(kind, "terminal") and num(get(p, "dock")) != null) {
                var found: V = .null;
                for (rows(sessions)) |session| {
                    if (sessionMatches(session, ws) and num(get(session, "dock_id")) == num(get(p, "dock")) and sessionId(session).len > 0) {
                        found = session;
                        break;
                    }
                }
                if (found != .null) {
                    if (!hasSession(panes.items, sessionId(found))) try panes.append(a, try terminal(a, wid, found));
                } else try panes.append(a, .{ .id = try std.fmt.allocPrint(a, "{s}:dock:{d}", .{ wid, num(get(p, "dock")).? }), .workspace_id = wid, .kind = "terminal", .title = fallback(s(p, "title"), fallback(s(p, "purpose"), "Terminal")), .status = "unavailable" });
            } else if (eq(kind, "browser")) try panes.append(a, .{ .id = try std.fmt.allocPrint(a, "{s}:browser:{d}", .{ wid, num(get(p, "id")) orelse @as(i64, @intCast(index)) }), .workspace_id = wid, .kind = "browser", .title = "Browser", .status = "unavailable" });
        }
        for (threads) |t| {
            const id = s(t, "local_thread_id");
            if (!yes(get(t, "archived")) and !subagent(id) and !hasThread(panes.items, id) and std.mem.startsWith(u8, id, "web-thread-") and !eqFalse(get(t, "open")) and !eqFalse(get(t, "committed"))) try panes.append(a, try chat(a, wid, t, turns));
        }
    } else {
        const sorted = try a.dupe(V, threads);
        std.mem.sort(V, sorted, {}, recent);
        var count: usize = 0;
        for (sorted) |t| {
            if (yes(get(t, "archived")) or subagent(s(t, "local_thread_id"))) continue;
            if (count == 16) break;
            try panes.append(a, try chat(a, wid, t, turns));
            count += 1;
        }
    }
    for (rows(sessions)) |session| {
        if (sessionMatches(session, ws) and sessionId(session).len > 0 and !hasSession(panes.items, sessionId(session)) and (yes(get(session, "running")) or eq(s(session, "status"), "working"))) try panes.append(a, try terminal(a, wid, session));
    }
    return panes.toOwnedSlice(a);
}
fn attentionOrder(_: void, l: Pane, r: Pane) bool {
    if (l.attention != r.attention) return l.attention;
    return std.mem.lessThan(u8, l.id, r.id);
}
fn historyOrder(_: void, l: ThreadSummary, r: ThreadSummary) bool {
    const x = l.last_activity_at_ms orelse 0;
    const y = r.last_activity_at_ms orelse 0;
    if (x != y) return x > y;
    const order = std.mem.order(u8, l.workspace_id, r.workspace_id);
    return if (order == .eq) std.mem.lessThan(u8, l.thread_id, r.thread_id) else order == .lt;
}
pub fn project(a: A, snapshot: V, catalog: []const V, has_catalog: bool, now: i64) host.ApiError!Models {
    var workspaces: std.ArrayList(Workspace) = .empty;
    var home: std.ArrayList(Pane) = .empty;
    var history: std.ArrayList(ThreadSummary) = .empty;
    const turns = get(snapshot, "turns");
    for (rows(get(get(snapshot, "snapshot"), "workspaces"))) |ws| {
        const wid = s(ws, "workspace_id");
        var threads: std.ArrayList(V) = .empty;
        if (has_catalog) {
            for (catalog) |t| {
                if (eq(s(t, "workspace_id"), wid)) try threads.append(a, t);
            }
        } else {
            for (rows(get(ws, "threads")), 0..) |t, i| {
                var copy = try host.parse(a, try std.json.Stringify.valueAlloc(a, t, .{}));
                if (copy == .object and !copy.object.contains("sort_index")) try copy.object.put(a, "sort_index", .{ .integer = @intCast(i) });
                try threads.append(a, copy);
            }
        }
        var summaries: std.ArrayList(ThreadSummary) = .empty;
        for (threads.items) |t| {
            const item = summary(wid, t, turns, now);
            try summaries.append(a, item);
            try history.append(a, item);
        }
        const panes = try panesForWorkspace(a, ws, threads.items, get(snapshot, "sessions"), turns);
        if (!yes(get(ws, "archived"))) {
            for (panes) |p| {
                if (p.attention or p.can_stop or eq(p.status, "working")) try home.append(a, p);
            }
        }
        try workspaces.append(a, .{ .workspace_id = wid, .label = fallback(s(ws, "label"), wid), .path = s(ws, "path"), .open = !yes(get(ws, "archived")), .panes = panes, .threads = try summaries.toOwnedSlice(a) });
    }
    std.mem.sort(Pane, home.items, {}, attentionOrder);
    std.mem.sort(ThreadSummary, history.items, {}, historyOrder);
    return .{ .workspaces = try workspaces.toOwnedSlice(a), .active = try home.toOwnedSlice(a), .history = try history.toOwnedSlice(a) };
}
