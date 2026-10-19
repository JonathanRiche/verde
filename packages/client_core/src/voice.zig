//! Real-time voice for the Companion. API keys stay on the desktop: the daemon
//! lists providers (`voice.providers`), stores keys (`voice.provider.configure`)
//! and mints short-lived provider tokens (`voice.session.create`). The platform
//! opens the provider WebSocket itself with the token from the `voice` view.
//!
//! Security: an `api_key` only ever travels in the outgoing RPC body. It is not
//! part of the intent's receipt identity, never copied into state or views, and
//! never persisted. The session token lives in memory only, is replaced by the
//! next `voice_session_create`, and is dropped when the app leaves the
//! foreground or the credential goes away. Nothing here logs.
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

pub const MAX_KEY_BYTES = 4096;
pub const MAX_PROVIDERS = 16;
pub const MAX_TOOLS = 32;
pub const SESSION_TIMEOUT_MS: u32 = 45_000;

pub const Provider = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    /// `openai_realtime` or `gemini_live`.
    protocol: []const u8 = "",
    configured: bool = false,
    /// `none`, `environment` or `verde`; never the key itself.
    key_source: []const u8 = "none",
    model: []const u8 = "",
    voice: []const u8 = "",
    voices: []const []const u8 = &.{},
};
/// A function the voice model may call; `parameters` is its JSON schema as raw JSON text.
pub const Tool = struct { name: []const u8 = "", description: []const u8 = "", parameters: []const u8 = "{}" };
pub const SessionCompanion = struct { id: []const u8 = "", name: []const u8 = "", home_workspace_id: []const u8 = "", thread_id: []const u8 = "" };
/// The latest `voice_session_create`. `token` is short-lived and memory-only.
pub const Session = struct {
    intent_id: []const u8,
    /// `pending`, `ready` or `failed`.
    status: []const u8 = "pending",
    error_code: ?[]const u8 = null,
    provider: []const u8 = "",
    protocol: []const u8 = "",
    model: []const u8 = "",
    voice: []const u8 = "",
    token: []const u8 = "",
    expires_at_ms: i64 = 0,
    websocket_url: []const u8 = "",
    /// `bearer` (Authorization header) or `query` (already in `websocket_url`).
    auth: []const u8 = "",
    instructions: []const u8 = "",
    tools: []const Tool = &.{},
    companion: SessionCompanion,
};
pub const View = struct {
    loaded: bool = false,
    loading: bool = false,
    configuring: bool = false,
    /// False when the host predates the voice RPCs.
    supported: bool = true,
    default_provider: ?[]const u8 = null,
    providers: []const Provider = &.{},
    session: ?Session = null,
    @"error": ?h.LocalError = null,
};

pub const State = struct {
    view: View = .{},
    list_id: ?u64 = null,
    list_intent: []const u8 = "",
    configure_id: ?u64 = null,
    configure_intent: []const u8 = "",
    session_id: ?u64 = null,
};

const tags = [_][]const u8{ "voice_providers_refresh", "voice_provider_configure", "voice_session_create" };

pub fn owns(tag: []const u8) bool {
    for (tags) |t| if (eq(t, tag)) return true;
    return false;
}

/// `api_key` is deliberately absent: receipts never hash or retain it.
pub fn receiptFields(context: []const u8) ?[]const u8 {
    if (eq(context, "voice_providers_refresh")) return "";
    if (eq(context, "voice_provider_configure")) return "provider model voice make_default";
    if (eq(context, "voice_session_create")) return "provider model voice companion_id";
    return null;
}

const Configure = struct { provider: []const u8, api_key: ?[]const u8 = null, model: ?[]const u8 = null, voice: ?[]const u8 = null, make_default: ?bool = null };
const Create = struct { provider: ?[]const u8 = null, model: ?[]const u8 = null, voice: ?[]const u8 = null, companion_id: ?[]const u8 = null };

pub fn validate(a: A, tag: []const u8, event: V) E!void {
    if (eq(tag, "voice_provider_configure")) {
        _ = try h.decode(Configure, a, event);
    } else if (eq(tag, "voice_session_create")) {
        _ = try h.decode(Create, a, event);
    }
}

