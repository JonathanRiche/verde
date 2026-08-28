//! Narrow durable credential seam for paired-device credentials.
//!
//! Profiles persist only an opaque `credential_ref`. The credential itself
//! lives in the OS secret service when one is reachable (Linux `secret-tool`
//! over the Secret Service D-Bus API) and otherwise only in process memory.
//! The memory-only fallback is reported explicitly so the UI can tell the user
//! that the pairing will need to be repeated after Verde restarts. Plaintext
//! is never written to disk, argv, logs, or diagnostics by this module.

const std = @import("std");
const builtin = @import("builtin");
const process = @import("../platform/process.zig");
const process_env = @import("../platform/env.zig");
const secret_store = @import("secret_store.zig");

const log = std.log.scoped(.credential_store);

pub const SERVICE_ATTRIBUTE: []const u8 = "verde-runtime";
pub const CREDENTIAL_REF_PREFIX: []const u8 = "verde-runtime/";
pub const MAX_CREDENTIAL_BYTES: usize = secret_store.MAX_TOKEN_BYTES;
pub const SECRET_TOOL_TIMEOUT_MS: i64 = 10_000;

/// Which storage is backing durable credentials right now.
pub const Backend = enum {
    /// Linux Secret Service via `secret-tool`; survives restarts.
    secret_service,
    /// No usable OS store: credentials survive only until Verde exits.
    memory_only,

    pub fn durable(self: Backend) bool {
        return self == .secret_service;
    }

    pub fn description(self: Backend) []const u8 {
        return switch (self) {
            .secret_service => "OS keyring (Secret Service)",
            .memory_only => "this Verde process only — pair again after restart",
        };
    }
};

/// Process-wide store. `init` probes once; the probe result is stable for the
/// process lifetime so UI copy cannot flip between frames.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: Backend,
    memory: secret_store.Store,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .backend = detectBackend(),
            .memory = secret_store.Store.init(allocator),
        };
    }

    /// Memory-only store for tests and for callers that must not touch the
    /// OS keyring.
    pub fn initMemoryOnly(allocator: std.mem.Allocator, io: std.Io) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .backend = .memory_only,
            .memory = secret_store.Store.init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.memory.deinit();
        self.* = undefined;
    }

    /// Stores a credential under `ref`, replacing any previous value. The
    /// memory copy is always kept so a keyring hiccup cannot strand a
    /// freshly paired device mid-session.
    pub fn put(self: *Store, ref: []const u8, credential: []const u8) !void {
        try validateRef(ref);
        try secret_store.validateToken(credential);
        var key_buffer: MemoryKeyBuffer = undefined;
        try self.memory.put(memoryKey(&key_buffer, ref), credential);
        if (self.backend == .secret_service) {
            secretToolStore(self.allocator, self.io, ref, credential) catch |err| {
                log.warn("keyring store failed for credential ref (kept in memory only): {s}", .{@errorName(err)});
                return error.CredentialStoreUnavailable;
            };
        }
    }

    /// Returns a caller-owned copy or null when nothing is stored under `ref`.
    pub fn getAlloc(self: *Store, allocator: std.mem.Allocator, ref: []const u8) !?[]u8 {
        try validateRef(ref);
        var key_buffer: MemoryKeyBuffer = undefined;
        if (self.memory.get(memoryKey(&key_buffer, ref))) |held| return try allocator.dupe(u8, held);
        if (self.backend != .secret_service) return null;
        const looked_up = secretToolLookup(self.allocator, self.io, ref) catch |err| {
            log.warn("keyring lookup failed for credential ref: {s}", .{@errorName(err)});
            return error.CredentialStoreUnavailable;
        } orelse return null;
        defer eraseAndFree(self.allocator, looked_up);
        secret_store.validateToken(looked_up) catch return null;
        // Cache in memory so repeated token mints never re-prompt the keyring.
        try self.memory.put(memoryKey(&key_buffer, ref), looked_up);
        return try allocator.dupe(u8, looked_up);
    }

    /// Forgets the credential everywhere. Returns whether anything was held.
    pub fn remove(self: *Store, ref: []const u8) !bool {
        try validateRef(ref);
        var key_buffer: MemoryKeyBuffer = undefined;
        const had_memory = self.memory.remove(memoryKey(&key_buffer, ref));
        if (self.backend != .secret_service) return had_memory;
        const had_keyring = secretToolClear(self.allocator, self.io, ref) catch |err| {
            log.warn("keyring clear failed for credential ref: {s}", .{@errorName(err)});
            return error.CredentialStoreUnavailable;
        };
        return had_memory or had_keyring;
    }
};

/// Builds the canonical ref for a profile's device credential.
pub fn deviceRefAlloc(allocator: std.mem.Allocator, profile_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}/device", .{ CREDENTIAL_REF_PREFIX, profile_id });
}

pub fn validateRef(ref: []const u8) !void {
    if (!std.mem.startsWith(u8, ref, CREDENTIAL_REF_PREFIX)) return error.InvalidCredentialRef;
    if (ref.len <= CREDENTIAL_REF_PREFIX.len or ref.len > secret_store.MAX_PROFILE_ID_BYTES + CREDENTIAL_REF_PREFIX.len + "/device".len) {
        return error.InvalidCredentialRef;
    }
    for (ref) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '/' and byte != '-' and byte != '_' and byte != '.') {
            return error.InvalidCredentialRef;
        }
    }
}

