//! SDL_GPU renderer bridge for powder render batches.

const Self = @This();
const std = @import("std");

const draw = @import("draw.zig");
const sdl = @import("sdl.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL_gpu.h");
});

pub const ShaderFormat = struct {
    pub const spirv: u32 = c.SDL_GPU_SHADERFORMAT_SPIRV;
    pub const msl: u32 = c.SDL_GPU_SHADERFORMAT_MSL;
    pub const metallib: u32 = c.SDL_GPU_SHADERFORMAT_METALLIB;
    pub const vulkan: u32 = spirv;
    pub const metal: u32 = msl | metallib;
    pub const portable: u32 = vulkan | metal;

    pub fn defaultForTarget(os_tag: std.Target.Os.Tag) u32 {
        return switch (os_tag) {
            .macos, .ios, .tvos, .watchos => metal,
            .linux, .freebsd, .openbsd, .netbsd, .dragonfly => vulkan,
            else => portable,
        };
    }
};

pub const ShaderCode = struct {
    format: u32,
    code: []const u8,
    entrypoint: [:0]const u8 = "main",
};

pub const ShaderPackage = struct {
    vertex: ShaderCode,
    fragment: ShaderCode,

    pub fn validate(self: ShaderPackage, accepted_formats: u32) !void {
        if (self.vertex.code.len == 0 or self.fragment.code.len == 0) return error.MissingGpuShaderCode;
        if (self.vertex.format & accepted_formats == 0) return error.UnsupportedVertexShaderFormat;
        if (self.fragment.format & accepted_formats == 0) return error.UnsupportedFragmentShaderFormat;
    }
};

pub const RendererConfig = struct {
    debug_mode: bool = false,
    shader_formats: u32 = ShaderFormat.portable,
    shader_package: ?ShaderPackage = null,
};

