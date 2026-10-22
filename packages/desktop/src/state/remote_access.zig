//! Settings → Remote access. Drives the sibling `verde-server` in desktop
//! mode (`serve --tailscale --desktop --data-dir <prefs> --json`, `service
//! uninstall --desktop`) on a worker thread. The gateway serves this app's
//! own data dir, so paired devices see these chats; `verde-server` adopts an
//! existing gateway service for it in place instead of starting a second. It
//! remembers the user's choice in `remote-access.json` beside Verde's prefs,
//! and at startup re-runs the idempotent serve when the installed service no
//! longer matches this app (version sync). Nothing here runs on the render
//! thread; the settings poll only copies finished results.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const process_env = @import("../platform/env.zig");

const allocator = std.heap.page_allocator;

pub const PREF_FILE = "remote-access.json";
pub const DEFAULT_HTTPS_PORT: u16 = 443;
pub const TAILSCALE_DOWNLOAD_URL = "https://tailscale.com/download";
pub const TAILSCALE_LOGIN_URL = "https://login.tailscale.com/";
/// Release record `verde-server` writes for the desktop gateway
/// (`desktop_gateway.zig`); older results lack `release_file`.
const GATEWAY_STATE_FILE = "desktop-gateway.json";
const MAX_OUTPUT_BYTES: usize = 256 * 1024;
const MAX_FILE_BYTES: usize = 64 * 1024;
/// Tailscale Serve mutation and user services exist only here (serve-pair-connect.md).
pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;
const SERVER_NAME = if (builtin.os.tag == .windows) "verde-server.exe" else "verde-server";

/// Fixed-capacity copy so results can cross from the worker without sharing
/// its allocations. Truncates at a UTF-8 boundary.
pub fn Text(comptime capacity: usize) type {
    return struct {
        buf: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *@This(), value: []const u8) void {
            var n = @min(value.len, capacity);
            while (n > 0 and n < value.len and value[n] & 0xC0 == 0x80) n -= 1;
            @memcpy(self.buf[0..n], value[0..n]);
            self.len = n;
        }
    };
}

/// The user's persisted choice plus what the last successful serve reported.
pub const Saved = struct {
    enabled: bool = false,
    https_port: u16 = DEFAULT_HTTPS_PORT,
    origin: Text(256) = .{},
    data_dir: Text(1024) = .{},
    state_dir: Text(1024) = .{},
    release_file: Text(1024) = .{},
    gateway_port: u16 = 0,
    unit: Text(256) = .{},
};

const SavedWire = struct {
    schema_version: u32 = 1,
    enabled: bool = false,
    https_port: u16 = DEFAULT_HTTPS_PORT,
    origin: []const u8 = "",
    data_dir: []const u8 = "",
    state_dir: []const u8 = "",
    release_file: []const u8 = "",
    gateway_port: u16 = 0,
    unit: []const u8 = "",
};

pub fn parseSaved(a: std.mem.Allocator, bytes: []const u8) !Saved {
    const parsed = try std.json.parseFromSlice(SavedWire, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.schema_version != 1 or wire.https_port == 0) return error.InvalidRemoteAccessPrefs;
    var saved: Saved = .{ .enabled = wire.enabled, .https_port = wire.https_port };
    if (wire.origin.len > 0 and !isHttpsOrigin(wire.origin)) return error.InvalidRemoteAccessPrefs;
    saved.origin.set(wire.origin);
    saved.data_dir.set(wire.data_dir);
    saved.state_dir.set(wire.state_dir);
    saved.release_file.set(wire.release_file);
    saved.gateway_port = wire.gateway_port;
    saved.unit.set(wire.unit);
    return saved;
}

pub fn encodeSaved(a: std.mem.Allocator, saved: *const Saved) ![]u8 {
    return std.json.Stringify.valueAlloc(a, SavedWire{
        .enabled = saved.enabled,
        .https_port = saved.https_port,
        .origin = saved.origin.slice(),
        .data_dir = saved.data_dir.slice(),
        .state_dir = saved.state_dir.slice(),
        .release_file = saved.release_file.slice(),
        .gateway_port = saved.gateway_port,
        .unit = saved.unit.slice(),
    }, .{});
}

/// One blocker, one action (docs/remote-access-and-pairing.md §1).
pub const Blocker = enum {
    tailscale_missing,
    tailscale_not_running,
    tailscale_not_logged_in,
    serve_collision,
    /// Another program holds the desktop gateway port.
    gateway_port_in_use,
    /// A hand-started (not service-managed) Verde gateway already serves
    /// this data dir; replacing it would mean killing a process.
    gateway_unmanaged,
    unsupported_os,
    server_missing,
    busy,
    failed,
};

pub const Action = enum { none, get_tailscale, open_tailscale, use_suggested_port, retry };

pub fn blockerAction(blocker: Blocker) Action {
    return switch (blocker) {
        .tailscale_missing => .get_tailscale,
        .tailscale_not_running, .tailscale_not_logged_in => .open_tailscale,
        .serve_collision => .use_suggested_port,
        .unsupported_os, .server_missing => .none,
        .gateway_port_in_use, .gateway_unmanaged, .busy, .failed => .retry,
    };
}

