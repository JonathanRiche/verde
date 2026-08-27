//! Windows ConPTY process backend owned by the persistent session daemon.

const std = @import("std");
const builtin = @import("builtin");
const process_env = @import("../../platform/env.zig");

const windows = std.os.windows;
const log = std.log.scoped(.windows_conpty);

const MAX_QUEUED_INPUT: usize = 8 * 1024 * 1024;
const MAX_QUEUED_OUTPUT: usize = 4 * 1024 * 1024;
const WORKER_CHUNK_BYTES: usize = 16 * 1024;
const STILL_ACTIVE: windows.DWORD = 259;
const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
const CREATE_SUSPENDED: windows.DWORD = 0x00000004;
const CREATE_NEW_PROCESS_GROUP: windows.DWORD = 0x00000200;
const CREATE_UNICODE_ENVIRONMENT: windows.DWORD = 0x00000400;
const EXTENDED_STARTUPINFO_PRESENT: windows.DWORD = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: windows.DWORD_PTR = 0x00020016;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: windows.DWORD = 0x00002000;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: c_int = 9;
const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const INFINITE: windows.DWORD = 0xffffffff;
const INVALID_RESUME_RESULT: windows.DWORD = 0xffffffff;
const FALSE: windows.BOOL = .FALSE;

pub const ReadResult = struct {
    bytes: usize = 0,
    dropped: u64 = 0,
    eof: bool = false,
};

pub const IoWorkerStatus = enum {
    running,
    broken_pipe,
    zero_length,
    cancelled,
    failed,
    shutdown,
    unavailable,
};

/// Process-safe worker health exposed by the session daemon without terminal contents.
pub const IoHealth = struct {
    output_reader_status: IoWorkerStatus = .unavailable,
    output_reader_error_code: ?u32 = null,
    input_writer_status: IoWorkerStatus = .unavailable,
    input_writer_error_code: ?u32 = null,
};

pub const ShellKind = enum {
    powershell_7,
    windows_powershell,
    command_prompt,
};

pub const ShellAvailability = struct {
    powershell_7: bool,
    windows_powershell: bool,
};

/// Selects the preferred interactive shell without coupling tests to host PATH.
pub fn selectShellKind(availability: ShellAvailability) ShellKind {
    if (availability.powershell_7) return .powershell_7;
    if (availability.windows_powershell) return .windows_powershell;
    return .command_prompt;
}

/// Builds the argv used by the daemon's Windows ConPTY process.
pub fn commandForOptions(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();

    if (args.len == 0) return defaultShellCommand(allocator, &env_map);

    const executable = try process_env.resolveExecutableInEnvMapAlloc(allocator, &env_map, args[0]);
    defer allocator.free(executable);
    // Preserve argv until spawnConpty chooses the correct final serializer.
    // Batch scripts cannot safely pass through generic CreateProcess quoting.
    const command = try allocator.alloc([:0]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    command[0] = try allocator.dupeZ(u8, executable);
    initialized += 1;
    for (args[1..], 1..) |arg, index| {
        command[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
    }
    return command;
}

/// Serializes argv according to the CreateProcessW/CommandLineToArgvW rules.
pub fn windowsCreateCommandLine(allocator: std.mem.Allocator, argv: []const []const u8) ![:0]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;

    for (argv, 0..) |arg, arg_index| {
        if (arg_index > 0) try writer.writeByte(' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\"") == null) {
            try writer.writeAll(arg);
            continue;
        }

        try writer.writeByte('"');
        var backslashes: usize = 0;
        for (arg) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try writer.splatByteAll('\\', backslashes * 2 + 1);
                try writer.writeByte('"');
                backslashes = 0;
            },
            else => {
                try writer.splatByteAll('\\', backslashes);
                try writer.writeByte(byte);
                backslashes = 0;
            },
        };
        // Backslashes before the closing quote must be doubled so the quote
        // terminates the argument instead of becoming a literal character.
        try writer.splatByteAll('\\', backslashes * 2);
        try writer.writeByte('"');
    }

    return buffer.toOwnedSliceSentinel(0);
}

