//! Wayland wire protocol: connection, object table, marshalling and fd passing.
//!
//! Messages are `[object id: u32][size << 16 | opcode: u32][args...]`, native endian, every
//! argument padded to 4 bytes. File descriptors travel out-of-band as SCM_RIGHTS ancillary data
//! and are matched to messages in order.
//!
//! Requests are encoded straight into a fixed send buffer (`request`); generated bindings call
//! it with a typed argument tuple which is checked against the protocol signature at compile
//! time. Incoming bytes land in a fixed receive buffer; `nextMessage` yields one complete
//! message at a time (zero copy) with its fds already split off, after handling the
//! `wl_display` events (error, delete_id) and registering server-created objects. Typed events
//! are decoded with `Message.decode`, a comptime-generated parser driven by the `Event` union
//! the scanner emits. Nothing here allocates in steady state; the object table grows only when
//! more objects are alive than ever before.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const proto = @import("wayland_protocol");

pub const Fixed = proto.Fixed;
pub const Fd = proto.Fd;
pub const Array = proto.Array;
pub const InterfaceId = proto.InterfaceId;

const log = std.log.scoped(.wayland);

pub const Error = error{
    ConnectionClosed,
    ProtocolError,
    InvalidMessage,
    MessageTooLarge,
    UnsupportedVersion,
    TooManyFds,
    Timeout,
    OutOfMemory,
    SystemResources,
    Unexpected,
};

/// Hard limit of a single message (libwayland uses 4096 for the default connection buffer).
pub const max_message_size = 4096;
/// libwayland's per-sendmsg fd cap (MAX_FDS_OUT).
pub const max_fds_out = 28;
const max_fds_in = 64;
/// Largest number of fds a single event may carry in any protocol we use.
pub const max_fds_per_message = 4;
const out_capacity = 16 * 1024;
const in_capacity = 32 * 1024;

pub const display_id: u32 = 1;
pub const server_id_base: u32 = 0xff000000;

pub const ObjectState = enum(u8) { free, live, zombie };

pub const Object = struct {
    iface: InterfaceId = .wl_display,
    state: ObjectState = .free,
    version: u32 = 0,
    /// Owner-defined tag (e.g. a window slot) so dispatch can route without searching.
    data: u32 = 0,
};

/// Fatal `wl_display.error` details, kept for diagnostics.
pub const DisplayError = struct {
    object_id: u32,
    interface: []const u8,
    code: u32,
    message_buf: [256]u8 = undefined,
    message_len: usize = 0,

    pub fn message(e: *const DisplayError) []const u8 {
        return e.message_buf[0..e.message_len];
    }
};

/// One received message. Its payload aliases the receive buffer and is valid until the next
/// call to `nextMessage`/`read`. fds not taken by `decode` are closed by `deinit`.
pub const Message = struct {
    object: u32,
    iface: InterfaceId,
    opcode: u16,
    /// User data attached to the receiving object.
    data: u32,
    payload: []align(4) const u8,
    fds: [max_fds_per_message]i32 = .{ -1, -1, -1, -1 },
    conn: *Connection,

    pub fn deinit(m: *Message) void {
        for (&m.fds) |*fd| if (fd.* >= 0) {
            _ = linux.close(fd.*);
            fd.* = -1;
        };
    }

    /// Decodes into the typed `T.Event` union. String/array fields alias the payload.
    pub fn decode(m: *Message, comptime T: type) Error!T.Event {
        const E = T.Event;
        if (m.iface != T.interface_id) return error.InvalidMessage;
        var r: Reader = .{ .buf = m.payload };
        var fd_index: usize = 0;
        inline for (@typeInfo(E).@"union".fields, 0..) |field, opcode| {
            if (m.opcode == opcode) {
                var payload: field.type = undefined;
                inline for (@typeInfo(field.type).@"struct".fields) |f| {
                    @field(payload, f.name) = try r.read(f.type, m, &fd_index);
                }
                return @unionInit(E, field.name, payload);
            }
        }
        return error.InvalidMessage;
    }
};