const MemoryKeyBuffer = [secret_store.MAX_PROFILE_ID_BYTES]u8;

// The in-memory store restricts ids to `[A-Za-z0-9._-]`; refs contain '/'.
fn memoryKey(buffer: *MemoryKeyBuffer, ref: []const u8) []const u8 {
    const tail = ref[CREDENTIAL_REF_PREFIX.len..];
    const len = @min(tail.len, buffer.len);
    for (tail[0..len], 0..) |byte, index| buffer[index] = if (byte == '/') '.' else byte;
    return buffer[0..len];
}

fn detectBackend() Backend {
    if (builtin.os.tag != .linux) return .memory_only;
    return if (process_env.commandExists("secret-tool")) .secret_service else .memory_only;
}

// secret-tool reads the secret from stdin; only non-secret attributes are
// passed as argv so the credential never appears in process listings.
fn secretToolStore(allocator: std.mem.Allocator, io: std.Io, ref: []const u8, credential: []const u8) !void {
    const label = try std.fmt.allocPrint(allocator, "Verde runtime device credential ({s})", .{ref});
    defer allocator.free(label);
    const label_arg = try std.fmt.allocPrint(allocator, "--label={s}", .{label});
    defer allocator.free(label_arg);
    var child = try process.spawn(allocator, io, .{
        .argv = &.{ "secret-tool", "store", label_arg, "service", SERVICE_ATTRIBUTE, "ref", ref },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .own_process_tree = false,
    });
    var write_buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &write_buffer);
    {
        var writer = child.child.stdin.?.writer(io, &write_buffer);
        writer.interface.writeAll(credential) catch |err| {
            child.kill(io);
            _ = child.wait(io) catch {};
            return err;
        };
        writer.interface.flush() catch |err| {
            child.kill(io);
            _ = child.wait(io) catch {};
            return err;
        };
    }
    child.child.stdin.?.close(io);
    child.child.stdin = null;
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.SecretToolFailed;
}

fn secretToolLookup(allocator: std.mem.Allocator, io: std.Io, ref: []const u8) !?[]u8 {
    var child = try process.spawn(allocator, io, .{
        .argv = &.{ "secret-tool", "lookup", "service", SERVICE_ATTRIBUTE, "ref", ref },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .own_process_tree = false,
    });
    var read_buffer: [MAX_CREDENTIAL_BYTES + 16]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buffer);
    var reader = child.child.stdout.?.reader(io, &read_buffer);
    var collected: std.Io.Writer.Allocating = .init(allocator);
    defer {
        std.crypto.secureZero(u8, collected.writer.buffer);
        collected.deinit();
    }
    _ = reader.interface.streamRemaining(&collected.writer) catch |err| {
        child.kill(io);
        _ = child.wait(io) catch {};
        return err;
    };
    const term = try child.wait(io);
    // secret-tool exits 1 when no matching item exists; that is "not stored".
    if (term != .exited) return error.SecretToolFailed;
    if (term.exited != 0) return null;
    const trimmed = std.mem.trimEnd(u8, collected.writer.buffered(), "\r\n");
    if (trimmed.len == 0 or trimmed.len > MAX_CREDENTIAL_BYTES) return null;
    return try allocator.dupe(u8, trimmed);
}

fn secretToolClear(allocator: std.mem.Allocator, io: std.Io, ref: []const u8) !bool {
    var child = try process.spawn(allocator, io, .{
        .argv = &.{ "secret-tool", "clear", "service", SERVICE_ATTRIBUTE, "ref", ref },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .own_process_tree = false,
    });
    const term = try child.wait(io);
    if (term != .exited) return error.SecretToolFailed;
    return term.exited == 0;
}

fn eraseAndFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

test "credential refs are namespaced and shell-safe" {
    const ref = try deviceRefAlloc(std.testing.allocator, "0123456789abcdef0123456789abcdef");
    defer std.testing.allocator.free(ref);
    try std.testing.expectEqualStrings("verde-runtime/0123456789abcdef0123456789abcdef/device", ref);
    try validateRef(ref);
    try std.testing.expectError(error.InvalidCredentialRef, validateRef("other/abc/device"));
    try std.testing.expectError(error.InvalidCredentialRef, validateRef("verde-runtime/"));
    try std.testing.expectError(error.InvalidCredentialRef, validateRef("verde-runtime/a b/device"));
}

test "memory-only store round trips and forgets without touching the OS" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var store = Store.initMemoryOnly(std.testing.allocator, threaded.io());
    defer store.deinit();
    try std.testing.expect(!store.backend.durable());
    const ref = "verde-runtime/0123456789abcdef0123456789abcdef/device";
    const credential = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect((try store.getAlloc(std.testing.allocator, ref)) == null);
    try store.put(ref, credential);
    const held = (try store.getAlloc(std.testing.allocator, ref)).?;
    defer std.testing.allocator.free(held);
    try std.testing.expectEqualStrings(credential, held);
    try std.testing.expect(try store.remove(ref));
    try std.testing.expect(!try store.remove(ref));
    try std.testing.expectError(error.WeakToken, store.put(ref, "short"));
}