/// Serializes a verified `.cmd`/`.bat` path and arguments using cmd.exe's
/// parsing rules. This mirrors Zig's BatBadBut mitigation rather than treating
/// a batch script like a native executable's CreateProcess argv.
pub fn windowsBatchCommandLine(allocator: std.mem.Allocator, script_path: []const u8, script_args: []const []const u8) ![:0]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    defer buffer.deinit();
    const writer = &buffer.writer;

    // Explicit extension and delayed-expansion modes are part of the percent
    // escaping contract below; registry defaults must not change semantics.
    try writer.writeAll("cmd.exe /d /e:ON /v:OFF /c \"");
    try writer.writeByte('"');
    if (std.mem.indexOfAny(u8, script_path, "\\/") == null) try writer.writeAll(".\\");
    try writer.writeAll(script_path);
    try writer.writeByte('"');

    for (script_args) |arg| {
        if (std.mem.indexOfAny(u8, arg, "\x00\r\n") != null) return error.InvalidBatchScriptArg;
        try writer.writeByte(' ');

        var needs_quotes = arg.len == 0 or arg[arg.len - 1] == '\\';
        if (!needs_quotes) {
            for (arg) |byte| switch (byte) {
                'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
                else => {
                    needs_quotes = true;
                    break;
                },
            };
        }
        if (needs_quotes) try writer.writeByte('"');

        var backslashes: usize = 0;
        for (arg) |byte| {
            switch (byte) {
                '\\' => backslashes += 1,
                '"' => {
                    try writer.splatByteAll('\\', backslashes);
                    try writer.writeByte('"');
                    backslashes = 0;
                },
                '%' => {
                    // `%cd:~,%` expands to empty with extensions enabled, so
                    // wrapping each literal percent prevents `%VAR%` expansion.
                    try writer.writeAll("%%cd:~,");
                    backslashes = 0;
                },
                else => backslashes = 0,
            }
            try writer.writeByte(byte);
        }
        if (needs_quotes) {
            try writer.splatByteAll('\\', backslashes);
            try writer.writeByte('"');
        }
    }

    try writer.writeByte('"');
    return buffer.toOwnedSliceSentinel(0);
}

pub const Backend = struct {
    input_read: windows.HANDLE,
    input_write: windows.HANDLE,
    output_read: windows.HANDLE,
    output_write: windows.HANDLE,
    pseudo_console: HPCON,
    process_handle: windows.HANDLE,
    job_handle: windows.HANDLE,
    child_pid: u32,
    running: bool = true,
    exit_status: ?u32 = null,
    io_state: *IoState,
    reader_thread: std.Thread,
    writer_thread: std.Thread,

    pub fn create(allocator: std.mem.Allocator, cwd: []const u8, command: []const [:0]u8, identity: anytype, cols: u16, rows: u16) !Backend {
        if (command.len == 0) return error.EmptyCommand;
        const spawned = try spawnConpty(allocator, cwd, command, identity, cols, rows);
        errdefer closeSpawned(spawned);

        const io_state = try allocator.create(IoState);
        errdefer allocator.destroy(io_state);
        io_state.* = try IoState.init(allocator);
        errdefer io_state.deinit();

        const reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{ io_state, spawned.output_read });
        errdefer {
            io_state.beginShutdown();
            _ = CancelSynchronousIo(reader_thread.getHandle());
            reader_thread.join();
        }
        const writer_thread = try std.Thread.spawn(.{}, writerThreadMain, .{ io_state, spawned.input_write });
        errdefer {
            io_state.beginShutdown();
            _ = CancelSynchronousIo(writer_thread.getHandle());
            writer_thread.join();
        }

        return .{
            .input_read = spawned.input_read,
            .input_write = spawned.input_write,
            .output_read = spawned.output_read,
            .output_write = spawned.output_write,
            .pseudo_console = spawned.pseudo_console,
            .process_handle = spawned.process_handle,
            .job_handle = spawned.job_handle,
            .child_pid = spawned.child_pid,
            .io_state = io_state,
            .reader_thread = reader_thread,
            .writer_thread = writer_thread,
        };
    }

    pub fn deinit(self: *Backend, allocator: std.mem.Allocator) void {
        self.io_state.beginShutdown();
        // `running` tracks the direct shell process and can already be false
        // while a descendant remains attached to the ConPTY. Always empty the
        // job before ClosePseudoConsole: older Windows versions wait for every
        // client and can otherwise block here indefinitely.
        _ = TerminateJobObject(self.job_handle, 1);

        // The ConPTY pipe handles are synchronous by contract. Cancel the
        // dedicated workers rather than ever blocking the daemon request or
        // polling thread on a large paste or a quiet terminal.
        _ = CancelSynchronousIo(self.writer_thread.getHandle());
        self.writer_thread.join();
        windows.CloseHandle(self.input_write);
        windows.CloseHandle(self.input_read);

        // Drop our retained ConPTY-facing writer before closing the HPCON so it
        // cannot mask ConHost's eventual EOF. The output reader remains alive
        // while ClosePseudoConsole drains final VT output; older Windows
        // releases can otherwise block this close indefinitely.
        windows.CloseHandle(self.output_write);
        ClosePseudoConsole(self.pseudo_console);
        _ = CancelSynchronousIo(self.reader_thread.getHandle());
        self.reader_thread.join();
        windows.CloseHandle(self.output_read);

        _ = WaitForSingleObject(self.process_handle, 2000);
        _ = self.captureExitStatus();
        windows.CloseHandle(self.process_handle);
        windows.CloseHandle(self.job_handle);
        self.io_state.deinit();
        allocator.destroy(self.io_state);
    }

    pub fn read(self: *Backend, buffer: []u8) ReadResult {
        const result = self.io_state.takeOutput(buffer);
        _ = self.captureExitStatus();
        return .{
            .bytes = result.bytes,
            .dropped = result.dropped,
            .eof = result.eof and result.bytes == 0,
        };
    }

    pub fn write(self: *Backend, bytes: []const u8) !bool {
        if (!self.running or bytes.len == 0) return false;
        try self.io_state.queueInput(bytes);
        return true;
    }

    pub fn resize(self: *Backend, cols: u16, rows: u16) !void {
        if (!self.running) return;
        const result = ResizePseudoConsole(self.pseudo_console, .{
            .X = @intCast(@max(cols, 1)),
            .Y = @intCast(@max(rows, 1)),
        });
        if (result < 0) return error.ResizeFailed;
    }

    pub fn terminate(self: *Backend) bool {
        // The direct process can exit before descendants in its job. Terminate
        // the job even after that handle has reported an exit.
        if (TerminateJobObject(self.job_handle, 1) == FALSE) return false;
        self.running = false;
        _ = self.captureExitStatus();
        return true;
    }

    pub fn foregroundProcessGroup(_: *const Backend) ?usize {
        // Windows has no Unix-style foreground process group. ConPTY routes
        // console control/input to the active client process internally.
        return null;
    }

    pub fn processId(self: *const Backend) usize {
        return self.child_pid;
    }

    pub fn isRunning(self: *Backend) bool {
        _ = self.captureExitStatus();
        return self.running;
    }

    pub fn exitStatus(self: *Backend) ?u32 {
        _ = self.captureExitStatus();
        return self.exit_status;
    }

    pub fn ioHealth(self: *const Backend) IoHealth {
        return self.io_state.health();
    }

    fn captureExitStatus(self: *Backend) bool {
        if (self.exit_status != null) return false;
        var exit_code: windows.DWORD = 0;
        if (GetExitCodeProcess(self.process_handle, &exit_code) == FALSE) return false;
        if (exit_code == STILL_ACTIVE) return false;
        self.running = false;
        self.exit_status = exit_code;
        return true;
    }
};

