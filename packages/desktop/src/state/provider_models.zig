//! Provider capabilities, model metadata, and static model options.

const std = @import("std");
const db_types = @import("../db/types.zig");

pub const ReasoningEffort = db_types.ReasoningEffort;
pub const FastMode = db_types.FastMode;
pub const AccessMode = db_types.AccessMode;
pub const ChatRole = db_types.ChatRole;
pub const Provider = db_types.Provider;
pub const Harness = db_types.Harness;

pub const DEFAULT_CODEX_MODEL: [:0]const u8 = "gpt-5.6-sol";
pub const DEFAULT_CODEX_REASONING_EFFORT: ReasoningEffort = .low;
pub const DEFAULT_OPENCODE_MODEL: [:0]const u8 = "opencode/gpt-5.4";
pub const DEFAULT_CLAUDE_MODEL: [:0]const u8 = "default";
pub const DEFAULT_CURSOR_MODEL: [:0]const u8 = "composer-2";

pub const ModelOption = struct {
    label: [:0]const u8,
    value: ?[:0]const u8 = null,
    /// From OpenCode model metadata (`capabilities.reasoning`); presets default to true.
    reasoning_supported: bool = true,
    /// Sorted OpenCode `variants` keys; owned with the option row (freed in `clearDynamicOpencodeModelOptions`).
    reasoning_variant_keys: ?[][:0]const u8 = null,
    cursor_fast_supported: bool = false,
    cursor_reasoning_param_id: ?[:0]const u8 = null,
    cursor_reasoning_values: ?[][:0]const u8 = null,
    cursor_reasoning_requires_thinking: bool = false,
    claude_effort_values: ?[]const [:0]const u8 = null,
};

pub const OpencodeReasoningMenuRow = struct {
    label: [:0]const u8,
    /// Null selects the default (no `variant` field on the wire).
    variant: ?[:0]const u8,
};

pub const PersistedCursorModelOption = struct {
    label: []const u8,
    value: []const u8,
    fast_supported: bool = false,
    reasoning_param_id: ?[]const u8 = null,
    reasoning_values: ?[]const []const u8 = null,
    reasoning_requires_thinking: bool = false,
};

pub fn persistedCursorModelCacheNeedsRefresh(options: []const PersistedCursorModelOption) bool {
    for (options) |option| {
        if (std.mem.eql(u8, option.value, "composer-2.5-fast") or
            std.mem.eql(u8, option.value, "composer-2-fast"))
        {
            return true;
        }
    }
    return false;
}

pub fn cursorReasoningValueLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "low")) return "Low";
    if (std.mem.eql(u8, value, "medium")) return "Medium";
    if (std.mem.eql(u8, value, "high")) return "High";
    if (std.mem.eql(u8, value, "extra-high") or std.mem.eql(u8, value, "xhigh")) return "Extra High";
    if (std.mem.eql(u8, value, "max")) return "Max";
    if (std.mem.eql(u8, value, "none")) return "None";
    return value;
}

pub fn parseReasoningEffort(value: []const u8) ?ReasoningEffort {
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

pub fn claudeEffortValueLabel(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "xhigh")) return "Xhigh";
    if (std.mem.eql(u8, value, "max")) return "Max";
    return cursorReasoningValueLabel(value);
}

pub fn reasoningEffortDisplayLabel(value: ReasoningEffort) []const u8 {
    return switch (value) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Xhigh",
        .max => "Max",
    };
}

pub const ReasoningOption = struct {
    label: [:0]const u8,
    value: ?ReasoningEffort = null,
};

pub const FastModeOption = struct {
    label: [:0]const u8,
    value: FastMode,
};

pub const AccessModeOption = struct {
    label: [:0]const u8,
    value: AccessMode,
};

pub const OPENCODE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "GPT-5.5", .value = "opencode/gpt-5.5" },
    .{ .label = "GPT-5.4", .value = "opencode/gpt-5.4" },
    .{ .label = "Claude Opus 4.7", .value = "opencode/claude-opus-4-7" },
    .{ .label = "Claude Opus 4.6", .value = "opencode/claude-opus-4-6" },
    .{ .label = "Claude Sonnet 4.5", .value = "opencode/claude-sonnet-4-5" },
    .{ .label = "Gemini 3.1 Pro", .value = "opencode/gemini-3.1-pro" },
};

pub const CODEX_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "GPT-5.6 Sol", .value = "gpt-5.6-sol" },
    .{ .label = "GPT-5.5", .value = "gpt-5.5" },
    .{ .label = "GPT-5.6 Terra", .value = "gpt-5.6-terra" },
    .{ .label = "GPT-5.6 Luna", .value = "gpt-5.6-luna" },
    .{ .label = "GPT-5.4", .value = "gpt-5.4" },
    .{ .label = "GPT-5.4 Mini", .value = "gpt-5.4-mini" },
    .{ .label = "GPT-5.3 Codex", .value = "gpt-5.3-codex" },
    .{ .label = "GPT-5.3 Codex Spark", .value = "gpt-5.3-codex-spark" },
    .{ .label = "GPT-5.2 Codex", .value = "gpt-5.2-codex" },
    .{ .label = "GPT-5.2", .value = "gpt-5.2" },
};

pub const CURSOR_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Auto", .value = "auto" },
    .{ .label = "Composer 2.5", .value = "composer-2.5", .cursor_fast_supported = true },
    .{ .label = "Composer 2", .value = DEFAULT_CURSOR_MODEL, .cursor_fast_supported = true },
    .{ .label = "GPT-5.5", .value = "gpt-5.5-medium", .cursor_fast_supported = true },
    .{ .label = "GPT-5.4", .value = "gpt-5.4-medium", .cursor_fast_supported = true },
    .{ .label = "Claude Opus 4.7", .value = "claude-opus-4-7" },
    .{ .label = "Claude Sonnet 4.5", .value = "claude-sonnet-4-5" },
};

/// Conservative fallback when a dynamic model row does not report its effort tiers.
pub const CLAUDE_STANDARD_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high" };
/// Full effort range reported by the Claude Agent SDK for current reasoning models.
pub const CLAUDE_FULL_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high", "xhigh", "max" };

/// Static fallback shown until the async bridge `list_models` response replaces it.
/// Keep this mirroring the Agent SDK's `supportedModels()` output (labels + ids)
/// so the picker doesn't flash stale model names while the bridge loads.
pub const CLAUDE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Default (Opus 5)", .value = DEFAULT_CLAUDE_MODEL, .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Opus 5 (1M context)", .value = "opus[1m]", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Fable", .value = "claude-fable-5[1m]", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Sonnet 5", .value = "sonnet", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Haiku 4.5", .value = "haiku", .reasoning_supported = false },
};

pub const CODEX_REASONING_OPTIONS = [_]ReasoningOption{
    .{ .label = "Default", .value = null },
    .{ .label = "Low", .value = .low },
    .{ .label = "Medium", .value = .medium },
    .{ .label = "High", .value = .high },
    .{ .label = "Xhigh", .value = .xhigh },
};

pub const CODEX_FAST_MODE_OPTIONS = [_]FastModeOption{
    .{ .label = "Off", .value = .off },
    .{ .label = "On", .value = .on },
};

pub const CODEX_ACCESS_MODE_OPTIONS = [_]AccessModeOption{
    .{ .label = "Full access", .value = .full_access },
    .{ .label = "Supervised", .value = .supervised },
};
