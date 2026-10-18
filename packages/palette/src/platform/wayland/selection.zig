//! Text selections: the regular clipboard (wl_data_device) and the primary selection
//! (zwp_primary_selection_device_v1). Both protocols have the same shape (device, offer,
//! source), so one generic implementation serves both.
//!
//! Offering: our text is kept in a ref-counted buffer; every `send` request from the compositor
//! becomes a non-blocking write job serviced from the App's poll loop, so a slow or stuck
//! receiver never blocks the UI thread. Receiving: `get` asks the offer to write into a pipe and
//! reads it with a bounded wait (the receiving side cannot be made asynchronous without
//! changing the API).

const std = @import("std");
const linux = std.os.linux;
const wire = @import("wire.zig");

const log = std.log.scoped(.wayland);

pub const mime_types = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

/// Returns the bit for a text mime type we understand, or 0.
pub fn mimeBit(mime: []const u8) u8 {
    for (mime_types, 0..) |m, i| {
        if (std.mem.eql(u8, m, mime)) return @as(u8, 1) << @intCast(i);
    }
    return 0;
}

/// Picks the preferred mime type out of a bitmask (lowest bit = most preferred).
pub fn bestMime(mask: u8) ?[]const u8 {
    if (mask == 0) return null;
    return mime_types[@ctz(mask)];
}

/// Text we are offering. Shared by the selection and every in-flight send job.
const Owned = struct {
    refs: u32,
    bytes: []u8,

    fn release(o: *Owned, gpa: std.mem.Allocator) void {
        o.refs -= 1;
        if (o.refs == 0) {
            gpa.free(o.bytes);
            gpa.destroy(o);
        }
    }
};

const SendJob = struct {
    fd: i32 = -1,
    owned: ?*Owned = null,
    pos: usize = 0,
};

pub const max_offers = 8;
pub const max_jobs = 8;
/// Upper bound for a receive (`get`).
pub const receive_timeout_ms = 1000;
pub const max_receive_bytes = 64 << 20;