/// Force-terminates a stale daemon by PID before a protocol-incompatible
/// replacement is launched.
pub fn terminateProcessById(pid: u32) bool {
    const process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid) orelse return false;
    defer windows.CloseHandle(process);
    if (TerminateProcess(process, 1) == FALSE) return false;
    _ = WaitForSingleObject(process, 2000);
    return true;
}

const IoState = struct {
    allocator: std.mem.Allocator,
    input_ready_event: windows.HANDLE,
    mutex: std.atomic.Mutex = .unlocked,
    input: std.ArrayList(u8) = .empty,
    input_offset: usize = 0,
    output: std.ArrayList(u8) = .empty,
    output_offset: usize = 0,
    output_dropped: u64 = 0,
    shutting_down: bool = false,
    reader_status: IoWorkerStatus = .running,
    reader_error_code: ?u32 = null,
    writer_status: IoWorkerStatus = .running,
    writer_error_code: ?u32 = null,

    fn init(allocator: std.mem.Allocator) !IoState {
        const input_ready_event = CreateEventW(null, FALSE, FALSE, null) orelse return error.SystemResources;
        return .{
            .allocator = allocator,
            .input_ready_event = input_ready_event,
        };
    }

    fn deinit(self: *IoState) void {
        self.input.deinit(self.allocator);
        self.output.deinit(self.allocator);
        windows.CloseHandle(self.input_ready_event);
    }

    fn lock(self: *IoState) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn beginShutdown(self: *IoState) void {
        self.lock();
        self.shutting_down = true;
        self.mutex.unlock();
        // The writer can be parked in WaitForSingleObject rather than inside a
        // cancellable pipe write, so shutdown must wake both possible states.
        _ = SetEvent(self.input_ready_event);
    }

    fn queueInput(self: *IoState, bytes: []const u8) !void {
        self.lock();
        if (self.shutting_down or self.writer_status != .running) {
            self.mutex.unlock();
            return error.BrokenPipe;
        }
        compactQueue(&self.input, &self.input_offset);
        if (self.input.items.len - self.input_offset + bytes.len > MAX_QUEUED_INPUT) {
            self.mutex.unlock();
            return error.InputQueueFull;
        }
        self.input.appendSlice(self.allocator, bytes) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        // Auto-reset events retain one signal, so input queued between the
        // writer's empty check and its wait cannot miss this wake-up.
        if (SetEvent(self.input_ready_event) == FALSE) return error.BrokenPipe;
    }

    fn takeInput(self: *IoState, buffer: []u8) struct { bytes: usize, stop: bool } {
        self.lock();
        defer self.mutex.unlock();
        const available = self.input.items.len - self.input_offset;
        const count = @min(available, buffer.len);
        if (count > 0) {
            @memcpy(buffer[0..count], self.input.items[self.input_offset..][0..count]);
            self.input_offset += count;
            compactQueue(&self.input, &self.input_offset);
        }
        return .{ .bytes = count, .stop = self.shutting_down and available == 0 };
    }

    fn appendOutput(self: *IoState, bytes: []const u8) void {
        self.lock();
        defer self.mutex.unlock();
        compactQueue(&self.output, &self.output_offset);
        const retained = self.output.items.len - self.output_offset;
        const overflow = retained + bytes.len -| MAX_QUEUED_OUTPUT;
        if (overflow > 0) {
            const dropped_existing = @min(overflow, retained);
            self.output_offset += dropped_existing;
            self.output_dropped +%= dropped_existing;
            const dropped_input = overflow - dropped_existing;
            self.output_dropped +%= dropped_input;
            compactQueue(&self.output, &self.output_offset);
            self.output.appendSlice(self.allocator, bytes[dropped_input..]) catch {
                self.output_dropped +%= bytes.len - dropped_input;
            };
            return;
        }
        self.output.appendSlice(self.allocator, bytes) catch {
            self.output_dropped +%= bytes.len;
        };
    }

    fn takeOutput(self: *IoState, buffer: []u8) ReadResult {
        self.lock();
        defer self.mutex.unlock();
        const available = self.output.items.len - self.output_offset;
        const count = @min(available, buffer.len);
        if (count > 0) {
            @memcpy(buffer[0..count], self.output.items[self.output_offset..][0..count]);
            self.output_offset += count;
            compactQueue(&self.output, &self.output_offset);
        }
        const dropped = self.output_dropped;
        self.output_dropped = 0;
        return .{ .bytes = count, .dropped = dropped, .eof = self.reader_status != .running and available == count };
    }

    fn finishReader(self: *IoState, status: IoWorkerStatus, error_code: ?u32) void {
        self.lock();
        defer self.mutex.unlock();
        self.reader_status = status;
        self.reader_error_code = error_code;
    }

    fn finishWriter(self: *IoState, status: IoWorkerStatus, error_code: ?u32) void {
        self.lock();
        defer self.mutex.unlock();
        self.writer_status = status;
        self.writer_error_code = error_code;
    }

    fn health(self: *IoState) IoHealth {
        self.lock();
        defer self.mutex.unlock();
        return .{
            .output_reader_status = self.reader_status,
            .output_reader_error_code = self.reader_error_code,
            .input_writer_status = self.writer_status,
            .input_writer_error_code = self.writer_error_code,
        };
    }
};

