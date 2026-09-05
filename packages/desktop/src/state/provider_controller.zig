//! Provider readiness and asynchronous model-discovery controller state.

const std = @import("std");
const headless = @import("headless");
const app_config = @import("../app/config.zig");
const daemon_client = @import("../daemon/client.zig");
const loop_wakeup = @import("loop_wakeup");
const utils = @import("../utils.zig");
const chat_types = @import("chat_types.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");

const log = std.log.scoped(.native_shell);
const provider_types = headless.provider_types;
const Provider = provider_models.Provider;
const ModelOption = provider_models.ModelOption;
const ChatThread = chat_types.ChatThread;
const Mutex = state_sync.Mutex;
const CURSOR_MODEL_CACHE_FILE_NAME = "cursor-models.json";
const DEFAULT_CODEX_MODEL = provider_models.DEFAULT_CODEX_MODEL;
const DEFAULT_OPENCODE_MODEL = provider_models.DEFAULT_OPENCODE_MODEL;
const DEFAULT_CLAUDE_MODEL = provider_models.DEFAULT_CLAUDE_MODEL;
const DEFAULT_CURSOR_MODEL = provider_models.DEFAULT_CURSOR_MODEL;
const DEFAULT_PI_MODEL = provider_models.DEFAULT_PI_MODEL;
const DEFAULT_FX_MODEL = provider_models.DEFAULT_FX_MODEL;
const DEFAULT_GROK_MODEL = provider_models.DEFAULT_GROK_MODEL;
const DEFAULT_MUSE_MODEL = provider_models.DEFAULT_MUSE_MODEL;
const OPENCODE_MODEL_OPTIONS = provider_models.OPENCODE_MODEL_OPTIONS;
const PI_MODEL_OPTIONS = provider_models.PI_MODEL_OPTIONS;
const FX_MODEL_OPTIONS = provider_models.FX_MODEL_OPTIONS;
const GROK_MODEL_OPTIONS = provider_models.GROK_MODEL_OPTIONS;
const MUSE_MODEL_OPTIONS = provider_models.MUSE_MODEL_OPTIONS;
const CLAUDE_MODEL_OPTIONS = provider_models.CLAUDE_MODEL_OPTIONS;
const CURSOR_MODEL_OPTIONS = provider_models.CURSOR_MODEL_OPTIONS;
const CLAUDE_STANDARD_EFFORT_VALUES = provider_models.CLAUDE_STANDARD_EFFORT_VALUES;
const PersistedCursorModelOption = provider_models.PersistedCursorModelOption;
const cursorReasoningValueLabel = provider_models.cursorReasoningValueLabel;
const claudeEffortValueLabel = provider_models.claudeEffortValueLabel;
const parseReasoningEffort = provider_models.parseReasoningEffort;
const persistedCursorModelCacheNeedsRefresh = provider_models.persistedCursorModelCacheNeedsRefresh;

pub const OpencodeModelCacheStatus = enum {
    idle,
    pending,
    completed,
    failed,
};