const Reader = struct {
    buf: []align(4) const u8,
    pos: usize = 0,

    fn word(r: *Reader) Error!u32 {
        if (r.pos + 4 > r.buf.len) return error.InvalidMessage;
        const v = std.mem.readInt(u32, r.buf[r.pos..][0..4], builtin.cpu.arch.endian());
        r.pos += 4;
        return v;
    }

    fn bytes(r: *Reader) Error![]const u8 {
        const len = try r.word();
        const padded = std.mem.alignForward(usize, len, 4);
        if (r.pos + padded > r.buf.len) return error.InvalidMessage;
        const s = r.buf[r.pos..][0..len];
        r.pos += padded;
        return s;
    }

    fn string(r: *Reader) Error!?[:0]const u8 {
        const s = try r.bytes();
        if (s.len == 0) return null;
        if (s[s.len - 1] != 0) return error.InvalidMessage;
        return s[0 .. s.len - 1 :0];
    }

    fn read(r: *Reader, comptime T: type, m: *Message, fd_index: *usize) Error!T {
        if (T == u32) return r.word();
        if (T == i32) return @bitCast(try r.word());
        if (T == Fixed) return @enumFromInt(@as(i32, @bitCast(try r.word())));
        if (T == Fd) {
            if (fd_index.* >= max_fds_per_message) return error.InvalidMessage;
            const fd = m.fds[fd_index.*];
            if (fd < 0) return error.InvalidMessage;
            m.fds[fd_index.*] = -1; // ownership moves to the handler
            fd_index.* += 1;
            return @enumFromInt(fd);
        }
        if (T == Array) return .{ .data = try r.bytes() };
        if (T == [:0]const u8) return (try r.string()) orelse error.InvalidMessage;
        if (T == ?[:0]const u8) return r.string();
        switch (@typeInfo(T)) {
            .@"enum" => return @enumFromInt(try r.word()),
            .optional => |o| {
                const v = try r.word();
                return if (v == 0) null else @as(o.child, @enumFromInt(v));
            },
            else => @compileError("unsupported event arg type " ++ @typeName(T)),
        }
    }
};

fn isObjectType(comptime T: type) bool {
    return @typeInfo(T) == .@"enum" and @hasDecl(T, "interface_id");
}

/// Wire size of one request argument.
fn argSize(arg: anytype) usize {
    const T = @TypeOf(arg);
    if (T == Array) return 4 + std.mem.alignForward(usize, arg.data.len, 4);
    if (T == Fd) return 0; // travels as SCM_RIGHTS ancillary data
    switch (@typeInfo(T)) {
        .optional => return if (arg) |v| argSize(v) else 4,
        .pointer => {
            const s: []const u8 = arg;
            return 4 + std.mem.alignForward(usize, s.len + 1, 4);
        },
        else => return 4,
    }
}

fn countFds(comptime Args: type) usize {
    var n: usize = 0;
    for (@typeInfo(Args).@"struct".fields) |f| {
        if (f.type == Fd) n += 1;
    }
    return n;
}

/// Number of wire arguments in a signature (ignores '?').
fn sigLen(comptime sig: []const u8) usize {
    var n: usize = 0;
    for (sig) |c| {
        if (c != '?') n += 1;
    }
    return n;
}

