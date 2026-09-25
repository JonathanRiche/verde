//! Gateway-owned, bounded store-client identities for authenticated pair sessions.
const std = @import("std");
const auth = @import("auth.zig");
const access = @import("headless").access_protocol;
const protocol = @import("headless").protocol;

pub const ACCESS_CAP_NOTICE = "This device is limited to approval-required access. The request was clamped to supervised mode; shell commands require explicit approval.";

pub const Manager = struct {
    const Entry = struct {
        device_id: [32]u8 = @splat(0),
        deadline_ms: i64 = 0,
        target_digest: [32]u8 = @splat(0),
        runtime_id: [32]u8 = @splat(0),
        instance_id: [32]u8 = @splat(0),
        targeted: bool = false,
        client_id: [128]u8 = @splat(0),
        len: usize = 0,
    };
    mutex: std.Io.Mutex = .init,
    entries: [auth.MAX_ACCESS_TOKENS]Entry = @splat(.{}),

    /// Re-read the durable device policy for every execution request. Tokens
    /// carry scopes, never a cached cap that could outlive a policy change.
    pub fn forward(self: *Manager, allocator: std.mem.Allocator, io: std.Io, claims: auth.PairClaims, raw: []const u8, daemon: anytype) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const root = &parsed.value.object;
        const method = root.get("method").?.string;
        const shell = std.mem.eql(u8, method, "chat.shell.run");
        if (!shell and !std.mem.eql(u8, method, "chat.turn.start"))
            return self.forwardUnchecked(allocator, io, claims, raw, daemon);
        const target: ?protocol.RequestTarget = if (root.get("target")) |value|
            protocol.parseRequestTarget(value) catch return self.forwardUnchecked(allocator, io, claims, raw, daemon)
        else
            null;
        const required = access.requiredScopeMaskForRpc(method).?;
        const scopes = try access.scopeNamesAlloc(allocator, required);
        defer allocator.free(scopes);
        const query = try std.json.Stringify.valueAlloc(allocator, .{
            .id = root.get("id") orelse .null,
            .target = target,
            .method = access.METHOD_DAEMON_DEVICE_AUTHORIZE,
            .params = access.DeviceAuthorizeRequest{
                .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
                .device_id = &claims.device_id,
                .required_scopes = scopes,
            },
        }, .{ .emit_null_optional_fields = false });
        defer allocator.free(query);
        const authorized = try daemon.callRaw(query);
        defer allocator.free(authorized.json);
        var response = try std.json.parseFromSlice(std.json.Value, allocator, authorized.json, .{});
        defer response.deinit();
        const result = response.value.object.get("result") orelse return allocator.dupe(u8, authorized.json);
        var policy = try std.json.parseFromValue(access.DeviceAuthorizationResult, allocator, result, .{});
        defer policy.deinit();
        if (policy.value.access_protocol_version != access.ACCESS_PROTOCOL_VERSION or
            !std.mem.eql(u8, policy.value.device_id, &claims.device_id) or
            try access.scopeMask(policy.value.scopes) != required) return error.InvalidDevicePolicy;
        if (policy.value.max_access_mode != .supervised)
            return self.forwardUnchecked(allocator, io, claims, raw, daemon);
        const params = root.getPtr("params") orelse return self.forwardUnchecked(allocator, io, claims, raw, daemon);
        if (params.* != .object) return self.forwardUnchecked(allocator, io, claims, raw, daemon);
        const requested = params.object.get("access_mode") orelse .null;
        // Missing, null and unrecognized values all mean full_access to the daemon.
        const clamped = shell or requested != .string or !std.mem.eql(u8, requested.string, "supervised");
        if (!clamped) return self.forwardUnchecked(allocator, io, claims, raw, daemon);
        if (!shell) try params.object.put(parsed.arena.allocator(), "access_mode", .{ .string = "supervised" });

        // A durable system row makes the policy visible to every client, including
        // reconnects. Its stable key prevents duplicate turn notices on retry.
        const workspace = params.object.get("workspace_id") orelse return error.InvalidCappedRequest;
        const thread = params.object.get("local_thread_id") orelse return error.InvalidCappedRequest;
        if (workspace != .string or thread != .string) return error.InvalidCappedRequest;
        const turn_id = params.object.get("turn_id") orelse .null;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(if (!shell and turn_id == .string) turn_id.string else raw, &digest, .{});
        const key = try std.fmt.allocPrint(allocator, "access-cap:{s}:{s}", .{ claims.device_id, std.fmt.bytesToHex(digest, .lower) });
        defer allocator.free(key);
        const notice = try std.json.Stringify.valueAlloc(allocator, .{
            .id = root.get("id") orelse .null,
            .target = target,
            .method = "chat.message.append",
            .params = .{
                .mutation = .{ .client_id = "gateway", .request_key = key },
                .workspace_id = workspace.string,
                .thread_id = thread.string,
                .message = .{
                    .message_id = key,
                    .role = "system",
                    .author = "Verde",
                    .body = ACCESS_CAP_NOTICE,
                },
            },
        }, .{ .emit_null_optional_fields = false });
        defer allocator.free(notice);
        // Start first so daemon-created threads exist. A retry of the same
        // turn ID is idempotent; if notice persistence fails, return that error
        // and the retry can repair the notice without starting another turn.
        const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(encoded);
        const started = if (!shell) try self.forwardUnchecked(allocator, io, claims, encoded, daemon) else null;
        defer if (started) |value| allocator.free(value);
        if (started) |value| {
            var accepted = try std.json.parseFromSlice(std.json.Value, allocator, value, .{});
            defer accepted.deinit();
            if (accepted.value.object.contains("error")) return allocator.dupe(u8, value);
        }
        var appended = try self.forwardUnchecked(allocator, io, claims, notice, daemon);
        defer allocator.free(appended);
        // Acceptance stages a new thread on the daemon worker. Wait only for
        // that short race; all other persistence failures are returned intact.
        if (started != null) {
            var attempt: usize = 0;
            while (attempt < 40 and try missingNoticeThread(allocator, appended)) : (attempt += 1) {
                try std.Io.sleep(io, .fromMilliseconds(25), .awake);
                const retry = try self.forwardUnchecked(allocator, io, claims, notice, daemon);
                allocator.free(appended);
                appended = retry;
            }
        }
        var receipt = try std.json.parseFromSlice(std.json.Value, allocator, appended, .{});
        defer receipt.deinit();
        if (receipt.value.object.contains("error")) return allocator.dupe(u8, appended);
        if (!receipt.value.object.contains("result")) return error.InvalidNoticeReceipt;
        if (shell) {
            const confirmed = params.object.get("confirmed") orelse .null;
            if (confirmed != .bool or !confirmed.bool) return std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = root.get("id") orelse .null,
                .@"error" = .{
                    .code = @import("headless").store_protocol.ERR_SHELL_CONFIRMATION_REQUIRED,
                    .message = ACCESS_CAP_NOTICE,
                },
            }, .{});
        }
        if (started) |value| return allocator.dupe(u8, value);
        return self.forwardUnchecked(allocator, io, claims, encoded, daemon);
    }

    fn missingNoticeThread(allocator: std.mem.Allocator, raw: []const u8) !bool {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        const err = parsed.value.object.get("error") orelse return false;
        if (err != .object) return false;
        const code = err.object.get("code") orelse return false;
        return code == .string and std.mem.eql(u8, code.string, protocol.ERR_RESOURCE_NOT_FOUND);
    }

    /// Called only after method scope and device authorization, for both transports.
    /// Registration parameters are gateway-owned; mutation identities cannot be
    /// borrowed from another session (including an owner browser).
    fn forwardUnchecked(self: *Manager, allocator: std.mem.Allocator, io: std.Io, claims: auth.PairClaims, raw: []const u8, daemon: anytype) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const root = &parsed.value.object;
        const method = root.get("method").?.string;
        if (std.mem.eql(u8, method, "device.push.register") or
            std.mem.eql(u8, method, "device.push.unregister") or
            std.mem.eql(u8, method, "device.push.test") or
            std.mem.eql(u8, method, access.METHOD_DEVICE_SELF_GET) or
            std.mem.eql(u8, method, access.METHOD_DEVICE_SELF_REVOKE))
        {
            // The private daemon trusts only the gateway's authenticated device
            // identity. Never allow a paired caller to select another phone.
            const arena = parsed.arena.allocator();
            if (!root.contains("params") or root.get("params").? == .null)
                try root.put(arena, "params", .{ .object = .empty });
            const params = root.getPtr("params").?;
            if (params.* != .object) return (try daemon.callRaw(raw)).json;
            try params.object.put(arena, "device_id", .{ .string = &claims.device_id });
            const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
            defer allocator.free(encoded);
            return (try daemon.callRaw(encoded)).json;
        }
        // Unknown fields and object key order are not part of a runtime identity.
        // Let the daemon report malformed envelopes without creating a cache slot.
        const target: ?protocol.RequestTarget = if (root.get("target")) |value|
            protocol.parseRequestTarget(value) catch return (try daemon.callRaw(raw)).json
        else
            null;
        const target_json = try std.json.Stringify.valueAlloc(allocator, target, .{});
        defer allocator.free(target_json);
        var target_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(target_json, &target_digest, .{});
        const register = std.mem.eql(u8, method, "daemon.client.register");
        const writes = access.scopeBit(.chat_write) | access.scopeBit(.repository_write);
        const process_write = (access.requiredScopeMaskForRpc(method) orelse 0) & access.scopeBit(.process_write) != 0;
        // Extra params on a read must not turn read authority into registration.
        if (!register and !process_write and (access.requiredScopeMaskForRpc(method) orelse 0) & writes == 0) return (try daemon.callRaw(raw)).json;
        const params = root.getPtr("params");
        const mutation = if (params) |value| if (value.* == .object) value.object.getPtr("mutation") else null else null;
        // Process ownership lives at params.client_id, not params.mutation.
        if (process_write and (params == null or params.?.* != .object)) return (try daemon.callRaw(raw)).json;
        if (!register and !process_write and (mutation == null or mutation.?.* != .object)) return (try daemon.callRaw(raw)).json;

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        var available: ?*Entry = null;
        var current: ?*Entry = null;
        const now = auth.nowMillis(io);
        for (&self.entries) |*entry| {
            if (entry.len != 0 and entry.deadline_ms <= now) closeEntry(allocator, entry, daemon) catch |err| {
                if (err == error.Canceled) return error.Canceled;
            };
            if (entry.len == 0) {
                available = entry;
            } else if (entry.deadline_ms == claims.deadline_ms and std.mem.eql(u8, &entry.device_id, &claims.device_id) and std.mem.eql(u8, &entry.target_digest, &target_digest)) {
                current = entry;
            }
        }
        const entry = current orelse available orelse return error.TooManyPairedClients;
        if (current == null) {
            // Never forward caller-selected persistence or client identities.
            const registration_request = try std.json.Stringify.valueAlloc(allocator, .{
                .jsonrpc = "2.0",
                .id = root.get("id") orelse .null,
                .target = target,
                .method = "daemon.client.register",
                .params = .{ .persistent = false },
            }, .{ .emit_null_optional_fields = false });
            defer allocator.free(registration_request);
            const registration = try daemon.callRaw(registration_request);
            defer allocator.free(registration.json);
            var response = try std.json.parseFromSlice(std.json.Value, allocator, registration.json, .{ .allocate = .alloc_always });
            defer response.deinit();
            const result = response.value.object.get("result");
            const client = if (result) |value| if (value == .object) value.object.get("client_id") else null else null;
            if (response.value.object.contains("error") or client == null or client.? != .string or client.?.string.len == 0 or client.?.string.len > entry.client_id.len) {
                try response.value.object.put(response.arena.allocator(), "id", root.get("id") orelse .null);
                return std.json.Stringify.valueAlloc(allocator, response.value, .{});
            }
            entry.* = .{ .device_id = claims.device_id, .deadline_ms = claims.deadline_ms, .target_digest = target_digest, .len = client.?.string.len };
            @memcpy(entry.client_id[0..entry.len], client.?.string);
            if (target) |identity| {
                entry.targeted = true;
                @memcpy(&entry.runtime_id, identity.runtime_id);
                @memcpy(&entry.instance_id, identity.instance_id);
            }
        }
        const client_id = entry.client_id[0..entry.len];
        if (register) return std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = root.get("id") orelse .null,
            .result = .{ .client_id = client_id, .persistent = false },
        }, .{});
        if (process_write) {
            try params.?.object.put(parsed.arena.allocator(), "client_id", .{ .string = client_id });
        } else {
            try mutation.?.object.put(parsed.arena.allocator(), "client_id", .{ .string = client_id });
        }
        const encoded = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        defer allocator.free(encoded);
        return (try daemon.callRaw(encoded)).json;
    }

    /// Close expired identities, retaining failed closes for bounded retries.
    pub fn reap(self: *Manager, allocator: std.mem.Allocator, io: std.Io, daemon: anytype) !void {
        try self.closeMatching(allocator, io, daemon, null, false);
    }

    pub fn closeDevice(self: *Manager, allocator: std.mem.Allocator, io: std.Io, daemon: anytype, device_id: []const u8) !void {
        try self.closeMatching(allocator, io, daemon, device_id, false);
    }

    pub fn closeAll(self: *Manager, allocator: std.mem.Allocator, io: std.Io, daemon: anytype) !void {
        const previous = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous);
        const Cleanup = struct {
            fn run(manager: *Manager, alloc: std.mem.Allocator, task_io: std.Io, client: @TypeOf(daemon)) anyerror!void {
                return manager.closeMatching(alloc, task_io, client, null, true);
            }
            fn timeout(task_io: std.Io) void {
                std.Io.sleep(task_io, .fromMilliseconds(2_000), .awake) catch {};
            }
        };
        const Result = union(enum) { closed: anyerror!void, timeout: void };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(io, &results);
        defer select.cancelDiscard();
        try select.concurrent(.timeout, Cleanup.timeout, .{io});
        try select.concurrent(.closed, Cleanup.run, .{ self, allocator, io, daemon });
        switch (try select.await()) {
            .closed => |result| try result,
            .timeout => return error.CloseTimedOut,
        }
    }

    fn closeMatching(self: *Manager, allocator: std.mem.Allocator, io: std.Io, daemon: anytype, device_id: ?[]const u8, all: bool) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const now = auth.nowMillis(io);
        // Invalidate every selected identity before I/O: cancellation of one
        // close must not leave later identities eligible for reuse.
        for (&self.entries) |*entry| {
            if (entry.len != 0 and (all or entry.deadline_ms <= now or (if (device_id) |id| std.mem.eql(u8, &entry.device_id, id) else false))) entry.deadline_ms = 0;
        }
        var failed = false;
        for (&self.entries) |*entry| {
            if (entry.len == 0 or entry.deadline_ms != 0) continue;
            closeEntry(allocator, entry, daemon) catch |err| {
                // Io cancellation is delivered once; swallowing it could
                // block forever on the next close after the shutdown deadline.
                if (err == error.Canceled) return error.Canceled;
                failed = true;
            };
        }
        if (failed) return error.CloseRejected;
    }

    fn closeEntry(allocator: std.mem.Allocator, entry: *Entry, daemon: anytype) !void {
        const target: ?protocol.RequestTarget = if (entry.targeted) .{ .runtime_id = &entry.runtime_id, .instance_id = &entry.instance_id } else null;
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = 0,
            .target = target,
            .method = "daemon.client.close",
            .params = .{ .client_id = entry.client_id[0..entry.len] },
        }, .{ .emit_null_optional_fields = false });
        defer allocator.free(request);
        const response = try daemon.callRaw(request);
        defer allocator.free(response.json);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidCloseResponse;
        if (parsed.value.object.get("error")) |err| {
            const code = if (err == .object) err.object.get("code") else null;
            if (code == null or code.? != .string) return error.InvalidCloseResponse;
            // A gone client or replaced daemon generation needs no further close.
            if (!std.mem.eql(u8, code.?.string, "resource_not_found") and
                !std.mem.eql(u8, code.?.string, protocol.ERR_RUNTIME_IDENTITY_MISMATCH)) return error.CloseRejected;
        } else if (!parsed.value.object.contains("result")) return error.InvalidCloseResponse;
        entry.* = .{};
    }
};

