//! Auth fixtures assert only booleans for secret-bearing values so a failure
//! never prints credentials, pairing codes, tokens, or serialized effects.
const std = @import("std");
const h = @import("host.zig");
const auth = @import("auth.zig");
const V = std.json.Value;
const expect = std.testing.expect;
const runtime_id = "1" ** 32;
const instance_id = "2" ** 32;
const device_id = "3" ** 32;
const secret = "4" ** 64;
const pin = "5" ** 64;
const scopes = [_][]const u8{ "runtime:read", "chat:read", "terminal:read", "repository:read" };
const link = "https://verdeai.dev/pair?host=https%3A%2F%2Fhost.example&grant_id=" ++ "6" ** 32 ++ "#code=" ++ "7" ** 64;
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    host: h.Host,
    now: i64 = 1,
    fn init() !Fixture {
        return .{ .arena = .init(std.testing.allocator), .host = try h.Host.init(std.testing.allocator,
            \\{"api_version":1,"host_id":"phone","label":"Dev","https_url":null,"wss_url":null,"client_revision":1,"session_nonce":"00000000000000000000000000000000","jitter_seed":1}
        ) };
    }
    fn deinit(f: *Fixture) void {
        f.host.deinit();
        f.arena.deinit();
    }
    fn event(f: *Fixture, tag: []const u8, payload: anytype) !V {
        const a = f.arena.allocator();
        var value = try h.parse(a, try h.encode(a, payload));
        if (value == .array) value = .{ .object = .empty };
        try value.object.put(a, "api_version", .{ .integer = 1 });
        try value.object.put(a, "type", .{ .string = tag });
        try value.object.put(a, "now_ms", .{ .integer = f.now });
        try value.object.put(a, "wall_time_ms", .{ .integer = f.now });
        return h.parse(a, try f.host.handle(try h.encode(a, value), a));
    }
    fn loaded(f: *Fixture) !void {
        const batch = try f.event("start", .{ .foreground = true, .network_available = true });
        for (get(batch, "effects").array.items) |effect| {
            if (!h.eq(get(effect, "type").string, "secure_store_get")) continue;
            _ = try f.event("secure_store_value", .{ .effect_id = get(effect, "effect_id").string, .generation = get(effect, "generation").string, .key = get(effect, "key").string, .value_base64 = @as(?u8, null), .@"error" = @as(?u8, null) });
        }
    }
    fn pair(f: *Fixture) !V {
        return f.event("pair", .{ .intent_id = "pair", .link = link, .device_label = "Phone", .client_nonce = "8" ** 32 });
    }
    fn response(f: *Fixture, effect: V, status: u16, body: anytype) !V {
        return f.event("http_response", .{ .effect_id = get(effect, "effect_id").string, .generation = get(effect, "generation").string, .status = status, .headers = .{}, .body_base64 = try auth.encode64(f.arena.allocator(), try h.encode(f.arena.allocator(), body)), .@"error" = @as(?u8, null) });
    }
    fn lost(f: *Fixture, effect: V) !V {
        return f.event("http_response", .{ .effect_id = get(effect, "effect_id").string, .generation = get(effect, "generation").string, .status = @as(?u8, null), .headers = .{}, .body_base64 = @as(?u8, null), .@"error" = .{ .kind = "network", .code = "reset" } });
    }
    fn done(f: *Fixture, effect: V) !V {
        return f.event("secure_store_done", .{ .effect_id = get(effect, "effect_id").string, .generation = get(effect, "generation").string, .key = get(effect, "key").string, .@"error" = @as(?u8, null) });
    }
    fn fire(f: *Fixture, effect: V) !V {
        f.now += get(effect, "delay_ms").integer;
        return f.event("timer_fired", .{ .timer_id = get(effect, "timer_id").string, .generation = get(effect, "generation").string });
    }
    fn discovery(f: *Fixture, trusted: bool, idempotent: bool) !V {
        const probe = try find(try f.pair(), "tls_probe");
        const batch = try f.event("tls_peer", .{ .effect_id = get(probe, "effect_id").string, .generation = get(probe, "generation").string, .origin = "https://host.example", .spki_sha256 = pin, .system_trusted = trusted });
        if (!trusted) return batch;
        return f.response(try find(batch, "http_request"), 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .https_url = "https://host.example", .wss_url = "wss://host.example/ws", .capabilities = if (idempotent) &[_][]const u8{ "access.pair.v1", "access.pair.idempotent.v1" } else &[_][]const u8{"access.pair.v1"} });
    }
    fn exchange(f: *Fixture, idempotent: bool) !V {
        try f.loaded();
        _ = try f.discovery(true, idempotent);
        const proposal = f.host.state.auth.proposal.?;
        const wire = @import("wire.zig");
        const query = try f.host.query("hosts", f.arena.allocator());
        const typed = try std.json.parseFromSliceLeaky(wire.Query(wire.HostsView), f.arena.allocator(), query, .{});
        try expect(h.eq(typed.data.?.items[0].trust_proposal.?.id, proposal.id));
        const write = try find(try f.event("trust_decision", .{ .intent_id = "trust", .proposal_id = proposal.id, .accept = true }), "secure_store_put");
        try expect(f.host.state.auth.pin == null);
        return find(try f.done(write), "http_request");
    }
    fn credential(f: *Fixture, exchange_effect: V) !V {
        const write = try find(try f.response(exchange_effect, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .device_id = device_id, .device_credential = secret, .scopes = scopes }), "secure_store_put");
        try expect(f.host.state.auth.token == null);
        return find(try f.done(write), "http_request");
    }
    fn token(f: *Fixture, effect: V) !V {
        return f.response(effect, 200, .{ .access_protocol_version = 1, .access_token = secret, .token_type = "Bearer", .expires_at_ms = f.now + 900000, .scopes = scopes });
    }
};
fn get(v: V, key: []const u8) V {
    return v.object.get(key).?;
}
fn find(batch: V, tag: []const u8) !V {
    for (get(batch, "effects").array.items) |effect| if (h.eq(get(effect, "type").string, tag)) return effect;
    return error.ExpectedEffectMissing;
}
fn no(batch: V, tag: []const u8) !void {
    for (get(batch, "effects").array.items) |effect| try expect(!h.eq(get(effect, "type").string, tag));
}
test "auth happy path persists before minting, ticket subprotocols, and refresh single flight" {
    var f = try Fixture.init();
    defer f.deinit();
    const exchange_effect = try f.exchange(true);
    const token_effect = try f.credential(exchange_effect);
    const batch = try f.token(token_effect);
    const refresh = try find(batch, "set_timer");
    try expect(get(refresh, "delay_ms").integer == 780000);
    const ticket_effect = try find(batch, "http_request");
    const socket = try find(try f.response(ticket_effect, 200, .{ .access_protocol_version = 1, .ticket = secret, .expires_at_ms = f.now + 30000 }), "ws_open");
    try expect(h.eq(get(socket, "url").string, "wss://host.example/ws"));
    try expect(h.eq(get(socket, "protocols").array.items[1].string, "verde.ticket." ++ secret));
    const refreshed = try find(try f.fire(refresh), "http_request");
    try expect(h.eq(get(refreshed, "url").string, "https://host.example/auth/access-token"));
    try no(try f.event("foreground", .{}), "http_request");
    _ = try f.token(refreshed);
    const query = try f.host.query("hosts", f.arena.allocator());
    try expect(std.mem.indexOf(u8, query, secret) == null);
    try expect(std.mem.indexOf(u8, query, "7" ** 64) == null);
}
test "auth lost exchange response retries identical nonce and grant then succeeds" {
    var f = try Fixture.init();
    defer f.deinit();
    const first = try f.exchange(true);
    const timer = try find(try f.lost(first), "set_timer");
    const second = try find(try f.fire(timer), "http_request");
    try expect(h.eq(get(first, "body_base64").string, get(second, "body_base64").string));
    _ = try f.credential(second);
    try expect(f.host.state.auth.pair == null);
    try expect(h.eq(f.host.state.auth_state, "paired"));
    try no(try f.lost(first), "http_request");
}
test "auth expired grant ends pairing without minting" {
    var f = try Fixture.init();
    defer f.deinit();
    const exchange_effect = try f.exchange(true);
    try no(try f.response(exchange_effect, 401, .{}), "http_request");
    try expect(f.host.state.auth.pair == null);
    try expect(h.eq(f.host.state.auth_state, "unpaired"));
}
test "auth revoked device retries one 401 then requires repair" {
    var f = try Fixture.init();
    defer f.deinit();
    const token_effect = try f.credential(try f.exchange(true));
    const retry_effect = try find(try f.response(token_effect, 401, .{}), "http_request");
    try no(try f.response(retry_effect, 401, .{}), "http_request");
    try expect(h.eq(f.host.state.auth_state, "repair_required"));
    try no(try f.event("foreground", .{}), "http_request");
}
test "auth ticket 401 refreshes then retries the ticket once" {
    var f = try Fixture.init();
    defer f.deinit();
    const ticket = try find(try f.token(try f.credential(try f.exchange(true))), "http_request");
    const token_effect = try find(try f.response(ticket, 401, .{}), "http_request");
    const retry_ticket = try find(try f.token(token_effect), "http_request");
    try no(try f.response(retry_ticket, 401, .{}), "ws_open");
    try expect(h.eq(f.host.state.auth_state, "repair_required"));
}
test "auth refuses invalid system trust and unsafe automatic exchange retries" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.loaded();
    try no(try f.discovery(false, true), "http_request");
    var legacy = try Fixture.init();
    defer legacy.deinit();
    try no(try legacy.lost(try legacy.exchange(false)), "set_timer");
    try expect(legacy.host.state.auth.blocked);
}
test "auth pair parser accepts native and App Link, rejects query secrets and ambiguous inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try auth.parseLink(arena.allocator(), link);
    _ = try auth.parseLink(arena.allocator(), "verde://pair?host=https%3A%2F%2Fhost.example&grant_id=" ++ "6" ** 32 ++ "#code=" ++ "7" ** 64);
    const bad = [_][]const u8{ "https://evil.example/pair?host=x#code=x", "verde://pair?host=https://host.example&code=x#code=x", link ++ "&code=other", "verde://pair?host=http://host.example&grant_id=" ++ "6" ** 32 ++ "#code=" ++ "7" ** 64 };
    for (bad) |value| {
        const result = auth.parseLink(arena.allocator(), value);
        try expect(if (result) |_| false else |_| true);
    }
}

