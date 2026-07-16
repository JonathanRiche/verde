//! Asynchronous GitHub release discovery for the desktop Settings UI.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const log = std.log.scoped(.native_updater);
const RELEASE_API_URL = "https://api.github.com/repos/JonathanRiche/verde/releases/latest";
const RELEASES_URL = "https://github.com/JonathanRiche/verde/releases/latest";
const MAX_RELEASE_RESPONSE_BYTES = 2 * 1024 * 1024;
const UPDATE_CHECK_TIMEOUT_SECONDS = 8;

const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

pub const Status = enum {
    idle,
    checking,
    up_to_date,
    update_available,
    failed,
};

pub const Release = struct {
    version: []u8,
    name: []u8,
    notes: []u8,
    page_url: []u8,
    asset_url: ?[]u8,

    pub fn deinit(self: *Release, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.name);
        allocator.free(self.notes);
        allocator.free(self.page_url);
        if (self.asset_url) |url| allocator.free(url);
    }
};

const WorkerResult = union(enum) {
    release: Release,
    failed,
};

pub const State = struct {
    mutex: Mutex = .{},
    status: Status = .idle,
    worker: ?std.Thread = null,
    worker_result: ?WorkerResult = null,
    release: ?Release = null,

    pub fn start(self: *State) void {
        self.poll();

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.status == .checking) return;

        self.status = .checking;
        self.worker_result = null;
        self.worker = std.Thread.spawn(.{}, checkWorker, .{self}) catch |err| {
            log.warn("failed to start update check: {s}", .{@errorName(err)});
            self.status = .failed;
            return;
        };
    }

    /// Transfers a completed worker result onto the UI-owned state.
    pub fn poll(self: *State) void {
        var result: ?WorkerResult = null;
        self.mutex.lock();
        if (self.worker_result != null) {
            result = self.worker_result;
            self.worker_result = null;
        }
        self.mutex.unlock();
        if (result == null) return;

        self.finishWorker();
        if (self.release) |*release| release.deinit(std.heap.page_allocator);
        self.release = null;

        switch (result.?) {
            .release => |release| {
                self.release = release;
                self.status = if (compareVersions(build_options.version, release.version)) |order|
                    if (order == .lt) .update_available else .up_to_date
                else
                    .failed;
            },
            .failed => self.status = .failed,
        }
    }

    pub fn deinit(self: *State) void {
        self.finishWorker();
        if (self.worker_result) |*result| switch (result.*) {
            .release => |*release| release.deinit(std.heap.page_allocator),
            .failed => {},
        };
        if (self.release) |*release| release.deinit(std.heap.page_allocator);
        self.* = .{};
    }

    pub fn downloadUrl(self: *const State) ?[]const u8 {
        const release = self.release orelse return null;
        return release.asset_url orelse release.page_url;
    }

    pub fn releasesUrl() []const u8 {
        return RELEASES_URL;
    }

    fn finishWorker(self: *State) void {
        if (self.worker) |worker| {
            worker.join();
            self.worker = null;
        }
    }
};

fn checkWorker(state: *State) void {
    const result: WorkerResult = if (fetchLatestRelease(std.heap.page_allocator)) |release|
        .{ .release = release }
    else |err| blk: {
        log.warn("update check failed: {s}", .{@errorName(err)});
        break :blk .failed;
    };

    state.mutex.lock();
    defer state.mutex.unlock();
    state.worker_result = result;
}

