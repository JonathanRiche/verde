//! Direct3D 11 backend (Windows): hand-written COM bindings, precompiled DXBC uber-shader,
//! offscreen targets with readback and a flip-model swapchain for windows. Implements the
//! backend interface documented in `../core.zig`. See README.md.
pub const com = @import("com.zig");
pub const context = @import("context.zig");
pub const renderer = @import("renderer.zig");
pub const targets = @import("targets.zig");

pub const Context = context.Context;
pub const ContextOptions = context.ContextOptions;
pub const Caps = context.Caps;
pub const Renderer = renderer.Renderer;
pub const Target = renderer.Target;
pub const Offscreen = targets.Offscreen;
pub const Swapchain = targets.Swapchain;
pub const SwapchainOptions = targets.SwapchainOptions;
pub const PresentResult = targets.PresentResult;

test {
    _ = com;
    _ = targets;
}
