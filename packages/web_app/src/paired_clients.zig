//! Gateway-owned, bounded store-client identities for authenticated pair sessions.
const std = @import("std");
const auth = @import("auth.zig");
const access = @import("headless").access_protocol;
const protocol = @import("headless").protocol;

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

    /// Called only after method scope and device authorization, for both transports.
    /// Registration parameters are gateway-owned; mutation identities cannot be
    /// borrowed from another session (including an owner browser).
    pub fn forward(self: *Manager, allocator: std.mem.Allocator, io: std.Io, claims: auth.PairClaims, raw: []const u8, daemon: anytype) ![]u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const root = &parsed.value.object;
        const method = root.get("method").?.string;
        if (std.mem.eql(u8, method, "device.push.register") or
            std.mem.eql(u8, method, "device.push.unregister") or
            std.mem.eql(u8, method, "device.push.test"))
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
    for ([_][]const u8{ "device.push.register", "device.push.unregister", "device.push.test" }) |method| {
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