pub const OpencodeModelCacheState = struct {
    mutex: Mutex = .{},
    status: OpencodeModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const CursorModelCacheStatus = OpencodeModelCacheStatus;

pub const CursorModelCacheState = struct {
    mutex: Mutex = .{},
    status: CursorModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const ClaudeModelCacheStatus = OpencodeModelCacheStatus;

pub const PiModelCacheStatus = OpencodeModelCacheStatus;

pub const PiModelCacheState = struct {
    mutex: Mutex = .{},
    status: PiModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const FxModelCacheStatus = OpencodeModelCacheStatus;

pub const FxModelCacheState = struct {
    mutex: Mutex = .{},
    status: FxModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const GrokModelCacheStatus = OpencodeModelCacheStatus;

pub const GrokModelCacheState = struct {
    mutex: Mutex = .{},
    status: GrokModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const MuseModelCacheStatus = OpencodeModelCacheStatus;

pub const MuseModelCacheState = struct {
    mutex: Mutex = .{},
    status: MuseModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const ClaudeModelCacheState = struct {
    mutex: Mutex = .{},
    status: ClaudeModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const ProviderReadiness = enum {
    checking,
    missing,
    signed_out,
    ready,
    unavailable,
};

pub const ProviderReadinessSnapshot = struct {
    codex: ProviderReadiness = .checking,
    opencode: ProviderReadiness = .checking,
    claude: ProviderReadiness = .checking,
    cursor: ProviderReadiness = .checking,
    pi: ProviderReadiness = .checking,
    fx: ProviderReadiness = .checking,
    grok: ProviderReadiness = .checking,
    muse: ProviderReadiness = .checking,

    pub fn forProvider(self: ProviderReadinessSnapshot, provider: Provider) ProviderReadiness {
        return switch (provider) {
            .codex => self.codex,
            .opencode => self.opencode,
            .claude => self.claude,
            .cursor => self.cursor,
            .pi => self.pi,
            .fx => self.fx,
            .grok => self.grok,
            .muse => self.muse,
        };
    }

    pub fn hasReadyProvider(self: ProviderReadinessSnapshot) bool {
        return self.codex == .ready or self.opencode == .ready or self.claude == .ready or self.cursor == .ready or self.pi == .ready or self.fx == .ready or self.grok == .ready or self.muse == .ready;
    }
};

pub const ProviderReadinessStatus = enum {
    idle,
    pending,
    completed,
};

pub const ProviderReadinessState = struct {
    mutex: Mutex = .{},
    status: ProviderReadinessStatus = .idle,
    snapshot: ProviderReadinessSnapshot = .{},
    worker: ?std.Thread = null,
};

pub const ProviderThreadOperationKind = enum {
    list,
    import_thread,
    sync_thread,
};

pub const ProviderThreadOperationRequest = struct {
    kind: ProviderThreadOperationKind,
    provider: Provider,
    project_index: usize,
    thread_index: ?usize,
    pref_path: []u8,
    project_path: []u8,
    thread_id: ?[]u8,

    pub fn deinit(self: *ProviderThreadOperationRequest) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.pref_path);
        allocator.free(self.project_path);
        if (self.thread_id) |thread_id| allocator.free(thread_id);
        allocator.destroy(self);
    }
};

pub const ProviderThreadOperationResult = union(enum) {
    list: []const provider_types.ChatThreadSummary,
    read: provider_types.ReadThreadResult,

    pub fn deinit(self: ProviderThreadOperationResult) void {
        const allocator = std.heap.page_allocator;
        switch (self) {
            .list => |threads| freeThreadSummaries(allocator, threads),
            .read => |thread| thread.deinit(allocator),
        }
    }
};

pub const ProviderThreadOperationStatus = enum {
    idle,
    pending,
    completed,
};

pub const ProviderThreadOperationState = struct {
    mutex: Mutex = .{},
    status: ProviderThreadOperationStatus = .idle,
    worker: ?std.Thread = null,
    request: ?*ProviderThreadOperationRequest = null,
    result: ?ProviderThreadOperationResult = null,
    failure: ?anyerror = null,
};

pub const State = struct {
    opencode_model_cache: OpencodeModelCacheState = .{},
    claude_model_cache: ClaudeModelCacheState = .{},
    cursor_model_cache: CursorModelCacheState = .{},
    pi_model_cache: PiModelCacheState = .{},
    fx_model_cache: FxModelCacheState = .{},
    grok_model_cache: GrokModelCacheState = .{},
    muse_model_cache: MuseModelCacheState = .{},
    readiness: ProviderReadinessState = .{},
    thread_operation: ProviderThreadOperationState = .{},
};

const ModelCacheWorkerRequest = struct {
    pref_path: []u8,
    project_path: []u8,

    fn deinit(self: ModelCacheWorkerRequest) void {
        std.heap.page_allocator.free(self.pref_path);
        std.heap.page_allocator.free(self.project_path);
    }
};

fn providerProtocolTag(provider: Provider) provider_types.Provider {
    return switch (provider) {
        .opencode => .opencode,
        .codex => .codex,
        .cursor => .cursor,
        .claude => .claude,
        .pi => .pi,
        .fx => .fx,
        .grok => .grok,
        .muse => .muse,
    };
}

fn providerDisplayName(provider: Provider) []const u8 {
    return switch (provider) {
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
        .claude => "Claude",
        .pi => "pi",
        .fx => "fx",
        .grok => "grok",
        .muse => "Muse",
    };
}

fn setProviderMcp(allocator: std.mem.Allocator, pref_path: []const u8, installed: bool) !headless.providers_protocol.McpSummary {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var transport: daemon_client.HeadlessTransport = .{ .allocator = arena.allocator(), .pref_path = pref_path };
    var client = daemon_client.headlessClient(arena.allocator(), &transport);
    var parsed = try client.callProviderMcpSet(headless.Capabilities.phase1(), .{ .installed = installed });
    defer parsed.deinit();
    return (try client.decodeProviderMcpSet(&parsed)).summary;
}

fn freeThreadSummaries(allocator: std.mem.Allocator, threads: []const provider_types.ChatThreadSummary) void {
    for (threads) |thread| {
        allocator.free(thread.id);
        allocator.free(thread.title);
    }
    allocator.free(threads);
}

fn runProviderThreadOperation(
    allocator: std.mem.Allocator,
    request: *const ProviderThreadOperationRequest,
) !ProviderThreadOperationResult {
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = request.pref_path,
    };
    var client = daemon_client.headlessClient(allocator, &transport);
    const protocol_provider = providerProtocolTag(request.provider);
    return switch (request.kind) {
        .list => blk: {
            var parsed = try client.callProviderThreadsList(headless.Capabilities.phase1(), .{
                .provider = protocol_provider,
                .project_path = request.project_path,
            });
            defer parsed.deinit();
            const response = try client.decodeProviderThreadsList(&parsed);
            if (response.provider != protocol_provider) {
                freeThreadSummaries(allocator, response.threads);
                return error.InvalidDaemonResponse;
            }
            break :blk .{ .list = response.threads };
        },
        .import_thread, .sync_thread => blk: {
            var parsed = try client.callProviderThreadRead(headless.Capabilities.phase1(), .{
                .provider = protocol_provider,
                .project_path = request.project_path,
                .thread_id = request.thread_id orelse return error.InvalidProviderThreadId,
            });
            defer parsed.deinit();
            const response = try client.decodeProviderThreadRead(&parsed);
            if (response.provider != protocol_provider) {
                response.thread.deinit(allocator);
                return error.InvalidDaemonResponse;
            }
            break :blk .{ .read = response.thread };
        },
    };
}

pub fn providerThreadOperationWorker(
    state: *ProviderThreadOperationState,
    request: *const ProviderThreadOperationRequest,
) void {
    const result = runProviderThreadOperation(std.heap.page_allocator, request);
    state.mutex.lock();
    defer state.mutex.unlock();
    if (result) |value| {
        state.result = value;
        state.failure = null;
    } else |err| {
        state.result = null;
        state.failure = err;
    }
    state.status = .completed;
    loop_wakeup.notify();
}

fn fetchProviderModels(provider: Provider, request: ModelCacheWorkerRequest) ?[]const provider_types.ModelInfo {
    defer request.deinit();
    const allocator = std.heap.page_allocator;
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = request.pref_path,
    };
    var client = daemon_client.headlessClient(allocator, &transport);
    const protocol_provider = providerProtocolTag(provider);
    var parsed = client.callProviderModelsList(headless.Capabilities.phase1(), .{
        .provider = protocol_provider,
        .project_path = request.project_path,
    }) catch |err| {
        log.warn("failed to request {s} models from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return null;
    };
    defer parsed.deinit();
    const result = client.decodeProviderModelsList(&parsed) catch |err| {
        log.warn("failed to decode {s} models from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return null;
    };
    if (result.provider != protocol_provider) {
        provider_types.freeModelInfos(allocator, result.models);
        log.warn("daemon returned the wrong provider model catalog for {s}", .{providerDisplayName(provider)});
        return null;
    }
    return result.models;
}

fn runModelCacheWorker(state: anytype, provider: Provider, request: ModelCacheWorkerRequest) void {
    const models = fetchProviderModels(provider, request);
    state.mutex.lock();
    defer state.mutex.unlock();
    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

/// Requests pi's dynamic model catalog through the session daemon.
pub fn piModelCacheWorker(state: *PiModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .pi, request);
}

/// Requests fx's dynamic model catalog through the session daemon.
pub fn fxModelCacheWorker(state: *FxModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .fx, request);
}

/// Requests grok's dynamic model catalog through the session daemon.
pub fn grokModelCacheWorker(state: *GrokModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .grok, request);
}

pub fn museModelCacheWorker(state: *MuseModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .muse, request);
}

const ProviderReadinessWorkerRequest = struct {
    pref_path: []u8,
    project_path: []u8,

    fn deinit(self: ProviderReadinessWorkerRequest) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.pref_path);
        allocator.free(self.project_path);
    }
};

fn fetchProviderReadiness(
    client: anytype,
    provider: Provider,
    project_path: []const u8,
) ProviderReadiness {
    var parsed = client.callProviderAuthStatus(headless.Capabilities.phase1(), .{
        .provider = providerProtocolTag(provider),
        .project_path = project_path,
    }) catch |err| {
        log.warn("failed to request {s} readiness from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return .unavailable;
    };
    defer parsed.deinit();
    const result = client.decodeProviderAuthStatus(&parsed) catch |err| {
        log.warn("failed to decode {s} readiness from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return .unavailable;
    };
    if (result.provider != providerProtocolTag(provider)) return .unavailable;
    if (!result.installed) return .missing;
    if (result.ready) return .ready;
    return switch (result.auth_state) {
        .signed_out => .signed_out,
        .signed_in => .ready,
        .unknown, .pending => .unavailable,
    };
}

pub fn providerReadinessWorker(state: *ProviderReadinessState, request: ProviderReadinessWorkerRequest) void {
    defer request.deinit();
    const allocator = std.heap.page_allocator;
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = request.pref_path,
    };
    var client = daemon_client.headlessClient(allocator, &transport);
    const snapshot: ProviderReadinessSnapshot = .{
        .codex = fetchProviderReadiness(&client, .codex, request.project_path),
        .opencode = fetchProviderReadiness(&client, .opencode, request.project_path),
        .claude = fetchProviderReadiness(&client, .claude, request.project_path),
        .cursor = fetchProviderReadiness(&client, .cursor, request.project_path),
        .pi = fetchProviderReadiness(&client, .pi, request.project_path),
        .fx = fetchProviderReadiness(&client, .fx, request.project_path),
        .grok = fetchProviderReadiness(&client, .grok, request.project_path),
        .muse = fetchProviderReadiness(&client, .muse, request.project_path),
    };

    state.mutex.lock();
    defer state.mutex.unlock();
    state.snapshot = snapshot;
    state.status = .completed;
}

pub fn opencodeModelCacheWorker(state: *OpencodeModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .opencode, request);
}

