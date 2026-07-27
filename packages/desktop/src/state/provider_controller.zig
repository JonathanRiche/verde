//! Provider readiness and asynchronous model-discovery controller state.

const std = @import("std");
const ai_harness = @import("../providers/harness.zig");
const app_config = @import("../app/config.zig");
const process_env = @import("../platform/env.zig");
const provider_mcp = @import("../providers/mcp.zig");
const utils = @import("../utils.zig");
const chat_types = @import("chat_types.zig");
const provider_models = @import("provider_models.zig");
const state_sync = @import("sync.zig");

const log = std.log.scoped(.native_shell);
const Provider = provider_models.Provider;
const ModelOption = provider_models.ModelOption;
const ChatThread = chat_types.ChatThread;
const Mutex = state_sync.Mutex;
const CURSOR_MODEL_CACHE_FILE_NAME = "cursor-models.json";
const DEFAULT_CODEX_MODEL = provider_models.DEFAULT_CODEX_MODEL;
const DEFAULT_OPENCODE_MODEL = provider_models.DEFAULT_OPENCODE_MODEL;
const DEFAULT_CLAUDE_MODEL = provider_models.DEFAULT_CLAUDE_MODEL;
const DEFAULT_CURSOR_MODEL = provider_models.DEFAULT_CURSOR_MODEL;
const OPENCODE_MODEL_OPTIONS = provider_models.OPENCODE_MODEL_OPTIONS;
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
    models: ?[]ai_harness.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const CursorModelCacheStatus = OpencodeModelCacheStatus;

pub const CursorModelCacheState = struct {
    mutex: Mutex = .{},
    status: CursorModelCacheStatus = .idle,
    models: ?[]ai_harness.ModelInfo = null,
    worker: ?std.Thread = null,
};

pub const ClaudeModelCacheStatus = OpencodeModelCacheStatus;

