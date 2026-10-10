//! Test + example module root for the gpu workstream (imports must stay under src/).
pub const gpu = @import("gpu/root.zig");
pub const draw = @import("draw.zig");
pub const scene = @import("gpu/scene.zig");
pub const clock = @import("clock.zig");

test {
    @import("std").testing.refAllDecls(gpu);
    _ = @import("gpu/core.zig");
    _ = @import("gpu/atlas.zig");
    _ = @import("gpu/png_lite.zig");
    _ = @import("gpu/text.zig");
    _ = @import("gpu/damage.zig");
    if (gpu.backend_kind == .vulkan) {
        _ = @import("gpu/vulkan/vk.zig");
        _ = @import("gpu/vulkan/context.zig");
        _ = @import("gpu/vulkan/renderer.zig");
    }
    _ = @import("gpu/d3d11/com.zig");
    _ = @import("gpu/gpu_tests.zig");
    if (@import("builtin").os.tag == .macos) {
        _ = @import("gpu/metal/renderer.zig");
        _ = @import("gpu/metal/targets.zig");
    }
}

test "font.Collection plugs into the renderer as a GlyphSource" {
    const Collection = @import("font/root.zig").Collection;
    var collection: Collection = undefined;
    const source = gpu.GlyphSource.adapt(Collection, &collection);
    try @import("std").testing.expect(source.ptr == @as(*anyopaque, @ptrCast(&collection)));
}
