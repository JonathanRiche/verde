//! Bounded local request/response transport for live-control protocols.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("platform_runtime");

const windows = std.os.windows;

pub const DEFAULT_MAX_MESSAGE_BYTES: usize = 256 * 1024;
pub const DEFAULT_MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
pub const DEFAULT_TIMEOUT_MS: u32 = 5000;
const WINDOWS_PIPE_BUFFER_BYTES: usize = 64 * 1024;
const RESPONSE_TOO_LARGE_RESPONSE = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":\"response_too_large\",\"message\":\"response exceeds transport limit\"}}";

pub const Options = struct {
    /// Maximum request size. Kept under the historical field name so existing
    /// callers continue to compile while responses use their own larger cap.
    max_message_bytes: usize = DEFAULT_MAX_MESSAGE_BYTES,
    max_response_bytes: usize = DEFAULT_MAX_RESPONSE_BYTES,
    timeout_ms: u32 = DEFAULT_TIMEOUT_MS,
};

/// A response plus the authenticated Windows server PID that produced it.
/// Unix transports authenticate through their filesystem endpoint and leave
/// `server_process_id` null.
pub const RequestResult = struct {
    response: []u8,
    server_process_id: ?u32 = null,
};

/// The callback takes ownership of `request` and returns an owned response.
pub const ServerCallbacks = struct {
    context: *anyopaque,
    should_stop: *const fn (context: *anyopaque) bool,
    handle_request: *const fn (context: *anyopaque, request: []u8) anyerror![]u8,
    /// Runs after the transport has acquired exclusive endpoint ownership.
    /// Servers use this to publish state and start lifetime-dependent workers.
    on_ready: ?*const fn (context: *anyopaque) anyerror!void = null,
    /// Runs after the accept loop exits but BEFORE endpoint teardown defers
    /// (socket unlink, listener close, exclusive lock release). Servers use
    /// this for transfer commit + store close so successor bind cannot race
    /// a pre-transfer snapshot. Invoked on both Unix and Windows serve paths.
    on_closing: ?*const fn (context: *anyopaque) void = null,
};

/// Serves newline-delimited messages until the callback requests shutdown.
pub fn serve(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    callbacks: ServerCallbacks,
    options: Options,
) !void {
    if (builtin.os.tag == .windows) return serveWindows(allocator, endpoint, callbacks, options);
    return serveUnix(allocator, endpoint, callbacks, options);
}

/// Sends one newline-delimited request and returns its response without CR/LF.
pub fn requestAlloc(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    request: []const u8,
    options: Options,
) ![]u8 {
    const result = try requestWithPeerAlloc(allocator, endpoint, request, options);
    return result.response;
}

/// Sends a request and returns the authenticated transport peer when the
/// platform exposes one. The caller owns `result.response`.
pub fn requestWithPeerAlloc(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    request: []const u8,
    options: Options,
) !RequestResult {
    if (request.len > options.max_message_bytes) return error.MessageTooLarge;
    if (builtin.os.tag == .windows) return requestWindowsAlloc(allocator, endpoint, request, options);
    return .{ .response = try requestUnixAlloc(allocator, endpoint, request, options) };
}

/// Wakes a listener so it can observe its shutdown flag.
pub fn wake(allocator: std.mem.Allocator, endpoint: []const u8, options: Options) void {
    if (builtin.os.tag == .windows) {
        const connection = openWindowsPipe(allocator, endpoint, options.timeout_ms) catch return;
        windows.CloseHandle(connection.handle);
        return;
    }

    var threaded = std.Io.Threaded.init_single_threaded;
    const address = std.Io.net.UnixAddress.init(endpoint) catch return;
    const stream = address.connect(threaded.io()) catch return;
    stream.close(threaded.io());
}

fn serveUnix(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    callbacks: ServerCallbacks,
    options: Options,
) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var endpoint_guard = try UnixEndpointGuard.acquire(allocator, io, endpoint);
    defer endpoint_guard.deinit();
    // The lock serializes the probe, reclaim, and bind with every Verde
    // server using this transport, closing the check/unlink/listen TOCTOU.
    try endpoint_guard.reclaimStaleEndpoint();

    const address = try std.Io.net.UnixAddress.init(endpoint);
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    endpoint_guard.claimListener();
    // The guard remains held while the listener is live. Re-checking the
    // claim before unlink prevents cleanup from deleting a replacement path.
    defer endpoint_guard.deleteIfOwned();

    // Transfer/store finalization must complete while this process still owns
    // the endpoint — on EVERY exit path, error returns included. Declared
    // after the teardown defers so LIFO runs it first: on_closing, then
    // deleteIfOwned (unlink socket), then listener.deinit, then endpoint_guard
    // deinit (releases exclusive lock).
    defer if (callbacks.on_closing) |on_closing| on_closing(callbacks.context);

    if (callbacks.on_ready) |on_ready| try on_ready(callbacks.context);

    while (!callbacks.should_stop(callbacks.context)) {
        const stream = listener.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => continue,
            else => return err,
        };
        handleUnixClient(allocator, io, stream, callbacks, options);
    }
}