pub fn cursorModelCacheWorker(state: *CursorModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .cursor, request);
}

pub fn claudeModelCacheWorker(state: *ClaudeModelCacheState, request: ModelCacheWorkerRequest) void {
    runModelCacheWorker(state, .claude, request);
}

pub fn opencodeModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.opencode_model_options.items.len > 0)
        self.opencode_model_options.items
    else
        OPENCODE_MODEL_OPTIONS[0..];
}

pub fn claudeModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.claude_model_options.items.len > 0)
        self.claude_model_options.items
    else
        CLAUDE_MODEL_OPTIONS[0..];
}

pub fn piModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.pi_model_options.items.len > 0)
        self.pi_model_options.items
    else
        PI_MODEL_OPTIONS[0..];
}

pub fn fxModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.fx_model_options.items.len > 0)
        self.fx_model_options.items
    else
        FX_MODEL_OPTIONS[0..];
}

pub fn grokModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.grok_model_options.items.len > 0)
        self.grok_model_options.items
    else
        GROK_MODEL_OPTIONS[0..];
}

pub fn museModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.muse_model_options.items.len > 0)
        self.muse_model_options.items
    else
        MUSE_MODEL_OPTIONS[0..];
}

pub fn cursorModelOptionsSnapshot(self: anytype) []const ModelOption {
    return if (self.cursor_model_options.items.len > 0)
        self.cursor_model_options.items
    else
        CURSOR_MODEL_OPTIONS[0..];
}

pub fn cachedDefaultModelRefForProvider(self: anytype, provider: Provider) [:0]const u8 {
    return switch (provider) {
        .codex => DEFAULT_CODEX_MODEL,
        .claude => DEFAULT_CLAUDE_MODEL,
        .cursor => DEFAULT_CURSOR_MODEL,
        .pi => DEFAULT_PI_MODEL,
        .fx => DEFAULT_FX_MODEL,
        .grok => DEFAULT_GROK_MODEL,
        .muse => DEFAULT_MUSE_MODEL,
        .opencode => blk: {
            for (self.opencodeModelOptionsSnapshot()) |option| {
                if (option.value) |value| break :blk value;
            }
            break :blk DEFAULT_OPENCODE_MODEL;
        },
    };
}

pub fn startOpencodeModelOptionsRefresh(self: anytype) void {
    self.refreshOpencodeModelOptionsCacheAsync();
}

pub fn startCursorModelOptionsRefresh(self: anytype) void {
    self.refreshCursorModelOptionsCacheAsync();
}

pub fn startClaudeModelOptionsRefresh(self: anytype) void {
    self.refreshClaudeModelOptionsCacheAsync();
}

pub fn startPiModelOptionsRefresh(self: anytype) void {
    self.refreshPiModelOptionsCacheAsync();
}

pub fn startFxModelOptionsRefresh(self: anytype) void {
    self.refreshFxModelOptionsCacheAsync();
}

pub fn startGrokModelOptionsRefresh(self: anytype) void {
    self.refreshGrokModelOptionsCacheAsync();
}

pub fn startMuseModelOptionsRefresh(self: anytype) void {
    self.refreshMuseModelOptionsCacheAsync();
}

pub fn startProviderReadinessCheck(self: anytype) void {
    self.pollProviderReadiness();

    self.provider_controller.readiness.mutex.lock();
    defer self.provider_controller.readiness.mutex.unlock();
    if (self.provider_controller.readiness.status == .pending) return;

    const allocator = std.heap.page_allocator;
    const pref_path = allocator.dupe(u8, self.storage.pref_path) catch return;
    const project_path = if (self.project_controller.projects.items.len > 0 and
        self.project_controller.selected_index < self.project_controller.projects.items.len)
        self.project_controller.projects.items[self.project_controller.selected_index].path
    else
        "";
    const owned_project_path = allocator.dupe(u8, project_path) catch {
        allocator.free(pref_path);
        return;
    };
    const request: ProviderReadinessWorkerRequest = .{
        .pref_path = pref_path,
        .project_path = owned_project_path,
    };

    self.provider_controller.readiness.status = .pending;
    self.provider_controller.readiness.snapshot = .{};
    self.provider_controller.readiness.worker = std.Thread.spawn(.{}, providerReadinessWorker, .{
        &self.provider_controller.readiness,
        request,
    }) catch {
        request.deinit();
        self.provider_controller.readiness.status = .completed;
        self.provider_controller.readiness.snapshot = .{
            .codex = .unavailable,
            .opencode = .unavailable,
            .claude = .unavailable,
            .cursor = .unavailable,
        };
        return;
    };
    self.markDirty();
}

/// Completes the one-time MCP onboarding choice. Enabling registers Verde
/// in every detected provider's user config; declining makes no external
/// changes and remains reversible from Settings.
pub fn completeMcpOnboarding(self: anytype, enable: bool) void {
    if (enable) {
        const summary = setProviderMcp(self.allocator, self.storage.pref_path, true) catch |err| {
            log.warn("failed to install provider MCP registrations: {s}", .{@errorName(err)});
            self.setSidebarNotice("Could not enable Verde MCP tools.");
            self.markDirty();
            return;
        };
        self.settings_controller.mcp_summary = summary;
        if (summary.detectedCount() == 0) {
            self.setSidebarNotice("No supported agent providers were detected.");
            self.markDirty();
            return;
        }
        self.app_config.mcp_integration_enabled = summary.installedCount() > 0;
        if (summary.failedCount() > 0) {
            self.setSidebarNotice("Enabled Verde MCP where possible; some provider configs could not be updated.");
        } else if (summary.conflictCount() > 0) {
            self.setSidebarNotice("Enabled Verde MCP where possible; an existing 'verde' entry was preserved.");
        } else {
            self.setSidebarNotice("Enabled Verde tools in detected agent providers.");
        }
    } else {
        self.app_config.mcp_integration_enabled = false;
        self.setSidebarNotice("Verde MCP tools were not enabled. You can enable them in Settings.");
    }

    self.app_config.mcp_onboarding_completed = true;
    app_config.saveAppConfig(self.allocator, &self.app_config) catch |err| {
        log.warn("failed to persist MCP onboarding choice: {s}", .{@errorName(err)});
        self.setSidebarNotice("MCP choice applied, but could not save Verde settings.");
    };
    self.settings_controller.mcp_onboarding_visible = false;
    self.markDirty();
}

