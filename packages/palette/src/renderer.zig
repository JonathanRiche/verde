//! SDL_GPU renderer bridge for palette render batches.

const Self = @This();
const std = @import("std");

const draw = @import("draw.zig");
const sdl = @import("sdl.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
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

pub const PipelineShaderPackages = struct {
    solid: ShaderPackage,
    text: ShaderPackage,
    image: ShaderPackage,
};

pub const RendererConfig = struct {
    debug_mode: bool = false,
    shader_formats: u32 = ShaderFormat.portable,
    shader_package: ?ShaderPackage = null,
    shader_packages: ?PipelineShaderPackages = null,
    font: ?*sdl.Font = null,
};

const PipelineKind = enum { solid, text, image };
const TEXT_CACHE_MAX_ENTRIES = 4096;
const GPU_TEXT_FONT_SCALE: f32 = 0.86;

const ViewportUniform = extern struct {
    viewport_size: [2]f32,
    padding: [2]f32 = .{ 0, 0 },
};

pub const TextureUploadKind = enum {
    image,
    browser,
};

pub const FrameStats = struct {
    batch_build_ns: u64 = 0,
    solid_upload_ns: u64 = 0,
    image_prepare_ns: u64 = 0,
    image_upload_ns: u64 = 0,
    browser_upload_ns: u64 = 0,
    text_prepare_ns: u64 = 0,
    text_upload_ns: u64 = 0,
    submit_present_ns: u64 = 0,
    image_upload_bytes: usize = 0,
    browser_upload_bytes: usize = 0,
    image_upload_count: usize = 0,
    browser_upload_count: usize = 0,

    pub fn hasWork(self: FrameStats) bool {
        return self.batch_build_ns != 0 or
            self.solid_upload_ns != 0 or
            self.image_prepare_ns != 0 or
            self.image_upload_ns != 0 or
            self.browser_upload_ns != 0 or
            self.text_prepare_ns != 0 or
            self.text_upload_ns != 0 or
            self.submit_present_ns != 0 or
            self.image_upload_count != 0 or
            self.browser_upload_count != 0;
    }
};

pub const Renderer = struct {
    device: ?*c.SDL_GPUDevice = null,
    pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    text_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    image_pipeline: ?*c.SDL_GPUGraphicsPipeline = null,
    sampler: ?*c.SDL_GPUSampler = null,
    text_engine: ?*c.TTF_TextEngine = null,
    font: ?*c.TTF_Font = null,
    vertex_buffer: ?*c.SDL_GPUBuffer = null,
    index_buffer: ?*c.SDL_GPUBuffer = null,
    text_vertex_buffer: ?*c.SDL_GPUBuffer = null,
    text_index_buffer: ?*c.SDL_GPUBuffer = null,
    image_vertex_buffer: ?*c.SDL_GPUBuffer = null,
    image_index_buffer: ?*c.SDL_GPUBuffer = null,
    vertex_transfer: ?*c.SDL_GPUTransferBuffer = null,
    index_transfer: ?*c.SDL_GPUTransferBuffer = null,
    text_vertex_transfer: ?*c.SDL_GPUTransferBuffer = null,
    text_index_transfer: ?*c.SDL_GPUTransferBuffer = null,
    image_vertex_transfer: ?*c.SDL_GPUTransferBuffer = null,
    image_index_transfer: ?*c.SDL_GPUTransferBuffer = null,
    vertex_capacity: usize = 0,
    index_capacity: usize = 0,
    text_vertex_capacity: usize = 0,
    text_index_capacity: usize = 0,
    image_vertex_capacity: usize = 0,
    image_index_capacity: usize = 0,
    textures: std.AutoHashMap(u32, GpuTexture) = std.AutoHashMap(u32, GpuTexture).init(std.heap.smp_allocator),
    text_cache: std.AutoHashMap(TextCacheKey, TextCacheEntry) = std.AutoHashMap(TextCacheKey, TextCacheEntry).init(std.heap.smp_allocator),
    command_counts: CommandCounts = .{},
    solid_index_count: u32 = 0,
    unsupported_text_commands: usize = 0,
    unsupported_image_commands: usize = 0,
    last_frame_stats: FrameStats = .{},
    pending_upload_stats: FrameStats = .{},

    /// Creates the SDL_GPU device. Pass SPIR-V shaders for Vulkan and MSL or
    /// metallib shaders for Metal to create a drawable pipeline.
    pub fn init(config: RendererConfig) !Renderer {
        const device = c.SDL_CreateGPUDevice(config.shader_formats, config.debug_mode, null) orelse return error.SdlGpuCreateDeviceFailed;
        var renderer: Renderer = .{ .device = device };
        errdefer renderer.deinit();
        if (config.shader_packages) |packages| {
            try renderer.createPipelines(packages);
        } else if (config.shader_package) |package| {
            try renderer.createPipeline(package, .solid);
        }
        if (config.font) |font| {
            try renderer.configureGpuText(font);
        }
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device) |device| {
            if (self.pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            if (self.text_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            if (self.image_pipeline) |pipeline| c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
            if (self.sampler) |sampler| c.SDL_ReleaseGPUSampler(device, sampler);
            if (self.text_engine) |engine| c.TTF_DestroyGPUTextEngine(engine);
            if (self.vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.index_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.text_vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.text_index_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.image_vertex_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.image_index_buffer) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (self.vertex_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.index_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.text_vertex_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.text_index_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.image_vertex_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            if (self.image_index_transfer) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            var iterator = self.textures.iterator();
            while (iterator.next()) |entry| entry.value_ptr.deinit(device);
            self.textures.deinit();
            self.clearTextCache();
            self.text_cache.deinit();
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

    pub fn lastFrameStats(self: *const Renderer) FrameStats {
        return self.last_frame_stats;
    }

    /// Compatibility entry point for callers that already own a render pass.
    /// This records command accounting and draws existing uploaded buffers when
    /// the renderer has been initialized with shaders and resources.
    pub fn renderBatch(self: *Renderer, pass: *c.SDL_GPURenderPass, batch: *const draw.RenderBatch) void {
        self.command_counts = CommandCounts.fromBatch(batch);
        self.unsupported_text_commands = if (self.supportsGpuText()) 0 else self.command_counts.text;
        self.unsupported_image_commands = 0;
        const index_count = if (self.solid_index_count > 0)
            self.solid_index_count
        else
            @as(u32, @intCast(self.command_counts.drawableIndexCount()));
        self.renderSolidIndexedRange(pass, 0, index_count);
    }

    fn renderSolidIndexedRange(self: *Renderer, pass: *c.SDL_GPURenderPass, first_index: u32, index_count: u32) void {
        if (index_count == 0 or self.pipeline == null or self.vertex_buffer == null or self.index_buffer == null) return;
        gpuSetFullScissor(pass);
        var vertex_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.vertex_buffer.?, .offset = 0 };
        var index_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.index_buffer.?, .offset = 0 };
        c.SDL_BindGPUGraphicsPipeline(pass, self.pipeline.?);
        c.SDL_BindGPUVertexBuffers(pass, 0, &vertex_binding, 1);
        c.SDL_BindGPUIndexBuffer(pass, &index_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        c.SDL_DrawGPUIndexedPrimitives(pass, index_count, 1, first_index, 0, 0);
    }

    /// Walks commands in batch order (already sorted by `z_index`) and draws solids, images, and
    /// text in one combined order. Without this, `renderTextFrame` would paint all text after all
    /// solid geometry, ignoring per-command z layering (e.g. composer placeholder over a menu).
    fn renderBatchInterleaved(
        self: *Renderer,
        pass: *c.SDL_GPURenderPass,
        batch: *const draw.RenderBatch,
        solid_indices_after_cmd: []const u32,
        image_frame: *const ImageFrame,
        image_draws_after_cmd: []const u32,
        text_frame: *const TextFrame,
        text_draws_after_cmd: []const u32,
        target_height: f32,
    ) void {
        const cmds = batch.commands.items;
        std.debug.assert(solid_indices_after_cmd.len == cmds.len);
        std.debug.assert(image_draws_after_cmd.len == cmds.len);
        std.debug.assert(text_draws_after_cmd.len == cmds.len);

        var i: usize = 0;
        while (i < cmds.len) {
            switch (cmds[i].kind) {
                .rect, .triangle, .cursor, .selection, .scrollbar => {
                    const start = i;
                    i += 1;
                    while (i < cmds.len) {
                        switch (cmds[i].kind) {
                            .rect, .triangle, .cursor, .selection, .scrollbar => i += 1,
                            else => break,
                        }
                    }
                    const prev: u32 = if (start == 0) 0 else solid_indices_after_cmd[start - 1];
                    const end: u32 = solid_indices_after_cmd[i - 1];
                    self.renderSolidIndexedRange(pass, prev, end - prev);
                },
                .image => {
                    const prev_d: u32 = if (i == 0) 0 else image_draws_after_cmd[i - 1];
                    const end_d: u32 = image_draws_after_cmd[i];
                    self.renderImageFrameSlice(pass, image_frame, prev_d, end_d, target_height);
                    i += 1;
                },
                .text => {
                    const prev_d: u32 = if (i == 0) 0 else text_draws_after_cmd[i - 1];
                    const end_d: u32 = text_draws_after_cmd[i];
                    self.renderTextFrameSlice(pass, text_frame, prev_d, end_d, target_height);
                    i += 1;
                },
            }
        }
    }

    /// Builds and uploads the current batch into GPU buffers. Text commands are
    /// intentionally tracked, not discarded; they require an atlas texture path.
    pub fn prepareBatch(self: *Renderer, allocator: std.mem.Allocator, command_buffer: *c.SDL_GPUCommandBuffer, batch: *const draw.RenderBatch, solid_indices_after_cmd: []u32, stats: *FrameStats) !void {
        std.debug.assert(solid_indices_after_cmd.len == batch.commands.items.len);
        var mesh: Mesh = .{};
        defer mesh.deinit(allocator);
        const build_start = nowNs();
        try buildMesh(allocator, batch, &mesh, solid_indices_after_cmd);
        stats.batch_build_ns +|= elapsedNs(build_start);

        self.command_counts = CommandCounts.fromBatch(batch);
        self.solid_index_count = @intCast(mesh.indices.items.len);
        self.unsupported_text_commands = if (self.supportsGpuText()) 0 else self.command_counts.text;
        self.unsupported_image_commands = 0;
        if (mesh.vertices.items.len > 0 and mesh.indices.items.len > 0) {
            try self.ensureBuffers(.solid, mesh.vertices.items.len, mesh.indices.items.len);
            const upload_start = nowNs();
            try self.uploadBuffer(command_buffer, self.vertex_transfer.?, self.vertex_buffer.?, std.mem.sliceAsBytes(mesh.vertices.items));
            try self.uploadBuffer(command_buffer, self.index_transfer.?, self.index_buffer.?, std.mem.sliceAsBytes(mesh.indices.items));
            stats.solid_upload_ns +|= elapsedNs(upload_start);
        }
    }

    pub fn renderWindow(self: *Renderer, allocator: std.mem.Allocator, window: *sdl.Window, batch: *const draw.RenderBatch, clear_color: draw.Color) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (self.pipeline == null) return error.MissingGpuPipeline;
        if (CommandCounts.fromBatch(batch).text > 0 and !self.supportsGpuText()) return error.GpuTextAtlasNotConfigured;

        var stats = self.beginFrameStats();
        const command_buffer = c.SDL_AcquireGPUCommandBuffer(device) orelse return error.SdlGpuCommandBufferFailed;
        try self.flushPendingTextureUploads(command_buffer, &stats);
        const cmd_n = batch.commands.items.len;
        const solid_ends = try allocator.alloc(u32, cmd_n);
        defer allocator.free(solid_ends);
        const image_draw_ends = try allocator.alloc(u32, cmd_n);
        defer allocator.free(image_draw_ends);
        const text_draw_ends = try allocator.alloc(u32, cmd_n);
        defer allocator.free(text_draw_ends);
        try self.prepareBatch(allocator, command_buffer, batch, solid_ends, &stats);
        var image_frame = try self.prepareImageFrame(allocator, command_buffer, batch, image_draw_ends, &stats);
        defer image_frame.deinit(allocator);
        var text_frame = try self.prepareTextFrame(allocator, command_buffer, batch, text_draw_ends, &stats);
        defer text_frame.deinit(allocator);

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
            c.SDL_PushGPUVertexUniformData(command_buffer, 0, &ViewportUniform{ .viewport_size = .{ @floatFromInt(width), @floatFromInt(height) } }, @sizeOf(ViewportUniform));
            self.renderBatchInterleaved(
                pass,
                batch,
                solid_ends,
                &image_frame,
                image_draw_ends,
                &text_frame,
                text_draw_ends,
                @floatFromInt(height),
            );
            c.SDL_EndGPURenderPass(pass);
        }
        const submit_start = nowNs();
        if (!c.SDL_SubmitGPUCommandBuffer(command_buffer)) return error.SdlGpuSubmitFailed;
        stats.submit_present_ns +|= elapsedNs(submit_start);
        self.last_frame_stats = stats;
    }

    pub fn supportsGpuText(self: *const Renderer) bool {
        return self.text_pipeline != null and self.text_engine != null and self.font != null and self.sampler != null;
    }

    pub fn configureGpuText(self: *Renderer, font: *sdl.Font) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        self.font = @ptrCast(font);
        self.text_engine = c.TTF_CreateGPUTextEngine(device) orelse return error.SdlTtfGpuTextEngineFailed;
        c.TTF_SetGPUTextEngineWinding(self.text_engine.?, c.TTF_GPU_TEXTENGINE_WINDING_COUNTER_CLOCKWISE);
        self.sampler = c.SDL_CreateGPUSampler(device, &.{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .mip_lod_bias = 0,
            .max_anisotropy = 8,
            .compare_op = c.SDL_GPU_COMPAREOP_INVALID,
            .min_lod = 0,
            .max_lod = 0,
            .enable_anisotropy = true,
            .enable_compare = false,
            .padding1 = 0,
            .padding2 = 0,
            .props = 0,
        }) orelse return error.SdlGpuSamplerFailed;
    }

    fn createPipelines(self: *Renderer, packages: PipelineShaderPackages) !void {
        try self.createPipeline(packages.solid, .solid);
        try self.createPipeline(packages.text, .text);
        try self.createPipeline(packages.image, .image);
    }

    fn createPipeline(self: *Renderer, package: ShaderPackage, kind: PipelineKind) !void {
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
            .num_samplers = if (kind == .text or kind == .image) 1 else 0,
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
        const pipeline = c.SDL_CreateGPUGraphicsPipeline(device, &.{
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
        switch (kind) {
            .solid => self.pipeline = pipeline,
            .text => self.text_pipeline = pipeline,
            .image => self.image_pipeline = pipeline,
        }
    }

    fn ensureBuffers(self: *Renderer, kind: PipelineKind, vertex_count: usize, index_count: usize) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        const vertex_buffer = switch (kind) {
            .solid => &self.vertex_buffer,
            .text => &self.text_vertex_buffer,
            .image => &self.image_vertex_buffer,
        };
        const index_buffer = switch (kind) {
            .solid => &self.index_buffer,
            .text => &self.text_index_buffer,
            .image => &self.image_index_buffer,
        };
        const vertex_transfer = switch (kind) {
            .solid => &self.vertex_transfer,
            .text => &self.text_vertex_transfer,
            .image => &self.image_vertex_transfer,
        };
        const index_transfer = switch (kind) {
            .solid => &self.index_transfer,
            .text => &self.text_index_transfer,
            .image => &self.image_index_transfer,
        };
        const vertex_capacity = switch (kind) {
            .solid => &self.vertex_capacity,
            .text => &self.text_vertex_capacity,
            .image => &self.image_vertex_capacity,
        };
        const index_capacity = switch (kind) {
            .solid => &self.index_capacity,
            .text => &self.text_index_capacity,
            .image => &self.image_index_capacity,
        };
        if (vertex_count > vertex_capacity.*) {
            if (vertex_buffer.*) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (vertex_transfer.*) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            vertex_capacity.* = growCapacity(vertex_count);
            const byte_size: u32 = @intCast(vertex_capacity.* * @sizeOf(draw.Vertex));
            vertex_buffer.* = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX, .size = byte_size, .props = 0 }) orelse return error.SdlGpuBufferFailed;
            vertex_transfer.* = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = byte_size, .props = 0 }) orelse return error.SdlGpuTransferBufferFailed;
        }
        if (index_count > index_capacity.*) {
            if (index_buffer.*) |buffer| c.SDL_ReleaseGPUBuffer(device, buffer);
            if (index_transfer.*) |buffer| c.SDL_ReleaseGPUTransferBuffer(device, buffer);
            index_capacity.* = growCapacity(index_count);
            const byte_size: u32 = @intCast(index_capacity.* * @sizeOf(u32));
            index_buffer.* = c.SDL_CreateGPUBuffer(device, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_INDEX, .size = byte_size, .props = 0 }) orelse return error.SdlGpuBufferFailed;
            index_transfer.* = c.SDL_CreateGPUTransferBuffer(device, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = byte_size, .props = 0 }) orelse return error.SdlGpuTransferBufferFailed;
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

    pub const TextureFormat = enum {
        rgba8,
        bgra8,

        fn toSdl(self: TextureFormat) c.SDL_GPUTextureFormat {
            return switch (self) {
                .rgba8 => c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
                .bgra8 => c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
            };
        }
    };

    pub fn uploadTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, kind: TextureUploadKind, pixels: []const u8) !void {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (id == 0 or width == 0 or height == 0) return error.InvalidGpuTexture;
        const byte_len: usize = @as(usize, width) * @as(usize, height) * 4;
        if (pixels.len != byte_len) return error.InvalidGpuTexture;

        const upload_start = nowNs();
        const texture_entry = try self.ensureTexture(id, width, height, format, byte_len);
        const mapped = c.SDL_MapGPUTransferBuffer(device, texture_entry.transfer, true) orelse return error.SdlGpuMapFailed;
        @memcpy(@as([*]u8, @ptrCast(mapped))[0..byte_len], pixels);
        c.SDL_UnmapGPUTransferBuffer(device, texture_entry.transfer);
        texture_entry.dirty = true;
        texture_entry.dirty_kind = kind;

        const elapsed = elapsedNs(upload_start);
        switch (kind) {
            .image => {
                self.pending_upload_stats.image_upload_ns +|= elapsed;
                self.pending_upload_stats.image_upload_bytes += byte_len;
                self.pending_upload_stats.image_upload_count += 1;
            },
            .browser => {
                self.pending_upload_stats.browser_upload_ns +|= elapsed;
                self.pending_upload_stats.browser_upload_bytes += byte_len;
                self.pending_upload_stats.browser_upload_count += 1;
            },
        }
    }

    fn ensureTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, byte_len: usize) !*GpuTexture {
        const device = self.device orelse return error.SdlGpuCreateDeviceFailed;
        if (self.textures.getPtr(id)) |entry| {
            if (entry.width == width and entry.height == height and entry.format == format and entry.transfer_size >= byte_len) return entry;
            entry.deinit(device);
            _ = self.textures.remove(id);
        }

        const texture = c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = format.toSdl(),
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            .props = 0,
        }) orelse return error.SdlGpuTextureFailed;
        errdefer c.SDL_ReleaseGPUTexture(device, texture);

        const transfer_size: u32 = @intCast(byte_len);
        const transfer = c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = transfer_size,
            .props = 0,
        }) orelse return error.SdlGpuTransferBufferFailed;
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, transfer);

        try self.textures.put(id, .{
            .texture = texture,
            .transfer = transfer,
            .transfer_size = byte_len,
            .width = width,
            .height = height,
            .format = format,
            .dirty = false,
            .dirty_kind = .image,
        });
        return self.textures.getPtr(id).?;
    }

    pub fn releaseTexture(self: *Renderer, id: u32) void {
        const device = self.device orelse return;
        if (self.textures.fetchRemove(id)) |entry| {
            var texture = entry.value;
            texture.deinit(device);
        }
    }

    fn beginFrameStats(self: *Renderer) FrameStats {
        const stats = self.pending_upload_stats;
        self.pending_upload_stats = .{};
        return stats;
    }

    fn flushPendingTextureUploads(self: *Renderer, command_buffer: *c.SDL_GPUCommandBuffer, stats: *FrameStats) !void {
        var copy_pass: ?*c.SDL_GPUCopyPass = null;
        defer if (copy_pass) |pass| c.SDL_EndGPUCopyPass(pass);

        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.dirty) continue;
            const pass = copy_pass orelse blk: {
                const created = c.SDL_BeginGPUCopyPass(command_buffer) orelse return error.SdlGpuCopyPassFailed;
                copy_pass = created;
                break :blk created;
            };
            const texture_entry = entry.value_ptr;
            const upload_start = nowNs();
            c.SDL_UploadToGPUTexture(
                pass,
                &.{
                    .transfer_buffer = texture_entry.transfer,
                    .offset = 0,
                    .pixels_per_row = texture_entry.width,
                    .rows_per_layer = texture_entry.height,
                },
                &.{
                    .texture = texture_entry.texture,
                    .mip_level = 0,
                    .layer = 0,
                    .x = 0,
                    .y = 0,
                    .z = 0,
                    .w = texture_entry.width,
                    .h = texture_entry.height,
                    .d = 1,
                },
                true,
            );
            const elapsed = elapsedNs(upload_start);
            switch (texture_entry.dirty_kind) {
                .image => stats.image_upload_ns +|= elapsed,
                .browser => stats.browser_upload_ns +|= elapsed,
            }
            texture_entry.dirty = false;
        }
    }

    fn prepareImageFrame(self: *Renderer, allocator: std.mem.Allocator, command_buffer: *c.SDL_GPUCommandBuffer, batch: *const draw.RenderBatch, image_draws_after_cmd: []u32, stats: *FrameStats) !ImageFrame {
        var frame: ImageFrame = .{};
        errdefer frame.deinit(allocator);
        std.debug.assert(image_draws_after_cmd.len == batch.commands.items.len);
        if (self.image_pipeline == null or self.sampler == null) {
            @memset(image_draws_after_cmd, 0);
            return frame;
        }

        const prepare_start = nowNs();
        try frame.mesh.vertices.ensureUnusedCapacity(allocator, batch.commands.items.len * 4);
        try frame.mesh.indices.ensureUnusedCapacity(allocator, batch.commands.items.len * 6);
        for (batch.commands.items, 0..) |command, cmd_i| {
            if (command.kind == .image and command.texture.valid() and command.color.a > 0.0) {
                const texture = self.textures.get(@intCast(command.texture.value)) orelse {
                    self.unsupported_image_commands += 1;
                    image_draws_after_cmd[cmd_i] = @intCast(frame.draws.items.len);
                    continue;
                };
                const first_index: u32 = @intCast(frame.mesh.indices.items.len);
                try appendQuad(&frame.mesh, allocator, command.rect, command.uv, command.color);
                const index_count: u32 = @intCast(frame.mesh.indices.items.len - first_index);
                if (index_count > 0) {
                    try frame.draws.append(allocator, .{
                        .texture = texture.texture,
                        .first_index = first_index,
                        .index_count = index_count,
                        .clip = command.clip,
                    });
                }
            }
            image_draws_after_cmd[cmd_i] = @intCast(frame.draws.items.len);
        }
        stats.image_prepare_ns +|= elapsedNs(prepare_start);

        if (frame.mesh.vertices.items.len > 0 and frame.mesh.indices.items.len > 0) {
            try self.ensureBuffers(.image, frame.mesh.vertices.items.len, frame.mesh.indices.items.len);
            const upload_start = nowNs();
            try self.uploadBuffer(command_buffer, self.image_vertex_transfer.?, self.image_vertex_buffer.?, std.mem.sliceAsBytes(frame.mesh.vertices.items));
            try self.uploadBuffer(command_buffer, self.image_index_transfer.?, self.image_index_buffer.?, std.mem.sliceAsBytes(frame.mesh.indices.items));
            stats.image_upload_ns +|= elapsedNs(upload_start);
        }
        return frame;
    }

    fn prepareTextFrame(self: *Renderer, allocator: std.mem.Allocator, command_buffer: *c.SDL_GPUCommandBuffer, batch: *const draw.RenderBatch, text_draws_after_cmd: []u32, stats: *FrameStats) !TextFrame {
        var frame: TextFrame = .{};
        errdefer frame.deinit(allocator);
        std.debug.assert(text_draws_after_cmd.len == batch.commands.items.len);
        if (!self.supportsGpuText()) {
            @memset(text_draws_after_cmd, 0);
            return frame;
        }
        const prepare_start = nowNs();
        for (batch.commands.items, 0..) |command, cmd_i| {
            if (command.kind == .text and command.text.len > 0 and command.color.a > 0.0) {
                try self.appendTextCommand(allocator, &frame, command);
            }
            text_draws_after_cmd[cmd_i] = @intCast(frame.draws.items.len);
        }
        stats.text_prepare_ns +|= elapsedNs(prepare_start);
        if (frame.vertices.items.len > 0 and frame.indices.items.len > 0) {
            try self.ensureBuffers(.text, frame.vertices.items.len, frame.indices.items.len);
            const upload_start = nowNs();
            try self.uploadBuffer(command_buffer, self.text_vertex_transfer.?, self.text_vertex_buffer.?, std.mem.sliceAsBytes(frame.vertices.items));
            try self.uploadBuffer(command_buffer, self.text_index_transfer.?, self.text_index_buffer.?, std.mem.sliceAsBytes(frame.indices.items));
            stats.text_upload_ns +|= elapsedNs(upload_start);
        }
        return frame;
    }

    fn appendTextCommand(self: *Renderer, allocator: std.mem.Allocator, frame: *TextFrame, command: draw.Command) !void {
        if (command.text_runs.len > 0) {
            for (command.text_runs) |run| {
                try self.appendNaturalTextSlice(allocator, frame, run.text, run.x - command.scroll.x, run.y - command.scroll.y, run.color, run.font_size, run.clip, null, null);
            }
            return;
        }
        try self.appendNaturalTextSlice(allocator, frame, command.text, command.rect.x - command.scroll.x, command.rect.y - command.scroll.y, command.color, command.font_size, command.clip, if (command.wrap) command.rect.w else null, null);
    }

    fn appendNaturalTextSlice(self: *Renderer, allocator: std.mem.Allocator, frame: *TextFrame, value: []const u8, x: f32, y: f32, color_value: draw.Color, font_size: f32, clip: ?draw.Rect, wrap_width: ?f32, target_width: ?f32) !void {
        const key = textCacheKey(value, font_size, wrap_width);
        if (self.text_cache.getPtr(key)) |entry| {
            try appendCachedText(allocator, frame, entry, x, y, color_value, clip, target_width);
            return;
        }

        if (self.text_cache.count() >= TEXT_CACHE_MAX_ENTRIES) self.clearTextCache();
        var cache_entry = try self.createTextCacheEntry(value, font_size, wrap_width);
        errdefer cache_entry.deinit();
        try appendCachedText(allocator, frame, &cache_entry, x, y, color_value, clip, target_width);
        try self.text_cache.put(key, cache_entry);
    }

    fn appendFixedTextSlice(self: *Renderer, allocator: std.mem.Allocator, frame: *TextFrame, value: []const u8, x: f32, y: f32, color_value: draw.Color, font_size: f32, glyph_width: f32, line_height: f32, clip: ?draw.Rect, wrap_width: ?f32) !void {
        var cursor_x = x;
        var cursor_y = y;
        const max_x = if (wrap_width) |width| x + @max(width, glyph_width) else std.math.floatMax(f32);
        var index: usize = 0;
        while (index < value.len) {
            const byte = value[index];
            if (byte == '\n') {
                cursor_x = x;
                cursor_y += line_height;
                index += 1;
                continue;
            }
            const len = utf8ByteLen(byte, value.len - index);
            const slice = value[index .. index + len];
            const advance = if (byte == '\t') glyph_width * 4.0 else glyph_width;
            if (wrap_width != null and cursor_x > x and cursor_x + advance > max_x) {
                cursor_x = x;
                cursor_y += line_height;
            }
            if (!isTextSpace(slice)) {
                try self.appendTextGlyph(allocator, frame, slice, cursor_x, cursor_y, color_value, font_size, clip);
            }
            cursor_x += advance;
            index += len;
        }
    }

    fn appendTextGlyph(self: *Renderer, allocator: std.mem.Allocator, frame: *TextFrame, value: []const u8, x: f32, y: f32, color_value: draw.Color, font_size: f32, clip: ?draw.Rect) !void {
        const key = textCacheKey(value, font_size, null);
        if (self.text_cache.getPtr(key)) |entry| {
            try appendCachedText(allocator, frame, entry, x, y, color_value, clip, null);
            return;
        }

        if (self.text_cache.count() >= TEXT_CACHE_MAX_ENTRIES) self.clearTextCache();
        var cache_entry = try self.createTextCacheEntry(value, font_size, null);
        errdefer cache_entry.deinit();
        try appendCachedText(allocator, frame, &cache_entry, x, y, color_value, clip, null);
        try self.text_cache.put(key, cache_entry);
    }

    fn createTextCacheEntry(self: *Renderer, value: []const u8, font_size: f32, wrap_width: ?f32) !TextCacheEntry {
        var entry: TextCacheEntry = .{};
        errdefer entry.deinit();

        if (!c.TTF_SetFontSize(self.font.?, font_size * GPU_TEXT_FONT_SCALE)) return error.SdlTtfTextFailed;
        const text = c.TTF_CreateText(self.text_engine.?, self.font.?, value.ptr, value.len) orelse return error.SdlTtfCreateTextFailed;
        errdefer c.TTF_DestroyText(text);
        if (wrap_width) |width| {
            if (width > 0 and !c.TTF_SetTextWrapWidth(text, @intFromFloat(@ceil(width)))) return error.SdlTtfTextFailed;
        }
        if (!c.TTF_UpdateText(text)) return error.SdlTtfTextFailed;
        const sequence_head = c.TTF_GetGPUTextDrawData(text) orelse return entry;

        var sequence: ?*c.TTF_GPUAtlasDrawSequence = sequence_head;
        while (sequence) |seq| : (sequence = seq.next) {
            if (seq.num_vertices <= 0 or seq.num_indices <= 0) continue;
            const base_vertex: u32 = @intCast(entry.vertices.items.len);
            const first_index: u32 = @intCast(entry.indices.items.len);
            try entry.vertices.ensureUnusedCapacity(std.heap.smp_allocator, @intCast(seq.num_vertices));
            try entry.indices.ensureUnusedCapacity(std.heap.smp_allocator, @intCast(seq.num_indices));

            const xy = @as([*]const c.SDL_FPoint, @ptrCast(seq.xy))[0..@intCast(seq.num_vertices)];
            const uv = @as([*]const c.SDL_FPoint, @ptrCast(seq.uv))[0..@intCast(seq.num_vertices)];
            for (xy, uv) |point, texcoord| {
                entry.min_x = @min(entry.min_x, point.x);
                entry.max_x = @max(entry.max_x, point.x);
                entry.vertices.appendAssumeCapacity(.{
                    .pos = .{ .x = point.x, .y = -point.y },
                    .uv = .{ .x = texcoord.x, .y = texcoord.y },
                });
            }
            const raw_indices = @as([*]const c_int, @ptrCast(seq.indices))[0..@intCast(seq.num_indices)];
            for (raw_indices) |index| entry.indices.appendAssumeCapacity(base_vertex + @as(u32, @intCast(index)));
            const atlas_texture = seq.atlas_texture orelse continue;
            try entry.draws.append(std.heap.smp_allocator, .{
                .atlas_texture = atlas_texture,
                .first_index = first_index,
                .index_count = @intCast(seq.num_indices),
            });
        }
        if (!c.TTF_SetTextFont(text, null)) return error.SdlTtfTextFailed;
        entry.text = text;
        return entry;
    }

    fn clearTextCache(self: *Renderer) void {
        var iterator = self.text_cache.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.text_cache.clearRetainingCapacity();
    }

    fn renderImageFrame(self: *Renderer, pass: *c.SDL_GPURenderPass, frame: *const ImageFrame, target_height: f32) void {
        self.renderImageFrameSlice(pass, frame, 0, frame.draws.items.len, target_height);
    }

    fn renderImageFrameSlice(self: *Renderer, pass: *c.SDL_GPURenderPass, frame: *const ImageFrame, draw_begin: usize, draw_end: usize, target_height: f32) void {
        if (self.image_vertex_buffer == null or self.image_index_buffer == null or self.sampler == null) {
            gpuSetFullScissor(pass);
            return;
        }
        if (frame.draws.items.len == 0 or draw_begin >= draw_end) {
            gpuSetFullScissor(pass);
            return;
        }
        var vertex_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.image_vertex_buffer.?, .offset = 0 };
        var index_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.image_index_buffer.?, .offset = 0 };
        c.SDL_BindGPUGraphicsPipeline(pass, self.image_pipeline.?);
        c.SDL_BindGPUVertexBuffers(pass, 0, &vertex_binding, 1);
        c.SDL_BindGPUIndexBuffer(pass, &index_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        for (frame.draws.items[draw_begin..draw_end]) |draw_call| {
            if (draw_call.clip) |clip| {
                var scissor = toSdlRect(clip, target_height);
                c.SDL_SetGPUScissor(pass, &scissor);
            } else {
                gpuSetFullScissor(pass);
            }
            var texture_binding: c.SDL_GPUTextureSamplerBinding = .{ .texture = draw_call.texture, .sampler = self.sampler.? };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &texture_binding, 1);
            c.SDL_DrawGPUIndexedPrimitives(pass, draw_call.index_count, 1, draw_call.first_index, 0, 0);
        }
        gpuSetFullScissor(pass);
    }

    fn renderTextFrame(self: *Renderer, pass: *c.SDL_GPURenderPass, frame: *const TextFrame, target_height: f32) void {
        self.renderTextFrameSlice(pass, frame, 0, frame.draws.items.len, target_height);
    }

    fn renderTextFrameSlice(self: *Renderer, pass: *c.SDL_GPURenderPass, frame: *const TextFrame, draw_begin: usize, draw_end: usize, target_height: f32) void {
        if (self.text_vertex_buffer == null or self.text_index_buffer == null) {
            gpuSetFullScissor(pass);
            return;
        }
        if (frame.draws.items.len == 0 or draw_begin >= draw_end) {
            gpuSetFullScissor(pass);
            return;
        }
        var vertex_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.text_vertex_buffer.?, .offset = 0 };
        var index_binding: c.SDL_GPUBufferBinding = .{ .buffer = self.text_index_buffer.?, .offset = 0 };
        c.SDL_BindGPUGraphicsPipeline(pass, self.text_pipeline.?);
        c.SDL_BindGPUVertexBuffers(pass, 0, &vertex_binding, 1);
        c.SDL_BindGPUIndexBuffer(pass, &index_binding, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
        for (frame.draws.items[draw_begin..draw_end]) |draw_call| {
            if (draw_call.clip) |clip| {
                var scissor = toSdlRect(clip, target_height);
                c.SDL_SetGPUScissor(pass, &scissor);
            } else {
                gpuSetFullScissor(pass);
            }
            var texture_binding: c.SDL_GPUTextureSamplerBinding = .{ .texture = draw_call.atlas_texture, .sampler = self.sampler.? };
            c.SDL_BindGPUFragmentSamplers(pass, 0, &texture_binding, 1);
            c.SDL_DrawGPUIndexedPrimitives(pass, draw_call.index_count, 1, draw_call.first_index, 0, 0);
        }
        gpuSetFullScissor(pass);
    }
};