fn handleUnixClient(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    callbacks: ServerCallbacks,
    options: Options,
) void {
    defer stream.close(io);
    const request = readUnixLineAlloc(
        allocator,
        io,
        stream,
        options.max_message_bytes,
        options.timeout_ms,
    ) catch return;
    const response = callbacks.handle_request(callbacks.context, request) catch return;
    defer allocator.free(response);
    const response_to_write = if (response.len <= options.max_response_bytes)
        response
    else
        RESPONSE_TOO_LARGE_RESPONSE;

    // Keep a stalled peer from holding the single-threaded accept loop hostage.
    const deadline = deadlineFromNow(options.timeout_ms);
    writeUnixAllWithDeadline(stream, response_to_write, deadline) catch return;
    writeUnixAllWithDeadline(stream, "\n", deadline) catch return;
}

fn writeUnixAllWithDeadline(stream: std.Io.net.Stream, bytes: []const u8, deadline: u64) !void {
    comptime if (builtin.os.tag == .windows) @compileError("Unix transport helper on Windows");

    var remaining = bytes;
    while (remaining.len > 0) {
        const remaining_ms = remainingTimeoutMs(deadline) orelse return error.ConnectionTimedOut;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stream.socket.handle,
            .events = std.posix.POLL.OUT,
            .revents = 0,
        }};
        const poll_timeout: i32 = @intCast(@min(remaining_ms, std.math.maxInt(i32)));
        const ready = try std.posix.poll(&poll_fds, poll_timeout);
        if (ready == 0) return error.ConnectionTimedOut;
        if (poll_fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            return error.ConnectionResetByPeer;
        }

        const written_raw = std.c.send(
            stream.socket.handle,
            remaining.ptr,
            remaining.len,
            std.posix.MSG.NOSIGNAL | std.posix.MSG.DONTWAIT,
        );
        if (written_raw < 0) switch (std.posix.errno(written_raw)) {
            .AGAIN, .INTR => continue,
            else => return error.ConnectionResetByPeer,
        };
        const written: usize = @intCast(written_raw);
        if (written == 0) return error.ConnectionResetByPeer;
        remaining = remaining[written..];
    }
}

fn readUnixLineAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    max_bytes: usize,
    timeout_ms: u32,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const deadline = deadlineFromNow(timeout_ms);
    var buffer: [4096]u8 = undefined;

    while (bytes.items.len <= max_bytes) {
        const remaining_ms = remainingTimeoutMs(deadline) orelse return error.ConnectionTimedOut;
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(remaining_ms),
            .clock = .awake,
        } };
        const message = try stream.socket.receiveTimeout(io, &buffer, timeout);
        if (message.data.len == 0) return error.ConnectionAborted;
        if (std.mem.indexOfScalar(u8, message.data, '\n')) |newline| {
            if (bytes.items.len + newline > max_bytes) return error.MessageTooLarge;
            try bytes.appendSlice(allocator, message.data[0..newline]);
            trimTrailingCarriageReturn(&bytes);
            return try bytes.toOwnedSlice(allocator);
        }
        if (bytes.items.len + message.data.len > max_bytes) return error.MessageTooLarge;
        try bytes.appendSlice(allocator, message.data);
    }
    return error.MessageTooLarge;
}

fn requestUnixAlloc(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    request: []const u8,
    options: Options,
) ![]u8 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const address = try std.Io.net.UnixAddress.init(endpoint);
    const stream = try address.connect(io);
    defer stream.close(io);

    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    return readUnixLineAlloc(allocator, io, stream, options.max_response_bytes, options.timeout_ms);
}

/// True when a peer can complete a connection to a Unix endpoint path.
/// Shared with the sessionizer live-endpoint bind guard so both refuse to
/// unlink/steal a pathname still accepted by another process.
pub fn unixEndpointAcceptsConnections(io: std.Io, endpoint: []const u8) bool {
    const address = std.Io.net.UnixAddress.init(endpoint) catch return false;
    const stream = address.connect(io) catch return false;
    stream.close(io);
    return true;
}