pub fn blockerSummary(blocker: Blocker) []const u8 {
    return switch (blocker) {
        .tailscale_missing => "Tailscale isn't installed on this computer.",
        .tailscale_not_running => "Tailscale isn't running on this computer.",
        .tailscale_not_logged_in => if (builtin.os.tag == .linux)
            "Tailscale isn't signed in on this computer. Sign in (for example with `sudo tailscale up`), then turn Remote access on."
        else
            "Tailscale isn't signed in on this computer. Sign in, then turn Remote access on.",
        .serve_collision => "Another app already uses this computer's Tailscale HTTPS address. Verde left it unchanged.",
        .gateway_port_in_use => "Another program is using the port Verde's gateway needs. Verde changed nothing; stop that program, then try again.",
        .gateway_unmanaged => "A Verde gateway started by hand already serves this computer. Stop it, then try again so Remote access can run it as a service.",
        .unsupported_os => "Remote access isn't available on Windows yet.",
        .server_missing => "This Verde build doesn't include verde-server. Install the full Verde package to use Remote access.",
        .busy => "Another Remote access change is in progress. Try again in a moment.",
        .failed => "Remote access couldn't be changed.",
    };
}

/// HTTPS ports Add connection → Nearby machines probes on each tailnet peer
/// (`nearby_pairing.zig`): the default and the documented collision fallback.
pub const NEARBY_PROBE_PORTS = [_]u16{ 443, 8443 };

pub fn discoverableNearby(https_port: u16) bool {
    return std.mem.indexOfScalar(u16, &NEARBY_PROBE_PORTS, https_port) != null;
}

pub const OutcomeKind = enum { ready, uninstalled, blocked };

/// Parsed `verde-server --json` result.
pub const Outcome = struct {
    kind: OutcomeKind = .blocked,
    blocker: Blocker = .failed,
    suggested_port: u16 = 0,
    https_port: u16 = DEFAULT_HTTPS_PORT,
    origin: Text(256) = .{},
    version: Text(128) = .{},
    root: Text(1024) = .{},
    data_dir: Text(1024) = .{},
    state_dir: Text(1024) = .{},
    release_file: Text(1024) = .{},
    gateway_port: u16 = 0,
    unit: Text(256) = .{},
    /// An existing gateway service was replaced in place.
    adopted: bool = false,
    /// Detail for `failed` (the server's message or last stderr line), or
    /// the program holding the gateway port.
    message: Text(512) = .{},

    fn blocked(blocker: Blocker, message: []const u8) Outcome {
        var outcome: Outcome = .{ .blocker = blocker };
        outcome.message.set(message);
        return outcome;
    }
};

/// Reads the last stdout line that is a `schema_version` object: child
/// processes (daemon init, service managers) may print before it.
pub fn parseOutput(a: std.mem.Allocator, stdout: []const u8, stderr: []const u8, exited_ok: bool) Outcome {
    var lines = std.mem.splitBackwardsScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0 or line[0] != '{') continue;
        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const object = parsed.value.object;
        if (integerField(object, "schema_version") != 1) continue;
        return outcomeFromObject(object);
    }
    if (exited_ok) return .blocked(.failed, "verde-server returned no result. It may be older than this app; update Verde.");
    return .blocked(.failed, lastStderrLine(stderr));
}

fn outcomeFromObject(object: std.json.ObjectMap) Outcome {
    const code = stringField(object, "code") orelse "";
    const ok = if (object.get("ok")) |value| value == .bool and value.bool else false;
    if (ok and std.mem.eql(u8, code, "remote_access_ready")) {
        const origin = stringField(object, "origin") orelse "";
        if (!isHttpsOrigin(origin)) return .blocked(.failed, "verde-server reported an invalid HTTPS address.");
        var outcome: Outcome = .{ .kind = .ready };
        outcome.origin.set(origin);
        outcome.https_port = std.math.cast(u16, integerField(object, "https_port") orelse DEFAULT_HTTPS_PORT) orelse DEFAULT_HTTPS_PORT;
        outcome.version.set(stringField(object, "version") orelse "");
        outcome.root.set(stringField(object, "root") orelse "");
        outcome.data_dir.set(stringField(object, "data_dir") orelse "");
        outcome.state_dir.set(stringField(object, "state_dir") orelse "");
        outcome.release_file.set(stringField(object, "release_file") orelse "");
        outcome.gateway_port = std.math.cast(u16, integerField(object, "gateway_port") orelse 0) orelse 0;
        outcome.unit.set(stringField(object, "unit") orelse "");
        outcome.adopted = if (object.get("adopted")) |value| value == .bool and value.bool else false;
        return outcome;
    }
    if (std.mem.eql(u8, code, "gateway_port_in_use") or std.mem.eql(u8, code, "gateway_unmanaged")) {
        var outcome: Outcome = .blocked(if (std.mem.eql(u8, code, "gateway_unmanaged")) .gateway_unmanaged else .gateway_port_in_use, "");
        outcome.gateway_port = std.math.cast(u16, integerField(object, "gateway_port") orelse 0) orelse 0;
        var buffer: [160]u8 = undefined;
        const process = stringField(object, "process");
        outcome.message.set(if (process) |name|
            std.fmt.bufPrint(&buffer, "Port {d} is used by {s}.", .{ outcome.gateway_port, name }) catch name
        else
            std.fmt.bufPrint(&buffer, "Port {d} is in use.", .{outcome.gateway_port}) catch "");
        return outcome;
    }
    if (ok and std.mem.eql(u8, code, "service_uninstalled")) return .{ .kind = .uninstalled };
    if (std.mem.eql(u8, code, "tailscale_serve_collision")) {
        var outcome: Outcome = .blocked(.serve_collision, "");
        outcome.https_port = std.math.cast(u16, integerField(object, "https_port") orelse DEFAULT_HTTPS_PORT) orelse DEFAULT_HTTPS_PORT;
        outcome.suggested_port = std.math.cast(u16, integerField(object, "suggested_https_port") orelse 0) orelse 0;
        return outcome;
    }
    const blocker: Blocker = if (std.mem.eql(u8, code, "tailscale_missing"))
        .tailscale_missing
    else if (std.mem.eql(u8, code, "tailscale_not_running"))
        .tailscale_not_running
    else if (std.mem.eql(u8, code, "tailscale_not_logged_in"))
        .tailscale_not_logged_in
    else if (std.mem.eql(u8, code, "unsupported_platform"))
        .unsupported_os
    else if (std.mem.eql(u8, code, "busy"))
        .busy
    else
        .failed;
    return .blocked(blocker, stringField(object, "message") orelse "");
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = object.get(name) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn lastStderrLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitBackwardsScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (line.len == 0) continue;
        const prefix = "verde-server: ";
        return if (std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else line;
    }
    return "verde-server failed without an error message.";
}