pub const Renderer = struct {
    device: ?*c.SDL_GPUDevice = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    vertex_buffer: ?*c.SDL_GPUBuffer = null,
    index_buffer: ?*c.SDL_GPUBuffer = null,
    vertex_transfer: ?*c.SDL_GPUTransferBuffer = null,
    index_transfer: ?*c.SDL_GPUTransferBuffer = null,
    vertex_capacity: usize = 0,
    index_capacity: usize = 0,
    command_counts: CommandCounts = .{},
    unsupported_text_commands: usize = 0,

    /// Creates the SDL_GPU device. Pass SPIR-V shaders for Vulkan and MSL or
    /// metallib shaders for Metal to create a drawable pipeline.
    pub fn init(config: RendererConfig) !Renderer {
        const device = c.SDL_CreateGPUDevice(config.shader_formats, config.debug_mode, null) orelse return error.SdlGpuCreateDeviceFailed;
        var renderer: Renderer = .{ .device = device };
        errdefer renderer.deinit();
        if (config.shader_package) |package| {
            try renderer.createPipeline(package);
        }
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device) |device| {
            if (self.pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            if (self.vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.index_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.vertex_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.index_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            c.SDL_DestroyGPUDevice(device);
        }
        self.* = undefined;
    }

    pub fn claimWindow(self: *Renderer, window: *sdl.Window) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (!c.SDL_ClaimWindowForGPUDevice(device, @ptrCast(window))) return error.SdlGpuClaimWindowFailed;
    }

    pub fn releaseWindow(self: *Renderer, window: *sdl.Window) void {
        if (self.device) |device| c.SDL_ReleaseWindowFromGPUDevice(device, @ptrCast(window));
    }

    /// Compatibility entry point for callers that already own a render pass.
    /// This records command accounting and draws existing uploaded buffers when
    /// the renderer has been initialized with shaders and resources.
    pub fn renderBatch(self: *Renderer, pass: *c.SDL_GPURenderPass, batch: *const draw.RenderBatch) void {
        self.command_counts = CommandCounts.fromBatch(batch);
        self.unsupported_text_commands = self.command_counts.text;
        if (self.pipeline == null or self.vertex_buffer == null or self.index_buffer == null or self.command_counts.drawableIndexCount() == 0) return;
        var vertex_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.vertex_buffer.?, .offset = 0 };
        var index_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.index_buffer.?, .offset = 0 };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline.?);
        c.SDL_BindGPUVertexBuffers(pass, 0, &vertex_binding, 1);
        c.SDL_BindGPUIndexBuffer(pass, &index_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        c.SDL_DrawGPUIndexedPrimitives(pass, @intCast(self.command_counts.drawableIndexCount()), 1, 0, 0, 0);
    }

    /// Builds and uploads the current batch into GPU buffers. Text commands are
    /// intentionally tracked, not discarded; they require an atlas texture path.
    pub fn prepareBatch(self: *Renderer, allocator: std.mem.Allocator, command_buffer: *c.SDL_GPUCommandBuffer, batch: *const draw.RenderBatch) !void {
        var mesh: Mesh = .{};
        defer mesh.deinit(allocator);
        try buildMesh(allocator, batch, &mesh);

        self.command_counts = CommandCounts.fromBatch(batch);
        self.unsupported_text_commands = self.command_counts.text;
        if (mesh.vertices.items.len == 0 or mesh.indices.items.len == 0) return;
        try self.ensureBuffers(mesh.vertices.items.len, mesh.indices.items.len);
        try self.uploadBuffer(command_buffer, self.vertex_transfer.?, self.vertex_buffer.?, std.mem.sliceAsBytes(mesh.vertices.items));
        try self.uploadBuffer(command_buffer, self.index_transfer.?, self.index_buffer.?, std.mem.sliceAsBytes(mesh.indices.items));
    }

    pub fn renderWindow(self: *Renderer, allocator: std.mem.Allocator, window: *sdl.Window, batch: *const draw.RenderBatch, clear_color: draw.Color) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (self.pipeline == null) return error.MissingGpuPipeline;
        if (CommandCounts.fromBatch(batch).text > 0 and !self.supportsGpuText()) return error.GpuTextAtlasNotConfigured;

        const command_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.SdlGpuCommandBufferFailed;
        try self.prepareBatch(allocator, command_buffer, batch);

        var swapchain_texture: ?*c.SDL_GPUTexture = null;
        var width: u32 = 0;
        var height: u32 = 0;
        if (!c.SDL_AcquireGPUSwapchainTexture(command_buffer, @ptrCast(window), &swapchain_texture, &width, &height)) return error.SdlGpuSwapchainFailed;
        if (swapchain_texture) |texture| {
            var target: c.SDL_GPUColorTargetInfo = .{
                .texture = texture,
                .mip_level = 0,
                .layer_or_depth_plane = 0,
                .clear_color = .{ .r = clear_color.r, .g = clear_color.g, .b = clear_color.b, .a = clear_color.a },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .resolve_texture = null,
                .resolve_mip_level = 0,
                .resolve_layer = 0,
                .cycle = false,
                .cycle_resolve_texture = false,
                .padding1 = 0,
                .padding2 = 0,
            };
            const pass = c.SDL_BeginGPURenderPass(command_buffer, &target, 1, null) orelse return error.SdlGpuRenderPassFailed;
            self.renderBatch(pass, batch);
            c.SDL_EndGPURenderPass(pass);
        }
        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) return error.SdlGpuSubmitFailed;
    }

    pub fn supportsGpuText(_: *const Renderer) bool {
        return false;
    }

    fn createPipeline(self: *Renderer, package: ShaderPackage) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        const accepted_formats = c.SDL_GetGPUShaderFormats(device);
        try package.validate(accepted_formats);

        const vertex_shader = c.SDL_CreateGPUShader(device, &.{
            .code_size = package.vertex.code.len,
            .code = package.vertex.code.ptr,
            .entrypoint = package.vertex.entrypoint.ptr,
            .format = package.vertex.format,
            .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
            .num_samplers = 0,
            .num_storage_textures = 0,
            .num_storage_buffers = 0,
            .num_uniform_buffers = 1,
            .props = 0,
        }) orelse return error.SdlGpuShaderFailed;
        defer c.SDL_ReleaseGPUShader(device, vertex_shader);

        const fragment_shader = c.SDL_CreateGPUShader(device, &.{
            .code_size = package.fragment.code.len,
            .code = package.fragment.code.ptr,
            .entrypoint = package.fragment.entrypoint.ptr,
            .format = package.fragment.format,
            .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            .num_samplers = 1,
            .num_storage_textures = 0,
            .num_storage_buffers = 0,
            .num_uniform_buffers = 0,
            .props = 0,
        }) orelse return error.SdlGpuShaderFailed;
        defer c.SDL_ReleaseGPUShader(device, fragment_shader);

        var vertex_buffers = [_]c.SDL_GPUVertexBufferDescription{.{
            .slot = 0,
            .pitch = @sizeOf(draw.Vertex),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
            .instance_step_rate = 0,
        }};
        var attributes = [_]c.SDL_GPUVertexAttribute{
            .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(draw.Vertex, "pos") },
            .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(draw.Vertex, "uv") },
            .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4, .offset = @offsetOf(draw.Vertex, "color") },
        };
        var color_targets = [_]c.SDL_GPUColorTargetDescription{.{
            .format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
            .blend_state = alphaBlendState(),
        }};
        self.pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &.{
            .vertex_shader = vertex_shader,
            .fragment_shader = fragment_shader,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vertex_buffers,
                .num_vertex_buffers = vertex_buffers.len,
                .vertex_attributes = &attributes,
                .num_vertex_attributes = attributes.len,
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
            .rasterizer_state = .{
                .fill_mode = c.SDL_GPU_FILLMODE_FILL,
                .cull_mode = c.SDL_GPU_CULLMODE_NONE,
                .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .enable_depth_bias = false,
                .enable_depth_clip = false,
                .padding1 = 0,
                .padding2 = 0,
            },
            .multisample_state = .{
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                .sample_mask = 0,
                .enable_mask = false,
                .enable_alpha_to_coverage = false,
                .padding2 = 0,
                .padding3 = 0,
            },
            .depth_stencil_state = std.mem.zeroes(c.SDL_GPUDepthStencilState),
            .target_info = .{
                .color_target_descriptions = &color_targets,
                .num_color_targets = color_targets.len,
                .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_INVALID,
                .has_depth_stencil_target = false,
                .padding1 = 0,
                .padding2 = 0,
                .padding3 = 0,
            },
            .props = 0,
        }) orelse return error.SdlGpuPipelineFailed;
    }

    fn ensureBuffers(self: *Renderer, vertex_count: usize, index_count: usize) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (vertex_count > self.vertex_capacity) {
            if (self.vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.vertex_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            self.vertex_capacity = growCapacity(vertex_count);
            const byte_size: u32 = @intCast(self.vertex_capacity * @sizeOf(draw.Vertex));
            self.vertex_buffer = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = byte_size, .props = 0 }) orelse return error.SdlGpuBufferFailed;
            self.vertex_transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = byte_size, .props = 0 }) orelse return error.SdlGpuTransferBufferFailed;
        }
        if (index_count > self.index_capacity) {
            if (self.index_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.index_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            self.index_capacity = growCapacity(index_count);
            const byte_size: u32 = @intCast(self.index_capacity * @sizeOf(u32));
            self.index_buffer = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_INDEX, .size = byte_size, .props = 0 }) orelse return error.SdlGpuBufferFailed;
            self.index_transfer = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = byte_size, .props = 0 }) orelse return error.SdlGpuTransferBufferFailed;
        }
    }

    fn uploadBuffer(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer, transfer: *c.SDL_GPUTransferBuffer, buffer: *c.SDL_GPUBuffer, bytes: []const u8) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        const mapped = c.SDL_MapGPUTransferBuffer(device, transfer, true) orelse return error.SdlGpuMapFailed;
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..bytes.len], bytes);
        c.SDL_UnmapGPUTransferBuffer(device, transfer);

        const copy_pass = c.SDL_BeginGPUCopyPass(command_buffer) orelse return error.SdlGpuCopyPassFailed;
        c.SDL_UploadToGPUBuffer(copy_pass, &.{ .transfer_buffer = transfer, .offset = 0 }, &.{ .buffer = buffer, .offset = 0, .size = @intCast(bytes.len) }, true);
        c.SDL_EndGPUCopyPass(copy_pass);
    }
};

