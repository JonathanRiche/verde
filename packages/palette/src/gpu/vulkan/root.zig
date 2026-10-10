//! Vulkan backend (Linux/BSD): Vulkan via dlopen, dma-buf targets for Wayland, offscreen
//! targets with readback. Implements the backend interface documented in `../core.zig`.
pub const vk = @import("vk.zig");
pub const context = @import("context.zig");
pub const renderer = @import("renderer.zig");
pub const targets = @import("targets.zig");
pub const import = @import("import.zig");

pub const Context = context.Context;
pub const ContextOptions = context.Options;
pub const Caps = context.Caps;
pub const Renderer = renderer.Renderer;
pub const Target = renderer.Target;
pub const Offscreen = targets.Offscreen;
pub const DmabufTargets = targets.DmabufTargets;
pub const DmabufTarget = targets.DmabufTarget;
pub const DmabufOptions = targets.DmabufOptions;
pub const SyncMode = targets.SyncMode;
pub const DmabufImportOptions = renderer.DmabufImportOptions;