pub fn intent(tx: *h.Transaction, tag: []const u8, event: V) E!void {
    if (!owns(tag)) return;
    const a = tx.allocator();
    const id = try h.string(event, "intent_id");
    const s = &tx.state.voice;
    if (eq(tag, "voice_session_create")) {
        // A new request always retires the previous session and its token.
        s.view.session = .{ .intent_id = id, .companion = .{} };
        s.session_id = null;
        tx.changed = true;
    }
    if (!online(&tx.state)) return fail(tx, id, tag, failure("offline", "Connect to the host first."));
    if (eq(tag, "voice_providers_refresh")) {
        if (!scoped(&tx.state, "chat:read")) return receipt(tx, id, "failed", failure("insufficient_scope", "This phone can't use voice on this host."));
        if (s.list_id != null) return receipt(tx, id, "succeeded", null);
        s.list_intent = id;
        s.view.loading = true;
        s.list_id = try rpc.request(tx, "voice.providers", .{}, .{ .mutation = false, .intent_id = "@voice" });
        tx.changed = true;
        return receipt(tx, id, "pending", null);
    }
    if (!scoped(&tx.state, "chat:write")) return fail(tx, id, tag, failure("insufficient_scope", "This phone can't use voice on this host."));
    if (!s.view.supported) return fail(tx, id, tag, failure("unsupported", "Update verde on the computer to use live voice."));
    if (eq(tag, "voice_provider_configure")) {
        if (s.configure_id != null) return receipt(tx, id, "failed", failure("busy", "Still saving the last voice change."));
        const r = try h.decode(Configure, a, event);
        if (r.provider.len == 0 or r.provider.len > 32) return receipt(tx, id, "failed", failure("invalid_provider", "Choose a voice provider."));
        if (r.api_key) |key| if (key.len > MAX_KEY_BYTES) return receipt(tx, id, "failed", failure("invalid_key", "That API key is too long."));
        var params: std.json.ObjectMap = .empty;
        try params.put(a, "provider", .{ .string = r.provider });
        if (r.api_key) |key| try params.put(a, "api_key", .{ .string = key });
        if (r.model) |model| try params.put(a, "model", .{ .string = model });
        if (r.voice) |voice| try params.put(a, "voice", .{ .string = voice });
        if (r.make_default) |value| try params.put(a, "make_default", .{ .bool = value });
        s.configure_intent = id;
        s.view.configuring = true;
        s.configure_id = try rpc.request(tx, "voice.provider.configure", V{ .object = params }, .{ .intent_id = "@voice" });
        tx.changed = true;
        return receipt(tx, id, "pending", null);
    }
    // voice_session_create
    const r = try h.decode(Create, a, event);
    var params: std.json.ObjectMap = .empty;
    if (r.provider) |v| try params.put(a, "provider", .{ .string = v });
    if (r.model) |v| try params.put(a, "model", .{ .string = v });
    if (r.voice) |v| try params.put(a, "voice", .{ .string = v });
    if (r.companion_id) |v| try params.put(a, "companion_id", .{ .string = v });
    s.session_id = try rpc.request(tx, "voice.session.create", V{ .object = params }, .{ .intent_id = "@voice", .timeout_ms = SESSION_TIMEOUT_MS });
    receipt(tx, id, "pending", null);
}

/// Drains `@voice` RPC outcomes.
pub fn pump(tx: *h.Transaction) E!void {
    const s = &tx.state.voice;
    const count = tx.state.rpc.results.len;
    for (0..count) |_| {
        const result = rpc.takeResult(tx).?;
        if (result.intent_id == null or !eq(result.intent_id.?, "@voice")) {
            try add(rpc.Result, tx.allocator(), &tx.state.rpc.results, result);
            continue;
        }
        tx.changed = true;
        if (s.list_id != null and s.list_id.? == result.id) {
            const id = s.list_intent;
            s.list_id = null;
            s.list_intent = "";
            s.view.loading = false;
            try listed(tx, id, result);
        } else if (s.configure_id != null and s.configure_id.? == result.id) {
            const id = s.configure_intent;
            s.configure_id = null;
            s.configure_intent = "";
            s.view.configuring = false;
            try listed(tx, id, result);
        } else if (s.session_id != null and s.session_id.? == result.id) {
            s.session_id = null;
            try created(tx, result);
        }
    }
}

/// The token is short-lived and memory-only: drop it with the credential or in the background.
pub fn observe(tx: *h.Transaction) void {
    const s = &tx.state.voice;
    if (tx.state.auth.credential == null) {
        if (s.view.loaded or s.view.session != null or s.list_id != null or s.configure_id != null or s.session_id != null) {
            tx.state.voice = .{};
            tx.changed = true;
        }
        return;
    }
    if (tx.state.lifecycle != .foreground and (s.view.session != null or s.session_id != null)) {
        s.view.session = null;
        s.session_id = null;
        tx.changed = true;
    }
}

pub fn query(a: A, state: *const h.State, selector: []const u8) E!?V {
    if (!eq(selector, "voice")) return null;
    return try h.parseLimit(a, try h.encode(a, state.voice.view), h.MAX_HTTP_INPUT);
}

pub fn scopes(before: *const h.State, after: *const h.State) []const []const u8 {
    if (!clone.equal(View, before.voice.view, after.voice.view)) return &.{"voice"};
    return &.{};
}

