//! Owner-only local-daemon phone pairing. Secrets live only in this transient state.
const std = @import("std");
const headless = @import("headless");
const access = headless.access_protocol;
const daemon = @import("../daemon/client.zig");
const clock = @import("platform_runtime");
const allocator = std.heap.page_allocator;

pub const PAIRING_PRESETS = access.PAIRING_PRESETS;

pub fn presetLabel(preset: ?access.PairingPreset) []const u8 {
    return if (preset) |value| switch (value) {
        .full => "Full",
        .chat => "Chat",
        .monitor => "Monitor",
    } else "Custom / legacy";
}

pub fn presetDescription(preset: access.PairingPreset) []const u8 {
    return switch (preset) {
        .full => "All permissions, including terminal, repository and process writes. No access-mode cap.",
        .chat => "Chat with supervised access; read terminals and repositories; receive push notifications.",
        .monitor => "Read-only chats, terminals, repositories and processes; receive push notifications.",
    };
}

pub fn accessModeLabel(mode: ?access.AccessMode) []const u8 {
    return if (mode) |value| switch (value) {
        .supervised => "Supervised",
        .full_access => "Full access",
    } else "No cap";
}

pub const Operation = enum { list, create, revoke };
pub const State = struct {
    host: [2048]u8 = @splat(0),
    host_len: usize = 0,
    opened: bool = false,
    preset: access.PairingPreset = .full,
    notice: []const u8 = "Devices paired with this machine.",
    pending: ?*Job = null,
    devices_result: ?*Job = null,
    grant: ?*Job = null,
    discard_grant: bool = false,
    last_second: i64 = -1,
    confirm_revoke: ?usize = null,

    pub fn deinit(self: *State) void {
        if (self.pending) |job| {
            if (job.thread) |thread| thread.join();
            job.destroy();
        }
        if (self.devices_result) |job| job.destroy();
        self.clearGrant();
        self.* = .{};
    }

    pub fn close(self: *State) void {
        self.opened = false;
        self.preset = .full;
        self.discard_grant = true;
        self.confirm_revoke = null;
        self.clearGrant();
    }

    pub fn clearGrant(self: *State) void {
        if (self.grant) |job| job.destroy();
        self.grant = null;
    }

    pub fn devices(self: *const State) []const access.DeviceRecord {
        return if (self.devices_result) |job| job.devices else &.{};
    }

    pub fn setHost(self: *State, raw: []const u8) !void {
        const host = std.mem.trim(u8, raw, " \t\r\n/");
        try validateHost(host);
        if (host.len > self.host.len) return error.InvalidHost;
        if (self.pending != null) return error.Busy;
        self.clearGrant();
        @memcpy(self.host[0..host.len], host);
        self.host_len = host.len;
    }

    /// Freeze the selection while creating or displaying a grant so its label stays accurate.
    pub fn selectPreset(self: *State, index: usize) void {
        if (index >= PAIRING_PRESETS.len or self.pending != null or self.grant != null) return;
        self.preset = PAIRING_PRESETS[index];
    }

    pub fn start(self: *State, pref_path: []const u8, operation: Operation, device_id: ?[]const u8) void {
        if (self.pending != null) return;
        if (operation == .create and self.host_len == 0) {
            self.notice = "Paste this machine's HTTPS gateway URL first.";
            return;
        }
        const job = Job.create(pref_path, operation, self.host[0..self.host_len], device_id, self.preset) catch {
            self.notice = "Could not start the daemon request.";
            return;
        };
        if (operation == .create) self.clearGrant();
        self.discard_grant = false;
        self.confirm_revoke = null;
        self.pending = job;
        self.notice = "Working…";
    }

    /// Called by the existing periodic Settings poll, never from the render path.
    pub fn poll(self: *State, now: i64) bool {
        var changed = false;
        if (self.pending) |job| if (job.done.load(.acquire)) {
            if (job.thread) |thread| thread.join();
            self.pending = null;
            changed = true;
            if (job.failed) {
                self.notice = if (job.revoked) "Device revoked, but the list could not refresh. Try Refresh devices." else "Daemon request failed. Check the host URL and relaunch the updated runtime, then retry.";
                job.destroy();
            } else if (job.operation == .create) {
                if (self.discard_grant) job.destroy() else {
                    self.grant = job;
                    self.notice = "Scan with your phone. Keep Tailscale connected on both devices.";
                }
            } else {
                if (self.devices_result) |old| old.destroy();
                self.devices_result = job;
                self.notice = if (job.operation == .revoke) "Device revoked." else "Devices paired with this machine.";
            }
        };
        if (self.grant) |job| {
            const second = @divFloor(now, 1000);
            if (second != self.last_second) {
                self.last_second = second;
                changed = true;
            }
            if (now >= job.expires_at_ms) {
                self.clearGrant();
                self.notice = "Pairing link expired. Create a new link to try again.";
                changed = true;
            }
        }
        return changed;
    }
};

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    pref_path: []const u8,
    operation: Operation,
    preset: access.PairingPreset = .full,
    host: []const u8,
    device_id: ?[]const u8,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    revoked: bool = false,
    devices: []const access.DeviceRecord = &.{},
    device_response: ?headless.protocol.ParsedResponse = null,
    link: ?[]u8 = null,
    qr: ?headless.qr.QrCode = null,
    expires_at_ms: i64 = 0,

    fn create(pref_path: []const u8, operation: Operation, host: []const u8, device_id: ?[]const u8, preset: access.PairingPreset) !*Job {
        const job = try allocator.create(Job);
        job.* = .{ .arena = .init(allocator), .pref_path = "", .operation = operation, .host = "", .device_id = null };
        job.preset = preset;
        errdefer job.destroy();
        const a = job.arena.allocator();
        job.pref_path = try a.dupe(u8, pref_path);
        job.host = try a.dupe(u8, host);
        if (device_id) |id| job.device_id = try a.dupe(u8, id);
        job.thread = try std.Thread.spawn(.{}, worker, .{job});
        return job;
    }

    fn destroy(self: *Job) void {
        if (self.link) |link| std.crypto.secureZero(u8, link);
        if (self.qr) |*qr| qr.wipe();
        if (self.device_response) |*response| response.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn worker(self: *Job) void {
        self.run() catch {
            self.failed = true;
        };
        self.done.store(true, .release);
    }

    fn run(self: *Job) !void {
        const a = self.arena.allocator();
        var transport: daemon.HeadlessTransport = .{ .allocator = a, .pref_path = self.pref_path };
        var client = daemon.headlessClient(a, &transport);
        try self.runClient(&client);
    }

    fn runClient(self: *Job, client: *headless.Client) !void {
        const a = self.arena.allocator();
        if (self.operation == .create) {
            // Omit scopes entirely: the daemon resolves the preset and its access cap.
            var response = try client.call(access.METHOD_DAEMON_PAIRING_GRANT_CREATE, .{
                .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
                .preset = self.preset,
            });
            defer response.deinit();
            const value = response.response.result orelse return error.DaemonRequestFailed;
            // Wipe the parser's secret copy too, including on validation failure.
            defer if (value == .object) {
                if (value.object.get("pairing_token")) |token| {
                    if (token == .string) std.crypto.secureZero(u8, @constCast(token.string));
                }
            };
            const grant = try std.json.parseFromValueLeaky(access.PairingGrantCreateResult, a, value, .{ .ignore_unknown_fields = true });
            defer std.crypto.secureZero(u8, @constCast(grant.pairing_token.reveal()));
            if (grant.access_protocol_version != access.ACCESS_PROTOCOL_VERSION or grant.expires_at_ms <= clock.unixTimestampMs()) return error.InvalidGrant;
            try access.validateGrantId(grant.grant_id);
            try access.validateSecret(grant.pairing_token.reveal());
            self.link = try appLinkAlloc(a, self.host, grant.grant_id, grant.pairing_token.reveal());
            self.qr = try headless.qr.encodeBytes(self.link.?, .{ .ecc = .medium, .max_version = 30 });
            self.expires_at_ms = grant.expires_at_ms;
            return;
        }
        if (self.operation == .revoke) {
            var response = try client.call(access.METHOD_DEVICE_REVOKE, access.DeviceRevokeRequest{
                .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
                .device_id = self.device_id.?,
            });
            defer response.deinit();
            const result = try client.decodeDeviceRevoke(&response);
            if (!result.revoked) return error.RevokeFailed;
            self.revoked = true;
        }
        var response = try client.call(access.METHOD_DEVICE_LIST, access.DeviceListRequest{ .access_protocol_version = access.ACCESS_PROTOCOL_VERSION });
        errdefer response.deinit();
        self.devices = (try client.decodeDeviceList(&response)).devices;
        self.device_response = response;
    }
};