test "auth durable writes survive background and no credential traffic precedes acknowledgement" {
    var f = try Fixture.init();
    defer f.deinit();
    const exchange_effect = try f.exchange(true);
    const batch = try f.response(exchange_effect, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .device_id = device_id, .device_credential = secret, .scopes = scopes });
    try no(batch, "http_request");
    const write = try find(batch, "secure_store_put");
    _ = try f.event("background", .{});
    try no(try f.done(write), "http_request");
    try expect(h.eq(f.host.state.auth_state, "paired"));
    _ = try find(try f.event("foreground", .{}), "tls_probe");
    try expect(f.host.state.auth.token == null);
}

test "auth storage failure preserves credential and explicit retry saves before token" {
    var f = try Fixture.init();
    defer f.deinit();
    const exchange_effect = try f.exchange(true);
    const write = try find(try f.response(exchange_effect, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .device_id = device_id, .device_credential = secret, .scopes = scopes }), "secure_store_put");
    try no(try f.event("secure_store_done", .{ .effect_id = get(write, "effect_id").string, .generation = get(write, "generation").string, .key = get(write, "key").string, .@"error" = .{ .code = "locked" } }), "http_request");
    const retry_write = try find(try f.event("retry_connection", .{ .intent_id = "retry-store" }), "secure_store_put");
    _ = try find(try f.done(retry_write), "http_request");
}