fn listed(tx: *h.Transaction, id: []const u8, result: rpc.Result) E!void {
    const s = &tx.state.voice;
    if (result.@"error") |e| {
        if (unsupported(e)) s.view.supported = false;
        s.view.@"error" = named(e);
        return receipt(tx, id, "failed", s.view.@"error");
    }
    const a = tx.allocator();
    const v = result.value orelse .null;
    if (p.get(v, "providers") != .array) {
        s.view.@"error" = failure("invalid_providers", "The host returned unreadable voice settings.");
        return receipt(tx, id, "failed", s.view.@"error");
    }
    var providers: []const Provider = &.{};
    for (p.rows(p.get(v, "providers"))) |row| {
        if (providers.len >= MAX_PROVIDERS) break;
        const pid = p.s(row, "id");
        if (pid.len == 0) continue;
        var voices: []const []const u8 = &.{};
        for (p.rows(p.get(row, "voices"))) |item| if (item == .string and voices.len < 64) try add([]const u8, a, &voices, item.string);
        try add(Provider, a, &providers, .{
            .id = pid,
            .label = p.s(row, "label"),
            .protocol = p.s(row, "protocol"),
            .configured = p.yes(p.get(row, "configured")),
            .key_source = if (p.s(row, "key_source").len > 0) p.s(row, "key_source") else "none",
            .model = p.s(row, "model"),
            .voice = p.s(row, "voice"),
            .voices = voices,
        });
    }
    const default_value = p.get(v, "default_provider");
    s.view.providers = providers;
    s.view.default_provider = if (default_value == .string) default_value.string else null;
    s.view.loaded = true;
    s.view.supported = true;
    s.view.@"error" = null;
    receipt(tx, id, "succeeded", null);
}

fn created(tx: *h.Transaction, result: rpc.Result) E!void {
    const s = &tx.state.voice;
    const current = s.view.session orelse return;
    const id = current.intent_id;
    if (result.@"error") |e| {
        if (unsupported(e)) s.view.supported = false;
        const err = named(e);
        s.view.session = .{ .intent_id = id, .status = "failed", .error_code = err.code, .companion = .{} };
        return receipt(tx, id, "failed", err);
    }
    const a = tx.allocator();
    const v = result.value orelse .null;
    const token = p.s(v, "token");
    const url = p.s(v, "websocket_url");
    const auth = p.s(v, "auth");
    if (token.len == 0 or url.len == 0 or !(eq(auth, "bearer") or eq(auth, "query")) or !std.mem.startsWith(u8, url, "wss://")) {
        const err = failure("invalid_session", "The host returned an unusable voice session.");
        s.view.session = .{ .intent_id = id, .status = "failed", .error_code = err.code, .companion = .{} };
        return receipt(tx, id, "failed", err);
    }
    var tools: []const Tool = &.{};
    for (p.rows(p.get(v, "tools"))) |row| {
        if (tools.len >= MAX_TOOLS) break;
        const name = p.s(row, "name");
        if (name.len == 0) continue;
        const schema = p.get(row, "parameters");
        try add(Tool, a, &tools, .{ .name = name, .description = p.s(row, "description"), .parameters = if (schema == .object) try h.encode(a, schema) else "{\"type\":\"object\",\"properties\":{}}" });
    }
    const companion = p.get(v, "companion");
    s.view.session = .{
        .intent_id = id,
        .status = "ready",
        .provider = p.s(v, "provider"),
        .protocol = p.s(v, "protocol"),
        .model = p.s(v, "model"),
        .voice = p.s(v, "voice"),
        .token = token,
        .expires_at_ms = p.num(p.get(v, "expires_at_ms")) orelse 0,
        .websocket_url = url,
        .auth = auth,
        .instructions = p.s(v, "instructions"),
        .tools = tools,
        .companion = .{ .id = p.s(companion, "id"), .name = p.s(companion, "name"), .home_workspace_id = p.s(companion, "home_workspace_id"), .thread_id = p.s(companion, "thread_id") },
    };
    receipt(tx, id, "succeeded", null);
}

fn fail(tx: *h.Transaction, id: []const u8, tag: []const u8, err: h.LocalError) void {
    if (eq(tag, "voice_session_create")) tx.state.voice.view.session = .{ .intent_id = id, .status = "failed", .error_code = err.code, .companion = .{} };
    receipt(tx, id, "failed", err);
}

fn unsupported(e: h.LocalError) bool {
    const code = e.rpc_code orelse e.code;
    return eq(code, "unknown_method") or eq(code, "method_not_found") or eq(code, "scope_denied");
}

/// Daemon codes the platform acts on become the local code; no host text is kept.
fn named(e: h.LocalError) h.LocalError {
    const code = e.rpc_code orelse e.code;
    var out: h.LocalError = .{ .domain = "voice", .code = code, .message = "The host couldn't start voice.", .retryable = e.retryable, .delivery = e.delivery, .rpc_code = e.rpc_code };
    if (eq(code, "voice_not_configured")) {
        out.message = "Add an xAI, OpenAI or Gemini API key for live voice.";
    } else if (eq(code, "voice_key_rejected")) {
        out.message = "The voice provider rejected the API key.";
    } else if (eq(code, "voice_provider_unavailable")) {
        out.message = "Couldn't reach the voice provider.";
    } else if (eq(code, "invalid_params")) {
        out.message = "The host rejected these voice settings.";
    } else if (unsupported(e)) {
        out.message = "Update verde on the computer to use live voice.";
    } else if (eq(e.domain, "transport")) {
        out.message = "Connect to the host to use live voice.";
    }
    return out;
}

fn failure(code: []const u8, message: []const u8) h.LocalError {
    return .{ .domain = "voice", .code = code, .message = message };
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
