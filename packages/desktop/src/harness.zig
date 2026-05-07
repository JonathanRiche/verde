//! Shared AI harness interface for native provider integrations.

const std = @import("std");
pub const types = @import("provider_types.zig");
const opencode = @import("providers/opencode.zig");
const codex = @import("providers/codex.zig");
const claude = @import("providers/claude.zig");

pub const Provider = types.Provider;
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
pub const StreamEvent = types.StreamEvent;
pub const SendPromptRequest = types.SendPromptRequest;
pub const SendPromptResult = types.SendPromptResult;
pub const InterruptThreadRequest = types.InterruptThreadRequest;
pub const SteerThreadRequest = types.SteerThreadRequest;
pub const freeModelInfos = types.freeModelInfos;

pub const ProviderConfig = union(Provider) {
    opencode: opencode.Config,
    codex: codex.Config,
    claude: claude.Config,
};

pub const ProviderClient = union(Provider) {
    opencode: opencode.Client,
    codex: codex.Client,
    claude: claude.Client,

    pub fn deinit(self: *ProviderClient) void {
        switch (self.*) {
            .opencode => |*client| client.deinit(),
            .codex => |*client| client.deinit(),
            .claude => |*client| client.deinit(),
        }
    }

    pub fn authState(self: *ProviderClient) !AuthState {
        return switch (self.*) {
            .opencode => |*client| client.authState(),
            .codex => |*client| client.authState(),
            .claude => |*client| client.authState(),
        };
    }

    pub fn listThreads(self: *ProviderClient, allocator: std.mem.Allocator) ![]ChatThreadSummary {
        return switch (self.*) {
            .opencode => |*client| client.listThreads(allocator),
            .codex => |*client| client.listThreads(allocator),
            .claude => |*client| client.listThreads(allocator),
        };
    }

    pub fn listModels(self: *ProviderClient, allocator: std.mem.Allocator) ![]ModelInfo {
        return switch (self.*) {
            .opencode => |*client| client.listModels(allocator),
            .codex => |*client| client.listModels(allocator),
            .claude => |*client| client.listModels(allocator),
        };
    }

    pub fn readThread(self: *ProviderClient, allocator: std.mem.Allocator, thread_id: []const u8) !ReadThreadResult {
        return switch (self.*) {
            .opencode => |*client| client.readThread(allocator, thread_id),
            .codex => |*client| client.readThread(allocator, thread_id),
            .claude => |*client| client.readThread(allocator, thread_id),
        };
    }

    pub fn sendPrompt(self: *ProviderClient, allocator: std.mem.Allocator, request: SendPromptRequest) !SendPromptResult {
        return switch (self.*) {
            .opencode => |*client| client.sendPrompt(allocator, request),
            .codex => |*client| client.sendPrompt(allocator, request),
            .claude => |*client| client.sendPrompt(allocator, request),
        };
    }

    pub fn interruptThread(self: *ProviderClient, request: InterruptThreadRequest) !void {
        return switch (self.*) {
            .opencode => |*client| client.interruptThread(request),
            .codex => |*client| client.interruptThread(request),
            .claude => |*client| client.interruptThread(request),
        };
    }

    pub fn steerThread(self: *ProviderClient, request: SteerThreadRequest) !void {
        return switch (self.*) {
            .opencode => |*client| client.steerThread(request),
            .codex => |*client| client.steerThread(request),
            .claude => |*client| client.steerThread(request),
        };
    }
};

pub fn connect(
    allocator: std.mem.Allocator,
    provider: ProviderConfig,
) !ProviderClient {
    return switch (provider) {
        .opencode => |config| .{ .opencode = try opencode.Client.init(allocator, config) },
        .codex => |config| .{ .codex = try codex.Client.init(allocator, config) },
        .claude => |config| .{ .claude = try claude.Client.init(allocator, config) },
    };
}

pub fn shutdownOwnedProviderProcesses() void {
    opencode.shutdownOwnedServer();
    codex.shutdownOwnedServer();
    claude.shutdownOwnedServer();
}
