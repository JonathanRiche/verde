//! Image bytes for transcript attachments (`chat.attachment.read`). A fetch
//! reads the image in chunks until `total_bytes` and exposes it in the
//! `attachments` view. Bytes never enter the cloned engine state: they
//! accumulate in the host's blob store (`Host.blobs`), applied only when a
//! transaction commits, so every event doesn't copy megabytes. Never logged.
const std = @import("std");
const h = @import("host.zig");
const rpc = @import("rpc.zig");
const p = @import("projection.zig");
const clone = @import("state_clone.zig");
const add = @import("chat_catalogs.zig").append;
const A = std.mem.Allocator;
const V = std.json.Value;
const E = h.ApiError;
const eq = h.eq;

pub const MAX_IMAGE_BYTES: u64 = 16 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: u64 = 512 * 1024;
/// Ready blobs kept in memory; older ones are dropped (apps cache to disk, then release).
pub const MAX_READY = 4;
/// Requests in flight at once; further fetches wait.
pub const MAX_ACTIVE = 4;
pub const MAX_ENTRIES = 64;
const MAX_REF_BYTES = 256;

/// One attachment's fetch, keyed `<workspace_id>|<thread_id>|<message_id>|<index>`.
pub const Item = struct {
    key: []const u8,
    /// `loading`, `ready`, `failed` or `unavailable` (no longer on the host).
    status: []const u8 = "loading",
    mime: []const u8 = "",
    total_bytes: u64 = 0,
    /// Base64 bytes; only in the view, only when `ready`.
    data_base64: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
};
pub const View = struct { items: []const Item = &.{} };

const Entry = struct {
    key: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    message_id: []const u8,
    index: u32,
    status: []const u8 = "loading",
    mime: []const u8 = "",
    total_bytes: u64 = 0,
    received: u64 = 0,
    error_code: ?[]const u8 = null,
    rpc_id: ?u64 = null,
    intents: []const []const u8 = &.{},
    /// Order in which entries became ready, for the in-memory LRU.
    ready_at: u64 = 0,
};
pub const State = struct { entries: []const Entry = &.{}, ready_serial: u64 = 0 };

/// A change to `Host.blobs`, applied at commit.
pub const BlobOp = union(enum) {
    append: struct { key: []const u8, bytes: []const u8 },
    drop: []const u8,
    clear,
};

const tags = [_][]const u8{ "attachment_fetch", "attachment_release" };
const Fetch = struct { workspace_id: []const u8, thread_id: []const u8, message_id: []const u8, index: u32 };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

pub fn receiptFields(context: []const u8) ?[]const u8 {
    if (eq(context, "attachment_fetch")) return "workspace_id thread_id message_id index";
    if (eq(context, "attachment_release")) return "key";
    return null;
}

pub fn validate(a: A, tag: []const u8, event: V) E!void {
    if (eq(tag, "attachment_fetch")) _ = try h.decode(Fetch, a, event) else _ = try h.decode(struct { key: []const u8 }, a, event);
}

pub fn key(a: A, workspace_id: []const u8, thread_id: []const u8, message_id: []const u8, index: u32) E![]const u8 {
    return std.fmt.allocPrint(a, "{s}|{s}|{s}|{d}", .{ workspace_id, thread_id, message_id, index });
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!owns(tag)) return;
    const a = tx.allocator();
    const id = try h.string(event, "intent_id");
    const s = &tx.state.attachments;
    if (eq(tag, "attachment_release")) {
        const k = try h.string(event, "key");
        if (find(s, k)) |i| try remove(tx, i);
        return receipt(tx, id, "succeeded", null);
    }
    const r = try h.decode(Fetch, a, event);
    if (!ref(r.workspace_id) or !ref(r.thread_id) or !ref(r.message_id)) return receipt(tx, id, "failed", failure("invalid_attachment", "This image can't be loaded."));
    if (!scoped(&tx.state, "chat:read")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't read chats on this host."));
    const k = try key(a, r.workspace_id, r.thread_id, r.message_id, r.index);
    if (find(s, k)) |i| {
        const e = &@constCast(s.entries)[i];
        // Loading: share the fetch. Ready: nothing to do. Failed/unavailable: try again.
        if (eq(e.status, "ready")) return receipt(tx, id, "succeeded", null);
        if (eq(e.status, "loading")) {
            try add([]const u8, a, &e.intents, id);
            return receipt(tx, id, "pending", null);
        }
        try remove(tx, i);
    }
    if (s.entries.len >= MAX_ENTRIES) {
        // Drop the oldest settled entry to make room; refuse when everything is loading.
        var dropped = false;
        for (s.entries, 0..) |e, i| if (!eq(e.status, "loading")) {
            try remove(tx, i);
            dropped = true;
            break;
        };
        if (!dropped) return receipt(tx, id, "failed", failure("busy", "Too many images are loading. Try again shortly."));
    }
    var intents: []const []const u8 = &.{};
    try add([]const u8, a, &intents, id);
    try add(Entry, a, &s.entries, .{ .key = k, .workspace_id = r.workspace_id, .thread_id = r.thread_id, .message_id = r.message_id, .index = r.index, .intents = intents });
    tx.changed = true;
    receipt(tx, id, "pending", null);
    try advance(tx);
}