pub const Connection = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    debug: bool = false,

    out: [out_capacity]u8 align(4) = undefined,
    out_len: usize = 0,
    out_fds: [max_fds_out]i32 = undefined,
    out_fd_len: usize = 0,

    in: [in_capacity]u8 align(4) = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    in_fds: [max_fds_in]i32 = undefined,
    in_fd_head: usize = 0,
    in_fd_len: usize = 0,

    /// Client-allocated ids: index = id - 1.
    objects: std.ArrayList(Object) = .empty,
    free_ids: std.ArrayList(u32) = .empty,
    /// Server-allocated ids: index = id - server_id_base.
    server_objects: std.ArrayList(Object) = .empty,

    display_error: ?DisplayError = null,
    closed: bool = false,

    /// Connects using WAYLAND_SOCKET (inherited fd) or $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY.
    pub fn connect(gpa: std.mem.Allocator, env: Env) !*Connection {
        if (env.get("WAYLAND_SOCKET")) |s| {
            const fd = std.fmt.parseInt(i32, s, 10) catch return error.InvalidWaylandSocket;
            // Inherited fds are not CLOEXEC; fix that.
            _ = linux.fcntl(fd, linux.F.SETFD, linux.FD_CLOEXEC);
            return fromFd(gpa, fd, env);
        }
        const display_name = env.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        var path_len: usize = 0;
        if (display_name.len > 0 and display_name[0] == '/') {
            if (display_name.len >= addr.path.len) return error.NameTooLong;
            @memcpy(addr.path[0..display_name.len], display_name);
            path_len = display_name.len;
        } else {
            const dir = env.get("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
            if (dir.len + 1 + display_name.len >= addr.path.len) return error.NameTooLong;
            @memcpy(addr.path[0..dir.len], dir);
            addr.path[dir.len] = '/';
            @memcpy(addr.path[dir.len + 1 ..][0..display_name.len], display_name);
            path_len = dir.len + 1 + display_name.len;
        }
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path_len + 1);
        while (true) {
            const crc = linux.connect(fd, &addr, len);
            switch (linux.errno(crc)) {
                .SUCCESS => break,
                .INTR => continue,
                .AGAIN, .INPROGRESS => {
                    // Unix sockets connect synchronously unless the backlog is full; wait.
                    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&pfd, 1, 1000);
                    break;
                },
                else => return error.ConnectionRefused,
            }
        }
        return fromFd(gpa, fd, env);
    }

    /// Wraps an already-connected socket (takes ownership).
    pub fn fromFd(gpa: std.mem.Allocator, fd: i32, env: Env) !*Connection {
        // Make sure the socket is non-blocking (WAYLAND_SOCKET / socketpair in tests).
        const fl = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(linux.O, "NONBLOCK")));
        const c = try gpa.create(Connection);
        c.* = .{ .gpa = gpa, .fd = fd };
        c.debug = if (env.get("PALETTE_WAYLAND_DEBUG")) |v| v.len > 0 and v[0] != '0' else false;
        // id 1 is wl_display.
        try c.objects.append(gpa, .{ .iface = .wl_display, .state = .live, .version = 1 });
        return c;
    }

    pub fn deinit(c: *Connection) void {
        for (c.out_fds[0..c.out_fd_len]) |fd| _ = linux.close(fd);
        while (c.in_fd_len > 0) _ = linux.close(c.popFd());
        _ = linux.close(c.fd);
        c.objects.deinit(c.gpa);
        c.free_ids.deinit(c.gpa);
        c.server_objects.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    pub fn display(_: *Connection) proto.WlDisplay {
        return @enumFromInt(display_id);
    }

    // -- object table ---------------------------------------------------------------------

    pub fn lookup(c: *Connection, id: u32) ?*Object {
        if (id == 0) return null;
        if (id >= server_id_base) {
            const i = id - server_id_base;
            return if (i < c.server_objects.items.len) &c.server_objects.items[i] else null;
        }
        return if (id - 1 < c.objects.items.len) &c.objects.items[id - 1] else null;
    }

    /// Allocates a client id for a new object of type `T` (generated bindings call this).
    pub fn newObject(c: *Connection, comptime T: type, version: u32) Error!T {
        const obj: Object = .{ .iface = T.interface_id, .state = .live, .version = version };
        if (c.free_ids.pop()) |id| {
            c.objects.items[id - 1] = obj;
            return @enumFromInt(id);
        }
        try c.objects.append(c.gpa, obj);
        return @enumFromInt(@as(u32, @intCast(c.objects.items.len)));
    }

    pub fn objectVersion(c: *Connection, obj: anytype) u32 {
        return if (c.lookup(@intFromEnum(obj))) |o| o.version else 0;
    }

    pub fn setData(c: *Connection, obj: anytype, data: u32) void {
        if (c.lookup(@intFromEnum(obj))) |o| o.data = data;
    }

    fn registerServerObject(c: *Connection, id: u32, iface: InterfaceId, version: u32) Error!void {
        if (id < server_id_base) return error.InvalidMessage;
        const i = id - server_id_base;
        while (c.server_objects.items.len <= i) try c.server_objects.append(c.gpa, .{});
        c.server_objects.items[i] = .{ .iface = iface, .state = .live, .version = version };
    }

    fn deleteId(c: *Connection, id: u32) void {
        const o = c.lookup(id) orelse return;
        o.* = .{};
        if (id < server_id_base) c.free_ids.append(c.gpa, id) catch {}; // leak the id on OOM
    }

    // -- sending ------------------------------------------------------------------------

    /// Encodes one request. `args` must match the protocol signature (checked at comptime).
    /// fd arguments are duplicated, so the caller keeps ownership of its fds.
    pub fn request(c: *Connection, obj: anytype, comptime opcode: u16, args: anytype) Error!void {
        const T = @TypeOf(obj);
        const msg = comptime T.interface.requests[opcode];
        comptime {
            const n = @typeInfo(@TypeOf(args)).@"struct".fields.len;
            if (n != sigLen(msg.signature))
                @compileError("argument count mismatch for " ++ T.interface_name ++ "." ++ msg.name);
        }
        if (c.closed) return error.ConnectionClosed;
        const id = @intFromEnum(obj);
        const o = c.lookup(id) orelse return error.InvalidMessage;
        if (o.state != .live) return error.InvalidMessage;
        if (o.version < msg.since) {
            log.err("{s}.{s} needs version {d}, object has {d}", .{ T.interface_name, msg.name, msg.since, o.version });
            return error.UnsupportedVersion;
        }

        var size: usize = 8;
        inline for (args) |a| size += argSize(a);
        if (size > max_message_size) return error.MessageTooLarge;
        const nfds = comptime countFds(@TypeOf(args));
        if (c.out_len + size > c.out.len or c.out_fd_len + nfds > max_fds_out) try c.flush();

        const start = c.out_len;
        c.putWord(id);
        c.putWord(@as(u32, @intCast(size)) << 16 | opcode);
        inline for (args) |a| try c.putArg(a);
        std.debug.assert(c.out_len - start == size);

        if (c.debug) logMessage("->", T.interface_name, id, msg, @alignCast(c.out[start + 8 .. c.out_len]));
        if (msg.destructor) o.state = .zombie;
    }

    fn putWord(c: *Connection, v: u32) void {
        std.mem.writeInt(u32, c.out[c.out_len..][0..4], v, builtin.cpu.arch.endian());
        c.out_len += 4;
    }

    fn putBytes(c: *Connection, bytes: []const u8, nul: bool) void {
        const len = bytes.len + @intFromBool(nul);
        c.putWord(@intCast(len));
        @memcpy(c.out[c.out_len..][0..bytes.len], bytes);
        const padded = std.mem.alignForward(usize, len, 4);
        @memset(c.out[c.out_len + bytes.len .. c.out_len + padded], 0);
        c.out_len += padded;
    }

    fn putArg(c: *Connection, a: anytype) Error!void {
        const A = @TypeOf(a);
        if (A == u32 or A == comptime_int) return c.putWord(a);
        if (A == i32) return c.putWord(@bitCast(a));
        if (A == Fixed) return c.putWord(@bitCast(@intFromEnum(a)));
        if (A == Array) return c.putBytes(a.data, false);
        if (A == Fd) {
            const rc = linux.fcntl(@intFromEnum(a), linux.F.DUPFD_CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
            c.out_fds[c.out_fd_len] = @intCast(rc);
            c.out_fd_len += 1;
            return;
        }
        switch (@typeInfo(A)) {
            .@"enum" => c.putWord(@bitCast(@as(u32, @truncate(@as(u64, @bitCast(@as(i64, @intFromEnum(a)))))))),
            .optional => if (a) |v| try c.putArg(v) else c.putWord(0),
            .pointer => c.putBytes(a, true),
            else => @compileError("unsupported request arg type " ++ @typeName(A)),
        }
    }

    pub fn hasPendingOutput(c: *const Connection) bool {
        return c.out_len > 0;
    }

    /// Sends buffered requests, waiting (poll POLLOUT) while the socket is full.
    pub fn flush(c: *Connection) Error!void {
        while (c.out_len > 0) {
            if (try c.trySend()) continue;
            var pfd = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, 5000);
            if (linux.errno(rc) == .INTR) continue;
            if (rc == 0) return error.Timeout;
            if (pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) return c.fail(error.ConnectionClosed);
        }
    }

    /// One non-blocking sendmsg. Returns false if the socket would block.
    pub fn trySend(c: *Connection) Error!bool {
        if (c.out_len == 0) return true;
        var iov = [1]std.posix.iovec_const{.{ .base = &c.out, .len = c.out_len }};
        var cmsg_buf: [cmsgSpace(max_fds_out * 4)]u8 align(8) = undefined;
        var msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        if (c.out_fd_len > 0) {
            const data_len = c.out_fd_len * 4;
            const hdr: *linux.cmsghdr = @ptrCast(&cmsg_buf);
            hdr.* = .{ .len = cmsgLen(data_len), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
            @memcpy(cmsg_buf[@sizeOf(linux.cmsghdr)..][0..data_len], std.mem.sliceAsBytes(c.out_fds[0..c.out_fd_len]));
            msg.control = &cmsg_buf;
            msg.controllen = cmsgSpace(data_len);
        }
        const rc = linux.sendmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return false,
            .INTR => return true,
            .PIPE, .CONNRESET => return c.fail(error.ConnectionClosed),
            else => return c.fail(error.Unexpected),
        }
        // fds are attached to the first byte sent; once accepted they are the kernel's.
        for (c.out_fds[0..c.out_fd_len]) |fd| _ = linux.close(fd);
        c.out_fd_len = 0;
        const sent: usize = rc;
        std.mem.copyForwards(u8, c.out[0 .. c.out_len - sent], c.out[sent..c.out_len]);
        c.out_len -= sent;
        return true;
    }

    fn fail(c: *Connection, err: Error) Error {
        c.closed = true;
        return err;
    }

    // -- receiving ------------------------------------------------------------------------

    fn popFd(c: *Connection) i32 {
        const fd = c.in_fds[c.in_fd_head];
        c.in_fd_head = (c.in_fd_head + 1) % max_fds_in;
        c.in_fd_len -= 1;
        return fd;
    }

    /// One non-blocking recvmsg into the receive buffer. Returns bytes read (0 = would block
    /// or buffer full).
    pub fn read(c: *Connection) Error!usize {
        if (c.closed) return error.ConnectionClosed;
        if (c.in_start > 0) {
            const n = c.in_end - c.in_start;
            std.mem.copyForwards(u8, c.in[0..n], c.in[c.in_start..c.in_end]);
            c.in_start = 0;
            c.in_end = n;
        }
        if (c.in_end == c.in.len) return 0;
        var iov = [1]std.posix.iovec{.{ .base = c.in[c.in_end..].ptr, .len = c.in.len - c.in_end }};
        var cmsg_buf: [cmsgSpace(max_fds_out * 4)]u8 align(8) = undefined;
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = cmsg_buf.len,
            .flags = 0,
        };
        const rc = while (true) {
            const r = linux.recvmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(r)) {
                .SUCCESS => break r,
                .INTR => continue,
                .AGAIN => return 0,
                else => return c.fail(error.ConnectionClosed),
            }
        };
        // Collect fds from every SCM_RIGHTS control message.
        var off: usize = 0;
        while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
            const hdr: *align(1) const linux.cmsghdr = @ptrCast(&cmsg_buf[off]);
            if (hdr.len < @sizeOf(linux.cmsghdr)) break;
            if (hdr.level == linux.SOL.SOCKET and hdr.type == linux.SCM.RIGHTS) {
                const n = (hdr.len - @sizeOf(linux.cmsghdr)) / 4;
                const fds: [*]align(1) const i32 = @ptrCast(&cmsg_buf[off + @sizeOf(linux.cmsghdr)]);
                for (fds[0..n]) |fd| {
                    if (c.in_fd_len == max_fds_in) {
                        _ = linux.close(fd);
                        return c.fail(error.TooManyFds);
                    }
                    c.in_fds[(c.in_fd_head + c.in_fd_len) % max_fds_in] = fd;
                    c.in_fd_len += 1;
                }
            }
            off += std.mem.alignForward(usize, hdr.len, @sizeOf(usize));
        }
        if (msg.flags & linux.MSG.CTRUNC != 0) return c.fail(error.TooManyFds);
        if (rc == 0) return c.fail(error.ConnectionClosed);
        c.in_end += rc;
        return rc;
    }

    /// Returns the next complete message for the application, or null if more bytes are
    /// needed. wl_display events and messages to destroyed objects are handled internally.
    pub fn nextMessage(c: *Connection) Error!?Message {
        while (true) {
            const avail = c.in_end - c.in_start;
            if (avail < 8) return null;
            const head: *align(4) const [8]u8 = @alignCast(c.in[c.in_start..][0..8]);
            const id = std.mem.readInt(u32, head[0..4], builtin.cpu.arch.endian());
            const word2 = std.mem.readInt(u32, head[4..8], builtin.cpu.arch.endian());
            const size: usize = word2 >> 16;
            const opcode: u16 = @truncate(word2);
            if (size < 8 or size % 4 != 0) return c.fail(error.InvalidMessage);
            if (avail < size) {
                if (size > c.in.len) return c.fail(error.MessageTooLarge);
                return null;
            }
            const payload: []align(4) const u8 = @alignCast(c.in[c.in_start + 8 .. c.in_start + size]);
            c.in_start += size;

            const obj = c.lookup(id) orelse {
                log.err("event for unknown object {d}", .{id});
                return c.fail(error.InvalidMessage);
            };
            if (obj.state == .free) {
                log.err("event for deleted object {d}", .{id});
                return c.fail(error.InvalidMessage);
            }
            const iface = &proto.interfaces[@intFromEnum(obj.iface)];
            if (opcode >= iface.events.len) {
                log.err("{s}#{d}: unknown event opcode {d}", .{ iface.name, id, opcode });
                return c.fail(error.InvalidMessage);
            }
            const ev = iface.events[opcode];
            var m: Message = .{ .object = id, .iface = obj.iface, .opcode = opcode, .data = obj.data, .payload = payload, .conn = c };
            var nfds: usize = 0;
            for (ev.signature) |ch| if (ch == 'h') {
                if (c.in_fd_len == 0 or nfds == max_fds_per_message) {
                    m.deinit();
                    return c.fail(error.InvalidMessage);
                }
                m.fds[nfds] = c.popFd();
                nfds += 1;
            };
            if (c.debug) logMessage("<-", iface.name, id, ev, payload);
            if (ev.new_id) |new_iface| {
                if (newIdArg(ev.signature, payload)) |new| try c.registerServerObject(new, new_iface, obj.version);
            }
            if (ev.destructor and obj.state == .live) obj.state = .zombie;

            if (id == display_id) {
                try c.handleDisplay(&m);
                continue;
            }
            if (obj.state == .zombie and !ev.destructor) {
                m.deinit();
                continue;
            }
            return m;
        }
    }

    fn handleDisplay(c: *Connection, m: *Message) Error!void {
        defer m.deinit();
        switch (try m.decode(proto.WlDisplay)) {
            .@"error" => |e| {
                var de: DisplayError = .{ .object_id = e.object_id, .interface = "?", .code = e.code };
                if (c.lookup(e.object_id)) |o| de.interface = proto.interfaces[@intFromEnum(o.iface)].name;
                de.message_len = @min(e.message.len, de.message_buf.len);
                @memcpy(de.message_buf[0..de.message_len], e.message[0..de.message_len]);
                c.display_error = de;
                if (!builtin.is_test) log.err("protocol error on {s}#{d}, code {d}: {s}", .{ de.interface, de.object_id, de.code, de.message() });
                return c.fail(error.ProtocolError);
            },
            .delete_id => |d| c.deleteId(d.id),
        }
    }

    /// Blocks until all requests so far have been processed by the server, dispatching
    /// nothing; the caller's handler sees every message via `handler.handle(*Message)`.
    pub fn roundtrip(c: *Connection, handler: anytype) !void {
        const cb = try c.display().sync(c);
        try c.flush();
        var done = false;
        const deadline = monotonicNs() + 5 * std.time.ns_per_s;
        while (!done) {
            while (try c.nextMessage()) |msg| {
                var m = msg;
                defer m.deinit();
                if (m.object == @intFromEnum(cb)) {
                    done = true;
                    continue;
                }
                try handler.handle(&m);
            }
            if (done) break;
            const now = monotonicNs();
            if (now >= deadline) return error.Timeout;
            var pfd = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, @intCast(@max(1, (deadline - now) / std.time.ns_per_ms)));
            _ = try c.read();
        }
    }
};