pub fn isHttpsOrigin(value: []const u8) bool {
    for (value) |byte| if (byte <= 32 or byte == 127) return false;
    const uri = std.Uri.parse(value) catch return false;
    return std.mem.eql(u8, uri.scheme, "https") and uri.host != null and !uri.host.?.isEmpty() and
        uri.user == null and uri.password == null and uri.path.isEmpty() and uri.query == null and uri.fragment == null;
}

/// Release recorded by `verde-server service install` vs. this app.
pub const Release = struct { version: []const u8, root: []const u8 };

pub const SyncDecision = enum { not_enabled, server_missing, in_sync, resync };

/// Re-serve when the installed gateway's release (or its artifact root)
/// differs from the running app, or when its record is gone. A stale gateway
/// silently lacks newer RPCs, so any difference counts, not just "older".
pub fn versionSyncDecision(enabled: bool, server_present: bool, installed: ?Release, app: Release) SyncDecision {
    if (!enabled) return .not_enabled;
    if (!server_present) return .server_missing;
    const release = installed orelse return .resync;
    if (!std.mem.eql(u8, release.version, app.version) or !std.mem.eql(u8, release.root, app.root)) return .resync;
    return .in_sync;
}

pub fn parseRelease(a: std.mem.Allocator, bytes: []const u8) ?Release {
    const Wire = struct { active_version: []const u8, active_root: []const u8 };
    const parsed = std.json.parseFromSlice(Wire, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    // Leaks into `a`, which callers pass as an arena.
    return .{ .version = parsed.value.active_version, .root = parsed.value.active_root };
}

/// Captured child result; `exited_ok` is a zero exit status.
pub const RunOutput = struct { stdout: []const u8, stderr: []const u8, exited_ok: bool };

/// Test seam: production spawns the real `verde-server`; tests never touch
/// this machine's Tailscale or services.
pub const Runner = struct {
    context: ?*anyopaque = null,
    run_fn: *const fn (?*anyopaque, std.mem.Allocator, []const []const u8) anyerror!RunOutput = spawnCaptured,

    fn run(self: Runner, a: std.mem.Allocator, argv: []const []const u8) !RunOutput {
        return self.run_fn(self.context, a, argv);
    }
};

fn spawnCaptured(_: ?*anyopaque, a: std.mem.Allocator, argv: []const []const u8) !RunOutput {
    try process_env.spawnPreflight(argv[0], null);
    // A GUI launch may lack the shell PATH that holds `tailscale`; reuse the
    // packaged-launch repair the other desktop helpers apply.
    var env_map = try process_env.buildAugmentedEnvMap(a);
    defer env_map.deinit();
    var threaded = std.Io.Threaded.init(a, .{ .environ = processEnviron() });
    defer threaded.deinit();
    const result = try std.process.run(a, threaded.io(), .{
        .argv = argv,
        .environ_map = &env_map,
        .stdout_limit = .limited(MAX_OUTPUT_BYTES),
        .stderr_limit = .limited(MAX_OUTPUT_BYTES),
    });
    const exited_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exited_ok = exited_ok };
}

