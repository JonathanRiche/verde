//! Token-file verification and bounded browser-session authentication.

const builtin = @import("builtin");
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Digest = [Sha256.digest_length]u8;

pub const TOKEN_MIN_BYTES: usize = 32;
pub const TOKEN_MAX_BYTES: usize = 4 * 1024;
pub const SESSION_ENTROPY_BYTES: usize = 32;
pub const SESSION_ID_BYTES: usize = SESSION_ENTROPY_BYTES * 2;
pub const MAX_SESSIONS: usize = 128;
pub const DEFAULT_MAX_SESSIONS: usize = 64;
pub const DEFAULT_SESSION_TTL_MS: i64 = 8 * 60 * 60 * 1000;
pub const SESSION_COOKIE_NAME = "verde_session";
pub const SESSION_COOKIE_ATTRIBUTES = "Path=/; HttpOnly; SameSite=Strict";

/// A fixed-size verifier. Raw token bytes are erased after initialization and
/// never retained in gateway configuration or authentication state.
pub const TokenVerifier = struct {
    digest: Digest,

    /// Opens a regular file without following its final symlink, validates its
    /// POSIX permissions, and derives the fixed token verifier.
    pub fn initFromFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        token_file: []const u8,
    ) !TokenVerifier {
        return initFromDir(allocator, io, std.Io.Dir.cwd(), token_file);
    }

    pub fn deinit(self: *TokenVerifier) void {
        std.crypto.secureZero(u8, self.digest[0..]);
        self.* = undefined;
    }

    /// Hashes every bounded candidate and compares fixed-size digests in
    /// constant time. Candidate length is public HTTP framing information.
    pub fn verify(self: *const TokenVerifier, presented: []const u8) bool {
        if (presented.len > TOKEN_MAX_BYTES) return false;
        var candidate = digestSecret(presented);
        defer std.crypto.secureZero(u8, candidate[0..]);
        return std.crypto.timing_safe.eql(Digest, self.digest, candidate);
    }

    fn initFromDir(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        token_file: []const u8,
    ) !TokenVerifier {
        if (token_file.len == 0) return error.TokenFileRequired;
        const file = dir.openFile(io, token_file, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.SymLinkLoop => return error.TokenFileSymlink,
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return error.TokenFileNotRegular;
        if (comptime builtin.os.tag != .windows and std.posix.mode_t != u0) {
            const mode = stat.permissions.toMode();
            if (mode & 0o077 != 0) return error.InsecureTokenFilePermissions;
        }
        try validateTokenFileOwner(file);
        if (stat.size > TOKEN_MAX_BYTES) return error.TokenTooLong;

        var read_buffer: [1024]u8 = undefined;
        defer std.crypto.secureZero(u8, read_buffer[0..]);
        var reader = file.reader(io, &read_buffer);
        const raw = reader.interface.allocRemaining(
            allocator,
            .limited(TOKEN_MAX_BYTES + 1),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.TokenTooLong,
            else => return err,
        };
        defer {
            std.crypto.secureZero(u8, raw);
            allocator.free(raw);
        }

        const token = std.mem.trim(u8, raw, &std.ascii.whitespace);
        try validateToken(token);
        return .{ .digest = digestSecret(token) };
    }
};

fn validateTokenFileOwner(file: std.Io.File) !void {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var native_stat: linux.Statx = undefined;
        const result = linux.statx(
            file.handle,
            "",
            linux.AT.EMPTY_PATH,
            .{ .UID = true },
            &native_stat,
        );
        if (linux.errno(result) != .SUCCESS or !native_stat.mask.UID) {
            return error.TokenFileOwnerCheckFailed;
        }
        if (native_stat.uid != linux.geteuid()) return error.TokenFileOwnerMismatch;
    } else if (comptime builtin.os.tag == .macos) {
        var native_stat: std.c.Stat = undefined;
        if (std.c.fstat(file.handle, &native_stat) != 0) {
            return error.TokenFileOwnerCheckFailed;
        }
        if (native_stat.uid != std.c.geteuid()) return error.TokenFileOwnerMismatch;
    }
}

/// The browser-visible bearer returned once when a session is created.
pub const IssuedSession = struct {
    id: [SESSION_ID_BYTES]u8,
    expires_at_ms: i64,
    max_age_seconds: u32,

    pub fn clear(self: *IssuedSession) void {
        std.crypto.secureZero(u8, self.id[0..]);
        self.expires_at_ms = 0;
        self.max_age_seconds = 0;
    }
};

pub const SessionOptions = struct {
    max_sessions: usize = DEFAULT_MAX_SESSIONS,
    ttl_ms: i64 = DEFAULT_SESSION_TTL_MS,
};

