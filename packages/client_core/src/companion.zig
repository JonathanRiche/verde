//! Machine-wide Companion roster and crew for the `companion` selector. The
//! daemon owns one roster per machine (`companion.roster.get`/`.put`) and
//! appends the companion persona to turns on its thread, so the platform
//! only reads/writes the roster here and talks through the ordinary chat
//! engine. The crew is the active companion thread's orchestration links
//! (`chat.links.list`). Sans-IO: every step is an owned `/api/rpc` call.
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

/// Daemon limits (desktop `companion_roster.zig`); enforced before a put.
pub const MAX_COMPANIONS = 8;
pub const MAX_NAME_BYTES = 32;
pub const MAX_ORDERS_BYTES = 1024;
pub const MAX_LINKS = 256;
/// `companion_transcript_save` bounds: messages per event and bytes per body.
pub const MAX_TRANSCRIPT_MESSAGES = 200;
pub const MAX_TRANSCRIPT_BODY = 8192;
const MAX_TRANSCRIPT_REF = 128;
const MAX_SAVE_JOBS = 8;
const MAX_REF_BYTES = 160;

/// One companion. `character` is `sprout`, `moss` or `vireo`; empty strings
/// mean "not set" (no thread yet, new-chat default brain, no orders).
pub const Companion = struct {
    id: []const u8,
    name: []const u8,
    character: []const u8 = "sprout",
    home_workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    provider: []const u8 = "",
    model: []const u8 = "",
    orders: []const u8 = "",
};
pub const Roster = struct {
    version: u32 = 1,
    active_id: []const u8 = "",
    companions: []const Companion = &.{},
};
/// One delegated chat of the companion thread; `workspace_id` is the child's.
pub const Link = struct {
    link_id: []const u8 = "",
    workspace_id: []const u8 = "",
    parent_workspace_id: []const u8 = "",
    local_thread_id: []const u8 = "",
    title: []const u8 = "",
    provider: []const u8 = "",
    status: []const u8 = "idle",
    summary: []const u8 = "",
    updated_at_ms: i64 = 0,
    hidden: bool = false,
};
pub const Crew = struct {
    workspace_id: []const u8 = "",
    thread_id: []const u8 = "",
    links: []const Link = &.{},
    loaded: bool = false,
    loading: bool = false,
    @"error": ?h.LocalError = null,
};
/// `revision` is the daemon roster revision as a decimal string ("0" = never
/// saved). `supported` turns false when the host predates the roster RPCs.
pub const View = struct {
    loaded: bool = false,
    loading: bool = false,
    saving: bool = false,
    supported: bool = true,
    can_edit: bool = false,
    revision: []const u8 = "0",
    roster: Roster,
    crew: Crew,
    @"error": ?h.LocalError = null,
};

/// One saved line of a live voice session; `key` is stable per line within the session.
pub const TranscriptMessage = struct {
    key: []const u8,
    role: []const u8,
    author: []const u8 = "",
    body: []const u8,
    created_at_ms: i64 = 0,
};
/// A queued `companion_transcript_save`, appended one message at a time.
const SaveJob = struct {
    intent_id: []const u8,
    workspace_id: []const u8,
    thread_id: []const u8,
    session_id: []const u8,
    messages: []const TranscriptMessage,
    index: usize = 0,
    rpc_id: ?u64 = null,
    registering: bool = false,
};

pub const State = struct {
    saves: []const SaveJob = &.{},
    view: View = .{ .roster = .{}, .crew = .{} },
    get_id: ?u64 = null,
    get_intent: []const u8 = "",
    put_id: ?u64 = null,
    put_intent: []const u8 = "",
    put_roster: ?Roster = null,
    crew_id: ?u64 = null,
    crew_intent: []const u8 = "",
};

const tags = [_][]const u8{ "companion_refresh", "companion_save", "companion_crew_refresh", "companion_transcript_save" };
const read: rpc.Options = .{ .mutation = false, .intent_id = "@companion" };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

pub fn receiptFields(context: []const u8) ?[]const u8 {
    if (eq(context, "companion_refresh")) return "";
    if (eq(context, "companion_save")) return "roster expected_revision";
    if (eq(context, "companion_crew_refresh")) return "workspace_id thread_id";
    if (eq(context, "roster")) return "version active_id companions";
    if (eq(context, "companions")) return "id name character home_workspace_id thread_id provider model orders";
    if (eq(context, "companion_transcript_save")) return "workspace_id thread_id session_id messages";
    if (eq(context, "messages")) return "key role author body created_at_ms";
    return null;
}