pub fn Selection(comptime Offer: type, comptime Source: type) type {
    return struct {
        const Self = @This();

        offers: [max_offers]struct { id: u32 = 0, mimes: u8 = 0 } = @splat(.{}),
        /// Offer currently holding the selection (0 = none / not text).
        current: u32 = 0,
        source: u32 = 0,
        owned: ?*Owned = null,
        jobs: [max_jobs]SendJob = @splat(.{}),

        pub fn deinit(s: *Self, conn: *wire.Connection, gpa: std.mem.Allocator) void {
            for (&s.jobs) |*j| s.finishJob(j, gpa);
            for (&s.offers) |*o| if (o.id != 0) {
                (@as(Offer, @enumFromInt(o.id))).destroy(conn) catch {};
                o.* = .{};
            };
            if (s.source != 0) (@as(Source, @enumFromInt(s.source))).destroy(conn) catch {};
            s.source = 0;
            if (s.owned) |o| o.release(gpa);
            s.owned = null;
        }

        // -- offers (incoming) --------------------------------------------------------------

        pub fn onDataOffer(s: *Self, conn: *wire.Connection, id: u32) void {
            for (&s.offers) |*o| if (o.id == 0) {
                o.* = .{ .id = id };
                return;
            };
            // Table full: a misbehaving compositor or lots of DnD; drop the newcomer.
            (@as(Offer, @enumFromInt(id))).destroy(conn) catch {};
        }

        pub fn onOfferMime(s: *Self, id: u32, mime: []const u8) void {
            for (&s.offers) |*o| if (o.id == id) {
                o.mimes |= mimeBit(mime);
                return;
            };
        }

        /// New selection (null = cleared). Older offers are destroyed.
        pub fn onSelection(s: *Self, conn: *wire.Connection, id: ?u32) void {
            const keep = id orelse 0;
            for (&s.offers) |*o| if (o.id != 0 and o.id != keep) {
                (@as(Offer, @enumFromInt(o.id))).destroy(conn) catch {};
                o.* = .{};
            };
            s.current = keep;
        }

        /// Destroys a single offer (DnD offers we do not use).
        pub fn dropOffer(s: *Self, conn: *wire.Connection, id: u32) void {
            for (&s.offers) |*o| if (o.id == id) {
                (@as(Offer, @enumFromInt(id))).destroy(conn) catch {};
                o.* = .{};
                if (s.current == id) s.current = 0;
                return;
            };
        }

        fn currentMimes(s: *const Self) u8 {
            if (s.current == 0) return 0;
            for (s.offers) |o| if (o.id == s.current) return o.mimes;
            return 0;
        }

        /// Reads the selection as UTF-8 text. Returns our own text directly when we own it.
        pub fn get(s: *Self, conn: *wire.Connection, allocator: std.mem.Allocator) !?[]u8 {
            if (s.source != 0) if (s.owned) |o| return try allocator.dupe(u8, o.bytes);
            const mime = bestMime(s.currentMimes()) orelse return null;
            var fds: [2]i32 = undefined;
            if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.SystemResources;
            defer _ = linux.close(fds[0]);
            {
                defer _ = linux.close(fds[1]);
                try (@as(Offer, @enumFromInt(s.current))).receive(conn, mime, @enumFromInt(fds[1]));
                try conn.flush();
            }
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            const deadline = wire.monotonicNs() + receive_timeout_ms * std.time.ns_per_ms;
            var buf: [16384]u8 = undefined;
            while (true) {
                const now = wire.monotonicNs();
                if (now >= deadline) {
                    log.warn("selection receive timed out after {d} bytes", .{out.items.len});
                    break;
                }
                var pfd = [1]linux.pollfd{.{ .fd = fds[0], .events = linux.POLL.IN, .revents = 0 }};
                const prc = linux.poll(&pfd, 1, @intCast(@max(1, (deadline - now) / std.time.ns_per_ms)));
                if (linux.errno(prc) == .INTR) continue;
                if (prc == 0) continue;
                const n = linux.read(fds[0], &buf, buf.len);
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    .INTR, .AGAIN => continue,
                    else => break,
                }
                if (n == 0) break;
                if (out.items.len + n > max_receive_bytes) break;
                try out.appendSlice(allocator, buf[0..n]);
            }
            return try out.toOwnedSlice(allocator);
        }

        // -- source (outgoing) --------------------------------------------------------------

        /// Takes ownership of the selection with `text`. `src` is a freshly created source,
        /// `device` the matching device object.
        pub fn set(s: *Self, conn: *wire.Connection, gpa: std.mem.Allocator, src: Source, device: anytype, serial: u32, text: []const u8) !void {
            const owned = try gpa.create(Owned);
            errdefer gpa.destroy(owned);
            owned.* = .{ .refs = 1, .bytes = try gpa.dupe(u8, text) };
            for (mime_types) |m| try src.offer(conn, m);
            try device.setSelection(conn, src, serial);
            if (s.source != 0) (@as(Source, @enumFromInt(s.source))).destroy(conn) catch {};
            if (s.owned) |o| o.release(gpa);
            s.source = @intFromEnum(src);
            s.owned = owned;
        }

        pub fn onSend(s: *Self, gpa: std.mem.Allocator, source: u32, mime: []const u8, fd: i32) void {
            if (source != s.source or s.owned == null or mimeBit(mime) == 0) {
                _ = linux.close(fd);
                return;
            }
            for (&s.jobs) |*j| if (j.fd < 0) {
                const fl = linux.fcntl(fd, linux.F.GETFL, 0);
                _ = linux.fcntl(fd, linux.F.SETFL, fl | @as(usize, 1 << @bitOffsetOf(linux.O, "NONBLOCK")));
                s.owned.?.refs += 1;
                j.* = .{ .fd = fd, .owned = s.owned };
                s.service(j, gpa);
                return;
            };
            log.warn("too many concurrent selection transfers; dropping one", .{});
            _ = linux.close(fd);
        }

        pub fn onCancelled(s: *Self, conn: *wire.Connection, gpa: std.mem.Allocator, source: u32) void {
            (@as(Source, @enumFromInt(source))).destroy(conn) catch {};
            if (source == s.source) {
                s.source = 0;
                if (s.owned) |o| o.release(gpa);
                s.owned = null;
            }
        }

        pub fn ownsSelection(s: *const Self) bool {
            return s.source != 0;
        }

        // -- send jobs ------------------------------------------------------------------------

        /// Appends pollfds for pending writes; returns how many were added.
        pub fn pollFds(s: *const Self, out: []linux.pollfd) usize {
            var n: usize = 0;
            for (s.jobs) |j| if (j.fd >= 0 and n < out.len) {
                out[n] = .{ .fd = j.fd, .events = linux.POLL.OUT, .revents = 0 };
                n += 1;
            };
            return n;
        }

        pub fn hasJobs(s: *const Self) bool {
            for (s.jobs) |j| if (j.fd >= 0) return true;
            return false;
        }

        /// Services the job owning `fd` (after poll reported it writable or errored).
        pub fn serviceFd(s: *Self, gpa: std.mem.Allocator, fd: i32) void {
            for (&s.jobs) |*j| if (j.fd == fd) return s.service(j, gpa);
        }

        fn service(s: *Self, j: *SendJob, gpa: std.mem.Allocator) void {
            const bytes = j.owned.?.bytes;
            while (j.pos < bytes.len) {
                const rc = linux.write(j.fd, bytes[j.pos..].ptr, bytes.len - j.pos);
                switch (linux.errno(rc)) {
                    .SUCCESS => j.pos += rc,
                    .INTR => continue,
                    .AGAIN => return,
                    else => break, // EPIPE etc.: receiver went away
                }
            }
            s.finishJob(j, gpa);
        }

        fn finishJob(_: *Self, j: *SendJob, gpa: std.mem.Allocator) void {
            if (j.fd < 0) return;
            _ = linux.close(j.fd);
            if (j.owned) |o| o.release(gpa);
            j.* = .{};
        }
    };
}