test "paired registrations are nonpersistent cached and mutations use the authenticated session identity" {
    const FakeDaemon = struct {
        registrations: usize = 0,
        pub fn callRaw(self: *@This(), raw: []const u8) !@import("daemon.zig").CallResult {
            var request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
            defer request.deinit();
            if (std.mem.eql(u8, request.value.object.get("method").?.string, "daemon.client.register")) {
                try std.testing.expect(!request.value.object.get("params").?.object.get("persistent").?.bool);
                self.registrations += 1;
                return .{ .json = try std.fmt.allocPrint(std.testing.allocator, "{{\"result\":{{\"client_id\":\"registered-{d}\"}}}}", .{self.registrations}) };
            }
            return .{ .json = try std.testing.allocator.dupe(u8, raw) };
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager: Manager = .{};
    var daemon: FakeDaemon = .{};
    const claims: auth.PairClaims = .{ .device_id = @splat('a'), .scope_mask = 0xffff, .deadline_ms = auth.nowMillis(io) + 60_000 };
    const registered = try manager.forward(allocator, io, claims, "{\"id\":7,\"method\":\"daemon.client.register\",\"params\":{\"persistent\":true}}", &daemon);
    defer allocator.free(registered);
    try std.testing.expect(std.mem.indexOf(u8, registered, "registered-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, registered, "\"persistent\":false") != null);
    const raw = "{\"id\":8,\"method\":\"chat.thread.archive.set\",\"params\":{\"mutation\":{\"client_id\":\"someone-else\",\"request_key\":\"k\",\"expected_store_revision\":9}}}";
    const forwarded = try manager.forward(allocator, io, claims, raw, &daemon);
    defer allocator.free(forwarded);
    try std.testing.expect(std.mem.indexOf(u8, forwarded, "registered-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, forwarded, "someone-else") == null);
    try std.testing.expect(std.mem.indexOf(u8, forwarded, "\"expected_store_revision\":9") != null);
    var other = claims;
    other.device_id = @splat('b');
    const separate = try manager.forward(allocator, io, other, raw, &daemon);
    defer allocator.free(separate);
    try std.testing.expect(std.mem.indexOf(u8, separate, "registered-2") != null);
    try std.testing.expectEqual(@as(usize, 2), daemon.registrations);
    const read = try manager.forward(allocator, io, other, "{\"id\":9,\"method\":\"chat.thread.list\",\"params\":{\"mutation\":{\"client_id\":\"ignored\"}}}", &daemon);
    defer allocator.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "ignored") != null);
    try std.testing.expectEqual(@as(usize, 2), daemon.registrations);
}

test "paired registration rejection propagates without caching or forwarding a mutation" {
    const FakeDaemon = struct {
        calls: usize = 0,
        pub fn callRaw(self: *@This(), raw: []const u8) !@import("daemon.zig").CallResult {
            self.calls += 1;
            var request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
            defer request.deinit();
            try std.testing.expectEqualStrings("daemon.client.register", request.value.object.get("method").?.string);
            try std.testing.expectEqualStrings("b" ** 32, request.value.object.get("target").?.object.get("instance_id").?.string);
            return .{ .json = try std.testing.allocator.dupe(u8, "{\"id\":99,\"error\":{\"code\":\"invalid_state\",\"message\":\"draining\"}}") };
        }
    };
    var manager: Manager = .{};
    var daemon: FakeDaemon = .{};
    const claims: auth.PairClaims = .{ .device_id = @splat('a'), .scope_mask = 0xffff, .deadline_ms = auth.nowMillis(std.testing.io) + 60_000 };
    const raw = "{\"id\":7,\"target\":{\"runtime_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"instance_id\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"method\":\"workspace.upsert\",\"params\":{\"mutation\":{\"client_id\":\"forged\"}}}";
    for (0..2) |_| {
        const response = try manager.forward(std.testing.allocator, std.testing.io, claims, raw, &daemon);
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "draining") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), daemon.calls);
}

