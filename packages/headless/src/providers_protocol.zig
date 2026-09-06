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
};

pub const TitleGenerateResult = struct {
    title: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const ProviderRequest = struct {
    provider: provider_types.Provider,
    project_path: []const u8,
};

pub const AuthStatusRequest = ProviderRequest;

pub const AuthStatusResult = struct {
    provider: provider_types.Provider,
    installed: bool,
    auth_state: provider_types.AuthState,
    ready: bool,
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

test "provider inventory DTO preserves distinct surfaces" {
    const rows = [_]ProviderStatus{
        .{
            .provider = "codex",
            .label = "Codex",
            .surfaces = .{ .native_chat = true, .terminal_tui = true, .mcp = true, .lifecycle = true },
            .installed = true,
            .state = "ready",
            .authentication = "authenticated",
        },
        .{
            .provider = "amp",
            .label = "Amp",
            .surfaces = .{ .terminal_tui = true, .mcp = true, .lifecycle = true },
            .installed = false,
            .state = "missing",
            .authentication = "unknown",
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, StatusResult{
        .runtime_id = "runtime-a",
        .instance_id = "instance-a",
        .probed_at_ms = 1,
        .providers = &rows,
    }, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(StatusResult, std.testing.allocator, encoded, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.providers[0].surfaces.native_chat);
    try std.testing.expect(!parsed.value.providers[1].surfaces.native_chat);
    try std.testing.expect(parsed.value.providers[1].surfaces.mcp);
}

test "provider status request encodes as an object" {
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        StatusRequest{},
        .{},
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("{}", encoded);
}

test "provider model list request preserves daemon wire shape" {
    const encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        ModelsListRequest{
            .provider = .cursor,
            .project_path = "/tmp/project",
        },
        .{},
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"provider\":\"cursor\",\"project_path\":\"/tmp/project\"}",
        encoded,
    );
}

test "provider operation DTOs preserve typed enum and import payload shapes" {
    const slash = try std.json.Stringify.valueAlloc(std.testing.allocator, SlashRunRequest{
        .provider = .codex,
        .project_path = "/tmp/project",
        .thread_id = "thread-1",
        .command = .custom,
        .raw_text = "/agents",
        .args = "",
    }, .{});
    defer std.testing.allocator.free(slash);
    try std.testing.expectEqualStrings(
        "{\"provider\":\"codex\",\"project_path\":\"/tmp/project\",\"thread_id\":\"thread-1\",\"command\":\"custom\",\"raw_text\":\"/agents\",\"args\":\"\"}",
        slash,
    );

    const images = [_]provider_types.ChatMessage{
        .{ .role = .user, .author = "You", .body = "import me" },
    };
    const result: ThreadReadResult = .{
        .provider = .codex,
        .thread = .{
            .thread_id = "thread-1",
            .title = "Imported",
            .messages = &images,
        },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, result, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(ThreadReadResult, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(provider_types.Provider.codex, parsed.value.provider);
    try std.testing.expectEqualStrings("import me", parsed.value.thread.messages[0].body);
}

test "provider thread control DTOs preserve turn identity and all images" {
    const attachments = [_]provider_types.ImageAttachment{
        .{ .path = "/tmp/one.png" },
        .{ .path = "/tmp/two.png" },
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, ThreadSteerRequest{
        .provider = .claude,
        .project_path = "/tmp/project",
        .thread_id = "thread-1",
        .turn_id = "turn-2",
        .prompt = "Use both images",
        .images = &attachments,
    }, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(ThreadSteerRequest, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(provider_types.Provider.claude, parsed.value.provider);
    try std.testing.expectEqualStrings("turn-2", parsed.value.turn_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.images.len);
    try std.testing.expectEqualStrings("/tmp/two.png", parsed.value.images[1].path);

    const result_encoded = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        ThreadControlResult{ .status = .unsupported },
        .{},
    );
    defer std.testing.allocator.free(result_encoded);
    try std.testing.expectEqualStrings("{\"status\":\"unsupported\"}", result_encoded);
}

test "integration DTOs retain distinct hook and eight-provider MCP surfaces" {
    const summary: McpSummary = .{
        .codex = .installed,
        .claude = .installed,
        .cursor = .installed,
        .opencode = .installed,
        .amp = .installed,
        .pi = .installed,
        .fx = .installed,
        .grok = .conflict,
    };
    try std.testing.expectEqual(@as(usize, 8), summary.detectedCount());
    try std.testing.expectEqual(@as(usize, 7), summary.installedCount());
    try std.testing.expectEqual(@as(usize, 1), summary.conflictCount());
    try std.testing.expectEqual(RegistrationStatus.installed, summary.forProvider(.fx));

    const hooks: ManagedHookStatus = .{ .pi = true };
    try std.testing.expect(hooks.forProvider(.pi));
    try std.testing.expect(!hooks.forProvider(.codex));
}

test "title generation request carries provider execution controls and exchange text" {
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, TitleGenerateRequest{
        .provider = .opencode,
        .model_ref = "openai/gpt-5",
        .reasoning_effort = .high,
        .reasoning_variant = "balanced",
        .fast = true,
        .access_mode = .supervised,
        .cwd = "/tmp/project",
        .user_text = "How do I fix this?",
        .assistant_text = "Use the typed daemon protocol.",
    }, .{});
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(TitleGenerateRequest, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(provider_types.Provider.opencode, parsed.value.provider);
    try std.testing.expectEqual(provider_types.ReasoningEffort.high, parsed.value.reasoning_effort.?);
    try std.testing.expectEqualStrings("balanced", parsed.value.reasoning_variant.?);
    try std.testing.expectEqualStrings("How do I fix this?", parsed.value.user_text);
}
