//! Conservative Tailscale Serve discovery and configuration.

const std = @import("std");
const builtin = @import("builtin");

pub const DEFAULT_HTTPS_PORT: u16 = 443;
pub const STATE_FILE = "tailscale-serve.json";
pub const LOCK_FILE = "tailscale-serve.lock";

pub const LifecycleLock = struct {
    file: std.Io.File,

    pub fn acquire(io: std.Io, state_dir: []const u8) !LifecycleLock {
        std.Io.Dir.cwd().createDirPath(io, state_dir) catch
            return error.TailscaleLifecycleLockFailed;
        if (builtin.os.tag != .windows and std.posix.mode_t != u0) {
            std.Io.Dir.cwd().setFilePermissions(io, state_dir, @enumFromInt(0o700), .{ .follow_symlinks = false }) catch
                return error.TailscaleLifecycleLockFailed;
        }
        const dir = std.Io.Dir.openDirAbsolute(io, state_dir, .{}) catch
            return error.TailscaleLifecycleLockFailed;
        defer dir.close(io);
        const file = dir.createFile(io, LOCK_FILE, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        }) catch return error.TailscaleLifecycleLockFailed;
        return .{ .file = file };
    }

    pub fn deinit(self: *LifecycleLock, io: std.Io) void {
        self.file.unlock(io);
        self.file.close(io);
        self.* = undefined;
    }
};

pub const ListenerState = enum { available, matching, collision };

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
    cas_fn: ?*const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]u8 = null,

    pub fn run(self: Runner, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        return self.run_fn(self.context, allocator, argv);
    }

    pub fn compareAndSetServeConfig(self: Runner, allocator: std.mem.Allocator, etag: []const u8, config: []const u8) ![]u8 {
        const cas_fn = self.cas_fn orelse return error.TailscaleServeCasUnavailable;
        return cas_fn(self.context, allocator, etag, config);
    }
};

pub const SystemRunner = struct {
    io: std.Io,

    pub fn runner(self: *SystemRunner) Runner {
        return .{ .context = self, .run_fn = run, .cas_fn = compareAndSetServeConfig };
    }

    fn run(context: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        const self: *SystemRunner = @ptrCast(@alignCast(context));
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(256 * 1024),
        });
        return .{
            .code = switch (result.term) {
                .exited => |code| code,
                else => 1,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn runLocalCredentials(self: *SystemRunner, allocator: std.mem.Allocator) !CommandResult {
        const result = try std.process.run(allocator, self.io, .{
            .argv = &.{ "tailscale", "debug", "local-creds" },
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        return .{
            .code = switch (result.term) {
                .exited => |code| code,
                else => 1,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }

    fn compareAndSetServeConfig(context: *anyopaque, allocator: std.mem.Allocator, etag: []const u8, config: []const u8) ![]u8 {
        const self: *SystemRunner = @ptrCast(@alignCast(context));
        if (!validEtag(etag)) return error.InvalidTailscaleStatus;
        // On Windows this command starts a persistent proxy and does not exit.
        if (builtin.os.tag == .windows) return error.TailscaleServeCasUnavailable;

        var credentials = self.runLocalCredentials(allocator) catch return error.TailscaleServeCasUnavailable;
        defer {
            std.crypto.secureZero(u8, credentials.stdout);
            credentials.deinit(allocator);
        }
        if (credentials.code != 0) return error.TailscaleServeCasUnavailable;
        if (credentials.stdout.len > 16 * 1024) return error.TailscaleServeCasUnavailable;
        const endpoint = parseLocalApiEndpoint(credentials.stdout) catch
            return error.TailscaleServeCasUnavailable;
        var authorization: ?[]u8 = null;
        defer if (authorization) |value| {
            std.crypto.secureZero(u8, value);
            allocator.free(value);
        };
        var host_buffer: [32]u8 = undefined;
        var host_header: []const u8 = "local-tailscaled.sock";
        var stream = switch (endpoint) {
            .unix_socket => |socket_path| blk: {
                const address = std.Io.net.UnixAddress.init(socket_path) catch
                    return error.TailscaleServeCasUnavailable;
                break :blk address.connect(self.io) catch return error.TailscaleServeCasUnavailable;
            },
            .authenticated_localhost => |local| blk: {
                authorization = basicAuthorization(allocator, local.token) catch
                    return error.TailscaleServeCasUnavailable;
                host_header = std.fmt.bufPrint(&host_buffer, "localhost:{d}", .{local.port}) catch
                    return error.TailscaleServeCasUnavailable;
                const address = std.Io.net.IpAddress.parse("127.0.0.1", local.port) catch
                    return error.TailscaleServeCasUnavailable;
                break :blk address.connect(self.io, .{
                    .mode = .stream,
                    .protocol = null,
                    .timeout = .none,
                }) catch return error.TailscaleServeCasUnavailable;
            },
        };
        defer stream.close(self.io);

        var write_buffer: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &write_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "POST /localapi/v0/serve-config HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "If-Match: {s}\r\n" ++
                "Content-Length: {d}\r\n",
            .{ host_header, etag, config.len },
        );
        if (authorization) |value| {
            try writer.interface.print("Authorization: Basic {s}\r\n", .{value});
        }
        try writer.interface.writeAll("Connection: close\r\n\r\n");
        try writer.interface.writeAll(config);
        try writer.interface.flush();

        var read_buffer: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        const response = reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch
            return error.TailscaleServeConfigureFailed;
        defer allocator.free(response);
        const status = httpStatus(response) orelse return error.TailscaleServeConfigureFailed;
        try validateCasStatus(status);

        // The POST response has no ETag. Verify the complete stored config and
        // capture its checksum before treating the mutation as owned.
        var verify = try run(context, allocator, &.{ "tailscale", "debug", "localapi", "--v", "serve-config" });
        defer verify.deinit(allocator);
        if (verify.code != 0) return error.TailscaleServePostwriteUnverified;
        const snapshot = parseServeSnapshot(verify.stdout) catch
            return error.TailscaleServePostwriteUnverified;
        if (!jsonEquivalent(allocator, config, snapshot.config)) {
            return error.TailscaleServePostwriteUnverified;
        }
        return allocator.dupe(u8, snapshot.etag);
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    origin: []u8,
    listener_url: []u8,
    target: []u8,
    current_target: ?[]u8,
    etag: []u8,
    desired_config: ?[]u8,
    owned_etag: ?[]u8 = null,
    handler_count: usize,
    https_port: u16,
    state: ListenerState,

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.origin);
        self.allocator.free(self.listener_url);
        self.allocator.free(self.target);
        if (self.current_target) |value| self.allocator.free(value);
        self.allocator.free(self.etag);
        if (self.desired_config) |value| self.allocator.free(value);
        if (self.owned_etag) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const DiagnosticCode = enum {
    tailscale_serve_available,
    tailscale_serve_matching,
    tailscale_serve_collision,
};

pub const Diagnostic = struct {
    schema_version: u32 = 1,
    ok: bool,
    code: DiagnosticCode,
    state: ListenerState,
    endpoint: []const u8,
    requested_target: []const u8,
    current_target: ?[]const u8,
    handler_count: usize,
    https_port: u16,
    safe_to_configure: bool,
    suggested_https_port: ?u16 = null,
    recovery_choices: []const []const u8 = &.{},
};

pub fn diagnostic(prepared: Prepared) Diagnostic {
    return switch (prepared.state) {
        .available => .{
            .ok = true,
            .code = .tailscale_serve_available,
            .state = .available,
            .endpoint = prepared.listener_url,
            .requested_target = prepared.target,
            .current_target = prepared.current_target,
            .handler_count = prepared.handler_count,
            .https_port = prepared.https_port,
            .safe_to_configure = true,
        },
        .matching => .{
            .ok = true,
            .code = .tailscale_serve_matching,
            .state = .matching,
            .endpoint = prepared.listener_url,
            .requested_target = prepared.target,
            .current_target = prepared.current_target,
            .handler_count = prepared.handler_count,
            .https_port = prepared.https_port,
            .safe_to_configure = true,
        },
        .collision => .{
            .ok = false,
            .code = .tailscale_serve_collision,
            .state = .collision,
            .endpoint = prepared.listener_url,
            .requested_target = prepared.target,
            .current_target = prepared.current_target,
            .handler_count = prepared.handler_count,
            .https_port = prepared.https_port,
            .safe_to_configure = false,
            .suggested_https_port = if (prepared.https_port == 8443) 8444 else 8443,
            .recovery_choices = &.{
                "choose_alternate_https_port",
                "keep_existing_listener_and_use_ssh",
                "remove_existing_listener_manually_after_verifying_ownership",
            },
        },
    };
}

pub const Intent = struct {
    schema_version: u32 = 1,
    origin: []const u8,
    target: []const u8,
    https_port: u16 = DEFAULT_HTTPS_PORT,
    verde_owned: bool,
    owned_etag: ?[]const u8 = null,
};

/// Verifies login, discovers the stable MagicDNS name, and refuses to alter a
/// non-Verde Serve configuration. No command is evaluated by a shell.
pub fn prepare(allocator: std.mem.Allocator, runner: Runner, gateway_port: u16, https_port: u16) !Prepared {
    if (gateway_port == 0 or https_port == 0) return error.InvalidPort;
    var version = runner.run(allocator, &.{ "tailscale", "version" }) catch return error.TailscaleCliMissing;
    defer version.deinit(allocator);
    if (version.code != 0) return error.TailscaleCliUnavailable;

    var status = try runner.run(allocator, &.{ "tailscale", "status", "--json" });
    defer status.deinit(allocator);
    if (status.code != 0) return error.TailscaleNotRunning;
    const dns_name = try magicDnsName(allocator, status.stdout);
    defer allocator.free(dns_name);
    const origin = if (https_port == DEFAULT_HTTPS_PORT)
        try std.fmt.allocPrint(allocator, "https://{s}", .{dns_name})
    else
        try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ dns_name, https_port });
    errdefer allocator.free(origin);
    const listener_url = try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ dns_name, https_port });
    errdefer allocator.free(listener_url);
    const target = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{gateway_port});
    errdefer allocator.free(target);

    var serve = try runner.run(allocator, &.{ "tailscale", "debug", "localapi", "--v", "serve-config" });
    defer serve.deinit(allocator);
    if (serve.code != 0) return error.TailscaleServeStatusFailed;
    const snapshot = try parseServeSnapshot(serve.stdout);
    const etag = try allocator.dupe(u8, snapshot.etag);
    errdefer allocator.free(etag);
    const authority = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ dns_name, https_port });
    defer allocator.free(authority);
    const classification = try classifyServeStatus(allocator, snapshot.config, authority, target);
    errdefer if (classification.current_target) |value| allocator.free(value);
    const desired_config = if (classification.state == .available)
        try buildConfiguredServeConfig(allocator, snapshot.config, authority, target)
    else
        null;
    errdefer if (desired_config) |value| allocator.free(value);
    return .{
        .allocator = allocator,
        .origin = origin,
        .listener_url = listener_url,
        .target = target,
        .current_target = classification.current_target,
        .etag = etag,
        .desired_config = desired_config,
        .owned_etag = null,
        .handler_count = classification.handler_count,
        .https_port = https_port,
        .state = classification.state,
    };
}

