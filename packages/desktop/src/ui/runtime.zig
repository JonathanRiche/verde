const std = @import("std");
const zgui = @import("zgui");

const native_state = @import("../state.zig");
const utils = @import("../utils.zig");

pub const AppState = native_state.AppState;
pub const ChatImageAttachment = native_state.ChatImageAttachment;
pub const ChatRole = native_state.ChatRole;

pub const ChangedFileEntry = struct {
    path: []const u8,
    additions: i64,
    deletions: i64,
    patch: ?[]const u8 = null,
};

pub const log = native_state.log;
pub const IMAGE_MODAL_ID: [:0]const u8 = native_state.IMAGE_MODAL_ID;
pub const PROJECT_RENAME_MODAL_ID: [:0]const u8 = "ProjectRenameModal";
pub const CODEX_IMPORT_MODAL_ID: [:0]const u8 = native_state.CODEX_IMPORT_MODAL_ID;
pub const SIDEBAR_VISIBLE_THREAD_LIMIT: usize = 6;
pub const PERSISTED_DIFF_MARKER = utils.PERSISTED_DIFF_MARKER;

pub fn providerLabel(provider: native_state.Provider) [:0]const u8 {
    return utils.providerLabel(provider);
}

pub fn scaledImageSize(width: i32, height: i32, max_width: f32, max_height: f32) [2]f32 {
    if (width <= 0 or height <= 0) return .{ max_width, max_height };
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    const scale = @min(max_width / width_f, max_height / height_f);
    return .{ width_f * scale, height_f * scale };
}

pub fn textureRefFromGlId(texture_id: c_uint) zgui.TextureRef {
    return .{
        .tex_data = null,
        .tex_id = @enumFromInt(@as(u64, texture_id)),
    };
}

pub fn formatByteSize(buffer: *[32:0]u8, size: usize) [:0]const u8 {
    @memset(buffer, 0);
    if (size >= 1024 * 1024) {
        _ = std.fmt.bufPrintZ(buffer, "{d:.1} MB", .{@as(f64, @floatFromInt(size)) / (1024.0 * 1024.0)}) catch {};
    } else if (size >= 1024) {
        _ = std.fmt.bufPrintZ(buffer, "{d:.1} KB", .{@as(f64, @floatFromInt(size)) / 1024.0}) catch {};
    } else {
        _ = std.fmt.bufPrintZ(buffer, "{d} B", .{size}) catch {};
    }
    return std.mem.sliceTo(buffer, 0);
}

pub fn isSendPending(state: *AppState) bool {
    return state.hasPendingStream();
}
