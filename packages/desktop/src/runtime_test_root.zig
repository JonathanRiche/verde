//! Focused tests for desktop remote-runtime infrastructure without GUI deps.

test {
    _ = @import("runtime/profile.zig");
    _ = @import("runtime/profile_store.zig");
    _ = @import("runtime/workspace_runtime_defaults.zig");
    _ = @import("runtime/secret_store.zig");
    _ = @import("runtime/gateway_transport.zig");
    _ = @import("runtime/ssh_tunnel.zig");
    _ = @import("runtime/ssh_tunnel_supervisor.zig");
    _ = @import("runtime/connection.zig");
    _ = @import("runtime/manager.zig");
    _ = @import("runtime/pin_controller.zig");
    _ = @import("runtime/service.zig");
    _ = @import("runtime/thread_binding.zig");
    _ = @import("daemon/runtime_identity.zig");
    _ = @import("daemon/repository_path.zig");
    _ = @import("db/client.zig");
    _ = @import("cli/runtime_profiles.zig");
}
