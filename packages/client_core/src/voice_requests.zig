//! Draft-independent voice requests. Acceptance and replies are tied to a
//! stable turn identity, never to whichever message last appeared in a chat.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const add = @import("chat_catalogs.zig").append;
const eq = h.eq;
const E = h.ApiError;
const V = std.json.Value;
const PREFIX = "@voice_request";
pub const RequestView = struct {
    intent_id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    status: []const u8,
    reply: []const u8,
    error_code: ?[]const u8 = null,
};
pub const Request = struct {
    intent_id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    status: []const u8 = "sending",
    reply: []const u8 = "",
    error_code: ?[]const u8 = null,
    rpc_id: ?u64 = null,
    phase: enum { settings, start, tail, cancel, done } = .settings,
    after_seq: u64 = 0,
    retry_at: i64 = 0,
    deadline: i64 = 0,
};
pub const Submit = struct { workspace_id: []const u8, thread_id: []const u8, prompt: []const u8 };
pub const Cancel = struct { turn_id: []const u8 };
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    const a = tx.allocator();
    const id = try h.string(event, "intent_id");
    const stopping = eq(tag, "voice_request_cancel");
    const r = if (stopping) Submit{ .workspace_id = "", .thread_id = "", .prompt = "" } else try h.decode(Submit, a, event);
    if (!stopping and (r.workspace_id.len == 0 or r.thread_id.len == 0 or std.mem.trim(u8, r.prompt, &std.ascii.whitespace).len == 0 or r.prompt.len > 32768)) return error.InvalidArgument;
    const list = &tx.state.voice.requests;
    const capacity: usize = if (stopping) 32 else 16;
    if (list.len >= capacity) {
        var kept: []const Request = &.{};
        for (list.*) |item| if (item.phase != .done) {
            try add(Request, a, &kept, item);
        };
        list.* = kept;
    }
    if (list.len >= capacity) {
        receipt(tx, id, "failed", "busy");
        return;
    }
    const turn_id = if (stopping) (try h.decode(Cancel, a, event)).turn_id else try std.fmt.allocPrint(a, "voice:{s}:{s}", .{ tx.state.config.session_nonce, id });
    if (turn_id.len == 0) return error.InvalidArgument;
    if (stopping) for (@constCast(list.*)) |*prior| {
        if (!eq(prior.turn_id, turn_id) or prior.phase != .settings) continue;
        prior.phase = .done;
        prior.rpc_id = null;
        prior.status = "aborted";
        receipt(tx, prior.intent_id, "failed", "cancelled_before_send");
        receipt(tx, id, "succeeded", null);
        return;
    };
    try add(Request, a, list, .{ .intent_id = id, .workspace_id = r.workspace_id, .thread_id = r.thread_id, .turn_id = turn_id, .prompt = r.prompt, .deadline = (tx.state.now_ms orelse 0) + 30 * 60 * 1000, .phase = if (stopping) .cancel else .settings });
    const item = &@constCast(list.*)[list.len - 1];
    if (stopping) for (list.*) |prior| {
        if (eq(prior.turn_id, turn_id) and prior.phase == .start) {
            receipt(tx, id, "pending", null);
            return;
        }
    };
    item.rpc_id = if (stopping) try rpc.request(tx, "chat.turn.cancel", .{ .turn_id = turn_id }, .{ .intent_id = PREFIX }) else try rpc.request(tx, "chat.thread.get", .{ .workspace_id = r.workspace_id, .local_thread_id = r.thread_id, .message_limit = @as(u32, 0) }, .{ .mutation = false, .intent_id = PREFIX });
    receipt(tx, id, "pending", null);
}
fn tail(tx: *h.Transaction, item: *Request) E!void {
    item.phase = .tail;
    item.rpc_id = try rpc.request(tx, "chat.turn.tail", .{ .turn_id = item.turn_id, .after_seq = item.after_seq, .wait_ms = @min(@as(u32, 25000), tx.state.rpc.limits.max_parked_wait_ms), .max_bytes = tx.state.rpc.limits.max_response_bytes }, .{ .mutation = false, .intent_id = PREFIX, .parked_wait_ms = @min(@as(u32, 25000), tx.state.rpc.limits.max_parked_wait_ms), .timeout_ms = 30000 });
}
pub fn pump(tx: *h.Transaction) E!void {
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (!eq(result.intent_id orelse "", PREFIX)) {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        }
        for (@constCast(tx.state.voice.requests)) |*item| {
            if (item.rpc_id == null or item.rpc_id.? != result.id) continue;
            item.rpc_id = null;
            tx.changed = true;
            if (result.@"error") |err| {
                const code = err.rpc_code orelse err.code;
                if (item.phase == .tail and (err.retryable or eq(code, "not_found") or eq(code, "resource_not_found"))) {
                    item.retry_at = (tx.state.now_ms orelse 0) + 1000;
                    try tx.setTimer("voice_request_retry", 1000);
                } else {
                    item.error_code = code;
                    item.status = if (eq(err.delivery orelse "", "uncertain")) "uncertain" else "failed";
                    const was_tail = item.phase == .tail;
                    item.phase = .done;
                    if (!was_tail) receipt(tx, item.intent_id, item.status, code);
                }
                break;
            }
            const value = result.value orelse .null;
            switch (item.phase) {
                .settings => {
                    const t = p.get(value, "thread");
                    if (p.s(t, "provider").len == 0 or p.yes(p.get(t, "archived"))) {
                        item.status = "failed";
                        item.error_code = "thread_unavailable";
                        item.phase = .done;
                        receipt(tx, item.intent_id, "failed", "thread_unavailable");
                        break;
                    }
                    item.phase = .start;
                    item.rpc_id = try rpc.request(tx, "chat.turn.start", .{
                        .turn_id = item.turn_id,
                        .workspace_id = item.workspace_id,
                        .local_thread_id = item.thread_id,
                        .prompt = item.prompt,
                        .task_owner = "voice",
                        .orchestration_note = @import("chat.zig").VOICE_NOTE,
                        .provider = p.s(t, "provider"),
                        .harness = p.s(t, "harness"),
                        .thread_title = p.s(t, "title"),
                        .model_ref = p.get(t, "model_ref"),
                        .provider_thread_id = p.get(t, "provider_thread_id"),
                        .reasoning_effort = p.get(t, "reasoning_effort"),
                        .opencode_reasoning_variant = p.get(t, "reasoning_variant"),
                        .access_mode = p.get(t, "access_mode"),
                        .fast_mode = eq(p.s(t, "fast_mode"), "on"),
                        .repository_id = if (p.s(t, "repository_id").len > 0) p.s(t, "repository_id") else "primary",
                        .relative_cwd = p.get(t, "repository_cwd"),
                    }, .{ .intent_id = PREFIX });
                },
                .start => {
                    if (!eq(p.s(value, "turn_id"), item.turn_id)) {
                        item.status = "uncertain";
                        item.error_code = "invalid_response";
                        item.phase = .done;
                        receipt(tx, item.intent_id, "uncertain", "invalid_response");
                        break;
                    }
                    item.status = if (p.yes(p.get(value, "queued"))) "queued" else "running";
                    receipt(tx, item.intent_id, "succeeded", null);
                    try tail(tx, item);
                },
                .tail => {
                    const status = p.s(value, "status");
                    item.status = status;
                    for (p.rows(p.get(value, "events"))) |e| item.after_seq = @max(item.after_seq, p.uint(p.get(e, "seq")) orelse 0);
                    if (p.yes(p.get(value, "has_more_events"))) {
                        try tail(tx, item);
                        break;
                    }
                    if (eq(status, "completed") or eq(status, "failed") or eq(status, "aborted") or eq(status, "interrupted")) {
                        item.reply = p.s(value, "result_reply_text");
                        item.error_code = if (eq(status, "completed")) null else status;
                        item.phase = .done;
                    } else {
                        item.retry_at = (tx.state.now_ms orelse 0) + 200;
                        try tx.setTimer("voice_request_retry", 200);
                    }
                },
                .cancel => {
                    const accepted = p.yes(p.get(value, "accepted"));
                    item.status = if (accepted) "stopped" else "uncertain";
                    item.phase = .done;
                    receipt(tx, item.intent_id, if (accepted) "succeeded" else "uncertain", if (accepted) null else "invalid_response");
                },
                .done => {},
            }
            break;
        }
    }
    // A start acknowledgement may unblock a stop in this same transaction.
    try observe(tx);
}
pub fn observe(tx: *h.Transaction) E!void {
    if (tx.state.rpc.phase != .ready or !tx.state.network_available or tx.state.lifecycle != .foreground) return;
    for (@constCast(tx.state.voice.requests)) |*item| {
        if (item.phase != .done and item.deadline <= (tx.state.now_ms orelse 0)) {
            const was_tail = item.phase == .tail;
            item.status = "uncertain";
            item.error_code = "timeout";
            item.phase = .done;
            item.rpc_id = null;
            if (!was_tail) receipt(tx, item.intent_id, "uncertain", "timeout");
            tx.changed = true;
        }
        if (item.phase == .tail and item.rpc_id == null and item.retry_at <= (tx.state.now_ms orelse 0)) try tail(tx, item);
        if (item.phase == .cancel and item.rpc_id == null) {
            var starting = false;
            for (tx.state.voice.requests) |prior| if (eq(prior.turn_id, item.turn_id) and prior.phase == .start) {
                starting = true;
            };
            if (!starting) item.rpc_id = try rpc.request(tx, "chat.turn.cancel", .{ .turn_id = item.turn_id }, .{ .intent_id = PREFIX });
        }
    }
}
fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, code: ?[]const u8) void {
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = if (code) |c| .{ .domain = "voice", .code = c, .message = "The voice request could not be delivered." } else null;
    };
    tx.changed = true;
}
