//! Verde web gateway: localhost HTTP/WebSocket client of the headless daemon.

const std = @import("std");

const auth_mod = @import("auth.zig");
const config_mod = @import("config.zig");
const daemon_mod = @import("daemon.zig");
const http_mod = @import("http.zig");
const theme_mod = @import("theme.zig");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| switch (err) {
        error.HelpRequested => {
            config_mod.printUsage();
            return;
        },
        else => {
            std.debug.print("verde-web fatal: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(init.gpa);
    while (iterator.next()) |arg| {
        try argv_list.append(init.gpa, arg);
    }

    const config = try config_mod.parse(init.gpa, init.environ_map, argv_list.items);
    var auth = try auth_mod.Service.initFromTokenFile(
        init.gpa,
        init.io,
        config.token_file,
        .{},
        .{},
    );
    defer auth.deinit();

    var daemon = daemon_mod.Daemon.init(init.gpa, init.io, config);
    try http_mod.serve(init.gpa, init.io, config, &daemon, &auth, init.environ_map);
}

test {
    std.testing.refAllDecls(@This());
    _ = auth_mod;
    _ = config_mod;
    _ = daemon_mod;
    _ = http_mod;
    _ = theme_mod;
}
