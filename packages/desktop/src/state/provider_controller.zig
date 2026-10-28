//! Provider readiness and asynchronous model-discovery controller state.

const std = @import("std");
const headless = @import("headless");
const app_config = @import("../app/config.zig");
const daemon_client = @import("../daemon/client.zig");
const loop_wakeup = @import("loop_wakeup");
const utils = @import("../utils.zig");
const chat_types = @import("chat_types.zig");
const provider_cli_version = @import("../providers/cli_version.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");
const provider_setup = @import("provider_setup.zig");
const platform_runtime = @import("platform_runtime");
const runtime_log = @import("../runtime/log.zig");

const log = std.log.scoped(.native_shell);
const provider_types = headless.provider_types;
const Provider = provider_models.Provider;
/// Sizes per-provider arrays indexed by `@intFromEnum(provider)`.
pub const PROVIDER_COUNT = std.meta.fields(Provider).len;
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

pub const MissingRequirement = headless.providers_protocol.MissingRequirement;

pub const ProviderReadiness = enum {
    checking,
    missing,
    signed_out,
    ready,
    unavailable,
};

/// Result of comparing the installed CLI with the provider's published release.
/// `unknown` means the check did not run or the versions could not be ordered.
pub const ProviderRelease = enum {
    unknown,
    current,
    available,
};

pub const HARNESS_VERSION_BYTES = 48;
const UPDATE_SHELL_BYTES = 192;

/// First line of a provider CLI's `--version`, copied out of the daemon response.
pub const ProviderHarnessVersion = struct {
    bytes: [HARNESS_VERSION_BYTES]u8 = .{0} ** HARNESS_VERSION_BYTES,
    len: u8 = 0,

    pub fn slice(self: *const ProviderHarnessVersion) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *ProviderHarnessVersion, text: []const u8) void {
        const n = @min(text.len, self.bytes.len);
        @memcpy(self.bytes[0..n], text[0..n]);
        self.len = @intCast(n);
    }
};

const ProviderUpdateShell = struct {
    bytes: [UPDATE_SHELL_BYTES]u8 = .{0} ** UPDATE_SHELL_BYTES,
    len: u8 = 0,

    pub fn slice(self: *const ProviderUpdateShell) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *ProviderUpdateShell, text: []const u8) void {
        const n = @min(text.len, self.bytes.len);
        @memcpy(self.bytes[0..n], text[0..n]);
        self.len = @intCast(n);
    }
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
    /// Ready when at least one `chat.custom_acp_agents` command resolves.
    custom_acp: ProviderReadiness = .checking,
    /// Indexed by `Provider`'s enum value. Empty when the daemon reported no version.
    versions: [PROVIDER_COUNT]ProviderHarnessVersion = @splat(.{}),
    /// Indexed by `Provider`'s enum value. `available` is the only state that offers Update.
    releases: [PROVIDER_COUNT]ProviderRelease = @splat(.unknown),
    /// Indexed by `Provider`'s enum value. The published version the last
    /// release lookup compared against; empty when it was not reached.
    latest_versions: [PROVIDER_COUNT]ProviderHarnessVersion = @splat(.{}),
    /// Indexed by `Provider`'s enum value. True when the PATH binary is owned by
    /// mise, Homebrew, or npm, so Update must not run the official installer.
    package_managed: [PROVIDER_COUNT]bool = @splat(false),
    /// Indexed by `Provider`'s enum value. Empty uses the official installer.
    update_shells: [PROVIDER_COUNT]ProviderUpdateShell = @splat(.{}),
    /// Indexed by `Provider`'s enum value. Set when the CLI is present but a
    /// runtime it needs is not (Claude without Node.js); readiness stays
    /// `.missing` so every existing "unusable" check still holds.
    requirements: [PROVIDER_COUNT]?MissingRequirement = @splat(null),

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
            .custom_acp => self.custom_acp,
        };
    }

    pub fn setForProvider(self: *ProviderReadinessSnapshot, provider: Provider, readiness: ProviderReadiness) void {
        switch (provider) {
            .codex => self.codex = readiness,
            .opencode => self.opencode = readiness,
            .claude => self.claude = readiness,
            .cursor => self.cursor = readiness,
            .pi => self.pi = readiness,
            .fx => self.fx = readiness,
            .grok => self.grok = readiness,
            .muse => self.muse = readiness,
            .custom_acp => self.custom_acp = readiness,
        }
    }

    pub fn versionForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) []const u8 {
        return self.versions[@intFromEnum(provider)].slice();
    }

    pub fn releaseForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) ProviderRelease {
        return self.releases[@intFromEnum(provider)];
    }

    pub fn latestVersionForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) []const u8 {
        return self.latest_versions[@intFromEnum(provider)].slice();
    }

    pub fn packageManagedForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) bool {
        return self.package_managed[@intFromEnum(provider)];
    }

    pub fn updateShellForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) []const u8 {
        return self.update_shells[@intFromEnum(provider)].slice();
    }

    pub fn requirementForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) ?MissingRequirement {
        return self.requirements[@intFromEnum(provider)];
    }

    /// How close `provider` is to chatting: 0 ready (or still checking),
    /// 1 installed but signed out or unverified, 2 installed but missing a
    /// runtime (Node.js), 3 not installed. The model picker and new-chat
    /// defaults prefer lower ranks, so an installed provider beats a missing one.
    pub fn setupRank(self: *const ProviderReadinessSnapshot, provider: Provider) u8 {
        return switch (self.forProvider(provider)) {
            .ready, .checking => 0,
            .signed_out, .unavailable => 1,
            .missing => if (self.requirementForProvider(provider) != null) 2 else 3,
        };
    }

    /// True when the CLI is on this machine, signed in or not (including one
    /// that still lacks a runtime such as Node.js).
    pub fn installedForProvider(self: *const ProviderReadinessSnapshot, provider: Provider) bool {
        return switch (self.forProvider(provider)) {
            .signed_out, .ready, .unavailable => true,
            .missing => self.requirementForProvider(provider) != null,
            .checking => false,
        };
    }

    pub fn hasReadyProvider(self: ProviderReadinessSnapshot) bool {
        return self.codex == .ready or self.opencode == .ready or self.claude == .ready or self.cursor == .ready or self.pi == .ready or self.fx == .ready or self.grok == .ready or self.muse == .ready or self.custom_acp == .ready;
    }

    /// True when a provider Verde's MCP server can register with has its
    /// CLI installed (signed in or not). The MCP dialog waits for one.
    pub fn hasMcpCapableProviderInstalled(self: ProviderReadinessSnapshot) bool {
        for (MCP_CAPABLE_PROVIDERS) |provider| {
            // Present but unable to run yet still counts: its config can be written.
            if (self.installedForProvider(provider)) return true;
        }
        return false;
    }
};