pub fn apply(allocator: std.mem.Allocator, runner: Runner, prepared: *Prepared) !void {
    if (prepared.state == .collision) return error.TailscaleServeConflict;
    if (prepared.state == .matching) return;
    const desired_config = prepared.desired_config orelse return error.InvalidTailscaleStatus;
    prepared.owned_etag = try runner.compareAndSetServeConfig(allocator, prepared.etag, desired_config);
}

pub const Cleanup = enum { removed, not_owned, missing, preserved_changed };
pub const PendingIntentState = enum { created, existing_unowned, existing_owned };

/// Removes only the one HTTPS listener Verde created, and only while both the
/// MagicDNS origin and sole proxy target still match the saved intent.
pub fn rollbackExact(
    allocator: std.mem.Allocator,
    runner: Runner,
    origin: []const u8,
    target: []const u8,
    https_port: u16,
    owned_etag: ?[]const u8,
) !Cleanup {
    var status = try runner.run(allocator, &.{ "tailscale", "status", "--json" });
    defer status.deinit(allocator);
    if (status.code != 0) return .preserved_changed;
    const dns_name = magicDnsName(allocator, status.stdout) catch return .preserved_changed;
    defer allocator.free(dns_name);
    const current_origin = if (https_port == DEFAULT_HTTPS_PORT)
        try std.fmt.allocPrint(allocator, "https://{s}", .{dns_name})
    else
        try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ dns_name, https_port });
    defer allocator.free(current_origin);
    if (!std.mem.eql(u8, current_origin, origin)) return .preserved_changed;

    var serve = try runner.run(allocator, &.{ "tailscale", "debug", "localapi", "--v", "serve-config" });
    defer serve.deinit(allocator);
    const authority = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ dns_name, https_port });
    defer allocator.free(authority);
    if (serve.code != 0) return .preserved_changed;
    const snapshot = parseServeSnapshot(serve.stdout) catch return .preserved_changed;
    const expected_etag = owned_etag orelse return .preserved_changed;
    if (!std.mem.eql(u8, snapshot.etag, expected_etag)) return .preserved_changed;
    const classification = try classifyServeStatus(allocator, snapshot.config, authority, target);
    defer if (classification.current_target) |value| allocator.free(value);
    if (classification.state == .available) return .missing;
    if (classification.state != .matching) {
        return .preserved_changed;
    }
    const desired_config = try buildRemovedServeConfig(allocator, snapshot.config, authority);
    defer allocator.free(desired_config);
    const removed_etag = runner.compareAndSetServeConfig(allocator, snapshot.etag, desired_config) catch |err| switch (err) {
        error.TailscaleServeChanged => return .preserved_changed,
        else => return error.TailscaleServeCleanupFailed,
    };
    allocator.free(removed_etag);
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
    if (intent.value.schema_version != 1 or intent.value.https_port == 0) return error.InvalidTailscaleIntent;
    if (!intent.value.verde_owned) return .not_owned;
    if (intent.value.owned_etag == null) {
        const adopted_etag = try adoptLegacyOwnedIntent(
            io,
            allocator,
            runner,
            state_dir,
            intent.value,
        ) orelse return .preserved_changed;
        defer allocator.free(adopted_etag);
        return rollbackExact(
            allocator,
            runner,
            intent.value.origin,
            intent.value.target,
            intent.value.https_port,
            adopted_etag,
        );
    }
    return rollbackExact(
        allocator,
        runner,
        intent.value.origin,
        intent.value.target,
        intent.value.https_port,
        intent.value.owned_etag,
    );
}

