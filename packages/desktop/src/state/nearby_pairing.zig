//! "Nearby machines" for Add connection: Verde runtimes on the same tailnet,
//! and pairing one of them by approval instead of a code.
//!
//! Discovery reads tailnet peers from the local Tailscale LocalAPI
//! (`/localapi/v0/status`) and probes each online peer over verified HTTPS
//! for Verde's public runtime metadata (`/.well-known/verde-runtime`).
//! Approval sends a pairing request to the chosen machine, then polls until
//! the owner allows or denies it there. An approval hands back one short-lived
//! pairing grant, which the wizard exchanges through the normal Pair path.
//!
//! All network work runs on worker threads that own heap jobs; the frame
//! thread only reads published results. Abandoning a running job detaches it
//! and the worker frees itself, so the UI never joins a blocked request.

const std = @import("std");
const builtin = @import("builtin");
const access = @import("headless").access_protocol;
const gateway_transport = @import("../runtime/gateway_transport.zig");
const loop_wakeup = @import("loop_wakeup");
const clock = @import("platform_runtime");
const Mutex = @import("sync.zig").Mutex;

const log = std.log.scoped(.native_nearby_pairing);
const allocator = std.heap.page_allocator;

pub const MAX_NEARBY: usize = 16;
pub const NAME_CAPACITY: usize = 63;
pub const OS_CAPACITY: usize = 15;
pub const URL_CAPACITY: usize = 255;
const PROBE_TIMEOUT_MS: i64 = 3_000;
const REQUEST_TIMEOUT_MS: i64 = 10_000;
const POLL_INTERVAL_MS: u64 = 1_500;
/// Transient poll failures tolerated before the request is reported failed.
const MAX_POLL_FAILURES: u8 = 5;
const STATUS_RESPONSE_LIMIT: usize = 4 * 1024 * 1024;
/// Tailscale's LocalAPI sockets for tailscaled on Linux and the open-source
/// macOS daemon. Status is readable without operator rights.
const LOCALAPI_SOCKETS = [_][]const u8{ "/var/run/tailscale/tailscaled.sock", "/var/run/tailscaled.socket" };
/// Verde's Serve listener: the default HTTPS port, then the documented
/// alternative when another app already owns 443.
const PROBE_PORTS = [_]u16{ 443, 8443 };

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), value: []const u8) void {
            const len = @min(value.len, capacity);
            @memcpy(self.bytes[0..len], value[0..len]);
            self.len = len;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const Machine = struct {
    name: Text(NAME_CAPACITY) = .{},
    os: Text(OS_CAPACITY) = .{},
    https_url: Text(URL_CAPACITY) = .{},
    /// The runtime advertises `access.pair.request.v1`; older runtimes can
    /// still be paired with a link.
    supports_approval: bool = false,

    pub fn osLabel(self: *const Machine) []const u8 {
        const os = self.os.slice();
        if (std.ascii.eqlIgnoreCase(os, "linux")) return "Linux";
        if (std.ascii.eqlIgnoreCase(os, "macos") or std.ascii.eqlIgnoreCase(os, "darwin")) return "macOS";
        if (std.ascii.eqlIgnoreCase(os, "windows")) return "Windows";
        return os;
    }
};

pub const DiscoveryPhase = enum {
    idle,
    scanning,
    done,
    /// No reachable LocalAPI: Tailscale is not installed or not running.
    no_tailscale,
    /// Tailscale is installed but logged out or stopped.
    tailscale_stopped,
    failed,
};

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

const JobState = enum(u8) { running, finished, abandoned };

const DiscoveryJob = struct {
    state: std.atomic.Value(JobState) = .init(.running),
    thread: ?std.Thread = null,
    phase: DiscoveryPhase = .scanning,
    machines: [MAX_NEARBY]Machine = undefined,
    count: usize = 0,

    fn worker(self: *DiscoveryJob) void {
        self.run();
        if (self.state.swap(.finished, .acq_rel) == .abandoned) {
            allocator.destroy(self);
            return;
        }
        _ = loop_wakeup.notify();
    }

    fn run(self: *DiscoveryJob) void {
        var peers: [MAX_NEARBY]Peer = undefined;
        const status_json = readTailscaleStatusAlloc() catch |err| {
            self.phase = if (err == error.TailscaleUnavailable) .no_tailscale else .failed;
            return;
        };
        defer allocator.free(status_json);
        const parsed = parseTailscaleStatus(status_json, &peers) catch |err| {
            self.phase = if (err == error.TailscaleNotRunning) .tailscale_stopped else .failed;
            return;
        };
        var probes: [MAX_NEARBY]Probe = undefined;
        var threads: [MAX_NEARBY]?std.Thread = @splat(null);
        for (peers[0..parsed], 0..) |*peer, index| {
            probes[index] = .{ .peer = peer };
            threads[index] = std.Thread.spawn(.{}, Probe.run, .{&probes[index]}) catch null;
            if (threads[index] == null) probes[index].run();
        }
        for (threads[0..parsed]) |maybe| if (maybe) |thread| thread.join();
        for (probes[0..parsed]) |probe| {
            if (!probe.found) continue;
            self.machines[self.count] = probe.machine;
            self.count += 1;
        }
        std.mem.sort(Machine, self.machines[0..self.count], {}, struct {
            fn lessThan(_: void, a: Machine, b: Machine) bool {
                return std.ascii.lessThanIgnoreCase(a.name.slice(), b.name.slice());
            }
        }.lessThan);
        self.phase = .done;
    }
};

const Probe = struct {
    peer: *const Peer,
    machine: Machine = .{},
    found: bool = false,

    fn run(self: *Probe) void {
        for (PROBE_PORTS) |port| {
            var origin_buffer: [URL_CAPACITY + 8]u8 = undefined;
            const origin = (if (port == 443)
                std.fmt.bufPrint(&origin_buffer, "https://{s}", .{self.peer.dns_name.slice()})
            else
                std.fmt.bufPrint(&origin_buffer, "https://{s}:{d}", .{ self.peer.dns_name.slice(), port })) catch return;
            const supports = probeRuntime(origin) orelse continue;
            self.machine.name.set(self.peer.host_name.slice());
            self.machine.os.set(self.peer.os.slice());
            self.machine.https_url.set(origin);
            self.machine.supports_approval = supports;
            self.found = true;
            return;
        }
    }
};

/// Returns whether the origin serves Verde metadata for itself, and whether it
/// supports approval pairing; null when it is not a Verde runtime.
fn probeRuntime(origin: []const u8) ?bool {
    const url = gateway_transport.endpointUrlAlloc(allocator, origin, access.HTTP_RUNTIME_METADATA_PATH) catch return null;
    defer allocator.free(url);
    var response = gateway_transport.getHttpsAlloc(allocator, url, PROBE_TIMEOUT_MS) catch return null;
    defer response.deinit(allocator);
    if (response.status != .ok) return null;
    return parseRuntimeMetadata(response.body, origin);
}

/// Owned by the wizard state; at most one scan runs at a time.
pub const Discovery = struct {
    job: ?*DiscoveryJob = null,
    phase: DiscoveryPhase = .idle,
    machines: [MAX_NEARBY]Machine = undefined,
    count: usize = 0,

    pub fn deinit(self: *Discovery) void {
        self.abandon();
    }

    /// Start a scan unless one is running. Results stay visible meanwhile.
    pub fn start(self: *Discovery) void {
        if (self.job != null) return;
        const job = allocator.create(DiscoveryJob) catch {
            self.phase = .failed;
            return;
        };
        job.* = .{};
        job.thread = std.Thread.spawn(.{}, DiscoveryJob.worker, .{job}) catch {
            allocator.destroy(job);
            self.phase = .failed;
            return;
        };
        self.job = job;
        self.phase = .scanning;
    }

    /// Frame-thread poll: publish a finished scan. Returns true on change.
    pub fn poll(self: *Discovery) bool {
        const job = self.job orelse return false;
        if (job.state.load(.acquire) != .finished) return false;
        if (job.thread) |thread| thread.join();
        self.phase = job.phase;
        self.count = job.count;
        @memcpy(self.machines[0..job.count], job.machines[0..job.count]);
        allocator.destroy(job);
        self.job = null;
        return true;
    }

    pub fn list(self: *const Discovery) []const Machine {
        return self.machines[0..self.count];
    }

    pub fn abandon(self: *Discovery) void {
        const job = self.job orelse return;
        self.job = null;
        if (job.state.swap(.abandoned, .acq_rel) == .finished) {
            if (job.thread) |thread| thread.join();
            allocator.destroy(job);
        } else if (job.thread) |thread| thread.detach();
    }
};

// ---------------------------------------------------------------------------
// Approval request
// ---------------------------------------------------------------------------

pub const ApprovalPhase = enum {
    sending,
    /// Waiting for the owner on the other machine; `match_code` is set.
    waiting,
    approved,
    denied,
    expired,
    rate_limited,
    /// The machine is reachable but does not accept requests from here
    /// (no Tailscale identity, or an older Verde).
    refused,
    failed,
};

/// Approved grant handed back once. `clear` wipes the secret.
pub const ApprovedGrant = struct {
    grant_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    pairing_token: [access.SECRET_HEX_BYTES]u8 = undefined,
    runtime_id: Text(128) = .{},

    pub fn clear(self: *ApprovedGrant) void {
        std.crypto.secureZero(u8, self.pairing_token[0..]);
    }
};

const ApprovalJob = struct {
    state: std.atomic.Value(JobState) = .init(.running),
    thread: ?std.Thread = null,
    mutex: Mutex = .{},
    phase: ApprovalPhase = .sending,
    match_code: [access.PAIR_MATCH_CODE_LEN]u8 = @splat(' '),
    has_match_code: bool = false,
    origin: Text(URL_CAPACITY) = .{},
    device_label: Text(access.MAX_DEVICE_LABEL_BYTES) = .{},
    request_id: [access.GRANT_ID_HEX_BYTES]u8 = undefined,
    grant: ApprovedGrant = .{},

    fn worker(self: *ApprovalJob) void {
        self.run();
        if (self.state.swap(.finished, .acq_rel) == .abandoned) {
            self.grant.clear();
            allocator.destroy(self);
            return;
        }
        _ = loop_wakeup.notify();
    }

    fn abandoned(self: *ApprovalJob) bool {
        return self.state.load(.acquire) == .abandoned;
    }

    fn setPhase(self: *ApprovalJob, phase: ApprovalPhase) void {
        self.mutex.lock();
        self.phase = phase;
        self.mutex.unlock();
        _ = loop_wakeup.notify();
    }

    fn run(self: *ApprovalJob) void {
        const submit_body = std.json.Stringify.valueAlloc(allocator, access.PairingRequestHttpRequest{
            .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
            .request_id = &self.request_id,
            .device_label = self.device_label.slice(),
        }, .{}) catch return self.setPhase(.failed);
        defer allocator.free(submit_body);
        var submitted = self.post(access.HTTP_PAIR_REQUEST_PATH, submit_body) catch return self.setPhase(.failed);
        defer submitted.deinit(allocator);
        switch (classifySubmit(submitted.status, submitted.body, &self.match_code)) {
            .waiting => {
                self.mutex.lock();
                self.has_match_code = true;
                self.phase = .waiting;
                self.mutex.unlock();
                _ = loop_wakeup.notify();
            },
            else => |phase| return self.setPhase(phase),
        }

        const poll_body = std.json.Stringify.valueAlloc(allocator, access.PairingRequestPollHttpRequest{
            .access_protocol_version = access.ACCESS_PROTOCOL_VERSION,
            .request_id = &self.request_id,
        }, .{}) catch return self.setPhase(.failed);
        defer allocator.free(poll_body);
        // The runtime expires the request after two minutes; stop shortly after.
        const deadline_ms = clock.unixTimestampMs() + access.PAIR_REQUEST_TTL_MS + 15_000;
        var failures: u8 = 0;
        while (!self.abandoned()) {
            if (!sleepUnlessAbandoned(self, POLL_INTERVAL_MS)) return;
            if (clock.unixTimestampMs() > deadline_ms) return self.setPhase(.expired);
            var response = self.post(access.HTTP_PAIR_REQUEST_STATUS_PATH, poll_body) catch {
                failures += 1;
                if (failures >= MAX_POLL_FAILURES) return self.setPhase(.failed);
                continue;
            };
            defer response.deinit(allocator);
            const phase = classifyPoll(response.status, response.body, &self.grant);
            switch (phase) {
                .waiting => failures = 0,
                .failed => {
                    failures += 1;
                    if (failures >= MAX_POLL_FAILURES) return self.setPhase(.failed);
                },
                else => return self.setPhase(phase),
            }
        }
    }

    fn post(self: *ApprovalJob, path: []const u8, body: []const u8) !gateway_transport.LoopbackResponse {
        const url = try gateway_transport.endpointUrlAlloc(allocator, self.origin.slice(), path);
        defer allocator.free(url);
        return gateway_transport.postHttpsAlloc(allocator, .{
            .url = url,
            .authorization = null,
            .body = body,
            .timeout_ms = REQUEST_TIMEOUT_MS,
        });
    }
};

fn sleepUnlessAbandoned(job: *ApprovalJob, total_ms: u64) bool {
    var waited: u64 = 0;
    while (waited < total_ms) : (waited += 100) {
        if (job.abandoned()) return false;
        clock.sleepMillis(100);
    }
    return !job.abandoned();
}

/// One outstanding pairing request from this computer.
pub const Approval = struct {
    job: ?*ApprovalJob = null,
    machine: Machine = .{},

    pub fn deinit(self: *Approval) void {
        self.cancel();
    }

    pub fn active(self: *const Approval) bool {
        return self.job != null;
    }

    pub fn start(self: *Approval, machine: Machine, device_label: []const u8) !void {
        self.cancel();
        try access.validateDeviceLabel(device_label);
        const job = try allocator.create(ApprovalJob);
        errdefer allocator.destroy(job);
        job.* = .{};
        job.origin.set(machine.https_url.slice());
        job.device_label.set(device_label);
        var random: [access.GRANT_ID_BYTES]u8 = undefined;
        var threaded = std.Io.Threaded.init_single_threaded;
        try std.Io.randomSecure(threaded.io(), &random);
        job.request_id = std.fmt.bytesToHex(random, .lower);
        job.thread = try std.Thread.spawn(.{}, ApprovalJob.worker, .{job});
        self.job = job;
        self.machine = machine;
    }

    pub const View = struct {
        phase: ApprovalPhase,
        match_code: ?[access.PAIR_MATCH_CODE_LEN]u8,
    };

    pub fn view(self: *const Approval) ?View {
        const job = self.job orelse return null;
        job.mutex.lock();
        defer job.mutex.unlock();
        return .{ .phase = job.phase, .match_code = if (job.has_match_code) job.match_code else null };
    }

    /// Once the worker finished with an approval, move the grant out (once).
    pub fn takeGrant(self: *Approval, out: *ApprovedGrant) bool {
        const job = self.job orelse return false;
        if (job.state.load(.acquire) != .finished) return false;
        if (job.phase != .approved) return false;
        out.* = job.grant;
        job.grant.clear();
        self.finish();
        return true;
    }

    /// Drop a finished job (keeping nothing secret). Running jobs are abandoned.
    pub fn cancel(self: *Approval) void {
        const job = self.job orelse return;
        self.job = null;
        if (job.state.swap(.abandoned, .acq_rel) == .finished) {
            if (job.thread) |thread| thread.join();
            job.grant.clear();
            allocator.destroy(job);
        } else if (job.thread) |thread| thread.detach();
    }

    pub fn finished(self: *const Approval) bool {
        const job = self.job orelse return false;
        return job.state.load(.acquire) == .finished;
    }

    fn finish(self: *Approval) void {
        self.cancel();
    }
};

// ---------------------------------------------------------------------------
// Pure parsing (unit-tested)
// ---------------------------------------------------------------------------

pub const Peer = struct {
    host_name: Text(NAME_CAPACITY) = .{},
    dns_name: Text(URL_CAPACITY) = .{},
    os: Text(OS_CAPACITY) = .{},
};

/// Online tailnet peers with a MagicDNS name, at most `out.len`.
pub fn parseTailscaleStatus(json: []const u8, out: []Peer) !usize {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), json, .{}) catch return error.InvalidTailscaleStatus;
    if (value != .object) return error.InvalidTailscaleStatus;
    const backend = value.object.get("BackendState") orelse return error.InvalidTailscaleStatus;
    if (backend != .string or !std.mem.eql(u8, backend.string, "Running")) return error.TailscaleNotRunning;
    const peers = value.object.get("Peer") orelse return 0;
    if (peers != .object) return 0;
    var count: usize = 0;
    var iterator = peers.object.iterator();
    while (iterator.next()) |entry| {
        if (count == out.len) break;
        const peer = entry.value_ptr.*;
        if (peer != .object) continue;
        const online = peer.object.get("Online") orelse continue;
        if (online != .bool or !online.bool) continue;
        const dns = jsonString(peer.object.get("DNSName")) orelse continue;
        const trimmed = std.mem.trimEnd(u8, dns, ".");
        if (!validDnsName(trimmed)) continue;
        const host = jsonString(peer.object.get("HostName")) orelse firstLabel(trimmed);
        out[count] = .{};
        out[count].dns_name.set(trimmed);
        out[count].host_name.set(if (host.len == 0 or host.len > NAME_CAPACITY) firstLabel(trimmed) else host);
        out[count].os.set(jsonString(peer.object.get("OS")) orelse "");
        count += 1;
    }
    return count;
}

