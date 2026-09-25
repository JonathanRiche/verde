//! Shared, transport-neutral remote client logic. Platform adapters own IO.

pub const connection = @import("connection.zig");
pub const pin_controller = @import("pin_controller.zig");
pub const thread_binding = @import("thread_binding.zig");
pub const transcript_apply = @import("transcript_apply.zig");
pub const profile = @import("profile.zig");
pub const pair_client = @import("pair_client.zig");
pub const threads = @import("threads.zig");
pub const slash_commands = @import("slash_commands.zig");

test {
    _ = connection;
    _ = pin_controller;
    _ = thread_binding;
    _ = transcript_apply;
    _ = profile;
    _ = pair_client;
    _ = threads;
    _ = slash_commands;
}
