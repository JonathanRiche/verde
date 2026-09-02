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
pub const DEFAULT_CLAUDE_MODEL: [:0]const u8 = "fable[1m]";
pub const DEFAULT_CURSOR_MODEL: [:0]const u8 = "composer-2.5";
pub const DEFAULT_PI_MODEL: [:0]const u8 = "default";
pub const DEFAULT_FX_MODEL: [:0]const u8 = "default";
pub const DEFAULT_GROK_MODEL: [:0]const u8 = "default";

pub const ModelOption = struct {
    label: [:0]const u8,
    value: ?[:0]const u8 = null,
    /// From OpenCode model metadata (`capabilities.reasoning`); presets default to true.
    reasoning_supported: bool = true,
    /// Sorted OpenCode `variants` keys; owned with the option row (freed in `clearDynamicOpencodeModelOptions`).
    reasoning_variant_keys: ?[][:0]const u8 = null,
    cursor_fast_supported: bool = false,
    cursor_reasoning_param_id: ?[:0]const u8 = null,
    cursor_reasoning_values: ?[]const [:0]const u8 = null,
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
    for (options, 0..) |option, index| {
        if (std.mem.eql(u8, option.value, "composer-2.5-fast") or
            std.mem.eql(u8, option.value, "composer-2-fast"))
        {
            return true;
        }
        for (options[index + 1 ..]) |other| {
            if (std.mem.eql(u8, option.value, other.value)) return true;
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
    .{ .label = "GPT-5.3 Codex Spark", .value = "gpt-5.3-codex-spark" },
};

const CURSOR_GROK_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high" };
const CURSOR_GPT_FULL_EFFORT_VALUES = [_][:0]const u8{ "none", "low", "medium", "high", "xhigh", "max" };
const CURSOR_GPT_55_EFFORT_VALUES = [_][:0]const u8{ "none", "low", "medium", "high", "extra-high" };
const CURSOR_GPT_54_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high", "xhigh" };
const CURSOR_CLAUDE_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high", "xhigh", "max" };

pub const CURSOR_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Auto", .value = "auto" },
    .{ .label = "Composer 2.5", .value = DEFAULT_CURSOR_MODEL, .cursor_fast_supported = true },
    .{ .label = "Cursor Grok 4.5", .value = "cursor-grok-4.5-high", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GROK_EFFORT_VALUES[0..] },
    .{ .label = "Opus 4.8 Thinking", .value = "claude-opus-4-8-thinking-high", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_CLAUDE_EFFORT_VALUES[0..] },
    .{ .label = "GPT-5.6 Sol", .value = "gpt-5.6-sol-medium", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GPT_FULL_EFFORT_VALUES[0..] },
    .{ .label = "GPT-5.5", .value = "gpt-5.5-medium", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GPT_55_EFFORT_VALUES[0..] },
    .{ .label = "Fable 5 Thinking", .value = "claude-fable-5-thinking-high", .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_CLAUDE_EFFORT_VALUES[0..] },
    .{ .label = "Sonnet 5 Thinking", .value = "claude-sonnet-5-thinking-high", .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_CLAUDE_EFFORT_VALUES[0..] },
    .{ .label = "GPT-5.6 Terra", .value = "gpt-5.6-terra-medium", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GPT_FULL_EFFORT_VALUES[0..] },
    .{ .label = "GPT-5.6 Luna", .value = "gpt-5.6-luna-medium", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GPT_FULL_EFFORT_VALUES[0..] },
    .{ .label = "GPT-5.4", .value = "gpt-5.4-medium", .cursor_fast_supported = true, .cursor_reasoning_param_id = "effort", .cursor_reasoning_values = CURSOR_GPT_54_EFFORT_VALUES[0..] },
    .{ .label = "Gemini 3.1 Pro", .value = "gemini-3.1-pro" },
    .{ .label = "Gemini 3.5 Flash", .value = "gemini-3.5-flash" },
    .{ .label = "Kimi K3", .value = "kimi-k3" },
    .{ .label = "GLM 5.2", .value = "glm-5.2-high" },
};

/// Conservative fallback when a dynamic model row does not report its effort tiers.
pub const CLAUDE_STANDARD_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high" };
/// Full effort range reported by the Claude Agent SDK for current reasoning models.
pub const CLAUDE_FULL_EFFORT_VALUES = [_][:0]const u8{ "low", "medium", "high", "xhigh", "max" };

/// Static fallback shown until the async bridge `list_models` response replaces it.
/// Keep this mirroring the Agent SDK's `supportedModels()` output (labels + ids)
/// so the picker doesn't flash stale model names while the bridge loads.
pub const CLAUDE_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Fable 5.1", .value = DEFAULT_CLAUDE_MODEL, .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Default (Opus 5)", .value = "default", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Opus 5 (1M context)", .value = "opus[1m]", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Sonnet 5", .value = "sonnet", .reasoning_supported = true, .claude_effort_values = CLAUDE_FULL_EFFORT_VALUES[0..] },
    .{ .label = "Haiku 4.5", .value = "haiku", .reasoning_supported = false },
};