fn processEnviron() std.process.Environ {
    if (builtin.os.tag == .windows) return .{ .block = .global };
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

pub const Kind = enum { startup, enable, disable };

pub const Phase = enum {
    /// Startup check not finished yet.
    loading,
    off,
    enabling,
    disabling,
    /// Startup found a different installed release and is re-serving.
    syncing,
    on,
};

pub const State = struct {
    saved: Saved = .{},
    phase: Phase = .loading,
    blocker: ?Blocker = null,
    suggested_port: u16 = 0,
    message: Text(512) = .{},
    /// True once a startup resync updated the installed gateway this run.
    synced: bool = false,
    notice_text: Text(320) = .{},
    /// Last requested change and port, so "Try again" repeats exactly it.
    last_kind: Kind = .startup,
    last_port: u16 = DEFAULT_HTTPS_PORT,
    pending: ?*Job = null,

    /// A running `verde-server` may take tens of seconds; quitting Verde must
    /// not wait for it. The detached worker owns its job memory, and the
    /// server's own lifecycle lock keeps the service change consistent.
    pub fn deinit(self: *State) void {
        if (self.pending) |job| {
            if (job.done.load(.acquire)) {
                if (job.thread) |thread| thread.join();
                job.destroy();
            } else if (job.thread) |thread| thread.detach();
        }
        self.* = .{};
    }

    /// Repeats the last change, or applies the Serve collision's suggested port.
    pub fn retry(self: *State, pref_path: []const u8) void {
        if (self.blocker == .serve_collision and self.suggested_port != 0) return self.enable(pref_path, self.suggested_port);
        switch (self.last_kind) {
            .disable => self.disable(pref_path),
            .enable => self.enable(pref_path, self.last_port),
            .startup => self.enable(pref_path, self.saved.https_port),
        }
    }

    pub fn busy(self: *const State) bool {
        return self.pending != null;
    }

    /// The switch shows On only for a working, persisted mapping.
    pub fn switchOn(self: *const State) bool {
        return switch (self.phase) {
            .on, .syncing, .disabling => true,
            .loading, .off, .enabling => false,
        };
    }

    /// HTTPS origin phone pairing should use, when Remote access is on.
    pub fn origin(self: *const State) ?[]const u8 {
        if (!self.saved.enabled or self.saved.origin.len == 0) return null;
        return self.saved.origin.slice();
    }

    /// One-line note after a change, e.g. that an existing gateway service
    /// was taken over. Empty when there is nothing to add.
    pub fn notice(self: *const State) []const u8 {
        return self.notice_text.slice();
    }

    /// Called once at app start. Reads prefs and decides version sync on the
    /// worker, so startup never waits on disk or `verde-server`.
    pub fn startStartup(self: *State, pref_path: []const u8) void {
        self.startWith(pref_path, .startup, self.saved.https_port, .{});
    }

    pub fn enable(self: *State, pref_path: []const u8, https_port: u16) void {
        if (!supported) {
            self.blocker = .unsupported_os;
            return;
        }
        self.startWith(pref_path, .enable, https_port, .{});
    }

    pub fn disable(self: *State, pref_path: []const u8) void {
        self.startWith(pref_path, .disable, self.saved.https_port, .{});
    }

    pub fn startWith(self: *State, pref_path: []const u8, kind: Kind, https_port: u16, runner: Runner) void {
        if (self.pending != null) return;
        const job = Job.create(pref_path, kind, https_port, self.saved, runner) catch {
            self.blocker = .failed;
            self.message.set("Could not start the Remote access worker.");
            if (self.phase == .loading) self.phase = .off;
            return;
        };
        self.pending = job;
        self.last_kind = kind;
        self.last_port = https_port;
        self.blocker = null;
        self.message.len = 0;
        self.phase = switch (kind) {
            .startup => .loading,
            .enable => .enabling,
            .disable => .disabling,
        };
    }

    /// Settings poll; returns true when the visible state changed.
    pub fn poll(self: *State) bool {
        const job = self.pending orelse return false;
        if (job.phase_hint.load(.acquire) and self.phase == .loading) {
            job.phase_hint.store(false, .release);
            self.phase = .syncing;
            return true;
        }
        if (!job.done.load(.acquire)) return false;
        if (job.thread) |thread| thread.join();
        self.pending = null;
        defer job.destroy();
        self.apply(job.kind, job.result_saved, job.outcome, job.resynced);
        return true;
    }

    fn apply(self: *State, kind: Kind, saved: Saved, outcome: ?Outcome, resynced: bool) void {
        self.saved = saved;
        self.synced = resynced;
        self.suggested_port = 0;
        self.blocker = null;
        self.message.len = 0;
        self.notice_text.len = 0;
        const result = outcome orelse {
            self.phase = if (saved.enabled) .on else .off;
            return;
        };
        switch (result.kind) {
            .ready => {
                self.phase = .on;
                if (result.adopted and result.unit.len > 0) {
                    var buffer: [320]u8 = undefined;
                    self.notice_text.set(std.fmt.bufPrint(&buffer, "Using the existing gateway service {s} on port {d}; no second gateway was started.", .{ result.unit.slice(), result.gateway_port }) catch "");
                }
            },
            .uninstalled => self.phase = .off,
            .blocked => {
                self.blocker = result.blocker;
                self.suggested_port = result.suggested_port;
                self.message = result.message;
                // A failed Off keeps the service; a failed On or resync leaves
                // the persisted choice as it was.
                self.phase = switch (kind) {
                    .disable => .on,
                    .enable => .off,
                    .startup => if (saved.enabled) .on else .off,
                };
            },
        }
    }
};

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    pref_path: []const u8,
    https_port: u16,
    runner: Runner,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Set by a startup job before a resync starts, so the card says so.
    phase_hint: std.atomic.Value(bool) = .init(false),
    result_saved: Saved,
    outcome: ?Outcome = null,
    resynced: bool = false,

    fn create(pref_path: []const u8, kind: Kind, https_port: u16, saved: Saved, runner: Runner) !*Job {
        const job = try allocator.create(Job);
        job.* = .{ .arena = .init(allocator), .kind = kind, .pref_path = "", .https_port = https_port, .runner = runner, .result_saved = saved };
        errdefer job.destroy();
        job.pref_path = try job.arena.allocator().dupe(u8, pref_path);
        job.thread = try std.Thread.spawn(.{}, worker, .{job});
        return job;
    }

    fn destroy(self: *Job) void {
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn worker(self: *Job) void {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        self.run(threaded.io(), appRelease) catch |err| {
            self.outcome = Outcome.blocked(.failed, @errorName(err));
        };
        self.done.store(true, .release);
    }

    const AppReleaseFn = *const fn (std.Io, std.mem.Allocator) anyerror!AppRelease;

    fn run(self: *Job, io: std.Io, app_release: AppReleaseFn) !void {
        const a = self.arena.allocator();
        if (self.kind == .startup) self.result_saved = loadSaved(io, a, self.pref_path);
        if (!supported) {
            if (self.kind != .startup) self.outcome = Outcome.blocked(.unsupported_os, "");
            return;
        }
        const app = try app_release(io, a);
        switch (self.kind) {
            .startup => {
                const installed: ?Release = blk: {
                    const path = if (self.result_saved.release_file.len > 0)
                        self.result_saved.release_file.slice()
                    else if (self.result_saved.state_dir.len > 0)
                        try std.fs.path.join(a, &.{ self.result_saved.state_dir.slice(), GATEWAY_STATE_FILE })
                    else
                        break :blk null;
                    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(MAX_FILE_BYTES)) catch break :blk null;
                    break :blk parseRelease(a, bytes);
                };
                switch (versionSyncDecision(self.result_saved.enabled, app.server_present, installed, app.release)) {
                    .not_enabled, .in_sync => {},
                    .server_missing => self.outcome = Outcome.blocked(.server_missing, ""),
                    .resync => {
                        self.phase_hint.store(true, .release);
                        try self.serve(io, a, app.server_path, self.result_saved.https_port);
                        self.resynced = self.outcome != null and self.outcome.?.kind == .ready;
                    },
                }
            },
            .enable => {
                if (!app.server_present) {
                    self.outcome = Outcome.blocked(.server_missing, "");
                    return;
                }
                try self.serve(io, a, app.server_path, self.https_port);
            },
            .disable => {
                if (!app.server_present) {
                    self.outcome = Outcome.blocked(.server_missing, "");
                    return;
                }
                const output = try self.runner.run(a, &.{ app.server_path, "service", "uninstall", "--desktop", "--data-dir", self.pref_path, "--json" });
                self.outcome = parseOutput(a, output.stdout, output.stderr, output.exited_ok);
                if (self.outcome.?.kind == .uninstalled) {
                    self.result_saved.enabled = false;
                    self.result_saved.origin.len = 0;
                    saveSaved(io, a, self.pref_path, &self.result_saved) catch |err| {
                        self.outcome = Outcome.blocked(.failed, @errorName(err));
                    };
                }
            },
        }
    }

    /// `serve --tailscale --desktop` is idempotent: it installs, adopts, or
    /// refreshes the one gateway service for this app's data dir and keeps an
    /// exactly matching Verde Serve mapping.
    fn serve(self: *Job, io: std.Io, a: std.mem.Allocator, server_path: []const u8, https_port: u16) !void {
        const output = try self.runner.run(a, try serveArgv(a, server_path, self.pref_path, https_port));
        const outcome = parseOutput(a, output.stdout, output.stderr, output.exited_ok);
        self.outcome = outcome;
        if (outcome.kind != .ready) return;
        self.result_saved.enabled = true;
        self.result_saved.https_port = outcome.https_port;
        self.result_saved.origin = outcome.origin;
        self.result_saved.data_dir = outcome.data_dir;
        self.result_saved.state_dir = outcome.state_dir;
        self.result_saved.release_file = outcome.release_file;
        self.result_saved.gateway_port = outcome.gateway_port;
        self.result_saved.unit = outcome.unit;
        saveSaved(io, a, self.pref_path, &self.result_saved) catch |err| {
            self.outcome = Outcome.blocked(.failed, @errorName(err));
        };
    }
};

