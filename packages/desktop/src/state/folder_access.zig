//! macOS folder access for first-run setup: asks for the privacy-protected
//! home folders (Documents, Desktop, Downloads) while the user is at the
//! screen, instead of leaving the first prompt to a background daemon request
//! nobody can answer (a remote device browsing folders, an agent's shell).
//!
//! Touching a protected folder is the only way to ask, and the call blocks
//! until the prompt is answered, so probes run on one detached worker thread.
//! Results live in process-lifetime atomics: a worker still parked behind an
//! unanswered prompt can never outlive the state it writes.

const std = @import("std");
const builtin = @import("builtin");
const loop_wakeup = @import("loop_wakeup");

/// Only macOS gates home folders behind per-app privacy prompts.
pub const supported = builtin.os.tag == .macos;

/// System Settings › Privacy & Security panes. A folder the user once denied
/// never prompts again; it can only be re-enabled there.
pub const FILES_AND_FOLDERS_SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders";
pub const FULL_DISK_ACCESS_SETTINGS_URL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

pub const Folder = enum(u2) {
    documents,
    desktop,
    downloads,

    pub fn label(self: Folder) []const u8 {
        return switch (self) {
            .documents => "Documents",
            .desktop => "Desktop",
            .downloads => "Downloads",
        };
    }

    /// Path under the home directory; also the `~/…` display path's tail.
    pub fn homeSubpath(self: Folder) []const u8 {
        return self.label();
    }

    pub fn displayPath(self: Folder) []const u8 {
        return switch (self) {
            .documents => "~/Documents",
            .desktop => "~/Desktop",
            .downloads => "~/Downloads",
        };
    }
};

pub const FOLDERS = [_]Folder{ .documents, .desktop, .downloads };

pub const Status = enum(u8) {
    /// Not asked this session. Checking would itself raise the prompt, so the
    /// state stays unknown until the user chooses to ask.
    unknown,
    /// Waiting on macOS (the prompt is up, or the probe is queued behind one).
    checking,
    granted,
    /// Denied now or earlier; only System Settings can change it.
    denied,
    /// This home has no such folder; nothing to grant.
    missing,
};

var statuses: [FOLDERS.len]std.atomic.Value(u8) = @splat(.init(@intFromEnum(Status.unknown)));
/// Bumped on every status change; the UI polls it to know when to redraw.
var revision: std.atomic.Value(u32) = .init(0);
/// Bit per `Folder` waiting for the worker.
var pending: std.atomic.Value(u8) = .init(0);
var worker_running: std.atomic.Value(bool) = .init(false);

pub fn status(folder: Folder) Status {
    return @enumFromInt(statuses[@intFromEnum(folder)].load(.acquire));
}

pub fn currentRevision() u32 {
    return revision.load(.acquire);
}

/// True while any folder is still unknown, i.e. "Allow all" has work to do.
pub fn anyUnasked() bool {
    for (FOLDERS) |folder| {
        if (status(folder) == .unknown) return true;
    }
    return false;
}

/// Queue a probe for `folder`, raising the macOS prompt if it was never
/// answered. No-op while one is already queued or running for it.
/// Called from the UI thread only.
pub fn request(folder: Folder) void {
    if (status(folder) == .checking) return;
    // Mark first: the worker may finish the probe before this returns.
    setStatus(folder, .checking);
    _ = pending.fetchOr(@as(u8, 1) << @intFromEnum(folder), .acq_rel);
    ensureWorker();
}

/// Queue every folder not yet answered, one prompt after another.
pub fn requestAllUnasked() void {
    for (FOLDERS) |folder| {
        if (status(folder) == .unknown) request(folder);
    }
}

/// Visibility rule for the first-run dialog, kept pure for tests.
pub fn shouldOffer(platform_supported: bool, completed: bool, snoozed: bool, other_dialog_visible: bool, settings_open: bool, startup_settled: bool) bool {
    return platform_supported and !completed and !snoozed and !other_dialog_visible and !settings_open and startup_settled;
}