fn validateHost(host: []const u8) !void {
    for (host) |byte| if (byte <= 32 or byte == 127) return error.InvalidHost;
    const uri = std.Uri.parse(host) catch return error.InvalidHost;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.host.?.isEmpty() or
        uri.user != null or uri.password != null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null) return error.InvalidHost;
}

fn appLinkAlloc(a: std.mem.Allocator, host: []const u8, grant: []const u8, code: []const u8) ![]u8 {
    try validateHost(host);
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    for (host) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try encoded.writer.writeByte(byte);
        } else {
            const hex = "0123456789ABCDEF";
            try encoded.writer.writeAll(&.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return std.fmt.allocPrint(a, "https://verdeai.dev/pair?host={s}&grant_id={s}#code={s}", .{ encoded.written(), grant, code });
}

test "phone pairing host validation and fragment-only code" {
    var state: State = .{};
    defer state.deinit();
    try state.setHost(" https://host.ts.net:8443/\n");
    try std.testing.expectEqualStrings("https://host.ts.net:8443", state.host[0..state.host_len]);
    for ([_][]const u8{ "http://host", "https://u:p@host", "https://host/path", "https://host?code=x", "https://host/#code=x" }) |bad|
        try std.testing.expectError(error.InvalidHost, state.setHost(bad));
    const link = try appLinkAlloc(std.testing.allocator, "https://host.ts.net:8443", "grant", "secret");
    defer std.testing.allocator.free(link);
    try std.testing.expectEqualStrings("https://verdeai.dev/pair?host=https%3A%2F%2Fhost.ts.net%3A8443&grant_id=grant#code=secret", link);
}

test "phone pairing close discards outstanding grant and resets confirmation" {
    var state: State = .{ .opened = true, .confirm_revoke = 2 };
    state.close();
    try std.testing.expect(!state.opened and state.discard_grant and state.confirm_revoke == null);
}

fn fixtureJob(operation: Operation) !*Job {
    const job = try allocator.create(Job);
    job.* = .{ .arena = .init(allocator), .pref_path = "", .operation = operation, .host = "", .device_id = null };
    job.done.store(true, .release);
    return job;
}

test "phone pairing completed grant expires and closing discards late results" {
    var state: State = .{};
    defer state.deinit();
    const job = try fixtureJob(.create);
    job.link = try job.arena.allocator().dupe(u8, "secret fixture");
    job.expires_at_ms = 2000;
    state.pending = job;
    try std.testing.expect(state.poll(1000));
    try std.testing.expect(state.grant != null and state.pending == null);
    try std.testing.expect(!state.poll(1500));
    try std.testing.expect(state.poll(2000));
    try std.testing.expect(state.grant == null);
    state.pending = try fixtureJob(.create);
    state.close();
    try std.testing.expect(state.poll(2100));
    try std.testing.expect(state.grant == null and state.pending == null);
}

test "phone pairing failed refresh preserves list and successful revoke replaces it" {
    var state: State = .{};
    defer state.deinit();
    const old = try fixtureJob(.list);
    state.devices_result = old;
    const failed = try fixtureJob(.list);
    failed.failed = true;
    state.pending = failed;
    try std.testing.expect(state.poll(0));
    try std.testing.expect(state.devices_result == old);
    const revoked = try fixtureJob(.revoke);
    state.pending = revoked;
    try std.testing.expect(state.poll(0));
    try std.testing.expect(state.devices_result == revoked);
    try std.testing.expectEqualStrings("Device revoked.", state.notice);
}

test "phone pairing local RPC grant becomes an App Link and local QR" {
    const Fixture = struct {
        fn send(ctx: *anyopaque, request_json: []const u8) ![]u8 {
            const expected: *access.PairingPreset = @ptrCast(@alignCast(ctx));
            var request = try headless.protocol.parseRequest(std.testing.allocator, request_json);
            defer request.deinit();
            try std.testing.expectEqualStrings(access.METHOD_DAEMON_PAIRING_GRANT_CREATE, request.request.method);
            const params = request.request.params.object;
            try std.testing.expectEqual(@as(usize, 2), params.count());
            try std.testing.expectEqualStrings(@tagName(expected.*), params.get("preset").?.string);
            try std.testing.expectEqual(@as(i64, 1), params.get("access_protocol_version").?.integer);
            try std.testing.expect(params.get("scopes") == null);
            return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"access_protocol_version\":1,\"runtime_id\":\"" ++ "a" ** 32 ++ "\",\"instance_id\":\"" ++ "b" ** 32 ++ "\",\"grant_id\":\"" ++ "c" ** 32 ++ "\",\"pairing_token\":\"" ++ "d" ** 64 ++ "\",\"expires_at_ms\":{d},\"scopes\":[\"runtime:read\"]}}}}", .{clock.unixTimestampMs() + 60000});
        }
    };
    for (PAIRING_PRESETS) |preset| {
        const job = try fixtureJob(.create);
        job.preset = preset;
        defer job.destroy();
        job.host = "https://fixture.ts.net";
        var context = preset;
        var client = headless.Client.init(allocator, &context, Fixture.send);
        try job.runClient(&client);
        try std.testing.expect(std.mem.startsWith(u8, job.link.?, "https://verdeai.dev/pair?host=https%3A%2F%2Ffixture.ts.net&grant_id="));
        try std.testing.expect(std.mem.endsWith(u8, job.link.?, "#code=" ++ "d" ** 64));
        try std.testing.expect(job.qr != null and job.qr.?.size > 0);
    }
}