/// Static fallback shown until the async pi `get_available_models` response
/// replaces it. "default" defers to the model configured inside pi itself.
pub const PI_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Default (pi config)", .value = DEFAULT_PI_MODEL, .reasoning_supported = true },
    .{ .label = "GPT-5.6 Sol", .value = "openai-codex/gpt-5.6-sol", .reasoning_supported = true },
    .{ .label = "GPT-5.5", .value = "openai-codex/gpt-5.5", .reasoning_supported = true },
    .{ .label = "GPT-5.4 Mini", .value = "openai-codex/gpt-5.4-mini", .reasoning_supported = true },
    .{ .label = "Gemini 3.1 Pro", .value = "google/gemini-3.1-pro-preview", .reasoning_supported = true },
    .{ .label = "Gemini 3.5 Flash", .value = "google/gemini-3.5-flash", .reasoning_supported = true },
};

/// Verde reasoning efforts are a strict subset of pi thinking levels, so every
/// tier is offered; "Default" leaves pi's configured thinking level untouched.
/// Static fallback shown until the async `fx acp` catalog discovery completes.
/// "default" defers to the model persisted inside fx itself (`fx acp` without
/// a --model override).
pub const FX_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Default (fx config)", .value = DEFAULT_FX_MODEL, .reasoning_supported = false },
    // fx's default provider is the Vercel AI Gateway, whose ids are
    // "<vendor>/<model>"; bare Codex-subscription ids (gpt-5.6-sol, ...) get
    // HTTP 403 from the gateway and surface only as "HTTP error".
    .{ .label = "GPT-5.2", .value = "openai/gpt-5.2", .reasoning_supported = false },
    .{ .label = "GPT-5.4 Mini", .value = "openai/gpt-5.4-mini", .reasoning_supported = false },
    .{ .label = "GPT-5.1 Codex", .value = "openai/gpt-5.1-codex", .reasoning_supported = false },
    .{ .label = "Claude Sonnet 5", .value = "anthropic/claude-sonnet-5", .reasoning_supported = false },
};

/// Static fallback shown until the async `grok agent stdio` initialize
/// handshake reports the live catalog. "default" defers to the model persisted
/// inside grok itself (no `--model` override).
pub const GROK_MODEL_OPTIONS = [_]ModelOption{
    .{ .label = "Default (grok config)", .value = DEFAULT_GROK_MODEL, .reasoning_supported = true },
    .{ .label = "Grok 4.6", .value = "grok-4.6", .reasoning_supported = true },
    .{ .label = "Grok 4.5", .value = "grok-4.5", .reasoning_supported = true },
};

pub const PI_REASONING_OPTIONS = [_]ReasoningOption{
    .{ .label = "Default", .value = null },
    .{ .label = "Low", .value = .low },
    .{ .label = "Medium", .value = .medium },
    .{ .label = "High", .value = .high },
    .{ .label = "Xhigh", .value = .xhigh },
    .{ .label = "Max", .value = .max },
};

