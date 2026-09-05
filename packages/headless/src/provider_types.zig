//! Shared provider-neutral types for AI provider protocols.

const std = @import("std");

pub const Provider = enum(u8) {
    opencode,
    codex,
    claude,
    cursor,
    pi,
    fx,
    grok,
    muse,
};

pub const ProviderSlashCommandId = enum(u8) {
    compact,
    goal,
    usage,
    review,
    shell,
    /// Provider-native slash command selected by its raw `/name` text.
    custom,
};

pub const SlashCommandAvailability = enum(u8) {
    available,
    disabled,
    unsupported,
};

pub const ProviderSlashCommand = struct {
    id: ProviderSlashCommandId,
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    requires_thread: bool,
    destructive_or_sensitive: bool = false,
    availability: SlashCommandAvailability = .available,
};

pub const HarnessKind = enum(u8) {
    local_cli,
    remote_session,
};

pub const AuthState = enum(u8) {
    unknown,
    signed_out,
    signed_in,
    pending,
};

pub const MessageRole = enum(u8) {
    system,
    user,
    assistant,
};

pub const ChatMessage = struct {
    role: MessageRole,
    author: []const u8,
    body: []const u8,
};

pub const ImageAttachment = struct {
    path: []const u8,
};

pub const ChatThreadSummary = struct {
    id: []const u8,
    title: []const u8,
};

pub const ModelInfo = struct {
    provider_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
    /// Catalog blurb shown in pickers; null when the provider omitted one.
    description: ?[]const u8 = null,
    /// From OpenCode model JSON `capabilities.reasoning` (defaults true when absent).
    reasoning_supported: bool = true,
    /// Sorted OpenCode `variants` object keys (API variant names). Null when none are declared.
    reasoning_variant_keys: ?[][:0]const u8 = null,
    cursor_fast_supported: bool = false,
    cursor_reasoning_param_id: ?[]const u8 = null,
    cursor_reasoning_values: ?[][:0]const u8 = null,
    cursor_reasoning_requires_thinking: bool = false,
    claude_effort_values: ?[]const [:0]const u8 = null,

    pub fn deinit(self: ModelInfo, allocator: anytype) void {
        allocator.free(self.provider_id);
        allocator.free(self.provider_name);
        allocator.free(self.model_id);
        allocator.free(self.model_name);
        if (self.description) |description| allocator.free(description);
        if (self.reasoning_variant_keys) |keys| {
            for (keys) |key| allocator.free(key);
            allocator.free(keys);
        }
        if (self.cursor_reasoning_param_id) |param_id| allocator.free(param_id);
        if (self.cursor_reasoning_values) |values| {
            for (values) |value| allocator.free(value);
            allocator.free(values);
        }
        if (self.claude_effort_values) |values| {
            for (values) |value| allocator.free(value);
            allocator.free(values);
        }
    }
};

pub fn freeModelInfos(allocator: anytype, models: []const ModelInfo) void {
    for (models) |model| model.deinit(allocator);
    allocator.free(models);
}

pub const ReadThreadResult = struct {
    thread_id: []const u8,
    title: []const u8,
    model_id: ?[]const u8 = null,
    updated_at: ?i64 = null,
    messages: []const ChatMessage,

    pub fn deinit(self: ReadThreadResult, allocator: anytype) void {
        allocator.free(self.thread_id);
        allocator.free(self.title);
        if (self.model_id) |model_id| allocator.free(model_id);
        for (self.messages) |message| {
            allocator.free(message.author);
            allocator.free(message.body);
        }
        allocator.free(self.messages);
    }
};

pub const ReasoningEffort = enum(u8) {
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const ApprovalPolicy = enum(u8) {
    on_request,
    never,
};

pub const SandboxMode = enum(u8) {
    workspace_write,
    danger_full_access,
};

pub const ServiceTier = enum(u8) {
    fast,
    flex,
};

pub const ApprovalDecision = enum(u8) {
    approve,
    deny,
};

pub const ApprovalRequest = struct {
    call_id: []const u8,
    title: []const u8,
    body: []const u8,
};

pub const StreamDiffFile = struct {
    path: []const u8,
    additions: i64,
    deletions: i64,
    patch: ?[]const u8 = null,
};

/// Identifies whether a streamed patch is one edit or the current whole-turn state.
pub const StreamDiffScope = enum(u8) {
    incremental,
    turn_snapshot,
};

/// File changes emitted during a provider turn.
pub const StreamDiffUpdate = struct {
    files: []const StreamDiffFile,
    scope: StreamDiffScope = .incremental,
};

pub const ToolCallKind = enum(u8) {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    mcp,
    other,
    /// Appended after `other` so existing SQLite integer codes stay stable.
    subagent,
};

/// Provider tool names that represent child-agent delegation, not a local tool.
pub fn isSubagentToolName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    return std.ascii.eqlIgnoreCase(trimmed, "task") or
        std.ascii.eqlIgnoreCase(trimmed, "agent") or
        std.ascii.eqlIgnoreCase(trimmed, "subagent") or
        std.ascii.eqlIgnoreCase(trimmed, "taskexecute") or
        std.ascii.eqlIgnoreCase(trimmed, "spawnagent") or
        std.ascii.eqlIgnoreCase(trimmed, "spawn_agent");
}