pub const CommandCounts = struct {
    rects: usize = 0,
    triangles: usize = 0,
    text: usize = 0,
    images: usize = 0,
    cursors: usize = 0,
    selections: usize = 0,
    scrollbars: usize = 0,

    pub fn fromBatch(batch: *const draw.RenderBatch) CommandCounts {
        var counts: CommandCounts = .{};
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect => counts.rects += 1,
                .triangle => counts.triangles += 1,
                .text => counts.text += 1,
                .image => counts.images += 1,
                .cursor => counts.cursors += 1,
                .selection => counts.selections += 1,
                .scrollbar => counts.scrollbars += 1,
            }
        }
        return counts;
    }

    pub fn drawableIndexCount(self: CommandCounts) usize {
        return (self.rects + self.cursors + self.selections + self.scrollbars) * 6 + self.triangles * 3;
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

const GpuTexture = struct {
    texture: *c.SDL_GPUTexture,
    transfer: *c.SDL_GPUTransferBuffer,
    transfer_size: usize,
    width: u32,
    height: u32,
    format: Renderer.TextureFormat,
    dirty: bool = false,
    dirty_kind: TextureUploadKind = .image,

    fn deinit(self: *GpuTexture, device: *c.SDL_GPUDevice) void {
        c.SDL_ReleaseGPUTexture(device, self.texture);
        c.SDL_ReleaseGPUTransferBuffer(device, self.transfer);
        self.* = undefined;
    }
};

const ImageDraw = struct {
    texture: *c.SDL_GPUTexture,
    first_index: u32,
    index_count: u32,
    clip: ?draw.Rect,
};

const ImageFrame = struct {
    mesh: Mesh = .{},
    draws: std.ArrayList(ImageDraw) = .empty,

    fn deinit(self: *ImageFrame, allocator: std.mem.Allocator) void {
        self.mesh.deinit(allocator);
        self.draws.deinit(allocator);
        self.* = .{};
    }
};

const TextDraw = struct {
    atlas_texture: *c.SDL_GPUTexture,
    first_index: u32,
    index_count: u32,
    clip: ?draw.Rect,
};

const TextFrame = struct {
    vertices: std.ArrayList(draw.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    draws: std.ArrayList(TextDraw) = .empty,

    fn deinit(self: *TextFrame, allocator: std.mem.Allocator) void {
        self.vertices.deinit(allocator);
        self.indices.deinit(allocator);
        self.draws.deinit(allocator);
    }
};

const TextCacheKey = struct {
    text_hash: u64,
    text_len: usize,
    font_size_bits: u32,
    wrap_width_bits: u32,
};

const TextCacheVertex = struct {
    pos: draw.Vec2,
    uv: draw.Vec2,
};

const TextCacheDraw = struct {
    atlas_texture: *c.SDL_GPUTexture,
    first_index: u32,
    index_count: u32,
};

const TextCacheEntry = struct {
    vertices: std.ArrayList(TextCacheVertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    draws: std.ArrayList(TextCacheDraw) = .empty,
    text: ?*c.TTF_Text = null,
    min_x: f32 = std.math.floatMax(f32),
    max_x: f32 = -std.math.floatMax(f32),

    fn deinit(self: *TextCacheEntry) void {
        if (self.text) |text| c.TTF_DestroyText(text);
        self.vertices.deinit(std.heap.smp_allocator);
        self.indices.deinit(std.heap.smp_allocator);
        self.draws.deinit(std.heap.smp_allocator);
        self.* = .{};
    }
};

fn appendCachedText(allocator: std.mem.Allocator, frame: *TextFrame, entry: *const TextCacheEntry, x: f32, y: f32, color: draw.Color, clip: ?draw.Rect, target_width: ?f32) !void {
    if (entry.vertices.items.len == 0 or entry.indices.items.len == 0) return;
    const base_vertex: u32 = @intCast(frame.vertices.items.len);
    const first_index: u32 = @intCast(frame.indices.items.len);
    try frame.vertices.ensureUnusedCapacity(allocator, entry.vertices.items.len);
    try frame.indices.ensureUnusedCapacity(allocator, entry.indices.items.len);
    const natural_width = if (std.math.isFinite(entry.min_x) and std.math.isFinite(entry.max_x)) @max(entry.max_x - entry.min_x, 0.0) else 0.0;
    const scale_x = if (target_width) |width| if (natural_width > 0.0 and width > 0.0) width / natural_width else 1.0 else 1.0;
    const origin_x = if (target_width != null and std.math.isFinite(entry.min_x)) entry.min_x else 0.0;
    for (entry.vertices.items) |vertex| {
        frame.vertices.appendAssumeCapacity(.{
            .pos = .{ .x = x + (vertex.pos.x - origin_x) * scale_x, .y = y + vertex.pos.y },
            .uv = vertex.uv,
            .color = color,
        });
    }
    for (entry.indices.items) |index| frame.indices.appendAssumeCapacity(base_vertex + index);
    for (entry.draws.items) |draw_call| {
        try frame.draws.append(allocator, .{
            .atlas_texture = draw_call.atlas_texture,
            .first_index = first_index + draw_call.first_index,
            .index_count = draw_call.index_count,
            .clip = clip,
        });
    }
}

fn utf8ByteLen(first: u8, remaining: usize) usize {
    const requested: usize = if ((first & 0x80) == 0)
        1
    else if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        1;
    return @min(requested, @max(remaining, 1));
}

fn isTextSpace(value: []const u8) bool {
    if (value.len == 1) return value[0] == ' ' or value[0] == '\t' or value[0] == '\r';
    return std.mem.eql(u8, value, "\xc2\xa0");
}

pub const SdlDebugRenderer = struct {
    allocator: std.mem.Allocator,
    renderer: *sdl.Renderer,

    pub fn renderBatch(self: *SdlDebugRenderer, batch: *const draw.RenderBatch) !void {
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.renderRect(command),
                .triangle => {},
                .text => try self.renderText(command),
                .image => try self.renderImage(command),
            }
        }
    }

    fn renderRect(self: *SdlDebugRenderer, command: draw.Command) !void {
        try renderStyledRect(self.renderer, command);
    }

    fn renderText(self: *SdlDebugRenderer, command: draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        const color = colorBytes(command.color);
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        if (command.text_runs.len > 0) {
            for (command.text_runs) |run| {
                if (run.text.len == 0) continue;
                if (run.clip == null or rectIntersectsY(run.clip.?, run.y, run.line_height)) {
                    try self.renderDebugLine(run.x, run.y, run.text);
                }
            }
            return;
        }

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

    fn renderImage(self: *SdlDebugRenderer, command: draw.Command) !void {
        try self.renderRect(.{ .kind = .rect, .rect = command.rect, .color = command.color });
        try self.renderDebugLine(command.rect.x + 4, command.rect.y + 4, if (command.texture.valid()) "image" else "image?");
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
    texture_context: ?*anyopaque = null,
    texture_lookup: ?*const fn (context: ?*anyopaque, id: draw.TextureId) ?SdlTexture = null,

    pub fn renderBatch(self: *SdlFontRenderer, batch: *const draw.RenderBatch) !void {
        for (batch.commands.items) |command| {
            switch (command.kind) {
                .rect, .cursor, .selection, .scrollbar => try self.renderRect(command),
                .triangle => {},
                .text => try self.renderText(command),
                .image => try self.renderImage(command),
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
        try renderStyledRect(self.renderer, command);
    }

    fn renderText(self: *SdlFontRenderer, command: draw.Command) !void {
        if (command.text.len == 0 or command.color.a <= 0.0) return;
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        if (command.text_runs.len > 0) {
            for (command.text_runs) |run| {
                if (run.text.len == 0) continue;
                if (run.clip == null or rectIntersectsY(run.clip.?, run.y, run.line_height)) {
                    try self.renderLine(run.x, run.y, run.text, run.color, run.font_size);
                }
            }
            return;
        }

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

    fn renderImage(self: *SdlFontRenderer, command: draw.Command) !void {
        if (command.color.a <= 0.0) return;
        if (command.clip) |clip| try sdl.setRenderClipRect(self.renderer, rectToSdl(clip));
        defer if (command.clip != null) sdl.setRenderClipRect(self.renderer, null) catch {};

        if (command.texture.valid()) {
            if (self.texture_lookup) |lookup| {
                if (lookup(self.texture_context, command.texture)) |texture| {
                    const src = texture.sourceRect(command.uv);
                    try sdl.renderTextureRegion(self.renderer, texture.texture, src, .{
                        .x = command.rect.x,
                        .y = command.rect.y,
                        .w = command.rect.w,
                        .h = command.rect.h,
                    });
                    return;
                }
            }
        }
        try self.renderImageFallback(command);
    }

    fn renderImageFallback(self: *SdlFontRenderer, command: draw.Command) !void {
        const color = colorBytes(.{ .r = command.color.r * 0.35, .g = command.color.g * 0.35, .b = command.color.b * 0.35, .a = command.color.a });
        if (color[3] == 0) return;
        try sdl.setRenderDrawColor(self.renderer, color[0], color[1], color[2], color[3]);
        try sdl.renderFillRect(self.renderer, .{
            .x = command.rect.x,
            .y = command.rect.y,
            .w = command.rect.w,
            .h = command.rect.h,
        });
        try self.renderLine(command.rect.x + 4, command.rect.y + 4, if (command.texture.valid()) "image" else "missing image", draw.Color.white, @min(self.current_font_size, 12.0));
    }

    fn setFontSize(self: *SdlFontRenderer, font_size: f32) !void {
        if (@abs(self.current_font_size - font_size) < 0.01) return;
        try sdl.ttfSetFontSize(self.font, font_size);
        self.current_font_size = font_size;
    }
};

pub const SdlTexture = struct {
    texture: *sdl.Texture,
    width: f32,
    height: f32,

    pub fn sourceRect(self: SdlTexture, uv: draw.Rect) sdl.FRect {
        const u = if (uv.w == 0.0 and uv.h == 0.0) draw.Rect{ .w = 1.0, .h = 1.0 } else uv;
        return .{
            .x = u.x * self.width,
            .y = u.y * self.height,
            .w = u.w * self.width,
            .h = u.h * self.height,
        };
    }
};

pub fn sdlFontRenderer(sdl_renderer: *sdl.Renderer, font: *sdl.Font, point_size: f32) SdlFontRenderer {
    return .{ .renderer = sdl_renderer, .font = font, .current_font_size = point_size };
}

pub fn sdlFontRendererWithTextures(
    sdl_renderer: *sdl.Renderer,
    font: *sdl.Font,
    point_size: f32,
    texture_context: ?*anyopaque,
    texture_lookup: *const fn (context: ?*anyopaque, id: draw.TextureId) ?SdlTexture,
) SdlFontRenderer {
    return .{
        .renderer = sdl_renderer,
        .font = font,
        .current_font_size = point_size,
        .texture_context = texture_context,
        .texture_lookup = texture_lookup,
    };
}

/// Converts retained render commands into indexed quads ready for GPU upload.
pub fn buildMesh(allocator: std.mem.Allocator, batch: *const draw.RenderBatch, mesh: *Mesh, solid_indices_after_cmd: ?[]u32) !void {
    mesh.clear();
    if (solid_indices_after_cmd) |ends| {
        std.debug.assert(ends.len == batch.commands.items.len);
    }
    try mesh.vertices.ensureUnusedCapacity(allocator, batch.commands.items.len * 8);
    try mesh.indices.ensureUnusedCapacity(allocator, batch.commands.items.len * 12);
    for (batch.commands.items, 0..) |command, i| {
        try appendCommand(allocator, mesh, command);
        if (solid_indices_after_cmd) |ends| {
            ends[i] = @intCast(mesh.indices.items.len);
        }
    }
}

fn appendCommand(allocator: std.mem.Allocator, mesh: *Mesh, command: draw.Command) !void {
    if (command.kind == .text or command.kind == .image) return;
    if (command.kind == .triangle) {
        try appendTriangle(allocator, mesh, command.p0, command.p1, command.p2, command.color, command.clip);
        return;
    }
    if (command.border_color) |border| {
        if (command.border_width > 0.0 and border.a > 0.0) {
            const border_width = @max(command.border_width, 1.0);
            if (command.color.a > 0.0) {
                try appendRoundedRect(allocator, mesh, command.rect, border, command.radius, command.clip);
            } else {
                try appendRoundedBorder(allocator, mesh, command.rect, border, command.radius, border_width, command.clip);
            }
        }
    }
    if (command.color.a <= 0.0) return;
    const rect = if (command.border_color != null and command.border_width > 0.0)
        insetRect(command.rect, command.border_width)
    else
        command.rect;
    try appendRoundedRect(allocator, mesh, rect, command.color, @max(command.radius - command.border_width, 0.0), command.clip);
}

fn appendQuad(mesh: *Mesh, allocator: std.mem.Allocator, rect: draw.Rect, uv: draw.Rect, color: draw.Color) !void {
    if (rect.w <= 0.0 or rect.h <= 0.0 or color.a <= 0.0) return;
    const base: u32 = @intCast(mesh.vertices.items.len);
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    const uv_x0 = uv.x;
    const uv_y0 = uv.y;
    const uv_x1 = uv.x + uv.w;
    const uv_y1 = uv.y + uv.h;
    try mesh.vertices.appendSlice(allocator, &.{
        .{ .pos = .{ .x = x0, .y = y0 }, .uv = .{ .x = uv_x0, .y = uv_y0 }, .color = color },
        .{ .pos = .{ .x = x1, .y = y0 }, .uv = .{ .x = uv_x1, .y = uv_y0 }, .color = color },
        .{ .pos = .{ .x = x1, .y = y1 }, .uv = .{ .x = uv_x1, .y = uv_y1 }, .color = color },
        .{ .pos = .{ .x = x0, .y = y1 }, .uv = .{ .x = uv_x0, .y = uv_y1 }, .color = color },
    });
    try mesh.indices.appendSlice(allocator, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
}

fn appendTriangle(allocator: std.mem.Allocator, mesh: *Mesh, p0: draw.Vec2, p1: draw.Vec2, p2: draw.Vec2, color: draw.Color, clip: ?draw.Rect) !void {
    if (color.a <= 0.0) return;
    if (clip) |clip_rect| {
        if (!clip_rect.contains(p0) and !clip_rect.contains(p1) and !clip_rect.contains(p2)) return;
    }
    const base: u32 = @intCast(mesh.vertices.items.len);
    try mesh.vertices.appendSlice(allocator, &.{
        .{ .pos = p0, .uv = .{}, .color = color },
        .{ .pos = p1, .uv = .{}, .color = color },
        .{ .pos = p2, .uv = .{}, .color = color },
    });
    try mesh.indices.appendSlice(allocator, &.{ base, base + 1, base + 2 });
}

fn appendBorderQuads(allocator: std.mem.Allocator, mesh: *Mesh, rect: draw.Rect, color: draw.Color, width: f32, clip: ?draw.Rect) !void {
    const w = @min(@max(width, 0.0), @min(rect.w, rect.h));
    try appendRect(allocator, mesh, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = w }, color, clip);
    try appendRect(allocator, mesh, .{ .x = rect.x, .y = rect.y + rect.h - w, .w = rect.w, .h = w }, color, clip);
    try appendRect(allocator, mesh, .{ .x = rect.x, .y = rect.y, .w = w, .h = rect.h }, color, clip);
    try appendRect(allocator, mesh, .{ .x = rect.x + rect.w - w, .y = rect.y, .w = w, .h = rect.h }, color, clip);
}

fn appendRect(allocator: std.mem.Allocator, mesh: *Mesh, rect: draw.Rect, color: draw.Color, clip: ?draw.Rect) !void {
    const clipped = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
    try appendQuad(mesh, allocator, clipped, .{}, color);
}

fn appendRoundedRect(allocator: std.mem.Allocator, mesh: *Mesh, rect: draw.Rect, color: draw.Color, radius: f32, clip: ?draw.Rect) !void {
    if (color.a <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0) return;
    const r = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
    const cr = clampedRadius(r, radius);
    if (cr <= 0.5) {
        try appendQuad(mesh, allocator, r, .{}, color);
        return;
    }

    try appendQuad(mesh, allocator, .{ .x = r.x + cr, .y = r.y, .w = r.w - cr * 2.0, .h = r.h }, .{}, color);
    try appendQuad(mesh, allocator, .{ .x = r.x, .y = r.y + cr, .w = cr, .h = r.h - cr * 2.0 }, .{}, color);
    try appendQuad(mesh, allocator, .{ .x = r.x + r.w - cr, .y = r.y + cr, .w = cr, .h = r.h - cr * 2.0 }, .{}, color);

    const segments = roundedSegmentCount(cr);
    try appendCornerFan(allocator, mesh, r.x + cr, r.y + cr, cr, std.math.pi, std.math.pi * 1.5, segments, color);
    try appendCornerFan(allocator, mesh, r.x + r.w - cr, r.y + cr, cr, std.math.pi * 1.5, std.math.pi * 2.0, segments, color);
    try appendCornerFan(allocator, mesh, r.x + r.w - cr, r.y + r.h - cr, cr, 0.0, std.math.pi * 0.5, segments, color);
    try appendCornerFan(allocator, mesh, r.x + cr, r.y + r.h - cr, cr, std.math.pi * 0.5, std.math.pi, segments, color);
}

fn appendCornerFan(allocator: std.mem.Allocator, mesh: *Mesh, cx: f32, cy: f32, radius: f32, start_angle: f32, end_angle: f32, segments: usize, color: draw.Color) !void {
    const center: draw.Vertex = .{ .pos = .{ .x = cx, .y = cy }, .uv = .{}, .color = color };
    var index: usize = 0;
    while (index < segments) : (index += 1) {
        const t0 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        const t1 = @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(segments));
        const a0 = start_angle + (end_angle - start_angle) * t0;
        const a1 = start_angle + (end_angle - start_angle) * t1;
        try appendTriangle(allocator, mesh, center.pos, .{
            .x = cx + @cos(a0) * radius,
            .y = cy + @sin(a0) * radius,
        }, .{
            .x = cx + @cos(a1) * radius,
            .y = cy + @sin(a1) * radius,
        }, color, null);
    }
}

fn appendRoundedBorder(allocator: std.mem.Allocator, mesh: *Mesh, rect: draw.Rect, color: draw.Color, radius: f32, width: f32, clip: ?draw.Rect) !void {
    if (color.a <= 0.0 or rect.w <= 0.0 or rect.h <= 0.0 or width <= 0.0) return;
    const r = if (clip) |clip_rect| clippedRect(rect, clip_rect) orelse return else rect;
    const cr = clampedRadius(r, radius);
    const thickness = @max(width, 1.0);
    const inner = insetRect(r, thickness);
    if (cr <= 0.5 or inner.w <= 0.0 or inner.h <= 0.0) {
        try appendBorderQuads(allocator, mesh, r, color, thickness, null);
        return;
    }

    const inner_r = clampedRadius(inner, @max(cr - thickness, 0.0));
    const y_start: i32 = @intFromFloat(@floor(r.y));
    const y_end: i32 = @intFromFloat(@ceil(r.y + r.h));
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const outer_inset = roundedInsetForY(r, cr, fy);
        const outer_x0 = r.x + outer_inset;
        const outer_x1 = r.x + r.w - outer_inset;
        if (fy < inner.y or fy >= inner.y + inner.h) {
            try appendQuad(mesh, allocator, .{ .x = outer_x0, .y = @floatFromInt(y), .w = @max(outer_x1 - outer_x0, 0.0), .h = 1.0 }, .{}, color);
            continue;
        }
        const inner_inset = roundedInsetForY(inner, inner_r, fy);
        const inner_x0 = inner.x + inner_inset;
        const inner_x1 = inner.x + inner.w - inner_inset;
        if (inner_x0 > outer_x0) {
            try appendQuad(mesh, allocator, .{ .x = outer_x0, .y = @floatFromInt(y), .w = inner_x0 - outer_x0, .h = 1.0 }, .{}, color);
        }
        if (outer_x1 > inner_x1) {
            try appendQuad(mesh, allocator, .{ .x = inner_x1, .y = @floatFromInt(y), .w = outer_x1 - inner_x1, .h = 1.0 }, .{}, color);
        }
    }
}

fn roundedSegmentCount(radius: f32) usize {
    if (radius >= 18.0) return 18;
    if (radius >= 10.0) return 12;
    return 8;
}

fn clippedRect(rect: draw.Rect, clip: draw.Rect) ?draw.Rect {
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
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

fn renderStyledRect(renderer: *sdl.Renderer, command: draw.Command) !void {
    const radius = clampedRadius(command.rect, command.radius);
    if (command.border_color) |border| {
        if (command.border_width > 0.0 and border.a > 0.0) {
            try renderRoundedBorder(renderer, command.rect, border, radius, command.border_width);
        }
    }
    if (command.color.a <= 0.0) return;
    const fill_rect = if (command.border_color != null and command.border_width > 0.0)
        insetRect(command.rect, command.border_width)
    else
        command.rect;
    if (fill_rect.w <= 0.0 or fill_rect.h <= 0.0) return;
    try renderRoundedFill(renderer, fill_rect, command.color, @max(radius - command.border_width, 0.0));
}

fn renderRoundedFill(renderer: *sdl.Renderer, rect: draw.Rect, color: draw.Color, radius: f32) !void {
    const bytes = colorBytes(color);
    if (bytes[3] == 0 or rect.w <= 0.0 or rect.h <= 0.0) return;
    try sdl.setRenderDrawColor(renderer, bytes[0], bytes[1], bytes[2], bytes[3]);
    const r = clampedRadius(rect, radius);
    if (r <= 0.0) {
        try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h });
        return;
    }

    const y_start: i32 = @intFromFloat(@floor(rect.y));
    const y_end: i32 = @intFromFloat(@ceil(rect.y + rect.h));
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const inset = roundedInsetForY(rect, r, fy);
        try sdl.renderFillRect(renderer, .{
            .x = rect.x + inset,
            .y = @floatFromInt(y),
            .w = @max(rect.w - inset * 2.0, 0.0),
            .h = 1.0,
        });
    }
}

fn renderRoundedBorder(renderer: *sdl.Renderer, rect: draw.Rect, color: draw.Color, radius: f32, width: f32) !void {
    const bytes = colorBytes(color);
    if (bytes[3] == 0 or rect.w <= 0.0 or rect.h <= 0.0 or width <= 0.0) return;
    try sdl.setRenderDrawColor(renderer, bytes[0], bytes[1], bytes[2], bytes[3]);
    const r = clampedRadius(rect, radius);
    const inner = insetRect(rect, width);
    if (r <= 0.0 or inner.w <= 0.0 or inner.h <= 0.0) {
        try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @min(width, rect.h) });
        try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y + rect.h - @min(width, rect.h), .w = rect.w, .h = @min(width, rect.h) });
        try sdl.renderFillRect(renderer, .{ .x = rect.x, .y = rect.y, .w = @min(width, rect.w), .h = rect.h });
        try sdl.renderFillRect(renderer, .{ .x = rect.x + rect.w - @min(width, rect.w), .y = rect.y, .w = @min(width, rect.w), .h = rect.h });
        return;
    }

    const inner_r = clampedRadius(inner, @max(r - width, 0.0));
    const y_start: i32 = @intFromFloat(@floor(rect.y));
    const y_end: i32 = @intFromFloat(@ceil(rect.y + rect.h));
    var y = y_start;
    while (y < y_end) : (y += 1) {
        const fy = @as(f32, @floatFromInt(y)) + 0.5;
        const outer_inset = roundedInsetForY(rect, r, fy);
        const outer_x0 = rect.x + outer_inset;
        const outer_x1 = rect.x + rect.w - outer_inset;
        if (fy < inner.y or fy >= inner.y + inner.h) {
            try sdl.renderFillRect(renderer, .{ .x = outer_x0, .y = @floatFromInt(y), .w = @max(outer_x1 - outer_x0, 0.0), .h = 1.0 });
            continue;
        }
        const inner_inset = roundedInsetForY(inner, inner_r, fy);
        const inner_x0 = inner.x + inner_inset;
        const inner_x1 = inner.x + inner.w - inner_inset;
        if (inner_x0 > outer_x0) {
            try sdl.renderFillRect(renderer, .{ .x = outer_x0, .y = @floatFromInt(y), .w = inner_x0 - outer_x0, .h = 1.0 });
        }
        if (outer_x1 > inner_x1) {
            try sdl.renderFillRect(renderer, .{ .x = inner_x1, .y = @floatFromInt(y), .w = outer_x1 - inner_x1, .h = 1.0 });
        }
    }
}

