const std = @import("std");

const native_state = @import("../state.zig");

const log = std.log.scoped(.composer_pickers);

const AppState = native_state.AppState;

pub fn render(state: *AppState) void {
    renderRetained(state);
}

pub fn renderRetained(state: *AppState) void {
    state.syncPaletteModelCascadeMenu();
    state.palette_model_cascade.render(state.allocator, &state.palette_overlay_batch) catch |err| {
        log.warn("failed to render retained composer model cascade: {s}", .{@errorName(err)});
    };
}