fn adoptLegacyOwnedIntent(
    io: std.Io,
    allocator: std.mem.Allocator,
    runner: Runner,
    state_dir: []const u8,
    intent: Intent,
) !?[]u8 {
    var status = try runner.run(allocator, &.{ "tailscale", "status", "--json" });
    defer status.deinit(allocator);
    if (status.code != 0) return null;
    const dns_name = magicDnsName(allocator, status.stdout) catch return null;
    defer allocator.free(dns_name);
    const current_origin = if (intent.https_port == DEFAULT_HTTPS_PORT)
        try std.fmt.allocPrint(allocator, "https://{s}", .{dns_name})
    else
        try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ dns_name, intent.https_port });
    defer allocator.free(current_origin);
    if (!std.mem.eql(u8, current_origin, intent.origin)) return null;

    var serve = try runner.run(allocator, &.{ "tailscale", "debug", "localapi", "--v", "serve-config" });
    defer serve.deinit(allocator);
    if (serve.code != 0) return null;
    const snapshot = parseServeSnapshot(serve.stdout) catch return null;
    const authority = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ dns_name, intent.https_port });
    defer allocator.free(authority);
    const classification = classifyServeStatus(allocator, snapshot.config, authority, intent.target) catch return null;
    defer if (classification.current_target) |value| allocator.free(value);
    if (classification.state != .matching) return null;

    const adopted_etag = try allocator.dupe(u8, snapshot.etag);
    errdefer allocator.free(adopted_etag);
    try writeIntentRecord(io, allocator, state_dir, .{
        .origin = intent.origin,
        .target = intent.target,
        .https_port = intent.https_port,
        .verde_owned = true,
        .owned_etag = adopted_etag,
    });
    return adopted_etag;
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
    const uri = std.Uri.parse(origin) catch return error.InvalidTailscaleIntent;
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.host == null or uri.user != null or
        uri.password != null or !uri.path.isEmpty() or uri.query != null or uri.fragment != null)
    {
        return error.InvalidTailscaleIntent;
    }
    var hostname_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const hostname = try uri.getHost(&hostname_buffer);
    if (hostname.bytes.len == 0 or std.mem.indexOfAny(u8, hostname.bytes, "/?#@:") != null) return error.InvalidTailscaleIntent;
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
        "tailscale", "cert", "--cert-file", cert_path, "--key-file", key_path, hostname.bytes,
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
    var prior = priorOwnership(
        io,
        allocator,
        state_dir,
        prepared.origin,
        prepared.target,
        prepared.https_port,
    ) catch |err| switch (err) {
        error.FileNotFound => PriorOwnership{},
        else => return err,
    };
    defer prior.deinit(allocator);
    const verde_owned = prepared.state == .available or prior.owned;
    const owned_etag = if (prepared.state == .available)
        prepared.owned_etag orelse return error.TailscaleServePostwriteUnverified
    else
        prior.owned_etag;
    return writeIntentValue(
        io,
        allocator,
        state_dir,
        prepared,
        verde_owned,
        owned_etag,
    );
}

/// Records the exact prospective listener before mutation without claiming it.
pub fn writePendingIntent(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    prepared: Prepared,
) !PendingIntentState {
    const path = try std.fs.path.join(allocator, &.{ state_dir, STATE_FILE });
    defer allocator.free(path);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try writeIntentValue(io, allocator, state_dir, prepared, false, null);
            return .created;
        },
        else => return err,
    };
    defer allocator.free(existing);
    var parsed = std.json.parseFromSlice(Intent, allocator, existing, .{ .ignore_unknown_fields = false }) catch
        return error.InvalidTailscaleIntent;
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or parsed.value.https_port == 0) {
        return error.InvalidTailscaleIntent;
    }
    if (parsed.value.https_port != prepared.https_port or
        !std.mem.eql(u8, parsed.value.origin, prepared.origin) or
        !std.mem.eql(u8, parsed.value.target, prepared.target))
    {
        return error.TailscaleIntentConflict;
    }
    // Preserve an exact existing record, especially its established ownership.
    // Rewriting it as pending could discard the only recoverable cleanup proof.
    return if (parsed.value.verde_owned) .existing_owned else .existing_unowned;
}

fn writeIntentValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    prepared: Prepared,
    verde_owned: bool,
    owned_etag: ?[]const u8,
) !void {
    return writeIntentRecord(io, allocator, state_dir, .{
        .origin = prepared.origin,
        .target = prepared.target,
        .https_port = prepared.https_port,
        .verde_owned = verde_owned,
        .owned_etag = owned_etag,
    });
}

