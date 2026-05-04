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

pub const Mesh = struct {
    vertices: std.ArrayList(draw.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Mesh, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
    }

    pub fn clear(self: *Mesh) void {
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }
};

/// Converts retained render commands into indexed quads ready for GPU upload.
pub fn buildMesh(allocator: std.mem.Allocator, batch: *const draw.RenderBatch, mesh: *Mesh) !void {
    mesh.clear();
    try mesh.vertices.ensureUnusedCapacity(allocator, batch.commands.items.len * 4);
    try mesh.indices.ensureUnusedCapacity(allocator, batch.commands.items.len * 6);
    for (batch.commands.items) |command| {
        appendCommand(mesh, command);
    }
}

fn appendCommand(mesh: *Mesh, command: draw.Command) void {
    const base: u32 = @intCast(mesh.vertices.items.len);
    const x0 = command.rect.x;
    const y0 = command.rect.y;
    const x1 = command.rect.x + command.rect.w;
    const y1 = command.rect.y + command.rect.h;
    const uv_x0 = command.uv.x;
    const uv_y0 = command.uv.y;
    const uv_x1 = command.uv.x + command.uv.w;
    const uv_y1 = command.uv.y + command.uv.h;
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x0, .y = y0 }, .uv = .{ .x = uv_x0, .y = uv_y0 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x1, .y = y0 }, .uv = .{ .x = uv_x1, .y = uv_y0 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x1, .y = y1 }, .uv = .{ .x = uv_x1, .y = uv_y1 }, .color = command.color });
    mesh.vertices.appendAssumeCapacity(.{ .pos = .{ .x = x0, .y = y1 }, .uv = .{ .x = uv_x0, .y = uv_y1 }, .color = command.color });
    mesh.indices.appendSliceAssumeCapacity(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

pub const ShaderSource = struct {
    pub const vertex_hlsl = @embedFile("shaders/ui.vert.hlsl");
    pub const fragment_hlsl = @embedFile("shaders/ui.frag.hlsl");
};

test "renderer builds indexed quads from commands" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .x = 1, .y = 2, .w = 3, .h = 4 }, draw.Color.white);
    try batch.glyph(std.testing.allocator, .{ .x = 5, .y = 6, .w = 7, .h = 8 }, .{ .x = 0.25, .y = 0.5, .w = 0.25, .h = 0.5 }, draw.Color.white);

    var mesh: Mesh = .{};
    defer mesh.deinit(std.testing.allocator);
    try buildMesh(std.testing.allocator, &batch, &mesh);

    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.items.len);
    try std.testing.expectEqual(@as(f32, 4), mesh.vertices.items[2].pos.x);
    try std.testing.expectEqual(@as(f32, 1.0), mesh.vertices.items[6].uv.y);
}
