//! Runtime-scoped provider inventory and dynamic model DTOs.
//!
//! Surface flags intentionally preserve Verde's distinct native-chat, MCP,
//! and terminal integration sets. Strings are used for probe/auth states so
//! older clients can tolerate a newer daemon state without enum decode failure.

const std = @import("std");
const provider_types = @import("provider_types.zig");

pub const METHOD_PROVIDER_MODELS_LIST: []const u8 = "provider.models.list";
pub const METHOD_PROVIDER_AUTH_STATUS: []const u8 = "provider.auth.status";
pub const METHOD_PROVIDER_THREADS_LIST: []const u8 = "provider.threads.list";
pub const METHOD_PROVIDER_THREAD_SYNC: []const u8 = "provider.thread.sync";
pub const METHOD_PROVIDER_THREAD_READ: []const u8 = "provider.thread.read";
pub const METHOD_PROVIDER_THREAD_INTERRUPT: []const u8 = "provider.thread.interrupt";
pub const METHOD_PROVIDER_THREAD_STEER: []const u8 = "provider.thread.steer";
pub const METHOD_PROVIDER_SLASH_LIST: []const u8 = "provider.slash.list";
pub const METHOD_PROVIDER_SLASH_RUN: []const u8 = "provider.slash.run";
pub const METHOD_PROVIDER_CODEX_BACKGROUND_STATUS: []const u8 = "provider.codex.background.status";
pub const METHOD_PROVIDER_CODEX_BACKGROUND_TERMINATE: []const u8 = "provider.codex.background.terminate";
pub const METHOD_PROVIDER_INTEGRATIONS_INSPECT: []const u8 = "provider.integrations.inspect";
pub const METHOD_PROVIDER_HOOKS_SET: []const u8 = "provider.hooks.set";
pub const METHOD_PROVIDER_MCP_SET: []const u8 = "provider.mcp.set";
pub const METHOD_PROVIDER_TITLE_GENERATE: []const u8 = "provider.title.generate";
pub const METHOD_PROVIDERS_STATUS: []const u8 = "providers.status";

pub const IntegrationProvider = enum {
    codex,
    claude,
    cursor,
    opencode,
    amp,
    pi,
    fx,
    grok,
};

pub const RegistrationStatus = enum {
    unavailable,
    not_installed,
    installed,
    conflict,
    failed,
};

pub const McpSummary = struct {
    codex: RegistrationStatus = .unavailable,
    claude: RegistrationStatus = .unavailable,
    cursor: RegistrationStatus = .unavailable,
    opencode: RegistrationStatus = .unavailable,
    amp: RegistrationStatus = .unavailable,
    pi: RegistrationStatus = .unavailable,
    fx: RegistrationStatus = .unavailable,
    grok: RegistrationStatus = .unavailable,

    pub fn forProvider(self: McpSummary, provider: IntegrationProvider) RegistrationStatus {
        return switch (provider) {
            .codex => self.codex,
            .claude => self.claude,
            .cursor => self.cursor,
            .opencode => self.opencode,
            .amp => self.amp,
            .pi => self.pi,
            .fx => self.fx,
            .grok => self.grok,
        };
    }

    pub fn detectedCount(self: McpSummary) usize {
        var count: usize = 0;
        inline for (std.meta.tags(IntegrationProvider)) |provider| {
            if (self.forProvider(provider) != .unavailable) count += 1;
        }
        return count;
    }

    pub fn installedCount(self: McpSummary) usize {
        var count: usize = 0;
        inline for (std.meta.tags(IntegrationProvider)) |provider| {
            if (self.forProvider(provider) == .installed) count += 1;
        }
        return count;
    }

    pub fn conflictCount(self: McpSummary) usize {
        var count: usize = 0;
        inline for (std.meta.tags(IntegrationProvider)) |provider| {
            if (self.forProvider(provider) == .conflict) count += 1;
        }
        return count;
    }

    pub fn failedCount(self: McpSummary) usize {
        var count: usize = 0;
        inline for (std.meta.tags(IntegrationProvider)) |provider| {
            if (self.forProvider(provider) == .failed) count += 1;
        }
        return count;
    }

    pub fn allDetectedInstalled(self: McpSummary) bool {
        const detected = self.detectedCount();
        return detected > 0 and self.installedCount() == detected;
    }
};

pub const ManagedHookProvider = enum {
    claude,
    codex,
    cursor,
    grok,
    amp,
    opencode,
    pi,
};

pub const ManagedHookStatus = struct {
    claude: bool = false,
    codex: bool = false,
    cursor: bool = false,
    grok: bool = false,
    amp: bool = false,
    opencode: bool = false,
    pi: bool = false,

    pub fn forProvider(self: ManagedHookStatus, provider: ManagedHookProvider) bool {
        return switch (provider) {
            .claude => self.claude,
            .codex => self.codex,
            .cursor => self.cursor,
            .grok => self.grok,
            .amp => self.amp,
            .opencode => self.opencode,
            .pi => self.pi,
        };
    }
};

pub const IntegrationsInspectRequest = struct {};
pub const IntegrationsInspectResult = struct {
    hooks: ManagedHookStatus,
    mcp: McpSummary,
};