test "auth denied trust and stale proposal never send secrets" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.loaded();
    _ = try f.discovery(true, true);
    const id = f.host.state.auth.proposal.?.id;
    try no(try f.event("trust_decision", .{ .intent_id = "deny", .proposal_id = id, .accept = false }), "http_request");
    try no(try f.event("retry_connection", .{ .intent_id = "retry" }), "http_request");
    const result = f.event("trust_decision", .{ .intent_id = "stale", .proposal_id = id, .accept = true });
    try expect(if (result) |_| false else |err| err == error.InvalidArgument);
}

test "auth changed TLS pin requires durable retrust before credential reuse" {
    var f = try Fixture.init();
    defer f.deinit();
    _ = try f.credential(try f.exchange(true));
    _ = try f.event("background", .{});
    const probe = try find(try f.event("foreground", .{}), "tls_probe");
    const discover = try find(try f.event("tls_peer", .{ .effect_id = get(probe, "effect_id").string, .generation = get(probe, "generation").string, .origin = "https://host.example", .spki_sha256 = "9" ** 64, .system_trusted = true }), "http_request");
    const batch = try f.response(discover, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .https_url = "https://host.example", .wss_url = "wss://host.example/ws", .capabilities = [_][]const u8{ "access.pair.v1", "access.pair.idempotent.v1" } });
    try no(batch, "http_request");
    try expect(f.host.state.auth.proposal != null);
    const write = try find(try f.event("trust_decision", .{ .intent_id = "retrust", .proposal_id = f.host.state.auth.proposal.?.id, .accept = true }), "secure_store_put");
    _ = try find(try f.done(write), "http_request");
}

