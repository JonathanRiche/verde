//! Shared AI harness interface for native provider integrations.

const std = @import("std");
pub const types = @import("types.zig");
const opencode = @import("opencode.zig");
const codex = @import("codex.zig");
const claude = @import("claude.zig");
const cursor = @import("cursor.zig");
const pi = @import("pi.zig");
const fx = @import("fx.zig");
const grok = @import("grok.zig");
const runtime_log = @import("../runtime/log.zig");

pub const Provider = types.Provider;
pub const ProviderSlashCommandId = types.ProviderSlashCommandId;
pub const SlashCommandAvailability = types.SlashCommandAvailability;
pub const ProviderSlashCommand = types.ProviderSlashCommand;
pub const HarnessKind = types.HarnessKind;
pub const AuthState = types.AuthState;
pub const MessageRole = types.MessageRole;
pub const ChatMessage = types.ChatMessage;
pub const ChatThreadSummary = types.ChatThreadSummary;
pub const ModelInfo = types.ModelInfo;
pub const ReadThreadResult = types.ReadThreadResult;
pub const ReasoningEffort = types.ReasoningEffort;
pub const ApprovalPolicy = types.ApprovalPolicy;
pub const SandboxMode = types.SandboxMode;
pub const ServiceTier = types.ServiceTier;
pub const ApprovalDecision = types.ApprovalDecision;
pub const ApprovalRequest = types.ApprovalRequest;
pub const StreamDiffFile = types.StreamDiffFile;
pub const StreamDiffScope = types.StreamDiffScope;
pub const StreamDiffUpdate = types.StreamDiffUpdate;
pub const ToolCallKind = types.ToolCallKind;
pub const ToolCallStatus = types.ToolCallStatus;
pub const ToolCallUpdate = types.ToolCallUpdate;
pub const StreamEvent = types.StreamEvent;
pub const SendPromptRequest = types.SendPromptRequest;
pub const SendPromptResult = types.SendPromptResult;
pub const RunSlashCommandRequest = types.RunSlashCommandRequest;
pub const RunSlashCommandResult = types.RunSlashCommandResult;
pub const InterruptThreadRequest = types.InterruptThreadRequest;
pub const SteerThreadRequest = types.SteerThreadRequest;
pub const freeModelInfos = types.freeModelInfos;

pub const ProviderConfig = union(Provider) {
    opencode: opencode.Config,
    codex: codex.Config,
    claude: claude.Config,
    cursor: cursor.Config,
    pi: pi.Config,
    fx: fx.Config,
    grok: grok.Config,
};