fn compactQueue(queue: *std.ArrayList(u8), offset: *usize) void {
    if (offset.* == 0) return;
    if (offset.* < queue.items.len and offset.* < 1024 * 1024) return;
    const remaining = queue.items.len - offset.*;
    std.mem.copyForwards(u8, queue.items[0..remaining], queue.items[offset.*..]);
    queue.shrinkRetainingCapacity(remaining);
    offset.* = 0;
}

fn readerThreadMain(state: *IoState, output_read: windows.HANDLE) void {
    var buffer: [WORKER_CHUNK_BYTES]u8 = undefined;
    while (true) {
        var read_len: windows.DWORD = 0;
        if (ReadFile(output_read, &buffer, buffer.len, &read_len, null) == FALSE) {
            const error_value = windows.GetLastError();
            state.finishReader(workerStatusForError(error_value), @intCast(@intFromEnum(error_value)));
            return;
        }
        if (read_len == 0) {
            state.finishReader(.zero_length, null);
            return;
        }
        state.appendOutput(buffer[0..read_len]);
    }
}

fn writerThreadMain(state: *IoState, input_write: windows.HANDLE) void {
    var buffer: [WORKER_CHUNK_BYTES]u8 = undefined;
    while (true) {
        const next = state.takeInput(&buffer);
        if (next.bytes == 0) {
            if (next.stop) {
                state.finishWriter(.shutdown, null);
                return;
            }
            const wait_result = WaitForSingleObject(state.input_ready_event, INFINITE);
            if (wait_result != WAIT_OBJECT_0) {
                const error_value = windows.GetLastError();
                state.finishWriter(.failed, @intCast(@intFromEnum(error_value)));
                return;
            }
            continue;
        }

        var offset: usize = 0;
        while (offset < next.bytes) {
            var written: windows.DWORD = 0;
            if (WriteFile(input_write, buffer[offset..].ptr, @intCast(next.bytes - offset), &written, null) == FALSE) {
                const error_value = windows.GetLastError();
                state.finishWriter(workerStatusForError(error_value), @intCast(@intFromEnum(error_value)));
                return;
            }
            if (written == 0) {
                state.finishWriter(.zero_length, null);
                return;
            }
            offset += written;
        }
    }
}

fn workerStatusForError(error_value: windows.Win32Error) IoWorkerStatus {
    return switch (error_value) {
        .BROKEN_PIPE, .PIPE_NOT_CONNECTED, .NO_DATA => .broken_pipe,
        .OPERATION_ABORTED => .cancelled,
        else => .failed,
    };
}