/// Providers `provider.mcp.set` can register Verde with (see `McpSummary`).
const MCP_CAPABLE_PROVIDERS = [_]Provider{ .codex, .claude, .cursor, .opencode, .pi, .fx, .grok };

fn mcpIntegrationProvider(provider: Provider) ?headless.providers_protocol.IntegrationProvider {
    return std.meta.stringToEnum(headless.providers_protocol.IntegrationProvider, @tagName(provider));
}

pub const McpSyncStatus = enum { idle, pending, completed };

/// Background `provider.mcp.set` run that registers Verde with providers
/// installed after Verde tools were enabled (see `syncMcpForNewProviders`).
pub const McpSyncState = struct {
    mutex: Mutex = .{},
    status: McpSyncStatus = .idle,
    worker: ?std.Thread = null,
    summary: ?headless.providers_protocol.McpSummary = null,
    /// Main thread only. Providers already tried this session, so a provider
    /// whose registration keeps failing is not retried on every check.
    attempted: [PROVIDER_COUNT]bool = @splat(false),
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
    /// Bumped on the worker after a provider row is published. The main thread
    /// copies `seen_revision` and redraws; the worker never reads it.
    revision: std.atomic.Value(u32) = .init(0),
    seen_revision: u32 = 0,
    /// Main thread only. Bumped per started check, so a caller can tell the
    /// check that answers its request from one already in flight.
    generation: u32 = 0,
    /// Main thread only. Start another check as soon as this one completes.
    fresh_requested: bool = false,
    /// Main thread only. Set once the first completed check has re-picked
    /// defaults for chats created while every provider still read "checking".
    startup_defaults_applied: bool = false,
    /// Main thread only. Wall-clock start of the last check; a long-running
    /// session rechecks on `PROVIDER_UPDATE_RECHECK_MS` so a CLI release
    /// published after launch still raises the update toast.
    last_started_ms: i64 = 0,
};

/// How often a running Verde looks for newer provider CLIs.
pub const PROVIDER_UPDATE_RECHECK_MS: i64 = 4 * std.time.ms_per_hour;

/// Main thread only. Per-session state of the "provider CLI update" toast.
pub const UpdateToastState = struct {
    /// Indexed by `Provider`. Set by × or by starting the update, so the
    /// toast does not return for that provider until Verde restarts.
    dismissed: [PROVIDER_COUNT]bool = @splat(false),
};

/// What the provider update toast draws this frame.
pub const UpdateToastView = struct {
    provider: Provider,
    name: []const u8,
    installed: ProviderHarnessVersion,
    latest: ProviderHarnessVersion,
    /// Other providers that also have an update waiting behind this one.
    more: usize = 0,
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
    workspace_id: ?[]u8 = null,
    local_thread_id: ?[]u8 = null,

    pub fn deinit(self: *ProviderThreadOperationRequest) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.pref_path);
        allocator.free(self.project_path);
        if (self.thread_id) |thread_id| allocator.free(thread_id);
        if (self.workspace_id) |value| allocator.free(value);
        if (self.local_thread_id) |value| allocator.free(value);
        allocator.destroy(self);
    }
};