/// Holds an advisory lock beside a Unix endpoint for the complete reclaim and
/// listener lifetime. The lock file is intentionally persistent; its inode is
/// the cross-process coordination object, while the socket pathname is owned
/// only by the listener that successfully claimed it.
pub const UnixEndpointGuard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    lock_file: std.Io.File,
    listener_claimed: bool = false,

    pub fn acquire(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8) !UnixEndpointGuard {
        const lock_path = try unixEndpointLockPathAlloc(allocator, endpoint);
        defer allocator.free(lock_path);
        var lock_file = if (std.fs.path.isAbsolute(lock_path))
            std.Io.Dir.createFileAbsolute(io, lock_path, .{ .read = true, .lock = .exclusive, .lock_nonblocking = true }) catch |err|
                return switch (err) {
                    error.WouldBlock => error.EndpointInUse,
                    else => err,
                }
        else
            std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .lock = .exclusive, .lock_nonblocking = true }) catch |err|
                return switch (err) {
                    error.WouldBlock => error.EndpointInUse,
                    else => err,
                };
        errdefer lock_file.close(io);
        return .{
            .allocator = allocator,
            .io = io,
            .endpoint = endpoint,
            .lock_file = lock_file,
        };
    }

    pub fn reclaimStaleEndpoint(self: *UnixEndpointGuard) !void {
        // Do not unlink a live instance: existing hooks retain this pathname
        // and would otherwise be stranded on an anonymous listening descriptor.
        if (unixEndpointAcceptsConnections(self.io, self.endpoint)) return error.EndpointInUse;
        deleteUnixEndpoint(self.io, self.endpoint);
    }

    pub fn claimListener(self: *UnixEndpointGuard) void {
        self.listener_claimed = true;
    }

    pub fn deleteIfOwned(self: *UnixEndpointGuard) void {
        if (!self.listener_claimed) return;
        self.listener_claimed = false;
        // The exclusive lock is the ownership re-check: another compliant
        // daemon cannot reclaim or bind this pathname until this guard closes.
        deleteUnixEndpoint(self.io, self.endpoint);
    }

    pub fn deinit(self: *UnixEndpointGuard) void {
        self.deleteIfOwned();
        self.lock_file.close(self.io);
        self.* = undefined;
    }
};

fn unixEndpointLockPathAlloc(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.lock", .{endpoint});
}

fn deleteUnixEndpoint(io: std.Io, endpoint: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, endpoint) catch {};
}

fn serveWindows(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    callbacks: ServerCallbacks,
    options: Options,
) !void {
    const pipe = try createWindowsPipe(allocator, endpoint, options);
    defer windows.CloseHandle(pipe);
    // Mirror Unix: finalize on every exit path (error returns included)
    // before the deferred pipe CloseHandle runs (LIFO).
    defer if (callbacks.on_closing) |on_closing| on_closing(callbacks.context);

    if (callbacks.on_ready) |on_ready| try on_ready(callbacks.context);

    // Keep the FIRST_PIPE_INSTANCE handle for the server lifetime. A client can
    // retain its disconnected handle briefly, so closing and recreating this
    // instance between requests can make CreateNamedPipeW report ACCESS_DENIED.
    while (!callbacks.should_stop(callbacks.context)) {
        connectWindowsPipe(pipe, deadlineFromNow(options.timeout_ms)) catch |err| {
            // A cancelled overlapped connect must be reset before this handle
            // can listen for the next client.
            _ = DisconnectNamedPipe(pipe);
            switch (err) {
                error.ConnectionTimedOut => continue,
                else => return err,
            }
        };
        defer _ = DisconnectNamedPipe(pipe);
        if (callbacks.should_stop(callbacks.context)) break;

        const request = readWindowsLineAlloc(allocator, pipe, options) catch continue;
        const response = callbacks.handle_request(callbacks.context, request) catch continue;
        defer allocator.free(response);
        const response_to_write = if (response.len <= options.max_response_bytes)
            response
        else
            RESPONSE_TOO_LARGE_RESPONSE;

        const deadline = deadlineFromNow(options.timeout_ms);
        writeWindowsAll(pipe, response_to_write, deadline) catch continue;
        writeWindowsAll(pipe, "\n", deadline) catch continue;
        // DisconnectNamedPipe discards unread bytes. Wait until the client has
        // consumed the complete newline-delimited reply before the loop's
        // deferred disconnect makes this instance available again.
        _ = FlushFileBuffers(pipe);
    }
}