fn writeIntentRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    intent: Intent,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, state_dir);
    if (builtin.os.tag != .windows and std.posix.mode_t != u0) {
        try std.Io.Dir.cwd().setFilePermissions(io, state_dir, @enumFromInt(0o700), .{ .follow_symlinks = false });
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, intent, .{});
    defer allocator.free(encoded);
    const dir = try std.Io.Dir.openDirAbsolute(io, state_dir, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, STATE_FILE, .{
        .permissions = @enumFromInt(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded);
    try atomic.file.sync(io);
    try atomic.replace(io);
}

const PriorOwnership = struct {
    owned: bool = false,
    owned_etag: ?[]u8 = null,

    fn deinit(self: *PriorOwnership, allocator: std.mem.Allocator) void {
        if (self.owned_etag) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn priorOwnership(
    io: std.Io,
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    origin: []const u8,
    target: []const u8,
    https_port: u16,
) !PriorOwnership {
    const path = try std.fs.path.join(allocator, &.{ state_dir, STATE_FILE });
    defer allocator.free(path);
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(Intent, allocator, encoded, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or parsed.value.https_port == 0) return error.InvalidTailscaleIntent;
    if (parsed.value.https_port != https_port or
        !std.mem.eql(u8, parsed.value.origin, origin) or
        !std.mem.eql(u8, parsed.value.target, target))
    {
        return error.TailscaleIntentConflict;
    }
    return .{
        .owned = parsed.value.verde_owned,
        .owned_etag = if (parsed.value.owned_etag) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn removeIntent(io: std.Io, state_dir: []const u8) !void {
    const dir = std.Io.Dir.openDirAbsolute(io, state_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    dir.deleteFile(io, STATE_FILE) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const ServeSnapshot = struct {
    etag: []const u8,
    config: []const u8,
};

fn parseServeSnapshot(response: []u8) !ServeSnapshot {
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
        return error.InvalidTailscaleStatus;
    if (httpStatus(response) != 200) return error.TailscaleServeStatusFailed;
    var etag: ?[]const u8 = null;
    var content_length: ?usize = null;
    var chunked = false;
    var lines = std.mem.splitSequence(u8, response[0..header_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidTailscaleStatus;
        const value = std.mem.trim(u8, line[separator + 1 ..], &std.ascii.whitespace);
        const name = line[0..separator];
        if (std.ascii.eqlIgnoreCase(name, "etag")) {
            if (etag != null or !validEtag(value)) return error.InvalidTailscaleStatus;
            etag = value;
        } else if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (content_length != null) return error.InvalidTailscaleStatus;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidTailscaleStatus;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            if (chunked or !std.ascii.eqlIgnoreCase(value, "chunked")) return error.InvalidTailscaleStatus;
            chunked = true;
        }
    }
    if (chunked == (content_length != null)) return error.InvalidTailscaleStatus;
    const body = response[header_end + 4 ..];
    const framed = if (chunked)
        try decodeChunkedBody(response, header_end + 4)
    else blk: {
        const length = content_length.?;
        if (length > 1024 * 1024 or body.len != length) return error.InvalidTailscaleStatus;
        break :blk body;
    };
    const config = std.mem.trim(u8, framed, &std.ascii.whitespace);
    if (config.len == 0) return error.InvalidTailscaleStatus;
    return .{ .etag = etag orelse return error.InvalidTailscaleStatus, .config = config };
}

fn decodeChunkedBody(response: []u8, body_start: usize) ![]u8 {
    var read_index = body_start;
    var write_index = body_start;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, response, read_index, "\r\n") orelse
            return error.InvalidTailscaleStatus;
        const size_line = response[read_index..line_end];
        const extension = std.mem.indexOfScalar(u8, size_line, ';') orelse size_line.len;
        const size_text = size_line[0..extension];
        if (size_text.len == 0) return error.InvalidTailscaleStatus;
        const chunk_size = std.fmt.parseInt(usize, size_text, 16) catch
            return error.InvalidTailscaleStatus;
        read_index = line_end + 2;
        if (chunk_size == 0) {
            while (true) {
                const trailer_end = std.mem.indexOfPos(u8, response, read_index, "\r\n") orelse
                    return error.InvalidTailscaleStatus;
                if (trailer_end == read_index) {
                    if (trailer_end + 2 != response.len) return error.InvalidTailscaleStatus;
                    return response[body_start..write_index];
                }
                const trailer = response[read_index..trailer_end];
                const separator = std.mem.indexOfScalar(u8, trailer, ':') orelse
                    return error.InvalidTailscaleStatus;
                if (separator == 0) return error.InvalidTailscaleStatus;
                read_index = trailer_end + 2;
            }
        }
        if (chunk_size > 1024 * 1024 or write_index - body_start > 1024 * 1024 - chunk_size) {
            return error.InvalidTailscaleStatus;
        }
        if (chunk_size > response.len - read_index or response.len - read_index - chunk_size < 2) {
            return error.InvalidTailscaleStatus;
        }
        if (!std.mem.eql(u8, response[read_index + chunk_size .. read_index + chunk_size + 2], "\r\n")) {
            return error.InvalidTailscaleStatus;
        }
        std.mem.copyForwards(u8, response[write_index .. write_index + chunk_size], response[read_index .. read_index + chunk_size]);
        write_index += chunk_size;
        read_index += chunk_size + 2;
    }
}

fn buildConfiguredServeConfig(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    authority: []const u8,
    target: []const u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, encoded, .{ .allocate = .alloc_always }) catch
        return error.InvalidTailscaleStatus;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.InvalidTailscaleStatus,
    };
    const port = requestedPort(authority) orelse return error.InvalidTailscaleStatus;

    const tcp = try ensureObject(scratch, root, "TCP");
    var tcp_handler: std.json.ObjectMap = .empty;
    try tcp_handler.put(scratch, "HTTPS", .{ .bool = true });
    try tcp.put(scratch, port, .{ .object = tcp_handler });

    const web = try ensureObject(scratch, root, "Web");
    var root_handler: std.json.ObjectMap = .empty;
    try root_handler.put(scratch, "Proxy", .{ .string = target });
    var handlers: std.json.ObjectMap = .empty;
    try handlers.put(scratch, "/", .{ .object = root_handler });
    var listener: std.json.ObjectMap = .empty;
    try listener.put(scratch, "Handlers", .{ .object = handlers });
    try web.put(scratch, authority, .{ .object = listener });
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn buildRemovedServeConfig(allocator: std.mem.Allocator, encoded: []const u8, authority: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, scratch, encoded, .{ .allocate = .alloc_always }) catch
        return error.InvalidTailscaleStatus;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.InvalidTailscaleStatus,
    };
    const port = requestedPort(authority) orelse return error.InvalidTailscaleStatus;
    const tcp_value = root.getPtr("TCP") orelse return error.InvalidTailscaleStatus;
    const tcp = switch (tcp_value.*) {
        .object => |*object| object,
        else => return error.InvalidTailscaleStatus,
    };
    if (!tcp.orderedRemove(port)) return error.InvalidTailscaleStatus;
    if (tcp.count() == 0) _ = root.orderedRemove("TCP");

    const web_value = root.getPtr("Web") orelse return error.InvalidTailscaleStatus;
    const web = switch (web_value.*) {
        .object => |*object| object,
        else => return error.InvalidTailscaleStatus,
    };
    if (!web.orderedRemove(authority)) return error.InvalidTailscaleStatus;
    if (web.count() == 0) _ = root.orderedRemove("Web");
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn ensureObject(allocator: std.mem.Allocator, parent: *std.json.ObjectMap, key: []const u8) !*std.json.ObjectMap {
    if (parent.getPtr(key)) |value| return switch (value.*) {
        .object => |*object| object,
        else => error.InvalidTailscaleStatus,
    };
    try parent.put(allocator, key, .{ .object = .empty });
    return &parent.getPtr(key).?.object;
}

fn requestedPort(authority: []const u8) ?[]const u8 {
    const separator = std.mem.findScalarLast(u8, authority, ':') orelse return null;
    const port = authority[separator + 1 ..];
    return if (port.len == 0) null else port;
}

fn validEtag(etag: []const u8) bool {
    if (etag.len == 0 or etag.len > 256) return false;
    for (etag) |byte| if (byte <= ' ' or byte == 0x7f) return false;
    return true;
}

const LocalApiEndpoint = union(enum) {
    unix_socket: []const u8,
    authenticated_localhost: struct {
        port: u16,
        token: []const u8,
    },
};

fn parseLocalApiEndpoint(output: []const u8) !LocalApiEndpoint {
    if (output.len == 0 or output.len > 16 * 1024) return error.InvalidTailscaleCredentials;
    const line = if (std.mem.endsWith(u8, output, "\r\n"))
        output[0 .. output.len - 2]
    else if (std.mem.endsWith(u8, output, "\n"))
        output[0 .. output.len - 1]
    else
        output;
    if (line.len == 0 or line[0] <= ' ' or line[line.len - 1] <= ' ') {
        return error.InvalidTailscaleCredentials;
    }
    if (std.mem.indexOfAny(u8, line, "\r\n") != null) return error.InvalidTailscaleCredentials;

    const unix_prefix = "curl --unix-socket ";
    const unix_suffix = " http://local-tailscaled.sock/localapi/v0/status";
    if (std.mem.startsWith(u8, line, unix_prefix) and std.mem.endsWith(u8, line, unix_suffix)) {
        const path = line[unix_prefix.len .. line.len - unix_suffix.len];
        if (path.len == 0 or path.len > std.Io.Dir.max_path_bytes) {
            return error.InvalidTailscaleCredentials;
        }
        for (path) |byte| if (byte <= ' ' or byte == 0x7f) return error.InvalidTailscaleCredentials;
        return .{ .unix_socket = path };
    }

    const tcp_prefix = "curl -u:";
    const tcp_middle = " http://localhost:";
    const tcp_suffix = "/localapi/v0/status";
    if (!std.mem.startsWith(u8, line, tcp_prefix) or !std.mem.endsWith(u8, line, tcp_suffix)) {
        return error.InvalidTailscaleCredentials;
    }
    const middle = std.mem.indexOfPos(u8, line, tcp_prefix.len, tcp_middle) orelse
        return error.InvalidTailscaleCredentials;
    const token = line[tcp_prefix.len..middle];
    if (token.len == 0 or token.len > 4096) return error.InvalidTailscaleCredentials;
    for (token) |byte| if (byte <= ' ' or byte == 0x7f) return error.InvalidTailscaleCredentials;
    const port_text = line[middle + tcp_middle.len .. line.len - tcp_suffix.len];
    if (port_text.len == 0 or port_text[0] == '0') return error.InvalidTailscaleCredentials;
    for (port_text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTailscaleCredentials;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidTailscaleCredentials;
    if (port == 0) return error.InvalidTailscaleCredentials;
    return .{ .authenticated_localhost = .{ .port = port, .token = token } };
}

fn basicAuthorization(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    const source = try allocator.alloc(u8, token.len + 1);
    defer {
        std.crypto.secureZero(u8, source);
        allocator.free(source);
    }
    source[0] = ':';
    @memcpy(source[1..], token);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(source.len));
    _ = std.base64.standard.Encoder.encode(encoded, source);
    return encoded;
}

fn httpStatus(response: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse return null;
    var fields = std.mem.splitScalar(u8, response[0..line_end], ' ');
    const protocol = fields.next() orelse return null;
    if (!std.mem.startsWith(u8, protocol, "HTTP/")) return null;
    return std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch null;
}

fn validateCasStatus(status: u16) !void {
    // Tailscale's serve-config LocalAPI handler writes StatusOK only after
    // SetServeConfig succeeds; an ETag mismatch returns PreconditionFailed
    // before the configuration is stored. Other 2xx codes are not accepted.
    return switch (status) {
        200 => {},
        412 => error.TailscaleServeChanged,
        else => error.TailscaleServeConfigureFailed,
    };
}

fn jsonEquivalent(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    var left_parsed = std.json.parseFromSlice(std.json.Value, allocator, left, .{}) catch return false;
    defer left_parsed.deinit();
    var right_parsed = std.json.parseFromSlice(std.json.Value, allocator, right, .{}) catch return false;
    defer right_parsed.deinit();
    return jsonValuesEqual(left_parsed.value, right_parsed.value);
}

fn jsonValuesEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |array| {
            if (array.items.len != right.array.items.len) return false;
            for (array.items, right.array.items) |left_item, right_item| {
                if (!jsonValuesEqual(left_item, right_item)) return false;
            }
            return true;
        },
        .object => |object| {
            if (object.count() != right.object.count()) return false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const right_value = right.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonValuesEqual(entry.value_ptr.*, right_value)) return false;
            }
            return true;
        },
    };
}

