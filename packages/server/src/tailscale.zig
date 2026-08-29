//! Conservative Tailscale Serve discovery and configuration.

const std = @import("std");

pub const HTTPS_PORT: u16 = 443;
pub const STATE_FILE = "tailscale-serve.json";

pub const CommandResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const Runner = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, std.mem.Allocator, []const []const u8) anyerror!CommandResult,

    pub fn run(self: Runner, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        return self.run_fn(self.context, allocator, argv);
    }
};

pub const SystemRunner = struct {
    io: std.Io,

    pub fn runner(self: *SystemRunner) Runner {
        return .{ .context = self, .run_fn = run };
    }

    fn run(context: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        const self: *SystemRunner = @ptrCast(@alignCast(context));
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(256 * 1024),
        });
        return .{
            .code = switch (result.term) { .exited => |code| code, else => 1 },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    origin: []u8,
    target: []u8,
    already_configured: bool,

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.origin);
        self.allocator.free(self.target);
        self.* = undefined;
    }
};

pub const Intent = struct {
    schema_version: u32 = 1,
    origin: []const u8,
    target: []const u8,
    https_port: u16 = HTTPS_PORT,
    verde_owned: bool,
};

/// Verifies login, discovers the stable MagicDNS name, and refuses to alter a
/// non-Verde Serve configuration. No command is evaluated by a shell.
pub fn prepare(allocator: std.mem.Allocator, runner: Runner, gateway_port: u16) !Prepared {
    var version = runner.run(allocator, &.{ "tailscale", "version" }) catch return error.TailscaleCliMissing;
    defer version.deinit(allocator);
    if (version.code != 0) return error.TailscaleCliUnavailable;

    var status = try runner.run(allocator, &.{ "tailscale", "status", "--json" });
    defer status.deinit(allocator);
    if (status.code != 0) return error.TailscaleNotRunning;
    const dns_name = try magicDnsName(allocator, status.stdout);
    defer allocator.free(dns_name);
    const origin = try std.fmt.allocPrint(allocator, "https://{s}", .{dns_name});
    errdefer allocator.free(origin);
    const target = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{gateway_port});
    errdefer allocator.free(target);

    var serve = try runner.run(allocator, &.{ "tailscale", "serve", "status", "--json" });
    defer serve.deinit(allocator);
    if (serve.code != 0) return error.TailscaleServeStatusFailed;
    const configuration = try classifyServeStatus(allocator, serve.stdout, target);
    if (configuration == .conflict) return error.TailscaleServeConflict;
    return .{
        .allocator = allocator,
        .origin = origin,
        .target = target,
        .already_configured = configuration == .ours,
    };
}

pub fn apply(allocator: std.mem.Allocator, runner: Runner, prepared: Prepared) !void {
    if (prepared.already_configured) return;
    var result = try runner.run(allocator, &.{
        "tailscale", "serve", "--bg", "--yes", "--https=443", prepared.target,
    });
    defer result.deinit(allocator);
    if (result.code != 0) return error.TailscaleServeConfigureFailed;
}

pub const Cleanup = enum { removed, not_owned, missing, preserved_changed };

/// Removes only the one HTTPS listener Verde created, and only while both the
/// MagicDNS origin and sole proxy target still match the saved intent.
pub fn rollbackExact(allocator: std.mem.Allocator, runner: Runner, origin: []const u8, target: []const u8) !Cleanup {
    var status = try runner.run(allocator, &.{ "tailscale", "status", "--json" });
    defer status.deinit(allocator);
    if (status.code != 0) return .preserved_changed;
    const dns_name = magicDnsName(allocator, status.stdout) catch return .preserved_changed;
    defer allocator.free(dns_name);
    const current_origin = try std.fmt.allocPrint(allocator, "https://{s}", .{dns_name});
    defer allocator.free(current_origin);
    if (!std.mem.eql(u8, current_origin, origin)) return .preserved_changed;

    var serve = try runner.run(allocator, &.{ "tailscale", "serve", "status", "--json" });
    defer serve.deinit(allocator);
    if (serve.code != 0 or try classifyServeStatus(allocator, serve.stdout, target) != .ours) {
        return .preserved_changed;
    }
    var remove = try runner.run(allocator, &.{ "tailscale", "serve", "--yes", "--https=443", "off" });
    defer remove.deinit(allocator);
    if (remove.code != 0) return error.TailscaleServeCleanupFailed;
    return .removed;
}

