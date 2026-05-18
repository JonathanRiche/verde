//! Browser bridge policy for deciding which pages may send privileged app messages.

const std = @import("std");

/// Allows app pages and localhost tooling while denying arbitrary remote origins by default.
pub const Policy = struct {
    allow_untrusted: bool = false,

    pub fn allowsHostMessaging(self: Policy, url: []const u8) bool {
        if (self.allow_untrusted) return true;

        const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
        const scheme = url[0..scheme_end];
        if (std.ascii.eqlIgnoreCase(scheme, "app")) return true;
        if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;

        var authority = url[scheme_end + 3 ..];
        const authority_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
        authority = authority[0..authority_end];
        if (authority.len == 0) return false;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |userinfo_end| {
            authority = authority[userinfo_end + 1 ..];
        }

        const host = hostFromAuthority(authority) orelse return false;
        return std.ascii.eqlIgnoreCase(host, "localhost") or
            std.mem.eql(u8, host, "127.0.0.1") or
            std.mem.eql(u8, host, "::1");
    }

    fn hostFromAuthority(authority: []const u8) ?[]const u8 {
        if (authority.len == 0) return null;
        if (authority[0] == '[') {
            const end = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
            if (end <= 1) return null;
            return authority[1..end];
        }
        const port_start = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        if (port_start == 0) return null;
        return authority[0..port_start];
    }
};

test "browser bridge policy allows app and loopback origins only" {
    const policy: Policy = .{};

    try std.testing.expect(policy.allowsHostMessaging("app://desktop/browser"));
    try std.testing.expect(policy.allowsHostMessaging("http://localhost:5173"));
    try std.testing.expect(policy.allowsHostMessaging("https://LOCALHOST/path"));
    try std.testing.expect(policy.allowsHostMessaging("http://127.0.0.1:3000/index.html"));
    try std.testing.expect(policy.allowsHostMessaging("http://[::1]:3000/"));

    try std.testing.expect(!policy.allowsHostMessaging("https://example.com"));
    try std.testing.expect(!policy.allowsHostMessaging("http://localhost.evil.test"));
    try std.testing.expect(!policy.allowsHostMessaging("data:text/html,<script></script>"));
    try std.testing.expect(!policy.allowsHostMessaging("file:///tmp/page.html"));
    try std.testing.expect(!policy.allowsHostMessaging("about:blank"));
}

test "browser bridge policy can explicitly allow untrusted pages" {
    const policy: Policy = .{ .allow_untrusted = true };
    try std.testing.expect(policy.allowsHostMessaging("https://example.com"));
    try std.testing.expect(policy.allowsHostMessaging("data:text/html,<script></script>"));
}