/// Finds the value of the first new_id argument in a payload.
fn newIdArg(sig: []const u8, payload: []align(4) const u8) ?u32 {
    var r: Reader = .{ .buf = payload };
    for (sig) |ch| switch (ch) {
        '?' => {},
        'n' => return r.word() catch null,
        's', 'a' => _ = r.bytes() catch return null,
        'h' => {},
        else => _ = r.word() catch return null,
    };
    return null;
}

fn cmsgLen(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + n;
}

fn cmsgSpace(n: usize) usize {
    return @sizeOf(linux.cmsghdr) + std.mem.alignForward(usize, n, @sizeOf(usize));
}

pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Formats a message for PALETTE_WAYLAND_DEBUG.
fn logMessage(dir: []const u8, iface: []const u8, id: u32, msg: proto.Message, payload: []align(4) const u8) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    formatArgs(&w, msg.signature, payload) catch {};
    std.debug.print("[wayland] {s} {s}#{d}.{s}({s})\n", .{ dir, iface, id, msg.name, w.buffered() });
}

fn formatArgs(w: *std.Io.Writer, sig: []const u8, payload: []align(4) const u8) !void {
    var r: Reader = .{ .buf = payload };
    var first = true;
    for (sig) |ch| {
        if (ch == '?') continue;
        if (!first) try w.writeAll(", ");
        first = false;
        switch (ch) {
            'i' => try w.print("{d}", .{@as(i32, @bitCast(try r.word()))}),
            'u' => try w.print("{d}", .{try r.word()}),
            'f' => try w.print("{d:.2}", .{Fixed.toFloat(@enumFromInt(@as(i32, @bitCast(try r.word()))))}),
            'o' => try w.print("#{d}", .{try r.word()}),
            'n' => try w.print("new #{d}", .{try r.word()}),
            's' => if (try r.string()) |s| try w.print("\"{s}\"", .{s[0..@min(s.len, 200)]}) else try w.writeAll("nil"),
            'a' => try w.print("array[{d}]", .{(try r.bytes()).len}),
            'h' => try w.writeAll("fd"),
            else => {},
        }
    }
}

