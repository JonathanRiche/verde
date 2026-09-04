//! Public Verde command and desktop launcher entry point.

const std = @import("std");
const builtin = @import("builtin");

const cli = @import("cli/main.zig");

pub fn main(init: std.process.Init) void {
    mainInner(init) catch |err| {
        std.debug.print("verde: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn mainInner(init: std.process.Init) !void {
    const allocator = init.gpa;
    if (try cli.dispatch(allocator, init.io, init.minimal.args) == .handled) return;

    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    var original_args: std.ArrayList([]const u8) = .empty;
    defer original_args.deinit(allocator);
    while (iterator.next()) |arg| try original_args.append(allocator, arg);

    const gui_path = try guiExecutablePathAlloc(allocator, init.io);
    defer allocator.free(gui_path);
    const gui_args = try allocator.alloc([]const u8, @max(original_args.items.len, 1));
    defer allocator.free(gui_args);
    gui_args[0] = gui_path;
    if (original_args.items.len > 1) {
        @memcpy(gui_args[1..], original_args.items[1..]);
    }

    try replaceOrWait(init.io, gui_args);
}

fn guiExecutablePathAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const sibling = try std.fs.path.join(allocator, &.{ executable_dir, guiExecutableName() });
    errdefer allocator.free(sibling);
    if (builtin.os.tag != .windows) return sibling;
    if (std.Io.Dir.accessAbsolute(io, sibling, .{})) {
        return sibling;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    allocator.free(sibling);

    // The assembled Windows package keeps the GUI-subsystem executable in
    // app/ and the console CLI in bin/ so their public names remain stable.
    return std.fs.path.resolveWindows(allocator, &.{ executable_dir, "..", "app", "Verde.exe" });
}

fn guiExecutableName() []const u8 {
    return if (builtin.os.tag == .windows) "verde-gui.exe" else "verde-gui";
}

fn replaceOrWait(io: std.Io, argv: []const []const u8) !void {
    if (builtin.os.tag != .windows) return std.process.replace(io, .{ .argv = argv });

    // Windows has no exec-style process replacement. Keep the public console
    // launcher alive only to preserve the GUI exit code for terminal callers.
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}