const Classification = struct {
    state: ListenerState,
    current_target: ?[]u8 = null,
    handler_count: usize = 0,
};

fn classifyServeStatus(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    authority: []const u8,
    target: []const u8,
) !Classification {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded, .{}) catch
        return error.InvalidTailscaleStatus;
    defer parsed.deinit();
    if (isEmpty(parsed.value)) return .{ .state = .available };
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };

    const port = requestedPort(authority) orelse return error.InvalidTailscaleStatus;

    if (funnelEnabled(root, authority)) return .{ .state = .collision };
    if (foregroundOccupiesPort(root, port, authority)) return .{ .state = .collision };

    const tcp_value = root.get("TCP") orelse return classifyUnusedTcpPort(root, authority);
    const tcp = switch (tcp_value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    const tcp_handler_value = tcp.get(port) orelse return classifyUnusedTcpPort(root, authority);
    const tcp_handler = switch (tcp_handler_value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    if (tcp_handler.count() != 1) return .{ .state = .collision };
    const https_value = tcp_handler.get("HTTPS") orelse return .{ .state = .collision };
    switch (https_value) {
        .bool => |enabled| if (!enabled) return .{ .state = .collision },
        else => return .{ .state = .collision },
    }

    const web_value = root.get("Web") orelse return .{ .state = .collision };
    const web = switch (web_value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    const listener = web.get(authority) orelse return .{ .state = .collision };
    const listener_object = switch (listener) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    if (listener_object.count() != 1) return .{ .state = .collision };
    const handlers_value = listener_object.get("Handlers") orelse return .{ .state = .collision };
    const handlers = switch (handlers_value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    const handler_count = handlers.count();
    const root_handler_value = handlers.get("/") orelse return .{ .state = .collision, .handler_count = handler_count };
    const root_handler = switch (root_handler_value) {
        .object => |object| object,
        else => return .{ .state = .collision, .handler_count = handler_count },
    };
    if (root_handler.count() != 1) return .{ .state = .collision, .handler_count = handler_count };
    const proxy_value = root_handler.get("Proxy") orelse return .{ .state = .collision, .handler_count = handler_count };
    const proxy = switch (proxy_value) {
        .string => |value| value,
        else => return .{ .state = .collision, .handler_count = handler_count },
    };
    const current_target = try redactTarget(allocator, proxy);
    return .{
        .state = if (handler_count == 1 and !funnelEnabled(root, authority) and std.mem.eql(u8, proxy, target))
            .matching
        else
            .collision,
        .current_target = current_target,
        .handler_count = handler_count,
    };
}

fn classifyUnusedTcpPort(root: std.json.ObjectMap, authority: []const u8) Classification {
    const web_value = root.get("Web") orelse return .{ .state = .available };
    const web = switch (web_value) {
        .object => |object| object,
        else => return .{ .state = .collision },
    };
    if (web.get(authority) != null) return .{ .state = .collision };
    return .{ .state = .available };
}

fn foregroundOccupiesPort(root: std.json.ObjectMap, port: []const u8, authority: []const u8) bool {
    const foreground_value = root.get("Foreground") orelse return false;
    const foreground = switch (foreground_value) {
        .object => |object| object,
        else => return true,
    };
    var iterator = foreground.iterator();
    while (iterator.next()) |entry| {
        const config = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return true,
        };
        if (funnelEnabled(config, authority)) return true;
        const tcp_value = config.get("TCP");
        if (tcp_value) |value| {
            const tcp = switch (value) {
                .object => |object| object,
                else => return true,
            };
            if (tcp.get(port) != null) return true;
        }
        const web_value = config.get("Web") orelse continue;
        const web = switch (web_value) {
            .object => |object| object,
            else => return true,
        };
        if (web.get(authority) != null) return true;
    }
    return false;
}

fn isEmpty(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .object => |object| object.count() == 0,
        else => false,
    };
}

fn funnelEnabled(root: std.json.ObjectMap, authority: []const u8) bool {
    const allow_value = root.get("AllowFunnel") orelse return false;
    const allow = switch (allow_value) {
        .object => |object| object,
        else => return true,
    };
    const direct = allow.get(authority);
    if (direct) |value| return switch (value) {
        .bool => |enabled| enabled,
        else => true,
    };
    return false;
}

fn redactTarget(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const uri = std.Uri.parse(target) catch return allocator.dupe(u8, "configured");
    if (uri.host == null or uri.scheme.len == 0) return allocator.dupe(u8, "configured");
    for (uri.scheme) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') {
            return allocator.dupe(u8, "configured");
        }
    }
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buffer) catch return allocator.dupe(u8, "configured");
    if (host.bytes.len == 0 or std.mem.indexOfAny(u8, host.bytes, "\r\n/?#@") != null) {
        return allocator.dupe(u8, "configured");
    }
    const display_host = if (std.mem.indexOfScalar(u8, host.bytes, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]", .{host.bytes})
    else
        try allocator.dupe(u8, host.bytes);
    defer allocator.free(display_host);
    return if (uri.port) |port|
        std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ uri.scheme, display_host, port })
    else
        std.fmt.allocPrint(allocator, "{s}://{s}", .{ uri.scheme, display_host });
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
    mutation_called: bool = false,
    https_port: ?u16 = null,
    cas_calls: usize = 0,
    cas_changed: bool = false,
    cas_config: ?[]u8 = null,

    fn runner(self: *FakeRunner) Runner {
        return .{ .context = self, .run_fn = run, .cas_fn = compareAndSetServeConfig };
    }

    fn deinit(self: *FakeRunner) void {
        if (self.cas_config) |value| std.testing.allocator.free(value);
    }

    fn run(context: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        if (argv.len > 0 and std.mem.eql(u8, argv[argv.len - 1], "off")) self.off_called = true;
        for (argv) |arg| {
            if (std.mem.eql(u8, arg, "reset") or std.mem.eql(u8, arg, "--all")) self.unsafe_called = true;
            if (std.mem.startsWith(u8, arg, "--https=")) {
                self.mutation_called = true;
                self.https_port = std.fmt.parseInt(u16, arg["--https=".len..], 10) catch null;
            }
        }
        const value = self.outputs[self.calls];
        self.calls += 1;
        var localapi = false;
        for (argv) |arg| if (std.mem.eql(u8, arg, "localapi")) {
            localapi = true;
        };
        const stdout = if (localapi)
            try std.fmt.allocPrint(
                allocator,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nEtag: test-etag\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ value.stdout.len, value.stdout },
            )
        else
            try allocator.dupe(u8, value.stdout);
        return .{
            .code = value.code,
            .stdout = stdout,
            .stderr = try allocator.dupe(u8, value.stderr),
        };
    }

    fn compareAndSetServeConfig(context: *anyopaque, allocator: std.mem.Allocator, _: []const u8, config: []const u8) ![]u8 {
        const self: *FakeRunner = @ptrCast(@alignCast(context));
        self.cas_calls += 1;
        self.mutation_called = true;
        if (self.cas_changed) return error.TailscaleServeChanged;
        if (self.cas_config) |value| allocator.free(value);
        self.cas_config = try allocator.dupe(u8, config);
        return allocator.dupe(u8, "post-etag");
    }
};