/// grok advertises per-model reasoning efforts capped at `xhigh`; Verde's
/// `max` tier is not offered. "Default" leaves grok's persisted effort untouched.
pub const GROK_REASONING_OPTIONS = [_]ReasoningOption{
    .{ .label = "Default", .value = null },
    .{ .label = "Low", .value = .low },
    .{ .label = "Medium", .value = .medium },
    .{ .label = "High", .value = .high },
    .{ .label = "Xhigh", .value = .xhigh },
};

pub const CODEX_REASONING_OPTIONS = [_]ReasoningOption{
    .{ .label = "Default", .value = null },
    .{ .label = "Low", .value = .low },
    .{ .label = "Medium", .value = .medium },
    .{ .label = "High", .value = .high },
    .{ .label = "Xhigh", .value = .xhigh },
};

pub const CODEX_56_REASONING_OPTIONS = CODEX_REASONING_OPTIONS ++ [_]ReasoningOption{
    .{ .label = "Max", .value = .max },
};

/// Returns the reasoning efforts supported by the selected Codex model.
pub fn codexReasoningOptions(model_ref: ?[]const u8) []const ReasoningOption {
    const model = model_ref orelse DEFAULT_CODEX_MODEL;
    if (std.mem.eql(u8, model, "gpt-5.6-sol") or
        std.mem.eql(u8, model, "gpt-5.6-terra") or
        std.mem.eql(u8, model, "gpt-5.6-luna"))
    {
        return CODEX_56_REASONING_OPTIONS[0..];
    }
    return CODEX_REASONING_OPTIONS[0..];
}

pub const CODEX_FAST_MODE_OPTIONS = [_]FastModeOption{
    .{ .label = "Off", .value = .off },
    .{ .label = "On", .value = .on },
};

pub const CODEX_ACCESS_MODE_OPTIONS = [_]AccessModeOption{
    .{ .label = "Full access", .value = .full_access },
    .{ .label = "Supervised", .value = .supervised },
};

test "Codex model options omit unsupported subscription models" {
    try std.testing.expectEqual(@as(usize, 5), CODEX_MODEL_OPTIONS.len);
    try std.testing.expectEqualStrings("gpt-5.6-sol", CODEX_MODEL_OPTIONS[0].value.?);
    try std.testing.expectEqualStrings("gpt-5.5", CODEX_MODEL_OPTIONS[1].value.?);
    try std.testing.expectEqualStrings("gpt-5.6-terra", CODEX_MODEL_OPTIONS[2].value.?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", CODEX_MODEL_OPTIONS[3].value.?);
    try std.testing.expectEqualStrings("gpt-5.3-codex-spark", CODEX_MODEL_OPTIONS[4].value.?);
}

test "Codex 5.6 models expose max reasoning" {
    for ([_][]const u8{ "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna" }) |model| {
        const options = codexReasoningOptions(model);
        try std.testing.expectEqual(ReasoningEffort.max, options[options.len - 1].value.?);
    }
    try std.testing.expectEqual(@as(usize, 5), codexReasoningOptions("gpt-5.5").len);
    try std.testing.expectEqual(@as(usize, 5), codexReasoningOptions("gpt-5.3-codex-spark").len);
}

test "Claude fallback defaults to Fable 5.1" {
    try std.testing.expectEqualStrings("fable[1m]", DEFAULT_CLAUDE_MODEL);
    try std.testing.expectEqualStrings("Fable 5.1", CLAUDE_MODEL_OPTIONS[0].label);
    try std.testing.expectEqualStrings(DEFAULT_CLAUDE_MODEL, CLAUDE_MODEL_OPTIONS[0].value.?);
}

test "persisted Cursor model cache refreshes duplicate model ids" {
    const options = [_]PersistedCursorModelOption{
        .{ .label = "GPT-5.6 Sol", .value = "gpt-5.6-sol-medium" },
        .{ .label = "GPT-5.6 Sol Fast", .value = "gpt-5.6-sol-medium", .fast_supported = true },
    };
    try std.testing.expect(persistedCursorModelCacheNeedsRefresh(&options));
}