/// Accept only metadata describing exactly the probed origin; returns whether
/// approval pairing is advertised, or null when it is not a Verde runtime.
pub fn parseRuntimeMetadata(json: []const u8, origin: []const u8) ?bool {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const metadata = std.json.parseFromSliceLeaky(access.RuntimeEndpointMetadata, arena_state.allocator(), json, .{ .ignore_unknown_fields = true }) catch return null;
    if (metadata.access_protocol_version != access.ACCESS_PROTOCOL_VERSION) return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, metadata.https_url, "/"), origin)) return null;
    var pair = false;
    var approval = false;
    for (metadata.capabilities) |capability| {
        if (std.mem.eql(u8, capability, access.PAIR_RUNTIME_CAPABILITY)) pair = true;
        if (std.mem.eql(u8, capability, access.PAIR_REQUEST_CAPABILITY)) approval = true;
    }
    return if (pair) approval else null;
}

fn classifySubmit(status: std.http.Status, body: []const u8, match_code: *[access.PAIR_MATCH_CODE_LEN]u8) ApprovalPhase {
    switch (status) {
        .accepted, .ok => {},
        .too_many_requests => return .rate_limited,
        .forbidden, .not_found, .method_not_allowed => return .refused,
        else => return .failed,
    }
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const result = std.json.parseFromSliceLeaky(access.PairingRequestSubmitResult, arena_state.allocator(), body, .{ .ignore_unknown_fields = true }) catch return .failed;
    access.validateMatchCode(result.match_code) catch return .failed;
    @memcpy(match_code, result.match_code);
    return switch (result.status) {
        .pending => .waiting,
        .denied => .denied,
        .expired => .expired,
        .approved => .waiting,
    };
}