const Spawned = struct {
    input_read: windows.HANDLE,
    input_write: windows.HANDLE,
    output_read: windows.HANDLE,
    output_write: windows.HANDLE,
    pseudo_console: HPCON,
    process_handle: windows.HANDLE,
    job_handle: windows.HANDLE,
    child_pid: u32,
};

fn spawnConpty(allocator: std.mem.Allocator, cwd: []const u8, command: []const [:0]u8, identity: anytype, cols: u16, rows: u16) !Spawned {
    var env_map = try process_env.buildAugmentedEnvMap(allocator);
    defer env_map.deinit();
    try addChildEnvironment(&env_map, identity);

    const is_batch_script = process_env.isWindowsCommandScript(command[0]);
    const application = if (is_batch_script)
        try resolveCommandPrompt(allocator, &env_map)
    else
        try allocator.dupe(u8, command[0]);
    defer allocator.free(application);
    const command_line = if (is_batch_script)
        try windowsBatchCommandLine(allocator, command[0], command[1..])
    else
        try windowsCreateCommandLine(allocator, command);
    defer allocator.free(command_line);
    const command_line_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_line);
    defer allocator.free(command_line_w);
    const application_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, application);
    defer allocator.free(application_w);
    const cwd_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, cwd);
    defer allocator.free(cwd_w);

    const environment = try env_map.createWindowsBlock(allocator, .{});
    defer environment.deinit(allocator);

    var input_read: windows.HANDLE = undefined;
    var input_write: windows.HANDLE = undefined;
    var output_read: windows.HANDLE = undefined;
    var output_write: windows.HANDLE = undefined;
    if (CreatePipe(&input_read, &input_write, null, 0) == FALSE) return win32Error();
    var input_read_open = true;
    var input_write_open = true;
    errdefer {
        if (input_read_open) windows.CloseHandle(input_read);
        if (input_write_open) windows.CloseHandle(input_write);
    }
    if (CreatePipe(&output_read, &output_write, null, 0) == FALSE) return win32Error();
    var output_read_open = true;
    var output_write_open = true;
    errdefer {
        if (output_read_open) windows.CloseHandle(output_read);
        if (output_write_open) windows.CloseHandle(output_write);
    }
    if (SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0) == FALSE) return win32Error();
    if (SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0) == FALSE) return win32Error();

    var pseudo_console: HPCON = undefined;
    if (CreatePseudoConsole(.{
        .X = @intCast(@max(cols, 1)),
        .Y = @intCast(@max(rows, 1)),
    }, input_read, output_write, 0, &pseudo_console) < 0) return error.CreatePseudoConsoleFailed;
    errdefer ClosePseudoConsole(pseudo_console);

    var attribute_list_size: windows.SIZE_T = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attribute_list_size);
    const attribute_storage = try allocator.alignedAlloc(u8, .of(usize), attribute_list_size);
    defer allocator.free(attribute_storage);
    const attribute_list: ProcThreadAttributeList = @ptrCast(attribute_storage.ptr);
    if (InitializeProcThreadAttributeList(attribute_list, 1, 0, &attribute_list_size) == FALSE) return win32Error();
    defer DeleteProcThreadAttributeList(attribute_list);
    if (UpdateProcThreadAttribute(
        attribute_list,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pseudo_console,
        @sizeOf(HPCON),
        null,
        null,
    ) == FALSE) return win32Error();

    var startup_info = conptyStartupInfo(attribute_list);

    const job_handle = try createJobObject();
    errdefer windows.CloseHandle(job_handle);
    var process_info: windows.PROCESS.INFORMATION = undefined;
    if (CreateProcessW(
        application_w.ptr,
        command_line_w.ptr,
        null,
        null,
        FALSE,
        CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
        environment.slice.ptr,
        cwd_w.ptr,
        @ptrCast(&startup_info.startup_info),
        &process_info,
    ) == FALSE) return win32Error();
    errdefer {
        _ = TerminateProcess(process_info.hProcess, 1);
        windows.CloseHandle(process_info.hThread);
        windows.CloseHandle(process_info.hProcess);
    }
    if (AssignProcessToJobObject(job_handle, process_info.hProcess) == FALSE) return win32Error();
    if (ResumeThread(process_info.hThread) == INVALID_RESUME_RESULT) return win32Error();

    windows.CloseHandle(process_info.hThread);

    // Retain all four ends for the ConPTY lifetime, matching Ghostty's Windows
    // backend. Some Windows builds otherwise expose an initial VT frame and
    // then report a broken channel before the hosted shell has exited.
    input_read_open = false;
    input_write_open = false;
    output_read_open = false;
    output_write_open = false;

    return .{
        .input_read = input_read,
        .input_write = input_write,
        .output_read = output_read,
        .output_write = output_write,
        .pseudo_console = pseudo_console,
        .process_handle = process_info.hProcess,
        .job_handle = job_handle,
        .child_pid = process_info.dwProcessId,
    };
}

