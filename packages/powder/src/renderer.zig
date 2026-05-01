//! SDL_GPU renderer bridge for powder render batches.

const Self = @This();
const std = @import("std");

const draw = @import("draw.zig");

pub const c = struct {
    pub const SDL_GPUDevice = opaque {};
    pub const SDL_GPURenderPass = opaque {};
    pub const SDL_GPUGraphicsPipeline = opaque {};

    extern fn SDL_CreateGPUDevice(format_flags: u32, debug_mode: bool, name: ?[*:0]const u8) ?*SDL_GPUDevice;
    extern fn SDL_DestroyGPUDevice(device: *SDL_GPUDevice) void;
    extern fn SDL_ReleaseGPUGraphicsPipeline(device: *SDL_GPUDevice, pipeline: *SDL_GPUGraphicsPipeline) void;
};

pub const RendererConfig = struct {
    debug_mode: bool = false,
    shader_formats: u32 = 0,
};

pub const Renderer = struct {
    device: ?*c.SDL_GPUDevice = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,

    /// Creates the SDL_GPU device. Vulkan and Metal are selected by SDL for Linux/macOS.
    pub fn init(config: RendererConfig) !Renderer {
        const device = c.SDL_CreateGPUDevice(config.shader_formats, config.debug_mode, null) orelse return error.SdlGpuCreateDeviceFailed;
        return .{ .device = device };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device) |device| {
            if (self.pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            c.SDL_DestroyGPUDevice(device);
        }
        self.* = undefined;
    }

    /// Placeholder submission point. The next step is persistent vertex/index buffers.
    pub fn renderBatch(self: *Renderer, pass: *c.SDL_GPURenderPass, batch: *const draw.RenderBatch) void {
        _ = self;
        _ = pass;
        _ = batch;
    }
};

pub const ShaderSource = struct {
    pub const vertex_hlsl = @embedFile("shaders/ui.vert.hlsl");
    pub const fragment_hlsl = @embedFile("shaders/ui.frag.hlsl");
};