/// Environment access. Defaults to the process environment (libc `environ` when linked).
pub const Env = struct {
    environ: std.process.Environ = .empty,

    pub fn get(e: Env, key: []const u8) ?[]const u8 {
        if (e.environ.block.slice.len > 0) return e.environ.getPosix(key);
        if (builtin.link_libc) {
            var kbuf: [128]u8 = undefined;
            if (key.len >= kbuf.len) return null;
            @memcpy(kbuf[0..key.len], key);
            kbuf[key.len] = 0;
            const v = std.c.getenv(@ptrCast(&kbuf)) orelse return null;
            return std.mem.sliceTo(v, 0);
        }
        return null;
    }
};

// ---------------------------------------------------------------------------------------------
// Tests: encode with a real Connection over a socketpair and decode on the other side.

const testing = std.testing;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    return fds;
}

test "marshal request bytes" {
    const fds = try socketPair();
    var c = try Connection.fromFd(testing.allocator, fds[0], .{});
    defer c.deinit();
    defer _ = linux.close(fds[1]);

    const reg = try c.display().getRegistry(c);
    try testing.expectEqual(@as(u32, 2), @intFromEnum(reg));
    const surface: proto.WlSurface = try c.newObject(proto.WlSurface, 6);
    try surface.attach(c, null, -1, 2);
    const tl = try c.newObject(proto.XdgToplevel, 6);
    try tl.setTitle(c, "hey");
    try c.flush();

    var buf: [256]u8 align(4) = undefined;
    const n = linux.read(fds[1], &buf, buf.len);
    const words: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, buf[0..n]));
    const expected = [_]u32{
        1, (12 << 16) | 1, 2, // wl_display.get_registry(new 2)
        3, (20 << 16) | 1, 0, @bitCast(@as(i32, -1)), 2, // wl_surface.attach(nil, -1, 2)
        4, (16 << 16) | 2, 4, std.mem.readInt(u32, "hey\x00", .little), // xdg_toplevel.set_title
    };
    try testing.expectEqualSlices(u32, &expected, words);
}