fn conptyStartupInfo(attribute_list: ProcThreadAttributeList) StartupInfoEx {
    var startup_info: StartupInfoEx = .{
        .startup_info = std.mem.zeroes(windows.STARTUPINFOW),
        .attribute_list = attribute_list,
    };
    startup_info.startup_info.cb = @sizeOf(StartupInfoEx);
    // The persistent daemon itself runs with NUL standard streams. Marking the
    // null hStd* fields as intentional lets ConPTY replace that detached parent
    // state with its console handles; otherwise PowerShell observes input EOF
    // immediately after drawing its first prompt and exits cleanly.
    startup_info.startup_info.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.startup_info.hStdInput = null;
    startup_info.startup_info.hStdOutput = null;
    startup_info.startup_info.hStdError = null;
    return startup_info;
}

fn addChildEnvironment(env_map: *std.process.Environ.Map, identity: anytype) !void {
    try env_map.put("TERM", "xterm-256color");
    try env_map.put("COLORTERM", "truecolor");
    try env_map.put("TERM_PROGRAM", "ghostty");
    try env_map.put("TERM_PROGRAM_VERSION", "1.1.0");
    try env_map.put("CLICOLOR", "1");
    try env_map.put("CLICOLOR_FORCE", "1");
    try env_map.put("FORCE_COLOR", "3");
    _ = env_map.swapRemove("NO_COLOR");
    try env_map.put("VERDE", "1");
    try env_map.put("VERDE_SESSION_ID", identity.session_id);
    try env_map.put("VERDE_WORKSPACE_ID", identity.project_id);
    try env_map.put("VERDE_WORKSPACE_PATH", identity.project_path);
    try env_map.put("VERDE_DOCK_ID", identity.dock_id);
    try env_map.put("VERDE_PANE_ID", identity.pane_id);
    try env_map.put("VERDE_SESSIONIZER_SOCKET", identity.sessionizer_endpoint);
    try env_map.put("VERDE_CLI", identity.cli_path);
    if (identity.mcp_token) |value| try env_map.put("VERDE_MCP_TOKEN", value);
    if (identity.live_endpoint.len > 0) {
        try env_map.put("VERDE_SOCKET", identity.live_endpoint);
        try env_map.put("VERDE_LIVE_ENDPOINT", identity.live_endpoint);
        try env_map.put("VERDE_LIVE_SOCKET", identity.live_endpoint);
    }
}

fn defaultShellCommand(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![][:0]u8 {
    const pwsh = process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, "pwsh.exe") catch null;
    defer if (pwsh) |path| allocator.free(path);
    const powershell = if (pwsh == null) resolveWindowsPowerShell(allocator, env_map) catch null else null;
    defer if (powershell) |path| allocator.free(path);
    return switch (selectShellKind(.{
        .powershell_7 = pwsh != null,
        .windows_powershell = powershell != null,
    })) {
        .powershell_7 => dupeCommand(allocator, &.{ pwsh.?, "-NoLogo", "-NoExit" }),
        .windows_powershell => dupeCommand(allocator, &.{ powershell.?, "-NoLogo", "-NoExit" }),
        .command_prompt => blk: {
            const cmd = try resolveCommandPrompt(allocator, env_map);
            defer allocator.free(cmd);
            break :blk dupeCommand(allocator, &.{ cmd, "/d", "/k" });
        },
    };
}

fn resolveWindowsPowerShell(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, "powershell.exe")) |path| return path else |_| {}
    const system_root = env_map.get("SystemRoot") orelse env_map.get("WINDIR") orelse return error.FileNotFound;
    const candidate = try joinWindowsPath(allocator, &.{ system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer allocator.free(candidate);
    return process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, candidate);
}

fn resolveCommandPrompt(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("ComSpec") orelse env_map.get("COMSPEC")) |comspec| {
        return allocator.dupe(u8, comspec);
    }
    if (process_env.resolveExecutableInEnvMapAlloc(allocator, env_map, "cmd.exe")) |path| return path else |_| {}
    const system_root = env_map.get("SystemRoot") orelse env_map.get("WINDIR") orelse "C:\\Windows";
    return joinWindowsPath(allocator, &.{ system_root, "System32", "cmd.exe" });
}

fn joinWindowsPath(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (parts, 0..) |part, index| {
        if (part.len == 0) continue;
        if (index > 0 and writer.writer.buffered().len > 0) {
            const previous = writer.writer.buffered()[writer.writer.buffered().len - 1];
            if (previous != '\\' and previous != '/' and part[0] != '\\' and part[0] != '/') try writer.writer.writeByte('\\');
        }
        const adjusted = if (writer.writer.buffered().len > 0 and
            (writer.writer.buffered()[writer.writer.buffered().len - 1] == '\\' or writer.writer.buffered()[writer.writer.buffered().len - 1] == '/') and
            (part[0] == '\\' or part[0] == '/')) part[1..] else part;
        try writer.writer.writeAll(adjusted);
    }
    return writer.toOwnedSlice();
}