pub const ProviderThreadOperationResult = union(enum) {
    list: []const provider_types.ChatThreadSummary,
    read: provider_types.ReadThreadResult,
    synced: headless.protocol.ParsedResponse,

    pub fn deinit(self: ProviderThreadOperationResult) void {
        const allocator = std.heap.page_allocator;
        switch (self) {
            .list => |threads| freeThreadSummaries(allocator, threads),
            .read => |thread| thread.deinit(allocator),
            .synced => |response| {
                var owned = response;
                owned.deinit();
            },
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
    /// Picker rows for `chat.custom_acp_agents`, one per agent; rebuilt when
    /// the configured list changes (see `syncCustomAcpModelOptions`).
    custom_acp_model_options: std.ArrayList(ModelOption) = .empty,
    custom_acp_options_hash: ?u64 = null,
    readiness: ProviderReadinessState = .{},
    update_toast: UpdateToastState = .{},
    thread_operation: ProviderThreadOperationState = .{},
    mcp_sync: McpSyncState = .{},
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
        .custom_acp => .custom_acp,
    };
}

fn providerDisplayName(provider: Provider) []const u8 {
    return provider_setup.displayName(provider);
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
        .sync_thread => blk: {
            var parsed = try client.call(headless.providers_protocol.METHOD_PROVIDER_THREAD_SYNC, headless.providers_protocol.ThreadSyncRequest{
                .workspace_id = request.workspace_id orelse return error.InvalidProviderThreadId,
                .local_thread_id = request.local_thread_id orelse return error.InvalidProviderThreadId,
                .provider_thread_id = request.thread_id orelse return error.InvalidProviderThreadId,
            });
            errdefer parsed.deinit();
            if (parsed.response.err) |remote_error| {
                if (std.mem.eql(u8, remote_error.code, headless.protocol.ERR_CONFLICT)) return error.ThreadChangedDuringSync;
                if (std.mem.eql(u8, remote_error.message, "ProviderHistoryWouldDropAttachments")) return error.ProviderHistoryWouldDropAttachments;
                // The sidebar notice only says "failed"; keep the daemon's
                // reason in the pref-dir log.
                runtime_log.diagnostic("provider thread sync rejected code={s} message={s}", .{ remote_error.code, remote_error.message });
                return error.RemoteError;
            }
            if (parsed.response.result == null) return error.InvalidDaemonResponse;
            break :blk .{ .synced = parsed };
        },
        .import_thread => blk: {
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
        // A provider whose CLI is not installed answers every launch's model
        // refresh with a remote error; that is expected, not a failure.
        if (err == error.RemoteError and provider_cli_version.executableForProvider(@tagName(provider)) == null) {
            log.debug("skipped {s} models: CLI not installed", .{providerDisplayName(provider)});
        } else {
            log.warn("failed to decode {s} models from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        }
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

const FetchedProvider = struct {
    readiness: ProviderReadiness,
    version: ProviderHarnessVersion = .{},
    release: ProviderRelease = .unknown,
    latest: ProviderHarnessVersion = .{},
    package_managed: bool = false,
    update_shell: ProviderUpdateShell = .{},
    requirement: ?MissingRequirement = null,
};

const ReleaseLookup = struct {
    release: ProviderRelease = .unknown,
    latest: ProviderHarnessVersion = .{},
};

fn releaseForInstalledVersion(provider_name: []const u8, installed: []const u8, plan: *const provider_cli_version.UpdatePlan) ReleaseLookup {
    if (installed.len == 0) return .{};
    var latest_buf: [HARNESS_VERSION_BYTES]u8 = undefined;
    const latest = provider_cli_version.fetchPlanLatest(std.heap.page_allocator, provider_name, plan, &latest_buf) orelse return .{};
    var lookup: ReleaseLookup = .{};
    lookup.latest.set(latest);
    const order = provider_cli_version.compareInstalled(installed, latest) orelse return lookup;
    lookup.release = if (order == .lt) .available else .current;
    return lookup;
}

fn fetchProviderReadiness(
    client: anytype,
    provider: Provider,
    project_path: []const u8,
) FetchedProvider {
    var parsed = client.callProviderAuthStatus(headless.Capabilities.phase1(), .{
        .provider = providerProtocolTag(provider),
        .project_path = project_path,
    }) catch |err| {
        log.warn("failed to request {s} readiness from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return .{ .readiness = .unavailable };
    };
    defer parsed.deinit();
    const result = client.decodeProviderAuthStatus(&parsed) catch |err| {
        log.warn("failed to decode {s} readiness from daemon: {s}", .{ providerDisplayName(provider), @errorName(err) });
        return .{ .readiness = .unavailable };
    };
    defer if (result.version) |text| client.allocator.free(text);
    if (result.provider != providerProtocolTag(provider)) return .{ .readiness = .unavailable };
    var fetched: FetchedProvider = .{ .readiness = .unavailable };
    if (result.version) |text| fetched.version.set(text);
    if (!result.installed) {
        fetched.readiness = .missing;
        fetched.requirement = result.missing_requirement;
        return fetched;
    }
    if (result.ready) {
        fetched.readiness = .ready;
        return fetched;
    }
    fetched.readiness = switch (result.auth_state) {
        .signed_out => .signed_out,
        .signed_in => .ready,
        .unknown, .pending => .unavailable,
    };
    return fetched;
}

const ReadinessJob = struct {
    state: *ProviderReadinessState,
    provider: Provider,
    pref_path: []const u8,
    project_path: []const u8,
};

fn publishProviderReadiness(state: *ProviderReadinessState, provider: Provider, fetched: FetchedProvider) void {
    state.mutex.lock();
    switch (provider) {
        .codex => state.snapshot.codex = fetched.readiness,
        .opencode => state.snapshot.opencode = fetched.readiness,
        .claude => state.snapshot.claude = fetched.readiness,
        .cursor => state.snapshot.cursor = fetched.readiness,
        .pi => state.snapshot.pi = fetched.readiness,
        .fx => state.snapshot.fx = fetched.readiness,
        .grok => state.snapshot.grok = fetched.readiness,
        .muse => state.snapshot.muse = fetched.readiness,
        .custom_acp => state.snapshot.custom_acp = fetched.readiness,
    }
    const index = @intFromEnum(provider);
    state.snapshot.versions[index] = fetched.version;
    state.snapshot.releases[index] = fetched.release;
    state.snapshot.latest_versions[index] = fetched.latest;
    state.snapshot.package_managed[index] = fetched.package_managed;
    state.snapshot.update_shells[index] = fetched.update_shell;
    state.snapshot.requirements[index] = fetched.requirement;
    state.mutex.unlock();
    _ = state.revision.fetchAdd(1, .release);
    loop_wakeup.notify();
}

fn publishVersionWhileChecking(state: *ProviderReadinessState, provider: Provider, version: ProviderHarnessVersion) void {
    state.mutex.lock();
    const checking = state.snapshot.forProvider(provider) == .checking;
    if (checking) state.snapshot.versions[@intFromEnum(provider)] = version;
    state.mutex.unlock();
    if (!checking) return;
    _ = state.revision.fetchAdd(1, .release);
    loop_wakeup.notify();
}

fn computeProviderRelease(
    state: *ProviderReadinessState,
    provider: Provider,
    version: ProviderHarnessVersion,
    plan: provider_cli_version.UpdatePlan,
    out: *ReleaseLookup,
) void {
    const lookup = releaseForInstalledVersion(@tagName(provider), version.slice(), &plan);
    out.* = lookup;
    const release = lookup.release;
    if (release == .unknown) return;
    var shell: ProviderUpdateShell = .{};
    shell.set(plan.shellSlice());
    state.mutex.lock();
    const index = @intFromEnum(provider);
    state.snapshot.releases[index] = release;
    state.snapshot.latest_versions[index] = lookup.latest;
    state.snapshot.package_managed[index] = plan.managed;
    state.snapshot.update_shells[index] = shell;
    if (state.snapshot.versions[index].slice().len == 0) state.snapshot.versions[index] = version;
    state.mutex.unlock();
    _ = state.revision.fetchAdd(1, .release);
    loop_wakeup.notify();
}

fn runProviderReadinessJob(job: ReadinessJob) void {
    var local_version: ProviderHarnessVersion = .{};
    var plan: provider_cli_version.UpdatePlan = .{};
    if (provider_cli_version.executableForProvider(@tagName(job.provider))) |executable| {
        var buf: [HARNESS_VERSION_BYTES]u8 = undefined;
        if (provider_cli_version.probe(std.heap.page_allocator, executable, &buf)) |line| {
            local_version.set(line);
        }
        provider_cli_version.planUpdate(std.heap.page_allocator, executable, &plan);
    }
    if (local_version.slice().len > 0) publishVersionWhileChecking(job.state, job.provider, local_version);

    // Latest-channel lookup overlaps the daemon auth handshake. Both are
    // network or process waits; running them one after another is most of
    // the multi-second Providers page delay.
    var release: ReleaseLookup = .{};
    const release_thread: ?std.Thread = if (local_version.slice().len == 0) null else std.Thread.spawn(.{}, computeProviderRelease, .{
        job.state,
        job.provider,
        local_version,
        plan,
        &release,
    }) catch null;
    if (release_thread == null and local_version.slice().len > 0) {
        computeProviderRelease(job.state, job.provider, local_version, plan, &release);
    }

    const allocator = std.heap.page_allocator;
    var transport: daemon_client.HeadlessTransport = .{
        .allocator = allocator,
        .pref_path = job.pref_path,
    };
    var client = daemon_client.headlessClient(allocator, &transport);
    var fetched = fetchProviderReadiness(&client, job.provider, job.project_path);
    if (release_thread) |thread| thread.join();

    // The local probe is the binary this process would run. A daemon that
    // searched PATH earlier can still report a different copy.
    if (fetched.readiness != .missing and local_version.slice().len > 0) fetched.version = local_version;
    if (fetched.readiness != .missing and fetched.version.slice().len > 0) {
        if (local_version.slice().len == 0) {
            release = releaseForInstalledVersion(@tagName(job.provider), fetched.version.slice(), &plan);
        }
        fetched.package_managed = plan.managed;
        fetched.update_shell.set(plan.shellSlice());
        fetched.release = release.release;
        fetched.latest = release.latest;
    }
    publishProviderReadiness(job.state, job.provider, fetched);
}

pub fn providerReadinessWorker(state: *ProviderReadinessState, request: ProviderReadinessWorkerRequest) void {
    defer request.deinit();
    const providers = [_]Provider{ .codex, .opencode, .claude, .cursor, .pi, .fx, .grok, .muse, .custom_acp };
    var threads: [providers.len]?std.Thread = @splat(null);
    for (providers, 0..) |provider, index| {
        const job: ReadinessJob = .{
            .state = state,
            .provider = provider,
            .pref_path = request.pref_path,
            .project_path = request.project_path,
        };
        threads[index] = std.Thread.spawn(.{}, runProviderReadinessJob, .{job}) catch null;
        if (threads[index] == null) runProviderReadinessJob(job);
    }
    for (threads) |maybe_thread| if (maybe_thread) |thread| thread.join();

    state.mutex.lock();
    state.status = .completed;
    state.mutex.unlock();
    _ = state.revision.fetchAdd(1, .release);
    loop_wakeup.notify();
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

/// One row per configured custom ACP agent; empty when none are configured.
pub fn customAcpModelOptionsSnapshot(self: anytype) []const ModelOption {
    return self.provider_controller.custom_acp_model_options.items;
}

/// Rebuilds the custom agent picker rows when `chat.custom_acp_agents`
/// changed. Cheap to call every poll: it only hashes ids and names.
pub fn syncCustomAcpModelOptions(self: anytype) void {
    const agents = self.app_config.custom_acp_agents;
    var hasher = std.hash.Wyhash.init(0);
    for (agents) |agent| {
        hasher.update(agent.id);
        hasher.update(&.{0});
        hasher.update(agent.name);
        hasher.update(&.{0});
    }
    const hash = hasher.final();
    const controller = &self.provider_controller;
    if (controller.custom_acp_options_hash == hash) return;
    clearCustomAcpModelOptions(controller, self.allocator);
    for (agents) |agent| {
        const label = self.allocator.dupeZ(u8, agent.name) catch break;
        const value = self.allocator.dupeZ(u8, agent.id) catch {
            self.allocator.free(label);
            break;
        };
        controller.custom_acp_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .description = "Custom ACP agent",
            .reasoning_supported = false,
        }) catch {
            self.allocator.free(label);
            self.allocator.free(value);
            break;
        };
    }
    controller.custom_acp_options_hash = hash;
    self.composer_controller.model_picker.invalidateItems();
    self.markDirty();
}

pub fn clearCustomAcpModelOptions(controller: *State, allocator: std.mem.Allocator) void {
    for (controller.custom_acp_model_options.items) |option| {
        allocator.free(option.label);
        if (option.value) |value| allocator.free(value);
    }
    controller.custom_acp_model_options.clearRetainingCapacity();
    controller.custom_acp_options_hash = null;
}

pub fn deinitCustomAcpModelOptions(controller: *State, allocator: std.mem.Allocator) void {
    clearCustomAcpModelOptions(controller, allocator);
    controller.custom_acp_model_options.deinit(allocator);
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
        .custom_acp => if (self.provider_controller.custom_acp_model_options.items.len > 0)
            self.provider_controller.custom_acp_model_options.items[0].value orelse "default"
        else
            "default",
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
    spawnProviderReadinessCheck(self);
}

/// Starts a readiness check that begins after this call: when one is already
/// in flight (its results may predate the caller's change), another starts
/// as soon as it completes. Returns the generation whose completion answers
/// the request; see `ProviderReadinessState.generation`.
pub fn requestFreshProviderReadinessCheck(self: anytype) u32 {
    self.pollProviderReadiness();
    const readiness = &self.provider_controller.readiness;
    readiness.mutex.lock();
    const pending = readiness.status != .idle;
    readiness.mutex.unlock();
    if (pending) {
        readiness.fresh_requested = true;
        return readiness.generation +% 1;
    }
    spawnProviderReadinessCheck(self);
    return readiness.generation;
}

fn spawnProviderReadinessCheck(self: anytype) void {
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
    self.provider_controller.readiness.generation +%= 1;
    self.provider_controller.readiness.last_started_ms = platform_runtime.unixTimestampMs();
    // Keep the last versions and Update/Latest labels visible. The worker
    // replaces each row as that provider finishes instead of blanking all
    // eight until the slowest lookup returns.
    self.provider_controller.readiness.worker = std.Thread.spawn(.{}, providerReadinessWorker, .{
        &self.provider_controller.readiness,
        request,
    }) catch {
        request.deinit();
        self.provider_controller.readiness.status = .completed;
        // Every row, so none is left saying "Checking..." forever.
        for (std.enums.values(Provider)) |provider| {
            self.provider_controller.readiness.snapshot.setForProvider(provider, .unavailable);
        }
        return;
    };
    self.markDirty();
}

/// Completes the one-time MCP onboarding choice. Enabling registers Verde
/// in every detected provider's user config; declining makes no external
/// changes and remains reversible from Settings. With no provider detected
/// there is nothing to decide yet: the dialog steps aside for this session
/// and returns after a provider is installed.
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
            self.setSidebarNotice("No supported agent providers were detected. Verde will ask again after you install one.");
            snoozeMcpOnboarding(self);
            return;
        }
        self.app_config.mcp_integration_enabled = summary.installedCount() > 0;
        var notice_buf: [192]u8 = undefined;
        self.setSidebarNotice(mcpEnableNotice(&notice_buf, summary.installedCount(), summary.conflictCount(), summary.failedCount()));
    } else {
        if (!self.providerReadinessSnapshot().hasMcpCapableProviderInstalled()) {
            snoozeMcpOnboarding(self);
            return;
        }
        self.app_config.mcp_integration_enabled = false;
        self.setSidebarNotice("Verde MCP tools were not enabled. You can enable them in Settings.");
    }

    self.app_config.mcp_onboarding_completed = true;
    if (app_config.saveAppConfig(self.allocator, &self.app_config)) |_| {
        // Our own write: the config watcher must not report it as an outside reload.
        self.app_config_file_mtime = app_config.configFileMtime(self.allocator) catch self.app_config_file_mtime;
    } else |err| {
        log.warn("failed to persist MCP onboarding choice: {s}", .{@errorName(err)});
        self.setSidebarNotice("MCP choice applied, but could not save Verde settings.");
    }
    self.settings_controller.mcp_onboarding_visible = false;
    self.markDirty();
}

/// Hides the MCP dialog without recording a choice.
fn snoozeMcpOnboarding(self: anytype) void {
    self.settings_controller.mcp_onboarding_visible = false;
    self.settings_controller.mcp_onboarding_snoozed = true;
    self.markDirty();
}

/// Says what Enable actually did, from the registration counts.
pub fn mcpEnableNotice(buf: []u8, installed: usize, conflicts: usize, failed: usize) []const u8 {
    if (installed == 0) {
        if (failed > 0) return "Could not enable Verde MCP: provider configs could not be updated.";
        if (conflicts > 0) return "Verde MCP was not added: each detected provider already has a 'verde' entry, which was kept.";
        return "Verde MCP was not added to any provider.";
    }
    const plural: []const u8 = if (installed == 1) "" else "s";
    if (failed > 0) return std.fmt.bufPrint(buf, "Enabled Verde MCP for {d} provider{s}; {d} config(s) could not be updated.", .{ installed, plural, failed }) catch "Enabled Verde MCP; some provider configs could not be updated.";
    if (conflicts > 0) return std.fmt.bufPrint(buf, "Enabled Verde MCP for {d} provider{s}; kept {d} existing 'verde' entr{s}.", .{ installed, plural, conflicts, if (conflicts == 1) "y" else "ies" }) catch "Enabled Verde MCP; an existing 'verde' entry was kept.";
    return std.fmt.bufPrint(buf, "Enabled Verde tools for {d} detected provider{s}.", .{ installed, plural }) catch "Enabled Verde tools in detected agent providers.";
}

/// With Verde tools enabled, registers them with any MCP-capable provider the
/// check found installed that the last registration did not cover (installed
/// after the user turned the tools on). Runs off the UI thread; each provider
/// is tried once per session.
fn syncMcpForNewProviders(self: anytype, snapshot: ProviderReadinessSnapshot) void {
    if (!self.app_config.mcp_integration_enabled) return;
    const sync = &self.provider_controller.mcp_sync;
    if (sync.status != .idle) return;
    const summary = self.settings_controller.mcp_summary;
    var wanted = false;
    for (MCP_CAPABLE_PROVIDERS) |provider| {
        if (sync.attempted[@intFromEnum(provider)]) continue;
        if (!snapshot.installedForProvider(provider)) continue;
        const integration = mcpIntegrationProvider(provider) orelse continue;
        switch (summary.forProvider(integration)) {
            .unavailable, .not_installed => {},
            .installed, .conflict, .failed => continue,
        }
        sync.attempted[@intFromEnum(provider)] = true;
        wanted = true;
    }
    if (!wanted) return;
    const pref_path = std.heap.page_allocator.dupe(u8, self.storage.pref_path) catch return;
    sync.status = .pending;
    sync.worker = std.Thread.spawn(.{}, mcpSyncWorker, .{ sync, pref_path }) catch {
        std.heap.page_allocator.free(pref_path);
        sync.status = .idle;
        return;
    };
}

fn mcpSyncWorker(sync: *McpSyncState, pref_path: []u8) void {
    defer std.heap.page_allocator.free(pref_path);
    const summary: ?headless.providers_protocol.McpSummary = setProviderMcp(std.heap.page_allocator, pref_path, true) catch |err| blk: {
        log.warn("failed to register Verde MCP with newly installed providers: {s}", .{@errorName(err)});
        break :blk null;
    };
    sync.mutex.lock();
    sync.summary = summary;
    sync.status = .completed;
    sync.mutex.unlock();
    loop_wakeup.notify();
}

/// Applies a finished background registration: the Settings summary updates
/// and one quiet notice names the providers that gained Verde tools.
fn pollMcpSync(self: anytype) void {
    const sync = &self.provider_controller.mcp_sync;
    sync.mutex.lock();
    const completed = sync.status == .completed;
    const summary = sync.summary;
    sync.mutex.unlock();
    if (!completed) return;
    finishMcpSyncWorker(self);
    const next = summary orelse return;
    const previous = self.settings_controller.mcp_summary;
    self.settings_controller.mcp_summary = next;
    var names_buf: [96]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&names_buf);
    var added: usize = 0;
    for (MCP_CAPABLE_PROVIDERS) |provider| {
        const integration = mcpIntegrationProvider(provider) orelse continue;
        if (next.forProvider(integration) != .installed or previous.forProvider(integration) == .installed) continue;
        if (added > 0) writer.writeAll(", ") catch {};
        writer.writeAll(providerDisplayName(provider)) catch {};
        added += 1;
    }
    if (added > 0) {
        var notice_buf: [160]u8 = undefined;
        self.setSidebarNotice(std.fmt.bufPrint(&notice_buf, "Added Verde tools to {s}.", .{names_buf[0..writer.end]}) catch "Added Verde tools to a newly installed provider.");
    }
    self.markDirty();
}

/// Joins a background MCP registration and drops its result. Settings calls
/// this before its own MCP change so a late worker cannot undo the user's
/// choice; AppState.deinit calls it on shutdown.
pub fn finishMcpSyncWorker(self: anytype) void {
    const sync = &self.provider_controller.mcp_sync;
    if (sync.worker) |worker| {
        worker.join();
        sync.worker = null;
    }
    sync.mutex.lock();
    sync.status = .idle;
    sync.summary = null;
    sync.mutex.unlock();
}

pub fn pollProviderReadiness(self: anytype) void {
    syncCustomAcpModelOptions(self);
    provider_setup.poll(self, platform_runtime.unixTimestampMs());
    self.pollProviderThreadOperation();
    self.pollProviderSlashCatalog();
    pollMcpSync(self);
    const revision = self.provider_controller.readiness.revision.load(.acquire);
    if (revision != self.provider_controller.readiness.seen_revision) {
        self.provider_controller.readiness.seen_revision = revision;
        self.markDirty();
    }
    var completed = false;
    var snapshot: ProviderReadinessSnapshot = .{};

    const readiness = &self.provider_controller.readiness;
    readiness.mutex.lock();
    if (readiness.status == .completed) {
        snapshot = readiness.snapshot;
        readiness.status = .idle;
        completed = true;
    }
    const idle = readiness.status == .idle;
    readiness.mutex.unlock();
    if (!completed) {
        if (idle and readiness.last_started_ms != 0 and
            platform_runtime.unixTimestampMs() -| readiness.last_started_ms >= PROVIDER_UPDATE_RECHECK_MS)
        {
            spawnProviderReadinessCheck(self);
        }
        return;
    }

    self.finishProviderReadinessThread();
    if (!readiness.startup_defaults_applied) {
        readiness.startup_defaults_applied = true;
        self.reapplyDefaultsToUnstartedChats();
    }
    const generation = readiness.generation;
    const setup = &self.settings_controller.provider_setup;
    provider_setup.noteReadinessCompleted(setup, snapshot, generation);
    const recheck = self.settings_controller.provider_recheck_generation;
    if (recheck != 0 and generation >= recheck) self.settings_controller.provider_recheck_generation = 0;
    if (readiness.fresh_requested) {
        readiness.fresh_requested = false;
        spawnProviderReadinessCheck(self);
    }
    syncMcpForNewProviders(self, snapshot);

    // Sign-in/install from the dialog worked: close the whole dialog and say
    // so, rather than leaving the user to click Back and then Not now. An
    // update starts from a ready CLI, so it waits for its command to exit.
    const updating = setup.mode == .update and setup.status == .running;
    // A remote target closes from its own status (`provider_setup`).
    if (self.settings_controller.provider_onboarding_visible and setup.visible() and !updating and setup.target_profile_id == null and snapshot.forProvider(setup.provider) == .ready) {
        const provider = setup.provider;
        self.dismissProviderOnboarding();
        var notice_buf: [128]u8 = undefined;
        const notice = std.fmt.bufPrint(&notice_buf, "{s} is ready. Pick it from the model menu in any chat.", .{providerDisplayName(provider)}) catch "Provider is ready.";
        self.setSidebarNotice(notice);
    }
    // Never surface a dialog underneath Settings; keys would reach the hidden
    // dialog first. The next check after Settings closes shows it.
    const settings_open = self.settings_controller.modal_visible;
    if (snapshot.hasReadyProvider()) {
        // Opened on purpose, or mid sign-in: let the user see the result.
        if (!self.settings_controller.provider_onboarding_pinned and !self.settings_controller.provider_setup.visible()) {
            self.settings_controller.provider_onboarding_visible = false;
        }
        self.settings_controller.provider_onboarding_dismissed = false;
    } else if (!self.settings_controller.provider_onboarding_dismissed and !settings_open) {
        self.settings_controller.provider_onboarding_visible = true;
    }
    // MCP registration needs an installed provider to write to; until one
    // exists the dialog could only fail. Re-evaluated on every check so it
    // appears after the first install.
    if (!settings_open) {
        self.settings_controller.mcp_onboarding_visible = !self.app_config.mcp_onboarding_completed and
            !self.settings_controller.mcp_onboarding_snoozed and
            snapshot.hasMcpCapableProviderInstalled();
        if (self.settings_controller.mcp_onboarding_visible) self.blurPaletteComposer();
    }
    self.markDirty();
}

pub fn providerReadinessSnapshot(self: anytype) ProviderReadinessSnapshot {
    self.provider_controller.readiness.mutex.lock();
    defer self.provider_controller.readiness.mutex.unlock();
    return self.provider_controller.readiness.snapshot;
}

pub fn dismissProviderOnboarding(self: anytype) void {
    provider_setup.close(self);
    self.settings_controller.provider_onboarding_highlight = null;
    self.settings_controller.provider_onboarding_pinned = false;
    self.settings_controller.provider_onboarding_visible = false;
    self.settings_controller.provider_onboarding_dismissed = true;
    self.markDirty();
}

pub fn recheckProviderReadiness(self: anytype) void {
    self.settings_controller.provider_onboarding_pinned = true;
    const now_ms = platform_runtime.unixTimestampMs();
    self.settings_controller.provider_setup.last_recheck_ms = now_ms;
    // A check with nothing installed answers in a few ms; hold "Checking..."
    // long enough to read, so the click visibly did something.
    self.settings_controller.provider_setup.checking_until_ms = now_ms + provider_setup.MIN_CHECKING_VISIBLE_MS;
    self.settings_controller.provider_onboarding_visible = true;
    self.settings_controller.provider_onboarding_dismissed = false;
    // "Check again" shows "Checking..." until a check started after the
    // click completes, even when a timer check was already running.
    self.settings_controller.provider_recheck_generation = requestFreshProviderReadinessCheck(self);
    provider_setup.requestRemoteRefresh(&self.settings_controller.provider_setup);
    self.markDirty();
}

/// Opens the provider dialog scrolled to `provider`'s row, highlighted, so
/// a model picked from an unconnected provider lands on its Install / Sign in.
pub fn showProviderSetupFor(self: anytype, provider: Provider) void {
    self.settings_controller.provider_onboarding_highlight = provider;
    self.settings_controller.provider_onboarding_scroll_to_highlight = true;
    recheckProviderReadiness(self);
}

/// Settings > Providers Install / Sign in / Update: runs the command in the
/// dialog's own setup terminal, so it works before any workspace exists.
pub fn openProviderSetupCommand(self: anytype, provider: Provider, mode: provider_setup.Mode, shell: []const u8) void {
    // The dialog draws below Settings; close Settings so it is on top.
    if (self.settings_controller.modal_visible) self.cancelSettingsModal();
    self.settings_controller.provider_onboarding_highlight = provider;
    self.settings_controller.provider_onboarding_scroll_to_highlight = true;
    self.settings_controller.provider_onboarding_pinned = true;
    self.settings_controller.provider_onboarding_visible = true;
    self.settings_controller.provider_onboarding_dismissed = false;
    // These are this computer's CLIs, whatever runtime the active chat uses.
    provider_setup.pinLocal(self);
    provider_setup.startCommand(self, provider, mode, shell);
    if (!self.settings_controller.provider_setup.visible()) {
        // The terminal failed to start; the list still offers Copy.
        self.settings_controller.provider_setup.notes[@intFromEnum(provider)] = .failed;
    }
    self.markDirty();
}

pub fn openProviderSetupGuide(self: anytype) void {
    utils.openUrlInDefaultBrowser(self.allocator, "https://verdeai.dev/docs/providers") catch |err| {
        log.warn("failed to open provider setup guide: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not open the provider setup guide.");
        return;
    };
    self.setSidebarNotice("Opened provider setup guide.");
}

/// "Get Node.js" for a CLI Verde runs through Node (Claude Code).
pub fn openNodeDownloadPage(self: anytype) void {
    utils.openUrlInDefaultBrowser(self.allocator, provider_setup.NODE_DOWNLOAD_URL) catch |err| {
        log.warn("failed to open the Node.js download page: {s}", .{@errorName(err)});
        self.setSidebarNotice("Could not open nodejs.org. Install Node.js 18+ with your package manager.");
        return;
    };
    self.setSidebarNotice("Opened nodejs.org. Install Node.js 18+, then Check again.");
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

/// Null when there is nothing to fetch (no workspace yet, or the CLI is
/// known to be missing) or the worker could not start; only the latter warns.
fn spawnModelCacheWorker(self: anytype, comptime worker: anytype, state: anytype, provider: Provider) ?std.Thread {
    if (self.providerReadinessSnapshot().forProvider(provider) == .missing) return null;
    const request = createModelCacheWorkerRequest(self) orelse return null;
    return std.Thread.spawn(.{}, worker, .{ state, request }) catch |err| {
        request.deinit();
        log.warn("failed to spawn {s} model cache worker: {s}", .{ providerDisplayName(provider), @errorName(err) });
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
        .opencode,
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
        .cursor,
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
        .claude,
    ) orelse {
        self.provider_controller.claude_model_cache.status = .idle;
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
        .pi,
    ) orelse {
        self.provider_controller.pi_model_cache.status = .idle;
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
        .fx,
    ) orelse {
        self.provider_controller.fx_model_cache.status = .idle;
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
        .grok,
    ) orelse {
        self.provider_controller.grok_model_cache.status = .idle;
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
        .muse,
    ) orelse {
        self.provider_controller.muse_model_cache.status = .idle;
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
        const label = try self.allocator.dupeZ(u8, provider_models.cursorModelLabel(model.model_id, label_text));
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
/// grok's own persisted selection; every grok model supports reasoning
/// effort, with the catalog's per-model tiers kept on the row.
pub fn populateGrokModelOptions(self: anytype, models: []const provider_types.ModelInfo) !void {
    try appendDefaultModelOption(self, &self.grok_model_options, GROK_MODEL_OPTIONS[0]);
    for (models) |model| {
        if (model.model_id.len == 0) continue;
        const label_text = if (model.model_name.len > 0) model.model_name else model.model_id;
        const label = try self.allocator.dupeZ(u8, label_text);
        errdefer self.allocator.free(label);
        const value = try self.allocator.dupeZ(u8, model.model_id);
        errdefer self.allocator.free(value);
        const effort_values = try duplicateReasoningVariantKeys(self.allocator, model.grok_effort_values);
        errdefer if (effort_values) |values| {
            for (values) |effort_value| self.allocator.free(effort_value);
            self.allocator.free(values);
        };
        try self.grok_model_options.append(self.allocator, .{
            .label = label,
            .value = value,
            .reasoning_supported = true,
            .grok_effort_values = effort_values,
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
    if (thread.provider == .grok) return self.refreshGrokReasoningMenu(thread);
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

/// grok efforts stop at xhigh and vary per model (the catalog lists each
/// model's tiers); rows mirror GROK_REASONING_OPTIONS filtered to the selected
/// model, with effort tag names as row variants (parsed back by the shared
/// handler).
pub fn refreshGrokReasoningMenu(self: anytype, thread: *const ChatThread) !void {
    const values: ?[]const [:0]const u8 = if (self.grokModelOptionForRef(thread.model_ref)) |opt| opt.grok_effort_values else null;
    for (provider_models.GROK_REASONING_OPTIONS) |option| {
        if (option.value) |effort| {
            if (!provider_models.grokEffortSupported(values, effort)) continue;
        }
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

/// Exact match first; otherwise a context-window variant such as
/// `opus[1m]` resolves to its base alias (`opus`). The live SDK model list
/// omits the `[1m]` refs that orchestration children and the built-in
/// default use, and without this fallback those chats lose their reasoning
/// levels in the run pill and run-config popover.
/// grok picker row for a thread's model ref; "default" and unknown refs map
/// to no row, which keeps the static effort tiers.
pub fn grokModelOptionForRef(self: anytype, model_ref: ?[:0]const u8) ?ModelOption {
    const ref: []const u8 = model_ref orelse return null;
    return findModelOptionByValue(self.grokModelOptionsSnapshot(), ref);
}

pub fn claudeModelOptionForRef(self: anytype, model_ref: ?[:0]const u8) ?ModelOption {
    const ref: []const u8 = model_ref orelse DEFAULT_CLAUDE_MODEL;
    const options = self.claudeModelOptionsSnapshot();
    if (findModelOptionByValue(options, ref)) |opt| return opt;
    const base = claudeModelBaseRef(ref);
    if (base.len == ref.len) return null;
    return findModelOptionByValue(options, base);
}

/// Display name for a model ref the live catalog does not list (Claude's live
/// list can omit the built-in `fable[1m]` option), from the built-in catalog,
/// then Claude's base ref, so labels never fall back to the raw id when a
/// name is known. `live` is the provider's current option list.
pub fn knownModelLabel(provider: Provider, live: []const ModelOption, ref: []const u8) ?[]const u8 {
    const builtin_options: []const ModelOption = switch (provider) {
        .codex => provider_models.CODEX_MODEL_OPTIONS[0..],
        .claude => CLAUDE_MODEL_OPTIONS[0..],
        .cursor => CURSOR_MODEL_OPTIONS[0..],
        .opencode => OPENCODE_MODEL_OPTIONS[0..],
        .pi => PI_MODEL_OPTIONS[0..],
        .fx => FX_MODEL_OPTIONS[0..],
        .grok => GROK_MODEL_OPTIONS[0..],
        .muse => MUSE_MODEL_OPTIONS[0..],
        .custom_acp => &.{},
    };
    if (findModelOptionByValue(live, ref)) |option| return option.label;
    if (findModelOptionByValue(builtin_options, ref)) |option| return option.label;
    if (provider != .claude) return null;
    const base = claudeModelBaseRef(ref);
    if (base.len == ref.len) return null;
    if (findModelOptionByValue(live, base)) |option| return option.label;
    if (findModelOptionByValue(builtin_options, base)) |option| return option.label;
    return null;
}

/// `ref` without a trailing `[...]` variant suffix (`opus[1m]` -> `opus`).
pub fn claudeModelBaseRef(ref: []const u8) []const u8 {
    if (ref.len == 0 or ref[ref.len - 1] != ']') return ref;
    const open = std.mem.lastIndexOfScalar(u8, ref, '[') orelse return ref;
    if (open == 0) return ref;
    return ref[0..open];
}

fn findModelOptionByValue(options: []const ModelOption, ref: []const u8) ?ModelOption {
    for (options) |opt| {
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
        if (option.grok_effort_values) |values| {
            for (values) |value| self.allocator.free(value);
            self.allocator.free(values);
        }
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
        const label = try self.allocator.dupeZ(u8, provider_models.cursorModelLabel(option.value, option.label));
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

test "MCP dialog waits for an installed MCP-capable provider" {
    var snapshot: ProviderReadinessSnapshot = .{};
    try std.testing.expect(!snapshot.hasMcpCapableProviderInstalled());
    inline for (.{ "codex", "opencode", "claude", "cursor", "pi", "fx", "grok", "muse", "custom_acp" }) |name| @field(snapshot, name) = .missing;
    try std.testing.expect(!snapshot.hasMcpCapableProviderInstalled());
    // Muse has no MCP registration, so installing it alone is not enough.
    snapshot.muse = .ready;
    try std.testing.expect(!snapshot.hasMcpCapableProviderInstalled());
    snapshot.grok = .signed_out;
    try std.testing.expect(snapshot.hasMcpCapableProviderInstalled());
}

test "MCP enable notice reports what was actually enabled" {
    var buf: [192]u8 = undefined;
    try std.testing.expectEqualStrings("Verde MCP was not added: each detected provider already has a 'verde' entry, which was kept.", mcpEnableNotice(&buf, 0, 2, 0));
    try std.testing.expectEqualStrings("Could not enable Verde MCP: provider configs could not be updated.", mcpEnableNotice(&buf, 0, 1, 1));
    try std.testing.expectEqualStrings("Enabled Verde MCP for 2 providers; kept 1 existing 'verde' entry.", mcpEnableNotice(&buf, 2, 1, 0));
    try std.testing.expectEqualStrings("Enabled Verde tools for 1 detected provider.", mcpEnableNotice(&buf, 1, 0, 0));
}

test "every provider has a readiness setter" {
    var snapshot: ProviderReadinessSnapshot = .{};
    for (std.enums.values(Provider)) |provider| snapshot.setForProvider(provider, .unavailable);
    for (std.enums.values(Provider)) |provider| try std.testing.expectEqual(ProviderReadiness.unavailable, snapshot.forProvider(provider));
}

test "known model label names built-in models the live catalog omits" {
    const live = [_]ModelOption{
        .{ .label = "Opus", .value = "opus" },
        .{ .label = "Sonnet", .value = "sonnet" },
    };
    try std.testing.expectEqualStrings("Fable 5.1", knownModelLabel(.claude, &live, "fable[1m]").?);
    try std.testing.expectEqualStrings("Sonnet", knownModelLabel(.claude, &live, "sonnet[1m]").?);
    try std.testing.expect(knownModelLabel(.claude, &live, "mystery") == null);
    try std.testing.expect(knownModelLabel(.custom_acp, &.{}, "agent") == null);
}