/// Fixed-capacity, synchronized browser sessions. Only SHA-256 digests of
/// session IDs are retained after `create` returns.
pub const SessionManager = struct {
    const Entry = struct {
        active: bool = false,
        digest: Digest = @splat(0),
        expires_at_ms: i64 = 0,
    };

    mutex: std.Io.Mutex = .init,
    entries: [MAX_SESSIONS]Entry = [_]Entry{.{}} ** MAX_SESSIONS,
    max_sessions: usize,
    ttl_ms: i64,

    pub fn init(options: SessionOptions) !SessionManager {
        if (options.max_sessions == 0 or options.max_sessions > MAX_SESSIONS) {
            return error.InvalidSessionLimit;
        }
        if (options.ttl_ms <= 0) return error.InvalidSessionTtl;
        return .{
            .max_sessions = options.max_sessions,
            .ttl_ms = options.ttl_ms,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        std.crypto.secureZero(Entry, self.entries[0..]);
    }

    pub fn create(self: *SessionManager, io: std.Io, now_ms: i64) !IssuedSession {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        _ = self.pruneLocked(now_ms);
        const slot = self.availableSlot() orelse return error.TooManySessions;

        var entropy: [SESSION_ENTROPY_BYTES]u8 = undefined;
        defer std.crypto.secureZero(u8, entropy[0..]);
        var issued: IssuedSession = undefined;
        var attempt: u8 = 0;
        while (attempt < 4) : (attempt += 1) {
            try std.Io.randomSecure(io, entropy[0..]);
            issued.id = std.fmt.bytesToHex(entropy, .lower);
            const candidate = digestSecret(issued.id[0..]);
            if (!self.containsDigest(candidate)) {
                const expires_at_ms = saturatingAdd(now_ms, self.ttl_ms);
                const ttl_seconds: i64 = @max(1, @divTrunc(self.ttl_ms, 1000));
                issued.expires_at_ms = expires_at_ms;
                issued.max_age_seconds = @intCast(@min(ttl_seconds, std.math.maxInt(u32)));
                self.entries[slot] = .{
                    .active = true,
                    .digest = candidate,
                    .expires_at_ms = expires_at_ms,
                };
                return issued;
            }
        }
        return error.RandomCollision;
    }

    pub fn validate(
        self: *SessionManager,
        io: std.Io,
        presented_id: []const u8,
        now_ms: i64,
    ) !bool {
        if (presented_id.len != SESSION_ID_BYTES) return false;
        var candidate = digestSecret(presented_id);
        defer std.crypto.secureZero(u8, candidate[0..]);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        _ = self.pruneLocked(now_ms);
        return self.containsDigest(candidate);
    }

    pub fn revoke(
        self: *SessionManager,
        io: std.Io,
        presented_id: []const u8,
    ) !bool {
        if (presented_id.len != SESSION_ID_BYTES) return false;
        var candidate = digestSecret(presented_id);
        defer std.crypto.secureZero(u8, candidate[0..]);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        var revoked = false;
        for (self.entries[0..self.max_sessions]) |*entry| {
            if (entry.active and std.crypto.timing_safe.eql(Digest, entry.digest, candidate)) {
                clearEntry(entry);
                revoked = true;
            }
        }
        return revoked;
    }

    pub fn prune(self: *SessionManager, io: std.Io, now_ms: i64) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.pruneLocked(now_ms);
    }

    pub fn count(self: *SessionManager, io: std.Io, now_ms: i64) !usize {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        _ = self.pruneLocked(now_ms);
        var active: usize = 0;
        for (self.entries[0..self.max_sessions]) |entry| {
            if (entry.active) active += 1;
        }
        return active;
    }

    fn availableSlot(self: *SessionManager) ?usize {
        for (self.entries[0..self.max_sessions], 0..) |entry, index| {
            if (!entry.active) return index;
        }
        return null;
    }

    fn containsDigest(self: *const SessionManager, candidate: Digest) bool {
        var found = false;
        for (self.entries[0..self.max_sessions]) |entry| {
            if (entry.active) {
                found = std.crypto.timing_safe.eql(Digest, entry.digest, candidate) or found;
            }
        }
        return found;
    }

    fn pruneLocked(self: *SessionManager, now_ms: i64) usize {
        var pruned: usize = 0;
        for (self.entries[0..self.max_sessions]) |*entry| {
            if (entry.active and entry.expires_at_ms <= now_ms) {
                clearEntry(entry);
                pruned += 1;
            }
        }
        return pruned;
    }
};

pub const MAX_RATE_LIMIT_CLIENTS: usize = 64;
pub const DEFAULT_LOGIN_FAILURES: u8 = 5;
pub const DEFAULT_LOGIN_WINDOW_MS: i64 = 60 * 1000;
pub const DEFAULT_LOGIN_BLOCK_MS: i64 = 5 * 60 * 1000;

pub const RateLimitDecision = enum { allowed, rate_limited };

pub const RateLimitOptions = struct {
    max_clients: usize = MAX_RATE_LIMIT_CLIENTS,
    max_failures: u8 = DEFAULT_LOGIN_FAILURES,
    window_ms: i64 = DEFAULT_LOGIN_WINDOW_MS,
    block_ms: i64 = DEFAULT_LOGIN_BLOCK_MS,
};

