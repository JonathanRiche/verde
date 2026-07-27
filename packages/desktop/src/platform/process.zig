//! Cross-platform ownership for provider subprocess trees.

const std = @import("std");
const builtin = @import("builtin");
const process_env = @import("../platform/env.zig");

const windows = std.os.windows;

/// Provider-facing spawn options without exposing POSIX-only process groups.
pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stdin: std.process.SpawnOptions.StdIo = .inherit,
    stdout: std.process.SpawnOptions.StdIo = .inherit,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
    request_resource_usage_statistics: bool = false,
    own_process_tree: bool = true,
    hide_window: bool = true,
};

/// A spawned child plus the platform resource that owns its descendants.
pub const OwnedChild = struct {
    child: std.process.Child,
    job: if (builtin.os.tag == .windows) ?windows.HANDLE else void,
    owns_tree: bool,

    /// Sends a best-effort termination request to the whole owned process tree.
    /// The child handle remains valid so its owner can still call `wait`.
    pub fn terminateTree(self: *OwnedChild) void {
        if (self.child.id == null) return;

        if (builtin.os.tag == .windows) {
            if (self.job) |job| {
                if (win32.TerminateJobObject(job, 1) != .FALSE) return;
            }
            _ = windows.ntdll.NtTerminateProcess(self.child.id, .UNSUCCESSFUL);
            return;
        }

        if (builtin.os.tag == .wasi) return;
        const pid = self.child.id.?;
        if (self.owns_tree) {
            std.posix.kill(-pid, .TERM) catch {
                std.posix.kill(pid, .TERM) catch {};
            };
        } else {
            std.posix.kill(pid, .TERM) catch {};
        }
    }

    /// Force-terminates and reaps the owned tree, releasing all process resources.
    pub fn kill(self: *OwnedChild, io: std.Io) void {
        self.terminateTree();
        self.child.kill(io);
        self.closeTreeOwner();
    }

    /// Waits for the direct child and then releases the tree owner.
    /// Closing the Windows job also prevents descendants from being orphaned.
    pub fn wait(self: *OwnedChild, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
        const term = try self.child.wait(io);
        self.closeTreeOwner();
        return term;
    }

    /// Returns a numeric process id suitable for diagnostics on every platform.
    pub fn processId(self: *const OwnedChild) ?u32 {
        const id = self.child.id orelse return null;
        if (builtin.os.tag == .windows) {
            const pid = win32.GetProcessId(id);
            return if (pid == 0) null else pid;
        }
        if (builtin.os.tag == .wasi) return null;
        return @intCast(id);
    }

    fn closeTreeOwner(self: *OwnedChild) void {
        if (builtin.os.tag == .windows) {
            if (self.job) |job| windows.CloseHandle(job);
            self.job = null;
        }
    }
};

/// Resolves argv[0] through the child environment, then spawns an owned tree.
/// Zig's Windows spawn implementation securely quotes and wraps resolved
/// `.cmd`/`.bat` shims with `cmd.exe`; keeping argv intact preserves that path.
pub fn spawn(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SpawnOptions,
) !OwnedChild {
    if (options.argv.len == 0) return error.InvalidArguments;

    var fallback_env: ?std.process.Environ.Map = if (options.environ_map == null)
        try process_env.buildAugmentedEnvMap(allocator)
    else
        null;
    defer if (fallback_env) |*env_map| env_map.deinit();
    const env_map = options.environ_map orelse &fallback_env.?;

    const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, options.argv[0]);
    defer allocator.free(executable);
    const argv = try allocator.alloc([]const u8, options.argv.len);
    defer allocator.free(argv);
    @memcpy(argv, options.argv);
    argv[0] = executable;

    const job = if (builtin.os.tag == .windows and options.own_process_tree)
        try createWindowsJob()
    else if (builtin.os.tag == .windows)
        null
    else {};
    errdefer if (builtin.os.tag == .windows) {
        if (job) |handle| windows.CloseHandle(handle);
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = options.cwd,
        .environ_map = env_map,
        .stdin = options.stdin,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .request_resource_usage_statistics = options.request_resource_usage_statistics,
        .pgid = if (builtin.os.tag == .windows or !options.own_process_tree) null else 0,
        .start_suspended = builtin.os.tag == .windows and options.own_process_tree,
        .create_no_window = builtin.os.tag == .windows and options.hide_window,
    });
    errdefer child.kill(io);

    if (builtin.os.tag == .windows and options.own_process_tree) {
        try assignWindowsJob(job.?, child.id.?);
        switch (windows.ntdll.NtResumeThread(child.thread_handle, null)) {
            .SUCCESS => {},
            else => |status| return windows.unexpectedStatus(status),
        }
    }

    return .{ .child = child, .job = job, .owns_tree = options.own_process_tree };
}

/// Classifies shims whose final Windows launch is delegated to Zig's secure
/// command-interpreter wrapper.
pub fn isWindowsCommandScript(path: []const u8) bool {
    return process_env.isWindowsCommandScript(path);
}