fn roundedInsetForY(rect: draw.Rect, radius: f32, y: f32) f32 {
    const r = clampedRadius(rect, radius);
    if (r <= 0.0) return 0.0;
    const top_center = rect.y + r;
    const bottom_center = rect.y + rect.h - r;
    const dy = if (y < top_center)
        top_center - y
    else if (y > bottom_center)
        y - bottom_center
    else
        0.0;
    if (dy <= 0.0) return 0.0;
    return @max(r - @sqrt(@max(r * r - dy * dy, 0.0)), 0.0);
}

fn clampedRadius(rect: draw.Rect, radius: f32) f32 {
    return @min(@max(radius, 0.0), @min(@max(rect.w, 0.0), @max(rect.h, 0.0)) * 0.5);
}

fn insetRect(rect: draw.Rect, inset: f32) draw.Rect {
    const amount = @max(inset, 0.0);
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .w = @max(rect.w - amount * 2.0, 0.0),
        .h = @max(rect.h - amount * 2.0, 0.0),
    };
}

fn rectToSdl(rect: draw.Rect) sdl.Rect {
    return .{
        .x = @intFromFloat(@floor(rect.x)),
        .y = @intFromFloat(@floor(rect.y)),
        .w = @intFromFloat(@ceil(rect.w)),
        .h = @intFromFloat(@ceil(rect.h)),
    };
}