/// Bounded per-client failed-login limiter. Once its client table is full it
/// fails closed for unseen clients until an expired bucket can be pruned.
pub const LoginRateLimiter = struct {
    const Bucket = struct {
        active: bool = false,
        client_digest: Digest = @splat(0),
        window_started_ms: i64 = 0,
        blocked_until_ms: i64 = 0,
        failures: u8 = 0,
    };

    mutex: std.Io.Mutex = .init,
    buckets: [MAX_RATE_LIMIT_CLIENTS]Bucket = [_]Bucket{.{}} ** MAX_RATE_LIMIT_CLIENTS,
    options: RateLimitOptions,

    pub fn init(options: RateLimitOptions) !LoginRateLimiter {
        if (options.max_clients == 0 or options.max_clients > MAX_RATE_LIMIT_CLIENTS) {
            return error.InvalidRateLimitCapacity;
        }
        if (options.max_failures == 0 or options.window_ms <= 0 or options.block_ms <= 0) {
            return error.InvalidRateLimitPolicy;
        }
        return .{ .options = options };
    }

    pub fn deinit(self: *LoginRateLimiter) void {
        std.crypto.secureZero(Bucket, self.buckets[0..]);
    }

    /// Reject an already blocked client before an expensive credential check.
    /// A full table also fails closed for an unseen client.
    pub fn preflight(
        self: *LoginRateLimiter,
        io: std.Io,
        client_key: []const u8,
        now_ms: i64,
    ) !RateLimitDecision {
        var client_digest = digestSecret(client_key);
        defer std.crypto.secureZero(u8, client_digest[0..]);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);
        if (self.findBucket(client_digest)) |bucket| {
            return if (bucket.blocked_until_ms > now_ms) .rate_limited else .allowed;
        }
        return if (self.availableBucket() == null) .rate_limited else .allowed;
    }

    /// Records one token comparison result. A successful credential clears a
    /// non-blocked bucket; a credential cannot bypass an existing block.
    pub fn recordAttempt(
        self: *LoginRateLimiter,
        io: std.Io,
        client_key: []const u8,
        credential_valid: bool,
        now_ms: i64,
    ) !RateLimitDecision {
        var client_digest = digestSecret(client_key);
        defer std.crypto.secureZero(u8, client_digest[0..]);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);

        if (self.findBucket(client_digest)) |bucket| {
            if (bucket.blocked_until_ms > now_ms) return .rate_limited;
            if (credential_valid) {
                clearBucket(bucket);
                return .allowed;
            }
            if (now_ms >= saturatingAdd(bucket.window_started_ms, self.options.window_ms)) {
                bucket.window_started_ms = now_ms;
                bucket.failures = 0;
            }
            bucket.failures +|= 1;
            if (bucket.failures >= self.options.max_failures) {
                bucket.blocked_until_ms = saturatingAdd(now_ms, self.options.block_ms);
            }
            return .allowed;
        }

        if (credential_valid) return .allowed;
        const bucket = self.availableBucket() orelse return .rate_limited;
        bucket.* = .{
            .active = true,
            .client_digest = client_digest,
            .window_started_ms = now_ms,
            .failures = 1,
        };
        if (self.options.max_failures == 1) {
            bucket.blocked_until_ms = saturatingAdd(now_ms, self.options.block_ms);
        }
        return .allowed;
    }

    fn findBucket(self: *LoginRateLimiter, client_digest: Digest) ?*Bucket {
        for (self.buckets[0..self.options.max_clients]) |*bucket| {
            if (bucket.active and
                std.crypto.timing_safe.eql(Digest, bucket.client_digest, client_digest))
            {
                return bucket;
            }
        }
        return null;
    }

    fn availableBucket(self: *LoginRateLimiter) ?*Bucket {
        for (self.buckets[0..self.options.max_clients]) |*bucket| {
            if (!bucket.active) return bucket;
        }
        return null;
    }

    fn pruneLocked(self: *LoginRateLimiter, now_ms: i64) void {
        for (self.buckets[0..self.options.max_clients]) |*bucket| {
            if (!bucket.active) continue;
            const retention_end = saturatingAdd(
                @max(bucket.window_started_ms, bucket.blocked_until_ms),
                self.options.window_ms,
            );
            if (retention_end <= now_ms) clearBucket(bucket);
        }
    }
};

pub const LoginResult = union(enum) {
    session: IssuedSession,
    invalid_credentials,
    rate_limited,
};

pub const PAIR_TOKEN_ENTROPY_BYTES: usize = 32;
pub const PAIR_TOKEN_BYTES: usize = PAIR_TOKEN_ENTROPY_BYTES * 2;
pub const MAX_ACCESS_TOKENS: usize = 256;
pub const MAX_WEBSOCKET_TICKETS: usize = 256;
pub const DEFAULT_ACCESS_TOKEN_TTL_MS: i64 = 15 * 60 * 1000;
pub const DEFAULT_WEBSOCKET_TICKET_TTL_MS: i64 = 30 * 1000;

pub const PairClaims = struct {
    device_id: [32]u8,
    scope_mask: u16,
    deadline_ms: i64,

    pub fn clear(self: *PairClaims) void {
        std.crypto.secureZero(u8, self.device_id[0..]);
        self.* = undefined;
    }
};

pub const IssuedPairCredential = struct {
    value: [PAIR_TOKEN_BYTES]u8,
    /// Unix timestamp returned on the wire. Validation uses the separate
    /// monotonic deadline retained only in the verifier entry.
    expires_at_ms: i64,

    pub fn clear(self: *IssuedPairCredential) void {
        std.crypto.secureZero(u8, self.value[0..]);
        self.* = undefined;
    }
};

pub const PairCredentialOptions = struct {
    max_access_tokens: usize = MAX_ACCESS_TOKENS,
    max_websocket_tickets: usize = MAX_WEBSOCKET_TICKETS,
    access_token_ttl_ms: i64 = DEFAULT_ACCESS_TOKEN_TTL_MS,
    websocket_ticket_ttl_ms: i64 = DEFAULT_WEBSOCKET_TICKET_TTL_MS,
};

