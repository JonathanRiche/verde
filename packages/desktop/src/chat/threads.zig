//! Thread-specific labels and helper functions.

const std = @import("std");

/// Returns the display label for a provider.
pub fn providerLabel(provider: anytype) [:0]const u8 {
    return switch (provider) {
        .opencode => "OpenCode",
        .codex => "Codex",
        .cursor => "Cursor",
    };
}

/// Returns the display label for a harness.
pub fn harnessLabel(harness: anytype) [:0]const u8 {
    return switch (harness) {
        .local_cli => "Local CLI",
        .remote_session => "Remote Session",
    };
}

/// Returns the access-mode label shown in the composer.
pub fn accessModeLabel(mode: anytype) [:0]const u8 {
    return switch (mode) {
        .full_access => "Full access",
        .supervised => "Supervised",
    };
}

/// Returns the model options for the active provider.
pub fn modelOptions(comptime Option: type, provider: anytype, opencode_options: []const Option, codex_options: []const Option) []const Option {
    return switch (provider) {
        .opencode => opencode_options,
        .codex => codex_options,
        .cursor => codex_options,
    };
}

/// Returns the current model label for a thread.
pub fn selectedModelLabel(comptime Option: type, thread: anytype, opencode_options: []const Option, codex_options: []const Option) [:0]const u8 {
    if (thread.model_ref) |model_ref| {
        for (modelOptions(Option, thread.provider, opencode_options, codex_options)) |option| {
            if (option.value) |value| {
                if (std.mem.eql(u8, model_ref, value)) return option.label;
            }
        }
    }
    const options = modelOptions(Option, thread.provider, opencode_options, codex_options);
    return if (options.len > 0) options[0].label else "Model";
}

/// Returns the current reasoning label for a thread.
pub fn selectedReasoningLabel(comptime Option: type, thread: anytype, reasoning_options: []const Option) [:0]const u8 {
    if (thread.reasoning_effort) |effort| {
        for (reasoning_options) |option| {
            if (option.value) |value| {
                if (value == effort) return option.label;
            }
        }
    }
    return "Reasoning";
}

/// Returns the saved committed-thread selection index.
pub fn selectedCommittedThreadIndex(project: anytype) usize {
    var committed_index: usize = 0;
    var fallback_index: usize = 0;
    for (project.threads.items, 0..) |thread, index| {
        if (!thread.committed) continue;
        if (index == project.selected_thread_index) return committed_index;
        committed_index += 1;
        fallback_index = committed_index - 1;
    }
    return if (committed_index == 0) 0 else fallback_index;
}

/// Builds a short title from the first prompt text.
pub fn makeThreadTitle(allocator: std.mem.Allocator, prompt: []const u8) ![:0]const u8 {
    const trimmed = std.mem.trim(u8, prompt, &std.ascii.whitespace);
    if (trimmed.len == 0) return try allocator.dupeZ(u8, "New chat");

    var compact: [96]u8 = undefined;
    var count: usize = 0;
    var saw_space = false;
    for (trimmed) |char| {
        const normalized = if (std.ascii.isWhitespace(char)) ' ' else char;
        if (normalized == ' ') {
            if (count == 0 or saw_space) continue;
            saw_space = true;
        } else {
            saw_space = false;
        }
        if (count == compact.len) break;
        compact[count] = normalized;
        count += 1;
    }

    while (count > 0 and compact[count - 1] == ' ') {
        count -= 1;
    }
    if (count == 0) return try allocator.dupeZ(u8, "New chat");
    return try allocator.dupeZ(u8, compact[0..count]);
}

/// Restores persisted enum values to a valid known variant.
pub fn sanitizeEnum(comptime Enum: type, value: *Enum, fallback: Enum) void {
    const raw = @as(*u8, @ptrCast(value)).*;
    value.* = std.enums.fromInt(Enum, raw) orelse fallback;
}
