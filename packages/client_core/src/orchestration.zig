//! Live linked chats for open conversations and browse rows. All I/O is emitted through RPC.
const std = @import("std");
const h = @import("host.zig");
const p = @import("projection.zig");
const rpc = @import("rpc.zig");
const m = @import("chat_models.zig");
const add = @import("chat_catalogs.zig").append;
const eq = h.eq;
pub const Parent = struct {
    workspace_id: []const u8,
    thread_id: []const u8,
    view: m.Orchestration = .{},
    request_id: ?u64 = null,
    refresh_at: i64 = 0,
};

pub fn view(state: *const h.State, ws: []const u8, id: []const u8) m.Orchestration {
    for (state.chat.orchestration) |parent| if (eq(parent.workspace_id, ws) and eq(parent.thread_id, id)) return parent.view;
    return .{};
}

/// Only view changes invalidate native projections; request bookkeeping stays private.
pub fn changed(before: *const h.State, after: *const h.State) bool {
    const equal = @import("state_clone.zig").equal;
    if (before.chat.orchestration.len != after.chat.orchestration.len) return true;
    for (before.chat.orchestration, after.chat.orchestration) |old, new| {
        if (!eq(old.workspace_id, new.workspace_id) or !eq(old.thread_id, new.thread_id) or !equal(m.Orchestration, old.view, new.view)) return true;
    }
    return false;
}

pub fn pump(tx: *h.Transaction) h.ApiError!void {
    const a = tx.allocator();
    if (tx.state.auth.credential == null) {
        tx.state.chat.orchestration = &.{};
        return;
    }
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (!eq(result.intent_id orelse "", "@agents")) {
            try add(rpc.Result, a, &tx.state.rpc.results, result);
            continue;
        }
        for (@constCast(tx.state.chat.orchestration)) |*parent| {
            if (parent.request_id == null or parent.request_id.? != result.id) continue;
            parent.request_id = null;
            parent.view.loading = false;
            parent.view.@"error" = result.@"error";
            if (result.@"error" == null) {
                if (p.get(result.value orelse .null, "links") == .array) {
                    parent.view = try project(a, result.value orelse .null, parent.workspace_id, tx.state.sync.catalog);
                } else parent.view.@"error" = .{ .domain = "orchestration", .code = "invalid_links", .message = "The host returned an unreadable agents list." };
            }
            const delay: i64 = if (parent.view.waiting_count > 0) 2500 else if (parent.view.links.len > 0) 6000 else 20000;
            parent.refresh_at = (tx.state.now_ms orelse 0) + delay;
            tx.changed = true;
        }
    }
    if (tx.state.lifecycle != .foreground or !tx.state.network_available or tx.state.rpc.phase != .ready) return;
    var allowed = false;
    for (tx.state.auth.credential.?.scopes) |s| allowed = allowed or eq(s, "chat:read");
    if (!allowed) return;
    // Focused threads are registered first, even before their catalog page arrives.
    for (tx.state.chat.threads) |t| if (t.focused) {
        try ensure(tx, t.workspace_id, t.id);
    };
    for (tx.state.sync.catalog) |row| {
        if (p.get(row, "open") == .bool and !p.yes(p.get(row, "open"))) continue;
        try ensure(tx, p.s(row, "workspace_id"), p.s(row, "local_thread_id"));
    }
    var in_flight: usize = 0;
    for (tx.state.chat.orchestration) |parent| if (parent.request_id != null) {
        in_flight += 1;
    };
    var next: ?i64 = null;
    const now = tx.state.now_ms orelse 0;
    for (@constCast(tx.state.chat.orchestration)) |*parent| {
        if (parent.request_id != null or !wanted(&tx.state, parent.workspace_id, parent.thread_id)) continue;
        if (parent.refresh_at <= now and in_flight < 4) {
            parent.request_id = try rpc.request(tx, "chat.links.list", .{ .workspace_id = parent.workspace_id, .parent_thread_id = parent.thread_id }, .{ .mutation = false, .intent_id = "@agents" });
            parent.view.loading = !parent.view.loaded;
            in_flight += 1;
        } else if (parent.refresh_at > now) {
            next = if (next) |old| @min(old, parent.refresh_at) else parent.refresh_at;
        }
    }
    if (next) |deadline| {
        var armed = false;
        for (tx.state.pending) |pending| if (pending.kind == .timer and eq(pending.purpose, "agents_refresh") and pending.deadline <= deadline) {
            armed = true;
        };
        if (!armed) try tx.setTimer("agents_refresh", @intCast(@min(20000, @max(1, deadline - now))));
    }
}