fn requestWindowsAlloc(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    request: []const u8,
    options: Options,
) !RequestResult {
    const connection = try openWindowsPipe(allocator, endpoint, options.timeout_ms);
    defer windows.CloseHandle(connection.handle);
    const deadline = deadlineFromNow(options.timeout_ms);
    try writeWindowsAll(connection.handle, request, deadline);
    try writeWindowsAll(connection.handle, "\n", deadline);
    return .{
        .response = try readWindowsLineAllocWithDeadline(allocator, connection.handle, options.max_response_bytes, deadline),
        .server_process_id = connection.server_process_id,
    };
}

fn createWindowsPipe(allocator: std.mem.Allocator, endpoint: []const u8, options: Options) !windows.HANDLE {
    const endpoint_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, endpoint);
    defer allocator.free(endpoint_w);
    var security = try PipeSecurity.init(allocator);
    defer security.deinit();

    const pipe = CreateNamedPipeW(
        endpoint_w,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1,
        @intCast(@min(options.max_response_bytes, WINDOWS_PIPE_BUFFER_BYTES)),
        @intCast(@min(options.max_message_bytes, WINDOWS_PIPE_BUFFER_BYTES)),
        options.timeout_ms,
        &security.attributes,
    );
    if (pipe == windows.INVALID_HANDLE_VALUE) return switch (windows.GetLastError()) {
        .ACCESS_DENIED => error.EndpointInUse,
        else => error.OpenFailed,
    };
    return pipe;
}

const WindowsPipeConnection = struct {
    handle: windows.HANDLE,
    server_process_id: u32,
};

fn openWindowsPipe(allocator: std.mem.Allocator, endpoint: []const u8, timeout_ms: u32) !WindowsPipeConnection {
    const endpoint_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, endpoint);
    defer allocator.free(endpoint_w);
    const deadline = deadlineFromNow(timeout_ms);

    while (true) {
        const pipe = CreateFileW(
            endpoint_w,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            WINDOWS_PIPE_CLIENT_FLAGS,
            null,
        );
        if (pipe != windows.INVALID_HANDLE_VALUE) {
            errdefer windows.CloseHandle(pipe);
            return .{
                .handle = pipe,
                .server_process_id = try authenticateWindowsPipeServer(allocator, pipe),
            };
        }

        switch (windows.GetLastError()) {
            .PIPE_BUSY => {
                const remaining = remainingTimeoutMs(deadline) orelse return error.ConnectionTimedOut;
                _ = WaitNamedPipeW(endpoint_w, @min(remaining, 100));
            },
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => return error.FileNotFound,
            .ACCESS_DENIED => return error.AccessDenied,
            else => return error.Unexpected,
        }
    }
}

/// Verifies the process behind a connected pipe belongs to this logon session.
/// The server ACL protects a legitimate listener from foreign clients, but it
/// cannot prevent a foreign process from pre-creating the predictable name.
fn authenticateWindowsPipeServer(allocator: std.mem.Allocator, pipe: windows.HANDLE) !u32 {
    var server_process_id: windows.DWORD = 0;
    if (!GetNamedPipeServerProcessId(pipe, &server_process_id).toBool() or server_process_id == 0) {
        return error.UntrustedServer;
    }

    const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, server_process_id) orelse
        return error.UntrustedServer;
    defer windows.CloseHandle(process);
    var token: windows.HANDLE = undefined;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token).toBool()) return error.UntrustedServer;
    defer windows.CloseHandle(token);

    const expected_logon_sid = try currentLogonSidStringAlloc(allocator);
    defer allocator.free(expected_logon_sid);
    const server_logon_sid = logonSidStringForTokenAlloc(allocator, token) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UntrustedServer,
    };
    defer allocator.free(server_logon_sid);
    if (!std.mem.eql(u8, expected_logon_sid, server_logon_sid)) return error.UntrustedServer;
    return server_process_id;
}

fn connectWindowsPipe(pipe: windows.HANDLE, deadline: u64) !void {
    var operation = try OverlappedOperation.init();
    defer operation.deinit();
    if (ConnectNamedPipe(pipe, &operation.overlapped).toBool()) return;
    switch (windows.GetLastError()) {
        .PIPE_CONNECTED => return,
        .IO_PENDING => try operation.wait(pipe, deadline, null),
        else => return error.ConnectionAborted,
    }
}