/// Checks a persisted numeric PID without exposing the platform-specific child
/// handle type. Permission failures mean the process still exists but is owned
/// by a security context that Verde cannot inspect.
pub fn processIdIsAlive(pid: u32) bool {
    if (pid == 0) return false;
    if (builtin.os.tag == .windows) {
        const process = win32.OpenProcess(win32.process_query_limited_information, .FALSE, pid) orelse {
            return windows.GetLastError() == .ACCESS_DENIED;
        };
        defer windows.CloseHandle(process);
        var exit_code: windows.DWORD = 0;
        if (win32.GetExitCodeProcess(process, &exit_code) == .FALSE) return false;
        return exit_code == win32.still_active;
    }
    if (builtin.os.tag == .wasi) return false;

    const native_pid = std.math.cast(std.posix.pid_t, pid) orelse return false;
    const group_alive = blk: {
        std.posix.kill(-native_pid, @enumFromInt(0)) catch |group_err| switch (group_err) {
            error.ProcessNotFound => break :blk false,
            error.PermissionDenied => break :blk true,
            else => break :blk false,
        };
        break :blk true;
    };
    if (group_alive) return true;
    std.posix.kill(native_pid, @enumFromInt(0)) catch |pid_err| switch (pid_err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return false,
    };
    return true;
}

/// Requests graceful termination of a persisted detached process tree.
/// Success means the operating system accepted the request, not that the
/// process has already exited; callers should continue polling liveness.
pub fn terminateProcessIdTree(pid: u32) !void {
    if (pid == 0) return error.InvalidProcessId;
    if (builtin.os.tag == .windows) {
        var pid_buffer: [16]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch return error.InvalidProcessId;
        var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        var child = try spawn(std.heap.page_allocator, threaded.io(), .{
            .argv = &.{ "taskkill.exe", "/PID", pid_text, "/T" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .own_process_tree = false,
        });
        const term = try child.wait(threaded.io());
        switch (term) {
            .exited => |code| if (code != 0) return error.TerminationFailed,
            else => return error.TerminationFailed,
        }
        return;
    }
    if (builtin.os.tag == .wasi) return error.UnsupportedPlatform;
    const native_pid = std.math.cast(std.posix.pid_t, pid) orelse return error.InvalidProcessId;
    std.posix.kill(-native_pid, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => try std.posix.kill(native_pid, .TERM),
        else => return err,
    };
}

const win32 = if (builtin.os.tag == .windows) struct {
    const BasicLimitInformation = extern struct {
        per_process_user_time_limit: windows.LARGE_INTEGER,
        per_job_user_time_limit: windows.LARGE_INTEGER,
        limit_flags: windows.DWORD,
        minimum_working_set_size: windows.SIZE_T,
        maximum_working_set_size: windows.SIZE_T,
        active_process_limit: windows.DWORD,
        affinity: windows.ULONG_PTR,
        priority_class: windows.DWORD,
        scheduling_class: windows.DWORD,
    };

    const IoCounters = extern struct {
        read_operation_count: windows.ULONGLONG,
        write_operation_count: windows.ULONGLONG,
        other_operation_count: windows.ULONGLONG,
        read_transfer_count: windows.ULONGLONG,
        write_transfer_count: windows.ULONGLONG,
        other_transfer_count: windows.ULONGLONG,
    };

    const ExtendedLimitInformation = extern struct {
        basic_limit_information: BasicLimitInformation,
        io_info: IoCounters,
        process_memory_limit: windows.SIZE_T,
        job_memory_limit: windows.SIZE_T,
        peak_process_memory_used: windows.SIZE_T,
        peak_job_memory_used: windows.SIZE_T,
    };

    const InformationClass = enum(c_int) {
        extended_limit_information = 9,
    };

    const kill_on_job_close: windows.DWORD = 0x00002000;
    const process_query_limited_information: windows.DWORD = 0x00001000;
    const still_active: windows.DWORD = 259;

    extern "kernel32" fn CreateJobObjectW(
        security_attributes: ?*windows.SECURITY_ATTRIBUTES,
        name: ?[*:0]const u16,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn AssignProcessToJobObject(
        job: windows.HANDLE,
        process: windows.HANDLE,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn SetInformationJobObject(
        job: windows.HANDLE,
        information_class: InformationClass,
        information: *anyopaque,
        information_length: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn TerminateJobObject(
        job: windows.HANDLE,
        exit_code: windows.UINT,
    ) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcessId(process: windows.HANDLE) callconv(.winapi) windows.DWORD;
    extern "kernel32" fn OpenProcess(
        desired_access: windows.DWORD,
        inherit_handle: windows.BOOL,
        process_id: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn GetExitCodeProcess(
        process: windows.HANDLE,
        exit_code: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

fn createWindowsJob() !windows.HANDLE {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const job = win32.CreateJobObjectW(null, null) orelse
        return windows.unexpectedError(windows.GetLastError());
    errdefer windows.CloseHandle(job);

    var limits: win32.ExtendedLimitInformation = std.mem.zeroes(win32.ExtendedLimitInformation);
    limits.basic_limit_information.limit_flags = win32.kill_on_job_close;
    if (win32.SetInformationJobObject(
        job,
        .extended_limit_information,
        @ptrCast(&limits),
        @intCast(@sizeOf(win32.ExtendedLimitInformation)),
    ) == .FALSE) return windows.unexpectedError(windows.GetLastError());
    return job;
}

fn assignWindowsJob(job: windows.HANDLE, child: windows.HANDLE) !void {
    comptime std.debug.assert(builtin.os.tag == .windows);
    if (win32.AssignProcessToJobObject(job, child) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

test "Windows command shim classification is case insensitive" {
    try std.testing.expect(isWindowsCommandScript("C:\\Users\\Test\\AppData\\Roaming\\npm\\claude.CMD"));
    try std.testing.expect(isWindowsCommandScript("agent.bat"));
    try std.testing.expect(!isWindowsCommandScript("codex.exe"));
}

test "zero is never a live process id" {
    try std.testing.expect(!processIdIsAlive(0));
}