/// Map one status poll. `.waiting` keeps polling; `.failed` is transient.
fn classifyPoll(status: std.http.Status, body: []const u8, grant: *ApprovedGrant) ApprovalPhase {
    switch (status) {
        .ok => {},
        .too_many_requests => return .rate_limited,
        // The runtime no longer knows the request (restarted or expired).
        .not_found => return .expired,
        .forbidden => return .refused,
        else => return .failed,
    }
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    // Copy strings into the arena so the token copy can be wiped; the
    // response body itself is wiped by its owner.
    const result = std.json.parseFromSliceLeaky(access.PairingRequestPollResult, arena_state.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .failed;
    defer if (result.pairing_token) |token| std.crypto.secureZero(u8, @constCast(token.reveal()));
    return switch (result.status) {
        .pending => .waiting,
        .denied => .denied,
        .expired => .expired,
        .approved => approved: {
            const grant_id = result.grant_id orelse break :approved .failed;
            const token = result.pairing_token orelse break :approved .failed;
            const runtime_id = result.runtime_id orelse break :approved .failed;
            access.validateGrantId(grant_id) catch break :approved .failed;
            access.validateSecret(token.reveal()) catch break :approved .failed;
            if (runtime_id.len == 0 or runtime_id.len > 128) break :approved .failed;
            @memcpy(&grant.grant_id, grant_id);
            @memcpy(&grant.pairing_token, token.reveal());
            grant.runtime_id.set(runtime_id);
            break :approved .approved;
        },
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}

fn firstLabel(dns: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, dns, '.') orelse dns.len;
    return dns[0..@min(dot, NAME_CAPACITY)];
}

fn validDnsName(name: []const u8) bool {
    if (name.len == 0 or name.len > URL_CAPACITY - 16) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
    }
    return std.mem.indexOfScalar(u8, name, '.') != null;
}

