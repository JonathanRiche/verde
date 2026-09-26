//! Pure composer catalogs and Usage transcript parsing, ported from the web client.
const std = @import("std");
const m = @import("chat_models.zig");
const p = @import("projection.zig");
const h = @import("host.zig");
const eq = h.eq;
const A = std.mem.Allocator;
const V = std.json.Value;
pub fn append(comptime T: type, a: A, dest: *[]const T, item: T) h.ApiError!void {
    if (dest.len >= 100_000) return error.ResourceLimit;
    const next = try a.alloc(T, dest.len + 1);
    @memcpy(next[0..dest.len], dest.*);
    next[dest.len] = item;
    dest.* = next;
}
fn choices(a: A, ids: []const []const u8) ![]const m.Choice {
    const out = try a.alloc(m.Choice, ids.len);
    for (ids, out) |id, *v| v.* = .{ .id = id, .label = choiceLabel(id) };
    return out;
}
pub fn catalogs(a: A, selection: m.Selection, dynamic: V, slash: V) h.ApiError!m.Catalogs {
    const provider = selection.provider orelse "codex";
    var out: m.Catalogs = .{};
    for (p.rows(p.get(dynamic, "models"))) |row| {
        const id = p.s(row, "model_id");
        if (id.len == 0) continue;
        const value = if (eq(provider, "opencode") and p.s(row, "provider_id").len > 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ p.s(row, "provider_id"), id }) else id;
        try append(m.Choice, a, &out.models, .{ .id = value, .label = if (p.s(row, "model_name").len > 0) p.s(row, "model_name") else id });
    }
    if (out.models.len == 0) out.models = try choices(a, fallback(provider));
    const model = selection.model orelse if (out.models.len > 0) out.models[0].id else "";
    var selected: V = .null;
    for (p.rows(p.get(dynamic, "models"))) |row| {
        const id = p.s(row, "model_id");
        if (eq(model, id) or (eq(provider, "opencode") and std.mem.endsWith(u8, model, id))) selected = row;
    }
    var effort_values: []const []const u8 = &.{};
    const key = if (eq(provider, "claude")) "claude_effort_values" else if (eq(provider, "cursor")) "cursor_reasoning_values" else "reasoning_variant_keys";
    for (p.rows(p.get(selected, key))) |v| if (v == .string) {
        try append([]const u8, a, &effort_values, v.string);
    };
    if (effort_values.len > 0) {
        out.efforts = try choices(a, effort_values);
    } else if ((eq(provider, "codex") or eq(provider, "claude") or eq(provider, "pi") or eq(provider, "grok") or eq(provider, "muse")) and !eq(model, "haiku") and !(p.get(selected, "reasoning_supported") == .bool and !p.yes(p.get(selected, "reasoning_supported")))) {
        out.efforts = try choices(a, if (eq(provider, "grok") or eq(model, "gpt-5.5")) &.{ "", "low", "medium", "high", "xhigh" } else &.{ "", "low", "medium", "high", "xhigh", "max" });
    }
    if (eq(provider, "cursor") and selected == .null) {
        const variants: []const []const u8 = if (eq(model, "grok-4.7-medium")) &.{ "low", "medium", "high", "xhigh" } else if (eq(model, "cursor-grok-4.5-high")) &.{ "low", "medium", "high" } else if (eq(model, "gpt-5.5-medium")) &.{ "none", "low", "medium", "high", "extra-high" } else if (eq(model, "gpt-5.4-medium")) &.{ "low", "medium", "high", "xhigh" } else if (std.mem.startsWith(u8, model, "gpt-5.6-")) &.{ "none", "low", "medium", "high", "xhigh", "max" } else if (std.mem.startsWith(u8, model, "claude-")) &.{ "low", "medium", "high", "xhigh", "max" } else &.{};
        out.efforts = try choices(a, variants);
    }
    if (eq(provider, "claude") and selected != .null and effort_values.len == 0 and !(p.get(selected, "reasoning_supported") == .bool and !p.yes(p.get(selected, "reasoning_supported")))) out.efforts = try choices(a, &.{ "", "low", "medium", "high" });
    out.access = try choices(a, &.{ "supervised", "full_access" });
    out.speeds = try choices(a, if (eq(provider, "codex") or (eq(provider, "cursor") and (p.yes(p.get(selected, "cursor_fast_supported")) or (selected == .null and (std.mem.startsWith(u8, model, "gpt-") or eq(model, "grok-4.7-medium") or eq(model, "composer-2.5") or eq(model, "cursor-grok-4.5-high") or eq(model, "claude-opus-4-8-thinking-high")))))) &.{ "off", "on" } else &.{"off"});
    for (p.rows(p.get(slash, "commands"))) |row| {
        const availability = p.s(row, "availability");
        try append(m.Choice, a, &out.slash, .{ .id = p.s(row, "id"), .label = p.s(row, "name"), .enabled = availability.len == 0 or eq(availability, "available"), .reason = if (availability.len > 0 and !eq(availability, "available")) availability else null });
    }
    return out;
}
/// Marks models starred in the desktop config (`config.chat.favorite_models`) for this provider.
pub fn favorites(a: A, catalog: m.Catalogs, provider: []const u8, config: V) h.ApiError!m.Catalogs {
    const starred = p.rows(p.get(p.get(config, "chat"), "favorite_models"));
    if (starred.len == 0) return catalog;
    var out = catalog;
    const models = try a.dupe(m.Choice, catalog.models);
    for (models) |*choice| for (starred) |row| {
        if (eq(p.s(row, "provider"), provider) and eq(p.s(row, "model"), choice.id)) choice.favorite = true;
    };
    out.models = models;
    return out;
}
fn fallback(provider: []const u8) []const []const u8 {
    if (eq(provider, "codex")) return &.{ "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.5", "gpt-5.6-terra", "gpt-5.6-luna" };
    if (eq(provider, "claude")) return &.{ "fable[1m]", "default", "opus[1m]", "sonnet", "haiku" };
    if (eq(provider, "opencode")) return &.{ "opencode/gpt-5.5", "opencode/gpt-5.4", "opencode/claude-opus-4-7", "opencode/claude-opus-4-6", "opencode/claude-sonnet-4-5", "opencode/gemini-3.1-pro" };
    if (eq(provider, "grok")) return &.{ "default", "grok-4.7", "grok-4.6", "grok-4.5" };
    if (eq(provider, "muse")) return &.{ "muse-spark-1.3", "muse-spark-1.3-contributor", "muse-spark-1.2", "muse-spark-1.2-contributor" };
    if (eq(provider, "pi")) return &.{"default"};
    if (eq(provider, "fx")) return &.{ "default", "openai/gpt-5.2", "openai/gpt-5.4-mini", "openai/gpt-5.1-codex", "anthropic/claude-sonnet-5" };
    if (eq(provider, "cursor")) return &.{ "auto", "grok-4.7-medium", "composer-2.5", "cursor-grok-4.5-high", "claude-opus-4-8-thinking-high", "gpt-5.6-sol-medium", "gpt-5.5-medium", "claude-fable-5-thinking-high", "claude-sonnet-5-thinking-high", "gpt-5.6-terra-medium", "gpt-5.6-luna-medium", "gpt-5.4-medium", "gemini-3.1-pro", "gemini-3.5-flash", "kimi-k3", "glm-5.2-high" };
    return &.{};
}
pub fn contains(items: []const m.Choice, value: ?[]const u8) bool {
    const v = value orelse return true;
    for (items) |item| if (eq(item.id, v) and item.enabled) return true;
    return false;
}
pub fn usage(a: A, author: []const u8, body: []const u8) h.ApiError!?m.Usage {
    if (!eq(author, "Usage")) return null;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, body, " \r\n\t"), '\n');
    const first = std.mem.trimEnd(u8, lines.next() orelse return null, "\r");
    var out: m.Usage = .{ .provider = if (eq(first, "Codex usage")) "codex" else if (eq(first, "Claude usage")) "claude" else return null };
    var section: enum { none, limits, stats, recent } = .none;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (eq(line, "Limits")) {
            section = .limits;
            continue;
        }
        if (eq(line, "Summary")) {
            section = .stats;
            continue;
        }
        if (eq(line, "Recent daily usage")) {
            section = .recent;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "• ")) continue;
        const item = line[4..];
        const colon = std.mem.indexOfScalar(u8, item, ':') orelse continue;
        const label = std.mem.trim(u8, item[0..colon], " ");
        const value = std.mem.trim(u8, item[colon + 1 ..], " ");
        if (label.len == 0 or value.len == 0) continue;
        if (section == .limits and out.limits.len < 8) {
            const end = std.mem.indexOf(u8, value, "% left") orelse continue;
            const percent = std.fmt.parseInt(u8, value[0..end], 10) catch continue;
            if (percent > 100) continue;
            const suffix = std.mem.trim(u8, value[end + 6 ..], " ");
            if (suffix.len > 0 and !(suffix[0] == '(' and suffix[suffix.len - 1] == ')')) continue;
            try append(m.UsageLimit, a, &out.limits, .{ .label = label, .percent_left = percent, .reset = if (suffix.len >= 2) suffix[1 .. suffix.len - 1] else "" });
        } else if (section == .stats and out.stats.len < 8) {
            try append(m.UsageStat, a, &out.stats, .{ .label = label, .value = value });
        } else if (section == .recent and out.recent.len < 8) {
            try append(m.UsageStat, a, &out.recent, .{ .label = label, .value = value });
        }
    }
    return out;
}

