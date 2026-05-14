//! Shared provider-neutral types for native AI harnesses.

pub const Provider = enum(u8) {
    opencode,
    codex,
    claude,
    cursor,
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
    id: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,

    pub fn deinit(self: ChatMessage, allocator: anytype) void {
        allocator.free(self.author);
        allocator.free(self.body);
        if (self.id) |id| allocator.free(id);
        if (self.kind) |kind| allocator.free(kind);
        if (self.metadata_json) |metadata_json| allocator.free(metadata_json);
    }
};

pub const ImageAttachment = struct {
    path: []const u8,
};

pub const ChatThreadSummary = struct {
    id: []const u8,
    title: []const u8,
    runtime: ProviderRuntime = .local,
    status: ?[]const u8 = null,
    updated_at: ?i64 = null,
    metadata_json: ?[]const u8 = null,

    pub fn deinit(self: ChatThreadSummary, allocator: anytype) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.status) |status| allocator.free(status);
        if (self.metadata_json) |metadata_json| allocator.free(metadata_json);
    }
};

pub fn freeChatThreadSummaries(allocator: anytype, threads: []const ChatThreadSummary) void {
    for (threads) |thread| thread.deinit(allocator);
    allocator.free(threads);
}

pub const ProviderRuntime = enum(u8) {
    local,
    cloud,
};

pub const RepositoryInfo = struct {
    url: []const u8,

    pub fn deinit(self: RepositoryInfo, allocator: anytype) void {
        allocator.free(self.url);
    }
};

pub fn freeRepositoryInfos(allocator: anytype, repositories: []const RepositoryInfo) void {
    for (repositories) |repository| repository.deinit(allocator);
    allocator.free(repositories);
}

pub const ArtifactInfo = struct {
    path: []const u8,
    size_bytes: i64 = 0,
    updated_at: ?[]const u8 = null,

    pub fn deinit(self: ArtifactInfo, allocator: anytype) void {
        allocator.free(self.path);
        if (self.updated_at) |updated_at| allocator.free(updated_at);
    }
};

pub fn freeArtifactInfos(allocator: anytype, artifacts: []const ArtifactInfo) void {
    for (artifacts) |artifact| artifact.deinit(allocator);
    allocator.free(artifacts);
}

pub const DownloadArtifactResult = struct {
    path: []const u8,
    data: []const u8,

    pub fn deinit(self: DownloadArtifactResult, allocator: anytype) void {
        allocator.free(self.path);
        allocator.free(self.data);
    }
};

pub const RunSummary = struct {
    id: []const u8,
    agent_id: []const u8,
    status: ?[]const u8 = null,
    result: ?[]const u8 = null,
    model_json: ?[]const u8 = null,
    git_json: ?[]const u8 = null,
    duration_ms: ?i64 = null,
    created_at: ?i64 = null,

    pub fn deinit(self: RunSummary, allocator: anytype) void {
        allocator.free(self.id);
        allocator.free(self.agent_id);
        if (self.status) |status| allocator.free(status);
        if (self.result) |result| allocator.free(result);
        if (self.model_json) |model_json| allocator.free(model_json);
        if (self.git_json) |git_json| allocator.free(git_json);
    }
};

pub fn freeRunSummaries(allocator: anytype, runs: []const RunSummary) void {
    for (runs) |run| run.deinit(allocator);
    allocator.free(runs);
}

pub const AgentOperation = enum(u8) {
    archive,
    unarchive,
    delete,
};

pub const AgentOperationRequest = struct {
    thread_id: []const u8,
    operation: AgentOperation,
};

pub const ModelInfo = struct {
    provider_id: []const u8,
    provider_name: []const u8,
    model_id: []const u8,
    model_name: []const u8,
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
    updated_at: ?i64 = null,
    messages: []const ChatMessage,

    pub fn deinit(self: ReadThreadResult, allocator: anytype) void {
        allocator.free(self.thread_id);
        allocator.free(self.title);
        for (self.messages) |message| {
            message.deinit(allocator);
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

pub const StreamEvent = union(enum) {
    message: struct {
        title: []const u8,
        body: []const u8,
    },
    diff: struct {
        files: []const StreamDiffFile,
    },
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
    on_should_stop: ?*const fn (?*anyopaque) bool = null,
    on_approval_request: ?*const fn (?*anyopaque, ApprovalRequest) ApprovalDecision = null,
};

pub const SendPromptResult = struct {
    thread_id: []const u8,
    reply_text: []const u8,
};

pub const InterruptThreadRequest = struct {
    thread_id: []const u8,
    turn_id: ?[]const u8 = null,
};

pub const SteerThreadRequest = struct {
    thread_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
};