pub const ProviderClient = union(Provider) {
    opencode: opencode.Client,
    codex: codex.Client,
    claude: claude.Client,
    cursor: cursor.Client,
    pi: pi.Client,
    fx: fx.Client,
    grok: grok.Client,

    pub fn deinit(self: *ProviderClient) void {
        switch (self.*) {
            .opencode => |*client| client.deinit(),
            .codex => |*client| client.deinit(),
            .claude => |*client| client.deinit(),
            .cursor => |*client| client.deinit(),
            .pi => |*client| client.deinit(),
            .fx => |*client| client.deinit(),
            .grok => |*client| client.deinit(),
        }
    }

    pub fn authState(self: *ProviderClient) !AuthState {
        return switch (self.*) {
            .opencode => |*client| client.authState(),
            .codex => |*client| client.authState(),
            .claude => |*client| client.authState(),
            .cursor => |*client| client.authState(),
            .pi => |*client| client.authState(),
            .fx => |*client| client.authState(),
            .grok => |*client| client.authState(),
        };
    }

    pub fn listThreads(self: *ProviderClient, allocator: std.mem.Allocator) ![]ChatThreadSummary {
        return switch (self.*) {
            .opencode => |*client| client.listThreads(allocator),
            .codex => |*client| client.listThreads(allocator),
            .claude => |*client| client.listThreads(allocator),
            .cursor => |*client| client.listThreads(allocator),
            .pi => |*client| client.listThreads(allocator),
            .fx => |*client| client.listThreads(allocator),
            .grok => |*client| client.listThreads(allocator),
        };
    }

    pub fn listModels(self: *ProviderClient, allocator: std.mem.Allocator) ![]ModelInfo {
        return switch (self.*) {
            .opencode => |*client| client.listModels(allocator),
            .codex => |*client| client.listModels(allocator),
            .claude => |*client| client.listModels(allocator),
            .cursor => |*client| client.listModels(allocator),
            .pi => |*client| client.listModels(allocator),
            .fx => |*client| client.listModels(allocator),
            .grok => |*client| client.listModels(allocator),
        };
    }

    pub fn readThread(self: *ProviderClient, allocator: std.mem.Allocator, thread_id: []const u8) !ReadThreadResult {
        return switch (self.*) {
            .opencode => |*client| client.readThread(allocator, thread_id),
            .codex => |*client| client.readThread(allocator, thread_id),
            .claude => |*client| client.readThread(allocator, thread_id),
            .cursor => |*client| client.readThread(allocator, thread_id),
            .pi => |*client| client.readThread(allocator, thread_id),
            .fx => |*client| client.readThread(allocator, thread_id),
            .grok => |*client| client.readThread(allocator, thread_id),
        };
    }

    pub fn sendPrompt(self: *ProviderClient, allocator: std.mem.Allocator, request: SendPromptRequest) !SendPromptResult {
        return switch (self.*) {
            .opencode => |*client| client.sendPrompt(allocator, request),
            .codex => |*client| client.sendPrompt(allocator, request),
            .claude => |*client| client.sendPrompt(allocator, request),
            .cursor => |*client| client.sendPrompt(allocator, request),
            .pi => |*client| client.sendPrompt(allocator, request),
            .fx => |*client| client.sendPrompt(allocator, request),
            .grok => |*client| client.sendPrompt(allocator, request),
        };
    }

    pub fn slashCommands(self: *ProviderClient) []const ProviderSlashCommand {
        return switch (self.*) {
            .opencode => |*client| client.slashCommands(),
            .codex => |*client| client.slashCommands(),
            .claude => |*client| client.slashCommands(),
            .cursor => |*client| client.slashCommands(),
            .pi => |*client| client.slashCommands(),
            .fx => |*client| client.slashCommands(),
            .grok => |*client| client.slashCommands(),
        };
    }

    pub fn runSlashCommand(self: *ProviderClient, allocator: std.mem.Allocator, request: RunSlashCommandRequest) !RunSlashCommandResult {
        return switch (self.*) {
            .opencode => |*client| client.runSlashCommand(allocator, request),
            .codex => |*client| client.runSlashCommand(allocator, request),
            .claude => |*client| client.runSlashCommand(allocator, request),
            .cursor => |*client| client.runSlashCommand(allocator, request),
            .pi => |*client| client.runSlashCommand(allocator, request),
            .fx => |*client| client.runSlashCommand(allocator, request),
            .grok => |*client| client.runSlashCommand(allocator, request),
        };
    }

    pub fn interruptThread(self: *ProviderClient, request: InterruptThreadRequest) !void {
        return switch (self.*) {
            .opencode => |*client| client.interruptThread(request),
            .codex => |*client| client.interruptThread(request),
            .claude => |*client| client.interruptThread(request),
            .cursor => |*client| client.interruptThread(request),
            .pi => |*client| client.interruptThread(request),
            .fx => |*client| client.interruptThread(request),
            .grok => |*client| client.interruptThread(request),
        };
    }

    pub fn terminateBackgroundTerminal(self: *ProviderClient, thread_id: []const u8, process_id: []const u8) !void {
        return switch (self.*) {
            .codex => |*client| client.terminateBackgroundTerminal(thread_id, process_id),
            else => error.UnsupportedOperation,
        };
    }

    pub fn backgroundTerminalIsRunning(self: *ProviderClient, thread_id: []const u8, process_id: []const u8) !bool {
        return switch (self.*) {
            .codex => |*client| client.backgroundTerminalIsRunning(thread_id, process_id),
            else => error.UnsupportedOperation,
        };
    }

    pub fn steerThread(self: *ProviderClient, request: SteerThreadRequest) !void {
        return switch (self.*) {
            .opencode => |*client| client.steerThread(request),
            .codex => |*client| client.steerThread(request),
            .claude => |*client| client.steerThread(request),
            .cursor => |*client| client.steerThread(request),
            .pi => |*client| client.steerThread(request),
            .fx => |*client| client.steerThread(request),
            .grok => |*client| client.steerThread(request),
        };
    }
};

pub fn slashCommandsForProvider(provider: Provider) []const ProviderSlashCommand {
    return switch (provider) {
        .opencode => opencode.providerSlashCommands(),
        .codex => codex.providerSlashCommands(),
        .claude => claude.providerSlashCommands(),
        .cursor => cursor.providerSlashCommands(),
        .pi => pi.providerSlashCommands(),
        .fx => fx.providerSlashCommands(),
        .grok => grok.providerSlashCommands(),
    };
}

pub fn connect(
    allocator: std.mem.Allocator,
    provider: ProviderConfig,
) !ProviderClient {
    return switch (provider) {
        .opencode => |config| .{ .opencode = try opencode.Client.init(allocator, config) },
        .codex => |config| .{ .codex = try codex.Client.init(allocator, config) },
        .claude => |config| .{ .claude = try claude.Client.init(allocator, config) },
        .cursor => |config| .{ .cursor = try cursor.Client.init(allocator, config) },
        .pi => |config| .{ .pi = try pi.Client.init(allocator, config) },
        .fx => |config| .{ .fx = try fx.Client.init(allocator, config) },
        .grok => |config| .{ .grok = try grok.Client.init(allocator, config) },
    };
}

pub fn shutdownOwnedProviderProcesses() void {
    runtime_log.diagnostic("provider shutdown begin opencode", .{});
    runtime_log.diagnostic("provider shutdown done opencode", .{});
    runtime_log.diagnostic("provider shutdown begin codex", .{});
    codex.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done codex", .{});
    runtime_log.diagnostic("provider shutdown begin claude", .{});
    claude.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done claude", .{});
    runtime_log.diagnostic("provider shutdown begin cursor", .{});
    cursor.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done cursor", .{});
    runtime_log.diagnostic("provider shutdown begin pi", .{});
    pi.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done pi", .{});
    runtime_log.diagnostic("provider shutdown begin fx", .{});
    fx.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done fx", .{});
    runtime_log.diagnostic("provider shutdown begin grok", .{});
    grok.shutdownOwnedServer();
    runtime_log.diagnostic("provider shutdown done grok", .{});
}

/// Stops a Codex app-server launched by this process so a durable send can
/// transfer server ownership to the session daemon.
pub fn releaseOwnedCodexServer() void {
    codex.shutdownOwnedServer();
}
