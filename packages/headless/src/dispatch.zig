//! Transport-independent headless method dispatcher.
//!
//! Takes method + params + a small context filled by the daemon host. Imports no
//! daemon code so the headless package stays free of SDL/Palette/sessionizer.

const std = @import("std");
const protocol = @import("protocol.zig");
const access_protocol = @import("access_protocol.zig");
const connect_protocol = @import("connect_protocol.zig");
const attachment_protocol = @import("attachment_protocol.zig");

/// Methods that must be refused once the daemon has entered its drain phase.
///
/// Full store mutation surface (S3). daemon.storeStatus is a read, not a mutator.
const MUTATING_METHODS = [_][]const u8{
    // Sessionizer-owned mutations.
    "session.create",
    "session.attach",
    "session.detach",
    "session.write",
    "session.resize",
    "session.kill",
    "session.cleanup",
    "chat.turn.start",
    "chat.turn.approve",
    "chat.turn.steer",
    "chat.followup",
    "chat.turn.cancel",
    "chat.turn.consume",
    attachment_protocol.METHOD_CHAT_ATTACHMENT_CREATE,
    attachment_protocol.METHOD_CHAT_ATTACHMENT_APPEND,
    attachment_protocol.METHOD_CHAT_ATTACHMENT_COMMIT,
    // Registry mutations.
    "process.start",
    "process.stop",
    "process.restart",
    "lease.acquire",
    "lease.renew",
    "lease.release",
    "daemon.client.register",
    "daemon.client.heartbeat",
    "daemon.client.close",
    "daemon.stop",
    // Full store mutation surface.
    "state.snapshot.replace",
    "workspace.upsert",
    "workspace.repository.upsert",
    "workspace.repository.remove",
    "workspace.repository.default.set",
    "workspace.repository.binding.upsert",
    "workspace.repository.binding.remove",
    "chat.thread.upsert",
    "chat.thread.close",
    "provider.thread.sync",
    "chat.draft.set",
    "chat.message.append",
    "surface.upsert",
    "surface.clear",
    "notification.chatCompletion.upsert",
    "notification.chatCompletion.clear",
    "config.favoriteModel.set",
    // Owner-only access administration. Lists are included because they
    // transactionally prune bounded terminal records before replying.
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_CREATE,
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_LIST,
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_REVOKE,
    access_protocol.METHOD_DAEMON_DEVICE_LIST,
    access_protocol.METHOD_DAEMON_DEVICE_REVOKE,
    connect_protocol.METHOD_LOGIN,
    connect_protocol.METHOD_LINK,
    connect_protocol.METHOD_UNLINK,
    connect_protocol.METHOD_LOGOUT,
    connect_protocol.METHOD_BOOTSTRAP_CONSUME,
};

/// Return whether a method changes daemon-owned state.
pub fn isMutatingMethod(method: []const u8) bool {
    for (MUTATING_METHODS) |candidate| {
        if (std.mem.eql(u8, method, candidate)) return true;
    }
    return false;
}

/// Daemon-filled snapshot for core.* methods. No pointers into daemon types.
pub const Context = struct {
    runtime_id: []const u8 = "",
    instance_id: []const u8 = "",
    server_version: []const u8 = "",
    pid: u32,
    sessionizer_protocol_version: u32,
    session_count: usize,
    chat_turn_count: usize,
    store_ready: bool = false,
};

/// Dispatcher outcome: structured result payloads or a stable protocol error.
pub const Response = struct {
    id: u64,
    body: Body,

    pub const Body = union(enum) {
        status: protocol.StatusResult,
        capabilities: protocol.CapabilitiesResult,
        err: protocol.Error,
    };

    pub fn isOk(self: Response) bool {
        return switch (self.body) {
            .err => false,
            else => true,
        };
    }
};

/// Dispatch a core.* (or other headless) method. Unknown methods return unknown_method.
pub fn dispatch(
    id: u64,
    method: []const u8,
    params: std.json.Value,
    ctx: Context,
) Response {
    if (!paramsAreAcceptable(params)) {
        return .{
            .id = id,
            .body = .{ .err = .{
                .code = protocol.ERR_INVALID_PARAMS,
                .message = "params must be an object or null",
            } },
        };
    }

    if (std.mem.eql(u8, method, "core.status")) {
        return .{
            .id = id,
            .body = .{ .status = buildStatus(ctx) },
        };
    }
    if (std.mem.eql(u8, method, "core.capabilities")) {
        return .{
            .id = id,
            .body = .{ .capabilities = buildCapabilities(ctx) },
        };
    }
    // Q8: these names are wire-reserved but explicitly undispatched through
    // all of M5. Use the host dispatch spelling so callers cannot mistake a
    // reserved push contract for the generic core extension namespace.
    if (std.mem.eql(u8, method, "core.subscribe") or
        std.mem.eql(u8, method, "core.unsubscribe"))
    {
        return .{
            .id = id,
            .body = .{ .err = .{
                .code = "method_not_found",
                .message = method,
            } },
        };
    }

    return .{
        .id = id,
        .body = .{ .err = .{
            .code = protocol.ERR_UNKNOWN_METHOD,
            .message = "unknown method",
        } },
    };
}

