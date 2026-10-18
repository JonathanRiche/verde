//! Official installer commands for the provider CLIs Verde drives.
//!
//! These are the upstream one-liners. Verde shows them and can open them in a
//! terminal; it does not download or execute them itself.

const provider_types = @import("provider_types.zig");

/// Custom ACP agents are configured in Settings, not installed or signed in
/// by Verde; their remediation commands only print where to do that.
const CUSTOM_ACP_HINT = "Add or fix custom ACP agents in Verde Settings, Providers";

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
        // User-defined agents bring their own command; nothing to install.
        .custom_acp => "echo " ++ CUSTOM_ACP_HINT,
    };
}

/// PowerShell one-liner that installs this provider's CLI on Windows, or null
/// when upstream publishes no native Windows installer. Each command is the
/// provider's documented Windows route; OpenCode documents npm.
pub fn installShellWindows(provider: provider_types.Provider) ?[]const u8 {
    return switch (provider) {
        .codex => "irm https://chatgpt.com/codex/install.ps1 | iex",
        .claude => "irm https://claude.ai/install.ps1 | iex",
        .cursor => "irm 'https://cursor.com/install?win32=true' | iex",
        .opencode => "npm install -g opencode-ai",
        .pi => "irm https://pi.dev/install.ps1 | iex",
        .grok => "irm https://x.ai/cli/install.ps1 | iex",
        .fx, .muse, .custom_acp => null,
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
        .custom_acp => comptime &.{installShell(.custom_acp)},
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
        .custom_acp => comptime &.{ "echo", CUSTOM_ACP_HINT },
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
        .custom_acp => "echo " ++ CUSTOM_ACP_HINT,
    };
}