pub fn validate(a: A, tag: []const u8, event: V) E!void {
    if (eq(tag, "companion_save")) {
        _ = try h.decode(struct { roster: Roster, expected_revision: []const u8 }, a, event);
    } else if (eq(tag, "companion_crew_refresh")) {
        _ = try h.decode(struct { workspace_id: []const u8, thread_id: []const u8 }, a, event);
    } else if (eq(tag, "companion_transcript_save")) {
        _ = try h.decode(TranscriptSave, a, event);
    }
}

const TranscriptSave = struct { workspace_id: []const u8, thread_id: []const u8, session_id: []const u8, messages: []const TranscriptMessage };

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!owns(tag)) return;
    const id = try h.string(event, "intent_id");
    const s = &tx.state.companion;
    if (!online(&tx.state)) return receipt(tx, id, "failed", failure("offline", "Connect to the host first."));
    if (eq(tag, "companion_refresh")) {
        if (!scoped(&tx.state, "chat:read")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't read chats on this host."));
        // Coalesce: the read in flight answers this refresh too.
        if (s.get_id != null) return receipt(tx, id, "succeeded", null);
        return requestRoster(tx, id);
    }
    if (eq(tag, "companion_transcript_save")) return transcriptSave(tx, id, event);
    if (eq(tag, "companion_crew_refresh")) {
        if (!scoped(&tx.state, "chat:read")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't read chats on this host."));
        const r = try h.decode(struct { workspace_id: []const u8, thread_id: []const u8 }, tx.allocator(), event);
        if (!ref(r.workspace_id) or !ref(r.thread_id)) return receipt(tx, id, "failed", failure("invalid_thread", "This companion has no conversation yet."));
        const same = eq(s.view.crew.workspace_id, r.workspace_id) and eq(s.view.crew.thread_id, r.thread_id);
        if (!same) {
            // A different companion: never show the previous companion's crew.
            s.view.crew = .{ .workspace_id = r.workspace_id, .thread_id = r.thread_id };
            s.crew_id = null;
            if (s.crew_intent.len > 0) receipt(tx, s.crew_intent, "succeeded", null);
            s.crew_intent = "";
        } else if (s.crew_id != null) return receipt(tx, id, "succeeded", null);
        s.view.crew.loading = true;
        s.crew_intent = id;
        s.crew_id = try rpc.request(tx, "chat.links.list", .{ .workspace_id = r.workspace_id, .parent_thread_id = r.thread_id }, read);
        tx.changed = true;
        return receipt(tx, id, "pending", null);
    }
    // companion_save
    if (!scoped(&tx.state, "chat:write")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't change companions on this host."));
    if (!s.view.supported) return receipt(tx, id, "failed", failure("unsupported", "Update Verde on the computer to use companions."));
    if (s.put_id != null) return receipt(tx, id, "failed", failure("busy", "Still saving the last change. Try again shortly."));
    const r = try h.decode(struct { roster: Roster, expected_revision: []const u8 }, tx.allocator(), event);
    const expected = std.fmt.parseInt(i64, r.expected_revision, 10) catch return receipt(tx, id, "failed", failure("invalid_revision", "Refresh companions and try again."));
    if (expected < 0) return receipt(tx, id, "failed", failure("invalid_revision", "Refresh companions and try again."));
    if (invalid(r.roster)) |err| return receipt(tx, id, "failed", err);
    s.put_intent = id;
    s.put_roster = r.roster;
    s.view.saving = true;
    s.put_id = try rpc.request(tx, "companion.roster.put", .{ .roster = r.roster, .expected_revision = expected }, .{ .intent_id = "@companion" });
    tx.changed = true;
    receipt(tx, id, "pending", null);
}

/// Drains `@companion` RPC outcomes.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.companion;
    const a = tx.allocator();
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@companion")) {
            try add(rpc.Result, a, &tx.state.rpc.results, result);
            continue;
        }
        tx.changed = true;
        if (s.get_id != null and s.get_id.? == result.id) {
            try rosterRead(tx, result);
        } else if (s.put_id != null and s.put_id.? == result.id) {
            try rosterWritten(tx, result);
        } else if (s.crew_id != null and s.crew_id.? == result.id) {
            try crewListed(tx, result);
        } else if (s.saves.len > 0 and s.saves[0].rpc_id != null and s.saves[0].rpc_id.? == result.id) {
            try transcriptStep(tx, result);
        }
    }
}