fn wanted(state: *const h.State, ws: []const u8, id: []const u8) bool {
    for (state.chat.threads) |t| if (t.focused and eq(t.workspace_id, ws) and eq(t.id, id)) return true;
    for (state.sync.catalog) |row| {
        if (p.get(row, "open") == .bool and !p.yes(p.get(row, "open"))) continue;
        if (eq(p.s(row, "workspace_id"), ws) and eq(p.s(row, "local_thread_id"), id)) return true;
    }
    return false;
}

fn ensure(tx: *h.Transaction, ws: []const u8, id: []const u8) h.ApiError!void {
    if (ws.len == 0 or id.len == 0) return;
    for (tx.state.chat.orchestration) |parent| if (eq(parent.workspace_id, ws) and eq(parent.thread_id, id)) return;
    // Bound work on hosts with very large histories; closed history is not polled.
    if (tx.state.chat.orchestration.len >= 256) return;
    try add(Parent, tx.allocator(), &tx.state.chat.orchestration, .{ .workspace_id = ws, .thread_id = id });
}

pub fn project(a: std.mem.Allocator, result: std.json.Value, ws: []const u8, catalog: []const std.json.Value) h.ApiError!m.Orchestration {
    var out: m.Orchestration = .{ .loaded = true };
    for (p.rows(p.get(result, "links"))) |row| {
        if (out.links.len >= 256) break;
        var link = std.json.parseFromValueLeaky(m.LinkedAgent, a, row, .{ .ignore_unknown_fields = true }) catch continue;
        if (link.hidden or link.local_thread_id.len == 0) continue;
        if (link.workspace_id.len == 0) link.workspace_id = ws;
        if (link.title.len == 0) link.title = "Untitled chat";
        for (catalog) |item| {
            if (eq(p.s(item, "workspace_id"), link.workspace_id) and eq(p.s(item, "local_thread_id"), link.local_thread_id)) link.model = p.s(item, "model_ref");
        }
        link.needs_you = eq(link.status, "waiting_approval") or eq(link.status, "blocked");
        link.status_label = label(link.status);
        if (eq(link.status, "running") or link.needs_you) out.waiting_count += 1;
        if (eq(link.status, "running")) out.working_count += 1;
        if (eq(link.status, "waiting_approval")) out.approval_count += 1;
        if (eq(link.status, "blocked")) out.input_count += 1;
        try add(m.LinkedAgent, a, &out.links, link);
    }
    std.mem.sort(m.LinkedAgent, @constCast(out.links), {}, newer);
    out.needs_you = out.approval_count + out.input_count > 0;
    if (out.waiting_count > 0) out.title = try std.fmt.allocPrint(a, "Waiting on {d} agent{s}", .{ out.waiting_count, if (out.waiting_count == 1) "" else "s" });
    var parts: std.ArrayList([]const u8) = .empty;
    if (out.working_count > 0) try parts.append(a, try std.fmt.allocPrint(a, "{d} working", .{out.working_count}));
    if (out.approval_count > 0) try parts.append(a, try std.fmt.allocPrint(a, "{d} needs approval", .{out.approval_count}));
    if (out.input_count > 0) try parts.append(a, try std.fmt.allocPrint(a, "{d} needs input", .{out.input_count}));
    out.summary = try std.mem.join(a, " · ", parts.items);
    return out;
}
fn newer(_: void, l: m.LinkedAgent, r: m.LinkedAgent) bool {
    if (l.updated_at_ms != r.updated_at_ms) return l.updated_at_ms > r.updated_at_ms;
    return std.mem.lessThan(u8, l.link_id, r.link_id);
}
fn label(status: []const u8) []const u8 {
    if (eq(status, "running")) return "Working";
    if (eq(status, "waiting_approval")) return "Needs approval";
    if (eq(status, "blocked")) return "Needs input";
    if (eq(status, "completed")) return "Done";
    if (eq(status, "failed")) return "Failed";
    if (eq(status, "aborted")) return "Stopped";
    if (eq(status, "interrupted")) return "Interrupted";
    if (eq(status, "idle")) return "Idle";
    return status;
}