/// Remote access always serves the desktop's own data dir (its prefs dir),
/// the same daemon this app uses, so paired devices see these chats.
pub fn serveArgv(a: std.mem.Allocator, server_path: []const u8, pref_path: []const u8, https_port: u16) ![]const []const u8 {
    const port = try std.fmt.allocPrint(a, "{d}", .{https_port});
    return a.dupe([]const u8, &.{ server_path, "serve", "--tailscale", "--desktop", "--data-dir", pref_path, "--tailscale-https-port", port, "--json" });
}

const AppRelease = struct {
    release: Release,
    server_path: []const u8,
    server_present: bool,
};

/// verde-server ships beside verde-gui (Linux `bin/`, macOS `Contents/MacOS`),
/// so both share the artifact root `verde-server` records as `active_root`.
fn appRelease(io: std.Io, a: std.mem.Allocator) !AppRelease {
    const exe_dir = try std.process.executableDirPathAlloc(io, a);
    const root = std.fs.path.dirname(exe_dir) orelse exe_dir;
    const server_path = try std.fs.path.join(a, &.{ exe_dir, SERVER_NAME });
    const present = if (std.Io.Dir.cwd().statFile(io, server_path, .{})) |stat| stat.kind == .file else |_| false;
    return .{ .release = .{ .version = build_options.version, .root = root }, .server_path = server_path, .server_present = present };
}