pub fn cleanupSaved(io: std.Io, allocator: std.mem.Allocator, runner: Runner, state_dir: []const u8) !Cleanup {
    const dir = std.Io.Dir.openDirAbsolute(io, state_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer dir.close(io);
    const encoded = dir.readFileAlloc(io, STATE_FILE, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer allocator.free(encoded);
    var intent = std.json.parseFromSlice(Intent, allocator, encoded, .{ .ignore_unknown_fields = false }) catch
        return error.InvalidTailscaleIntent;
    defer intent.deinit();
    if (intent.value.schema_version != 1 or intent.value.https_port != HTTPS_PORT) return error.InvalidTailscaleIntent;
    if (!intent.value.verde_owned) return .not_owned;
    return rollbackExact(allocator, runner, intent.value.origin, intent.value.target);
}

pub fn savedOrigin(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ state_dir, STATE_FILE });
    defer allocator.free(path);
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    var parsed = std.json.parseFromSlice(Intent, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return error.InvalidTailscaleIntent;
    defer parsed.deinit();
    if (parsed.value.schema_version != 1) return error.InvalidTailscaleIntent;
    return allocator.dupe(u8, parsed.value.origin);
}

/// Asks tailscaled for the same certificate used by Serve, hashes its exact
/// DER SubjectPublicKeyInfo, and removes both temporary certificate files.
pub fn spkiSha256(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: Runner,
    state_dir: []const u8,
    origin: []const u8,
) ![43]u8 {
    if (!std.mem.startsWith(u8, origin, "https://")) return error.InvalidTailscaleIntent;
    const hostname = origin["https://".len..];
    if (hostname.len == 0 or std.mem.indexOfAny(u8, hostname, "/?#@:") != null) return error.InvalidTailscaleIntent;
    var random: [8]u8 = undefined;
    try io.randomSecure(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    const cert_path = try std.fmt.allocPrint(allocator, "{s}/.tailscale-cert-{s}.pem", .{ state_dir, @as([]const u8, &suffix) });
    defer allocator.free(cert_path);
    defer std.Io.Dir.cwd().deleteFile(io, cert_path) catch {};
    const key_path = try std.fmt.allocPrint(allocator, "{s}/.tailscale-key-{s}.pem", .{ state_dir, @as([]const u8, &suffix) });
    defer allocator.free(key_path);
    defer std.Io.Dir.cwd().deleteFile(io, key_path) catch {};
    var result = try runner.run(allocator, &.{
        "tailscale", "cert", "--cert-file", cert_path, "--key-file", key_path, hostname,
    });
    defer result.deinit(allocator);
    if (result.code != 0) return error.TailscaleCertificateFailed;
    const pem = try std.Io.Dir.cwd().readFileAlloc(io, cert_path, allocator, .limited(256 * 1024));
    defer allocator.free(pem);
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const start_index = (std.mem.indexOf(u8, pem, begin) orelse return error.InvalidTailscaleCertificate) + begin.len;
    const end_index = std.mem.indexOfPos(u8, pem, start_index, end) orelse return error.InvalidTailscaleCertificate;
    const encoded = std.mem.trim(u8, pem[start_index..end_index], &std.ascii.whitespace);
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const der_bytes = try allocator.alloc(u8, decoder.calcSizeUpperBound(encoded.len));
    defer allocator.free(der_bytes);
    const decoded_size = try decoder.decode(der_bytes, encoded);
    const spki = try subjectPublicKeyInfo(der_bytes[0..decoded_size]);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(spki, &digest, .{});
    var encoded_digest: [43]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded_digest, &digest);
    return encoded_digest;
}

fn subjectPublicKeyInfo(certificate_bytes: []const u8) ![]const u8 {
    const der = std.crypto.Certificate.der;
    const certificate = try der.Element.parse(certificate_bytes, 0);
    const tbs = try der.Element.parse(certificate_bytes, certificate.slice.start);
    const version_or_serial = try der.Element.parse(certificate_bytes, tbs.slice.start);
    const serial = if (@as(u8, @bitCast(version_or_serial.identifier)) == 0xa0)
        try der.Element.parse(certificate_bytes, version_or_serial.slice.end)
    else
        version_or_serial;
    const signature = try der.Element.parse(certificate_bytes, serial.slice.end);
    const issuer = try der.Element.parse(certificate_bytes, signature.slice.end);
    const validity = try der.Element.parse(certificate_bytes, issuer.slice.end);
    const subject = try der.Element.parse(certificate_bytes, validity.slice.end);
    const spki = try der.Element.parse(certificate_bytes, subject.slice.end);
    return certificate_bytes[subject.slice.end..spki.slice.end];
}

pub fn writeIntent(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, prepared: Prepared) !void {
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    if (@import("builtin").os.tag != .windows and std.posix.mode_t != u0) {
        try std.Io.Dir.cwd().setFilePermissions(io, state_dir, @enumFromInt(0o700), .{ .follow_symlinks = false });
    }
    const retain_ownership = priorOwned(io, allocator, state_dir, prepared.origin, prepared.target) catch false;
    const encoded = try std.json.Stringify.valueAlloc(allocator, Intent{
        .origin = prepared.origin,
        .target = prepared.target,
        .verde_owned = !prepared.already_configured or retain_ownership,
    }, .{});
    defer allocator.free(encoded);
    const dir = try std.Io.Dir.openDirAbsolute(io, state_dir, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = STATE_FILE, .data = encoded, .flags = .{ .permissions = @enumFromInt(0o600) } });
}

