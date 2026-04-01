//! Browser bridge policy for deciding which pages receive privileged app messaging.

const std = @import("std");

/// Restricts host messaging until the embedded browser runtime is production ready.
pub const Policy = struct {
    /// Allows app pages and localhost tooling while denying arbitrary remote origins by default.
    pub fn allowsHostMessaging(self: Policy, origin: []const u8) bool {
        _ = self;
        if (std.mem.startsWith(u8, origin, "app://")) return true;
        if (std.mem.startsWith(u8, origin, "http://127.0.0.1")) return true;
        if (std.mem.startsWith(u8, origin, "http://localhost")) return true;
        return false;
    }
};