fn loadSaved(io: std.Io, a: std.mem.Allocator, pref_path: []const u8) Saved {
    const path = std.fs.path.join(a, &.{ pref_path, PREF_FILE }) catch return .{};
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(MAX_FILE_BYTES)) catch return .{};
    return parseSaved(a, bytes) catch .{};
}

fn saveSaved(io: std.Io, a: std.mem.Allocator, pref_path: []const u8, saved: *const Saved) !void {
    const encoded = try encodeSaved(a, saved);
    var dir = try std.Io.Dir.cwd().openDir(io, pref_path, .{});
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, PREF_FILE, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, encoded);
    try atomic.replace(io);
}

// ---- tests ------------------------------------------------------------------

test "serve JSON maps to ready and the last JSON line wins over child output" {
    const stdout =
        \\Gateway token: /home/u/.config/verde/web-token (owner-only; value not displayed)
        \\{"schema_version":1,"ok":true,"code":"remote_access_ready","origin":"https://box.tail1.ts.net:8443","https_port":8443,"version":"1.2.3","root":"/opt/verde","data_dir":"/home/u/.local/share/verde/runtime","state_dir":"/home/u/.local/state/verde-server"}
        \\
    ;
    const outcome = parseOutput(std.testing.allocator, stdout, "", true);
    try std.testing.expectEqual(OutcomeKind.ready, outcome.kind);
    try std.testing.expectEqualStrings("https://box.tail1.ts.net:8443", outcome.origin.slice());
    try std.testing.expectEqual(@as(u16, 8443), outcome.https_port);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/runtime", outcome.data_dir.slice());
    try std.testing.expectEqualStrings("/home/u/.local/state/verde-server", outcome.state_dir.slice());
}

test "serve blockers map to exactly one action each" {
    const cases = [_]struct { json: []const u8, blocker: Blocker, action: Action }{
        .{ .json = "{\"schema_version\":1,\"ok\":false,\"code\":\"tailscale_missing\",\"error\":\"TailscaleCliMissing\",\"message\":\"m\"}", .blocker = .tailscale_missing, .action = .get_tailscale },
        .{ .json = "{\"schema_version\":1,\"ok\":false,\"code\":\"tailscale_not_logged_in\",\"error\":\"TailscaleNotLoggedIn\",\"message\":\"m\"}", .blocker = .tailscale_not_logged_in, .action = .open_tailscale },
        .{ .json = "{\"schema_version\":1,\"ok\":false,\"code\":\"tailscale_not_running\",\"error\":\"TailscaleNotRunning\",\"message\":\"m\"}", .blocker = .tailscale_not_running, .action = .open_tailscale },
        .{ .json = "{\"schema_version\":1,\"ok\":false,\"code\":\"unsupported_platform\",\"error\":\"UnsupportedPlatform\",\"message\":\"m\"}", .blocker = .unsupported_os, .action = .none },
        .{ .json = "{\"schema_version\":1,\"ok\":false,\"code\":\"failed\",\"error\":\"SystemctlFailed\",\"message\":\"systemctl failed\"}", .blocker = .failed, .action = .retry },
    };
    for (cases) |case| {
        const outcome = parseOutput(std.testing.allocator, case.json, "verde-server: ignored", false);
        try std.testing.expectEqual(OutcomeKind.blocked, outcome.kind);
        try std.testing.expectEqual(case.blocker, outcome.blocker);
        try std.testing.expectEqual(case.action, blockerAction(outcome.blocker));
    }
}

test "Serve collision offers the suggested port and never a reset" {
    const collision =
        \\{"schema_version":1,"ok":false,"code":"tailscale_serve_collision","state":"collision","endpoint":"https://box.ts.net:443","requested_target":"http://127.0.0.1:7420","current_target":"http://127.0.0.1:3000","handler_count":1,"https_port":443,"safe_to_configure":false,"suggested_https_port":8443,"recovery_choices":["choose_alternate_https_port"]}
    ;
    const outcome = parseOutput(std.testing.allocator, collision, "verde-server: the requested Tailscale Serve listener is occupied", false);
    try std.testing.expectEqual(Blocker.serve_collision, outcome.blocker);
    try std.testing.expectEqual(@as(u16, 8443), outcome.suggested_port);
    try std.testing.expectEqual(Action.use_suggested_port, blockerAction(outcome.blocker));
    try std.testing.expect(std.mem.indexOf(u8, blockerSummary(.serve_collision), "reset") == null);
}

