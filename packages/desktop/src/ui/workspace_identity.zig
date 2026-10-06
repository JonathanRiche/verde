//! Deterministic per-workspace identity (icon + theme-derived color) and
//! GUI-local workspace recency for the sidebar workspace switcher. The
//! derivation is a cross-client contract — see
//! `docs/workspace-switcher-sidebar.md`; web and mobile compute the same
//! icon/color indices from the workspace id.

const std = @import("std");
const theme = @import("theme.zig");

pub const ICON_COUNT: u32 = 16;
pub const COLOR_COUNT: u32 = 8;

/// Nerd Font (Font Awesome range) glyphs in spec index order: folder, rocket,
/// flask, leaf, bolt, star, flame, cube, code, terminal, globe, heart, moon,
/// sun, compass, puzzle. Order is part of the cross-client contract.
const ICON_GLYPHS = [ICON_COUNT][]const u8{
    "\u{F07B}", "\u{F135}", "\u{F0C3}", "\u{F06C}",
    "\u{F0E7}", "\u{F005}", "\u{F06D}", "\u{F1B2}",
    "\u{F121}", "\u{F120}", "\u{F0AC}", "\u{F004}",
    "\u{F186}", "\u{F185}", "\u{F14E}", "\u{F12E}",
};

/// Glyph shown for the "All Workspaces" scope (fa-th-large).
pub const ALL_WORKSPACES_GLYPH = "\u{F009}";

pub const Identity = struct {
    icon_index: u32,
    color_index: u32,
};

/// FNV-1a 32-bit over the id bytes.
pub fn hashId(id: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (id) |byte| {
        h ^= byte;
        h *%= 0x01000193;
    }
    return h;
}

pub fn identityFor(id: []const u8) Identity {
    const h = hashId(id);
    return .{ .icon_index = h % ICON_COUNT, .color_index = (h >> 8) % COLOR_COUNT };
}

/// Identity with the workspace's persisted overrides applied (null slots
/// fall back to the id hash). Out-of-range overrides are ignored.
pub fn resolve(id: []const u8, icon_override: ?u8, color_override: ?u8) Identity {
    var identity = identityFor(id);
    if (icon_override) |value| if (value < ICON_COUNT) {
        identity.icon_index = value;
    };
    if (color_override) |value| if (value < COLOR_COUNT) {
        identity.color_index = value;
    };
    return identity;
}

pub fn glyphAt(icon_index: u32) []const u8 {
    return ICON_GLYPHS[icon_index % ICON_COUNT];
}

pub fn iconGlyph(id: []const u8) []const u8 {
    return glyphAt(identityFor(id).icon_index);
}

/// Theme accent rotated by `slot * 45°`, clamped so every slot stays legible
/// on the active (dark or light) surface.
pub fn slotColor(slot: u32) [4]f32 {
    const hsl = rgbToHsl(theme.accent());
    const light = theme.isLightPalette();
    const hue = @mod(hsl[0] + @as(f32, @floatFromInt(slot % COLOR_COUNT)) * 45.0, 360.0);
    const sat = std.math.clamp(hsl[1], 0.45, 0.85);
    const lum = if (light) std.math.clamp(hsl[2], 0.38, 0.50) else std.math.clamp(hsl[2], 0.55, 0.72);
    return hslToRgb(hue, sat, lum);
}

pub fn colorFor(id: []const u8) [4]f32 {
    return slotColor(identityFor(id).color_index);
}

// ---------------------------------------------------------------------------
// Recency
// ---------------------------------------------------------------------------

const RECENCY_CAPACITY: usize = 128;
const RecencyEntry = struct { hash: u32, used_ms: i64 };
var recency_entries: [RECENCY_CAPACITY]RecencyEntry = undefined;
var recency_count: usize = 0;

/// Records that the workspace was used (selected/focused) at `now_ms`.
pub fn noteUsed(id: []const u8, now_ms: i64) void {
    const h = hashId(id);
    for (recency_entries[0..recency_count]) |*entry| {
        if (entry.hash == h) {
            entry.used_ms = @max(entry.used_ms, now_ms);
            return;
        }
    }
    if (recency_count < RECENCY_CAPACITY) {
        recency_entries[recency_count] = .{ .hash = h, .used_ms = now_ms };
        recency_count += 1;
        return;
    }
    // Full: evict the stalest entry.
    var oldest: usize = 0;
    for (recency_entries[0..recency_count], 0..) |entry, index| {
        if (entry.used_ms < recency_entries[oldest].used_ms) oldest = index;
    }
    recency_entries[oldest] = .{ .hash = h, .used_ms = now_ms };
}

/// Last GUI-observed use of the workspace this session, or 0.
pub fn lastUsedMs(id: []const u8) i64 {
    const h = hashId(id);
    for (recency_entries[0..recency_count]) |entry| {
        if (entry.hash == h) return entry.used_ms;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

fn rgbToHsl(c: [4]f32) [3]f32 {
    const r = c[0];
    const g = c[1];
    const b = c[2];
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const l = (max + min) * 0.5;
    if (max - min < 1e-5) return .{ 0.0, 0.0, l };
    const d = max - min;
    const s = if (l > 0.5) d / (2.0 - max - min) else d / (max + min);
    var h: f32 = if (max == r)
        (g - b) / d + (if (g < b) @as(f32, 6.0) else 0.0)
    else if (max == g)
        (b - r) / d + 2.0
    else
        (r - g) / d + 4.0;
    h *= 60.0;
    return .{ h, s, l };
}

fn hslToRgb(h: f32, s: f32, l: f32) [4]f32 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var rgb: [3]f32 = .{ 0.0, 0.0, 0.0 };
    if (hp < 1.0) {
        rgb = .{ c, x, 0.0 };
    } else if (hp < 2.0) {
        rgb = .{ x, c, 0.0 };
    } else if (hp < 3.0) {
        rgb = .{ 0.0, c, x };
    } else if (hp < 4.0) {
        rgb = .{ 0.0, x, c };
    } else if (hp < 5.0) {
        rgb = .{ x, 0.0, c };
    } else {
        rgb = .{ c, 0.0, x };
    }
    const m = l - c * 0.5;
    return .{ rgb[0] + m, rgb[1] + m, rgb[2] + m, 1.0 };
}

test "workspace identity matches cross-client vectors" {
    try std.testing.expectEqual(@as(u32, 0x48d4ea0e), hashId("ws-alpha"));
    try std.testing.expectEqual(Identity{ .icon_index = 14, .color_index = 2 }, identityFor("ws-alpha"));
    try std.testing.expectEqual(Identity{ .icon_index = 9, .color_index = 6 }, identityFor("baaa819e66d8f3be"));
    try std.testing.expectEqual(Identity{ .icon_index = 5, .color_index = 5 }, identityFor(""));
}

test "workspace recency keeps the newest use per id" {
    recency_count = 0;
    noteUsed("a", 10);
    noteUsed("b", 20);
    noteUsed("a", 5);
    try std.testing.expectEqual(@as(i64, 10), lastUsedMs("a"));
    try std.testing.expectEqual(@as(i64, 20), lastUsedMs("b"));
    try std.testing.expectEqual(@as(i64, 0), lastUsedMs("c"));
    recency_count = 0;
}

test "hsl round trip preserves primaries" {
    const red = hslToRgb(0.0, 1.0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), red[0], 0.001);
    const back = rgbToHsl(.{ 0.2, 0.6, 0.4, 1.0 });
    const again = hslToRgb(back[0], back[1], back[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), again[1], 0.001);
}