pub fn pollProviderReadiness(self: anytype) void {
    self.pollProviderThreadOperation();
    self.pollProviderSlashCatalog();
    var completed = false;
    var snapshot: ProviderReadinessSnapshot = .{};

    self.provider_controller.readiness.mutex.lock();
    if (self.provider_controller.readiness.status == .completed) {
        snapshot = self.provider_controller.readiness.snapshot;
        self.provider_controller.readiness.status = .idle;
        completed = true;
    }
    self.provider_controller.readiness.mutex.unlock();
    if (!completed) return;

    self.finishProviderReadinessThread();
    if (snapshot.hasReadyProvider()) {
        self.settings_controller.provider_onboarding_visible = false;
        self.settings_controller.provider_onboarding_dismissed = false;
    } else if (!self.settings_controller.provider_onboarding_dismissed) {
        self.settings_controller.provider_onboarding_visible = true;
    }
    self.settings_controller.mcp_onboarding_visible = !self.app_config.mcp_onboarding_completed;
    if (self.settings_controller.mcp_onboarding_visible) self.blurPaletteComposer();
    self.markDirty();
}

pub fn providerReadinessSnapshot(self: anytype) ProviderReadinessSnapshot {
    self.provider_controller.readiness.mutex.lock();
    defer self.provider_controller.readiness.mutex.unlock();
    return self.provider_controller.readiness.snapshot;
}

pub fn dismissProviderOnboarding(self: anytype) void {
    self.settings_controller.provider_onboarding_visible = false;
    self.settings_controller.provider_onboarding_dismissed = true;
    self.markDirty();
}

pub fn recheckProviderReadiness(self: anytype) void {
    self.settings_controller.provider_onboarding_visible = true;
    self.settings_controller.provider_onboarding_dismissed = false;
    self.startProviderReadinessCheck();
}

pub fn openProviderSetupGuide(self: anytype) void {
    utils.openUrlInDefaultBrowser(self.allocator, "https://verdeai.dev/docs/providers") catch |err| {
        log.warn("failed to open provider setup guide: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not open the provider setup guide.");
        return;
    };
    self.setSidebarNotice("Opened provider setup guide.");
}

fn createModelCacheWorkerRequest(self: anytype) ?ModelCacheWorkerRequest {
    if (self.project_controller.projects.items.len == 0 or
        self.project_controller.selected_index >= self.project_controller.projects.items.len)
    {
        return null;
    }
    const allocator = std.heap.page_allocator;
    const pref_path = allocator.dupe(u8, self.storage.pref_path) catch return null;
    const project_path = allocator.dupe(
        u8,
        self.project_controller.projects.items[self.project_controller.selected_index].path,
    ) catch {
        allocator.free(pref_path);
        return null;
    };
    return .{
        .pref_path = pref_path,
        .project_path = project_path,
    };
}

fn spawnModelCacheWorker(self: anytype, comptime worker: anytype, state: anytype) ?std.Thread {
    const request = createModelCacheWorkerRequest(self) orelse return null;
    return std.Thread.spawn(.{}, worker, .{ state, request }) catch {
        request.deinit();
        return null;
    };
}

pub fn refreshOpencodeModelOptionsCacheAsync(self: anytype) void {
    self.pollOpencodeModelOptionsCache();

    self.provider_controller.opencode_model_cache.mutex.lock();
    defer self.provider_controller.opencode_model_cache.mutex.unlock();
    if (self.provider_controller.opencode_model_cache.status == .pending) return;

    self.provider_controller.opencode_model_cache.status = .pending;
    self.provider_controller.opencode_model_cache.worker = spawnModelCacheWorker(
        self,
        opencodeModelCacheWorker,
        &self.provider_controller.opencode_model_cache,
    ) orelse {
        self.provider_controller.opencode_model_cache.status = .idle;
        return;
    };
}

pub fn refreshCursorModelOptionsCacheAsync(self: anytype) void {
    self.pollCursorModelOptionsCache();

    self.provider_controller.cursor_model_cache.mutex.lock();
    defer self.provider_controller.cursor_model_cache.mutex.unlock();
    if (self.provider_controller.cursor_model_cache.status == .pending) return;

    self.provider_controller.cursor_model_cache.status = .pending;
    self.provider_controller.cursor_model_cache.worker = spawnModelCacheWorker(
        self,
        cursorModelCacheWorker,
        &self.provider_controller.cursor_model_cache,
    ) orelse {
        self.provider_controller.cursor_model_cache.status = .idle;
        return;
    };
}

pub fn refreshClaudeModelOptionsCacheAsync(self: anytype) void {
    self.pollClaudeModelOptionsCache();

    self.provider_controller.claude_model_cache.mutex.lock();
    defer self.provider_controller.claude_model_cache.mutex.unlock();
    if (self.provider_controller.claude_model_cache.status == .pending) return;

    self.provider_controller.claude_model_cache.status = .pending;
    self.provider_controller.claude_model_cache.worker = spawnModelCacheWorker(
        self,
        claudeModelCacheWorker,
        &self.provider_controller.claude_model_cache,
    ) orelse {
        self.provider_controller.claude_model_cache.status = .idle;
        log.warn("failed to spawn Claude model cache worker", .{});
        return;
    };
}

pub fn refreshPiModelOptionsCacheAsync(self: anytype) void {
    self.pollPiModelOptionsCache();

    self.provider_controller.pi_model_cache.mutex.lock();
    defer self.provider_controller.pi_model_cache.mutex.unlock();
    if (self.provider_controller.pi_model_cache.status == .pending) return;

    self.provider_controller.pi_model_cache.status = .pending;
    self.provider_controller.pi_model_cache.worker = spawnModelCacheWorker(
        self,
        piModelCacheWorker,
        &self.provider_controller.pi_model_cache,
    ) orelse {
        self.provider_controller.pi_model_cache.status = .idle;
        log.warn("failed to spawn pi model cache worker", .{});
        return;
    };
}

pub fn refreshFxModelOptionsCacheAsync(self: anytype) void {
    self.pollFxModelOptionsCache();

    self.provider_controller.fx_model_cache.mutex.lock();
    defer self.provider_controller.fx_model_cache.mutex.unlock();
    if (self.provider_controller.fx_model_cache.status == .pending) return;

    self.provider_controller.fx_model_cache.status = .pending;
    self.provider_controller.fx_model_cache.worker = spawnModelCacheWorker(
        self,
        fxModelCacheWorker,
        &self.provider_controller.fx_model_cache,
    ) orelse {
        self.provider_controller.fx_model_cache.status = .idle;
        log.warn("failed to spawn fx model cache worker", .{});
        return;
    };
}

pub fn refreshGrokModelOptionsCacheAsync(self: anytype) void {
    self.pollGrokModelOptionsCache();

    self.provider_controller.grok_model_cache.mutex.lock();
    defer self.provider_controller.grok_model_cache.mutex.unlock();
    if (self.provider_controller.grok_model_cache.status == .pending) return;

    self.provider_controller.grok_model_cache.status = .pending;
    self.provider_controller.grok_model_cache.worker = spawnModelCacheWorker(
        self,
        grokModelCacheWorker,
        &self.provider_controller.grok_model_cache,
    ) orelse {
        self.provider_controller.grok_model_cache.status = .idle;
        log.warn("failed to spawn grok model cache worker", .{});
        return;
    };
}

pub fn refreshMuseModelOptionsCacheAsync(self: anytype) void {
    self.pollMuseModelOptionsCache();

    self.provider_controller.muse_model_cache.mutex.lock();
    defer self.provider_controller.muse_model_cache.mutex.unlock();
    if (self.provider_controller.muse_model_cache.status == .pending) return;

    self.provider_controller.muse_model_cache.status = .pending;
    self.provider_controller.muse_model_cache.worker = spawnModelCacheWorker(
        self,
        museModelCacheWorker,
        &self.provider_controller.muse_model_cache,
    ) orelse {
        self.provider_controller.muse_model_cache.status = .idle;
        log.warn("failed to spawn muse model cache worker", .{});
        return;
    };
}