fn readWindowsLineAlloc(allocator: std.mem.Allocator, pipe: windows.HANDLE, options: Options) ![]u8 {
    return readWindowsLineAllocWithDeadline(allocator, pipe, options.max_message_bytes, deadlineFromNow(options.timeout_ms));
}

fn readWindowsLineAllocWithDeadline(
    allocator: std.mem.Allocator,
    pipe: windows.HANDLE,
    max_message_bytes: usize,
    deadline: u64,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [4096]u8 = undefined;

    while (bytes.items.len <= max_message_bytes) {
        const read_len = try readWindows(pipe, &buffer, deadline);
        if (read_len == 0) return error.ConnectionAborted;
        const chunk = buffer[0..read_len];
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline| {
            if (bytes.items.len + newline > max_message_bytes) return error.MessageTooLarge;
            try bytes.appendSlice(allocator, chunk[0..newline]);
            trimTrailingCarriageReturn(&bytes);
            return try bytes.toOwnedSlice(allocator);
        }
        if (bytes.items.len + chunk.len > max_message_bytes) return error.MessageTooLarge;
        try bytes.appendSlice(allocator, chunk);
    }
    return error.MessageTooLarge;
}

fn readWindows(pipe: windows.HANDLE, buffer: []u8, deadline: u64) !usize {
    var operation = try OverlappedOperation.init();
    defer operation.deinit();
    var read_len: windows.DWORD = 0;
    if (ReadFile(pipe, buffer.ptr, @intCast(buffer.len), &read_len, &operation.overlapped).toBool()) return read_len;
    switch (windows.GetLastError()) {
        .IO_PENDING => try operation.wait(pipe, deadline, &read_len),
        .BROKEN_PIPE, .NO_DATA => return error.ConnectionAborted,
        else => return error.ConnectionAborted,
    }
    return read_len;
}

fn writeWindowsAll(pipe: windows.HANDLE, bytes: []const u8, deadline: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var operation = try OverlappedOperation.init();
        defer operation.deinit();
        const chunk = bytes[offset..@min(bytes.len, offset + 64 * 1024)];
        var written: windows.DWORD = 0;
        if (!WriteFile(pipe, chunk.ptr, @intCast(chunk.len), &written, &operation.overlapped).toBool()) {
            switch (windows.GetLastError()) {
                .IO_PENDING => try operation.wait(pipe, deadline, &written),
                .BROKEN_PIPE, .NO_DATA => return error.ConnectionAborted,
                else => return error.ConnectionAborted,
            }
        }
        if (written == 0) return error.ConnectionAborted;
        offset += written;
    }
}

const Overlapped = extern struct {
    internal: windows.ULONG_PTR = 0,
    internal_high: windows.ULONG_PTR = 0,
    offset: windows.DWORD = 0,
    offset_high: windows.DWORD = 0,
    event: ?windows.HANDLE = null,
};

const OverlappedOperation = struct {
    event: windows.HANDLE,
    overlapped: Overlapped,

    fn init() !OverlappedOperation {
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
        return .{ .event = event, .overlapped = .{ .event = event } };
    }

    fn deinit(self: *OverlappedOperation) void {
        windows.CloseHandle(self.event);
    }

    fn wait(self: *OverlappedOperation, pipe: windows.HANDLE, deadline: u64, transferred: ?*windows.DWORD) !void {
        const remaining = remainingTimeoutMs(deadline) orelse {
            self.cancelAndDrain(pipe);
            return error.ConnectionTimedOut;
        };
        const result = WaitForSingleObject(self.event, remaining);
        if (result == WAIT_TIMEOUT) {
            self.cancelAndDrain(pipe);
            return error.ConnectionTimedOut;
        }
        if (result != WAIT_OBJECT_0) {
            self.cancelAndDrain(pipe);
            return error.ConnectionAborted;
        }

        var ignored: windows.DWORD = 0;
        if (!GetOverlappedResult(pipe, &self.overlapped, transferred orelse &ignored, .FALSE).toBool()) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .NO_DATA, .OPERATION_ABORTED => error.ConnectionAborted,
                else => error.Unexpected,
            };
        }
    }

    fn cancelAndDrain(self: *OverlappedOperation, pipe: windows.HANDLE) void {
        _ = CancelIoEx(pipe, &self.overlapped);
        _ = WaitForSingleObject(self.event, INFINITE);
    }
};

