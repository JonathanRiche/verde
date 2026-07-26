//! Shared state value types used by UI and worker helpers.

const std = @import("std");
const state_sync = @import("sync.zig");

const Mutex = state_sync.Mutex;

pub const ProjectEditorTarget = enum {
    configured,
    cursor,
    vscode,
    zed,
};

pub const PickerStatus = enum {
    idle,
    pending,
    selected,
    cancelled,
    unavailable,
    failed,
};
pub const PickerState = struct {
    mutex: Mutex = .{},
    status: PickerStatus = .idle,
    selected_path: ?[]u8 = null,
    worker: ?std.Thread = null,
};

pub const TextureBackend = enum {
    external,
};

pub const CachedImageTexture = struct {
    texture_id: c_uint = 0,
    width: i32 = 0,
    height: i32 = 0,
    valid: bool = false,
    backend: TextureBackend = .external,

    pub fn deinit(self: CachedImageTexture) void {
        _ = self;
    }
};
