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
    "companion.roster.put",
    "companion.brain.switch",
    "schedule.create",
    "schedule.update",
    "schedule.delete",
    "schedule.run",
    "voice.provider.configure",
    "device.push.register",
    "device.push.unregister",
    "device.push.test",
    "session.create",
    "session.attach",
    "session.detach",
    "session.write",
    "session.resize",
    "session.kill",
    "session.cleanup",
    "chat.turn.start",
    "chat.links.create",
    "chat.subagent.open",
    "chat.links.clear",
    "chat.tasks.blocked",
    "chat.tasks.resume",
    "chat.tasks.retitle",
    "chat.turn.approve",
    "chat.turn.steer",
    "chat.followup",
    "chat.turn.cancel",
    "chat.turn.consume",
    "chat.shell.run",
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
    "workspace.create",
    "workspace.close",
    "workspace.upsert",
    "workspace.reorder",
    "workspace.repository.upsert",
    "workspace.repository.remove",
    "workspace.repository.default.set",
    "workspace.repository.binding.upsert",
    "workspace.repository.binding.remove",
    "chat.thread.upsert",
    "chat.thread.close",
    "chat.thread.move",
    "chat.thread.archive.set",
    "provider.thread.sync",
    "chat.draft.set",
    "chat.message.append",
    "surface.upsert",
    "surface.clear",
    "notification.chatCompletion.upsert",
    "notification.chatCompletion.clear",
    "config.favoriteModel.set",
    "config.ui.set",
    "config.commit.set",
    // Git commits and pushes change the repository, never automatically.
    "git.changes.commit",
    "git.changes.push",
    "git.changes.pull_push",
    // Owner-only access administration. Lists are included because they
    // transactionally prune bounded terminal records before replying.
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_CREATE,
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_LIST,
    access_protocol.METHOD_DAEMON_PAIRING_GRANT_REVOKE,
    access_protocol.METHOD_DAEMON_DEVICE_LIST,
    access_protocol.METHOD_DAEMON_DEVICE_REVOKE,
    access_protocol.METHOD_DEVICE_LIST,
    access_protocol.METHOD_DEVICE_REVOKE,
    access_protocol.METHOD_DEVICE_SELF_REVOKE,
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
        .mobile = .current(),
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
        .mobile = .current(),
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

test "core.status and core.capabilities payloads carry mobile.min_client and only landed capability names" {
    const allocator = std.testing.allocator;
    for ([_]bool{ true, false }) |store_ready| {
        var ctx = fakeContext();
        ctx.store_ready = store_ready;
        inline for (.{ "core.status", "core.capabilities" }) |method| {
            const response = dispatch(6, method, .null, ctx);
            const encoded = switch (response.body) {
                .status => |result| try protocol.encodeOkResponse(allocator, response.id, result),
                .capabilities => |result| try protocol.encodeOkResponse(allocator, response.id, result),
                .err => return error.TestUnexpectedResult,
            };
            defer allocator.free(encoded);

            var parsed = try protocol.parseResponse(allocator, encoded);
            defer parsed.deinit();
            const result = parsed.response.result.?.object;
            try std.testing.expectEqual(
                @as(i64, protocol.MOBILE_MIN_CLIENT),
                result.get("mobile").?.object.get("min_client").?.integer,
            );
            const advertised = result.get("runtime_capabilities").?.array.items;
            try std.testing.expect(advertised.len > 0);
            for (advertised) |name| {
                for (protocol.PENDING_RUNTIME_CAPABILITY_NAMES) |pending| {
                    try std.testing.expect(!std.mem.eql(u8, name.string, pending));
                }
            }
        }
    }
}