pub const ClaudeModelCacheState = struct {
    mutex: Mutex = .{},
    status: ClaudeModelCacheStatus = .idle,
    models: ?[]ai_harness.ModelInfo = null,
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

    pub fn forProvider(self: ProviderReadinessSnapshot, provider: Provider) ProviderReadiness {
        return switch (provider) {
            .codex => self.codex,
            .opencode => self.opencode,
            .claude => self.claude,
            .cursor => self.cursor,
        };
    }

    pub fn hasReadyProvider(self: ProviderReadinessSnapshot) bool {
        return self.codex == .ready or self.opencode == .ready or self.claude == .ready or self.cursor == .ready;
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

pub const State = struct {
    opencode_model_cache: OpencodeModelCacheState = .{},
    claude_model_cache: ClaudeModelCacheState = .{},
    cursor_model_cache: CursorModelCacheState = .{},
    readiness: ProviderReadinessState = .{},
};

pub fn providerReadinessWorker(state: *ProviderReadinessState) void {
    const snapshot: ProviderReadinessSnapshot = .{
        .codex = detectProviderReadiness(.codex),
        .opencode = detectProviderReadiness(.opencode),
        .claude = detectProviderReadiness(.claude),
        .cursor = detectProviderReadiness(.cursor),
    };

    state.mutex.lock();
    defer state.mutex.unlock();
    state.snapshot = snapshot;
    state.status = .completed;
}

pub fn detectProviderReadiness(provider: Provider) ProviderReadiness {
    const executable_ready = switch (provider) {
        .codex => process_env.commandExists("codex"),
        .opencode => process_env.commandExists("opencode"),
        .claude => process_env.commandExists("node") and process_env.commandExists("claude"),
        .cursor => process_env.commandExists("agent"),
    };
    if (!executable_ready) return .missing;

    const provider_config = switch (provider) {
        .codex => ai_harness.ProviderConfig{ .codex = .{} },
        .opencode => ai_harness.ProviderConfig{ .opencode = .{
            .allocator = std.heap.page_allocator,
            .working_directory = null,
            .launch_if_missing = true,
        } },
        .claude => ai_harness.ProviderConfig{ .claude = .{} },
        .cursor => ai_harness.ProviderConfig{ .cursor = .{} },
    };
    var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
        log.warn("provider readiness connect failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    defer client.deinit();

    const auth_state = client.authState() catch |err| {
        log.warn("provider readiness auth failed provider={s}: {s}", .{ @tagName(provider), @errorName(err) });
        return if (err == error.FileNotFound) .missing else .unavailable;
    };
    return switch (auth_state) {
        .signed_in => .ready,
        .signed_out => .signed_out,
        .unknown, .pending => .unavailable,
    };
}

pub fn opencodeModelCacheWorker(state: *OpencodeModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .opencode = .{
            .allocator = std.heap.page_allocator,
            .working_directory = null,
            .launch_if_missing = true,
        },
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to OpenCode for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load OpenCode configured models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

pub fn cursorModelCacheWorker(state: *CursorModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .cursor = .{},
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to Cursor for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load Cursor models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
}

pub fn claudeModelCacheWorker(state: *ClaudeModelCacheState) void {
    const provider_config = ai_harness.ProviderConfig{
        .claude = .{},
    };

    const models = blk: {
        var client = ai_harness.connect(std.heap.page_allocator, provider_config) catch |err| {
            log.warn("failed to connect to Claude for model discovery: {s}", .{@errorName(err)});
            break :blk null;
        };
        defer client.deinit();

        break :blk client.listModels(std.heap.page_allocator) catch |err| {
            log.warn("failed to load Claude models: {s}", .{@errorName(err)});
            break :blk null;
        };
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    if (models) |loaded| {
        state.models = loaded;
        state.status = .completed;
    } else {
        state.status = .failed;
    }
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

pub fn startProviderReadinessCheck(self: anytype) void {
    self.pollProviderReadiness();

    self.provider_controller.readiness.mutex.lock();
    defer self.provider_controller.readiness.mutex.unlock();
    if (self.provider_controller.readiness.status == .pending) return;

    self.provider_controller.readiness.status = .pending;
    self.provider_controller.readiness.snapshot = .{};
    self.provider_controller.readiness.worker = std.Thread.spawn(.{}, providerReadinessWorker, .{
        &self.provider_controller.readiness,
    }) catch {
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
        const summary = provider_mcp.install(self.allocator) catch |err| {
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

pub fn refreshOpencodeModelOptionsCacheAsync(self: anytype) void {
    self.pollOpencodeModelOptionsCache();

    self.provider_controller.opencode_model_cache.mutex.lock();
    defer self.provider_controller.opencode_model_cache.mutex.unlock();
    if (self.provider_controller.opencode_model_cache.status == .pending) return;

    self.provider_controller.opencode_model_cache.status = .pending;
    self.provider_controller.opencode_model_cache.worker = std.Thread.spawn(.{}, opencodeModelCacheWorker, .{
        &self.provider_controller.opencode_model_cache,
    }) catch {
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
    self.provider_controller.cursor_model_cache.worker = std.Thread.spawn(.{}, cursorModelCacheWorker, .{
        &self.provider_controller.cursor_model_cache,
    }) catch {
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
    self.provider_controller.claude_model_cache.worker = std.Thread.spawn(.{}, claudeModelCacheWorker, .{
        &self.provider_controller.claude_model_cache,
    }) catch {
        self.provider_controller.claude_model_cache.status = .idle;
        log.warn("failed to spawn Claude model cache worker", .{});
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

pub fn populateOpencodeModelOptions(self: anytype, models: []const ai_harness.ModelInfo) !void {
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

pub fn opencodeSortedModelsContainModelIdFromOrder(order: []const usize, model_list: []const ai_harness.ModelInfo, model_id: []const u8) bool {
    for (order) |mi| {
        if (std.mem.eql(u8, model_list[mi].model_id, model_id)) return true;
    }
    return false;
}

pub fn opencodeModelSortLessThan(a: ai_harness.ModelInfo, b: ai_harness.ModelInfo) bool {
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

pub fn populateCursorModelOptions(self: anytype, models: []const ai_harness.ModelInfo) !void {
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

pub fn populateClaudeModelOptions(self: anytype, models: []const ai_harness.ModelInfo) !void {
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
    models: ?[]ai_harness.ModelInfo = null,
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
            defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
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
            defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
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

pub fn pollClaudeModelOptionsCache(self: anytype) void {
    const poll = takeModelCachePoll(&self.provider_controller.claude_model_cache);
    if (poll.status != .idle) {
        self.finishClaudeModelCacheThread();
    }

    switch (poll.status) {
        .completed => {
            const models = poll.models orelse return;
            defer ai_harness.freeModelInfos(std.heap.page_allocator, models);
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