/// Bounded verifier-only storage for short-lived access tokens and one-use
/// WebSocket tickets. Raw bearer values exist only in the returned structs.
pub const PairCredentialManager = struct {
    const AccessEntry = struct {
        active: bool = false,
        digest: Digest = @splat(0),
        claims: PairClaims = .{
            .device_id = @splat(0),
            .scope_mask = 0,
            .deadline_ms = 0,
        },
    };
    const TicketEntry = AccessEntry;

    mutex: std.Io.Mutex = .init,
    access_entries: [MAX_ACCESS_TOKENS]AccessEntry = [_]AccessEntry{.{}} ** MAX_ACCESS_TOKENS,
    ticket_entries: [MAX_WEBSOCKET_TICKETS]TicketEntry = [_]TicketEntry{.{}} ** MAX_WEBSOCKET_TICKETS,
    options: PairCredentialOptions,

    pub fn init(options: PairCredentialOptions) !PairCredentialManager {
        if (options.max_access_tokens == 0 or options.max_access_tokens > MAX_ACCESS_TOKENS or
            options.max_websocket_tickets == 0 or options.max_websocket_tickets > MAX_WEBSOCKET_TICKETS)
        {
            return error.InvalidPairCredentialLimit;
        }
        if (options.access_token_ttl_ms <= 0 or options.websocket_ticket_ttl_ms <= 0) {
            return error.InvalidPairCredentialTtl;
        }
        return .{ .options = options };
    }

    pub fn deinit(self: *PairCredentialManager) void {
        std.crypto.secureZero(AccessEntry, self.access_entries[0..]);
        std.crypto.secureZero(TicketEntry, self.ticket_entries[0..]);
    }

    pub fn issueAccessToken(
        self: *PairCredentialManager,
        io: std.Io,
        device_id: []const u8,
        scope_mask: u16,
        now_ms: i64,
        unix_now_ms: i64,
    ) !IssuedPairCredential {
        if (device_id.len != 32 or scope_mask == 0 or now_ms < 0 or unix_now_ms < 0) {
            return error.InvalidPairClaims;
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);
        const entries = self.access_entries[0..self.options.max_access_tokens];
        const slot = entryForDevice(entries, device_id) orelse availableEntry(entries) orelse
            return error.TooManyAccessTokens;
        const deadline_ms = saturatingAdd(now_ms, self.options.access_token_ttl_ms);
        const expires_at_ms = saturatingAdd(unix_now_ms, self.options.access_token_ttl_ms);
        return self.issueLocked(io, slot, device_id, scope_mask, deadline_ms, expires_at_ms);
    }

    pub fn validateAccessToken(
        self: *PairCredentialManager,
        io: std.Io,
        presented: []const u8,
        now_ms: i64,
    ) !?PairClaims {
        if (presented.len != PAIR_TOKEN_BYTES or now_ms < 0) return null;
        var candidate = digestSecret(presented);
        defer std.crypto.secureZero(u8, candidate[0..]);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);
        return findClaims(self.access_entries[0..self.options.max_access_tokens], candidate);
    }

    pub fn issueWebSocketTicket(
        self: *PairCredentialManager,
        io: std.Io,
        claims: PairClaims,
        now_ms: i64,
        unix_now_ms: i64,
    ) !IssuedPairCredential {
        if (claims.scope_mask == 0 or claims.deadline_ms <= now_ms or now_ms < 0 or unix_now_ms < 0) {
            return error.InvalidPairClaims;
        }
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);
        const entries = self.ticket_entries[0..self.options.max_websocket_tickets];
        const slot = entryForDevice(entries, claims.device_id[0..]) orelse availableEntry(entries) orelse
            return error.TooManyWebSocketTickets;
        const ticket_deadline = @min(
            claims.deadline_ms,
            saturatingAdd(now_ms, self.options.websocket_ticket_ttl_ms),
        );
        const expires_at_ms = saturatingAdd(unix_now_ms, ticket_deadline - now_ms);
        return self.issueLocked(
            io,
            slot,
            claims.device_id[0..],
            claims.scope_mask,
            ticket_deadline,
            expires_at_ms,
        );
    }

    /// Atomically validate and erase a WebSocket ticket. Concurrent callers
    /// cannot both observe the same ticket as active.
    pub fn consumeWebSocketTicket(
        self: *PairCredentialManager,
        io: std.Io,
        presented: []const u8,
        now_ms: i64,
    ) !?PairClaims {
        if (presented.len != PAIR_TOKEN_BYTES or now_ms < 0) return null;
        var candidate = digestSecret(presented);
        defer std.crypto.secureZero(u8, candidate[0..]);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        self.pruneLocked(now_ms);
        for (self.ticket_entries[0..self.options.max_websocket_tickets]) |*entry| {
            if (!entry.active or !std.crypto.timing_safe.eql(Digest, entry.digest, candidate)) continue;
            const claims = entry.claims;
            clearPairEntry(entry);
            return claims;
        }
        return null;
    }

    /// Erase every short-lived credential for a device after durable
    /// authorization reports that the device is no longer accepted.
    pub fn clearDeviceCredentials(
        self: *PairCredentialManager,
        io: std.Io,
        device_id: []const u8,
    ) !void {
        if (device_id.len != 32) return error.InvalidPairClaims;
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        clearDeviceEntries(self.access_entries[0..self.options.max_access_tokens], device_id);
        clearDeviceEntries(self.ticket_entries[0..self.options.max_websocket_tickets], device_id);
    }

    fn issueLocked(
        self: *PairCredentialManager,
        io: std.Io,
        slot: *AccessEntry,
        device_id: []const u8,
        scope_mask: u16,
        deadline_ms: i64,
        expires_at_ms: i64,
    ) !IssuedPairCredential {
        var entropy: [PAIR_TOKEN_ENTROPY_BYTES]u8 = undefined;
        defer std.crypto.secureZero(u8, entropy[0..]);
        var attempt: u8 = 0;
        while (attempt < 4) : (attempt += 1) {
            try std.Io.randomSecure(io, entropy[0..]);
            var issued: IssuedPairCredential = .{
                .value = std.fmt.bytesToHex(entropy, .lower),
                .expires_at_ms = expires_at_ms,
            };
            const candidate = digestSecret(issued.value[0..]);
            if (findClaims(self.access_entries[0..self.options.max_access_tokens], candidate) != null or
                findClaims(self.ticket_entries[0..self.options.max_websocket_tickets], candidate) != null)
            {
                issued.clear();
                continue;
            }
            var copied_id: [32]u8 = undefined;
            @memcpy(copied_id[0..], device_id);
            slot.* = .{
                .active = true,
                .digest = candidate,
                .claims = .{
                    .device_id = copied_id,
                    .scope_mask = scope_mask,
                    .deadline_ms = deadline_ms,
                },
            };
            return issued;
        }
        return error.RandomCollision;
    }

    fn pruneLocked(self: *PairCredentialManager, now_ms: i64) void {
        for (self.access_entries[0..self.options.max_access_tokens]) |*entry| {
            if (entry.active and entry.claims.deadline_ms <= now_ms) clearPairEntry(entry);
        }
        for (self.ticket_entries[0..self.options.max_websocket_tickets]) |*entry| {
            if (entry.active and entry.claims.deadline_ms <= now_ms) clearPairEntry(entry);
        }
    }
};

