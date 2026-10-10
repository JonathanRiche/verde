//! Metal backend (macOS): Metal.framework through the objc runtime (dlopened, no SDK),
//! the uber-shader from the embedded precompiled metallib (runtime MSL compile as fallback), offscreen targets with readback
//! and CAMetalLayer window targets. Implements the backend interface in `../core.zig`.
//! See README.md in this directory.
pub const mtl = @import("mtl.zig");
pub const renderer = @import("renderer.zig");
pub const targets = @import("targets.zig");

pub const Context = renderer.Context;
pub const ContextOptions = renderer.ContextOptions;
pub const Renderer = renderer.Renderer;
pub const ShaderLibrary = renderer.ShaderLibrary;
pub const Target = renderer.Target;
pub const Offscreen = targets.Offscreen;
pub const LayerTarget = targets.LayerTarget;
pub const LayerOptions = targets.LayerOptions;