fn buildStatus(ctx: Context) protocol.StatusResult {
    return .{
        .runtime_id = ctx.runtime_id,
        .instance_id = ctx.instance_id,
        .server_version = ctx.server_version,
        .protocol = .{},
        .runtime_capabilities = runtimeCapabilities(ctx.store_ready),
        .limits = .{},
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .protocol_version = ctx.sessionizer_protocol_version,
        .pid = ctx.pid,
        .session_count = ctx.session_count,
        .chat_turn_count = ctx.chat_turn_count,
        .capabilities = capabilities(ctx.store_ready),
    };
}

fn buildCapabilities(ctx: Context) protocol.CapabilitiesResult {
    return .{
        .runtime_id = ctx.runtime_id,
        .instance_id = ctx.instance_id,
        .server_version = ctx.server_version,
        .protocol = .{},
        .runtime_capabilities = runtimeCapabilities(ctx.store_ready),
        .limits = .{},
        .headless_protocol_version = protocol.HEADLESS_PROTOCOL_VERSION,
        .min_supported = protocol.MIN_SUPPORTED_PROTOCOL_VERSION,
        .max_supported = protocol.MAX_SUPPORTED_PROTOCOL_VERSION,
        .capabilities = capabilities(ctx.store_ready),
    };
}

fn capabilities(store_ready: bool) protocol.Capabilities {
    var result: protocol.Capabilities = .phase1();
    result.store = store_ready;
    result.repository_manifests = store_ready;
    return result;
}

fn runtimeCapabilities(store_ready: bool) []const []const u8 {
    return if (store_ready)
        &protocol.RUNTIME_CAPABILITY_NAMES
    else
        &protocol.RUNTIME_CAPABILITY_NAMES_BASE;
}

/// Params may be null or an object; unknown object fields are ignored by callers.
fn paramsAreAcceptable(params: std.json.Value) bool {
    return switch (params) {
        .null, .object => true,
        else => false,
    };
}

fn fakeContext() Context {
    return .{
        .runtime_id = "runtime-test",
        .instance_id = "instance-test",
        .server_version = "test",
        .pid = 4242,
        .sessionizer_protocol_version = 18,
        .session_count = 3,
        .chat_turn_count = 5,
        .store_ready = true,
    };
}

test "core.status happy path with fake context" {
    const response = dispatch(1, "core.status", .null, fakeContext());
    try std.testing.expect(response.isOk());
    const status = response.body.status;
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, status.headless_protocol_version);
    try std.testing.expectEqual(protocol.MIN_SUPPORTED_PROTOCOL_VERSION, status.min_supported);
    try std.testing.expectEqual(protocol.MAX_SUPPORTED_PROTOCOL_VERSION, status.max_supported);
    try std.testing.expectEqual(@as(u32, 18), status.protocol_version);
    try std.testing.expectEqual(@as(u32, 4242), status.pid);
    try std.testing.expectEqual(@as(usize, 3), status.session_count);
    try std.testing.expectEqual(@as(usize, 5), status.chat_turn_count);
    try std.testing.expectEqualStrings("runtime-test", status.runtime_id);
    try std.testing.expectEqualStrings("instance-test", status.instance_id);
    try std.testing.expectEqualStrings("test", status.server_version);
    try std.testing.expect(status.capabilities.terminal_raw);
    // M4-P5 flip: chat is advertised in the same commit that routes the
    // MCP/CLI chat tools daemon-direct (was pinned false through M4-P4).
    try std.testing.expect(status.capabilities.chat);
    try std.testing.expect(status.capabilities.snapshots);
    try std.testing.expect(status.capabilities.changes);
    try std.testing.expect(!status.capabilities.subscriptions);
    try std.testing.expect(!status.capabilities.terminal_grid);
    try std.testing.expect(!status.capabilities.processes);
    try std.testing.expect(!status.capabilities.leases);
    try std.testing.expect(!status.capabilities.browser_execution);
    try std.testing.expect(!status.capabilities.browser_presentation);
    try std.testing.expect(!status.capabilities.browser.available);
    try std.testing.expect(!status.capabilities.isFeatureAvailable(.browser_navigation));
}