pub const ToolCallStatus = enum(u8) {
    pending,
    in_progress,
    completed,
    failed,
    cancelled,
    unknown,
};

/// Provider-neutral lifecycle update for one tool invocation.
///
/// All slices are borrowed for the duration of `on_stream_event`. Providers
/// should preserve a stable `call_id`; consumers use it to upsert one visible
/// call as start/update/completion events arrive.
pub const ToolCallUpdate = struct {
    call_id: []const u8,
    title: []const u8,
    kind: ?ToolCallKind = null,
    status: ?ToolCallStatus = null,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    error_text: ?[]const u8 = null,
    locations: ?[]const u8 = null,
    raw: ?[]const u8 = null,
};

pub const StreamEvent = union(enum) {
    message: struct {
        title: []const u8,
        body: []const u8,
    },
    tool_call: ToolCallUpdate,
    diff: StreamDiffUpdate,
};

pub const SendPromptRequest = struct {
    thread_id: ?[]const u8 = null,
    thread_title: ?[]const u8 = null,
    prompt: []const u8,
    image: ?ImageAttachment = null,
    images: []const ImageAttachment = &.{},
    cwd: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// When set (OpenCode), sent as the JSON `variant` string instead of mapping `reasoning_effort`.
    opencode_variant: ?[]const u8 = null,
    cursor_model_params_json: ?[]const u8 = null,
    reasoning_effort: ?ReasoningEffort = null,
    service_tier: ?ServiceTier = null,
    approval_policy: ?ApprovalPolicy = null,
    sandbox_mode: ?SandboxMode = null,
    stream_context: ?*anyopaque = null,
    on_thread_id: ?*const fn (?*anyopaque, []const u8) void = null,
    on_turn_id: ?*const fn (?*anyopaque, []const u8) void = null,
    on_stream_delta: ?*const fn (?*anyopaque, []const u8) void = null,
    on_stream_event: ?*const fn (?*anyopaque, StreamEvent) void = null,
    on_failure: ?*const fn (?*anyopaque, []const u8) void = null,
    on_should_stop: ?*const fn (?*anyopaque) bool = null,
    on_approval_request: ?*const fn (?*anyopaque, ApprovalRequest) ApprovalDecision = null,
};

pub const SendPromptResult = struct {
    thread_id: []const u8,
    reply_text: []const u8,
};

pub const RunSlashCommandRequest = struct {
    thread_id: ?[]const u8,
    cwd: ?[]const u8 = null,
    command: ProviderSlashCommandId,
    raw_text: []const u8,
    args: []const u8,
};

pub const RunSlashCommandResult = struct {
    handled: bool,
    thread_id: ?[]const u8 = null,
    notice: ?[]const u8 = null,
    transcript_title: ?[]const u8 = null,
    transcript_body: ?[]const u8 = null,

    /// Frees allocator-owned strings returned by provider command execution.
    pub fn deinit(self: RunSlashCommandResult, allocator: anytype) void {
        if (self.thread_id) |value| allocator.free(value);
        if (self.notice) |value| allocator.free(value);
        if (self.transcript_title) |value| allocator.free(value);
        if (self.transcript_body) |value| allocator.free(value);
    }
};

pub const InterruptThreadRequest = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
};

pub const SteerThreadRequest = struct {
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    images: []const ImageAttachment = &.{},
};

test "subagent tool names match delegation tools only" {
    try std.testing.expect(isSubagentToolName("task"));
    try std.testing.expect(isSubagentToolName("Agent"));
    try std.testing.expect(isSubagentToolName("TaskExecute"));
    try std.testing.expect(isSubagentToolName("spawnAgent"));
    try std.testing.expect(!isSubagentToolName("TaskCreate"));
    try std.testing.expect(!isSubagentToolName("bash"));
    try std.testing.expect(!isSubagentToolName(""));
}
