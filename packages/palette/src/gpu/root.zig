//! Palette GPU renderer: public surface.
//!
//! Backend-neutral core (`core.zig`, `text.zig`, `atlas.zig`, `damage.zig`, `scene.zig`)
//! plus one device backend chosen at comptime (`backend`): Vulkan (`vulkan/`) on Linux/BSD,
//! Metal (`metal/`) on macOS, Direct3D 11 (`d3d11/`) on Windows.
//! The backend interface is documented in `core.zig` and checked by `core.checkBackend`.
//!
//!     const ctx = try gpu.Context.init(gpa, .{ .preferred_device = feedback.main_device });
//!     const r = try gpu.Renderer.init(gpa, ctx, .{ .glyph_source = gpu.GlyphSource.adapt(font.Collection, coll) });
//!     var bufs = try gpu.DmabufTargets.init(r, w, h, .{ .feedback = feedback });
//!     // per frame:
//!     if (bufs.acquire()) |t| {
//!         const res = try bufs.render(t, &batch, .{ .clear = bg });
//!         if (!res.stats.skipped) window.present(bufs.exported(t), res.damage);
//!     }
//!     // on wl_buffer.release: bufs.release(t)
const builtin = @import("builtin");

pub const core = @import("core.zig");
pub const atlas = @import("atlas.zig");
pub const text = @import("text.zig");
pub const damage = @import("damage.zig");
pub const png = @import("png_lite.zig");
/// Deterministic reference scene used by the goldens and `gpu-bench`.
pub const scene = @import("scene.zig");

pub const BackendKind = enum { vulkan, metal, d3d11 };

pub const backend_kind: BackendKind = switch (builtin.os.tag) {
    .macos => .metal,
    .windows => .d3d11,
    else => .vulkan,
};

/// The comptime-selected device backend.
pub const backend = switch (backend_kind) {
    .vulkan => vulkan,
    .metal => metal,
    .d3d11 => d3d11,
};

/// Vulkan backend (Linux/BSD). Only analysed when referenced.
pub const vulkan = @import("vulkan/root.zig");
/// Metal backend (macOS). Only analysed when referenced.
pub const metal = @import("metal/root.zig");
/// Direct3D 11 backend (Windows). Only analysed when referenced.
pub const d3d11 = @import("d3d11/root.zig");

comptime {
    core.checkBackend(backend);
}

// Vulkan-specific names, kept for existing callers (Linux). On other backends they resolve to
// the backend's module of the same name when it has one, else `void`.
const vk_only = backend_kind == .vulkan;
fn backendDecl(comptime name: []const u8) type {
    return if (@hasDecl(backend, name)) @field(backend, name) else void;
}
pub const vk = if (vk_only) vulkan.vk else void;
pub const context = if (vk_only) vulkan.context else backendDecl("context");
pub const renderer = if (vk_only) vulkan.renderer else backendDecl("renderer");
pub const targets = if (vk_only) vulkan.targets else backendDecl("targets");
pub const Caps = if (vk_only) vulkan.Caps else backendDecl("Caps");
pub const DmabufTargets = if (vk_only) vulkan.DmabufTargets else void;
pub const DmabufTarget = if (vk_only) vulkan.DmabufTarget else void;
pub const DmabufOptions = if (vk_only) vulkan.DmabufOptions else void;
pub const SyncMode = if (vk_only) vulkan.SyncMode else void;
pub const DmabufImportOptions = if (vk_only) vulkan.DmabufImportOptions else void;

pub const Context = backend.Context;
pub const ContextOptions = backend.ContextOptions;
pub const Renderer = backend.Renderer;
pub const Offscreen = backend.Offscreen;
pub const Target = backend.Target;

pub const MemoryStats = core.MemoryStats;
pub const RendererOptions = core.Options;
pub const FrameOptions = core.FrameOptions;
pub const FrameResult = core.FrameResult;
pub const FrameStats = core.FrameStats;
pub const TextureFormat = core.TextureFormat;
pub const TextureRect = core.TextureRect;
pub const StreamOptions = core.StreamOptions;
pub const DamageRect = damage.Rect;

pub const GlyphSource = text.GlyphSource;
pub const StubGlyphSource = text.StubGlyphSource;

pub const snapRectToPixelGrid = core.snapRectToPixelGrid;
pub const strokePixelWidth = core.strokePixelWidth;