/// Drains `@attach` results and starts waiting fetches while slots are free.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.attachments;
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@attach")) {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        }
        for (s.entries, 0..) |e, i| if (e.rpc_id != null and e.rpc_id.? == result.id) {
            try chunk(tx, i, result);
            break;
        };
    }
    try advance(tx);
}

/// Signing out drops every entry and blob.
pub fn observe(tx: *h.Transaction) E!void {
    if (tx.state.auth.credential != null or tx.state.attachments.entries.len == 0) return;
    tx.state.attachments = .{};
    try tx.blob(.clear);
    tx.changed = true;
}

pub fn query(a: A, state: *const h.State, blobs: anytype, selector: []const u8) E!?V {
    if (!eq(selector, "attachments")) return null;
    var items: []const Item = &.{};
    for (state.attachments.entries) |e| {
        var item: Item = .{ .key = e.key, .status = e.status, .mime = e.mime, .total_bytes = e.total_bytes, .error_code = e.error_code };
        if (eq(e.status, "ready")) if (blobs.get(e.key)) |bytes| {
            const out = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
            item.data_base64 = std.base64.standard.Encoder.encode(out, bytes);
        };
        try add(Item, a, &items, item);
    }
    return try h.parseLimit(a, try h.encode(a, View{ .items = items }), h.MAX_HTTP_INPUT * 2);
}

pub fn scopes(before: *const h.State, after: *const h.State) []const []const u8 {
    if (!clone.equal(State, before.attachments, after.attachments)) return &.{"attachments"};
    return &.{};
}

fn advance(tx: *h.Transaction) E!void {
    if (!online(&tx.state)) return;
    const s = &tx.state.attachments;
    var active: usize = 0;
    for (s.entries) |e| if (e.rpc_id != null) {
        active += 1;
    };
    for (@constCast(s.entries)) |*e| {
        if (active >= MAX_ACTIVE) return;
        if (!eq(e.status, "loading") or e.rpc_id != null) continue;
        try request(tx, e);
        active += 1;
    }
}

fn request(tx: *h.Transaction, e: *Entry) E!void {
    // Base64 grows 4/3: stay within the runtime's response cap.
    const cap: u64 = @intCast(tx.state.rpc.limits.max_response_bytes);
    const room = if (cap > 16 * 1024) (cap - 16 * 1024) / 4 * 3 else 4096;
    const length = @min(MAX_CHUNK_BYTES, room);
    e.rpc_id = try rpc.request(tx, "chat.attachment.read", .{ .workspace_id = e.workspace_id, .local_thread_id = e.thread_id, .message_id = e.message_id, .index = e.index, .offset = e.received, .length = length }, .{ .mutation = false, .intent_id = "@attach" });
    tx.changed = true;
}