test "auth restart reads durable records out of order then probes before device auth" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = try f.event("start", .{ .foreground = true, .network_available = true });
    const reads = get(batch, "effects").array.items;
    const a = f.arena.allocator();
    const credential = try auth.encode64(a, try h.encode(a, auth.Credential{ .runtime_id = runtime_id, .device_id = device_id, .device_credential = secret, .scopes = &scopes }));
    const profile = try auth.encode64(a, try h.encode(a, auth.Pin{ .origin = "https://host.example", .wss_url = "wss://host.example/ws", .spki_sha256 = pin, .runtime_id = runtime_id, .instance_id = instance_id }));
    try no(try f.event("secure_store_value", .{ .effect_id = get(reads[1], "effect_id").string, .generation = "0", .key = get(reads[1], "key").string, .value_base64 = credential, .@"error" = @as(?u8, null) }), "tls_probe");
    const probe = try find(try f.event("secure_store_value", .{ .effect_id = get(reads[0], "effect_id").string, .generation = "0", .key = get(reads[0], "key").string, .value_base64 = profile, .@"error" = @as(?u8, null) }), "tls_probe");
    const discovery = try find(try f.event("tls_peer", .{ .effect_id = get(probe, "effect_id").string, .generation = "0", .origin = "https://host.example", .spki_sha256 = pin, .system_trusted = true }), "http_request");
    const request = try find(try f.response(discovery, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .https_url = "https://host.example", .wss_url = "wss://host.example/ws", .capabilities = [_][]const u8{"access.pair.v1"} }), "http_request");
    try expect(h.eq(get(request, "url").string, "https://host.example/auth/access-token"));
    try expect(f.host.state.auth.proposal == null);
}

test "auth locked reads both retry after unlock without becoming unpaired" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = try f.event("start", .{ .foreground = true, .network_available = true });
    for (get(batch, "effects").array.items[0..2]) |read| {
        _ = try f.event("secure_store_value", .{ .effect_id = get(read, "effect_id").string, .generation = "0", .key = get(read, "key").string, .value_base64 = @as(?u8, null), .@"error" = .{ .code = "locked" } });
    }
    try expect(h.eq(f.host.state.auth_state, "loading"));
    const retried = try f.event("retry_connection", .{ .intent_id = "unlock" });
    var count: usize = 0;
    for (get(retried, "effects").array.items) |effect| if (h.eq(get(effect, "type").string, "secure_store_get")) {
        count += 1;
    };
    try expect(count == 2);
}

