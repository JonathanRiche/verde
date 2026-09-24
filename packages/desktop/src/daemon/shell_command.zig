//! Bounded composer shell (`!command`) execution for detached daemon clients.
//! Mirrors the desktop bang-command worker (same shell, argv, and transcript
//! body) but caps runtime and captured output so one RPC cannot pin a daemon
//! worker or produce an unbounded transcript row.

const std = @import("std");
const builtin = @import("builtin");
const platform_runtime = @import("platform_runtime");
const bang_commands = @import("../workspace/bang_commands.zig");
const platform_process = @import("../platform/process.zig");

/// Stays under the 30 s remote-runtime RPC deadline in `web_runtime.zig`.
pub const TIMEOUT_MS: u32 = 20_000;
/// Per-stream capture cap; the rest is drained and discarded.
pub const MAX_STREAM_BYTES: usize = 256 * 1024;
pub const MAX_COMMAND_BYTES: usize = 16 * 1024;
/// How long readers may linger after the process tree exited before they are
/// abandoned (a descendant that escaped the process group can hold a pipe).
const READER_GRACE_MS: i64 = 1_000;

pub const Status = enum { completed, failed, timed_out };

pub const Options = struct {
    timeout_ms: u32 = TIMEOUT_MS,
    max_stream_bytes: usize = MAX_STREAM_BYTES,
};