fn dupeCommand(allocator: std.mem.Allocator, args: []const []const u8) ![][:0]u8 {
    const command = try allocator.alloc([:0]u8, args.len);
    var initialized: usize = 0;
    errdefer {
        for (command[0..initialized]) |arg| allocator.free(arg);
        allocator.free(command);
    }
    for (args, 0..) |arg, index| {
        command[index] = try allocator.dupeZ(u8, arg);
        initialized += 1;
    }
    return command;
}

fn createJobObject() !windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return win32Error();
    errdefer windows.CloseHandle(job);
    var limits: JobObjectExtendedLimitInformation = std.mem.zeroes(JobObjectExtendedLimitInformation);
    limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (SetInformationJobObject(
        job,
        JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
        @ptrCast(&limits),
        @sizeOf(JobObjectExtendedLimitInformation),
    ) == FALSE) return win32Error();
    return job;
}

fn closeSpawned(spawned: Spawned) void {
    _ = TerminateJobObject(spawned.job_handle, 1);
    windows.CloseHandle(spawned.input_write);
    windows.CloseHandle(spawned.input_read);
    // Backend construction can fail before its reader worker exists. Break the
    // output pipe first so ClosePseudoConsole cannot wait forever for a reader.
    windows.CloseHandle(spawned.output_read);
    windows.CloseHandle(spawned.output_write);
    ClosePseudoConsole(spawned.pseudo_console);
    windows.CloseHandle(spawned.process_handle);
    windows.CloseHandle(spawned.job_handle);
}

fn win32Error() error{WindowsOperationFailed} {
    log.err("Windows ConPTY operation failed error={s}", .{@tagName(windows.GetLastError())});
    return error.WindowsOperationFailed;
}

const HPCON = windows.HANDLE;
const ProcThreadAttributeList = *anyopaque;

const StartupInfoEx = extern struct {
    startup_info: windows.STARTUPINFOW,
    attribute_list: ProcThreadAttributeList,
};