/// Thread-safe authentication facade intended for the HTTP gateway owner.
pub const Service = struct {
    token: TokenVerifier,
    sessions: SessionManager,
    rate_limiter: LoginRateLimiter,
    pair_rate_limiter: LoginRateLimiter,
    connect_rate_limiter: LoginRateLimiter,
    device_rate_limiter: LoginRateLimiter,
    ticket_rate_limiter: LoginRateLimiter,
    pair_credentials: PairCredentialManager,

    pub fn initFromTokenFile(
        allocator: std.mem.Allocator,
        io: std.Io,
        token_file: []const u8,
        session_options: SessionOptions,
        rate_limit_options: RateLimitOptions,
    ) !Service {
        var token = try TokenVerifier.initFromFile(allocator, io, token_file);
        errdefer token.deinit();
        var sessions = try SessionManager.init(session_options);
        errdefer sessions.deinit();
        return .{
            .token = token,
            .sessions = sessions,
            .rate_limiter = try LoginRateLimiter.init(rate_limit_options),
            .pair_rate_limiter = try LoginRateLimiter.init(rate_limit_options),
            .connect_rate_limiter = try LoginRateLimiter.init(rate_limit_options),
            .device_rate_limiter = try LoginRateLimiter.init(rate_limit_options),
            .ticket_rate_limiter = try LoginRateLimiter.init(rate_limit_options),
            .pair_credentials = try PairCredentialManager.init(.{}),
        };
    }

    pub fn deinit(self: *Service) void {
        self.pair_credentials.deinit();
        self.ticket_rate_limiter.deinit();
        self.device_rate_limiter.deinit();
        self.connect_rate_limiter.deinit();
        self.pair_rate_limiter.deinit();
        self.rate_limiter.deinit();
        self.sessions.deinit();
        self.token.deinit();
    }

    pub fn verifyBearer(self: *const Service, bearer: []const u8) bool {
        return self.token.verify(bearer);
    }

    pub fn login(
        self: *Service,
        io: std.Io,
        client_key: []const u8,
        presented_token: []const u8,
        now_ms: i64,
    ) !LoginResult {
        const valid = self.token.verify(presented_token);
        const decision = try self.rate_limiter.recordAttempt(io, client_key, valid, now_ms);
        if (decision == .rate_limited) return .rate_limited;
        if (!valid) return .invalid_credentials;
        return .{ .session = try self.sessions.create(io, now_ms) };
    }

    pub fn verifySession(
        self: *Service,
        io: std.Io,
        session_id: []const u8,
        now_ms: i64,
    ) !bool {
        return self.sessions.validate(io, session_id, now_ms);
    }

    pub fn logout(self: *Service, io: std.Io, session_id: []const u8) !bool {
        return self.sessions.revoke(io, session_id);
    }

    pub fn pairPreflight(self: *Service, io: std.Io, client_key: []const u8, now_ms: i64) !RateLimitDecision {
        return self.pair_rate_limiter.preflight(io, client_key, now_ms);
    }

    pub fn recordPairAttempt(
        self: *Service,
        io: std.Io,
        client_key: []const u8,
        credential_valid: bool,
        now_ms: i64,
    ) !RateLimitDecision {
        return self.pair_rate_limiter.recordAttempt(io, client_key, credential_valid, now_ms);
    }

    pub fn connectPreflight(self: *Service, io: std.Io, client_key: []const u8, now_ms: i64) !RateLimitDecision {
        return self.connect_rate_limiter.preflight(io, client_key, now_ms);
    }

    pub fn recordConnectAttempt(
        self: *Service,
        io: std.Io,
        client_key: []const u8,
        credential_valid: bool,
        now_ms: i64,
    ) !RateLimitDecision {
        return self.connect_rate_limiter.recordAttempt(io, client_key, credential_valid, now_ms);
    }

    pub fn devicePreflight(self: *Service, io: std.Io, client_key: []const u8, now_ms: i64) !RateLimitDecision {
        return self.device_rate_limiter.preflight(io, client_key, now_ms);
    }

    pub fn recordDeviceAttempt(
        self: *Service,
        io: std.Io,
        client_key: []const u8,
        credential_valid: bool,
        now_ms: i64,
    ) !RateLimitDecision {
        return self.device_rate_limiter.recordAttempt(io, client_key, credential_valid, now_ms);
    }

    pub fn ticketPreflight(self: *Service, io: std.Io, client_key: []const u8, now_ms: i64) !RateLimitDecision {
        return self.ticket_rate_limiter.preflight(io, client_key, now_ms);
    }

    pub fn recordTicketAttempt(
        self: *Service,
        io: std.Io,
        client_key: []const u8,
        credential_valid: bool,
        now_ms: i64,
    ) !RateLimitDecision {
        return self.ticket_rate_limiter.recordAttempt(io, client_key, credential_valid, now_ms);
    }
};

/// Formats cookie metadata for either an HTTP SSH forward or the configured
/// HTTPS proxy. HttpOnly and SameSite=Strict remain mandatory in both modes.
pub fn formatSessionCookie(buffer: []u8, issued: *const IssuedSession, secure: bool) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        SESSION_COOKIE_NAME ++ "={s}; " ++ SESSION_COOKIE_ATTRIBUTES ++ "; Max-Age={d}{s}",
        .{ issued.id[0..], issued.max_age_seconds, if (secure) "; Secure" else "" },
    );
}

pub fn formatClearSessionCookie(buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        SESSION_COOKIE_NAME ++ "=; " ++ SESSION_COOKIE_ATTRIBUTES ++ "; Max-Age=0",
        .{},
    );
}

pub fn nowMillis(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

pub fn unixNowMillis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

fn validateToken(token: []const u8) !void {
    if (token.len < TOKEN_MIN_BYTES) return error.WeakToken;
    if (token.len > TOKEN_MAX_BYTES) return error.TokenTooLong;
    for (token) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidTokenEncoding;
    }
}

fn digestSecret(secret: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(secret, &digest, .{});
    return digest;
}

fn clearEntry(entry: *SessionManager.Entry) void {
    std.crypto.secureZero(u8, entry.digest[0..]);
    entry.* = .{};
}

fn clearBucket(bucket: *LoginRateLimiter.Bucket) void {
    std.crypto.secureZero(u8, bucket.client_digest[0..]);
    bucket.* = .{};
}

fn availableEntry(entries: []PairCredentialManager.AccessEntry) ?*PairCredentialManager.AccessEntry {
    for (entries) |*entry| if (!entry.active) return entry;
    return null;
}