fn findUrl(batch: V, suffix: []const u8) !V {
    for (get(batch, "effects").array.items) |effect| {
        if (!h.eq(get(effect, "type").string, "http_request")) continue;
        if (std.mem.endsWith(u8, get(effect, "url").string, suffix)) return effect;
    }
    return error.ExpectedEffectMissing;
}
test "auth RPC 401 refresh retries the same envelope once then stops on another 401" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = try f.token(try f.credential(try f.exchange(true)));
    const rpc_effect = try findUrl(batch, "/api/rpc");
    const refresh = try findUrl(try f.response(rpc_effect, 401, .{}), "/auth/access-token");
    try expect(f.host.state.rpc.results.len == 0);
    try no(try f.event("foreground", .{}), "http_request");
    const retried = try findUrl(try f.token(refresh), "/api/rpc");
    try expect(h.eq(get(rpc_effect, "body_base64").string, get(retried, "body_base64").string));
    try no(try f.response(retried, 401, .{}), "http_request");
    try expect(h.eq(f.host.state.auth_state, "repair_required"));
    try expect(f.host.state.rpc.bearer == null);
    try expect(f.host.state.rpc.results.len == 1);
}
test "auth RPC 403 never refreshes or flags repair" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = try f.token(try f.credential(try f.exchange(true)));
    const rpc_effect = try findUrl(batch, "/api/rpc");
    try no(try f.response(rpc_effect, 403, .{}), "http_request");
    try expect(!h.eq(f.host.state.auth_state, "repair_required"));
    try expect(f.host.state.rpc.results.len == 1);
    try expect(h.eq(f.host.state.rpc.results[0].@"error".?.code, "scope_denied"));
}

test "auth terminal token failure cancels old transport and clears RPC bearer" {
    var f = try Fixture.init();
    defer f.deinit();
    const batch = try f.token(try f.credential(try f.exchange(true)));
    const ticket = try findUrl(batch, "/auth/websocket-ticket");
    _ = try f.response(ticket, 200, .{ .access_protocol_version = 1, .ticket = secret, .expires_at_ms = f.now + 30000 });
    const refresh = try findUrl(try f.fire(try find(batch, "set_timer")), "/auth/access-token");
    const failed = try f.response(refresh, 200, .{ .access_protocol_version = 1, .access_token = secret, .token_type = "Bearer", .expires_at_ms = f.now - 1, .scopes = scopes });
    _ = try find(failed, "ws_close");
    try expect(f.host.state.rpc.bearer == null);
    try expect(f.host.state.auth.blocked);
    try no(failed, "http_request");
}

test "auth stale completion cannot trigger refresh even after wall expiry" {
    var f = try Fixture.init();
    defer f.deinit();
    const exchange_effect = try f.exchange(true);
    _ = try f.token(try f.credential(exchange_effect));
    f.now += 900001;
    const stale = try f.response(exchange_effect, 401, .{});
    try expect(get(stale, "effects").array.items.len == 0);
    _ = try findUrl(try f.event("foreground", .{}), "/auth/access-token");
}