test "preflight discovers MagicDNS and reuses only the exact Verde mapping" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net.\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("https://runtime.tail.ts.net", prepared.origin);
    try std.testing.expectEqualStrings("https://runtime.tail.ts.net:443", prepared.listener_url);
    try std.testing.expectEqual(ListenerState.matching, prepared.state);
}

test "occupied ServeConfig forms are collisions" {
    const fixtures = [_][]const u8{
        // A raw TCP forward owns the requested TCP port without a Web entry.
        "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:22\"}}}",
        // Plain HTTP is not Verde's HTTPS listener, even with the same proxy.
        "{\"TCP\":{\"443\":{\"HTTP\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}",
        // An HTTPS TCP handler without its Web route is only a partial config.
        "{\"TCP\":{\"443\":{\"HTTPS\":true}}}",
        // A malformed handler still occupies the requested TCP key.
        "{\"TCP\":{\"443\":[]}}",
        // The full HTTPS listener exists, but its root proxy belongs elsewhere.
        "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}",
        // Foreground listeners are never owned by Verde's background command.
        "{\"Foreground\":{\"session-1\":{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}}}",
        // Orphan Funnel authorization still exposes the requested authority.
        "{\"AllowFunnel\":{\"runtime.tail.ts.net:443\":true}}",
        // Foreground Funnel authorization occupies the authority without TCP/Web.
        "{\"Foreground\":{\"session-1\":{\"AllowFunnel\":{\"runtime.tail.ts.net:443\":true}}}}",
    };
    for (fixtures) |fixture| {
        const classification = try classifyServeStatus(
            std.testing.allocator,
            fixture,
            "runtime.tail.ts.net:443",
            "http://127.0.0.1:7420",
        );
        defer if (classification.current_target) |value| std.testing.allocator.free(value);
        try std.testing.expectEqual(ListenerState.collision, classification.state);
    }
}

test "ServeConfig CAS accepts only documented status" {
    try validateCasStatus(200);
    try std.testing.expectError(error.TailscaleServeChanged, validateCasStatus(412));
    try std.testing.expectError(error.TailscaleServeConfigureFailed, validateCasStatus(201));
    try std.testing.expectError(error.TailscaleServeConfigureFailed, validateCasStatus(204));
}

test "verbose LocalAPI snapshot decodes content length and chunked framing" {
    const content_length_response =
        "HTTP/1.1 200 OK\r\nEtag: length-etag\r\nContent-Length: 2\r\n\r\n{}";
    const length_bytes = try std.testing.allocator.dupe(u8, content_length_response);
    defer std.testing.allocator.free(length_bytes);
    const length_snapshot = try parseServeSnapshot(length_bytes);
    try std.testing.expectEqualStrings("length-etag", length_snapshot.etag);
    try std.testing.expectEqualStrings("{}", length_snapshot.config);

    const chunked_response =
        "HTTP/1.1 200 OK\r\nEtag: chunk-etag\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "1\r\n{\r\n1\r\n}\r\n0\r\nX-Verified: yes\r\n\r\n";
    const chunked_bytes = try std.testing.allocator.dupe(u8, chunked_response);
    defer std.testing.allocator.free(chunked_bytes);
    const chunked_snapshot = try parseServeSnapshot(chunked_bytes);
    try std.testing.expectEqualStrings("chunk-etag", chunked_snapshot.etag);
    try std.testing.expectEqualStrings("{}", chunked_snapshot.config);
}