pub const HooksSetRequest = struct {
    provider: ManagedHookProvider,
    installed: bool,
};
pub const HooksSetResult = struct {
    provider: ManagedHookProvider,
    installed: bool,
};

pub const McpSetRequest = struct {
    installed: bool,
};
pub const McpSetResult = struct {
    summary: McpSummary,
};

pub const TitleAccessMode = enum {
    supervised,
    full_access,
};

pub const TitleGenerateRequest = struct {
    provider: provider_types.Provider,
    model_ref: ?[]const u8 = null,
    reasoning_effort: ?provider_types.ReasoningEffort = null,
    reasoning_variant: ?[]const u8 = null,
    fast: bool = false,
    access_mode: TitleAccessMode = .supervised,
    cwd: []const u8,
    user_text: []const u8,
    assistant_text: []const u8,
    /// Optional durable identity; when both are set the daemon records the
    /// generated search description for that thread.
    workspace_id: ?[]const u8 = null,
    local_thread_id: ?[]const u8 = null,
    /// Provider and model of the chat being titled. When `provider` is not
    /// the chat's provider and is not signed in, the daemon titles with this
    /// one instead of sending the chat to a provider the user never set up.
    chat_provider: ?provider_types.Provider = null,
    chat_model_ref: ?[]const u8 = null,
};

pub const TitleGenerateResult = struct {
    title: ?[]const u8 = null,
    /// One-line search description, when the model produced one.
    description: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const ProviderRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
};

pub const AuthStatusRequest = ProviderRequest;

/// A runtime the provider CLI needs before Verde can drive it.
pub const MissingRequirement = enum {
    /// Verde runs Claude Code through Node.js and the Claude Agent SDK; the
    /// native Claude installer does not install Node.
    node,
};

pub const AuthStatusResult = struct {
    provider: provider_types.Provider,
    installed: bool,
    auth_state: provider_types.AuthState,
    ready: bool,
    /// First line of `<cli> --version` as seen by this daemon. Absent when the
    /// CLI is missing or the probe did not finish.
    version: ?[]const u8 = null,
    /// Set when the provider CLI is present but cannot run yet. `installed`
    /// stays false so older clients still treat the provider as unusable.
    missing_requirement: ?MissingRequirement = null,
};

pub const ThreadsListRequest = ProviderRequest;

pub const ThreadsListResult = struct {
    provider: provider_types.Provider,
    threads: []const provider_types.ChatThreadSummary,
};

pub const ThreadReadRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
    thread_id: []const u8,
};

/// Replace an existing local thread from its provider-owned history.
pub const ThreadSyncRequest = struct {
    workspace_id: []const u8,
    local_thread_id: []const u8,
    provider_thread_id: []const u8,
};

pub const ThreadReadResult = struct {
    provider: provider_types.Provider,
    thread: provider_types.ReadThreadResult,
};

pub const ThreadInterruptRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
};

pub const ThreadSteerRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    images: []const provider_types.ImageAttachment = &.{},
};

pub const ThreadControlStatus = enum {
    accepted,
    unsupported,
};

pub const ThreadControlResult = struct {
    status: ThreadControlStatus,
};

pub const SlashListRequest = ProviderRequest;

pub const SlashListResult = struct {
    provider: provider_types.Provider,
    commands: []const provider_types.ProviderSlashCommand,
};

pub const SlashRunRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
    thread_id: ?[]const u8 = null,
    command: provider_types.ProviderSlashCommandId,
    raw_text: []const u8,
    args: []const u8,
};

pub const SlashRunResult = struct {
    provider: provider_types.Provider,
    result: provider_types.RunSlashCommandResult,
};

pub const CodexBackgroundRequest = struct {
    project_path: []const u8,
    thread_id: []const u8,
    process_id: []const u8,
};

pub const CodexBackgroundStatusResult = struct {
    running: bool,
};

pub const CodexBackgroundTerminateResult = struct {
    terminated: bool,
};

pub const ModelsListRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
};

pub const ModelsListResult = struct {
    provider: provider_types.Provider,
    models: []const provider_types.ModelInfo,
};

/// Named empty request object; an anonymous `.{}` encodes as the JSON tuple
/// `[]`, which the daemon correctly rejects for object-shaped parameters.
pub const StatusRequest = struct {};

pub const ProviderSurfaces = struct {
    native_chat: bool = false,
    terminal_tui: bool = false,
    mcp: bool = false,
    lifecycle: bool = false,
};

pub const Remediation = struct {
    kind: []const u8,
    label: []const u8,
    command: []const []const u8 = &.{},
};

pub const ProviderStatus = struct {
    provider: []const u8,
    label: []const u8,
    surfaces: ProviderSurfaces,
    installed: bool,
    state: []const u8,
    authentication: []const u8,
    executable_path: ?[]const u8 = null,
    version: ?[]const u8 = null,
    account_label: ?[]const u8 = null,
    auth_kind: ?[]const u8 = null,
    remediation: ?Remediation = null,
};

pub const StatusResult = struct {
    runtime_id: []const u8,
    instance_id: []const u8,
    probed_at_ms: i64,
    providers: []const ProviderStatus,
};