test "roundtrip events with fds, strings, arrays and new ids" {
    const fds = try socketPair();
    var c = try Connection.fromFd(testing.allocator, fds[0], .{});
    defer c.deinit();
    defer _ = linux.close(fds[1]);

    const kb = try c.newObject(proto.WlKeyboard, 9); // id 2
    const dev = try c.newObject(proto.WlDataDevice, 3); // id 3

    // Hand-encode a server stream: keymap(format=1, fd, size=42), data_offer(new 0xff000000),
    // offer.offer("text/plain"), keyboard.enter(serial 7, surface 9, keys [30, 31]), delete_id(3).
    var s: [64]u32 = undefined;
    var n: usize = 0;
    const put = struct {
        fn f(arr: []u32, i: *usize, v: u32) void {
            arr[i.*] = v;
            i.* += 1;
        }
    }.f;
    put(&s, &n, 2);
    put(&s, &n, (16 << 16) | 0);
    put(&s, &n, 1);
    put(&s, &n, 42);
    put(&s, &n, 3);
    put(&s, &n, (12 << 16) | 0);
    put(&s, &n, 0xff000000);
    put(&s, &n, 0xff000000);
    put(&s, &n, (24 << 16) | 0);
    put(&s, &n, 11);
    for (std.mem.bytesAsSlice(u32, "text/plain\x00\x00")) |w| put(&s, &n, w);
    put(&s, &n, 2);
    put(&s, &n, (28 << 16) | 1);
    put(&s, &n, 7);
    put(&s, &n, 9);
    put(&s, &n, 8);
    put(&s, &n, 30);
    put(&s, &n, 31);
    put(&s, &n, 1);
    put(&s, &n, (12 << 16) | 1);
    put(&s, &n, 3);

    // Send with one fd (a pipe end) attached.
    var pipe_fds: [2]i32 = undefined;
    _ = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    defer _ = linux.close(pipe_fds[1]);
    {
        var iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(&s), .len = n * 4 }};
        var cbuf: [cmsgSpace(4)]u8 align(8) = undefined;
        const hdr: *linux.cmsghdr = @ptrCast(&cbuf);
        hdr.* = .{ .len = cmsgLen(4), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(cbuf[@sizeOf(linux.cmsghdr)..][0..4], std.mem.asBytes(&pipe_fds[0]));
        const msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len, .flags = 0 };
        try testing.expect(linux.errno(linux.sendmsg(fds[1], &msg, 0)) == .SUCCESS);
        _ = linux.close(pipe_fds[0]); // the receiver got its own copy
    }

    try testing.expect(try c.read() > 0);

    var m1 = (try c.nextMessage()).?;
    defer m1.deinit();
    try testing.expectEqual(@intFromEnum(kb), m1.object);
    const km = (try m1.decode(proto.WlKeyboard)).keymap;
    try testing.expectEqual(proto.WlKeyboard.KeymapFormat.xkb_v1, km.format);
    try testing.expectEqual(@as(u32, 42), km.size);
    // The received fd is a working dup of the pipe's read end.
    _ = linux.write(pipe_fds[1], "x", 1);
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), linux.read(@intFromEnum(km.fd), &one, 1));
    _ = linux.close(@intFromEnum(km.fd));

    var m2 = (try c.nextMessage()).?;
    defer m2.deinit();
    const offer = (try m2.decode(proto.WlDataDevice)).data_offer.id;
    try testing.expectEqual(@as(u32, 0xff000000), @intFromEnum(offer));
    try testing.expectEqual(InterfaceId.wl_data_offer, c.lookup(0xff000000).?.iface);
    try testing.expectEqual(@as(u32, 3), c.lookup(0xff000000).?.version);

    var m3 = (try c.nextMessage()).?;
    defer m3.deinit();
    try testing.expectEqualStrings("text/plain", (try m3.decode(proto.WlDataOffer)).offer.mime_type);

    var m4 = (try c.nextMessage()).?;
    defer m4.deinit();
    const enter = (try m4.decode(proto.WlKeyboard)).enter;
    try testing.expectEqual(@as(u32, 7), enter.serial);
    const keys = enter.keys.u32s();
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqual(@as(u32, 30), keys[0]);
    try testing.expectEqual(@as(u32, 31), keys[1]);

    // delete_id is consumed internally and frees id 3 for reuse.
    _ = dev;
    try testing.expect((try c.nextMessage()) == null);
    try testing.expectEqual(ObjectState.free, c.lookup(3).?.state);
    const again = try c.newObject(proto.WlCallback, 1);
    try testing.expectEqual(@as(u32, 3), @intFromEnum(again));
}

test "partial messages wait for more bytes" {
    const fds = try socketPair();
    var c = try Connection.fromFd(testing.allocator, fds[0], .{});
    defer c.deinit();
    defer _ = linux.close(fds[1]);
    _ = try c.newObject(proto.WlCallback, 1); // id 2
    const msg = [_]u32{ 2, (12 << 16) | 0, 99 };
    const bytes = std.mem.sliceAsBytes(&msg);
    _ = linux.write(fds[1], bytes.ptr, 6);
    _ = try c.read();
    try testing.expect((try c.nextMessage()) == null);
    _ = linux.write(fds[1], bytes[6..].ptr, bytes.len - 6);
    _ = try c.read();
    var m = (try c.nextMessage()).?;
    defer m.deinit();
    try testing.expectEqual(@as(u32, 99), (try m.decode(proto.WlCallback)).done.callback_data);
    // done is a destructor event: object becomes a zombie until delete_id.
    try testing.expectEqual(ObjectState.zombie, c.lookup(2).?.state);
}