pub fn duplicateReasoningVariantKeys(allocator: std.mem.Allocator, src: ?[]const [:0]const u8) !?[][:0]const u8 {
    const keys = src orelse return null;
    if (keys.len == 0) return null;
    const out = try allocator.alloc([:0]const u8, keys.len);
    errdefer {
        for (out) |k| allocator.free(k);
        allocator.free(out);
    }
    for (keys, 0..) |k, i| {
        out[i] = try allocator.dupeZ(u8, k);
    }
    return out;
}

pub fn populateOpencodeModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    var order = try self.allocator.alloc(usize, models.len);
    defer self.allocator.free(order);
    for (0..models.len) |i| order[i] = i;

    var sort_i: usize = 1;
    while (sort_i < order.len) : (sort_i += 1) {
        const cur_idx = order[sort_i];
        var j = sort_i;
        while (j > 0 and opencodeModelSortLessThan(models[cur_idx], models[order[j - 1]])) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = cur_idx;
    }

    // Preset `opencode/…` routes first when the API list omits them (common when only one vendor
    // is configured). Skip a preset when any API row already exposes the same model id so we do
    // not list two entries for the same model (e.g. `openai/gpt-5.4` vs `opencode/gpt-5.4`).
    for (OPENCODE_MODEL_OPTIONS) |preset| {
        const preset_value = preset.value orelse continue;
        const preset_model_id = opencodeModelIdSuffixFromRef(preset_value) orelse continue;
        if (opencodeSortedModelsContainModelIdFromOrder(order, models, preset_model_id)) continue;

        const preset_label = try self.allocator.dupeZ(u8, preset.label);
        errdefer self.allocator.free(preset_label);
        const preset_value_copy = try self.allocator.dupeZ(u8, preset_value);
        errdefer self.allocator.free(preset_value_copy);
        const preset_keys = try duplicateReasoningVariantKeys(self.allocator, preset.reasoning_variant_keys);
        errdefer if (preset_keys) |pk| {
            for (pk) |k| self.allocator.free(k);
            self.allocator.free(pk);
        };
        try self.opencode_model_options.append(self.allocator, .{
            .label = preset_label,
            .value = preset_value_copy,
            .reasoning_supported = preset.reasoning_supported,
            .reasoning_variant_keys = preset_keys,
        });
    }

    for (order) |mi| {
        const model = models[mi];
        const model_name = if (model.model_name.len > 0) model.model_name else model.model_id;
        const provider_name = if (model.provider_name.len > 0) model.provider_name else model.provider_id;
        const label_text = try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ model_name, provider_name });
        defer self.allocator.free(label_text);
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);

        const value_text = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider_id, model.model_id });
        defer self.allocator.free(value_text);
        const value = try self.allocator.dupeZ(u8, value_text);
        errdefer self.allocator.free(value);

        const keys = try duplicateReasoningVariantKeys(self.allocator, model.reasoning_variant_keys);
        errdefer if (keys) |k| {
            for (k) |x| self.allocator.free(x);
            self.allocator.free(k);
        };

        try self.opencode_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = model.reasoning_supported,
            .reasoning_variant_keys = keys,
        });
    }
}

pub fn opencodeModelIdSuffixFromRef(model_ref: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, model_ref, '/') orelse return null;
    if (slash + 1 >= model_ref.len) return null;
    return model_ref[slash + 1 ..];
}

pub fn opencodeSortedModelsContainModelIdFromOrder(order: []const usize, model_list: []const provider_types.ModelInfo, model_id: []const u8) bool {
    for (order) |mi| {
        if (std.mem.eql(u8, model_list[mi].model_id, model_id)) return true;
    }
    return false;
}

pub fn opencodeModelSortLessThan(a: provider_types.ModelInfo, b: provider_types.ModelInfo) bool {
    const provider_name_a = if (a.provider_name.len > 0) a.provider_name else a.provider_id;
    const provider_name_b = if (b.provider_name.len > 0) b.provider_name else b.provider_id;
    const provider_cmp = asciiCaseInsensitiveCompare(provider_name_a, provider_name_b);
    if (provider_cmp != .eq) return provider_cmp == .lt;

    const model_name_a = if (a.model_name.len > 0) a.model_name else a.model_id;
    const model_name_b = if (b.model_name.len > 0) b.model_name else b.model_id;
    const model_cmp = asciiCaseInsensitiveCompare(model_name_a, model_name_b);
    if (model_cmp != .eq) return model_cmp == .lt;

    const provider_id_cmp = asciiCaseInsensitiveCompare(a.provider_id, b.provider_id);
    if (provider_id_cmp != .eq) return provider_id_cmp == .lt;

    return asciiCaseInsensitiveCompare(a.model_id, b.model_id) == .lt;
}

pub fn populateCursorModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        const reasoning_param_id = if (model.cursor_reasoning_param_id) |param_id| try self.allocator.dupeZ(u8, param_id) else null;
        errdefer if (reasoning_param_id) |param_id| self.allocator.free(param_id);
        const cursor_reasoning_values = try duplicateReasoningVariantKeys(self.allocator, model.cursor_reasoning_values);
        errdefer if (cursor_reasoning_values) |values| {
            for (values) |reasoning_value| self.allocator.free(reasoning_value);
            self.allocator.free(values);
        };

        try self.cursor_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = model.reasoning_supported,
            .cursor_fast_supported = model.cursor_fast_supported,
            .cursor_reasoning_param_id = reasoning_param_id,
            .cursor_reasoning_values = cursor_reasoning_values,
            .cursor_reasoning_requires_thinking = model.cursor_reasoning_requires_thinking,
        });
    }
}

pub fn populateClaudeModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        const effort_values = try duplicateReasoningVariantKeys(self.allocator, model.claude_effort_values);
        errdefer if (effort_values) |values| {
            for (values) |effort_value| self.allocator.free(effort_value);
            self.allocator.free(values);
        };

        try self.claude_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = model.reasoning_supported,
            .claude_effort_values = effort_values,
        });
    }
}

/// Rebuilds the pi picker from `get_available_models`. The "Default (pi
/// config)" row stays first so users can keep deferring to pi's own config.
pub fn populatePiModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    try appendDefaultModelOption(self, &self.pi_model_options, PI_MODEL_OPTIONS[0]);
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        try self.pi_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = model.reasoning_supported,
        });
    }
}

/// Rebuilds the fx picker from the ACP `model` configOption. The "Default (fx
/// config)" row stays first so users can keep deferring to fx's own config.
pub fn populateFxModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    try appendDefaultModelOption(self, &self.fx_model_options, FX_MODEL_OPTIONS[0]);
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        try self.fx_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = false,
        });
    }
}

/// Rebuilds the grok picker from the initialize `modelState` catalog. The
/// "Default (grok config)" row stays first so users can keep deferring to
/// grok's own persisted selection; every grok model supports reasoning effort.
pub fn populateGrokModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    try appendDefaultModelOption(self, &self.grok_model_options, GROK_MODEL_OPTIONS[0]);
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        try self.grok_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = true,
        });
    }
}