/// Opens and lists `home/<folder>`: the access macOS gates behind the
/// prompt. Blocks while the prompt is up.
pub fn probe(io: std.Io, home: []const u8, folder: Folder) Status {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), folder.homeSubpath() }) catch return .missing;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| return statusForError(err);
    defer dir.close(io);
    var iterator = dir.iterate();
    _ = iterator.next(io) catch |err| return statusForError(err);
    return .granted;
}

fn statusForError(err: anyerror) Status {
    return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .denied,
    };
}

fn setStatus(folder: Folder, value: Status) void {
    statuses[@intFromEnum(folder)].store(@intFromEnum(value), .release);
    _ = revision.fetchAdd(1, .acq_rel);
}

fn ensureWorker() void {
    if (worker_running.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    const thread = std.Thread.spawn(.{}, workerMain, .{}) catch {
        worker_running.store(false, .release);
        // No thread: report the queued folders as unanswered again.
        const queued = pending.swap(0, .acq_rel);
        for (FOLDERS) |folder| {
            if (queued & (@as(u8, 1) << @intFromEnum(folder)) != 0) setStatus(folder, .unknown);
        }
        return;
    };
    // Detached: a probe parked behind an unanswered prompt must not hold up
    // quitting Verde.
    thread.detach();
}

fn workerMain() void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const home: []const u8 = if (std.c.getenv("HOME")) |value| std.mem.span(value) else "";
    while (true) {
        const folder = takePending() orelse {
            worker_running.store(false, .release);
            // A request that raced the shutdown above restarts the loop.
            if (pending.load(.acquire) == 0) return;
            if (worker_running.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
            continue;
        };
        setStatus(folder, if (home.len == 0) .missing else probe(io, home, folder));
        // The UI may be idle-waiting; show the answer without a user event.
        loop_wakeup.notify();
    }
}

/// Lowest queued folder, removed from the queue.
fn takePending() ?Folder {
    var current = pending.load(.acquire);
    while (current != 0) {
        const index: u2 = @intCast(@ctz(current));
        const bit = @as(u8, 1) << index;
        current = pending.cmpxchgWeak(current, current & ~bit, .acq_rel, .acquire) orelse return @enumFromInt(index);
    }
    return null;
}

test "probe reports granted, missing, and denied folders" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Documents/project");
    try tmp.dir.writeFile(io, .{ .sub_path = "Desktop", .data = "not a folder" });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const home = buffer[0..len];
    try std.testing.expectEqual(Status.granted, probe(io, home, .documents));
    try std.testing.expectEqual(Status.missing, probe(io, home, .desktop));
    try std.testing.expectEqual(Status.missing, probe(io, home, .downloads));
    // An unreadable folder stands in for one macOS denied (root reads anyway).
    if (builtin.os.tag != .windows and std.c.geteuid() != 0) {
        try tmp.dir.createDirPath(io, "Downloads");
        const downloads = try std.fmt.allocPrint(std.testing.allocator, "{s}/Downloads", .{home});
        defer std.testing.allocator.free(downloads);
        const downloads_z = try std.testing.allocator.dupeZ(u8, downloads);
        defer std.testing.allocator.free(downloads_z);
        try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(downloads_z, 0o000));
        defer _ = std.c.chmod(downloads_z, 0o755);
        try std.testing.expectEqual(Status.denied, probe(io, home, .downloads));
    }
}

test "first-run folder dialog waits its turn and stays dismissed" {
    try std.testing.expect(shouldOffer(true, false, false, false, false, true));
    try std.testing.expect(!shouldOffer(false, false, false, false, false, true)); // not macOS
    try std.testing.expect(!shouldOffer(true, true, false, false, false, true)); // already completed
    try std.testing.expect(!shouldOffer(true, false, true, false, false, true)); // dismissed this session
    try std.testing.expect(!shouldOffer(true, false, false, true, false, true)); // provider/MCP dialog first
    try std.testing.expect(!shouldOffer(true, false, false, false, true, true)); // Settings is open
    try std.testing.expect(!shouldOffer(true, false, false, false, false, false)); // startup checks pending
}

test "queued folders are taken lowest first and only once" {
    pending.store(0b101, .release);
    try std.testing.expectEqual(@as(?Folder, .documents), takePending());
    try std.testing.expectEqual(@as(?Folder, .downloads), takePending());
    try std.testing.expectEqual(@as(?Folder, null), takePending());
}