fn entryForDevice(
    entries: []PairCredentialManager.AccessEntry,
    device_id: []const u8,
) ?*PairCredentialManager.AccessEntry {
    for (entries) |*entry| {
        if (entry.active and std.mem.eql(u8, entry.claims.device_id[0..], device_id)) return entry;
    }
    return null;
}

fn clearDeviceEntries(entries: []PairCredentialManager.AccessEntry, device_id: []const u8) void {
    for (entries) |*entry| {
        if (entry.active and std.mem.eql(u8, entry.claims.device_id[0..], device_id)) {
            clearPairEntry(entry);
        }
    }
}

fn findClaims(
    entries: []const PairCredentialManager.AccessEntry,
    candidate: Digest,
) ?PairClaims {
    var result: ?PairClaims = null;
    for (entries) |entry| {
        if (entry.active and std.crypto.timing_safe.eql(Digest, entry.digest, candidate)) {
            result = entry.claims;
        }
    }
    return result;
}

fn clearPairEntry(entry: *PairCredentialManager.AccessEntry) void {
    std.crypto.secureZero(u8, entry.digest[0..]);
    entry.claims.clear();
    entry.* = .{};
}

fn saturatingAdd(left: i64, right: i64) i64 {
    const result = @addWithOverflow(left, right);
    return if (result[1] == 0) result[0] else std.math.maxInt(i64);
}

const TEST_TOKEN = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH";

fn writeTestToken(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    contents: []const u8,
    permissions: u16,
) !void {
    try dir.writeFile(io, .{
        .sub_path = name,
        .data = contents,
        .flags = .{ .permissions = @enumFromInt(permissions) },
    });
    if (comptime builtin.os.tag != .windows and std.posix.mode_t != u0) {
        try dir.setFilePermissions(
            io,
            name,
            @enumFromInt(permissions),
            .{ .follow_symlinks = false },
        );
    }
}

test "token file must exist and be owner-only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.FileNotFound,
        TokenVerifier.initFromDir(std.testing.allocator, std.testing.io, tmp.dir, "missing"),
    );

    try writeTestToken(std.testing.io, tmp.dir, "token", TEST_TOKEN ++ "\n", 0o644);
    if (comptime builtin.os.tag != .windows and std.posix.mode_t != u0) {
        try std.testing.expectError(
            error.InsecureTokenFilePermissions,
            TokenVerifier.initFromDir(std.testing.allocator, std.testing.io, tmp.dir, "token"),
        );
        try tmp.dir.setFilePermissions(
            std.testing.io,
            "token",
            @enumFromInt(0o400),
            .{ .follow_symlinks = false },
        );
        var verifier = try TokenVerifier.initFromDir(
            std.testing.allocator,
            std.testing.io,
            tmp.dir,
            "token",
        );
        verifier.deinit();
    }
}

test "token file symlink is rejected" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestToken(std.testing.io, tmp.dir, "token", TEST_TOKEN, 0o600);
    try tmp.dir.symLink(std.testing.io, "token", "token-link", .{});
    try std.testing.expectError(
        error.TokenFileSymlink,
        TokenVerifier.initFromDir(std.testing.allocator, std.testing.io, tmp.dir, "token-link"),
    );
}

test "token verifier accepts only the exact token" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestToken(std.testing.io, tmp.dir, "token", "  " ++ TEST_TOKEN ++ "\n", 0o600);

    var verifier = try TokenVerifier.initFromDir(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "token",
    );
    defer verifier.deinit();
    try std.testing.expect(verifier.verify(TEST_TOKEN));
    try std.testing.expect(!verifier.verify("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGX"));
    try std.testing.expect(!verifier.verify(""));
}

test "weak and non-header-safe tokens are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestToken(std.testing.io, tmp.dir, "weak", "too-short", 0o600);
    try std.testing.expectError(
        error.WeakToken,
        TokenVerifier.initFromDir(std.testing.allocator, std.testing.io, tmp.dir, "weak"),
    );
    try writeTestToken(
        std.testing.io,
        tmp.dir,
        "control",
        "0123456789abcdefghijklmno\x01pqrstuvwxyz",
        0o600,
    );
    try std.testing.expectError(
        error.InvalidTokenEncoding,
        TokenVerifier.initFromDir(std.testing.allocator, std.testing.io, tmp.dir, "control"),
    );
}

test "browser sessions expire and enforce their cap" {
    var sessions = try SessionManager.init(.{ .max_sessions = 2, .ttl_ms = 100 });
    defer sessions.deinit();

    var first = try sessions.create(std.testing.io, 1_000);
    defer first.clear();
    var second = try sessions.create(std.testing.io, 1_001);
    defer second.clear();
    try std.testing.expect(try sessions.validate(std.testing.io, first.id[0..], 1_099));
    try std.testing.expectEqual(@as(usize, 2), try sessions.count(std.testing.io, 1_099));
    try std.testing.expectError(
        error.TooManySessions,
        sessions.create(std.testing.io, 1_099),
    );

    try std.testing.expect(!try sessions.validate(std.testing.io, first.id[0..], 1_100));
    try std.testing.expectEqual(@as(usize, 1), try sessions.count(std.testing.io, 1_100));
    var replacement = try sessions.create(std.testing.io, 1_100);
    defer replacement.clear();
    try std.testing.expect(try sessions.validate(std.testing.io, replacement.id[0..], 1_100));
}

test "browser sessions can be revoked and emit strict cookie metadata" {
    var sessions = try SessionManager.init(.{ .max_sessions = 1, .ttl_ms = 60_000 });
    defer sessions.deinit();
    var issued = try sessions.create(std.testing.io, 2_000);
    defer issued.clear();

    var buffer: [256]u8 = undefined;
    const cookie = try formatSessionCookie(&buffer, &issued, false);
    try std.testing.expect(std.mem.startsWith(u8, cookie, SESSION_COOKIE_NAME ++ "="));
    try std.testing.expect(std.mem.indexOf(u8, cookie, "HttpOnly") != null);
    try std.testing.expect(std.mem.indexOf(u8, cookie, "SameSite=Strict") != null);
    try std.testing.expect(try sessions.revoke(std.testing.io, issued.id[0..]));
    try std.testing.expect(!try sessions.validate(std.testing.io, issued.id[0..], 2_001));
}