test "verbose LocalAPI snapshot rejects malformed framing" {
    const fixtures = [_][]const u8{
        "HTTP/1.1 200 OK\r\nEtag: e\r\nContent-Length: 3\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\nEtag: e\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}",
        "HTTP/1.1 200 OK\r\nEtag: e\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n",
        "HTTP/1.1 200 OK\r\nEtag: e\r\n\r\n{}",
    };
    for (fixtures) |fixture| {
        const bytes = try std.testing.allocator.dupe(u8, fixture);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(error.InvalidTailscaleStatus, parseServeSnapshot(bytes));
    }
}

test "local-creds parser accepts official Unix and authenticated localhost forms" {
    const unix = try parseLocalApiEndpoint(
        "curl --unix-socket /var/run/tailscale/tailscaled.sock http://local-tailscaled.sock/localapi/v0/status\n",
    );
    try std.testing.expectEqualStrings("/var/run/tailscale/tailscaled.sock", unix.unix_socket);
    const relative_unix = try parseLocalApiEndpoint(
        "curl --unix-socket tailscaled.sock http://local-tailscaled.sock/localapi/v0/status\n",
    );
    try std.testing.expectEqualStrings("tailscaled.sock", relative_unix.unix_socket);

    const localhost = try parseLocalApiEndpoint(
        "curl -u:x http://localhost:52808/localapi/v0/status\n",
    );
    try std.testing.expectEqual(@as(u16, 52808), localhost.authenticated_localhost.port);
    try std.testing.expectEqual(@as(usize, 1), localhost.authenticated_localhost.token.len);
    const authorization = try basicAuthorization(std.testing.allocator, localhost.authenticated_localhost.token);
    defer {
        std.crypto.secureZero(u8, authorization);
        std.testing.allocator.free(authorization);
    }
    try std.testing.expectEqual(@as(usize, 4), authorization.len);

    try std.testing.expectError(
        error.InvalidTailscaleCredentials,
        parseLocalApiEndpoint("Serving LocalAPI proxy on http://localhost:1234"),
    );
    try std.testing.expectError(
        error.InvalidTailscaleCredentials,
        parseLocalApiEndpoint("curl -u:x http://localhost:052808/localapi/v0/status\n"),
    );
    try std.testing.expectError(
        error.InvalidTailscaleCredentials,
        parseLocalApiEndpoint("curl -u:x http://127.0.0.1:52808/localapi/v0/status\n"),
    );
    try std.testing.expectError(
        error.InvalidTailscaleCredentials,
        parseLocalApiEndpoint(" curl --unix-socket relative.sock http://local-tailscaled.sock/localapi/v0/status\n"),
    );
}

test "lifecycle lock serializes independent file handles and releases cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const state_dir = buffer[0..length];
    var first = try LifecycleLock.acquire(std.testing.io, state_dir);
    errdefer first.deinit(std.testing.io);
    try std.testing.expectError(
        error.WouldBlock,
        tmp.dir.openFile(std.testing.io, LOCK_FILE, .{
            .mode = .read_write,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }),
    );
    first.deinit(std.testing.io);

    const after_release = try tmp.dir.openFile(std.testing.io, LOCK_FILE, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    after_release.close(std.testing.io);
}

test "cleanup removes only an unchanged exact mapping without reset" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net.\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast(""), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(Cleanup.removed, try rollbackExact(
        std.testing.allocator,
        fake.runner(),
        "https://runtime.tail.ts.net",
        "http://127.0.0.1:7420",
        443,
        "test-etag",
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    try std.testing.expect(!fake.off_called);
    try std.testing.expect(!fake.unsafe_called);
}

test "cleanup preserves a mapping after a foreign handler appears" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"},\"/other\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(Cleanup.preserved_changed, try rollbackExact(
        std.testing.allocator,
        fake.runner(),
        "https://runtime.tail.ts.net",
        "http://127.0.0.1:7420",
        443,
        "test-etag",
    ));
    try std.testing.expect(!fake.off_called);
    try std.testing.expect(!fake.unsafe_called);
    try std.testing.expectEqual(@as(usize, 2), fake.calls);
}

test "cleanup preserves an exact mapping when its CAS snapshot changes" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs, .cas_changed = true };
    defer fake.deinit();
    try std.testing.expectEqual(Cleanup.preserved_changed, try rollbackExact(
        std.testing.allocator,
        fake.runner(),
        "https://runtime.tail.ts.net",
        "http://127.0.0.1:7420",
        443,
        "test-etag",
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    try std.testing.expect(fake.cas_config == null);
}

test "cleanup preserves an exact mapping after any visible global config change" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(Cleanup.preserved_changed, try rollbackExact(
        std.testing.allocator,
        fake.runner(),
        "https://runtime.tail.ts.net",
        "http://127.0.0.1:7420",
        443,
        "older-owned-etag",
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.cas_calls);
}

test "legacy owned intent atomically adopts an exact current ETag before cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const state_dir = buffer[0..length];
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = STATE_FILE,
        .data = "{\"schema_version\":1,\"origin\":\"https://runtime.tail.ts.net\",\"target\":\"http://127.0.0.1:7420\",\"https_port\":443,\"verde_owned\":true,\"owned_etag\":null}",
    });
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(
        Cleanup.removed,
        try cleanupSaved(std.testing.io, std.testing.allocator, fake.runner(), state_dir),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    const encoded = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(encoded);
    var intent = try std.json.parseFromSlice(Intent, std.testing.allocator, encoded, .{});
    defer intent.deinit();
    try std.testing.expect(intent.value.verde_owned);
    try std.testing.expectEqualStrings("test-etag", intent.value.owned_etag.?);
}