// Establish auth through real events; handshake/snapshot behavior is covered by
// the RPC/sync harnesses. These tests isolate removal from those consumers.
fn readyForRemoval(f: *Fixture) !void {
    _ = try f.token(try f.credential(try f.exchange(true)));
    f.host.state.rpc.phase = .ready;
    f.host.state.rpc.instance_id = instance_id;
}
fn removal(f: *Fixture, tag: []const u8, id: []const u8) !V {
    return f.event(tag, .{ .intent_id = id, .host_id = "phone" });
}
fn revokeResponse(f: *Fixture, effect: V) !V {
    const request = try h.parse(f.arena.allocator(), try auth.decode64(f.arena.allocator(), get(effect, "body_base64").string));
    try expect(h.eq(get(request, "method").string, "device.self.revoke"));
    try expect(h.eq(get(get(request, "target"), "runtime_id").string, runtime_id));
    return f.response(effect, 200, .{ .jsonrpc = "2.0", .id = get(request, "id").integer, .result = .{ .access_protocol_version = 1, .revoked = true, .device_id = device_id } });
}
/// K-17: after the sync checkpoint, attention and push records go, then the
/// chat index is read and deleted (no chat records exist in these tests).
fn finishK17Records(f: *Fixture, sync_delete: V) !void {
    const attention = try find(try f.done(sync_delete), "secure_store_delete");
    try expect(std.mem.endsWith(u8, get(attention, "key").string, "/attention"));
    const push = try find(try f.done(attention), "secure_store_delete");
    try expect(std.mem.endsWith(u8, get(push, "key").string, "/push"));
    const index_read = try find(try f.done(push), "secure_store_get");
    try expect(std.mem.endsWith(u8, get(index_read, "key").string, "/chat_index"));
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    const batch = try f.event("secure_store_value", .{ .effect_id = get(index_read, "effect_id").string, .generation = get(index_read, "generation").string, .key = get(index_read, "key").string, .value_base64 = @as(?u8, null), .@"error" = @as(?u8, null) });
    const index_delete = try find(batch, "secure_store_delete");
    try expect(std.mem.endsWith(u8, get(index_delete, "key").string, "/chat_index"));
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    _ = try f.done(index_delete);
}
fn finishRemoval(f: *Fixture, first: V) !void {
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    try expect(f.host.state.auth.token == null and f.host.state.rpc.bearer == null);
    const second = try find(try f.done(first), "secure_store_delete");
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    const third = try find(try f.done(second), "secure_store_delete");
    try expect(std.mem.endsWith(u8, get(third, "key").string, "/sync"));
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    try finishK17Records(f, third);
    try expect(h.eq(f.host.state.auth_state, "signed_out"));
    try expect(f.host.state.auth.pin == null and f.host.state.auth.credential == null);
    try expect(f.host.state.config.https_url == null);
}
test "sign out correlates revoke then waits for both deletes and permits re-pair" {
    var f = try Fixture.init();
    defer f.deinit();
    try readyForRemoval(&f);
    const request = try findUrl(try removal(&f, "sign_out", "out"), "/api/rpc");
    try expect(h.eq(f.host.state.auth_state, "paired"));
    const batch = try revokeResponse(&f, request);
    _ = try find(batch, "cancel_timer");
    try finishRemoval(&f, try find(batch, "secure_store_delete"));
    // A new operation ID on the same profile can start a complete new pairing.
    const probe = try find(try f.event("pair", .{ .intent_id = "pair-again", .link = link, .device_label = "Phone", .client_nonce = "9" ** 32 }), "tls_probe");
    const discovery = try find(try f.event("tls_peer", .{ .effect_id = get(probe, "effect_id").string, .generation = get(probe, "generation").string, .origin = "https://host.example", .spki_sha256 = pin, .system_trusted = true }), "http_request");
    _ = try f.response(discovery, 200, .{ .access_protocol_version = 1, .runtime_id = runtime_id, .instance_id = instance_id, .https_url = "https://host.example", .wss_url = "wss://host.example/ws", .capabilities = .{"access.pair.v1"} });
    const write = try find(try f.event("trust_decision", .{ .intent_id = "trust-again", .proposal_id = f.host.state.auth.proposal.?.id, .accept = true }), "secure_store_put");
    _ = try f.credential(try find(try f.done(write), "http_request"));
    try expect(h.eq(f.host.state.auth_state, "paired"));
}
test "sign out definitively revoked credential wipes without network" {
    var f = try Fixture.init();
    defer f.deinit();
    const mint = try f.credential(try f.exchange(true));
    const again = try find(try f.response(mint, 401, .{}), "http_request");
    _ = try f.response(again, 401, .{});
    try expect(f.host.state.auth.credential_invalid);
    const batch = try removal(&f, "sign_out", "out");
    try no(batch, "http_request");
    try finishRemoval(&f, try find(batch, "secure_store_delete"));
}
test "sign out offline and lost revoke remain unconfirmed until explicit forget" {
    for ([_]bool{ false, true }) |lost| {
        var f = try Fixture.init();
        defer f.deinit();
        try readyForRemoval(&f);
        if (!lost) _ = try f.event("network_changed", .{ .available = false, .network_id = "offline" });
        var batch = try removal(&f, "sign_out", "out");
        if (lost) batch = try f.lost(try findUrl(batch, "/api/rpc"));
        try no(batch, "secure_store_delete");
        try expect(h.eq(f.host.state.host_error.?.code, "sign_out_unconfirmed"));
        try expect(f.host.state.auth.credential != null);
        try finishRemoval(&f, try find(try removal(&f, "forget_host", "forget"), "secure_store_delete"));
    }
}
test "sign out delete failure retries failed record and ignores duplicate acknowledgements" {
    var f = try Fixture.init();
    defer f.deinit();
    try readyForRemoval(&f);
    const first = try find(try removal(&f, "forget_host", "forget"), "secure_store_delete");
    const second = try find(try f.done(first), "secure_store_delete");
    _ = try f.event("secure_store_done", .{ .effect_id = get(second, "effect_id").string, .generation = get(second, "generation").string, .key = get(second, "key").string, .@"error" = .{ .code = "locked" } });
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    try expect(h.eq(f.host.state.host_error.?.code, "sign_out_delete_failed"));
    const retried = try find(try f.event("retry_connection", .{ .intent_id = "retry-delete" }), "secure_store_delete");
    try expect(h.eq(get(retried, "key").string, get(second, "key").string));
    _ = try f.done(second);
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    const sync_record = try find(try f.done(retried), "secure_store_delete");
    try expect(h.eq(f.host.state.auth_state, "signing_out"));
    try finishK17Records(&f, sync_record);
    try expect(h.eq(f.host.state.auth_state, "signed_out"));
}
test "sign out rejects another host and duplicate intent cannot repeat revoke" {
    var f = try Fixture.init();
    defer f.deinit();
    try readyForRemoval(&f);
    try std.testing.expectError(error.InvalidArgument, f.event("sign_out", .{ .intent_id = "wrong", .host_id = "another" }));
    _ = try removal(&f, "sign_out", "out");
    try no(try removal(&f, "sign_out", "out"), "http_request");
    try std.testing.expectError(error.InvalidArgument, f.event("sign_out", .{ .intent_id = "out", .host_id = "another" }));
}