test "paired identities canonicalize targets and close on expiry revocation and shutdown" {
    const FakeDaemon = struct {
        registrations: usize = 0,
        closes: usize = 0,
        unavailable: bool = false,
        pub fn callRaw(self: *@This(), raw: []const u8) !@import("daemon.zig").CallResult {
            var request = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
            defer request.deinit();
            const method = request.value.object.get("method").?.string;
            if (std.mem.eql(u8, method, "daemon.client.register")) {
                self.registrations += 1;
                return .{ .json = try std.fmt.allocPrint(std.testing.allocator, "{{\"result\":{{\"client_id\":\"registered-{d}\"}}}}", .{self.registrations}) };
            }
            try std.testing.expectEqualStrings("daemon.client.close", method);
            if (self.unavailable) return error.Unavailable;
            const target = try protocol.parseRequestTarget(request.value.object.get("target").?);
            try std.testing.expectEqualStrings("a" ** 32, target.runtime_id);
            try std.testing.expectEqualStrings("b" ** 32, target.instance_id);
            self.closes += 1;
            return .{ .json = try std.testing.allocator.dupe(u8, "{\"result\":{}}") };
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var manager: Manager = .{};
    var daemon: FakeDaemon = .{};
    const claims: auth.PairClaims = .{ .device_id = @splat('a'), .scope_mask = 0xffff, .deadline_ms = auth.nowMillis(io) + 60_000 };
    const requests = [_][]const u8{
        \\{"id":1,"method":"daemon.client.register","target":{"runtime_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","instance_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
        ,
        \\{"id":2,"method":"daemon.client.register","target":{"extra":"ignored","instance_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","runtime_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}
        ,
    };
    for (requests) |raw| {
        const response = try manager.forward(allocator, io, claims, raw, &daemon);
        allocator.free(response);
    }
    try std.testing.expectEqual(@as(usize, 1), daemon.registrations);
    for (&manager.entries) |*entry| if (entry.len != 0) {
        entry.deadline_ms = 0;
    };
    daemon.unavailable = true;
    try std.testing.expectError(error.CloseRejected, manager.reap(allocator, io, &daemon));
    var retained: usize = 0;
    for (manager.entries) |entry| {
        if (entry.len != 0) retained += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), retained);
    daemon.unavailable = false;
    try manager.reap(allocator, io, &daemon);
    try std.testing.expectEqual(@as(usize, 1), daemon.closes);
    for (0..2) |index| {
        const response = try manager.forward(allocator, io, claims, requests[0], &daemon);
        allocator.free(response);
        if (index == 0) {
            daemon.unavailable = true;
            try std.testing.expectError(error.CloseRejected, manager.closeDevice(allocator, io, &daemon, &claims.device_id));
            for (manager.entries) |entry| {
                if (entry.len != 0) try std.testing.expectEqual(@as(i64, 0), entry.deadline_ms);
            }
            daemon.unavailable = false;
            try manager.reap(allocator, io, &daemon);
        } else try manager.closeAll(allocator, io, &daemon);
    }
    try std.testing.expectEqual(@as(usize, 3), daemon.closes);
    for (manager.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.len);
}

test "paired shutdown cleanup cancels an unresponsive daemon within its deadline" {
    const FakeDaemon = struct {
        canceled: bool = false,
        pub fn callRaw(self: *@This(), _: []const u8) !@import("daemon.zig").CallResult {
            std.Io.sleep(std.testing.io, .fromMilliseconds(60_000), .awake) catch |err| {
                self.canceled = true;
                return err;
            };
            return error.UnexpectedCompletion;
        }
    };
    var manager: Manager = .{};
    manager.entries[0] = .{ .len = 1, .client_id = @splat('x') };
    manager.entries[1] = .{ .len = 1, .client_id = @splat('y'), .deadline_ms = auth.nowMillis(std.testing.io) + 60_000 };
    var daemon: FakeDaemon = .{};
    try std.testing.expectError(error.CloseTimedOut, manager.closeAll(std.testing.allocator, std.testing.io, &daemon));
    try std.testing.expect(daemon.canceled);
    try std.testing.expectEqual(@as(usize, 1), manager.entries[0].len);
    try std.testing.expectEqual(@as(usize, 1), manager.entries[1].len);
    try std.testing.expectEqual(@as(i64, 0), manager.entries[1].deadline_ms);
}

test "push RPC forwarding binds every operation to the authenticated device" {
    const FakeDaemon = struct {
        pub fn callRaw(_: *@This(), raw: []const u8) !struct { json: []u8 } {
            return .{ .json = try std.testing.allocator.dupe(u8, raw) };
        }
    };
    const a = std.testing.allocator;
    var manager: Manager = .{};
    var daemon: FakeDaemon = .{};
    const claims: auth.PairClaims = .{ .device_id = @splat('a'), .scope_mask = access.scopeBit(.device_write), .deadline_ms = auth.nowMillis(std.testing.io) + 60000 };
    for ([_][]const u8{ "device.push.register", "device.push.unregister", "device.push.test", access.METHOD_DEVICE_SELF_GET, access.METHOD_DEVICE_SELF_REVOKE }) |method| {
        const raw = try std.json.Stringify.valueAlloc(a, .{ .id = 1, .method = method, .params = .{ .device_id = "forged-other-phone", .platform = "android", .send_token = "fixture", .public_key = "fixture" } }, .{});
        defer a.free(raw);
        const forwarded = try manager.forward(a, std.testing.io, claims, raw, &daemon);
        defer a.free(forwarded);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, forwarded, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(&claims.device_id, parsed.value.object.get("params").?.object.get("device_id").?.string);
        try std.testing.expectEqualStrings(method, parsed.value.object.get("method").?.string);
    }
    const no_params = try manager.forward(a, std.testing.io, claims, "{\"id\":1,\"method\":\"device.push.unregister\"}", &daemon);
    defer a.free(no_params);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, no_params, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(&claims.device_id, parsed.value.object.get("params").?.object.get("device_id").?.string);
}

test "paired execution clamps defaults and elevated modes with durable notices and shell approval" {
    const FakeDaemon = struct {
        cap: ?access.AccessMode = .supervised,
        notices: usize = 0,
        executions: usize = 0,
        fail_notice: bool = false,
        missing_thread_once: bool = true,
        reject_device: bool = false,
        last_notice: [128]u8 = @splat(0),
        last_notice_len: usize = 0,
        pub fn callRaw(self: *@This(), raw: []const u8) !struct { json: []u8 } {
            const a = std.testing.allocator;
            var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
            defer parsed.deinit();
            const root = parsed.value.object;
            const method = root.get("method").?.string;
            const params = root.get("params").?.object;
            if (std.mem.eql(u8, method, access.METHOD_DAEMON_DEVICE_AUTHORIZE)) {
                try std.testing.expectEqualStrings("a" ** 32, params.get("device_id").?.string);
                if (self.reject_device) return .{ .json = try a.dupe(u8, "{\"error\":{\"code\":\"authentication_rejected\"}}") };
                return .{ .json = try std.json.Stringify.valueAlloc(a, .{ .result = .{ .access_protocol_version = 1, .device_id = "a" ** 32, .scopes = params.get("required_scopes").?, .max_access_mode = self.cap } }, .{}) };
            }
            if (std.mem.eql(u8, method, "daemon.client.register")) return .{ .json = try a.dupe(u8, "{\"result\":{\"client_id\":\"fixture\"}}") };
            if (std.mem.eql(u8, method, "chat.message.append")) {
                self.notices += 1;
                const key = params.get("message").?.object.get("message_id").?.string;
                self.last_notice_len = key.len;
                @memcpy(self.last_notice[0..key.len], key);
                if (self.missing_thread_once) {
                    self.missing_thread_once = false;
                    return .{ .json = try a.dupe(u8, "{\"error\":{\"code\":\"resource_not_found\"}}") };
                }
                try std.testing.expectEqualStrings("fixture", params.get("mutation").?.object.get("client_id").?.string);
                try std.testing.expectEqualStrings("system", params.get("message").?.object.get("role").?.string);
                try std.testing.expectEqualStrings(ACCESS_CAP_NOTICE, params.get("message").?.object.get("body").?.string);
                return .{ .json = try a.dupe(u8, if (self.fail_notice) "{\"error\":{\"code\":\"store_unavailable\"}}" else "{\"result\":{\"applied\":true}}") };
            }
            self.executions += 1;
            return .{ .json = try a.dupe(u8, raw) };
        }
    };
    const a = std.testing.allocator;
    const claims: auth.PairClaims = .{ .device_id = @splat('a'), .scope_mask = 0xffff, .deadline_ms = auth.nowMillis(std.testing.io) + 60000 };
    var manager: Manager = .{};
    var daemon: FakeDaemon = .{};
    for ([_][]const u8{ "", ",\"access_mode\":null", ",\"access_mode\":\"full_access\"", ",\"access_mode\":\"unknown\"", ",\"access_mode\":42", ",\"access_mode\":\"supervised\"" }, 0..) |mode, index| {
        const raw = try std.fmt.allocPrint(a, "{{\"id\":1,\"method\":\"chat.turn.start\",\"params\":{{\"workspace_id\":\"ws\",\"local_thread_id\":\"thread\",\"turn_id\":\"turn-{d}\"{s}}}}}", .{ index, mode });
        defer a.free(raw);
        const forwarded = try manager.forward(a, std.testing.io, claims, raw, &daemon);
        defer a.free(forwarded);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, forwarded, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("supervised", parsed.value.object.get("params").?.object.get("access_mode").?.string);
    }
    try std.testing.expectEqual(@as(usize, 6), daemon.notices);
    try std.testing.expectEqual(@as(usize, 6), daemon.executions);
    for ([_]bool{ false, true }) |confirmed| {
        const raw = try std.json.Stringify.valueAlloc(a, .{ .id = 2, .method = "chat.shell.run", .params = .{ .workspace_id = "ws", .local_thread_id = "thread", .command = "pwd", .confirmed = confirmed } }, .{});
        defer a.free(raw);
        const response = try manager.forward(a, std.testing.io, claims, raw, &daemon);
        defer a.free(response);
        if (!confirmed) try std.testing.expect(std.mem.indexOf(u8, response, "confirmation_required") != null);
    }
    try std.testing.expectEqual(@as(usize, 7), daemon.executions);
    const raw = "{\"id\":3,\"method\":\"chat.turn.start\",\"params\":{\"workspace_id\":\"ws\",\"local_thread_id\":\"thread\",\"turn_id\":\"last\",\"access_mode\":\"full_access\"}}";
    daemon.fail_notice = true;
    const failed = try manager.forward(a, std.testing.io, claims, raw, &daemon);
    defer a.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "store_unavailable") != null);
    try std.testing.expectEqual(@as(usize, 8), daemon.executions);
    const failed_key = daemon.last_notice;
    const failed_key_len = daemon.last_notice_len;
    daemon.fail_notice = false;
    const repaired = try manager.forward(a, std.testing.io, claims, raw, &daemon);
    defer a.free(repaired);
    try std.testing.expectEqualStrings(failed_key[0..failed_key_len], daemon.last_notice[0..daemon.last_notice_len]);
    daemon.reject_device = true;
    const rejected = try manager.forward(a, std.testing.io, claims, raw, &daemon);
    defer a.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "authentication_rejected") != null);
    try std.testing.expectEqual(@as(usize, 9), daemon.executions);
    daemon.reject_device = false;
    daemon.cap = null;
    const uncapped = try manager.forward(a, std.testing.io, claims, raw, &daemon);
    defer a.free(uncapped);
    try std.testing.expectEqualStrings(raw, uncapped);
    try std.testing.expectEqual(@as(usize, 10), daemon.executions);
}