test "HTTPS proxy sessions add the Secure cookie attribute" {
    var issued: IssuedSession = .{
        .id = [_]u8{'a'} ** SESSION_ID_BYTES,
        .expires_at_ms = 2_000,
        .max_age_seconds = 60,
    };
    defer issued.clear();
    var buffer: [256]u8 = undefined;
    const cookie = try formatSessionCookie(&buffer, &issued, true);
    try std.testing.expect(std.mem.endsWith(u8, cookie, "; Secure"));
}

test "failed logins are rate limited for a bounded window" {
    var limiter = try LoginRateLimiter.init(.{
        .max_clients = 2,
        .max_failures = 2,
        .window_ms = 100,
        .block_ms = 500,
    });
    defer limiter.deinit();

    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try limiter.recordAttempt(std.testing.io, "client-a", false, 1_000),
    );
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try limiter.recordAttempt(std.testing.io, "client-a", false, 1_001),
    );
    try std.testing.expectEqual(
        RateLimitDecision.rate_limited,
        try limiter.recordAttempt(std.testing.io, "client-a", true, 1_002),
    );
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try limiter.recordAttempt(std.testing.io, "client-a", true, 1_501),
    );
}

test "pair rate limiter rejects blocked clients before credential work" {
    var limiter = try LoginRateLimiter.init(.{
        .max_clients = 1,
        .max_failures = 1,
        .window_ms = 100,
        .block_ms = 500,
    });
    defer limiter.deinit();
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try limiter.preflight(std.testing.io, "client-a", 1_000),
    );
    _ = try limiter.recordAttempt(std.testing.io, "client-a", false, 1_000);
    try std.testing.expectEqual(
        RateLimitDecision.rate_limited,
        try limiter.preflight(std.testing.io, "client-a", 1_001),
    );
    try std.testing.expectEqual(
        RateLimitDecision.rate_limited,
        try limiter.preflight(std.testing.io, "unseen-full-table", 1_001),
    );
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try limiter.preflight(std.testing.io, "client-a", 1_500),
    );
}

test "credential rate limiters are independent and success clears a bucket" {
    const options: RateLimitOptions = .{
        .max_clients = 1,
        .max_failures = 1,
        .window_ms = 100,
        .block_ms = 500,
    };
    var device_limiter = try LoginRateLimiter.init(options);
    defer device_limiter.deinit();
    var ticket_limiter = try LoginRateLimiter.init(options);
    defer ticket_limiter.deinit();

    _ = try device_limiter.recordAttempt(std.testing.io, "client-a", false, 1_000);
    try std.testing.expectEqual(
        RateLimitDecision.rate_limited,
        try device_limiter.preflight(std.testing.io, "client-a", 1_001),
    );
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try ticket_limiter.preflight(std.testing.io, "client-a", 1_001),
    );
    _ = try ticket_limiter.recordAttempt(std.testing.io, "client-a", false, 1_001);
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try ticket_limiter.recordAttempt(std.testing.io, "client-a", true, 1_501),
    );
    try std.testing.expectEqual(
        RateLimitDecision.allowed,
        try ticket_limiter.preflight(std.testing.io, "client-a", 1_502),
    );
}

test "pair access tokens expire and WebSocket tickets are one use" {
    var manager = try PairCredentialManager.init(.{
        .max_access_tokens = 2,
        .max_websocket_tickets = 2,
        .access_token_ttl_ms = 100,
        .websocket_ticket_ttl_ms = 10,
    });
    defer manager.deinit();
    const device_id = "0123456789abcdef0123456789abcdef";
    var access_token = try manager.issueAccessToken(std.testing.io, device_id, 5, 1_000, 10_000);
    defer access_token.clear();
    try std.testing.expectEqual(@as(usize, PAIR_TOKEN_BYTES), access_token.value.len);
    try std.testing.expectEqual(@as(i64, 10_100), access_token.expires_at_ms);
    var claims = (try manager.validateAccessToken(
        std.testing.io,
        access_token.value[0..],
        1_099,
    )).?;
    defer claims.clear();
    try std.testing.expectEqualStrings(device_id, claims.device_id[0..]);
    try std.testing.expectEqual(@as(u16, 5), claims.scope_mask);
    try std.testing.expect((try manager.validateAccessToken(
        std.testing.io,
        access_token.value[0..],
        1_100,
    )) == null);

    claims.deadline_ms = 1_200;
    var ticket = try manager.issueWebSocketTicket(std.testing.io, claims, 1_100, 10_100);
    defer ticket.clear();
    try std.testing.expectEqual(@as(i64, 10_110), ticket.expires_at_ms);
    var consumed = (try manager.consumeWebSocketTicket(
        std.testing.io,
        ticket.value[0..],
        1_109,
    )).?;
    defer consumed.clear();
    try std.testing.expect((try manager.consumeWebSocketTicket(
        std.testing.io,
        ticket.value[0..],
        1_109,
    )) == null);
}