fn chunk(tx: *h.Transaction, i: usize, result: rpc.Result) E!void {
    const s = &tx.state.attachments;
    const e = &@constCast(s.entries)[i];
    e.rpc_id = null;
    tx.changed = true;
    if (result.@"error") |err| {
        const code = err.rpc_code orelse err.code;
        // A dropped connection is retried by the next fetch; a missing image is final.
        return settle(tx, i, if (eq(code, "resource_not_found") or eq(code, "not_found")) "unavailable" else "failed", code);
    }
    const v = result.value orelse .null;
    const total = p.uint(p.get(v, "total_bytes")) orelse return settle(tx, i, "failed", "invalid_attachment");
    const offset = p.uint(p.get(v, "offset")) orelse return settle(tx, i, "failed", "invalid_attachment");
    if (total > MAX_IMAGE_BYTES) return settle(tx, i, "failed", "too_large");
    if (offset != e.received) return settle(tx, i, "failed", "invalid_attachment");
    const data = p.s(v, "data");
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch return settle(tx, i, "failed", "invalid_attachment");
    const bytes = try tx.allocator().alloc(u8, size);
    std.base64.standard.Decoder.decode(bytes, data) catch return settle(tx, i, "failed", "invalid_attachment");
    if (e.received + bytes.len > total) return settle(tx, i, "failed", "invalid_attachment");
    if (bytes.len == 0 and e.received < total) return settle(tx, i, "failed", "invalid_attachment");
    if (e.received == 0) {
        e.mime = p.s(v, "mime");
        e.total_bytes = total;
    }
    if (bytes.len > 0) try tx.blob(.{ .append = .{ .key = e.key, .bytes = bytes } });
    e.received += bytes.len;
    if (e.received >= total) {
        s.ready_serial += 1;
        e.ready_at = s.ready_serial;
        try settle(tx, i, "ready", null);
        try evict(tx);
    }
}

fn settle(tx: *h.Transaction, i: usize, status: []const u8, code: ?[]const u8) E!void {
    const e = &@constCast(tx.state.attachments.entries)[i];
    e.status = status;
    e.error_code = code;
    tx.changed = true;
    if (!eq(status, "ready")) {
        e.received = 0;
        try tx.blob(.{ .drop = e.key });
    }
    const err: ?h.LocalError = if (code) |c| failure(c, "This image couldn't be loaded.") else null;
    for (e.intents) |id| receipt(tx, id, if (eq(status, "ready")) "succeeded" else "failed", err);
    e.intents = &.{};
}

/// Keeps at most [MAX_READY] ready blobs in memory: the oldest ready one goes first.
fn evict(tx: *h.Transaction) E!void {
    const s = &tx.state.attachments;
    while (true) {
        var ready: usize = 0;
        var oldest: ?usize = null;
        for (s.entries, 0..) |e, i| if (eq(e.status, "ready")) {
            ready += 1;
            if (oldest == null or e.ready_at < s.entries[oldest.?].ready_at) oldest = i;
        };
        if (ready <= MAX_READY) return;
        try remove(tx, oldest.?);
    }
}

fn remove(tx: *h.Transaction, i: usize) E!void {
    const s = &tx.state.attachments;
    const gone = s.entries[i];
    try tx.blob(.{ .drop = gone.key });
    for (gone.intents) |id| receipt(tx, id, "failed", failure("released", "This image was released."));
    const next = try tx.allocator().alloc(Entry, s.entries.len - 1);
    @memcpy(next[0..i], s.entries[0..i]);
    @memcpy(next[i..], s.entries[i + 1 ..]);
    s.entries = next;
    tx.changed = true;
}

fn find(s: *const State, k: []const u8) ?usize {
    for (s.entries, 0..) |e, i| if (eq(e.key, k)) return i;
    return null;
}

fn ref(id: []const u8) bool {
    if (id.len == 0 or id.len > MAX_REF_BYTES) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f or c == '|') return false;
    return true;
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "attachments", .code = code, .message = message };
}

fn receipt(tx: *h.Transaction, id: []const u8, state: []const u8, err: ?h.LocalError) void {
    if (id.len == 0) return;
    for (@constCast(tx.state.receipts)) |*r| if (eq(r.operation.intent_id, id)) {
        r.operation.state = state;
        r.operation.@"error" = err;
    };
    tx.changed = true;
}

fn scoped(s: *const h.State, name: []const u8) bool {
    const credential = s.auth.credential orelse return false;
    for (credential.scopes) |scope| if (eq(scope, name)) return true;
    return false;
}

fn online(s: *const h.State) bool {
    return s.lifecycle == .foreground and s.network_available and s.rpc.phase == .ready and s.rpc.bearer != null;
}
