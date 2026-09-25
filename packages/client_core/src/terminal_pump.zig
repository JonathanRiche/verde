//! Session-only PTY pump. Offsets commit after VT acknowledgement; writes never replay.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const vt = @import("terminal.zig");
const V = std.json.Value;
const eq = h.eq;
const A = std.mem.Allocator;
pub const View = struct {
    terminal_id: []const u8,
    workspace_id: []const u8 = "",
    label: []const u8 = "Terminal",
    session_status: []const u8 = "running",
    attached: bool = false,
    cols: u16 = 80,
    rows: u16 = 24,
    next_offset: ?[]const u8 = null,
    grid_revision: []const u8 = "0",
    stale: bool = true,
    @"error": ?h.LocalError = null,
};
const Action = struct { method: []const u8, params: V, intent_id: ?[]const u8, last: bool = true };
const Row = struct {
    slot: u8 = 0,
    view: View,
    offset: ?u64 = null,
    tail_id: ?u64 = null,
    action_id: ?u64 = null,
    actions: []const Action = &.{},
    output_id: ?[]const u8 = null,
    staged_offset: u64 = 0,
    delay: u32 = 1000,
    waiting: bool = false,
};
pub const State = struct { rows: []Row = &.{} };
fn append(comptime T: type, a: A, list: *[]const T, item: T) !void {
    const next = try a.alloc(T, list.len + 1);
    @memcpy(next[0..list.len], list.*);
    next[list.len] = item;
    list.* = next;
}
fn row(tx: *h.Transaction, id: []const u8) ?*Row {
    for (tx.state.terminal.rows) |*r| if (eq(r.view.terminal_id, id)) return r;
    return null;
}
fn add(tx: *h.Transaction, id: []const u8) !*Row {
    if (id.len == 0 or id.len > 256) return error.InvalidArgument;
    if (tx.state.terminal.rows.len >= 32) return error.ResourceLimit;
    const old = tx.state.terminal.rows;
    const next = try tx.allocator().alloc(Row, old.len + 1);
    @memcpy(next[0..old.len], old);
    next[old.len] = .{ .slot = @intCast(old.len), .view = .{ .terminal_id = id } };
    tx.state.terminal.rows = next;
    return &next[old.len];
}
fn operation(tx: *h.Transaction, id: ?[]const u8, state: []const u8, failure: ?h.LocalError) void {
    const wanted = id orelse return;
    for (@constCast(tx.state.receipts)) |*receipt| if (eq(receipt.operation.intent_id, wanted)) {
        receipt.operation.state = state;
        receipt.operation.@"error" = failure;
        if (receipt.operation.@"error") |*err| err.intent_id = wanted;
        tx.changed = true;
        return;
    };
}
fn rejected(code: []const u8) h.LocalError {
    return .{ .domain = "lifecycle", .code = code, .message = "Terminal operation could not complete." };
}
fn queue(tx: *h.Transaction, r: *Row, method: []const u8, params: anytype, id: ?[]const u8, last: bool) !void {
    if (r.actions.len >= 256) return error.ResourceLimit;
    var queued_bytes: usize = 0;
    for (tx.state.terminal.rows) |item| for (item.actions) |action| {
        queued_bytes += p.s(action.params, "text").len;
    };
    const value = try h.parse(tx.allocator(), try h.encode(tx.allocator(), params));
    if (queued_bytes + p.s(value, "text").len > h.MAX_INPUT) return error.ResourceLimit;
    if (eq(method, "session.resize") and r.actions.len > @as(usize, if (r.action_id != null) 1 else 0) and eq(r.actions[r.actions.len - 1].method, method)) {
        operation(tx, r.actions[r.actions.len - 1].intent_id, "failed", rejected("superseded"));
        r.actions = r.actions[0 .. r.actions.len - 1];
    }
    try append(Action, tx.allocator(), &r.actions, .{ .method = method, .params = value, .intent_id = id, .last = last });
    operation(tx, id, "pending", null);
}
fn ready(tx: *h.Transaction) bool {
    return tx.state.lifecycle == .foreground and tx.state.network_available and tx.state.rpc.phase == .ready;
}
pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) h.ApiError!bool {
    if (!std.mem.startsWith(u8, tag, "terminal_")) return false;
    const id = try h.string(event, "intent_id");
    if (eq(tag, "terminal_create")) {
        const cols: u16 = @intCast(try h.integer(event, "cols"));
        const rows: u16 = @intCast(try h.integer(event, "rows"));
        try vt.dimensions(cols, rows);
        if (!ready(tx)) {
            operation(tx, id, "failed", rejected("not_connected"));
            return true;
        }
        const workspace_id = try h.string(event, "workspace_id");
        var cwd = p.s(event, "cwd");
        if (cwd.len == 0) {
            for (p.rows(p.get(p.get(tx.state.sync.snapshot, "snapshot"), "workspaces"))) |workspace| {
                if (eq(p.s(workspace, "workspace_id"), workspace_id)) {
                    cwd = p.s(workspace, "path");
                    break;
                }
            }
        }
        if (cwd.len == 0) {
            operation(tx, id, "failed", rejected("workspace_path_unavailable"));
            return true;
        }
        const terminal_id = try std.fmt.allocPrint(tx.allocator(), "mobile:{s}:{d}", .{ tx.state.config.session_nonce, tx.state.next_id });
        const r = try add(tx, terminal_id);
        r.view.workspace_id = try h.string(event, "workspace_id");
        r.view.cols = cols;
        r.view.rows = rows;
        r.view.session_status = "starting";
        r.view.attached = true;
        try queue(tx, r, "session.create", .{ .id = terminal_id, .workspace_id = r.view.workspace_id, .cwd = cwd, .cols = cols, .rows = rows }, id, true);
        return true;
    }
    const terminal_id = try h.string(event, "terminal_id");
    const r = row(tx, terminal_id) orelse if (eq(tag, "terminal_attach")) try add(tx, terminal_id) else {
        operation(tx, id, "failed", rejected("not_found"));
        return true;
    };
    if (eq(tag, "terminal_attach") or eq(tag, "terminal_detach")) {
        try cancelTail(tx, r);
        r.view.attached = eq(tag, "terminal_attach");
        // Every attach may bind a recreated VT. It must start with a full replay.
        r.offset = null;
        r.view.next_offset = null;
        r.view.stale = true;
        operation(tx, id, "succeeded", null);
    } else if (!ready(tx)) {
        operation(tx, id, "failed", rejected("not_connected"));
    } else if (eq(tag, "terminal_resize")) {
        const cols: u16 = @intCast(try h.integer(event, "cols"));
        const rows: u16 = @intCast(try h.integer(event, "rows"));
        try vt.dimensions(cols, rows);
        try queue(tx, r, "session.resize", .{ .id = terminal_id, .cols = cols, .rows = rows }, id, true);
    } else if (eq(tag, "terminal_kill")) {
        try queue(tx, r, "session.kill", .{ .id = terminal_id }, id, true);
    } else if (eq(tag, "terminal_input")) {
        if (!r.view.attached) {
            operation(tx, id, "failed", rejected("not_attached"));
            return true;
        }
        const bytes = try encodeInput(tx.allocator(), event);
        var offset: usize = 0;
        while (offset < bytes.len) {
            var end = @min(offset + 4096, bytes.len);
            while (end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
            try queue(tx, r, "session.write", .{ .id = terminal_id, .text = bytes[offset..end] }, id, end == bytes.len);
            offset = end;
        }
        if (bytes.len == 0) operation(tx, id, "succeeded", null);
    }
    return true;
}
pub fn reply(tx: *h.Transaction, event: V) h.ApiError!void {
    const r = row(tx, try h.string(event, "terminal_id")) orelse return error.InvalidLifecycle;
    if (!ready(tx) or !r.view.attached) return error.InvalidLifecycle;
    const encoded = try h.string(event, "bytes_base64");
    const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidArgument;
    const bytes = try tx.allocator().alloc(u8, size);
    std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidArgument;
    if (bytes.len > 65536) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidArgument;
    try queue(tx, r, "session.write", .{ .id = r.view.terminal_id, .text = bytes }, null, true);
}
fn cancelCall(tx: *h.Transaction, id: ?u64) !void {
    const wanted = id orelse return;
    for (tx.state.rpc.calls, 0..) |call, index| if (call.id == wanted) {
        _ = try tx.emit("http_cancel", .{ .request_id = call.effect_id });
        for (tx.state.pending, 0..) |pending, i| if (eq(pending.id, call.effect_id)) {
            try tx.remove(i);
            break;
        };
        const next = try tx.allocator().alloc(rpc.Call, tx.state.rpc.calls.len - 1);
        @memcpy(next[0..index], tx.state.rpc.calls[0..index]);
        @memcpy(next[index..], tx.state.rpc.calls[index + 1 ..]);
        tx.state.rpc.calls = next;
        break;
    };
}
fn cancelTail(tx: *h.Transaction, r: *Row) !void {
    try cancelCall(tx, r.tail_id);
    r.tail_id = null;
    var i: usize = 0;
    while (i < tx.state.pending.len) {
        const pending = tx.state.pending[i];
        if ((pending.kind == .terminal and eq(pending.key, r.view.terminal_id)) or
            (pending.kind == .timer and eq(pending.purpose, try purpose(tx.allocator(), r))))
        {
            if (pending.kind == .timer) _ = try tx.emit("cancel_timer", .{ .timer_id = pending.id });
            try tx.remove(i);
        } else i += 1;
    }
    r.output_id = null;
    r.waiting = false;
}
pub fn invalidate(tx: *h.Transaction) void {
    for (tx.state.terminal.rows) |*r| {
        if (r.output_id != null) {
            r.offset = null;
            r.view.next_offset = null;
        }
        r.output_id = null;
        r.waiting = false;
        r.view.stale = true;
        // RPC invalidation produces results for in-flight calls. Unsent bytes
        // cannot survive background/reconnect and later execute unexpectedly.
        const keep: usize = if (r.action_id != null) 1 else 0;
        for (r.actions[keep..]) |action| operation(tx, action.intent_id, "failed", rejected("cancelled"));
        r.actions = r.actions[0..keep];
    }
}
fn purpose(a: A, r: *const Row) ![]const u8 {
    return std.fmt.allocPrint(a, "terminal_poll_{d}", .{r.slot});
}
fn wait(tx: *h.Transaction, r: *Row, ms: u32) !void {
    if (!ready(tx) or !r.view.attached) return;
    try tx.setTimer(try purpose(tx.allocator(), r), ms);
    r.waiting = true;
}
pub fn complete(tx: *h.Transaction, pending: h.Pending, event: V) h.ApiError!bool {
    if (pending.kind == .timer and std.mem.startsWith(u8, pending.purpose, "terminal_poll_")) {
        for (tx.state.terminal.rows) |*r| {
            if (eq(try purpose(tx.allocator(), r), pending.purpose)) {
                r.waiting = false;
                break;
            }
        }
        return true;
    }
    if (pending.kind != .terminal) return false;
    const r = row(tx, pending.key) orelse return true;
    if (!eq(try h.string(event, "terminal_id"), pending.key)) return error.InvalidArgument;
    if (r.output_id == null or !eq(r.output_id.?, pending.id)) return true;
    r.output_id = null;
    if (p.get(event, "error") != .null) {
        r.offset = null;
        r.view.next_offset = null;
        r.view.stale = true;
        r.view.@"error" = rejected("terminal_apply_failed");
        try wait(tx, r, 1000);
    } else {
        r.offset = r.staged_offset;
        r.view.next_offset = try std.fmt.allocPrint(tx.allocator(), "{d}", .{r.staged_offset});
        r.view.grid_revision = try h.string(event, "grid_revision");
        r.view.stale = false;
        r.view.@"error" = null;
        try wait(tx, r, r.delay);
    }
    tx.changed = true;
    return true;
}
pub fn pump(tx: *h.Transaction) h.ApiError!void {
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        var consumed = false;
        for (tx.state.terminal.rows) |*r| {
            if (r.tail_id == result.id) {
                r.tail_id = null;
                consumed = true;
                if (result.@"error") |err| {
                    r.view.@"error" = err;
                    r.view.stale = true;
                    if (err.retryable) try wait(tx, r, 1000) else r.view.attached = false;
                } else try tail(tx, r, result.value orelse .null);
            } else if (r.action_id == result.id) {
                r.action_id = null;
                consumed = true;
                const action = r.actions[0];
                r.actions = r.actions[1..];
                const value = result.value orelse .null;
                const failure = result.@"error" orelse if (eq(action.method, "session.create")) blk: {
                    const session = p.get(value, "session");
                    if (!eq(p.s(session, "id"), r.view.terminal_id) or p.get(session, "running") != .bool) break :blk rpc.failure(.protocol, "invalid_terminal_create", true);
                    break :blk @as(?h.LocalError, null);
                } else if (p.get(value, "accepted") != .bool or !p.yes(p.get(value, "accepted"))) rejected("not_accepted") else null;
                if (failure) |err| {
                    r.view.@"error" = err;
                    operation(tx, action.intent_id, if (err.delivery != null and eq(err.delivery.?, "uncertain")) "uncertain" else "failed", err);
                    // Abort every remaining chunk of the failed paste (and any
                    // queued input) rather than send a suffix after ambiguity.
                    for (r.actions) |queued| if (action.intent_id == null or queued.intent_id == null or !eq(action.intent_id.?, queued.intent_id.?)) {
                        operation(tx, queued.intent_id, "failed", rejected("cancelled"));
                    };
                    r.actions = &.{};
                    if (eq(action.method, "session.create")) {
                        r.view.attached = false;
                        r.view.session_status = "unknown";
                    }
                } else {
                    if (action.last) operation(tx, action.intent_id, "succeeded", null);
                    if (eq(action.method, "session.create")) r.view.session_status = "running";
                    if (eq(action.method, "session.resize")) {
                        r.view.cols = @intCast(p.uint(p.get(action.params, "cols")).?);
                        r.view.rows = @intCast(p.uint(p.get(action.params, "rows")).?);
                    }
                    if (eq(action.method, "session.kill")) {
                        r.view.attached = false;
                        r.view.session_status = "exited";
                        try cancelTail(tx, r);
                    }
                }
            }
            if (consumed) {
                tx.changed = true;
                break;
            }
        }
        if (!consumed and !(result.intent_id != null and eq(result.intent_id.?, "@terminal"))) try append(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
    }
    if (!ready(tx)) return;
    for (tx.state.terminal.rows) |*r| {
        if (r.action_id == null and r.actions.len > 0) {
            const action = r.actions[0];
            r.action_id = try rpc.request(tx, action.method, action.params, .{ .intent_id = "@terminal" });
        }
        if (!r.view.attached or r.tail_id != null or r.output_id != null or r.waiting or eq(r.view.session_status, "starting")) continue;
        var params = try h.parse(tx.allocator(), try h.encode(tx.allocator(), .{ .id = r.view.terminal_id, .max_bytes = @as(u32, 256 * 1024) }));
        if (r.offset) |offset| try params.object.put(tx.allocator(), "offset", .{ .number_string = try std.fmt.allocPrint(tx.allocator(), "{d}", .{offset}) });
        r.tail_id = try rpc.request(tx, "session.tail", params, .{ .mutation = false, .intent_id = "@terminal" });
    }
}
fn tail(tx: *h.Transaction, r: *Row, value: V) !void {
    if (p.get(value, "cols") != .null and p.get(value, "rows") != .null) {
        const cols = p.uint(p.get(value, "cols")) orelse 0;
        const rows = p.uint(p.get(value, "rows")) orelse 0;
        if (cols > 512 or rows > 512 or cols == 0 or rows == 0 or cols * rows > 65536) {
            r.view.attached = false;
            r.view.@"error" = rpc.failure(.protocol, "invalid_terminal_grid", false);
            return;
        }
        r.view.cols = @intCast(cols);
        r.view.rows = @intCast(rows);
    }
    const next = p.uint(p.get(value, "next_offset")) orelse {
        r.view.@"error" = rpc.failure(.protocol, "invalid_terminal_tail", false);
        r.view.attached = false;
        return;
    };
    const text = p.get(value, "text");
    if (text != .string or p.get(value, "running") != .bool) {
        r.view.attached = false;
        r.view.@"error" = rpc.failure(.protocol, "invalid_terminal_tail", false);
        return;
    }
    // Older daemons signal a ring gap through offset rather than truncated.
    const gap = if (r.offset) |offset| next < offset or (p.uint(p.get(value, "offset")) orelse offset) > offset else false;
    const reset = r.offset == null or gap or p.yes(p.get(value, "truncated"));
    const bytes = if (reset) alignPtyStream(text.string) else text.string;
    r.view.session_status = if (p.yes(p.get(value, "running"))) "running" else "exited";
    r.delay = if (text.string.len > 0) 160 else 1000;
    r.staged_offset = next;
    const id = try tx.emit("terminal_output", .{ .terminal_id = r.view.terminal_id, .reset = reset, .bytes_base64 = try rpc.encodeBase64(tx.allocator(), bytes), .next_offset = try std.fmt.allocPrint(tx.allocator(), "{d}", .{next}) });
    try tx.track(.terminal, id, r.view.terminal_id);
    r.output_id = id;
}
pub fn query(a: A, state: *const h.State, encoded: []const u8) h.ApiError!?V {
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        if (encoded[i] != '%') continue;
        if (i + 2 >= encoded.len or !std.ascii.isHex(encoded[i + 1]) or !std.ascii.isHex(encoded[i + 2])) return error.InvalidArgument;
        i += 2;
    }
    const id = std.Uri.percentDecodeInPlace(try a.dupe(u8, encoded));
    for (state.terminal.rows) |r| if (eq(r.view.terminal_id, id)) return try h.parse(a, try h.encode(a, r.view));
    return null;
}
pub fn alignPtyStream(bytes: []const u8) []const u8 {
    var start: usize = 0;
    for ([_][]const u8{ "\x1b[?1049h", "\x1b[2J", "\x1b[H", "\x1bc", "\x1b[?1049l" }) |marker| if (std.mem.lastIndexOf(u8, bytes, marker)) |index| {
        start = @max(start, index);
    };
    if (start == 0) {
        if (std.mem.indexOfScalar(u8, bytes, 27)) |esc| {
            if (esc > 0 and esc < 256) start = esc;
        }
        if (start == 0) if (std.mem.indexOfScalar(u8, bytes, '\n')) |nl| {
            if (nl < 256) start = nl + 1;
        };
    }
    if (bytes.len - start > 48 * 1024) {
        start = bytes.len - 48 * 1024;
        if (std.mem.indexOfScalarPos(u8, bytes, start, 27)) |esc| start = esc;
    }
    while (start < bytes.len and bytes[start] & 0xc0 == 0x80) start += 1;
    return bytes[start..];
}
pub fn encodeInput(a: A, event: V) h.ApiError![]const u8 {
    const input = try h.field(event, "input");
    const kind = try h.string(input, "kind");
    const modes = try h.field(event, "vt_modes");
    const text = p.s(input, "text");
    if (eq(kind, "paste")) return if (try h.boolean(modes, "bracketed_paste")) std.fmt.allocPrint(a, "\x1b[200~{s}\x1b[201~", .{text}) else text;
    if (eq(kind, "text")) return text;
    const key = try h.string(input, "key");
    const ctrl = try h.boolean(input, "ctrl");
    const alt = try h.boolean(input, "alt");
    const shift = try h.boolean(input, "shift");
    var bytes: []const u8 = key;
    const names = [_][]const u8{ "Escape", "Tab", "Enter", "Backspace", "Delete", "ArrowUp", "ArrowDown", "ArrowRight", "ArrowLeft", "Home", "End", "PageUp", "PageDown" };
    const codes = [_][]const u8{ "\x1b", "\t", "\r", "\x7f", "\x1b[3~", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\x1b[H", "\x1b[F", "\x1b[5~", "\x1b[6~" };
    var named = false;
    for (names, codes, 0..) |name, code, index| if (eq(key, name)) {
        named = true;
        bytes = code;
        if (index == 1 and shift) bytes = "\x1b[Z";
        if (index >= 5 and index <= 10 and !ctrl and !alt and !shift and try h.boolean(modes, "application_cursor")) bytes = try std.fmt.allocPrint(a, "\x1bO{c}", .{code[2]});
        const mod: u8 = 1 + @as(u8, if (shift) 1 else 0) + @as(u8, if (alt) 2 else 0) + @as(u8, if (ctrl) 4 else 0);
        if (mod > 1 and index >= 4) bytes = if (index == 4 or index >= 11) try std.fmt.allocPrint(a, "\x1b[{c};{d}~", .{ code[2], mod }) else try std.fmt.allocPrint(a, "\x1b[1;{d}{c}", .{ mod, code[2] });
        return if (alt and index < 4) try std.fmt.allocPrint(a, "\x1b{s}", .{bytes}) else bytes;
    };
    if (!named) {
        if (key.len != 1) return error.InvalidArgument;
        if (ctrl) {
            const c = std.ascii.toUpper(key[0]);
            bytes = try a.dupe(u8, &.{if (c == '?' or c == '8') 127 else if (c == ' ' or c == '2') 0 else if (c >= '@' and c <= '_') c & 31 else return error.InvalidArgument});
        }
    }
    return if (alt) std.fmt.allocPrint(a, "\x1b{s}", .{bytes}) else bytes;
}

/// Append terminal selectors to the host's single coalesced invalidation.
pub fn queryScopes(tx: *h.Transaction) h.ApiError!void {
    const effect = &tx.effects.items[tx.effects.items.len - 1];
    const scopes = effect.object.getPtr("scopes").?;
    for (tx.state.terminal.rows) |r| {
        var selector: std.ArrayList(u8) = .empty;
        try selector.appendSlice(tx.allocator(), "terminal:");
        for (r.view.terminal_id) |byte| {
            if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try selector.append(tx.allocator(), byte) else try selector.appendSlice(tx.allocator(), try std.fmt.allocPrint(tx.allocator(), "%{X:0>2}", .{byte}));
        }
        try scopes.array.append(.{ .string = selector.items });
    }
}