fn priorOwned(io: std.Io, allocator: std.mem.Allocator, state_dir: []const u8, origin: []const u8, target: []const u8) !bool {
    const path = try std.fs.path.join(allocator, &.{ state_dir, STATE_FILE });
    defer allocator.free(path);
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(Intent, allocator, encoded, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    return parsed.value.schema_version == 1 and parsed.value.verde_owned and
        std.mem.eql(u8, parsed.value.origin, origin) and std.mem.eql(u8, parsed.value.target, target);
}

pub fn removeIntent(io: std.Io, state_dir: []const u8) void {
    const dir = std.Io.Dir.openDirAbsolute(io, state_dir, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, STATE_FILE) catch {};
}

const ServeStatus = enum { empty, ours, conflict };

fn classifyServeStatus(allocator: std.mem.Allocator, encoded: []const u8, target: []const u8) !ServeStatus {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{}) catch
        return error.InvalidTailscaleStatus;
    defer parsed.deinit();
    if (isEmpty(parsed.value)) return .empty;
    var targets: usize = 0;
    var foreign_targets: usize = 0;
    var handlers: usize = 0;
    countProxyTargets(parsed.value, target, &targets, &foreign_targets, &handlers);
    if (targets == 1 and foreign_targets == 0 and handlers == 1) return .ours;
    return .conflict;
}

fn isEmpty(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .object => |object| object.count() == 0,
        else => false,
    };
}

