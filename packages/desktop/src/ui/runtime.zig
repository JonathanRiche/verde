const std = @import("std");

const native_state = @import("../state.zig");
const utils = @import("../utils.zig");

pub const AppState = native_state.AppState;
pub const CachedImageTexture = native_state.CachedImageTexture;
pub const ChatImageAttachment = native_state.ChatImageAttachment;
pub const ChatThread = native_state.ChatThread;
pub const ChatRole = native_state.ChatRole;
pub const PendingApproval = native_state.PendingApproval;
pub const Project = native_state.Project;
pub const PaletteModalAction = native_state.PaletteModalAction;
pub const PaletteModalHit = native_state.PaletteModalHit;
pub const PaletteModalTextFocus = native_state.PaletteModalTextFocus;
pub const Provider = native_state.Provider;
pub const RuntimePickerStatus = native_state.RuntimePickerStatus;
pub const runtimePickerStatusBadge = native_state.runtimePickerStatusBadge;
pub const runtimePickerStatusDescription = native_state.runtimePickerStatusDescription;
pub const RuntimeRecovery = native_state.RuntimeRecovery;
pub const runtimeStatusRecovery = native_state.runtimeStatusRecovery;
pub const runtimeRecoveryLabel = native_state.runtimeRecoveryLabel;
pub const runtimeStatusOffersServerSetup = native_state.runtimeStatusOffersServerSetup;
pub const runtimeStatusTone = native_state.runtimeStatusTone;
pub const ProviderReadiness = native_state.ProviderReadiness;
pub const SurfaceProvider = native_state.SurfaceProvider;
pub const SurfaceStatus = native_state.SurfaceStatus;
pub const WorkspaceNode = native_state.WorkspaceNode;
pub const WorkspaceLayout = native_state.WorkspaceLayout;
pub const WorkspacePaneId = native_state.WorkspacePaneId;
pub const WorkspacePaneKind = native_state.WorkspacePaneKind;
pub const workspace_tabs = native_state.workspace_tabs;
pub const WorkspaceTab = native_state.WorkspaceTab;
pub const WorkspaceTabId = native_state.WorkspaceTabId;
pub const WorkspacePaneDirection = native_state.WorkspacePaneDirection;
pub const WorkspaceSplitAxis = native_state.WorkspaceSplitAxis;
pub const FloatingPaneGeometry = native_state.FloatingPaneGeometry;
pub const FloatingQuickPane = native_state.FloatingQuickPane;

pub const ChangedFileEntry = struct {
    path: []const u8,
    additions: i64,
    deletions: i64,
    patch: ?[]const u8 = null,
};

pub const log = native_state.log;
pub const IMAGE_MODAL_ID: [:0]const u8 = native_state.IMAGE_MODAL_ID;
pub const WORKSPACE_RENAME_MODAL_ID: [:0]const u8 = "WorkspaceRenameModal";
pub const THREAD_IMPORT_MODAL_ID: [:0]const u8 = native_state.THREAD_IMPORT_MODAL_ID;
pub const TRANSCRIPT_SELECTION_MODAL_ID: [:0]const u8 = native_state.TRANSCRIPT_SELECTION_MODAL_ID;
pub const PERSISTED_DIFF_MARKER = utils.PERSISTED_DIFF_MARKER;
pub const paletteUiTextPrefixWidth = native_state.paletteUiTextPrefixWidth;

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