const PipeSecurity = struct {
    descriptor: *anyopaque,
    attributes: windows.SECURITY_ATTRIBUTES,

    fn init(allocator: std.mem.Allocator) !PipeSecurity {
        const logon_sid = try currentLogonSidStringAlloc(allocator);
        defer allocator.free(logon_sid);
        const sddl = try std.fmt.allocPrint(allocator, PIPE_SDDL_FORMAT, .{logon_sid});
        defer allocator.free(sddl);
        const sddl_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, sddl);
        defer allocator.free(sddl_w);

        var descriptor: ?*anyopaque = null;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w,
            SDDL_REVISION_1,
            &descriptor,
            null,
        ).toBool()) return error.SecurityDescriptorFailed;
        const non_null = descriptor orelse return error.SecurityDescriptorFailed;
        return .{
            .descriptor = non_null,
            .attributes = .{
                .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
                .lpSecurityDescriptor = non_null,
                .bInheritHandle = .FALSE,
            },
        };
    }

    fn deinit(self: *PipeSecurity) void {
        _ = LocalFree(self.descriptor);
    }
};

const SidAndAttributes = extern struct {
    sid: *anyopaque,
    attributes: windows.DWORD,
};

const TokenGroups = extern struct {
    group_count: windows.DWORD,
    groups: [1]SidAndAttributes,
};

fn currentLogonSidStringAlloc(allocator: std.mem.Allocator) ![]u8 {
    comptime std.debug.assert(builtin.os.tag == .windows);

    var token: windows.HANDLE = undefined;
    if (!OpenProcessToken(windows.GetCurrentProcess(), TOKEN_QUERY, &token).toBool()) {
        return error.SecurityDescriptorFailed;
    }
    defer windows.CloseHandle(token);

    return logonSidStringForTokenAlloc(allocator, token);
}

fn logonSidStringForTokenAlloc(allocator: std.mem.Allocator, token: windows.HANDLE) ![]u8 {
    comptime std.debug.assert(builtin.os.tag == .windows);

    var required_bytes: windows.DWORD = 0;
    _ = GetTokenInformation(token, TOKEN_GROUPS_INFORMATION_CLASS, null, 0, &required_bytes);
    if (required_bytes < @offsetOf(TokenGroups, "groups") + @sizeOf(SidAndAttributes)) {
        return error.SecurityDescriptorFailed;
    }

    // usize storage supplies native pointer alignment for TOKEN_GROUPS while
    // still allowing the variable-length Win32 result to be treated as bytes.
    const word_count = (required_bytes + @sizeOf(usize) - 1) / @sizeOf(usize);
    const storage = try allocator.alloc(usize, word_count);
    defer allocator.free(storage);
    const storage_bytes = std.mem.sliceAsBytes(storage);
    if (!GetTokenInformation(
        token,
        TOKEN_GROUPS_INFORMATION_CLASS,
        storage_bytes.ptr,
        @intCast(storage_bytes.len),
        &required_bytes,
    ).toBool()) return error.SecurityDescriptorFailed;

    const token_groups: *const TokenGroups = @ptrCast(storage.ptr);
    const groups_offset = @offsetOf(TokenGroups, "groups");
    const max_group_count = (storage_bytes.len - groups_offset) / @sizeOf(SidAndAttributes);
    if (token_groups.group_count > max_group_count) return error.SecurityDescriptorFailed;
    const groups: [*]const SidAndAttributes = @ptrCast(&token_groups.groups);
    for (groups[0..token_groups.group_count]) |group| {
        if (group.attributes & SE_GROUP_LOGON_ID != SE_GROUP_LOGON_ID) continue;

        var sid_w: ?[*:0]u16 = null;
        if (!ConvertSidToStringSidW(group.sid, &sid_w).toBool()) {
            return error.SecurityDescriptorFailed;
        }
        defer _ = LocalFree(@ptrCast(sid_w.?));
        return try std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(sid_w.?));
    }
    return error.SecurityDescriptorFailed;
}