fn toSdlRect(rect: draw.Rect, target_height: f32) c.SDL_Rect {
    _ = target_height;
    return .{
        .x = @intFromFloat(@floor(rect.x)),
        .y = @intFromFloat(@floor(rect.y)),
        .w = @intFromFloat(@ceil(rect.w)),
        .h = @intFromFloat(@ceil(rect.h)),
    };
}

fn gpuSetFullScissor(pass: *c.SDL_GPURenderPass) void {
    var full: c.SDL_Rect = .{ .x = 0, .y = 0, .w = 65535, .h = 65535 };
    c.SDL_SetGPUScissor(pass, &full);
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

fn textCacheKey(value: []const u8, font_size: f32, wrap_width: ?f32) TextCacheKey {
    const wrap_value = wrap_width orelse 0.0;
    return .{
        .text_hash = std.hash.Wyhash.hash(0, value),
        .text_len = value.len,
        .font_size_bits = @bitCast(font_size),
        .wrap_width_bits = @bitCast(wrap_value),
    };
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

fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(i128, @intCast(ts.nsec));
}

fn elapsedNs(start: i128) u64 {
    const end = nowNs();
    if (end <= start) return 0;
    return @intCast(end - start);
}

pub const ShaderSource = struct {
    pub const vertex_hlsl = @embedFile("shaders/ui.vert.hlsl");
    pub const fragment_hlsl = @embedFile("shaders/ui.frag.hlsl");
    pub const vertex_spirv = @embedFile("shaders/ui.vert.spv");
    pub const solid_fragment_spirv = @embedFile("shaders/ui.solid.frag.spv");
    pub const text_fragment_spirv = @embedFile("shaders/ui.text.frag.spv");
    pub const image_fragment_spirv = @embedFile("shaders/ui.image.frag.spv");
    pub const vertex_msl = @embedFile("shaders/ui.vert.msl");
    pub const solid_fragment_msl = @embedFile("shaders/ui.solid.frag.msl");
    pub const text_fragment_msl = @embedFile("shaders/ui.text.frag.msl");
    pub const image_fragment_msl = @embedFile("shaders/ui.image.frag.msl");

    pub fn vulkanPackages() PipelineShaderPackages {
        return .{
            .solid = .{
                .vertex = .{ .format = ShaderFormat.spirv, .code = vertex_spirv },
                .fragment = .{ .format = ShaderFormat.spirv, .code = solid_fragment_spirv },
            },
            .text = .{
                .vertex = .{ .format = ShaderFormat.spirv, .code = vertex_spirv },
                .fragment = .{ .format = ShaderFormat.spirv, .code = text_fragment_spirv },
            },
            .image = .{
                .vertex = .{ .format = ShaderFormat.spirv, .code = vertex_spirv },
                .fragment = .{ .format = ShaderFormat.spirv, .code = image_fragment_spirv },
            },
        };
    }

    pub fn metalPackages() PipelineShaderPackages {
        return .{
            .solid = .{
                .vertex = .{ .format = ShaderFormat.msl, .code = vertex_msl },
                .fragment = .{ .format = ShaderFormat.msl, .code = solid_fragment_msl },
            },
            .text = .{
                .vertex = .{ .format = ShaderFormat.msl, .code = vertex_msl },
                .fragment = .{ .format = ShaderFormat.msl, .code = text_fragment_msl },
            },
            .image = .{
                .vertex = .{ .format = ShaderFormat.msl, .code = vertex_msl },
                .fragment = .{ .format = ShaderFormat.msl, .code = image_fragment_msl },
            },
        };
    }

    pub fn packagesForTarget(os_tag: std.Target.Os.Tag) PipelineShaderPackages {
        return switch (os_tag) {
            .macos, .ios, .tvos, .watchos => metalPackages(),
            else => vulkanPackages(),
        };
    }
};

test "renderer builds indexed quads from commands" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .x = 1, .y = 2, .w = 3, .h = 4 }, draw.Color.white);
    try batch.cursor(std.testing.allocator, .{ .x = 5, .y = 6, .w = 7, .h = 8 }, draw.Color.white);

    var mesh: Mesh = .{};
    defer mesh.deinit(std.testing.allocator);
    try buildMesh(std.testing.allocator, &batch, &mesh, null);

    try std.testing.expectEqual(@as(usize, 8), mesh.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.indices.items.len);
    try std.testing.expectEqual(@as(f32, 4), mesh.vertices.items[2].pos.x);
}

