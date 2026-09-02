//! Provider-neutral single-flight connector reconciliation.

const std = @import("std");

pub const Connector = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (*anyopaque, []u8) anyerror!void,
        stop: *const fn (*anyopaque) anyerror!void,
        running: *const fn (*anyopaque) bool,
    };

    pub fn start(self: Connector, enrollment_secret: []u8) !void {
        return self.vtable.start(self.context, enrollment_secret);
    }

    pub fn stop(self: Connector) !void {
        return self.vtable.stop(self.context);
    }

    pub fn running(self: Connector) bool {
        return self.vtable.running(self.context);
    }
};

pub const Desired = enum { unlinked, linked };
pub const Outcome = union(enum) {
    steady,
    started,
    stopped,
    retry_at_ms: i64,
};

pub const Reconciler = struct {
    connector: Connector,
    reconciling: bool = false,
    attempt: u16 = 0,
    jitter_seed: u64,

    pub fn init(connector: Connector, runtime_id: []const u8) Reconciler {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(runtime_id, &digest, .{});
        return .{
            .connector = connector,
            .jitter_seed = std.mem.readInt(u64, digest[0..8], .big),
        };
    }

    /// Reconcile once. Enrollment secret ownership transfers to this call and
    /// is cleared before return on every success or failure path.
    pub fn reconcile(
        self: *Reconciler,
        desired: Desired,
        enrollment_secret: ?[]u8,
        now_ms: i64,
    ) !Outcome {
        if (self.reconciling) return error.ConnectorReconcileInProgress;
        self.reconciling = true;
        defer self.reconciling = false;
        defer if (enrollment_secret) |secret| std.crypto.secureZero(u8, secret);

        if (desired == .unlinked) {
            self.attempt = 0;
            if (!self.connector.running()) return .steady;
            try self.connector.stop();
            return .stopped;
        }
        if (self.connector.running()) {
            self.attempt = 0;
            return .steady;
        }
        const secret = enrollment_secret orelse return error.ConnectorEnrollmentRequired;
        self.connector.start(secret) catch {
            self.attempt +|= 1;
            return .{ .retry_at_ms = now_ms + self.retryDelayMs() };
        };
        self.attempt = 0;
        return .started;
    }

    fn retryDelayMs(self: Reconciler) i64 {
        const exponent: u4 = @intCast(@min(self.attempt, 10));
        const base: u64 = @min(@as(u64, 300_000), @as(u64, 1_000) << exponent);
        var prng = std.Random.DefaultPrng.init(self.jitter_seed ^ self.attempt);
        const jitter = prng.random().uintLessThan(u64, @max(@as(u64, 1), base / 4));
        return @intCast(@min(@as(u64, 300_000), base + jitter));
    }
};

/// The public reference service's external endpoint provider needs no local
/// connector process; the operator owns its endpoint lifecycle.
pub const ExternalAdapter = struct {
    pub fn connector(self: *ExternalAdapter) Connector {
        return .{ .context = self, .vtable = &.{
            .start = start,
            .stop = stop,
            .running = running,
        } };
    }

    fn start(_: *anyopaque, _: []u8) !void {
        return error.ExternalEndpointHasNoConnector;
    }

    fn stop(_: *anyopaque) !void {}
    fn running(_: *anyopaque) bool {
        return false;
    }
};

const FakeAdapter = struct {
    is_running: bool = false,
    starts: usize = 0,
    stops: usize = 0,
    fail_starts: usize = 0,
    observed_secret_nonzero: bool = false,

    fn connector(self: *FakeAdapter) Connector {
        return .{ .context = self, .vtable = &.{
            .start = start,
            .stop = stop,
            .running = running,
        } };
    }

    fn start(raw: *anyopaque, secret: []u8) !void {
        const self: *FakeAdapter = @ptrCast(@alignCast(raw));
        self.starts += 1;
        self.observed_secret_nonzero = std.mem.indexOfNone(u8, secret, &.{0}) != null;
        if (self.fail_starts > 0) {
            self.fail_starts -= 1;
            return error.FakeStartFailed;
        }
        self.is_running = true;
    }

    fn stop(raw: *anyopaque) !void {
        const self: *FakeAdapter = @ptrCast(@alignCast(raw));
        self.stops += 1;
        self.is_running = false;
    }

    fn running(raw: *anyopaque) bool {
        const self: *FakeAdapter = @ptrCast(@alignCast(raw));
        return self.is_running;
    }
};

test "connector reconciliation is single-owner across restart and unlink" {
    var fake: FakeAdapter = .{};
    var first = Reconciler.init(fake.connector(), "runtime-a");
    var secret = [_]u8{0xa5} ** 32;
    try std.testing.expectEqual(Outcome.started, try first.reconcile(.linked, &secret, 1_000));
    try std.testing.expect(fake.observed_secret_nonzero);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &secret);
    try std.testing.expectEqual(Outcome.steady, try first.reconcile(.linked, null, 1_001));
    try std.testing.expectEqual(@as(usize, 1), fake.starts);

    // A recreated reconciler observes the same owned process and never starts
    // a duplicate. If the process disappeared, the recovered enrollment is
    // consumed exactly once to restart it.
    var restarted = Reconciler.init(fake.connector(), "runtime-a");
    try std.testing.expectEqual(Outcome.steady, try restarted.reconcile(.linked, null, 2_000));
    fake.is_running = false;
    var recovered_secret = [_]u8{0x5a} ** 32;
    try std.testing.expectEqual(Outcome.started, try restarted.reconcile(.linked, &recovered_secret, 2_001));
    try std.testing.expectEqual(@as(usize, 2), fake.starts);
    try std.testing.expectEqual(Outcome.stopped, try restarted.reconcile(.unlinked, null, 3_000));
    try std.testing.expectEqual(@as(usize, 1), fake.stops);
}

test "connector retries are bounded, jittered, and secrets are cleared" {
    var fake: FakeAdapter = .{ .fail_starts = 1 };
    var reconciler = Reconciler.init(fake.connector(), "runtime-b");
    var secret = [_]u8{0xcc} ** 32;
    const outcome = try reconciler.reconcile(.linked, &secret, 10_000);
    const retry_at = outcome.retry_at_ms;
    try std.testing.expect(retry_at > 11_000 and retry_at <= 312_000);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &secret);
}