/// Rebuilds the Muse picker from MSP `model/list`. Labels stay the catalog
/// `displayLabel` so the GUI matches the TUI; descriptions stay on the row,
/// not the composer pill.
pub fn populateMuseModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        const description = if (model.description) |text|
            if (text.len > 0) try self.allocator.dupeZ(u8, text) else null
        else
            null;
        errdefer if (description) |owned| self.allocator.free(owned);
        try self.muse_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .description = description,
            .reasoning_supported = true,
        });
    }
}

// Dynamic rows own their strings, so the static default row is copied rather
// than referenced to keep the clear path uniform.
fn appendDefaultModelOption(self: anytype, list: *std.ArrayList(ModelOption), template: ModelOption) !void {
    const label = try self.allocator.dupeZ(u8, template.label);
    errdefer self.allocator.free(label);
    const value = if (template.value) |v| try self.allocator.dupeZ(u8, v) else null;
    errdefer if (value) |v| self.allocator.free(v);
    const description = if (template.description) |text| try self.allocator.dupeZ(u8, text) else null;
    errdefer if (description) |owned| self.allocator.free(owned);
    try list.append(self.allocator, .{
        .label = label,
        .value = value,
        .description = description,
        .reasoning_supported = template.reasoning_supported,
    });
}

pub fn asciiCaseInsensitiveCompare(a: []const u8, b: []const u8) std.math.Order {
    var index: usize = 0;
    const min_len = @min(a.len, b.len);
    while (index < min_len) : (index += 1) {
        const lhs = std.ascii.toLower(a[index]);
        const rhs = std.ascii.toLower(b[index]);
        if (lhs < rhs) return .lt;
        if (lhs > rhs) return .gt;
    }
    if (a.len < b.len) return .lt;
    if (a.len > b.len) return .gt;
    return .eq;
}

pub fn normalizeCurrentOpencodeThreadModel(self: anytype) void {
    if (self.project_controller.projects.items.len == 0) return;
    if (self.opencode_model_options.items.len == 0) return;

    const thread = self.currentThreadMutable();
    if (thread.provider != .opencode) return;

    const fallback_model_ref = blk: {
        for (self.opencode_model_options.items) |option| {
            if (option.value) |value| break :blk value;
        }
        return;
    };

    if (thread.model_ref) |model_ref| {
        for (self.opencode_model_options.items) |option| {
            if (option.value) |value| {
                if (std.mem.eql(u8, model_ref, value)) {
                    self.normalizeOpencodeReasoningVariant(thread);
                    return;
                }
            }
        }
        self.allocator.free(model_ref);
    }

    thread.model_ref = self.allocator.dupeZ(u8, fallback_model_ref) catch null;
    self.normalizeOpencodeReasoningVariant(thread);
    self.markDirty();
}

pub fn opencodeModelOptionForRef(self: anytype, model_ref: ?[:0]const u8) ?ModelOption {
    const ref = model_ref orelse return null;
    for (self.opencode_model_options.items) |opt| {
        if (opt.value) |v| {
            if (std.mem.eql(u8, ref, v)) return opt;
        }
    }
    return null;
}

pub fn refreshOpencodeReasoningMenu(self: anytype, thread: *const ChatThread) !void {
    self.clearOpencodeReasoningMenu();
    errdefer self.clearOpencodeReasoningMenu();

    if (thread.provider == .cursor) return self.refreshCursorReasoningMenu(thread);
    if (thread.provider == .claude) return self.refreshClaudeReasoningMenu(thread);
    if (thread.provider == .pi) return self.refreshPiReasoningMenu();
    if (thread.provider == .grok) return self.refreshGrokReasoningMenu();
    if (thread.provider == .muse) return self.refreshMuseReasoningMenu();
    if (thread.provider != .opencode) return;
    const opt = self.opencodeModelOptionForRef(thread.model_ref) orelse return;
    if (!opt.reasoning_supported) return;
    const keys = opt.reasoning_variant_keys orelse return;
    if (keys.len == 0) return;

    const default_label = try self.allocator.dupeZ(u8, "Default");
    try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

    for (keys) |key| {
        const label = try self.allocator.dupeZ(u8, key);
        const variant_copy = try self.allocator.dupeZ(u8, key);
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
    }
}

pub fn refreshCursorReasoningMenu(self: anytype, thread: *const ChatThread) !void {
    const opt = self.cursorModelOptionForRef(thread.model_ref) orelse return;
    const values = opt.cursor_reasoning_values orelse return;
    if (values.len == 0) return;

    const default_label = try self.allocator.dupeZ(u8, "Default");
    try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

    for (values) |value| {
        const label_text = cursorReasoningValueLabel(value);
        const label = try self.allocator.dupeZ(u8, label_text);
        const variant_copy = try self.allocator.dupeZ(u8, value);
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
    }
}

/// Pi accepts every Verde effort tag; the menu mirrors PI_REASONING_OPTIONS
/// with effort tag names as row variants (the shared claude/pi selection
/// handler parses them back into reasoning_effort).
pub fn refreshPiReasoningMenu(self: anytype) !void {
    for (provider_models.PI_REASONING_OPTIONS) |option| {
        const label = try self.allocator.dupeZ(u8, option.label);
        errdefer self.allocator.free(label);
        const variant: ?[:0]u8 = if (option.value) |value| try self.allocator.dupeZ(u8, @tagName(value)) else null;
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant });
    }
}

/// grok efforts stop at xhigh; the menu mirrors GROK_REASONING_OPTIONS with
/// effort tag names as row variants (parsed back by the shared handler).
pub fn refreshGrokReasoningMenu(self: anytype) !void {
    for (provider_models.GROK_REASONING_OPTIONS) |option| {
        const label = try self.allocator.dupeZ(u8, option.label);
        errdefer self.allocator.free(label);
        const variant: ?[:0]u8 = if (option.value) |value| try self.allocator.dupeZ(u8, @tagName(value)) else null;
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant });
    }
}

pub fn refreshMuseReasoningMenu(self: anytype) !void {
    for (provider_models.MUSE_REASONING_OPTIONS) |option| {
        const label = try self.allocator.dupeZ(u8, option.label);
        errdefer self.allocator.free(label);
        const variant: ?[:0]u8 = if (option.value) |value| try self.allocator.dupeZ(u8, @tagName(value)) else null;
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant });
    }
}

pub fn refreshClaudeReasoningMenu(self: anytype, thread: *const ChatThread) !void {
    const opt = self.claudeModelOptionForRef(thread.model_ref) orelse return;
    if (!opt.reasoning_supported) return;
    const values = opt.claude_effort_values orelse CLAUDE_STANDARD_EFFORT_VALUES[0..];
    if (values.len == 0) return;

    const default_label = try self.allocator.dupeZ(u8, "Default");
    try self.opencode_reasoning_menu.append(self.allocator, .{ .label = default_label, .variant = null });

    for (values) |value| {
        if (parseReasoningEffort(value) == null) continue;
        const label_text = claudeEffortValueLabel(value);
        const label = try self.allocator.dupeZ(u8, label_text);
        const variant_copy = try self.allocator.dupeZ(u8, value);
        try self.opencode_reasoning_menu.append(self.allocator, .{ .label = label, .variant = variant_copy });
    }
}