test "gpu renderer renderBatch consumes command kinds" {
    var batch: draw.RenderBatch = .{};
    defer batch.deinit(std.testing.allocator);
    try batch.rect(std.testing.allocator, .{ .w = 1, .h = 1 }, draw.Color.white);
    try batch.text(std.testing.allocator, .{ .w = 20, .h = 20 }, "hello", draw.Color.white, 16, null);
    try batch.image(std.testing.allocator, .{ .w = 16, .h = 16 }, draw.TextureId.init(2), .{ .w = 1, .h = 1 }, draw.Color.white, null);
    try batch.cursor(std.testing.allocator, .{ .w = 1, .h = 20 }, draw.Color.white);
    try batch.selection(std.testing.allocator, .{ .w = 10, .h = 20 }, draw.Color.white);
    try batch.scrollbar(std.testing.allocator, .{ .w = 4, .h = 20 }, draw.Color.white);

    var renderer: Renderer = .{};
    renderer.renderBatch(undefined, &batch);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.rects);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.text);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.images);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.cursors);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.selections);
    try std.testing.expectEqual(@as(usize, 1), renderer.command_counts.scrollbars);
    try std.testing.expectEqual(@as(usize, 1), renderer.unsupported_text_commands);
    try std.testing.expectEqual(@as(usize, 1), renderer.unsupported_image_commands);
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

test "embedded Vulkan and Metal shader packages validate" {
    const vulkan = ShaderSource.vulkanPackages();
    try vulkan.solid.validate(ShaderFormat.vulkan);
    try vulkan.text.validate(ShaderFormat.vulkan);
    try std.testing.expect(ShaderSource.vertex_spirv.len > 4);
    try std.testing.expect(ShaderSource.text_fragment_spirv.len > 4);

    const metal = ShaderSource.metalPackages();
    try metal.solid.validate(ShaderFormat.metal);
    try metal.text.validate(ShaderFormat.metal);
    try std.testing.expect(std.mem.indexOf(u8, ShaderSource.vertex_msl, "vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, ShaderSource.text_fragment_msl, "texture2d") != null);
}