// ---------------------------------------------------------------------------
// LocalAPI transport
// ---------------------------------------------------------------------------

fn readTailscaleStatusAlloc() ![]u8 {
    if (comptime builtin.os.tag == .windows) return error.TailscaleUnavailable;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (LOCALAPI_SOCKETS) |path| {
        const address = std.Io.net.UnixAddress.init(path) catch continue;
        var stream = address.connect(io) catch continue;
        defer stream.close(io);
        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        // HTTP/1.0 keeps tailscaled from chunking the body; it closes after.
        writer.interface.writeAll("GET /localapi/v0/status HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\r\n") catch continue;
        writer.interface.flush() catch continue;
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        const response = reader.interface.allocRemaining(allocator, .limited(STATUS_RESPONSE_LIMIT)) catch continue;
        defer allocator.free(response);
        const body = httpOkBody(response) orelse {
            log.info("tailscale LocalAPI status answered without 200", .{});
            return error.TailscaleStatusFailed;
        };
        return try allocator.dupe(u8, body);
    }
    return error.TailscaleUnavailable;
}

fn httpOkBody(response: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
    const status_line_end = std.mem.indexOf(u8, response, "\r\n") orelse return null;
    const status_line = response[0..status_line_end];
    var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = parts.next() orelse return null;
    const code = parts.next() orelse return null;
    if (!std.mem.eql(u8, code, "200")) return null;
    return response[header_end + 4 ..];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tailscale status yields online peers with MagicDNS names" {
    const json =
        \\{"BackendState":"Running","Self":{"HostName":"lightning","DNSName":"lightning.tail1.ts.net.","OS":"linux","Online":true},
        \\ "Peer":{
        \\  "nodekey:a":{"HostName":"richetech","DNSName":"richetech.tail1.ts.net.","OS":"linux","Online":true},
        \\  "nodekey:b":{"HostName":"phone","DNSName":"phone.tail1.ts.net.","OS":"iOS","Online":false},
        \\  "nodekey:c":{"HostName":"","DNSName":"mini.tail1.ts.net.","OS":"macOS","Online":true},
        \\  "nodekey:d":{"HostName":"bad","DNSName":"bad host.ts.net.","OS":"linux","Online":true}
        \\ }}
    ;
    var peers: [8]Peer = undefined;
    const count = try parseTailscaleStatus(json, &peers);
    try std.testing.expectEqual(@as(usize, 2), count);
    var saw_richetech = false;
    var saw_mini = false;
    for (peers[0..count]) |peer| {
        if (std.mem.eql(u8, peer.host_name.slice(), "richetech")) {
            saw_richetech = true;
            try std.testing.expectEqualStrings("richetech.tail1.ts.net", peer.dns_name.slice());
        }
        if (std.mem.eql(u8, peer.host_name.slice(), "mini")) saw_mini = true;
    }
    try std.testing.expect(saw_richetech and saw_mini);
    try std.testing.expectError(error.TailscaleNotRunning, parseTailscaleStatus("{\"BackendState\":\"NeedsLogin\"}", &peers));
    try std.testing.expectError(error.InvalidTailscaleStatus, parseTailscaleStatus("not json", &peers));
}