fn countProxyTargets(value: std.json.Value, target: []const u8, ours: *usize, foreign: *usize, handlers: *usize) void {
    switch (value) {
        .string => |string| {
            if (std.mem.startsWith(u8, string, "http://127.0.0.1:") or
                std.mem.startsWith(u8, string, "http://localhost:"))
            {
                if (std.mem.eql(u8, string, target)) ours.* += 1 else foreign.* += 1;
            }
        },
        .array => |array| for (array.items) |item| countProxyTargets(item, target, ours, foreign, handlers),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "Handlers")) switch (entry.value_ptr.*) {
                    .object => |map| handlers.* += map.count(),
                    else => handlers.* += 1,
                };
                countProxyTargets(entry.value_ptr.*, target, ours, foreign, handlers);
            }
        },
        else => {},
    }
}

fn magicDnsName(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const Status = struct {
        BackendState: []const u8,
        Self: struct { DNSName: []const u8 },
    };
    var parsed = std.json.parseFromSlice(Status, allocator, encoded, .{ .ignore_unknown_fields = true }) catch
        return error.InvalidTailscaleStatus;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.BackendState, "Running")) return error.TailscaleNotLoggedIn;
    const raw = std.mem.trimEnd(u8, parsed.value.Self.DNSName, ".");
    if (raw.len == 0 or raw.len > 253) return error.InvalidTailscaleStatus;
    for (raw) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '-') {
        return error.InvalidTailscaleStatus;
    };
    return allocator.dupe(u8, raw);
}

const FakeRunner = struct {
    calls: usize = 0,
    outputs: []const CommandResult,
    off_called: bool = false,
    unsafe_called: bool = false,

    fn runner(self: *FakeRunner) Runner {
        return .{ .context = self, .run_fn = run };
    }

    fn run(context: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        if (argv.len > 0 and std.mem.eql(u8, argv[argv.len - 1], "off")) self.off_called = true;
        for (argv) |arg| {
            if (std.mem.eql(u8, arg, "reset") or std.mem.eql(u8, arg, "--all")) self.unsafe_called = true;
        }
        const value = self.outputs[self.calls];
        self.calls += 1;
        return .{
            .code = value.code,
            .stdout = try allocator.dupe(u8, value.stdout),
            .stderr = try allocator.dupe(u8, value.stderr),
        };
    }
};

test "preflight discovers MagicDNS and reuses only the exact Verde mapping" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net.\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("https://runtime.tail.ts.net", prepared.origin);
    try std.testing.expect(prepared.already_configured);
}

test "cleanup removes only an unchanged exact mapping without reset" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net.\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast(""), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    try std.testing.expectEqual(Cleanup.removed, try rollbackExact(
        std.testing.allocator, fake.runner(), "https://runtime.tail.ts.net", "http://127.0.0.1:7420",
    ));
    try std.testing.expect(fake.off_called);
    try std.testing.expect(!fake.unsafe_called);
}

test "cleanup preserves a mapping after a foreign handler appears" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"},\"/other\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    try std.testing.expectEqual(Cleanup.preserved_changed, try rollbackExact(
        std.testing.allocator, fake.runner(), "https://runtime.tail.ts.net", "http://127.0.0.1:7420",
    ));
    try std.testing.expect(!fake.off_called);
    try std.testing.expect(!fake.unsafe_called);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "re-running exact configuration retains Verde ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const state_dir = buffer[0..length];
    var created: Prepared = .{
        .allocator = std.testing.allocator,
        .origin = try std.testing.allocator.dupe(u8, "https://runtime.tail.ts.net"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1:7420"),
        .already_configured = false,
    };
    defer created.deinit();
    try writeIntent(std.testing.io, std.testing.allocator, state_dir, created);
    var reused: Prepared = .{
        .allocator = std.testing.allocator,
        .origin = try std.testing.allocator.dupe(u8, created.origin),
        .target = try std.testing.allocator.dupe(u8, created.target),
        .already_configured = true,
    };
    defer reused.deinit();
    try writeIntent(std.testing.io, std.testing.allocator, state_dir, reused);
    const encoded = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(Intent, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.verde_owned);
}

test "preflight rejects a foreign Serve mapping without applying commands" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    try std.testing.expectError(error.TailscaleServeConflict, prepare(std.testing.allocator, fake.runner(), 7420));
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
}