// Microsoft recommends a logon SID for named pipes so another user or terminal
// session cannot connect. LocalSystem retains access for OS-level diagnostics.
const PIPE_SDDL_FORMAT = "D:P(A;;GA;;;{s})(A;;GA;;;SY)";
const SDDL_REVISION_1: windows.DWORD = 1;
const TOKEN_QUERY: windows.DWORD = 0x0008;
const TOKEN_GROUPS_INFORMATION_CLASS: c_int = 2;
const SE_GROUP_LOGON_ID: windows.DWORD = 0xc0000000;
const PIPE_ACCESS_DUPLEX: windows.DWORD = 0x00000003;
const FILE_FLAG_FIRST_PIPE_INSTANCE: windows.DWORD = 0x00080000;
const FILE_FLAG_OVERLAPPED: windows.DWORD = 0x40000000;
const PIPE_TYPE_BYTE: windows.DWORD = 0x00000000;
const PIPE_READMODE_BYTE: windows.DWORD = 0x00000000;
const PIPE_WAIT: windows.DWORD = 0x00000000;
const PIPE_REJECT_REMOTE_CLIENTS: windows.DWORD = 0x00000008;
const GENERIC_READ: windows.DWORD = 0x80000000;
const GENERIC_WRITE: windows.DWORD = 0x40000000;
const OPEN_EXISTING: windows.DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x00000080;
const SECURITY_IDENTIFICATION: windows.DWORD = 0x00010000;
const SECURITY_SQOS_PRESENT: windows.DWORD = 0x00100000;
const WINDOWS_PIPE_CLIENT_FLAGS = FILE_ATTRIBUTE_NORMAL |
    FILE_FLAG_OVERLAPPED |
    SECURITY_SQOS_PRESENT |
    SECURITY_IDENTIFICATION;
const PROCESS_QUERY_LIMITED_INFORMATION: windows.DWORD = 0x1000;
const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 258;
const INFINITE: windows.DWORD = 0xffffffff;

fn deadlineFromNow(timeout_ms: u32) u64 {
    return monotonicMilliseconds() + timeout_ms;
}

fn remainingTimeoutMs(deadline: u64) ?u32 {
    const now = monotonicMilliseconds();
    if (now >= deadline) return null;
    return @intCast(@min(deadline - now, std.math.maxInt(u32) - 1));
}

fn monotonicMilliseconds() u64 {
    return runtime.monotonicTimestampNs() / std.time.ns_per_ms;
}

fn trimTrailingCarriageReturn(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len > 0 and bytes.items[bytes.items.len - 1] == '\r') bytes.items.len -= 1;
}