test "missing JSON falls back to the server's stderr message" {
    const outcome = parseOutput(std.testing.allocator, "", "noise\nverde-server: one or more runtime components are unhealthy\n", false);
    try std.testing.expectEqual(Blocker.failed, outcome.blocker);
    try std.testing.expectEqualStrings("one or more runtime components are unhealthy", outcome.message.slice());
    const silent = parseOutput(std.testing.allocator, "Verde is installed\n", "", true);
    try std.testing.expectEqual(Blocker.failed, silent.blocker);
    // A non-HTTPS origin is rejected rather than offered to phones.
    const bad = parseOutput(std.testing.allocator, "{\"schema_version\":1,\"ok\":true,\"code\":\"remote_access_ready\",\"origin\":\"http://box\"}", "", true);
    try std.testing.expectEqual(OutcomeKind.blocked, bad.kind);
}

test "version sync re-serves only when the installed release differs" {
    const app: Release = .{ .version = "1.4.0", .root = "/opt/verde" };
    try std.testing.expectEqual(SyncDecision.not_enabled, versionSyncDecision(false, true, null, app));
    try std.testing.expectEqual(SyncDecision.server_missing, versionSyncDecision(true, false, app, app));
    try std.testing.expectEqual(SyncDecision.in_sync, versionSyncDecision(true, true, app, app));
    try std.testing.expectEqual(SyncDecision.resync, versionSyncDecision(true, true, .{ .version = "1.3.9", .root = "/opt/verde" }, app));
    try std.testing.expectEqual(SyncDecision.resync, versionSyncDecision(true, true, .{ .version = "1.4.0", .root = "/home/u/old/verde" }, app));
    try std.testing.expectEqual(SyncDecision.resync, versionSyncDecision(true, true, null, app));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const release = parseRelease(arena.allocator(), "{\"schema_version\":1,\"active_version\":\"1.3.9\",\"active_root\":\"/opt/verde\",\"previous_version\":null}").?;
    try std.testing.expectEqualStrings("1.3.9", release.version);
    try std.testing.expect(parseRelease(arena.allocator(), "not json") == null);
}

test "saved choice round-trips and rejects unsafe origins" {
    var saved: Saved = .{ .enabled = true, .https_port = 8443 };
    saved.origin.set("https://box.ts.net:8443");
    saved.data_dir.set("/home/u/.local/share/verde/runtime");
    const encoded = try encodeSaved(std.testing.allocator, &saved);
    defer std.testing.allocator.free(encoded);
    const loaded = try parseSaved(std.testing.allocator, encoded);
    try std.testing.expect(loaded.enabled);
    try std.testing.expectEqual(@as(u16, 8443), loaded.https_port);
    try std.testing.expectEqualStrings("https://box.ts.net:8443", loaded.origin.slice());
    try std.testing.expectError(error.InvalidRemoteAccessPrefs, parseSaved(std.testing.allocator, "{\"enabled\":true,\"origin\":\"https://box/#code=x\"}"));
}

const FakeServer = struct {
    stdout: []const u8,
    calls: usize = 0,
    last_argv: [12][]const u8 = undefined,
    last_len: usize = 0,

    fn run(context: ?*anyopaque, _: std.mem.Allocator, argv: []const []const u8) anyerror!RunOutput {
        const self: *FakeServer = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.last_len = @min(argv.len, self.last_argv.len);
        @memcpy(self.last_argv[0..self.last_len], argv[0..self.last_len]);
        return .{ .stdout = self.stdout, .stderr = "", .exited_ok = true };
    }

    fn appWith(comptime version: []const u8) Job.AppReleaseFn {
        return struct {
            fn release(_: std.Io, _: std.mem.Allocator) anyerror!AppRelease {
                return .{ .release = .{ .version = version, .root = "/opt/verde" }, .server_path = "/opt/verde/bin/verde-server", .server_present = true };
            }
        }.release;
    }
};

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
}

test "startup resyncs a stale service through the fake server and persists the result" {
    if (!supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const prefs = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"enabled\":true,\"https_port\":8443,\"origin\":\"https://box.ts.net:8443\",\"data_dir\":\"/d\",\"state_dir\":\"{s}\"}}", .{root});
    defer std.testing.allocator.free(prefs);
    try writeFixture(tmp.dir, PREF_FILE, prefs);
    try writeFixture(tmp.dir, GATEWAY_STATE_FILE, "{\"schema_version\":1,\"active_version\":\"1.0.0\",\"active_root\":\"/opt/verde\"}");

    var fake: FakeServer = .{ .stdout = "{\"schema_version\":1,\"ok\":true,\"code\":\"remote_access_ready\",\"origin\":\"https://box.ts.net:8443\",\"https_port\":8443,\"version\":\"2.0.0\",\"root\":\"/opt/verde\",\"data_dir\":\"/d\",\"state_dir\":\"/s\"}" };
    var job: Job = .{ .arena = .init(std.testing.allocator), .kind = .startup, .pref_path = root, .https_port = DEFAULT_HTTPS_PORT, .runner = .{ .context = &fake, .run_fn = FakeServer.run }, .result_saved = .{} };
    defer job.arena.deinit();
    try job.run(std.testing.io, FakeServer.appWith("2.0.0"));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("serve", fake.last_argv[1]);
    try std.testing.expectEqualStrings("--desktop", fake.last_argv[3]);
    try std.testing.expectEqualStrings(root, fake.last_argv[5]);
    try std.testing.expectEqualStrings("8443", fake.last_argv[7]);
    try std.testing.expect(job.resynced);
    try std.testing.expectEqualStrings("/s", job.result_saved.state_dir.slice());

    // The same release is left alone: no spawn at all.
    var current: Job = .{ .arena = .init(std.testing.allocator), .kind = .startup, .pref_path = root, .https_port = DEFAULT_HTTPS_PORT, .runner = .{ .context = &fake, .run_fn = FakeServer.run }, .result_saved = .{} };
    defer current.arena.deinit();
    try writeFixture(tmp.dir, PREF_FILE, prefs);
    try current.run(std.testing.io, FakeServer.appWith("1.0.0"));
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expect(current.outcome == null and current.result_saved.enabled);

    var state: State = .{};
    state.apply(.startup, current.result_saved, current.outcome, false);
    try std.testing.expectEqual(Phase.on, state.phase);
    try std.testing.expectEqualStrings("https://box.ts.net:8443", state.origin().?);
}