pub const CommandCounts = struct {
    rects: usize = 0,
    text: usize = 0,
    cursors: usize = 0,
    selections: usize = 0,
    scrollbars: usize = 0,

    pub fn fromBatch(batch: *const draw.RenderBatch) CommandCounts {
        var counts: CommandCounts = .{};
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect => counts.rects += 1,
                .text => counts.text += 1,
                .cursor => counts.cursors += 1,
                .selection => counts.selections += 1,
                .scrollbar => counts.scrollbars += 1,
            }
        }
        return counts;
    }

    pub fn drawableIndexCount(self: CommandCounts) usize {
        return (self.rects + self.cursors + self.selections + self.scrollbars) * 6;
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

pub const SdlDebugRenderer = struct {
    allocator: std.mem.Allocator,
    renderer: *sdl.Renderer,

    pub fn renderBatch(self: *SdlDebugRenderer, batch: *const draw.RenderBatch) !void {
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.renderRect(command),
                .text => try self.renderText(command),
            }
        }
    }

    fn renderRect(self: *SdlDebugRenderer, command: draw.Command) !void {
        const color = colorBytes(command.color);
        if (color[3] == 0) return;
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        try sdl.renderFillRect(self.renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
    }

    fn renderText(self: *SdlDebugRenderer, command: draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        const color = colorBytes(command.color);
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        const wrap_columns = if (command.wrap)
            @max(@as(usize, @intFromFloat(@floor(command.rect.w / @max(command.glyph_width, 1.0)))), 1)
        else
            std.math.maxInt(usize);
        var row: usize = 0;
        var start: usize = 0;
        while (start <= command.text.len) {
            const hard_end = std.mem.indexOfScalarPos(u8, command.text, start, '\n') orelse command.text.len;
            var line_start = start;
            while (line_start <= hard_end) {
                const line_end = visualLineEnd(command.text[line_start..hard_end], wrap_columns) + line_start;
                const y = command.rect.y + @as(f32, @floatFromInt(row)) * command.line_height - command.scroll.y;
                if (command.clip == null or rectIntersectsY(command.clip.?, y, command.line_height)) {
                    try self.renderDebugLine(command.rect.x - command.scroll.x, y, command.text[line_start..line_end]);
                }
                row += 1;
                if (line_end >= hard_end) break;
                line_start = line_end;
            }
            if (hard_end == command.text.len) break;
            start = hard_end + 1;
        }
    }

    fn renderDebugLine(self: *SdlDebugRenderer, x: f32, y: f32, value: []const u8) !void {
        const z_text = try self.allocator.dupeZ(u8, if (value.len == 0) " " else value);
        defer self.allocator.free(z_text);
        try sdl.renderDebugText(self.renderer, x, y, z_text);
    }
};