extern "kernel32" fn CreateEventW(
    event_attributes: ?*windows.SECURITY_ATTRIBUTES,
    manual_reset: windows.BOOL,
    initial_state: windows.BOOL,
    name: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn GetOverlappedResult(
    file: windows.HANDLE,
    overlapped: *Overlapped,
    transferred: *windows.DWORD,
    wait: windows.BOOL,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CancelIoEx(file: windows.HANDLE, overlapped: ?*Overlapped) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateNamedPipeW(
    name: windows.LPCWSTR,
    open_mode: windows.DWORD,
    pipe_mode: windows.DWORD,
    max_instances: windows.DWORD,
    output_buffer_size: windows.DWORD,
    input_buffer_size: windows.DWORD,
    default_timeout_ms: windows.DWORD,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ConnectNamedPipe(pipe: windows.HANDLE, overlapped: ?*Overlapped) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn FlushFileBuffers(file: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(
    pipe: windows.HANDLE,
    server_process_id: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateFileW(
    name: windows.LPCWSTR,
    desired_access: windows.DWORD,
    share_mode: windows.DWORD,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
    creation_disposition: windows.DWORD,
    flags_and_attributes: windows.DWORD,
    template_file: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitNamedPipeW(name: windows.LPCWSTR, timeout_ms: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: windows.DWORD,
    bytes_read: *windows.DWORD,
    overlapped: ?*Overlapped,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: windows.DWORD,
    bytes_written: *windows.DWORD,
    overlapped: ?*Overlapped,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn LocalFree(memory: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(
    process: windows.HANDLE,
    desired_access: windows.DWORD,
    token: *windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: c_int,
    information: ?*anyopaque,
    information_length: windows.DWORD,
    return_length: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertSidToStringSidW(
    sid: *anyopaque,
    string_sid: *?[*:0]u16,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string_security_descriptor: windows.LPCWSTR,
    string_revision: windows.DWORD,
    security_descriptor: *?*anyopaque,
    security_descriptor_size: ?*windows.ULONG,
) callconv(.winapi) windows.BOOL;

test "pipe security descriptor excludes broad principals" {
    try std.testing.expect(std.mem.indexOf(u8, PIPE_SDDL_FORMAT, ";;;WD") == null);
    try std.testing.expect(std.mem.indexOf(u8, PIPE_SDDL_FORMAT, ";;;AN") == null);
    try std.testing.expect(std.mem.indexOf(u8, PIPE_SDDL_FORMAT, ";;;OW") == null);
    try std.testing.expect(std.mem.indexOf(u8, PIPE_SDDL_FORMAT, ";;;{s}") != null);
    try std.testing.expect(std.mem.indexOf(u8, PIPE_SDDL_FORMAT, ";;;SY") != null);
}

test "named pipe clients prevent server impersonation" {
    try std.testing.expect(WINDOWS_PIPE_CLIENT_FLAGS & SECURITY_SQOS_PRESENT != 0);
    try std.testing.expect(WINDOWS_PIPE_CLIENT_FLAGS & SECURITY_IDENTIFICATION != 0);
}

test "unix endpoint guard derives a neighboring lock path" {
    const allocator = std.testing.allocator;
    const lock_path = try unixEndpointLockPathAlloc(allocator, "/tmp/verde-sessionizer.sock");
    defer allocator.free(lock_path);
    try std.testing.expectEqualStrings("/tmp/verde-sessionizer.sock.lock", lock_path);
}

test "message limits are release invariant" {
    try std.testing.expect(DEFAULT_MAX_MESSAGE_BYTES >= 64 * 1024);
    try std.testing.expect(DEFAULT_MAX_MESSAGE_BYTES <= 1024 * 1024);
    try std.testing.expect(DEFAULT_MAX_RESPONSE_BYTES > DEFAULT_MAX_MESSAGE_BYTES);
    try std.testing.expect(DEFAULT_MAX_RESPONSE_BYTES <= 32 * 1024 * 1024);
    try std.testing.expect(WINDOWS_PIPE_BUFFER_BYTES <= DEFAULT_MAX_MESSAGE_BYTES);
    try std.testing.expect(DEFAULT_TIMEOUT_MS > 0);
}

// Pins the handoff barrier: on_closing runs while the socket path still
// accepts connections and before serve's LIFO endpoint teardown defers.
// Use a short absolute path: AF_UNIX sun_path is ~108 bytes on Linux.
test "on_closing runs before unix endpoint teardown" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    // /tmp/verde-oc-{pid}.sock stays well under the Unix path length limit.
    const endpoint = try std.fmt.allocPrint(allocator, "/tmp/verde-oc-{d}.sock", .{runtime.processId()});
    defer allocator.free(endpoint);
    defer {
        var cleanup_threaded = std.Io.Threaded.init_single_threaded;
        const cleanup_io = cleanup_threaded.io();
        std.Io.Dir.deleteFileAbsolute(cleanup_io, endpoint) catch {};
        if (std.fmt.allocPrint(allocator, "{s}.lock", .{endpoint})) |lock_path| {
            defer allocator.free(lock_path);
            std.Io.Dir.deleteFileAbsolute(cleanup_io, lock_path) catch {};
        } else |_| {}
    }

    const State = struct {
        stop: bool = false,
        closing_ran: bool = false,
        endpoint_alive_at_closing: bool = false,
        endpoint: []const u8 = "",
    };
    var state: State = .{ .endpoint = endpoint };

    const should_stop = struct {
        fn call(ctx: *anyopaque) bool {
            const s: *State = @ptrCast(@alignCast(ctx));
            return s.stop;
        }
    }.call;
    const handle = struct {
        fn call(ctx: *anyopaque, request: []u8) anyerror![]u8 {
            _ = ctx;
            _ = request;
            return error.UnexpectedRequest;
        }
    }.call;
    const on_ready = struct {
        fn call(ctx: *anyopaque) anyerror!void {
            const s: *State = @ptrCast(@alignCast(ctx));
            // Exit the accept loop on the next should_stop check.
            s.stop = true;
        }
    }.call;
    const on_closing = struct {
        fn call(ctx: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ctx));
            s.closing_ran = true;
            var threaded = std.Io.Threaded.init_single_threaded;
            s.endpoint_alive_at_closing = unixEndpointAcceptsConnections(threaded.io(), s.endpoint);
        }
    }.call;

    try serve(allocator, endpoint, .{
        .context = &state,
        .should_stop = should_stop,
        .handle_request = handle,
        .on_ready = on_ready,
        .on_closing = on_closing,
    }, .{
        .timeout_ms = 500,
    });

    try std.testing.expect(state.closing_ran);
    try std.testing.expect(state.endpoint_alive_at_closing);
    // After serve returns, LIFO defers have unlinked the socket.
    var threaded = std.Io.Threaded.init_single_threaded;
    try std.testing.expect(!unixEndpointAcceptsConnections(threaded.io(), endpoint));
}