test "phone pairing presets default to Full and freeze for in-flight or displayed grants" {
    var state: State = .{};
    defer state.deinit();
    try std.testing.expectEqual(access.PairingPreset.full, state.preset);
    for (PAIRING_PRESETS, 0..) |preset, index| {
        state.selectPreset(index);
        try std.testing.expectEqual(preset, state.preset);
        try std.testing.expect(presetDescription(preset).len > 0);
    }
    state.selectPreset(PAIRING_PRESETS.len);
    try std.testing.expectEqual(access.PairingPreset.monitor, state.preset);
    state.pending = try fixtureJob(.create);
    state.selectPreset(0);
    try std.testing.expectEqual(access.PairingPreset.monitor, state.preset);
    state.pending.?.expires_at_ms = 2000;
    _ = state.poll(1000);
    state.selectPreset(0);
    try std.testing.expectEqual(access.PairingPreset.monitor, state.preset);
    state.close();
    try std.testing.expectEqual(access.PairingPreset.full, state.preset);
}

test "phone pairing device preset and access cap labels preserve null semantics" {
    try std.testing.expectEqualStrings("Custom / legacy", presetLabel(null));
    try std.testing.expectEqualStrings("Full", presetLabel(.full));
    try std.testing.expectEqualStrings("Chat", presetLabel(.chat));
    try std.testing.expectEqualStrings("Monitor", presetLabel(.monitor));
    try std.testing.expectEqualStrings("No cap", accessModeLabel(null));
    try std.testing.expectEqualStrings("Supervised", accessModeLabel(.supervised));
    try std.testing.expectEqualStrings("Full access", accessModeLabel(.full_access));
}
