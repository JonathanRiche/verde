//! Public API for the powder SDL_GPU UI package.

const std = @import("std");

pub const atlas = @import("atlas.zig");
pub const draw = @import("draw.zig");
pub const renderer = @import("renderer.zig");
pub const sdl = @import("sdl.zig");
pub const text_component = @import("components/text.zig");
pub const text_area_component = @import("components/text_area.zig");

pub const Color = draw.Color;
pub const Rect = draw.Rect;
pub const RenderBatch = draw.RenderBatch;
pub const Renderer = renderer.Renderer;
pub const FontAtlas = atlas.FontAtlas;
pub const Text = text_component.Text;
pub const TextArea = text_area_component.TextArea;
pub const TextAreaConfig = text_area_component.TextAreaConfig;

/// Creates a retained text label type with comptime styling.
pub fn text(comptime config: text_component.TextConfig) type {
    return text_component.Text(config);
}

/// Creates a retained text-area type with comptime styling.
pub fn textArea(comptime config: TextAreaConfig) type {
    return text_area_component.TextArea(config);
}

test {
    _ = draw;
    _ = text_component;
    _ = text_area_component;
}