test "sign out repeated unauthorized RPC refresh wipes only after definitive rejection" {
    var f = try Fixture.init();
    defer f.deinit();
    try readyForRemoval(&f);
    const request = try findUrl(try removal(&f, "sign_out", "out"), "/api/rpc");
    const refresh = try findUrl(try f.response(request, 401, .{}), "/auth/access-token");
    try expect(f.host.state.auth.credential != null);
    const retried = try findUrl(try f.token(refresh), "/api/rpc");
    try finishRemoval(&f, try find(try f.response(retried, 401, .{}), "secure_store_delete"));
}

test "forget host still wipes while revoke waits on a failed token refresh" {
    var f = try Fixture.init();
    defer f.deinit();
    try readyForRemoval(&f);
    const request = try findUrl(try removal(&f, "sign_out", "out"), "/api/rpc");
    const refresh = try findUrl(try f.response(request, 401, .{}), "/auth/access-token");
    _ = try f.lost(refresh);
    try expect(f.host.state.auth.removal.rpc_id != null);
    try std.testing.expectError(error.InvalidLifecycle, removal(&f, "sign_out", "out-again"));
    try finishRemoval(&f, try find(try removal(&f, "forget_host", "forget"), "secure_store_delete"));
    for (f.host.state.receipts) |r| {
        if (h.eq(r.operation.intent_id, "out")) try expect(h.eq(r.operation.state, "uncertain"));
        if (h.eq(r.operation.intent_id, "forget")) try expect(h.eq(r.operation.state, "succeeded"));
    }
}