/// Signing out or forgetting the host drops the roster, crew and queued transcript saves.
pub fn observe(tx: *h.Transaction) void {
    if (tx.state.auth.credential != null) return;
    const s = &tx.state.companion;
    if (s.view.loaded or s.view.crew.links.len > 0 or s.get_id != null or s.put_id != null or s.crew_id != null or s.saves.len > 0) {
        tx.state.companion = .{};
        tx.changed = true;
    }
}

pub fn query(a: A, state: *const h.State, selector: []const u8) E!?V {
    if (!eq(selector, "companion")) return null;
    var view = state.companion.view;
    view.can_edit = view.supported and view.loaded and online(state) and scoped(state, "chat:write");
    return try h.parseLimit(a, try h.encode(a, view), h.MAX_HTTP_INPUT);
}

pub fn scopes(a: A, before: *const h.State, after: *const h.State, host_changed: bool) E![]const []const u8 {
    _ = a;
    if (host_changed or !clone.equal(View, before.companion.view, after.companion.view)) return &.{"companion"};
    return &.{};
}

/// Validates, bounds and queues a live voice transcript for `chat.message.append`.
fn transcriptSave(tx: *h.Transaction, id: []const u8, event: V) E!void {
    const a = tx.allocator();
    const s = &tx.state.companion;
    if (!scoped(&tx.state, "chat:write")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't write to chats on this host."));
    const r = try h.decode(TranscriptSave, a, event);
    if (!ref(r.workspace_id) or !ref(r.thread_id) or !ref(r.session_id) or r.session_id.len > MAX_TRANSCRIPT_REF)
        return receipt(tx, id, "failed", failure("invalid_thread", "This companion has no conversation yet."));
    if (r.messages.len > MAX_TRANSCRIPT_MESSAGES) return receipt(tx, id, "failed", failure("too_many", "Save at most 200 lines at a time."));
    var messages: []const TranscriptMessage = &.{};
    for (r.messages) |m| {
        if (!ref(m.key) or m.key.len > MAX_TRANSCRIPT_REF) return receipt(tx, id, "failed", failure("invalid_message", "A transcript line has no key."));
        if (!(eq(m.role, "user") or eq(m.role, "assistant") or eq(m.role, "system"))) return receipt(tx, id, "failed", failure("invalid_role", "A transcript line has an unknown role."));
        if (std.mem.trim(u8, m.body, " \t\r\n").len == 0) continue;
        try add(TranscriptMessage, a, &messages, .{ .key = m.key, .role = m.role, .author = m.author, .body = try clip(a, m.body, MAX_TRANSCRIPT_BODY), .created_at_ms = m.created_at_ms });
    }
    if (messages.len == 0) return receipt(tx, id, "succeeded", null);
    if (s.saves.len >= MAX_SAVE_JOBS) return receipt(tx, id, "failed", failure("busy", "Still saving earlier transcripts. Try again shortly."));
    try add(SaveJob, a, &s.saves, .{ .intent_id = id, .workspace_id = r.workspace_id, .thread_id = r.thread_id, .session_id = r.session_id, .messages = messages });
    receipt(tx, id, "pending", null);
    if (s.saves.len == 1) try advanceSave(tx);
}

/// Issues the next request of the oldest queued save: register a client first, then one append per line.
fn advanceSave(tx: *h.Transaction) E!void {
    const s = &tx.state.companion;
    while (s.saves.len > 0) {
        const job = @constCast(&s.saves[0]);
        if (!online(&tx.state)) {
            const id = job.intent_id;
            dropSave(tx);
            receipt(tx, id, "failed", failure("offline", "Connect to the host to save the voice transcript."));
            continue;
        }
        const client = tx.state.chat.client_id orelse {
            job.registering = true;
            job.rpc_id = try rpc.request(tx, "daemon.client.register", .{ .persistent = false }, .{ .intent_id = "@companion" });
            return;
        };
        const m = job.messages[job.index];
        const a = tx.allocator();
        const message_id = try std.fmt.allocPrint(a, "live:{s}:{s}", .{ job.session_id, m.key });
        job.registering = false;
        job.rpc_id = try rpc.request(tx, "chat.message.append", .{
            .mutation = .{ .request_key = message_id, .client_id = client },
            .workspace_id = job.workspace_id,
            .thread_id = job.thread_id,
            .message = .{ .message_id = message_id, .role = m.role, .author = m.author, .body = m.body, .created_at_ms = m.created_at_ms, .updated_at_ms = m.created_at_ms },
        }, .{ .intent_id = "@companion" });
        return;
    }
}

fn transcriptStep(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.companion;
    const job = @constCast(&s.saves[0]);
    job.rpc_id = null;
    if (result.@"error") |e| {
        const id = job.intent_id;
        dropSave(tx);
        receipt(tx, id, "failed", named(e));
        return advanceSave(tx);
    }
    if (job.registering) {
        const client = p.s(result.value orelse .null, "client_id");
        if (client.len == 0) {
            const id = job.intent_id;
            dropSave(tx);
            receipt(tx, id, "failed", failure("invalid_client", "The host did not register this device."));
            return advanceSave(tx);
        }
        tx.state.chat.client_id = client;
        return advanceSave(tx);
    }
    job.index += 1;
    if (job.index >= job.messages.len) {
        const id = job.intent_id;
        dropSave(tx);
        receipt(tx, id, "succeeded", null);
    }
    try advanceSave(tx);
}

fn dropSave(tx: *h.Transaction) void {
    const s = &tx.state.companion;
    s.saves = s.saves[1..];
    tx.changed = true;
}

/// At most `max` bytes, cut on a UTF-8 boundary and ending with an ellipsis when clipped.
pub fn clip(a: A, body: []const u8, max: usize) E![]const u8 {
    if (body.len <= max) return body;
    const ellipsis = "\u{2026}";
    var end = max - ellipsis.len;
    while (end > 0 and (body[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(a, "{s}{s}", .{ body[0..end], ellipsis });
}

fn requestRoster(tx: *h.Transaction, intent_id: []const u8) E!void {
    const s = &tx.state.companion;
    s.get_intent = intent_id;
    s.view.loading = true;
    s.get_id = try rpc.request(tx, "companion.roster.get", .{}, read);
    tx.changed = true;
    receipt(tx, intent_id, "pending", null);
}

fn rosterRead(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.companion;
    const id = s.get_intent;
    s.get_id = null;
    s.get_intent = "";
    s.view.loading = false;
    if (result.@"error") |e| {
        if (unsupported(e)) s.view.supported = false;
        s.view.@"error" = named(e);
        return receipt(tx, id, "failed", s.view.@"error");
    }
    const v = result.value orelse .null;
    const revision = p.uint(p.get(v, "revision"));
    const roster = parseRoster(tx.allocator(), p.get(v, "roster"));
    if (revision == null or roster == null) {
        s.view.@"error" = failure("invalid_roster", "The host returned an unreadable companion roster.");
        return receipt(tx, id, "failed", s.view.@"error");
    }
    // A put that landed meanwhile already moved the local revision forward.
    const current = std.fmt.parseInt(u64, s.view.revision, 10) catch 0;
    if (!s.view.loaded or revision.? >= current) {
        s.view.revision = try std.fmt.allocPrint(tx.allocator(), "{d}", .{revision.?});
        s.view.roster = roster.?;
    }
    s.view.loaded = true;
    s.view.supported = true;
    s.view.@"error" = null;
    receipt(tx, id, "succeeded", null);
}

fn rosterWritten(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.companion;
    const id = s.put_intent;
    const roster = s.put_roster;
    s.put_id = null;
    s.put_intent = "";
    s.put_roster = null;
    s.view.saving = false;
    if (result.@"error") |e| {
        const err = named(e);
        receipt(tx, id, "failed", err);
        // Someone else saved first: re-read so the platform can re-apply its edit.
        if (eq(err.code, "conflict") and s.get_id == null and online(&tx.state)) try requestRoster(tx, "");
        return;
    }
    const revision = p.uint(p.get(result.value orelse .null, "revision")) orelse {
        receipt(tx, id, "failed", failure("invalid_roster", "The host did not confirm the companion change."));
        if (s.get_id == null and online(&tx.state)) try requestRoster(tx, "");
        return;
    };
    s.view.revision = try std.fmt.allocPrint(tx.allocator(), "{d}", .{revision});
    s.view.roster = roster orelse s.view.roster;
    s.view.loaded = true;
    s.view.@"error" = null;
    receipt(tx, id, "succeeded", null);
}

fn crewListed(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.companion;
    const id = s.crew_intent;
    s.crew_id = null;
    s.crew_intent = "";
    s.view.crew.loading = false;
    if (result.@"error") |e| {
        s.view.crew.@"error" = named(e);
        return receipt(tx, id, "failed", s.view.crew.@"error");
    }
    const a = tx.allocator();
    var links: []const Link = &.{};
    for (p.rows(p.get(result.value orelse .null, "links"))) |row| {
        if (links.len >= MAX_LINKS) break;
        const link = std.json.parseFromValueLeaky(Link, a, row, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        if (link.local_thread_id.len == 0 or link.workspace_id.len == 0) continue;
        try add(Link, a, &links, link);
    }
    s.view.crew.links = links;
    s.view.crew.loaded = true;
    s.view.crew.@"error" = null;
    receipt(tx, id, "succeeded", null);
}

/// Lenient read of the daemon's canonical roster: unknown fields are ignored
/// and entries without an id are dropped rather than failing the whole view.
pub fn parseRoster(a: A, v: V) ?Roster {
    if (v != .object) return null;
    var out: Roster = .{ .active_id = p.s(v, "active_id") };
    if (p.uint(p.get(v, "version"))) |version| out.version = std.math.cast(u32, version) orelse 1;
    var list: []const Companion = &.{};
    for (p.rows(p.get(v, "companions"))) |row| {
        if (list.len >= MAX_COMPANIONS) break;
        const id = p.s(row, "id");
        if (id.len == 0) continue;
        const character = p.s(row, "character");
        add(Companion, a, &list, .{
            .id = id,
            .name = p.s(row, "name"),
            .character = if (knownCharacter(character)) character else "sprout",
            .home_workspace_id = p.s(row, "home_workspace_id"),
            .thread_id = p.s(row, "thread_id"),
            .provider = p.s(row, "provider"),
            .model = p.s(row, "model"),
            .orders = p.s(row, "orders"),
        }) catch return null;
    }
    out.companions = list;
    return out;
}

fn invalid(roster: Roster) ?h.LocalError {
    if (roster.companions.len > MAX_COMPANIONS) return failure("too_many", "Keep at most 8 companions.");
    for (roster.companions, 0..) |c, i| {
        const name = std.mem.trim(u8, c.name, " \t\r\n");
        if (c.id.len == 0 or c.id.len > 48 or !std.unicode.utf8ValidateSlice(c.id)) return failure("invalid_companion", "This companion can't be saved.");
        if (name.len == 0 or c.name.len > MAX_NAME_BYTES) return failure("invalid_name", "Use a name between 1 and 32 bytes.");
        for (c.name) |byte| if (byte < 0x20 or byte == 0x7f) return failure("invalid_name", "Use a name without line breaks.");
        if (!knownCharacter(c.character)) return failure("invalid_character", "Choose Sprout, Moss or Vireo.");
        if (c.orders.len > MAX_ORDERS_BYTES) return failure("invalid_orders", "Keep standing orders under 1024 bytes.");
        if (c.home_workspace_id.len > MAX_REF_BYTES or c.thread_id.len > MAX_REF_BYTES or c.provider.len > 24 or c.model.len > MAX_REF_BYTES)
            return failure("invalid_companion", "This companion can't be saved.");
        for (roster.companions[0..i]) |other| if (eq(other.id, c.id)) return failure("invalid_companion", "Two companions share an id.");
    }
    return null;
}

pub fn knownCharacter(character: []const u8) bool {
    return eq(character, "sprout") or eq(character, "moss") or eq(character, "vireo");
}

fn ref(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn unsupported(e: h.LocalError) bool {
    const code = e.rpc_code orelse e.code;
    return eq(code, "method_not_found") or eq(code, "unknown_method") or eq(code, "scope_denied");
}

/// Daemon codes the platform acts on become the local code; messages never
/// carry host text.
fn named(e: h.LocalError) h.LocalError {
    const code = e.rpc_code orelse e.code;
    var out: h.LocalError = .{ .domain = "companion", .code = code, .message = "The host couldn't update companions.", .retryable = e.retryable, .delivery = e.delivery, .rpc_code = e.rpc_code };
    if (eq(code, "conflict")) {
        out.message = "Companions changed on another device.";
    } else if (unsupported(e)) {
        out.message = "Update Verde on the computer to use companions.";
    } else if (eq(code, "invalid_params")) {
        out.message = "The host rejected this companion.";
    } else if (eq(code, "cancelled") or eq(code, "offline") or eq(e.domain, "transport")) {
        out.message = "Connect to the host to refresh companions.";
    }
    return out;
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "companion", .code = code, .message = message };
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
