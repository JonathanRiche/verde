//! Shared desktop platform services.

pub const runtime = @import("platform_runtime");
pub const paths = @import("platform_paths");
pub const process = @import("process.zig");
pub const live_endpoint = @import("live_endpoint.zig");
pub const ipc = @import("ipc.zig");
pub const windows_known_folders = @import("platform_windows_known_folders");
pub const windows_integrations = @import("windows/integrations.zig");

test {
    _ = ipc;
    _ = live_endpoint;
    _ = paths;
    _ = process;
    _ = runtime;
    _ = windows_known_folders;
    _ = windows_integrations;
}