pub fn cursorModelOptionForRef(self: anytype, model_ref: ?[:0]const u8) ?ModelOption {
    const ref = model_ref orelse DEFAULT_CURSOR_MODEL;
    for (self.cursorModelOptionsSnapshot()) |opt| {
        if (opt.value) |v| {
            if (std.mem.eql(u8, ref, v)) return opt;
        }
    }
    return null;
}

pub fn claudeModelOptionForRef(self: anytype, model_ref: ?[:0]const u8) ?ModelOption {
    const ref = model_ref orelse DEFAULT_CLAUDE_MODEL;
    for (self.claudeModelOptionsSnapshot()) |opt| {
        if (opt.value) |v| {
            if (std.mem.eql(u8, ref, v)) return opt;
        }
    }
    return null;
}

pub fn cursorModelParamsJsonAlloc(self: anytype, allocator: std.mem.Allocator, thread: *const ChatThread) !?[]u8 {
    if (thread.provider != .cursor) return null;
    const opt = self.cursorModelOptionForRef(thread.model_ref) orelse return null;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer, .options = .{} };
    try stringify.beginArray();
    var wrote_any = false;

    if (opt.cursor_reasoning_requires_thinking and thread.opencode_reasoning_variant != null) {
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write("thinking");
        try stringify.objectField("value");
        try stringify.write("true");
        try stringify.endObject();
        wrote_any = true;
    }
    if (opt.cursor_reasoning_param_id) |param_id| {
        if (thread.opencode_reasoning_variant) |value| {
            try stringify.beginObject();
            try stringify.objectField("id");
            try stringify.write(std.mem.sliceTo(param_id, 0));
            try stringify.objectField("value");
            try stringify.write(std.mem.sliceTo(value, 0));
            try stringify.endObject();
            wrote_any = true;
        }
    }
    if (opt.cursor_fast_supported) {
        try stringify.beginObject();
        try stringify.objectField("id");
        try stringify.write("fast");
        try stringify.objectField("value");
        try stringify.write(if (thread.fast_mode == .on) "true" else "false");
        try stringify.endObject();
        wrote_any = true;
    }

    try stringify.endArray();
    if (!wrote_any) {
        writer.deinit();
        return null;
    }
    return try writer.toOwnedSlice();
}

pub fn normalizeOpencodeReasoningVariant(self: anytype, thread: *ChatThread) void {
    if (thread.provider != .opencode) return;
    if (thread.opencode_reasoning_variant) |cur| {
        const opt = self.opencodeModelOptionForRef(thread.model_ref) orelse {
            self.allocator.free(cur);
            thread.opencode_reasoning_variant = null;
            return;
        };
        if (!opt.reasoning_supported) {
            self.allocator.free(cur);
            thread.opencode_reasoning_variant = null;
            return;
        }
        const keys = opt.reasoning_variant_keys orelse {
            self.allocator.free(cur);
            thread.opencode_reasoning_variant = null;
            return;
        };
        if (keys.len == 0) {
            self.allocator.free(cur);
            thread.opencode_reasoning_variant = null;
            return;
        }
        for (keys) |k| {
            if (std.mem.eql(u8, cur, k)) return;
        }
        self.allocator.free(cur);
        thread.opencode_reasoning_variant = null;
    }
}

pub fn clearDynamicOpencodeModelOptions(self: anytype) void {
    for (self.opencode_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.reasoning_variant_keys) |keys| {
            for (keys) |k| self.allocator.free(k);
            self.allocator.free(keys);
        }
    }
    self.opencode_model_options.clearRetainingCapacity();
    self.clearOpencodeReasoningMenu();
}

pub fn clearOpencodeReasoningMenu(self: anytype) void {
    for (self.opencode_reasoning_menu.items) |row| {
        self.allocator.free(row.label);
        if (row.variant) |v| self.allocator.free(v);
    }
    self.opencode_reasoning_menu.clearRetainingCapacity();
}

pub fn clearOpencodeModelOptions(self: anytype) void {
    self.clearDynamicOpencodeModelOptions();
}

pub fn clearDynamicCursorModelOptions(self: anytype) void {
    for (self.cursor_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.reasoning_variant_keys) |keys| {
            for (keys) |k| self.allocator.free(k);
            self.allocator.free(keys);
        }
        if (option.cursor_reasoning_param_id) |param_id| self.allocator.free(param_id);
        if (option.cursor_reasoning_values) |values| {
            for (values) |value| self.allocator.free(value);
            self.allocator.free(values);
        }
    }
    self.cursor_model_options.clearRetainingCapacity();
}

pub fn clearDynamicClaudeModelOptions(self: anytype) void {
    for (self.claude_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.reasoning_variant_keys) |keys| {
            for (keys) |k| self.allocator.free(k);
            self.allocator.free(keys);
        }
        if (option.claude_effort_values) |values| {
            for (values) |value| self.allocator.free(value);
            self.allocator.free(values);
        }
    }
    self.claude_model_options.clearRetainingCapacity();
}

pub fn clearClaudeModelOptions(self: anytype) void {
    self.clearDynamicClaudeModelOptions();
}

pub fn clearDynamicPiModelOptions(self: anytype) void {
    for (self.pi_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.description) |description| self.allocator.free(description);
    }
    self.pi_model_options.clearRetainingCapacity();
}

pub fn clearPiModelOptions(self: anytype) void {
    self.clearDynamicPiModelOptions();
}

pub fn clearDynamicFxModelOptions(self: anytype) void {
    for (self.fx_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.description) |description| self.allocator.free(description);
    }
    self.fx_model_options.clearRetainingCapacity();
}

pub fn clearFxModelOptions(self: anytype) void {
    self.clearDynamicFxModelOptions();
}

pub fn clearDynamicGrokModelOptions(self: anytype) void {
    for (self.grok_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.description) |description| self.allocator.free(description);
    }
    self.grok_model_options.clearRetainingCapacity();
}

pub fn clearGrokModelOptions(self: anytype) void {
    self.clearDynamicGrokModelOptions();
}

pub fn clearDynamicMuseModelOptions(self: anytype) void {
    for (self.muse_model_options.items) |option| {
        self.allocator.free(option.label);
        if (option.value) |value| self.allocator.free(value);
        if (option.description) |description| self.allocator.free(description);
    }
    self.muse_model_options.clearRetainingCapacity();
}

pub fn clearMuseModelOptions(self: anytype) void {
    self.clearDynamicMuseModelOptions();
}

pub fn clearCursorModelOptions(self: anytype) void {
    self.clearDynamicCursorModelOptions();
}