const JobObjectBasicLimitInformation = extern struct {
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

const JobObjectExtendedLimitInformation = extern struct {
    basic_limit_information: JobObjectBasicLimitInformation,
    io_info: IoCounters,
    process_memory_limit: windows.SIZE_T,
    job_memory_limit: windows.SIZE_T,
    peak_process_memory_used: windows.SIZE_T,
    peak_job_memory_used: windows.SIZE_T,
};

const PROCESS_TERMINATE: windows.DWORD = 0x0001;
const SYNCHRONIZE: windows.DWORD = 0x00100000;

extern "kernel32" fn CreatePipe(read_pipe: *windows.HANDLE, write_pipe: *windows.HANDLE, attributes: ?*windows.SECURITY_ATTRIBUTES, size: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateEventW(event_attributes: ?*windows.SECURITY_ATTRIBUTES, manual_reset: windows.BOOL, initial_state: windows.BOOL, name: ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetHandleInformation(handle: windows.HANDLE, mask: windows.DWORD, flags: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreatePseudoConsole(size: windows.COORD, input: windows.HANDLE, output: windows.HANDLE, flags: windows.DWORD, pseudo_console: *HPCON) callconv(.winapi) i32;
extern "kernel32" fn ResizePseudoConsole(pseudo_console: HPCON, size: windows.COORD) callconv(.winapi) i32;
extern "kernel32" fn ClosePseudoConsole(pseudo_console: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?ProcThreadAttributeList, count: windows.DWORD, flags: windows.DWORD, size: *windows.SIZE_T) callconv(.winapi) windows.BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: ProcThreadAttributeList, flags: windows.DWORD, attribute: windows.DWORD_PTR, value: windows.LPVOID, size: windows.SIZE_T, previous: ?windows.LPVOID, return_size: ?*windows.SIZE_T) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: ProcThreadAttributeList) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(application: ?windows.LPCWSTR, command_line: ?windows.LPWSTR, process_attributes: ?*windows.SECURITY_ATTRIBUTES, thread_attributes: ?*windows.SECURITY_ATTRIBUTES, inherit_handles: windows.BOOL, creation_flags: windows.DWORD, environment: ?[*:0]const u16, current_directory: ?windows.LPCWSTR, startup_info: *windows.STARTUPINFOW, process_information: *windows.PROCESS.INFORMATION) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResumeThread(thread: windows.HANDLE) callconv(.winapi) windows.DWORD;
extern "kernel32" fn ReadFile(file: windows.HANDLE, buffer: [*]u8, bytes_to_read: windows.DWORD, bytes_read: *windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(file: windows.HANDLE, buffer: [*]const u8, bytes_to_write: windows.DWORD, bytes_written: *windows.DWORD, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetExitCodeProcess(process: windows.HANDLE, exit_code: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateProcess(process: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;
extern "kernel32" fn OpenProcess(desired_access: windows.DWORD, inherit_handle: windows.BOOL, process_id: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn CancelSynchronousIo(thread: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateJobObjectW(attributes: ?*windows.SECURITY_ATTRIBUTES, name: ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(job: windows.HANDLE, information_class: c_int, information: *anyopaque, information_length: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: windows.HANDLE, process: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn TerminateJobObject(job: windows.HANDLE, exit_code: windows.UINT) callconv(.winapi) windows.BOOL;

test "CreateProcess command line quoting handles spaces quotes and trailing slashes" {
    const allocator = std.testing.allocator;
    const line = try windowsCreateCommandLine(allocator, &.{
        "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
        "",
        "plain",
        "two words",
        "say\"hello",
        "C:\\trailing\\",
    });
    defer allocator.free(line);
    try std.testing.expectEqualStrings(
        "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" \"\" plain \"two words\" \"say\\\"hello\" C:\\trailing\\",
        line,
    );
}

test "batch command line uses hardened cmd escaping" {
    const allocator = std.testing.allocator;
    const line = try windowsBatchCommandLine(allocator, "npm.cmd", &.{
        "",
        "%PATH%",
        "& whoami",
        "bang!",
        "trailing\\",
    });
    defer allocator.free(line);

    try std.testing.expect(std.mem.startsWith(u8, line, "cmd.exe /d /e:ON /v:OFF /c \"\".\\npm.cmd\" "));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"%%cd:~,%PATH%%cd:~,%\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"& whoami\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"bang!\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "\"trailing\\\\\"\""));
}

test "batch command line rejects lossy control characters" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidBatchScriptArg, windowsBatchCommandLine(allocator, "npm.cmd", &.{"line\nnext"}));
    try std.testing.expectError(error.InvalidBatchScriptArg, windowsBatchCommandLine(allocator, "npm.cmd", &.{"line\rnext"}));
    try std.testing.expectError(error.InvalidBatchScriptArg, windowsBatchCommandLine(allocator, "npm.cmd", &.{"nul\x00tail"}));
}

test "interactive shell preference is deterministic" {
    try std.testing.expectEqual(ShellKind.powershell_7, selectShellKind(.{ .powershell_7 = true, .windows_powershell = true }));
    try std.testing.expectEqual(ShellKind.windows_powershell, selectShellKind(.{ .powershell_7 = false, .windows_powershell = true }));
    try std.testing.expectEqual(ShellKind.command_prompt, selectShellKind(.{ .powershell_7 = false, .windows_powershell = false }));
}

test "ConPTY worker health preserves completion reasons" {
    if (builtin.os.tag != .windows) return;
    var state = try IoState.init(std.testing.allocator);
    defer state.deinit();

    state.finishReader(.broken_pipe, @intFromEnum(windows.Win32Error.BROKEN_PIPE));
    state.finishWriter(.cancelled, @intFromEnum(windows.Win32Error.OPERATION_ABORTED));
    const health = state.health();

    try std.testing.expectEqual(IoWorkerStatus.broken_pipe, health.output_reader_status);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(windows.Win32Error.BROKEN_PIPE)), health.output_reader_error_code);
    try std.testing.expectEqual(IoWorkerStatus.cancelled, health.input_writer_status);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(windows.Win32Error.OPERATION_ABORTED)), health.input_writer_error_code);
    try std.testing.expectEqual(IoWorkerStatus.broken_pipe, workerStatusForError(.PIPE_NOT_CONNECTED));
    try std.testing.expectEqual(IoWorkerStatus.failed, workerStatusForError(.INVALID_HANDLE));
}

test "ConPTY input queue signals and resets its writer event" {
    if (builtin.os.tag != .windows) return;
    var state = try IoState.init(std.testing.allocator);
    defer state.deinit();

    try state.queueInput("abc");
    try std.testing.expectEqual(WAIT_OBJECT_0, WaitForSingleObject(state.input_ready_event, 0));
    try std.testing.expectEqual(WAIT_TIMEOUT, WaitForSingleObject(state.input_ready_event, 0));

    var buffer: [8]u8 = undefined;
    const input = state.takeInput(&buffer);
    try std.testing.expectEqualStrings("abc", buffer[0..input.bytes]);
    try std.testing.expect(!input.stop);

    state.beginShutdown();
    try std.testing.expectEqual(WAIT_OBJECT_0, WaitForSingleObject(state.input_ready_event, 0));
    try std.testing.expect(state.takeInput(&buffer).stop);
}

test "ConPTY startup replaces detached daemon standard streams" {
    var attribute_storage: usize = 0;
    const startup_info = conptyStartupInfo(@ptrCast(&attribute_storage));

    try std.testing.expectEqual(@as(windows.DWORD, @sizeOf(StartupInfoEx)), startup_info.startup_info.cb);
    try std.testing.expect(startup_info.startup_info.dwFlags & windows.STARTF_USESTDHANDLES != 0);
    try std.testing.expectEqual(@as(?windows.HANDLE, null), startup_info.startup_info.hStdInput);
    try std.testing.expectEqual(@as(?windows.HANDLE, null), startup_info.startup_info.hStdOutput);
    try std.testing.expectEqual(@as(?windows.HANDLE, null), startup_info.startup_info.hStdError);
}
