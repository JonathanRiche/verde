//! Temporary native TLS fixture shared by owning unit and isolated daemon tests.
const std = @import("std");

pub const Fixture = struct {
    child: std.process.Child,
    base_url: []u8,
    ca_file: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !Fixture {
        const ready = try std.fs.path.join(allocator, &.{ directory, "ready" });
        defer allocator.free(ready);
        var child = try std.process.spawn(io, .{
            .argv = &.{ "python3", "-c", @embedFile("connect_tls_fixture.py"), directory },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer child.kill(io);
        const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
        while (std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
            if (std.Io.Dir.cwd().readFileAlloc(io, ready, allocator, .limited(32))) |bytes| {
                defer allocator.free(bytes);
                const port = try std.fmt.parseInt(u16, bytes, 10);
                const base_url = try std.fmt.allocPrint(allocator, "https://localhost:{d}", .{port});
                errdefer allocator.free(base_url);
                return .{ .child = child, .base_url = base_url, .ca_file = try std.fs.path.join(allocator, &.{ directory, "ca.pem" }) };
            } else |err| if (err != error.FileNotFound) return err;
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        return error.ConnectTlsFixtureStartupTimedOut;
    }

    pub fn deinit(self: *Fixture, allocator: std.mem.Allocator, io: std.Io) void {
        self.child.kill(io);
        allocator.free(self.base_url);
        allocator.free(self.ca_file);
    }
};