test "runtime metadata must describe the probed origin" {
    const origin = "https://richetech.tail1.ts.net";
    const approval =
        \\{"access_protocol_version":1,"runtime_id":"r","instance_id":"i","https_url":"https://richetech.tail1.ts.net","wss_url":"wss://richetech.tail1.ts.net/ws","capabilities":["access.pair.v1","access.pair.idempotent.v1","access.pair.request.v1"]}
    ;
    try std.testing.expectEqual(@as(?bool, true), parseRuntimeMetadata(approval, origin));
    const link_only =
        \\{"access_protocol_version":1,"runtime_id":"r","instance_id":"i","https_url":"https://richetech.tail1.ts.net","wss_url":"wss://x/ws","capabilities":["access.pair.v1"]}
    ;
    try std.testing.expectEqual(@as(?bool, false), parseRuntimeMetadata(link_only, origin));
    // Metadata for another origin (a proxy echoing someone else) is ignored.
    try std.testing.expectEqual(@as(?bool, null), parseRuntimeMetadata(approval, "https://other.tail1.ts.net"));
    try std.testing.expectEqual(@as(?bool, null), parseRuntimeMetadata("{}", origin));
}

test "approval responses map to clear requester outcomes and capture the grant once" {
    var code: [access.PAIR_MATCH_CODE_LEN]u8 = undefined;
    try std.testing.expectEqual(ApprovalPhase.waiting, classifySubmit(.accepted, "{\"access_protocol_version\":1,\"status\":\"pending\",\"match_code\":\"4F2K\",\"expires_at_ms\":1}", &code));
    try std.testing.expectEqualStrings("4F2K", &code);
    try std.testing.expectEqual(ApprovalPhase.rate_limited, classifySubmit(.too_many_requests, "", &code));
    try std.testing.expectEqual(ApprovalPhase.refused, classifySubmit(.forbidden, "{\"ok\":false,\"error\":\"tailscale_identity_required\"}", &code));
    try std.testing.expectEqual(ApprovalPhase.failed, classifySubmit(.accepted, "{\"access_protocol_version\":1,\"status\":\"pending\",\"match_code\":\"0000\",\"expires_at_ms\":1}", &code));

    var grant: ApprovedGrant = .{};
    try std.testing.expectEqual(ApprovalPhase.waiting, classifyPoll(.ok, "{\"access_protocol_version\":1,\"status\":\"pending\",\"match_code\":\"4F2K\",\"expires_at_ms\":1}", &grant));
    try std.testing.expectEqual(ApprovalPhase.denied, classifyPoll(.ok, "{\"access_protocol_version\":1,\"status\":\"denied\",\"match_code\":\"4F2K\",\"expires_at_ms\":1}", &grant));
    try std.testing.expectEqual(ApprovalPhase.expired, classifyPoll(.not_found, "", &grant));
    const approved =
        \\{"access_protocol_version":1,"status":"approved","match_code":"4F2K","expires_at_ms":1,"runtime_id":"0123456789abcdef0123456789abcdef","instance_id":"00112233445566778899aabbccddeeff","grant_id":"fedcba9876543210fedcba9876543210","pairing_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","preset":"full"}
    ;
    try std.testing.expectEqual(ApprovalPhase.approved, classifyPoll(.ok, approved, &grant));
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210", &grant.grant_id);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", grant.runtime_id.slice());
    grant.clear();
    try std.testing.expect(std.mem.indexOfScalar(u8, &grant.pairing_token, 'a') == null);
    // An "approved" reply missing the grant is not trusted.
    try std.testing.expectEqual(ApprovalPhase.failed, classifyPoll(.ok, "{\"access_protocol_version\":1,\"status\":\"approved\",\"match_code\":\"4F2K\",\"expires_at_ms\":1}", &grant));
}

test "LocalAPI response framing accepts only 200" {
    try std.testing.expectEqualStrings("{}", httpOkBody("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n{}").?);
    try std.testing.expect(httpOkBody("HTTP/1.0 403 Forbidden\r\n\r\nno") == null);
    try std.testing.expect(httpOkBody("garbage") == null);
}