pub fn loadCursorModelOptionsDiskCache(self: anytype) !void {
    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    var dir = try std.Io.Dir.openDirAbsolute(threaded.io(), self.storage.pref_path, .{});
    defer dir.close(threaded.io());

    const bytes = dir.readFileAlloc(threaded.io(), CURSOR_MODEL_CACHE_FILE_NAME, self.allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice([]PersistedCursorModelOption, self.allocator, bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (persistedCursorModelCacheNeedsRefresh(parsed.value)) return;

    self.clearCursorModelOptions();
    errdefer self.clearCursorModelOptions();
    for (parsed.value) |option| {
        if (option.label.len == 0 or option.value.len == 0) continue;
        const label = try self.allocator.dupeZ(u8, option.label);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, option.value);
        errdefer self.allocator.free(value);
        const reasoning_param_id = if (option.reasoning_param_id) |param_id| try self.allocator.dupeZ(u8, param_id) else null;
        errdefer if (reasoning_param_id) |param_id| self.allocator.free(param_id);
        const reasoning_values = if (option.reasoning_values) |values| blk: {
            const out = try self.allocator.alloc([:0]const u8, values.len);
            errdefer {
                for (out) |v| self.allocator.free(v);
                self.allocator.free(out);
            }
            for (values, 0..) |v, i| out[i] = try self.allocator.dupeZ(u8, v);
            break :blk out;
        } else null;
        errdefer if (reasoning_values) |values| {
            for (values) |v| self.allocator.free(v);
            self.allocator.free(values);
        };
        try self.cursor_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .cursor_fast_supported = option.fast_supported,
            .cursor_reasoning_param_id = reasoning_param_id,
            .cursor_reasoning_values = reasoning_values,
            .cursor_reasoning_requires_thinking = option.reasoning_requires_thinking,
        });
    }
}

pub fn saveCursorModelOptionsDiskCache(self: anytype) !void {
    if (self.cursor_model_options.items.len == 0) return;

    var persisted: std.ArrayList(PersistedCursorModelOption) = .empty;
    defer persisted.deinit(self.allocator);
    for (self.cursor_model_options.items) |option| {
        const value = option.value orelse continue;
        try persisted.append(self.allocator, .{
            .label = std.mem.sliceTo(option.label, 0),
            .value = std.mem.sliceTo(value, 0),
            .fast_supported = option.cursor_fast_supported,
            .reasoning_param_id = if (option.cursor_reasoning_param_id) |param_id| std.mem.sliceTo(param_id, 0) else null,
            .reasoning_values = if (option.cursor_reasoning_values) |values| blk: {
                const out = try self.allocator.alloc([]const u8, values.len);
                for (values, 0..) |v, i| out[i] = std.mem.sliceTo(v, 0);
                break :blk out;
            } else null,
            .reasoning_requires_thinking = option.cursor_reasoning_requires_thinking,
        });
    }
    defer {
        for (persisted.items) |option| {
            if (option.reasoning_values) |values| self.allocator.free(values);
        }
    }
    if (persisted.items.len == 0) return;

    const json = try std.json.Stringify.valueAlloc(self.allocator, persisted.items, .{ .whitespace = .minified });
    defer self.allocator.free(json);

    const path = try std.fs.path.join(self.allocator, &.{ self.storage.pref_path, CURSOR_MODEL_CACHE_FILE_NAME });
    defer self.allocator.free(path);

    var threaded: std.Io.Threaded = .init(self.allocator, .{});
    defer threaded.deinit();
    var file = try std.Io.Dir.createFileAbsolute(threaded.io(), path, .{ .truncate = true });
    defer file.close(threaded.io());
    try file.writeStreamingAll(threaded.io(), json);
}

const ModelCachePoll = struct {
    status: OpencodeModelCacheStatus = .idle,
    models: ?[]const provider_types.ModelInfo = null,
};

fn takeModelCachePoll(cache: anytype) ModelCachePoll {
    cache.mutex.lock();
    defer cache.mutex.unlock();
    return switch (cache.status) {
        .completed => {
            const models = cache.models;
            cache.models = null;
            cache.status = .idle;
            return .{ .status = .completed, .models = models };
        },
        .failed => {
            cache.status = .idle;
            return .{ .status = .failed };
        },
        else => .{},
    };
}

pub fn pollOpencodeModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.opencode_model_cache);
    if (poll.status != .idle) {
        self.finishOpencodeModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearOpencodeModelOptions();
            if (models.len == 0) return;
            self.populateOpencodeModelOptions(models) catch |err| {
                log.warn("failed to cache OpenCode configured models: {s}", .{@errorName(err)});
                self.clearDynamicOpencodeModelOptions();
                return;
            };
            self.normalizeCurrentOpencodeThreadModel();
        },
        .failed => {
            log.warn("failed to refresh OpenCode model cache", .{});
        },
        else => {},
    }
}

pub fn pollCursorModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.cursor_model_cache);
    if (poll.status != .idle) {
        self.finishCursorModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearCursorModelOptions();
            if (models.len == 0) return;
            self.populateCursorModelOptions(models) catch |err| {
                log.warn("failed to cache Cursor models: {s}", .{@errorName(err)});
                self.clearDynamicCursorModelOptions();
                return;
            };
            self.saveCursorModelOptionsDiskCache() catch |err| {
                log.warn("failed to save Cursor model cache: {s}", .{@errorName(err)});
            };
        },
        .failed => {
            log.warn("failed to refresh Cursor model cache", .{});
        },
        else => {},
    }
}

pub fn pollPiModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.pi_model_cache);
    if (poll.status != .idle) {
        self.finishPiModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearPiModelOptions();
            if (models.len == 0) return;
            self.populatePiModelOptions(models) catch |err| {
                log.warn("failed to cache pi models: {s}", .{@errorName(err)});
                self.clearDynamicPiModelOptions();
                return;
            };
        },
        .failed => {
            log.warn("failed to refresh pi model cache", .{});
        },
        else => {},
    }
}

pub fn pollFxModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.fx_model_cache);
    if (poll.status != .idle) {
        self.finishFxModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearFxModelOptions();
            if (models.len == 0) return;
            self.populateFxModelOptions(models) catch |err| {
                log.warn("failed to cache fx models: {s}", .{@errorName(err)});
                self.clearDynamicFxModelOptions();
                return;
            };
        },
        .failed => {
            log.warn("failed to refresh fx model cache", .{});
        },
        else => {},
    }
}

pub fn pollGrokModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.grok_model_cache);
    if (poll.status != .idle) {
        self.finishGrokModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearGrokModelOptions();
            if (models.len == 0) return;
            self.populateGrokModelOptions(models) catch |err| {
                log.warn("failed to cache grok models: {s}", .{@errorName(err)});
                self.clearDynamicGrokModelOptions();
                return;
            };
        },
        .failed => {
            log.warn("failed to refresh grok model cache", .{});
        },
        else => {},
    }
}

pub fn pollMuseModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.muse_model_cache);
    if (poll.status != .idle) {
        self.finishMuseModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearMuseModelOptions();
            if (models.len == 0) return;
            self.populateMuseModelOptions(models) catch |err| {
                log.warn("failed to cache muse models: {s}", .{@errorName(err)});
                self.clearDynamicMuseModelOptions();
                return;
            };
        },
        .failed => {
            log.warn("failed to refresh muse model cache", .{});
        },
        else => {},
    }
}

pub fn pollClaudeModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.claude_model_cache);
    if (poll.status != .idle) {
        self.finishClaudeModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer provider_types.freeModelInfos(std.heap.page_allocator, models);
            self.clearClaudeModelOptions();
            if (models.len == 0) return;
            self.populateClaudeModelOptions(models) catch |err| {
                log.warn("failed to cache Claude models: {s}", .{@errorName(err)});
                self.clearDynamicClaudeModelOptions();
                return;
            };
        },
        .failed => {
            log.warn("failed to refresh Claude model cache", .{});
        },
        else => {},
    }
}