pub fn sdlDebugRenderer(allocator: std.mem.Allocator, sdl_renderer: *sdl.Renderer) SdlDebugRenderer {
    return .{ .allocator = allocator, .renderer = sdl_renderer };
}

pub const SdlFontRenderer = struct {
    renderer: *sdl.Renderer,
    font: *sdl.Font,
    current_font_size: f32,

    pub fn renderBatch(self: *SdlFontRenderer, batch: *const draw.RenderBatch) !void {
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.renderRect(command),
                .text => try self.renderText(command),
            }
        }
    }

    pub fn renderLine(self: *SdlFontRenderer, x: f32, y: f32, value: []const u8, color: draw.Color, font_size: f32) !void {
        try self.setFontSize(font_size);
        const surface = try sdl.ttfRenderTextBlended(self.font, value, colorToSdl(color));
        defer sdl.destroySurface(surface);
        const texture = try sdl.createTextureFromSurface(self.renderer, surface);
        defer sdl.destroyTexture(texture);
        try sdl.renderTexture(self.renderer, texture, .{
            .x = x,
            .y = y,
            .w = @floatFromInt(surface.w),
            .h = @floatFromInt(surface.h),
        });
    }

    fn renderRect(self: *SdlFontRenderer, command: draw.Command) !void {
        const color = colorBytes(command.color);
        if (color[3] == 0) return;
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        try sdl.renderFillRect(self.renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
    }

    fn renderText(self: *SdlFontRenderer, command: draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        const wrap_columns = if (command.wrap)
            @max(@as(usize, @intFromFloat(@floor(command.rect.w / @max(command.glyph_width, 1.0)))), 1)
        else
            std.math.maxInt(usize);
        var row: usize = 0;
        var start: usize = 0;
        while (start <= command.text.len) {
            const hard_end = std.mem.indexOfScalarPos(u8, command.text, start, '\n') orelse command.text.len;
            var line_start = start;
            while (line_start <= hard_end) {
                const line_end = visualLineEnd(command.text[line_start..hard_end], wrap_columns) + line_start;
                const y = command.rect.y + @as(f32, @floatFromInt(row)) * command.line_height - command.scroll.y;
                if (command.clip == null or rectIntersectsY(command.clip.?, y, command.line_height)) {
                    try self.renderLine(command.rect.x - command.scroll.x, y, command.text[line_start..line_end], command.color, command.font_size);
                }
                row += 1;
                if (line_end >= hard_end) break;
                line_start = line_end;
            }
            if (hard_end == command.text.len) break;
            start = hard_end + 1;
        }
    }

    fn setFontSize(self: *SdlFontRenderer, font_size: f32) !void {
        if (@abs(self.current_font_size - font_size) < 0.01) return;
        try sdl.ttfSetFontSize(self.font, font_size);
        self.current_font_size = font_size;
    }
};