fn fetchLatestRelease(allocator: std.mem.Allocator) !Release {
    const response_buffer = try allocator.alloc(u8, MAX_RELEASE_RESPONSE_BYTES);
    defer allocator.free(response_buffer);
    var response_writer = std.Io.Writer.fixed(response_buffer);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = allocator, .io = threaded.io() };
    defer client.deinit();

    const fetch_options: std.http.Client.FetchOptions = .{
        .location = .{ .url = RELEASE_API_URL },
        .response_writer = &response_writer,
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "verde-desktop-updater" },
            .{ .name = "x-github-api-version", .value = "2022-11-28" },
        },
    };
    const SelectResult = union(enum) {
        fetch: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: std.Io.Cancelable!void,
    };
    var select_buffer: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(threaded.io(), &select_buffer);
    select.async(.fetch, std.http.Client.fetch, .{ &client, fetch_options });
    select.async(.timeout, std.Io.sleep, .{ threaded.io(), std.Io.Duration.fromSeconds(UPDATE_CHECK_TIMEOUT_SECONDS), .awake });
    defer select.cancelDiscard();

    const selected = try select.await();
    const result = switch (selected) {
        .fetch => |fetch_result| fetch_result catch |err| switch (err) {
            error.WriteFailed => if (response_writer.end == response_buffer.len)
                return error.ReleaseResponseTooLarge
            else
                return err,
            else => return err,
        },
        .timeout => |timeout_result| {
            try timeout_result;
            return error.UpdateCheckTimedOut;
        },
    };
    if (result.status != .ok) return error.UpdateServerError;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_writer.buffered(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidReleaseResponse;

    const object = parsed.value.object;
    const tag = jsonString(object, "tag_name") orelse return error.InvalidReleaseResponse;
    const version = stripVersionPrefix(tag);
    _ = std.SemanticVersion.parse(version) catch return error.InvalidReleaseVersion;
    const name = jsonString(object, "name") orelse tag;
    const notes = jsonString(object, "body") orelse "No release notes were provided.";
    const page_url = jsonString(object, "html_url") orelse RELEASES_URL;

    const owned_version = try allocator.dupe(u8, version);
    errdefer allocator.free(owned_version);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_notes = try allocator.dupe(u8, notes);
    errdefer allocator.free(owned_notes);
    const owned_page_url = try allocator.dupe(u8, page_url);
    errdefer allocator.free(owned_page_url);
    const asset_url = try selectAssetUrl(allocator, object);
    errdefer if (asset_url) |url| allocator.free(url);

    return .{
        .version = owned_version,
        .name = owned_name,
        .notes = owned_notes,
        .page_url = owned_page_url,
        .asset_url = asset_url,
    };
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn selectAssetUrl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]u8 {
    const assets = object.get("assets") orelse return null;
    if (assets != .array) return null;

    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = jsonString(asset.object, "name") orelse continue;
        if (!isInstallAssetForCurrentPlatform(name)) continue;
        const url = jsonString(asset.object, "browser_download_url") orelse continue;
        return try allocator.dupe(u8, url);
    }
    return null;
}

fn isInstallAssetForCurrentPlatform(name: []const u8) bool {
    const architecture = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => return false,
    };
    if (std.mem.indexOf(u8, name, architecture) == null) return false;

    return switch (builtin.os.tag) {
        .linux => std.mem.indexOf(u8, name, "-linux-") != null and std.mem.endsWith(u8, name, ".tar.gz"),
        .macos => std.mem.indexOf(u8, name, "-macos-") != null and std.mem.endsWith(u8, name, ".dmg"),
        .windows => std.mem.indexOf(u8, name, "-windows-") != null and std.mem.endsWith(u8, name, ".zip"),
        else => false,
    };
}

fn stripVersionPrefix(version: []const u8) []const u8 {
    if (version.len > 1 and (version[0] == 'v' or version[0] == 'V')) return version[1..];
    return version;
}

fn compareVersions(installed_raw: []const u8, available_raw: []const u8) ?std.math.Order {
    const installed = std.SemanticVersion.parse(stripVersionPrefix(installed_raw)) catch return null;
    const available = std.SemanticVersion.parse(stripVersionPrefix(available_raw)) catch return null;
    return installed.order(available);
}

test "version comparison accepts release tag prefixes" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.4.0", "v0.5.0").?);
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("0.5.0", "v0.5.0").?);
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.6.0", "v0.5.0").?);
    try std.testing.expect(compareVersions("development", "v0.5.0") == null);
}

test "release assets match the current platform archive" {
    const expected = switch (builtin.os.tag) {
        .linux => isInstallAssetForCurrentPlatform(if (builtin.cpu.arch == .aarch64) "verde-1.2.3-linux-arm64.tar.gz" else "verde-1.2.3-linux-x86_64.tar.gz"),
        .macos => isInstallAssetForCurrentPlatform(if (builtin.cpu.arch == .aarch64) "verde-1.2.3-macos-arm64.dmg" else "verde-1.2.3-macos-x86_64.dmg"),
        .windows => isInstallAssetForCurrentPlatform("verde-1.2.3-windows-x86_64.zip"),
        else => false,
    };
    if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .windows) {
        try std.testing.expect(expected);
    }
    try std.testing.expect(!isInstallAssetForCurrentPlatform("SHA256SUMS.txt"));
}