test "legacy owned intent preserves a non-exact current mapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const state_dir = buffer[0..length];
    const legacy = "{\"schema_version\":1,\"origin\":\"https://runtime.tail.ts.net\",\"target\":\"http://127.0.0.1:7420\",\"https_port\":443,\"verde_owned\":true,\"owned_etag\":null}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = STATE_FILE, .data = legacy });
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(
        Cleanup.preserved_changed,
        try cleanupSaved(std.testing.io, std.testing.allocator, fake.runner(), state_dir),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.cas_calls);
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings(legacy, preserved);
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
        .listener_url = try std.testing.allocator.dupe(u8, "https://runtime.tail.ts.net:443"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1:7420"),
        .current_target = null,
        .etag = try std.testing.allocator.dupe(u8, "test-etag"),
        .desired_config = try std.testing.allocator.dupe(u8, "{}"),
        .owned_etag = try std.testing.allocator.dupe(u8, "post-etag"),
        .handler_count = 0,
        .https_port = 443,
        .state = .available,
    };
    defer created.deinit();
    try writeIntent(std.testing.io, std.testing.allocator, state_dir, created);
    const pending_state = try writePendingIntent(std.testing.io, std.testing.allocator, state_dir, created);
    try std.testing.expectEqual(PendingIntentState.existing_owned, pending_state);
    const preserved = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(preserved);
    var preserved_intent = try std.json.parseFromSlice(Intent, std.testing.allocator, preserved, .{});
    defer preserved_intent.deinit();
    try std.testing.expect(preserved_intent.value.verde_owned);

    var different: Prepared = .{
        .allocator = std.testing.allocator,
        .origin = try std.testing.allocator.dupe(u8, "https://other.tail.ts.net"),
        .listener_url = try std.testing.allocator.dupe(u8, "https://other.tail.ts.net:443"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1:9000"),
        .current_target = null,
        .etag = try std.testing.allocator.dupe(u8, "test-etag"),
        .desired_config = try std.testing.allocator.dupe(u8, "{}"),
        .handler_count = 0,
        .https_port = 443,
        .state = .available,
    };
    defer different.deinit();
    try std.testing.expectError(
        error.TailscaleIntentConflict,
        writePendingIntent(std.testing.io, std.testing.allocator, state_dir, different),
    );
    var reused: Prepared = .{
        .allocator = std.testing.allocator,
        .origin = try std.testing.allocator.dupe(u8, created.origin),
        .listener_url = try std.testing.allocator.dupe(u8, created.listener_url),
        .target = try std.testing.allocator.dupe(u8, created.target),
        .current_target = try std.testing.allocator.dupe(u8, created.target),
        .etag = try std.testing.allocator.dupe(u8, "test-etag"),
        .desired_config = null,
        .handler_count = 1,
        .https_port = 443,
        .state = .matching,
    };
    defer reused.deinit();
    try writeIntent(std.testing.io, std.testing.allocator, state_dir, reused);
    const encoded = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(Intent, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.verde_owned);
    try std.testing.expectEqualStrings("post-etag", parsed.value.owned_etag.?);
}

test "CAS conflict retains a newly created pending recovery intent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &buffer);
    const state_dir = buffer[0..length];
    var prepared: Prepared = .{
        .allocator = std.testing.allocator,
        .origin = try std.testing.allocator.dupe(u8, "https://runtime.tail.ts.net"),
        .listener_url = try std.testing.allocator.dupe(u8, "https://runtime.tail.ts.net:443"),
        .target = try std.testing.allocator.dupe(u8, "http://127.0.0.1:7420"),
        .current_target = null,
        .etag = try std.testing.allocator.dupe(u8, "test-etag"),
        .desired_config = try std.testing.allocator.dupe(u8, "{}"),
        .handler_count = 0,
        .https_port = 443,
        .state = .available,
    };
    defer prepared.deinit();
    try std.testing.expectEqual(
        PendingIntentState.created,
        try writePendingIntent(std.testing.io, std.testing.allocator, state_dir, prepared),
    );

    var fake: FakeRunner = .{ .outputs = &.{}, .cas_changed = true };
    defer fake.deinit();
    try std.testing.expectError(
        error.TailscaleServeChanged,
        apply(std.testing.allocator, fake.runner(), &prepared),
    );

    const encoded = try tmp.dir.readFileAlloc(std.testing.io, STATE_FILE, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(encoded);
    var intent = try std.json.parseFromSlice(Intent, std.testing.allocator, encoded, .{});
    defer intent.deinit();
    try std.testing.expect(!intent.value.verde_owned);
    try std.testing.expect(intent.value.owned_etag == null);
    try std.testing.expectEqualStrings(prepared.origin, intent.value.origin);
    try std.testing.expectEqualStrings(prepared.target, intent.value.target);
}

test "preflight reports a typed collision without applying commands" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqual(ListenerState.collision, prepared.state);
    const report = diagnostic(prepared);
    try std.testing.expectEqual(DiagnosticCode.tailscale_serve_collision, report.code);
    try std.testing.expectEqualStrings("https://runtime.tail.ts.net:443", report.endpoint);
    try std.testing.expect(!report.safe_to_configure);
    try std.testing.expectEqual(@as(?u16, 8443), report.suggested_https_port);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, report, .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"schema_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"code\":\"tailscale_serve_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"endpoint\":\"https://runtime.tail.ts.net:443\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"current_target\":\"http://127.0.0.1:8080\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"choose_alternate_https_port\"") != null);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    try std.testing.expect(!fake.mutation_called);
}

test "apply fails closed when the ServeConfig ETag changes" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.102.3"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs, .cas_changed = true };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqual(ListenerState.available, prepared.state);
    try std.testing.expectError(
        error.TailscaleServeChanged,
        apply(std.testing.allocator, fake.runner(), &prepared),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    try std.testing.expect(fake.cas_config == null);
}

test "foreign target diagnostics redact credentials and request details" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.102.3"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"https://alice:secret@foreign.example:8443/private/token?api_key=hunter2#fragment\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqualStrings("https://foreign.example:8443", prepared.current_target.?);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, diagnostic(prepared), .{});
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "fragment") == null);
}

test "an extra path on the selected listener is a collision" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"},\"/openclaw\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqual(ListenerState.collision, prepared.state);
    try std.testing.expect(!fake.mutation_called);
}

test "Funnel on the selected listener is a collision even for the requested backend" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}},\"AllowFunnel\":{\"runtime.tail.ts.net:443\":true}}"), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 443);
    defer prepared.deinit();
    try std.testing.expectEqual(ListenerState.collision, prepared.state);
    try std.testing.expect(!fake.mutation_called);
}

test "an unrelated 443 listener allows a dedicated Verde HTTPS port" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("1.92.0"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}}}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast(""), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    var prepared = try prepare(std.testing.allocator, fake.runner(), 7420, 8443);
    defer prepared.deinit();
    try std.testing.expectEqual(ListenerState.available, prepared.state);
    try std.testing.expectEqualStrings("https://runtime.tail.ts.net:8443", prepared.origin);
    try apply(std.testing.allocator, fake.runner(), &prepared);
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    try std.testing.expectEqual(@as(usize, 3), fake.calls);
    const classification = try classifyServeStatus(
        std.testing.allocator,
        fake.cas_config.?,
        "runtime.tail.ts.net:8443",
        "http://127.0.0.1:7420",
    );
    defer if (classification.current_target) |value| std.testing.allocator.free(value);
    try std.testing.expectEqual(ListenerState.matching, classification.state);
    try std.testing.expect(!fake.unsafe_called);
}

test "cleanup targets only the saved dedicated HTTPS listener" {
    const outputs = [_]CommandResult{
        .{ .code = 0, .stdout = @constCast("{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"runtime.tail.ts.net\"}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast("{\"TCP\":{\"443\":{\"HTTPS\":true},\"8443\":{\"HTTPS\":true}},\"Web\":{\"runtime.tail.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8080\"}}},\"runtime.tail.ts.net:8443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7420\"}}}}}"), .stderr = @constCast("") },
        .{ .code = 0, .stdout = @constCast(""), .stderr = @constCast("") },
    };
    var fake: FakeRunner = .{ .outputs = &outputs };
    defer fake.deinit();
    try std.testing.expectEqual(Cleanup.removed, try rollbackExact(
        std.testing.allocator,
        fake.runner(),
        "https://runtime.tail.ts.net:8443",
        "http://127.0.0.1:7420",
        8443,
        "test-etag",
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.cas_calls);
    try std.testing.expect(!fake.off_called);
    try std.testing.expect(!fake.unsafe_called);
}