pub fn sdlFontRenderer(sdl_renderer: *sdl.Renderer, font: *sdl.Font, point_size: f32) SdlFontRenderer {
    return .{ .renderer = sdl_renderer, .font = font, .current_font_size = point_size };
}

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
    if (command.kind == .text) return;
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

fn visualLineEnd(text: []const u8, max_columns: usize) usize {
    if (text.len == 0) return 0;
    var offset: usize = 0;
    var column: usize = 0;
    while (offset < text.len and column < max_columns) : (column += 1) {
        offset = nextOffset(text, offset);
    }
    return @max(offset, 1);
}

fn nextOffset(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
    return @min(offset + len, text.len);
}

fn rectIntersectsY(rect: draw.Rect, y: f32, h: f32) bool {
    return y + h >= rect.y and y <= rect.y + rect.h;
}

fn rectToSdl(rect: draw.Rect) sdl.Rect {
    return .{
        .x = @intFromFloat(@floor(rect.x)),
        .y = @intFromFloat(@floor(rect.y)),
        .w = @intFromFloat(@ceil(rect.w)),
        .h = @intFromFloat(@ceil(rect.h)),
    };
}

fn colorBytes(color: draw.Color) [4]u8 {
    return .{ colorByte(color.r), colorByte(color.g), colorByte(color.b), colorByte(color.a) };
}