fn choiceLabel(id: []const u8) []const u8 {
    if (eq(id, "low")) return "Low";
    if (eq(id, "medium")) return "Medium";
    if (eq(id, "high")) return "High";
    if (eq(id, "gpt-6-astra")) return "GPT-6 Astra";
    if (eq(id, "gpt-6-sol")) return "GPT-6 Sol";
    if (eq(id, "gpt-6-luna")) return "GPT-6 Luna";
    if (eq(id, "gpt-5.6-sol")) return "GPT-5.6 Sol";
    if (eq(id, "gpt-5.5")) return "GPT-5.5";
    if (eq(id, "gpt-5.6-terra")) return "GPT-5.6 Terra";
    if (eq(id, "gpt-5.6-luna")) return "GPT-5.6 Luna";
    if (eq(id, "fable[1m]")) return "Fable 5.1";
    if (eq(id, "opus[1m]")) return "Opus 5.5 (1M context)";
    if (eq(id, "sonnet")) return "Sonnet 5";
    if (eq(id, "haiku")) return "Haiku 4.5";
    if (eq(id, "opencode/gpt-5.5")) return "GPT-5.5";
    if (eq(id, "opencode/gpt-5.4")) return "GPT-5.4";
    if (eq(id, "opencode/claude-opus-4-7")) return "Claude Opus 4.7";
    if (eq(id, "opencode/claude-opus-4-6")) return "Claude Opus 4.6";
    if (eq(id, "opencode/claude-sonnet-4-5")) return "Claude Sonnet 4.5";
    if (eq(id, "opencode/gemini-3.1-pro")) return "Gemini 3.1 Pro";
    if (eq(id, "openai/gpt-5.2")) return "GPT-5.2";
    if (eq(id, "openai/gpt-5.4-mini")) return "GPT-5.4 Mini";
    if (eq(id, "openai/gpt-5.1-codex")) return "GPT-5.1 Codex";
    if (eq(id, "anthropic/claude-sonnet-5")) return "Claude Sonnet 5";
    if (eq(id, "grok-4.7")) return "Grok 4.7";
    if (eq(id, "grok-4.6")) return "Grok 4.6";
    if (eq(id, "grok-4.5")) return "Grok 4.5";
    if (eq(id, "muse-spark-1.3")) return "muse-spark-1.3";
    if (eq(id, "muse-spark-1.2")) return "muse-spark-1.2";
    if (eq(id, "auto")) return "Auto";
    if (eq(id, "grok-4.7-medium")) return "Grok 4.7";
    if (eq(id, "composer-2.5")) return "Composer 2.5";
    if (eq(id, "cursor-grok-4.5-high")) return "Cursor Grok 4.5";
    if (eq(id, "claude-opus-4-8-thinking-high")) return "Opus 4.8 Thinking";
    if (eq(id, "gpt-5.6-sol-medium")) return "GPT-5.6 Sol";
    if (eq(id, "gpt-5.5-medium")) return "GPT-5.5";
    if (eq(id, "claude-fable-5-thinking-high")) return "Fable 5 Thinking";
    if (eq(id, "claude-sonnet-5-thinking-high")) return "Sonnet 5 Thinking";
    if (eq(id, "gpt-5.6-terra-medium")) return "GPT-5.6 Terra";
    if (eq(id, "gpt-5.6-luna-medium")) return "GPT-5.6 Luna";
    if (eq(id, "gpt-5.4-medium")) return "GPT-5.4";
    if (eq(id, "gemini-3.1-pro")) return "Gemini 3.1 Pro";
    if (eq(id, "gemini-3.5-flash")) return "Gemini 3.5 Flash";
    if (eq(id, "kimi-k3")) return "Kimi K3";
    if (eq(id, "glm-5.2-high")) return "GLM 5.2";
    if (eq(id, "")) return "Default";
    if (eq(id, "default")) return "Default";
    if (eq(id, "max")) return "Max";
    if (eq(id, "xhigh")) return "Xhigh";
    if (eq(id, "supervised")) return "Supervised";
    if (eq(id, "full_access")) return "Full access";
    if (eq(id, "on")) return "Fast";
    if (eq(id, "off")) return "Normal";
    return id;
}