test "core.capabilities content" {
    var empty_object: std.json.ObjectMap = .empty;
    defer empty_object.deinit(std.testing.allocator);
    // Object with no fields — and any future fields would be ignored by dispatch.
    const params: std.json.Value = .{ .object = empty_object };
    const response = dispatch(2, "core.capabilities", params, fakeContext());
    try std.testing.expect(response.isOk());
    const caps = response.body.capabilities;
    try std.testing.expectEqual(protocol.HEADLESS_PROTOCOL_VERSION, caps.headless_protocol_version);
    try std.testing.expectEqual(protocol.MIN_SUPPORTED_PROTOCOL_VERSION, caps.min_supported);
    try std.testing.expectEqual(protocol.MAX_SUPPORTED_PROTOCOL_VERSION, caps.max_supported);
    try std.testing.expect(caps.capabilities.terminal_raw);
    // M4-P5 flip: buildCapabilities advertises chat with the MCP/CLI flip.
    try std.testing.expect(caps.capabilities.chat);
    // M5-P5: both already-routed read surfaces advertise atomically.
    try std.testing.expect(caps.capabilities.snapshots);
    try std.testing.expect(caps.capabilities.changes);
    try std.testing.expect(caps.capabilities.workspace_pagination);
    try std.testing.expect(caps.capabilities.thread_pagination);
    try std.testing.expect(caps.capabilities.message_pagination);
    try std.testing.expect(caps.capabilities.provider_status);
    try std.testing.expect(caps.capabilities.repository_projection);
    try std.testing.expect(caps.capabilities.repository_manifests);
    // Q8 is unconditional: reserved push names remain undispatched.
    try std.testing.expect(!caps.capabilities.subscriptions);
    try std.testing.expect(!caps.capabilities.browser_presentation);
    try std.testing.expect(!caps.capabilities.browser.available);
    try std.testing.expect(!caps.capabilities.isFeatureAvailable(.browser_screenshot));
}

test "unknown method yields unknown_method" {
    const response = dispatch(3, "core.snapshot", .null, fakeContext());
    try std.testing.expect(!response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_UNKNOWN_METHOD, response.body.err.code);
}

test "M5-P5 snapshot and changes are reads while push names stay reserved" {
    try std.testing.expect(!isMutatingMethod("core.snapshot"));
    try std.testing.expect(!isMutatingMethod("core.changes"));
    try std.testing.expect(!isMutatingMethod("core.subscribe"));
    try std.testing.expect(!isMutatingMethod("core.unsubscribe"));

    // This transport-independent dispatcher does not own the store-backed
    // handlers; importantly it also does not dispatch either reserved name.
    inline for (.{ "core.subscribe", "core.unsubscribe" }) |method| {
        const response = dispatch(30, method, .null, fakeContext());
        try std.testing.expect(!response.isOk());
        try std.testing.expectEqualStrings("method_not_found", response.body.err.code);
    }
}

test "invalid params yields invalid_params" {
    const response = dispatch(4, "core.status", .{ .string = "nope" }, fakeContext());
    try std.testing.expect(!response.isOk());
    try std.testing.expectEqualStrings(protocol.ERR_INVALID_PARAMS, response.body.err.code);
}

test "params object with unknown fields is accepted" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "future_field", .{ .bool = true });
    const response = dispatch(5, "core.status", .{ .object = obj }, fakeContext());
    try std.testing.expect(response.isOk());
}

test "shared mutator table pins the current sessionizer methods" {
    const sessionizer_mutators = [_][]const u8{
        "session.create",
        "session.attach",
        "session.detach",
        "session.write",
        "session.resize",
        "session.kill",
        "session.cleanup",
        "chat.turn.start",
        "chat.turn.approve",
        "chat.turn.steer",
        "chat.followup",
        "chat.turn.cancel",
        "chat.turn.consume",
        "chat.attachment.create",
        "chat.attachment.append",
        "chat.attachment.commit",
    };
    for (sessionizer_mutators) |method| {
        try std.testing.expect(isMutatingMethod(method));
    }

    const registry_mutators = [_][]const u8{
        "process.start",
        "process.stop",
        "process.restart",
        "lease.acquire",
        "lease.renew",
        "lease.release",
        "daemon.client.register",
        "daemon.client.heartbeat",
        "daemon.client.close",
        "daemon.stop",
    };
    for (registry_mutators) |method| {
        try std.testing.expect(isMutatingMethod(method));
    }
}

test "reads are not mutators and store mutators drain" {
    const reads = [_][]const u8{
        "session.list",
        "session.inspect",
        "session.tail",
        "session.tail.batch",
        "session.screen",
        "chat.turn.list",
        "chat.turn.tail",
        "status",
        "core.status",
        "core.capabilities",
        "process.list",
        "process.inspect",
        "process.logs",
        "process.wait",
        "lease.check",
        "daemon.notifications",
        "workspace.resolve",
        "daemon.prepareShutdown",
        "daemon.storeStatus",
        "workspace.list",
        "workspace.repository.manifest.get",
        "chat.thread.list",
        "chat.message.list",
        "providers.status",
    };
    for (reads) |method| {
        try std.testing.expect(!isMutatingMethod(method));
    }

    // Full store mutation surface must drain with the rest of the mutator set.
    const store_mutators = [_][]const u8{
        "state.snapshot.replace",
        "workspace.upsert",
        "workspace.repository.upsert",
        "workspace.repository.remove",
        "workspace.repository.default.set",
        "workspace.repository.binding.upsert",
        "workspace.repository.binding.remove",
        "chat.thread.upsert",
    "chat.thread.close",
        "provider.thread.sync",
        "chat.draft.set",
        "chat.message.append",
        "surface.upsert",
        "surface.clear",
        "notification.chatCompletion.upsert",
        "notification.chatCompletion.clear",
        "config.favoriteModel.set",
    };
    for (store_mutators) |method| {
        try std.testing.expect(isMutatingMethod(method));
    }
}