fn colorToSdl(color: draw.Color) sdl.Color {
    const bytes = colorBytes(color);
    return .{ .r = bytes[0], .g = bytes[1], .b = bytes[2], .a = bytes[3] };
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(@min(@max(value, 0.0), 1.0) * 255.0);
}

fn growCapacity(required: usize) usize {
    var capacity: usize = 64;
    while (capacity < required) capacity *= 2;
    return capacity;
}

fn alphaBlendState() c.SDL_GPUColorTargetBlendState {
    return .{
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = c.SDL_GPU_COLORCOMPONENT_R | c.SDL_GPU_COLORCOMPONENT_G | c.SDL_GPU_COLORCOMPONENT_B | c.SDL_GPU_COLORCOMPONENT_A,
        .enable_blend = true,
        .enable_color_write_mask = true,
        .padding1 = 0,
        .padding2 = 0,
    };
}

pub const ShaderSource = struct {
    pub const vertex_hlsl = @embedFile("shaders/ui.vert.hlsl");
    pub const fragment_hlsl = @embedFile("shaders/ui.frag.hlsl");
};

test "renderer builds indexed quads from commands" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .x = 1, .y = 2, .w = 3, .h = 4 }, draw.Color.white);
    try batch.cursor(std.testing.allocator, .{ .x = 5, .y = 6, .w = 7, .h = 8 }, draw.Color.white);

    var mesh: Mesh = .{};
    defer mesh.deinit(std.testing.allocator);
    try buildMesh(std.testing.allocator, &batch, &mesh);

    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.items.len);
    try std.testing.expectEqual(@as(f32, 4), mesh.vertices.items[2].pos.x);
}

test "gpu renderer renderBatch consumes command kinds" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .w = 1, .h = 1 }, draw.Color.white);
    try batch.text(std.testing.allocator, .{ .w = 20, .h = 20 }, "hello", draw.Color.white, 16, null);
    try batch.cursor(std.testing.allocator, .{ .w = 1, .h = 20 }, draw.Color.white);
    try batch.selection(std.testing.allocator, .{ .w = 10, .h = 20 }, draw.Color.white);
    try batch.scrollbar(std.testing.allocator, .{ .w = 4, .h = 20 }, draw.Color.white);

    var renderer: Renderer = .{};
    renderer.renderBatch(undefined, &batch);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.rects);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.text);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.cursors);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.selections);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.scrollbars);
    try std.testing.expectEqual(@as(usize, 1), renderer.unsupported_text_commands);
    try std.testing.expectEqual(@as(usize, 24), renderer.command_counts.drawableIndexCount());
}

test "shader format defaults target Vulkan and Metal backends" {
    try std.testing.expectEqual(ShaderFormat.vulkan, ShaderFormat.defaultForTarget(.linux));
    try std.testing.expectEqual(ShaderFormat.metal, ShaderFormat.defaultForTarget(.macos));
    try std.testing.expect(ShaderFormat.portable & ShaderFormat.vulkan != 0);
    try std.testing.expect(ShaderFormat.portable & ShaderFormat.metal != 0);
}

test "shader package rejects missing and unsupported formats" {
    const empty: ShaderPackage = .{
        .vertex = .{ .format = ShaderFormat.vulkan, .code = "" },
        .fragment = .{ .format = ShaderFormat.vulkan, .code = "x" },
    };
    try std.testing.expectError(error.MissingGpuShaderCode, empty.validate(ShaderFormat.vulkan));

    const msl_package: ShaderPackage = .{
        .vertex = .{ .format = ShaderFormat.msl, .code = "vertex" },
        .fragment = .{ .format = ShaderFormat.msl, .code = "fragment" },
    };
    try std.testing.expectError(error.UnsupportedVertexShaderFormat, msl_package.validate(ShaderFormat.vulkan));
    try msl_package.validate(ShaderFormat.metal);
}

test "gpu text support is explicit until atlas path is configured" {
    const renderer: Renderer = .{};
    try std.testing.expect(!renderer.supportsGpuText());
}