test "Pair credentials replace per device without consuming another device capacity" {
    var manager = try PairCredentialManager.init(.{
        .max_access_tokens = 2,
        .max_websocket_tickets = 2,
        .access_token_ttl_ms = 1_000,
        .websocket_ticket_ttl_ms = 100,
    });
    defer manager.deinit();
    const device_a = "0123456789abcdef0123456789abcdef";
    const device_b = "fedcba9876543210fedcba9876543210";

    var access_a1 = try manager.issueAccessToken(std.testing.io, device_a, 1, 1_000, 10_000);
    defer access_a1.clear();
    var access_a2 = try manager.issueAccessToken(std.testing.io, device_a, 1, 1_001, 10_001);
    defer access_a2.clear();
    var access_a3 = try manager.issueAccessToken(std.testing.io, device_a, 1, 1_002, 10_002);
    defer access_a3.clear();
    try std.testing.expect((try manager.validateAccessToken(std.testing.io, access_a1.value[0..], 1_003)) == null);
    try std.testing.expect((try manager.validateAccessToken(std.testing.io, access_a2.value[0..], 1_003)) == null);
    var claims_a = (try manager.validateAccessToken(std.testing.io, access_a3.value[0..], 1_003)).?;
    defer claims_a.clear();

    var access_b = try manager.issueAccessToken(std.testing.io, device_b, 2, 1_003, 10_003);
    defer access_b.clear();
    var claims_b = (try manager.validateAccessToken(std.testing.io, access_b.value[0..], 1_004)).?;
    defer claims_b.clear();

    var ticket_a1 = try manager.issueWebSocketTicket(std.testing.io, claims_a, 1_004, 10_004);
    defer ticket_a1.clear();
    var ticket_a2 = try manager.issueWebSocketTicket(std.testing.io, claims_a, 1_005, 10_005);
    defer ticket_a2.clear();
    var ticket_a3 = try manager.issueWebSocketTicket(std.testing.io, claims_a, 1_006, 10_006);
    defer ticket_a3.clear();
    try std.testing.expect((try manager.consumeWebSocketTicket(std.testing.io, ticket_a1.value[0..], 1_007)) == null);
    try std.testing.expect((try manager.consumeWebSocketTicket(std.testing.io, ticket_a2.value[0..], 1_007)) == null);

    var ticket_b = try manager.issueWebSocketTicket(std.testing.io, claims_b, 1_007, 10_007);
    defer ticket_b.clear();
    try manager.clearDeviceCredentials(std.testing.io, device_a);
    try std.testing.expect((try manager.validateAccessToken(std.testing.io, access_a3.value[0..], 1_008)) == null);
    try std.testing.expect((try manager.consumeWebSocketTicket(std.testing.io, ticket_a3.value[0..], 1_008)) == null);

    var surviving_b = (try manager.validateAccessToken(std.testing.io, access_b.value[0..], 1_008)).?;
    defer surviving_b.clear();
    try std.testing.expectEqualStrings(device_b, surviving_b.device_id[0..]);
    var consumed_b = (try manager.consumeWebSocketTicket(std.testing.io, ticket_b.value[0..], 1_008)).?;
    defer consumed_b.clear();
    try std.testing.expectEqualStrings(device_b, consumed_b.device_id[0..]);
}

test "concurrent access-token issuance leaves one live credential per device" {
    var manager = try PairCredentialManager.init(.{
        .max_access_tokens = 1,
        .max_websocket_tickets = 1,
    });
    defer manager.deinit();
    const device_id = "0123456789abcdef0123456789abcdef";

    const Race = struct {
        manager: *PairCredentialManager,
        device_id: []const u8,
        ready: *std.atomic.Value(u8),
        start: *std.atomic.Value(bool),
        issued: ?IssuedPairCredential = null,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var threaded = std.Io.Threaded.init_single_threaded;
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.issued = self.manager.issueAccessToken(
                threaded.io(),
                self.device_id,
                1,
                1_000,
                10_000,
            ) catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var ready: std.atomic.Value(u8) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var first: Race = .{ .manager = &manager, .device_id = device_id, .ready = &ready, .start = &start };
    var second: Race = .{ .manager = &manager, .device_id = device_id, .ready = &ready, .start = &start };
    const first_thread = try std.Thread.spawn(.{}, Race.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Race.run, .{&second});
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    defer if (first.issued) |*issued| issued.clear();
    defer if (second.issued) |*issued| issued.clear();

    var first_claims = try manager.validateAccessToken(std.testing.io, first.issued.?.value[0..], 1_001);
    defer if (first_claims) |*claims| claims.clear();
    var second_claims = try manager.validateAccessToken(std.testing.io, second.issued.?.value[0..], 1_001);
    defer if (second_claims) |*claims| claims.clear();
    try std.testing.expect((first_claims != null) != (second_claims != null));
}

test "concurrent WebSocket ticket replay has exactly one winner" {
    var manager = try PairCredentialManager.init(.{
        .max_access_tokens = 1,
        .max_websocket_tickets = 1,
    });
    defer manager.deinit();
    var claims: PairClaims = .{
        .device_id = "0123456789abcdef0123456789abcdef".*,
        .scope_mask = 1,
        .deadline_ms = 10_000,
    };
    defer claims.clear();
    var ticket = try manager.issueWebSocketTicket(std.testing.io, claims, 1_000, 10_000);
    defer ticket.clear();

    const Race = struct {
        manager: *PairCredentialManager,
        ticket: *const [PAIR_TOKEN_BYTES]u8,
        ready: *std.atomic.Value(u8),
        start: *std.atomic.Value(bool),
        consumed: bool = false,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            var threaded = std.Io.Threaded.init_single_threaded;
            _ = self.ready.fetchAdd(1, .release);
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const result = self.manager.consumeWebSocketTicket(
                threaded.io(),
                self.ticket[0..],
                1_001,
            ) catch |err| {
                self.failure = err;
                return;
            };
            if (result) |claims_value| {
                var owned = claims_value;
                owned.clear();
                self.consumed = true;
            }
        }
    };
    var ready: std.atomic.Value(u8) = .init(0);
    var start: std.atomic.Value(bool) = .init(false);
    var first: Race = .{ .manager = &manager, .ticket = &ticket.value, .ready = &ready, .start = &start };
    var second: Race = .{ .manager = &manager, .ticket = &ticket.value, .ready = &ready, .start = &start };
    const first_thread = try std.Thread.spawn(.{}, Race.run, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Race.run, .{&second});
    while (ready.load(.acquire) != 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first_thread.join();
    second_thread.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try std.testing.expect(first.consumed != second.consumed);
}