pub const Outcome = struct {
    status: Status,
    exit_code: ?u8,
    duration_ms: i64,
    stdout: []u8,
    stderr: []u8,
    truncated: bool,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Runs `command` through the platform shell in `cwd` and captures its output.
/// Returns an error only when the process cannot be started.
pub fn run(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8, options: Options) !Outcome {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const argv = bang_commands.shellArgv(command);
    const started_ms = monotonicMs();
    var child = try platform_process.spawn(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // Readers own the pipe ends so reaping the child cannot close them early.
    var stdout_capture: Capture = .{ .allocator = allocator, .file = child.child.stdout.?, .limit = options.max_stream_bytes };
    var stderr_capture: Capture = .{ .allocator = allocator, .file = child.child.stderr.?, .limit = options.max_stream_bytes };
    child.child.stdout = null;
    child.child.stderr = null;
    defer stdout_capture.bytes.deinit(allocator);
    defer stderr_capture.bytes.deinit(allocator);

    const stdout_thread = std.Thread.spawn(.{}, drain, .{&stdout_capture}) catch |err| {
        stdout_capture.file.close(io);
        stderr_capture.file.close(io);
        child.kill(io);
        return err;
    };
    const stderr_thread = std.Thread.spawn(.{}, drain, .{&stderr_capture}) catch |err| {
        stderr_capture.file.close(io);
        child.kill(io);
        stdout_capture.abandon.store(true, .release);
        stdout_thread.join();
        return err;
    };

    var timed_out = false;
    const term: ?std.process.Child.Term = while (true) {
        const polled = child.poll(io) catch {
            child.kill(io);
            break null;
        };
        if (polled) |value| break value;
        if (monotonicMs() - started_ms >= options.timeout_ms) {
            timed_out = true;
            child.kill(io);
            break null;
        }
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch {};
    };

    const grace_deadline = monotonicMs() + READER_GRACE_MS;
    while (!(stdout_capture.done.load(.acquire) and stderr_capture.done.load(.acquire)) and monotonicMs() < grace_deadline) {
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    stdout_capture.abandon.store(true, .release);
    stderr_capture.abandon.store(true, .release);
    stdout_thread.join();
    stderr_thread.join();

    const exit_code: ?u8 = if (term) |value| switch (value) {
        .exited => |code| code,
        else => null,
    } else null;
    const status: Status = if (timed_out)
        .timed_out
    else if (exit_code != null and exit_code.? == 0)
        .completed
    else
        .failed;

    const stdout = try stdout_capture.bytes.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try stderr_capture.bytes.toOwnedSlice(allocator);
    return .{
        .status = status,
        .exit_code = exit_code,
        .duration_ms = @max(monotonicMs() - started_ms, 0),
        .stdout = stdout,
        .stderr = stderr,
        .truncated = stdout_capture.truncated or stderr_capture.truncated,
    };
}

/// Transcript author matching the desktop bang-command row.
pub fn resultAuthor(status: Status) []const u8 {
    return if (status == .completed) "Ran command" else "Command failed";
}

/// Transcript body in the desktop bang-command format.
pub fn formatResultBody(allocator: std.mem.Allocator, command: []const u8, cwd: []const u8, outcome: Outcome) ![]u8 {
    var exit_buffer: [16]u8 = undefined;
    const exit_label = if (outcome.exit_code) |code|
        std.fmt.bufPrint(&exit_buffer, "{d}", .{code}) catch "unknown"
    else
        "terminated";
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (outcome.stdout.len > 0) try output.writer.print("stdout:\n{s}", .{outcome.stdout});
    if (outcome.stderr.len > 0) try output.writer.print("\nstderr:\n{s}", .{outcome.stderr});
    if (outcome.stdout.len == 0 and outcome.stderr.len == 0) try output.writer.writeAll("(no output)");
    if (outcome.truncated) try output.writer.writeAll("\n\n[output truncated]");
    return std.fmt.allocPrint(allocator, "$ {s}\n\nWorkspace: {s}\nShell: {s}\nExit: {s}\nDuration: {d} ms\nStatus: {s}\n\n{s}", .{
        command,
        cwd,
        bang_commands.shellName(),
        exit_label,
        outcome.duration_ms,
        if (outcome.status == .timed_out) "timed out" else "finished",
        output.written(),
    });
}

const Capture = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    limit: usize,
    bytes: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    abandon: std.atomic.Value(bool) = .init(false),

    fn keep(self: *Capture, data: []const u8) void {
        const room = self.limit -| self.bytes.items.len;
        const take = @min(room, data.len);
        if (take < data.len) self.truncated = true;
        if (take == 0) return;
        self.bytes.appendSlice(self.allocator, data[0..take]) catch {
            self.truncated = true;
        };
    }
};

fn drain(capture: *Capture) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer capture.done.store(true, .release);
    defer capture.file.close(io);
    var chunk: [4096]u8 = undefined;
    if (comptime builtin.os.tag == .windows) {
        var read_buffer: [4096]u8 = undefined;
        var reader = capture.file.reader(io, &read_buffer);
        while (true) {
            const count = reader.interface.readSliceShort(&chunk) catch break;
            if (count == 0) break;
            capture.keep(chunk[0..count]);
        }
        return;
    }
    // Poll with a short timeout so an abandoned reader exits deterministically.
    var fds = [_]std.posix.pollfd{.{ .fd = capture.file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    while (!capture.abandon.load(.acquire)) {
        const ready = std.posix.poll(&fds, 100) catch break;
        if (ready == 0) continue;
        const count = std.posix.read(capture.file.handle, &chunk) catch break;
        if (count == 0) break;
        capture.keep(chunk[0..count]);
    }
}

fn monotonicMs() i64 {
    return @intCast(@divTrunc(platform_runtime.monotonicTimestampNs(), std.time.ns_per_ms));
}

test "shell command captures stdout, stderr, and exit status" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var outcome = try run(allocator, "printf out; printf err >&2; exit 3", "/", .{});
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(Status.failed, outcome.status);
    try std.testing.expectEqual(@as(?u8, 3), outcome.exit_code);
    try std.testing.expectEqualStrings("out", outcome.stdout);
    try std.testing.expectEqualStrings("err", outcome.stderr);
    const body = try formatResultBody(allocator, "printf", "/", outcome);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Exit: 3\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "stdout:\nout\nstderr:\nerr"));
    try std.testing.expectEqualStrings("Command failed", resultAuthor(outcome.status));
}

test "shell command runs in the requested directory and truncates output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var outcome = try run(allocator, "pwd; printf '%0500d' 0", "/", .{ .max_stream_bytes = 64 });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(Status.completed, outcome.status);
    try std.testing.expect(outcome.truncated);
    try std.testing.expectEqual(@as(usize, 64), outcome.stdout.len);
    try std.testing.expect(std.mem.startsWith(u8, outcome.stdout, "/\n"));
}

test "shell command is killed at its deadline" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var outcome = try run(allocator, "sleep 5 & sleep 5", "/", .{ .timeout_ms = 200 });
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(Status.timed_out, outcome.status);
    try std.testing.expect(outcome.duration_ms < 4_000);
    const body = try formatResultBody(allocator, "sleep 5", "/", outcome);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "Status: timed out") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "(no output)"));
}
