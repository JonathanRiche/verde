//! Official installer commands for the provider CLIs Verde drives.
//!
//! These are the upstream one-liners. Verde shows them and can open them in a
//! terminal; it does not download or execute them itself.

const std = @import("std");
const provider_types = @import("provider_types.zig");

/// Single shell command that installs or updates this provider's CLI.
/// Each arm is one string literal so the returned slice has static lifetime.
pub fn installShell(provider: provider_types.Provider) []const u8 {
    return switch (provider) {
        .codex => "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        .claude => "curl -fsSL https://claude.ai/install.sh | bash",
        .cursor => "curl https://cursor.com/install -fsS | bash",
        .opencode => "curl -fsSL https://opencode.ai/v2/install | bash",
        .pi => "curl -fsSL https://pi.dev/install.sh | sh",
        .fx => "curl -fsSL https://fx.sh/setup.sh | bash",
        .grok => "curl -fsSL https://x.ai/cli/install.sh | bash",
        .muse => "curl -fsSL https://dev.meta.ai/install.sh | sh",
    };
}

/// One-element argv whose only item is `installShell`. Safe to store in a
/// provider-status remediation command. Force the entire backing array to be
/// comptime so returning its slice never exposes a runtime stack temporary.
pub fn installArgv(provider: provider_types.Provider) []const []const u8 {
    return switch (provider) {
        .codex => comptime &.{installShell(.codex)},
        .claude => comptime &.{installShell(.claude)},
        .cursor => comptime &.{installShell(.cursor)},
        .opencode => comptime &.{installShell(.opencode)},
        .pi => comptime &.{installShell(.pi)},
        .fx => comptime &.{installShell(.fx)},
        .grok => comptime &.{installShell(.grok)},
        .muse => comptime &.{installShell(.muse)},
    };
}

/// Interactive command that signs this provider's CLI in. Pi has no login
/// subcommand; its TUI owns `/login`. Cursor uses `cursor-agent` because
/// Grok also installs an `agent` binary that can shadow Cursor's on PATH.
pub fn loginArgv(provider: provider_types.Provider) []const []const u8 {
    return switch (provider) {
        .codex => comptime &.{ "codex", "login" },
        .claude => comptime &.{ "claude", "auth", "login" },
        .cursor => comptime &.{ "cursor-agent", "login" },
        .opencode => comptime &.{ "opencode", "auth", "login" },
        .pi => comptime &.{"pi"},
        .fx => comptime &.{ "fx", "login" },
        .grok => comptime &.{ "grok", "login" },
        .muse => comptime &.{ "muse", "login" },
    };
}

/// `loginArgv` as one shell string, for launching in a terminal pane.
pub fn loginShell(provider: provider_types.Provider) []const u8 {
    return switch (provider) {
        .codex => "codex login",
        .claude => "claude auth login",
        .cursor => "cursor-agent login",
        .opencode => "opencode auth login",
        .pi => "pi",
        .fx => "fx login",
        .grok => "grok login",
        .muse => "muse login",
    };
}

test "provider login shell matches its argv" {
    inline for (std.meta.tags(provider_types.Provider)) |provider| {
        const joined = try std.mem.join(std.testing.allocator, " ", loginArgv(provider));
        defer std.testing.allocator.free(joined);
        try std.testing.expectEqualStrings(joined, loginShell(provider));
    }
}

test "provider installers are single-line curl commands" {
    inline for (std.meta.tags(provider_types.Provider)) |provider| {
        const shell = installShell(provider);
        try std.testing.expect(shell.len > 0);
        try std.testing.expect(std.mem.indexOfAny(u8, shell, "\r\n") == null);
        try std.testing.expect(std.mem.startsWith(u8, shell, "curl "));
        try std.testing.expectEqualStrings(shell, installArgv(provider)[0]);
    }
}