test "Off uninstalls through the server and a failed Off keeps the switch on" {
    if (!supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var saved: Saved = .{ .enabled = true };
    saved.origin.set("https://box.ts.net");

    var fake: FakeServer = .{ .stdout = "{\"schema_version\":1,\"ok\":true,\"code\":\"service_uninstalled\",\"tailscale_cleanup\":\"removed\"}" };
    var job: Job = .{ .arena = .init(std.testing.allocator), .kind = .disable, .pref_path = root, .https_port = DEFAULT_HTTPS_PORT, .runner = .{ .context = &fake, .run_fn = FakeServer.run }, .result_saved = saved };
    defer job.arena.deinit();
    try job.run(std.testing.io, FakeServer.appWith("1.0.0"));
    try std.testing.expectEqualStrings("uninstall", fake.last_argv[2]);
    try std.testing.expectEqualStrings("--desktop", fake.last_argv[3]);
    try std.testing.expectEqualStrings(root, fake.last_argv[5]);
    var state: State = .{};
    state.apply(.disable, job.result_saved, job.outcome, false);
    try std.testing.expectEqual(Phase.off, state.phase);
    try std.testing.expect(state.origin() == null);
    const stored = loadSaved(std.testing.io, job.arena.allocator(), root);
    try std.testing.expect(!stored.enabled);

    var failed: State = .{ .saved = saved, .phase = .on };
    failed.apply(.disable, saved, Outcome.blocked(.failed, "systemctl failed"), false);
    try std.testing.expectEqual(Phase.on, failed.phase);
    try std.testing.expect(failed.switchOn());
    try std.testing.expectEqualStrings("systemctl failed", failed.message.slice());
}

test "Remote access serves the desktop's own data dir and reports gateway adoption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try serveArgv(arena.allocator(), "/opt/verde/bin/verde-server", "/home/u/.local/share/verde/Native", 443);
    try std.testing.expectEqualStrings("--desktop", argv[3]);
    try std.testing.expectEqualStrings("--data-dir", argv[4]);
    try std.testing.expectEqualStrings("/home/u/.local/share/verde/Native", argv[5]);
    try std.testing.expectEqualStrings("--json", argv[argv.len - 1]);

    const adopted = parseOutput(std.testing.allocator,
        \\{"schema_version":1,"ok":true,"code":"remote_access_ready","origin":"https://box.ts.net","https_port":443,"version":"1.0.0","root":"/opt/verde","data_dir":"/home/u/.local/share/verde/Native","state_dir":"/s","release_file":"/s/desktop-gateway.json","gateway_port":6783,"unit":"verde-web-desktop.service","adopted":true}
    , "", true);
    try std.testing.expect(adopted.adopted);
    try std.testing.expectEqual(@as(u16, 6783), adopted.gateway_port);
    try std.testing.expectEqualStrings("/s/desktop-gateway.json", adopted.release_file.slice());
    var state: State = .{};
    state.apply(.enable, .{ .enabled = true }, adopted, false);
    try std.testing.expect(std.mem.indexOf(u8, state.notice(), "verde-web-desktop.service") != null);

    const busy_port = parseOutput(std.testing.allocator, "{\"schema_version\":1,\"ok\":false,\"code\":\"gateway_port_in_use\",\"gateway_port\":6783,\"process\":\"node\",\"message\":\"m\"}", "", false);
    try std.testing.expectEqual(Blocker.gateway_port_in_use, busy_port.blocker);
    try std.testing.expectEqualStrings("Port 6783 is used by node.", busy_port.message.slice());
    try std.testing.expectEqual(Action.retry, blockerAction(busy_port.blocker));
    const by_hand = parseOutput(std.testing.allocator, "{\"schema_version\":1,\"ok\":false,\"code\":\"gateway_unmanaged\",\"gateway_port\":6783,\"process\":\"verde-web\",\"message\":\"m\"}", "", false);
    try std.testing.expectEqual(Blocker.gateway_unmanaged, by_hand.blocker);
    // The collision fallback port stays discoverable by pairing by approval.
    try std.testing.expect(discoverableNearby(443) and discoverableNearby(8443));
    try std.testing.expect(!discoverableNearby(8444));
}
