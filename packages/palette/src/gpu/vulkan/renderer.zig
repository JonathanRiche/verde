//! Palette's Vulkan renderer: `draw.RenderBatch` -> one instanced pipeline.
//!
//! The backend-neutral part (batch -> 64-byte `core.Instance`s, texture runs, glyph layout +
//! atlas packing, damage diffing, the full/partial/skip plan, stream-region merging) lives in
//! `../core.zig` and is shared with the Metal and D3D11 backends. This file owns the Vulkan
//! objects and records/submits.
//!
//! Every command becomes 64-byte instances in a persistently mapped per-frame ring; one
//! `vkCmdDraw(4, n)` covers runs of instances and draws only split when an image instance
//! needs a different texture. Clipping is geometric in the vertex shader, so interleaving
//! rects, text and images in z-order costs nothing. Output is premultiplied.
//!
//! Visual parity with the old SDL_GPU renderer (palette/src/renderer.zig):
//! - rects: SDF rounded box with 0.75 px AA and a 1 px halo; stroked rects snap each edge to
//!   the pixel grid and use whole-pixel strokes (`snapRectToPixelGrid`, `strokePixelWidth`);
//!   fill-only rects keep sub-pixel geometry; `radius <= 0.5` and no border = plain quad
//! - the old border composite (straight colours mixed by border alpha) by default
//! - images: texture * tint, straight-alpha textures, trilinear + mips, clamp to edge
//! - text/image clips follow the old scissor rule (floor x/y, ceil w/h)

const std = @import("std");
const draw = @import("../../draw.zig");
const vk = @import("vk.zig");
const context = @import("context.zig");
const core = @import("../core.zig");
const text = @import("../text.zig");
const damage = @import("../damage.zig");
const clock = @import("../../clock.zig");
const present = @import("../../platform/present.zig");
const import_ = @import("import.zig");

const Context = context.Context;

pub const Instance = core.Instance;
pub const Kind = core.Kind;

/// The only colour attachment format: maps 1:1 to DRM ARGB8888/XRGB8888.
pub const target_format: vk.Format = .b8g8r8a8_unorm;

const vert_spv align(4) = @embedFile("../../shaders/ui.vert.spv").*;
const frag_spv align(4) = @embedFile("../../shaders/ui.frag.spv").*;

pub const Options = core.Options;
pub const TextureFormat = core.TextureFormat;
pub const FrameStats = core.FrameStats;
pub const FrameOptions = core.FrameOptions;
pub const FrameResult = core.FrameResult;

/// A colour attachment the renderer can draw into. Owned by targets.zig wrappers.
pub const Target = struct {
    image: vk.Image = .null_handle,
    view: vk.ImageView = .null_handle,
    framebuffer: vk.Framebuffer = .null_handle,
    width: u32 = 0,
    height: u32 = 0,
    /// Layout the image is left in after each frame.
    final_layout: vk.ImageLayout = .color_attachment_optimal,
    /// Current layout (undefined until first rendered).
    layout: vk.ImageLayout = .undefined,
    /// Shared with a foreign queue (compositor): release after rendering, acquire before.
    foreign: bool = false,
    foreign_family: u32 = vk.queue_family_foreign_ext,
    /// Damage-history frame index of the last render into this target (0 = never/undefined).
    last_frame: u64 = 0,
    last_serial: u64 = 0,
    /// Optional semaphores for this submission (set by the owner per frame).
    wait_semaphore: vk.Semaphore = .null_handle,
    signal_semaphore: vk.Semaphore = .null_handle,

    /// Marks contents as undefined (e.g. the compositor may have scribbled on it).
    pub fn invalidate(self: *Target) void {
        self.last_frame = 0;
    }
};

const Texture = struct {
    image: vk.Image,
    view: vk.ImageView,
    allocation: context.Allocation,
    width: u32,
    height: u32,
    format: vk.Format,
    mip_levels: u32,
    set: vk.DescriptorSet,
    pool: vk.DescriptorPool,
    generation: u32,
    /// Has valid contents (an upload was recorded).
    ready: bool = false,
    /// Persistent staging ring for `streamTexture` (null for one-shot uploads).
    stream: ?*Stream = null,
    /// Set when the id is bound to an imported dma-buf; the image/view/set belong to it.
    external: ?*Import = null,
    /// Imported frames with producer damage: what changed since the encoder last drew the
    /// image (texels; 0 rects = the whole image), `damage_base` = generation of the last
    /// whole-image change. `damage_seen`: a frame was built since the last import, so the
    /// next import starts a new set instead of accumulating.
    damage_n: u8 = 0,
    damage_seen: bool = false,
    damage_base: u32 = 0,
    damage: [core.max_texture_damage]TextureRect = undefined,
};

/// Staging buffers a streamed texture reuses frame after frame. A slot is writable once the
/// submission that last copied from it completed (`serial <= completed_serial`) and no
/// unrecorded upload references it.
const Stream = struct {
    slots: [max_stream_slots]Slot = @splat(.{}),
    count: u8 = 0,

    const Slot = struct {
        buffer: Context.Buffer = .{},
        serial: u64 = 0,
        pending: bool = false,
    };
};

/// An imported dma-buf (one producer buffer), cached until the producer drops it.
const Import = struct {
    key: u64,
    image: vk.Image = .null_handle,
    view: vk.ImageView = .null_handle,
    memory: vk.DeviceMemory = .null_handle,
    set: vk.DescriptorSet = .null_handle,
    pool: vk.DescriptorPool = .null_handle,
    width: u32,
    height: u32,
    fourcc: present.Fourcc,
    modifier: u64,
    /// dup of plane 0 (implicit-sync ioctls).
    fd: c_int = -1,
    /// Temporary-import wait semaphore for the producer's fence.
    wait_semaphore: vk.Semaphore = .null_handle,
    /// Producer fence of the newest frame, not yet waited on by a submission.
    pending_fence: c_int = -1,
    /// Last submission that sampled the buffer and its exported completion sync_file.
    last_serial: u64 = 0,
    release_fence: c_int = -1,
    generation: u32 = 0,
    /// Scratch: referenced by the frame being recorded.
    in_frame: bool = false,
};

pub const DmabufImportOptions = struct {
    /// Producer buffer id, stable for the buffer's lifetime. 0 = derive the key from the
    /// dma-buf inode (st_dev, st_ino) of plane 0.
    key: u64 = 0,
    /// sync_file that signals when the producer finished writing this frame. Ownership moves
    /// to the renderer (also on error). -1 = take the dma-buf's implicit write fences
    /// (DMA_BUF_IOCTL_EXPORT_SYNC_FILE), or none when the kernel lacks that ioctl.
    acquire_fence: c_int = -1,
    /// The buffer holds a new frame: bumps the texture generation, so the image's rects are
    /// damaged. False only (re)binds the id (no repaint unless the binding changed).
    new_frame: bool = true,
    /// Texels that differ from the frame the id showed before (producer damage, e.g. WPE's
    /// damage rects); empty = everything. Only these parts of the image's rects are
    /// repainted. Ignored (whole image) after a size change or with more than
    /// `core.max_texture_damage` rects.
    damage: []const TextureRect = &.{},
};

const max_stream_slots = core.max_stream_slots;
pub const max_stream_regions = core.max_stream_regions;
pub const TextureRect = core.TextureRect;
pub const StreamOptions = core.StreamOptions;

const PendingUpload = struct {
    id: u32,
    staging: Context.Buffer,
    /// Index into the texture's stream ring (staging is not retired after recording).
    slot: ?u8 = null,
    /// Copy regions in `staging` (packed, tightly). 0 = one full-size region at offset 0.
    region_count: u8 = 0,
    regions: [max_stream_regions]TextureRect = undefined,
};

const AtlasImage = struct {
    image: vk.Image = .null_handle,
    view: vk.ImageView = .null_handle,
    allocation: context.Allocation = .{},
    size: u32 = 0,
    format: vk.Format,
    layout: vk.ImageLayout = .undefined,
};

const Frame = struct {
    cmd: vk.CommandBuffer = .null_handle,
    fence: vk.Fence = .null_handle,
    serial: u64 = 0,
    instances: Context.Buffer = .{},
    staging: Context.Buffer = .{},
    set0: vk.DescriptorSet = .null_handle,
    set0_generation: u64 = 0,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    ctx: *Context,
    options: Options,

    render_pass_clear: vk.RenderPass = .null_handle,
    render_pass_load: vk.RenderPass = .null_handle,
    set0_layout: vk.DescriptorSetLayout = .null_handle,
    set1_layout: vk.DescriptorSetLayout = .null_handle,
    pipeline_layout: vk.PipelineLayout = .null_handle,
    pipeline: vk.Pipeline = .null_handle,
    sampler_nearest: vk.Sampler = .null_handle,
    sampler_linear: vk.Sampler = .null_handle,
    command_pool: vk.CommandPool = .null_handle,
    set0_pool: vk.DescriptorPool = .null_handle,
    image_pools: std.ArrayList(vk.DescriptorPool) = .empty,

    frames: [3]Frame = @splat(.{}),
    frame_count: u8 = 2,
    frame_cursor: u64 = 0,

    atlases: [2]AtlasImage = .{ .{ .format = .r8_unorm }, .{ .format = .r8g8b8a8_unorm } },
    atlas_generation: u64 = 1,

    textures: std.AutoHashMapUnmanaged(u32, Texture) = .empty,
    pending_uploads: std.ArrayList(PendingUpload) = .empty,
    dummy_texture: Texture = undefined,
    texture_generation: u32 = 0,

    /// Imported dma-bufs by key, plus dropped ones waiting for their last submission.
    imports: std.AutoHashMapUnmanaged(u64, *Import) = .empty,
    dead_imports: std.ArrayList(*Import) = .empty,
    frame_imports: std.ArrayList(*Import) = .empty,
    /// Exportable SYNC_FD semaphore signalled by submissions that sample imports.
    import_signal: vk.Semaphore = .null_handle,

    /// Backend-neutral batch encoder: instances, runs, glyph cache, damage.
    enc: core.Encoder,
    last_stats: FrameStats = .{},

    pub fn init(gpa: std.mem.Allocator, ctx: *Context, options: Options) !*Renderer {
        const self = try gpa.create(Renderer);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ctx = ctx,
            .options = options,
            .frame_count = std.math.clamp(options.frames_in_flight, 2, 3),
            .enc = .init(gpa, options),
        };
        errdefer self.deinit();
        try self.createPipeline();
        try self.createFrames();
        try self.createAtlas(.coverage, self.enc.glyph_cache.atlasSize(.coverage));
        try self.createAtlas(.color, self.enc.glyph_cache.atlasSize(.color));
        self.dummy_texture = try self.createTexture(1, 1, .r8g8b8a8_unorm, false);
        {
            const staging = try ctx.createBuffer(4, vk.BufferUsageFlags.transfer_src, vk.MemoryPropertyFlags.host_visible | vk.MemoryPropertyFlags.host_coherent, 0);
            @memset(staging.bytes()[0..4], 255);
            try self.pending_uploads.append(gpa, .{ .id = 0, .staging = staging });
        }
        if (options.glyph_source) |source| self.setGlyphSource(source);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const ctx = self.ctx;
        const vkd = &ctx.vkd;
        const dev = ctx.device;
        _ = vkd.vkDeviceWaitIdle(dev);
        ctx.markCompleted(ctx.submit_serial);
        for (self.pending_uploads.items) |p| if (p.slot == null) ctx.destroyBuffer(p.staging);
        self.pending_uploads.deinit(self.gpa);
        var it = self.textures.valueIterator();
        while (it.next()) |t| self.destroyTextureNow(t.*);
        self.textures.deinit(self.gpa);
        var imp_it = self.imports.valueIterator();
        while (imp_it.next()) |imp| self.destroyImportNow(imp.*);
        self.imports.deinit(self.gpa);
        for (self.dead_imports.items) |imp| self.destroyImportNow(imp);
        self.dead_imports.deinit(self.gpa);
        self.frame_imports.deinit(self.gpa);
        if (self.import_signal != .null_handle) vkd.vkDestroySemaphore(dev, self.import_signal, null);
        if (self.dummy_texture.image != .null_handle) self.destroyTextureNow(self.dummy_texture);
        for (&self.atlases) |*a| {
            if (a.view != .null_handle) vkd.vkDestroyImageView(dev, a.view, null);
            if (a.image != .null_handle) vkd.vkDestroyImage(dev, a.image, null);
            ctx.free(a.allocation);
        }
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.fence != .null_handle) vkd.vkDestroyFence(dev, f.fence, null);
            ctx.destroyBuffer(f.instances);
            ctx.destroyBuffer(f.staging);
        }
        for (self.image_pools.items) |p| vkd.vkDestroyDescriptorPool(dev, p, null);
        self.image_pools.deinit(self.gpa);
        if (self.set0_pool != .null_handle) vkd.vkDestroyDescriptorPool(dev, self.set0_pool, null);
        if (self.command_pool != .null_handle) vkd.vkDestroyCommandPool(dev, self.command_pool, null);
        if (self.pipeline != .null_handle) vkd.vkDestroyPipeline(dev, self.pipeline, null);
        if (self.pipeline_layout != .null_handle) vkd.vkDestroyPipelineLayout(dev, self.pipeline_layout, null);
        if (self.set0_layout != .null_handle) vkd.vkDestroyDescriptorSetLayout(dev, self.set0_layout, null);
        if (self.set1_layout != .null_handle) vkd.vkDestroyDescriptorSetLayout(dev, self.set1_layout, null);
        if (self.sampler_nearest != .null_handle) vkd.vkDestroySampler(dev, self.sampler_nearest, null);
        if (self.sampler_linear != .null_handle) vkd.vkDestroySampler(dev, self.sampler_linear, null);
        if (self.render_pass_clear != .null_handle) vkd.vkDestroyRenderPass(dev, self.render_pass_clear, null);
        if (self.render_pass_load != .null_handle) vkd.vkDestroyRenderPass(dev, self.render_pass_load, null);
        self.enc.deinit();
        self.gpa.destroy(self);
    }

    pub fn setGlyphSource(self: *Renderer, source: text.GlyphSource) void {
        self.enc.setGlyphSource(source);
    }

    /// Render pass compatible with every target (for framebuffer creation).
    pub fn renderPass(self: *const Renderer) vk.RenderPass {
        return self.render_pass_clear;
    }

    pub fn lastFrameStats(self: *const Renderer) FrameStats {
        return self.last_stats;
    }

    // ---- Setup ----------------------------------------------------------------------------

    fn createRenderPass(self: *Renderer, load: vk.AttachmentLoadOp) !vk.RenderPass {
        const attachment: vk.AttachmentDescription = .{
            .format = target_format,
            .samples = vk.SampleCountFlags.@"1",
            .loadOp = load,
            .storeOp = .store,
            .stencilLoadOp = .dont_care,
            .stencilStoreOp = .dont_care,
            .initialLayout = .color_attachment_optimal,
            .finalLayout = .color_attachment_optimal,
        };
        const color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
        const subpass: vk.SubpassDescription = .{
            .pipelineBindPoint = .graphics,
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&color_ref),
        };
        const info: vk.RenderPassCreateInfo = .{
            .attachmentCount = 1,
            .pAttachments = @ptrCast(&attachment),
            .subpassCount = 1,
            .pSubpasses = @ptrCast(&subpass),
        };
        var pass: vk.RenderPass = .null_handle;
        try vk.check(self.ctx.vkd.vkCreateRenderPass(self.ctx.device, &info, null, &pass));
        return pass;
    }

    fn createPipeline(self: *Renderer) !void {
        const ctx = self.ctx;
        const vkd = &ctx.vkd;
        const dev = ctx.device;
        self.render_pass_clear = try self.createRenderPass(.clear);
        self.render_pass_load = try self.createRenderPass(.load);

        // Samplers.
        {
            const nearest: vk.SamplerCreateInfo = .{
                .magFilter = .nearest,
                .minFilter = .nearest,
                .mipmapMode = .nearest,
                .addressModeU = .clamp_to_edge,
                .addressModeV = .clamp_to_edge,
                .addressModeW = .clamp_to_edge,
            };
            try vk.check(vkd.vkCreateSampler(dev, &nearest, null, &self.sampler_nearest));
            const aniso = ctx.caps.sampler_anisotropy;
            const linear: vk.SamplerCreateInfo = .{
                .magFilter = .linear,
                .minFilter = .linear,
                .mipmapMode = .linear,
                .addressModeU = .clamp_to_edge,
                .addressModeV = .clamp_to_edge,
                .addressModeW = .clamp_to_edge,
                .anisotropyEnable = @intFromBool(aniso),
                .maxAnisotropy = if (aniso) @min(8.0, ctx.caps.max_anisotropy) else 1.0,
                .maxLod = 1000.0,
            };
            try vk.check(vkd.vkCreateSampler(dev, &linear, null, &self.sampler_linear));
        }

        // Descriptor set layouts.
        {
            const b0 = [_]vk.DescriptorSetLayoutBinding{
                .{ .binding = 0, .descriptorType = .combined_image_sampler, .descriptorCount = 1, .stageFlags = vk.ShaderStageFlags.fragment },
                .{ .binding = 1, .descriptorType = .combined_image_sampler, .descriptorCount = 1, .stageFlags = vk.ShaderStageFlags.fragment },
            };
            const info0: vk.DescriptorSetLayoutCreateInfo = .{ .bindingCount = b0.len, .pBindings = &b0 };
            try vk.check(vkd.vkCreateDescriptorSetLayout(dev, &info0, null, &self.set0_layout));
            const b1 = [_]vk.DescriptorSetLayoutBinding{
                .{ .binding = 0, .descriptorType = .combined_image_sampler, .descriptorCount = 1, .stageFlags = vk.ShaderStageFlags.fragment },
            };
            const info1: vk.DescriptorSetLayoutCreateInfo = .{ .bindingCount = b1.len, .pBindings = &b1 };
            try vk.check(vkd.vkCreateDescriptorSetLayout(dev, &info1, null, &self.set1_layout));
        }
        {
            const layouts = [_]vk.DescriptorSetLayout{ self.set0_layout, self.set1_layout };
            const push: vk.PushConstantRange = .{ .stageFlags = vk.ShaderStageFlags.vertex | vk.ShaderStageFlags.fragment, .offset = 0, .size = 16 };
            const info: vk.PipelineLayoutCreateInfo = .{
                .setLayoutCount = layouts.len,
                .pSetLayouts = &layouts,
                .pushConstantRangeCount = 1,
                .pPushConstantRanges = @ptrCast(&push),
            };
            try vk.check(vkd.vkCreatePipelineLayout(dev, &info, null, &self.pipeline_layout));
        }

        var vert: vk.ShaderModule = .null_handle;
        var frag: vk.ShaderModule = .null_handle;
        const vinfo: vk.ShaderModuleCreateInfo = .{ .codeSize = vert_spv.len, .pCode = @ptrCast(&vert_spv) };
        try vk.check(vkd.vkCreateShaderModule(dev, &vinfo, null, &vert));
        defer vkd.vkDestroyShaderModule(dev, vert, null);
        const finfo: vk.ShaderModuleCreateInfo = .{ .codeSize = frag_spv.len, .pCode = @ptrCast(&frag_spv) };
        try vk.check(vkd.vkCreateShaderModule(dev, &finfo, null, &frag));
        defer vkd.vkDestroyShaderModule(dev, frag, null);

        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = vk.ShaderStageFlags.vertex, .module = vert, .pName = "main" },
            .{ .stage = vk.ShaderStageFlags.fragment, .module = frag, .pName = "main" },
        };
        const binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(Instance), .inputRate = .instance };
        const attrs = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = 16 },
            .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = 32 },
            .{ .location = 3, .binding = 0, .format = .r32g32b32a32_uint, .offset = 48 },
        };
        const vertex_input: vk.PipelineVertexInputStateCreateInfo = .{
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = @ptrCast(&binding),
            .vertexAttributeDescriptionCount = attrs.len,
            .pVertexAttributeDescriptions = &attrs,
        };
        const input_assembly: vk.PipelineInputAssemblyStateCreateInfo = .{ .topology = .triangle_strip };
        const viewport_state: vk.PipelineViewportStateCreateInfo = .{ .viewportCount = 1, .scissorCount = 1 };
        const raster: vk.PipelineRasterizationStateCreateInfo = .{
            .polygonMode = .fill,
            .cullMode = vk.CullModeFlags.none,
            .frontFace = .counter_clockwise,
            .lineWidth = 1.0,
        };
        const multisample: vk.PipelineMultisampleStateCreateInfo = .{ .rasterizationSamples = vk.SampleCountFlags.@"1" };
        const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blendEnable = vk.true_,
            .srcColorBlendFactor = .one,
            .dstColorBlendFactor = .one_minus_src_alpha,
            .colorBlendOp = .add,
            .srcAlphaBlendFactor = .one,
            .dstAlphaBlendFactor = .one_minus_src_alpha,
            .alphaBlendOp = .add,
            .colorWriteMask = vk.ColorComponentFlags.rgba,
        };
        const blend: vk.PipelineColorBlendStateCreateInfo = .{ .attachmentCount = 1, .pAttachments = @ptrCast(&blend_attachment), .blendConstants = .{ 0, 0, 0, 0 } };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic: vk.PipelineDynamicStateCreateInfo = .{ .dynamicStateCount = dynamic_states.len, .pDynamicStates = &dynamic_states };
        const info: vk.GraphicsPipelineCreateInfo = .{
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = @ptrCast(&vertex_input),
            .pInputAssemblyState = @ptrCast(&input_assembly),
            .pViewportState = @ptrCast(&viewport_state),
            .pRasterizationState = @ptrCast(&raster),
            .pMultisampleState = @ptrCast(&multisample),
            .pColorBlendState = @ptrCast(&blend),
            .pDynamicState = @ptrCast(&dynamic),
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass_clear,
            .basePipelineHandle = .null_handle,
            .basePipelineIndex = -1,
        };
        try vk.check(vkd.vkCreateGraphicsPipelines(dev, .null_handle, 1, @ptrCast(&info), null, @ptrCast(&self.pipeline)));
    }

    fn createFrames(self: *Renderer) !void {
        const ctx = self.ctx;
        const vkd = &ctx.vkd;
        const dev = ctx.device;
        const pool_info: vk.CommandPoolCreateInfo = .{
            .flags = vk.CommandPoolCreateFlags.reset_command_buffer,
            .queueFamilyIndex = ctx.queue_family,
        };
        try vk.check(vkd.vkCreateCommandPool(dev, &pool_info, null, &self.command_pool));
        var cmds: [3]vk.CommandBuffer = undefined;
        const alloc_info: vk.CommandBufferAllocateInfo = .{
            .commandPool = self.command_pool,
            .level = .primary,
            .commandBufferCount = self.frame_count,
        };
        try vk.check(vkd.vkAllocateCommandBuffers(dev, &alloc_info, &cmds));

        const sizes = [_]vk.DescriptorPoolSize{.{ .type = .combined_image_sampler, .descriptorCount = 2 * 3 }};
        const set0_pool_info: vk.DescriptorPoolCreateInfo = .{ .maxSets = 3, .poolSizeCount = 1, .pPoolSizes = &sizes };
        try vk.check(vkd.vkCreateDescriptorPool(dev, &set0_pool_info, null, &self.set0_pool));
        var layouts: [3]vk.DescriptorSetLayout = @splat(self.set0_layout);
        var sets: [3]vk.DescriptorSet = undefined;
        const set_info: vk.DescriptorSetAllocateInfo = .{
            .descriptorPool = self.set0_pool,
            .descriptorSetCount = self.frame_count,
            .pSetLayouts = &layouts,
        };
        try vk.check(vkd.vkAllocateDescriptorSets(dev, &set_info, &sets));

        for (self.frames[0..self.frame_count], 0..) |*f, i| {
            f.cmd = cmds[i];
            f.set0 = sets[i];
            const fence_info: vk.FenceCreateInfo = .{};
            try vk.check(vkd.vkCreateFence(dev, &fence_info, null, &f.fence));
        }
    }

    fn createImage(self: *Renderer, width: u32, height: u32, format: vk.Format, mip_levels: u32, usage: vk.Flags) !struct { image: vk.Image, view: vk.ImageView, allocation: context.Allocation } {
        const ctx = self.ctx;
        const vkd = &ctx.vkd;
        const info: vk.ImageCreateInfo = .{
            .imageType = .@"2d",
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = mip_levels,
            .arrayLayers = 1,
            .samples = vk.SampleCountFlags.@"1",
            .tiling = .optimal,
            .usage = usage,
            .sharingMode = .exclusive,
            .initialLayout = .undefined,
        };
        var image: vk.Image = .null_handle;
        try vk.check(vkd.vkCreateImage(ctx.device, &info, null, &image));
        errdefer vkd.vkDestroyImage(ctx.device, image, null);
        var reqs: vk.MemoryRequirements = undefined;
        vkd.vkGetImageMemoryRequirements(ctx.device, image, &reqs);
        const allocation = try ctx.allocate(reqs, vk.MemoryPropertyFlags.device_local, 0, null);
        errdefer ctx.free(allocation);
        try vk.check(vkd.vkBindImageMemory(ctx.device, image, allocation.memory, 0));
        const view_info: vk.ImageViewCreateInfo = .{
            .image = image,
            .viewType = .@"2d",
            .format = format,
            .components = .{},
            .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = mip_levels, .layerCount = 1 },
        };
        var view: vk.ImageView = .null_handle;
        try vk.check(vkd.vkCreateImageView(ctx.device, &view_info, null, &view));
        return .{ .image = image, .view = view, .allocation = allocation };
    }

    /// Creates or grows a glyph atlas image. Growth copies the old contents (texel
    /// coordinates stay valid) inside the next frame's command buffer.
    fn createAtlas(self: *Renderer, kind: text.AtlasKind, size: u32) !void {
        const a = &self.atlases[@intFromEnum(kind)];
        const created = try self.createImage(size, size, a.format, 1, vk.ImageUsageFlags.sampled | vk.ImageUsageFlags.transfer_dst | vk.ImageUsageFlags.transfer_src);
        a.* = .{ .image = created.image, .view = created.view, .allocation = created.allocation, .size = size, .format = a.format };
        self.atlas_generation += 1;
    }

    fn allocImageSet(self: *Renderer) !struct { set: vk.DescriptorSet, pool: vk.DescriptorPool } {
        const vkd = &self.ctx.vkd;
        const dev = self.ctx.device;
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            if (self.image_pools.items.len > 0) {
                const pool = self.image_pools.items[self.image_pools.items.len - 1];
                const info: vk.DescriptorSetAllocateInfo = .{ .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = @ptrCast(&self.set1_layout) };
                var set: vk.DescriptorSet = .null_handle;
                const r = vkd.vkAllocateDescriptorSets(dev, &info, @ptrCast(&set));
                if (r == .success) return .{ .set = set, .pool = pool };
                if (r != .error_out_of_pool_memory and r != .error_fragmented_pool) try vk.check(r);
            }
            const sizes = [_]vk.DescriptorPoolSize{.{ .type = .combined_image_sampler, .descriptorCount = 64 }};
            const pool_info: vk.DescriptorPoolCreateInfo = .{
                .flags = vk.DescriptorPoolCreateFlags.free_descriptor_set,
                .maxSets = 64,
                .poolSizeCount = 1,
                .pPoolSizes = &sizes,
            };
            var pool: vk.DescriptorPool = .null_handle;
            try vk.check(vkd.vkCreateDescriptorPool(dev, &pool_info, null, &pool));
            try self.image_pools.append(self.gpa, pool);
        }
        return error.VulkanOutOfPoolMemory;
    }

    fn createTexture(self: *Renderer, width: u32, height: u32, format: vk.Format, mips: bool) !Texture {
        const can_blit = switch (format) {
            .r8g8b8a8_unorm => self.ctx.caps.blit_rgba8,
            .b8g8r8a8_unorm => self.ctx.caps.blit_bgra8,
            else => false,
        };
        const levels: u32 = if (mips and can_blit) std.math.log2_int(u32, @max(width, height)) + 1 else 1;
        var usage = vk.ImageUsageFlags.sampled | vk.ImageUsageFlags.transfer_dst;
        if (levels > 1) usage |= vk.ImageUsageFlags.transfer_src;
        const created = try self.createImage(width, height, format, levels, usage);
        const set = try self.allocImageSet();
        const image_info: vk.DescriptorImageInfo = .{ .sampler = self.sampler_linear, .imageView = created.view, .imageLayout = .shader_read_only_optimal };
        const write: vk.WriteDescriptorSet = .{
            .dstSet = set.set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = .combined_image_sampler,
            .pImageInfo = @ptrCast(&image_info),
        };
        self.ctx.vkd.vkUpdateDescriptorSets(self.ctx.device, 1, @ptrCast(&write), 0, null);
        self.texture_generation +%= 1;
        return .{
            .image = created.image,
            .view = created.view,
            .allocation = created.allocation,
            .width = width,
            .height = height,
            .format = format,
            .mip_levels = levels,
            .set = set.set,
            .pool = set.pool,
            .generation = self.texture_generation,
        };
    }

    fn destroyTextureNow(self: *Renderer, t: Texture) void {
        if (t.external != null) return;
        if (t.stream) |st| {
            for (st.slots[0..st.count]) |sl| self.ctx.destroyBuffer(sl.buffer);
            self.gpa.destroy(st);
        }
        const vkd = &self.ctx.vkd;
        vkd.vkDestroyImageView(self.ctx.device, t.view, null);
        vkd.vkDestroyImage(self.ctx.device, t.image, null);
        self.ctx.free(t.allocation);
        // Descriptor sets die with their pools.
    }

    fn retireTexture(self: *Renderer, t: Texture) void {
        if (t.external != null) return;
        if (t.stream) |st| {
            for (st.slots[0..st.count]) |sl| self.ctx.retire(.{ .buffer = sl.buffer });
            self.gpa.destroy(st);
        }
        self.ctx.retire(.{ .image = .{ .image = t.image, .view = t.view, .allocation = t.allocation } });
        self.ctx.retire(.{ .descriptor_set = .{ .pool = t.pool, .set = t.set } });
    }

    // ---- Textures (images) ----------------------------------------------------------------

    /// Uploads (or replaces) image `id` (== draw.TextureId.value). Pixels are straight-alpha
    /// RGBA8/BGRA8, tightly packed; they are copied immediately, the GPU copy (plus mip chain)
    /// is recorded into the next frame.
    pub fn uploadTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8) !void {
        if (id == 0) return error.InvalidTextureId;
        if (width == 0 or height == 0 or pixels.len < @as(usize, width) * height * 4) return error.InvalidTextureSize;
        const vk_format: vk.Format = switch (format) {
            .rgba8 => .r8g8b8a8_unorm,
            .bgra8 => .b8g8r8a8_unorm,
        };
        const ctx = self.ctx;
        const size = @as(u64, width) * height * 4;
        const staging = try ctx.createBuffer(size, vk.BufferUsageFlags.transfer_src, vk.MemoryPropertyFlags.host_visible, vk.MemoryPropertyFlags.host_coherent);
        errdefer ctx.destroyBuffer(staging);
        @memcpy(staging.bytes()[0..@intCast(size)], pixels[0..@intCast(size)]);
        ctx.flush(staging.allocation, 0, size);

        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.external == null and old.width == width and old.height == height and old.format == vk_format) {
                self.texture_generation +%= 1;
                gop.value_ptr.generation = self.texture_generation;
            } else {
                gop.value_ptr.* = self.createTexture(width, height, vk_format, true) catch |err| {
                    _ = self.textures.remove(id);
                    self.retireTexture(old);
                    return err;
                };
                self.retireTexture(old);
            }
        } else {
            gop.value_ptr.* = self.createTexture(width, height, vk_format, true) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
        }
        // A newer upload supersedes a pending one.
        self.dropPendingUpload(id);
        try self.pending_uploads.append(self.gpa, .{ .id = id, .staging = staging });
    }

    /// Removes the unrecorded upload of `id`, if any. One-shot staging is retired; stream
    /// slots belong to the texture (callers retire the texture or reuse the slot).
    fn dropPendingUpload(self: *Renderer, id: u32) void {
        var i: usize = 0;
        while (i < self.pending_uploads.items.len) {
            const p = self.pending_uploads.items[i];
            if (p.id == id) {
                if (p.slot) |si| {
                    if (self.textures.get(id)) |t| if (t.stream) |st| {
                        st.slots[si].pending = false;
                    };
                } else self.ctx.retire(.{ .buffer = p.staging });
                _ = self.pending_uploads.orderedRemove(i);
            } else i += 1;
        }
    }

    /// Streams a frequently changing image (browser frames, video) into texture `id`: no
    /// mip chain, the image is kept while the size and format stay the same, and staging
    /// memory comes from a per-texture ring of persistent buffers, so steady-state updates
    /// allocate nothing. `pixels` is the whole current image (`stride` bytes per row);
    /// with `options.dirty` only those rectangles are copied (CPU and GPU). Updates issued
    /// before the next frame merge (the newest pixels win). Sampled with linear filtering
    /// like other images.
    pub fn streamTexture(self: *Renderer, id: u32, width: u32, height: u32, format: TextureFormat, pixels: []const u8, options: StreamOptions) !void {
        const stride = try core.checkStream(id, width, height, pixels, options);
        const vk_format: vk.Format = switch (format) {
            .rgba8 => .r8g8b8a8_unorm,
            .bgra8 => .b8g8r8a8_unorm,
        };
        const ctx = self.ctx;

        // 1. Texture: reuse when the size/format match and it is a streamed one.
        var fresh = false;
        const gop = try self.textures.getOrPut(self.gpa, id);
        if (gop.found_existing) {
            const old = gop.value_ptr.*;
            if (old.stream == null or old.width != width or old.height != height or old.format != vk_format) {
                self.dropPendingUpload(id);
                self.retireTexture(old);
                gop.value_ptr.* = self.createStreamTexture(width, height, vk_format) catch |err| {
                    _ = self.textures.remove(id);
                    return err;
                };
                fresh = true;
            }
        } else {
            gop.value_ptr.* = self.createStreamTexture(width, height, vk_format) catch |err| {
                _ = self.textures.remove(id);
                return err;
            };
            fresh = true;
        }
        const tex = gop.value_ptr;
        const st = tex.stream.?;

        // 2. Regions: merge with an unrecorded update of the same texture.
        var pending_index: ?usize = null;
        var pending_regions: ?[]const TextureRect = null;
        for (self.pending_uploads.items, 0..) |*p, i| if (p.id == id) {
            pending_index = i;
            pending_regions = p.regions[0..p.region_count];
        };
        const merged = core.mergeStreamRegions(width, height, fresh or !tex.ready, pending_regions, options.dirty);
        if (merged.empty() and pending_index == null) return; // nothing changed (all rects clipped away)
        const full_bytes = @as(u64, width) * height * 4;

        // 3. Staging slot: the pending one, else a completed one, else grow, else wait.
        var slot_index: u8 = undefined;
        if (pending_index) |pi| {
            slot_index = self.pending_uploads.items[pi].slot.?;
        } else {
            self.pollCompleted();
            slot_index = try self.acquireStreamSlot(st, full_bytes);
        }
        const slot = &st.slots[slot_index];
        merged.pack(slot.buffer.bytes(), pixels, stride, width, height);
        ctx.flush(slot.buffer.allocation, 0, merged.bytes);
        slot.pending = true;

        var up: PendingUpload = .{ .id = id, .staging = slot.buffer, .slot = slot_index, .region_count = @intCast(merged.count) };
        @memcpy(up.regions[0..merged.count], merged.regions[0..merged.count]);
        if (pending_index) |pi| {
            self.pending_uploads.items[pi] = up;
        } else {
            try self.pending_uploads.append(self.gpa, up);
        }
        self.texture_generation +%= 1;
        tex.generation = self.texture_generation;
    }

    fn createStreamTexture(self: *Renderer, width: u32, height: u32, format: vk.Format) !Texture {
        var t = try self.createTexture(width, height, format, false);
        errdefer self.retireTexture(t);
        t.stream = try self.gpa.create(Stream);
        t.stream.?.* = .{};
        return t;
    }

    fn acquireStreamSlot(self: *Renderer, st: *Stream, size: u64) !u8 {
        const ctx = self.ctx;
        for (st.slots[0..st.count], 0..) |*sl, i| {
            if (!sl.pending and sl.serial <= ctx.completed_serial) return @intCast(i);
        }
        if (st.count < max_stream_slots) {
            const i = st.count;
            st.slots[i] = .{ .buffer = try ctx.createBuffer(size, vk.BufferUsageFlags.transfer_src, vk.MemoryPropertyFlags.host_visible, vk.MemoryPropertyFlags.host_coherent) };
            st.count += 1;
            return i;
        }
        // Every slot is in flight: wait for the oldest submission.
        var oldest: u8 = 0;
        for (st.slots[0..st.count], 0..) |sl, i| {
            if (!sl.pending and sl.serial < st.slots[oldest].serial) oldest = @intCast(i);
        }
        try self.waitSerial(st.slots[oldest].serial);
        return oldest;
    }

    /// Advances `completed_serial` for frames whose fence already signalled (non-blocking).
    fn pollCompleted(self: *Renderer) void {
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.serial == 0 or f.serial <= self.ctx.completed_serial) continue;
            if (self.ctx.vkd.vkGetFenceStatus(self.ctx.device, f.fence) == .success) self.ctx.markCompleted(f.serial);
        }
    }

    pub fn releaseTexture(self: *Renderer, id: u32) void {
        const kv = self.textures.fetchRemove(id) orelse return;
        self.dropPendingUpload(id);
        self.retireTexture(kv.value);
    }

    // ---- Imported dma-bufs (zero-copy frames from other processes) ---------------------------

    /// Whether this device can import dma-bufs at all (VK_EXT_external_memory_dma_buf +
    /// vkGetMemoryFdPropertiesKHR). Modifier support is `ctx.caps.drm_format_modifier`.
    pub fn canImportDmabuf(self: *const Renderer) bool {
        return self.ctx.caps.dmabuf_export and self.ctx.vkd.vkGetMemoryFdPropertiesKHR != null;
    }

    /// (fourcc, modifier) pairs a producer may allocate for `importDmabufTexture`.
    pub fn appendDmabufImportFormats(self: *Renderer, gpa: std.mem.Allocator, out: *std.ArrayList(present.FormatModifier)) !void {
        if (!self.canImportDmabuf()) return;
        try import_.appendImportFormats(self.ctx, gpa, out);
    }

    /// Binds image `id` (== draw.TextureId.value) to the dma-buf `image` without copying it.
    /// The Vulkan import is cached per buffer (`options.key`, else the dma-buf inode), so a
    /// producer cycling through a small pool imports each buffer once; plane fds are dup'd,
    /// the caller keeps its own. Every submission that samples the buffer waits for the
    /// newest acquire fence and takes queue-family ownership from FOREIGN (released again at
    /// the end of the submission). Hand the buffer back to the producer with
    /// `takeDmabufReleaseFence` once `id` shows another buffer.
    pub fn importDmabufTexture(self: *Renderer, id: u32, image: present.DmabufImage, options: DmabufImportOptions) !void {
        var acquire = options.acquire_fence;
        defer if (acquire >= 0) {
            _ = import_.close(acquire);
        };
        if (id == 0) return error.InvalidTextureId;
        if (!self.canImportDmabuf()) return error.DmabufImportUnsupported;
        if (image.plane_count == 0 or image.plane_count > present.max_planes) return error.InvalidDmabuf;
        if (image.width == 0 or image.height == 0 or image.width > self.ctx.caps.max_image_dimension_2d or image.height > self.ctx.caps.max_image_dimension_2d) return error.InvalidTextureSize;
        const key = if (options.key != 0) options.key else import_.bufferKey(image.planes[0].fd);
        if (key == 0) return error.InvalidDmabuf;

        var imp: *Import = undefined;
        var created = false;
        if (self.imports.get(key)) |existing| {
            if (existing.width == image.width and existing.height == image.height and existing.fourcc == image.format and existing.modifier == image.modifier) {
                imp = existing;
            } else {
                self.releaseDmabufImport(key);
                imp = try self.createImport(key, image);
                created = true;
            }
        } else {
            imp = try self.createImport(key, image);
            created = true;
        }
        if (created) {
            errdefer self.destroyImportNow(imp);
            try self.imports.put(self.gpa, key, imp);
        }

        // Producer fence for this frame (explicit, else the implicit write fences).
        if (acquire < 0 and options.new_frame) acquire = import_.exportReadFence(imp.fd);
        if (acquire >= 0) {
            if (imp.pending_fence >= 0) _ = import_.close(imp.pending_fence);
            imp.pending_fence = acquire;
            acquire = -1;
        }

        // Bind the id.
        const gop = try self.textures.getOrPut(self.gpa, id);
        const prev: ?Texture = if (gop.found_existing) gop.value_ptr.* else null;
        const rebound = !gop.found_existing or gop.value_ptr.external != imp;
        if (gop.found_existing and gop.value_ptr.external == null) {
            self.dropPendingUpload(id);
            self.retireTexture(gop.value_ptr.*);
        }
        if (options.new_frame or rebound) {
            self.texture_generation +%= 1;
            imp.generation = self.texture_generation;
        }
        gop.value_ptr.* = .{
            .image = imp.image,
            .view = imp.view,
            .allocation = .{},
            .width = imp.width,
            .height = imp.height,
            .format = import_.mapFourcc(imp.fourcc).?.format,
            .mip_levels = 1,
            .set = imp.set,
            .pool = imp.pool,
            .generation = imp.generation,
            .ready = true,
            .external = imp,
        };
        importDamage(gop.value_ptr, prev, options);
    }

    /// Damage bookkeeping of a freshly bound import (see `Texture.damage_n`).
    fn importDamage(tex: *Texture, prev_opt: ?Texture, options: DmabufImportOptions) void {
        const prev = prev_opt orelse return; // first binding: whole image
        const same_size = prev.external != null and prev.ready and prev.width == tex.width and prev.height == tex.height;
        if (!options.new_frame) {
            if (same_size and tex.generation == prev.generation) {
                tex.damage_n = prev.damage_n;
                tex.damage_seen = prev.damage_seen;
                tex.damage_base = prev.damage_base;
                tex.damage = prev.damage;
            }
            return;
        }
        if (!same_size or options.damage.len == 0) return;
        // Damage accumulates over frames the encoder never drew.
        var n: usize = 0;
        var rects: [core.max_texture_damage]TextureRect = undefined;
        if (!prev.damage_seen) {
            if (prev.damage_n == 0) return; // an undrawn whole-image change is still pending
            n = prev.damage_n;
            rects = prev.damage;
        }
        for (options.damage) |r| {
            const c = core.clampRect(r, tex.width, tex.height) orelse continue;
            if (n == rects.len) return; // too many: whole image
            rects[n] = c;
            n += 1;
        }
        if (n == 0) return;
        tex.damage_n = @intCast(n);
        tex.damage = rects;
        tex.damage_seen = false;
        tex.damage_base = if (prev.damage_n > 0) prev.damage_base else prev.generation;
    }

    /// Returns a sync_file (owned by the caller) that signals once the GPU finished every
    /// submission that sampled buffer `key`, or -1 when nothing is pending. Without SYNC_FD
    /// export this waits on the CPU instead and returns -1. The producer may write the buffer
    /// again after the fence; the caller must not have it bound to an id that is still drawn.
    pub fn takeDmabufReleaseFence(self: *Renderer, key: u64) c_int {
        const imp = self.imports.get(key) orelse return -1;
        if (imp.release_fence >= 0) {
            const fd = imp.release_fence;
            imp.release_fence = -1;
            self.pollCompleted();
            if (imp.last_serial <= self.ctx.completed_serial) {
                _ = import_.close(fd);
                return -1;
            }
            return fd;
        }
        if (imp.last_serial > self.ctx.completed_serial) self.waitSerial(imp.last_serial) catch {};
        return -1;
    }

    /// Key `importDmabufTexture` derives for a buffer without a producer id.
    pub fn dmabufKey(fd: c_int) u64 {
        return import_.bufferKey(fd);
    }

    /// Whether buffer `key` is imported.
    pub fn hasDmabufImport(self: *const Renderer, key: u64) bool {
        return self.imports.contains(key);
    }

    /// Drops the import of buffer `key` (producer destroyed or resized it). Ids still bound
    /// to it are released; the Vulkan objects die after the last submission that sampled it.
    pub fn releaseDmabufImport(self: *Renderer, key: u64) void {
        const kv = self.imports.fetchRemove(key) orelse return;
        const imp = kv.value;
        var it = self.textures.iterator();
        var ids: [16]u32 = undefined;
        var n: usize = 0;
        while (it.next()) |e| {
            if (e.value_ptr.external == imp and n < ids.len) {
                ids[n] = e.key_ptr.*;
                n += 1;
            }
        }
        for (ids[0..n]) |tid| _ = self.textures.remove(tid);
        if (n > 0) self.texture_generation +%= 1;
        if (imp.last_serial <= self.ctx.completed_serial) {
            self.destroyImportNow(imp);
        } else {
            self.dead_imports.append(self.gpa, imp) catch {
                self.waitSerial(imp.last_serial) catch {};
                self.destroyImportNow(imp);
            };
        }
    }

    fn collectDeadImports(self: *Renderer) void {
        var i: usize = 0;
        while (i < self.dead_imports.items.len) {
            const imp = self.dead_imports.items[i];
            if (imp.last_serial <= self.ctx.completed_serial) {
                self.destroyImportNow(imp);
                _ = self.dead_imports.swapRemove(i);
            } else i += 1;
        }
    }

    fn destroyImportNow(self: *Renderer, imp: *Import) void {
        const vkd = &self.ctx.vkd;
        const dev = self.ctx.device;
        if (imp.set != .null_handle) _ = vkd.vkFreeDescriptorSets(dev, imp.pool, 1, @ptrCast(&imp.set));
        if (imp.view != .null_handle) vkd.vkDestroyImageView(dev, imp.view, null);
        if (imp.image != .null_handle) vkd.vkDestroyImage(dev, imp.image, null);
        if (imp.memory != .null_handle) vkd.vkFreeMemory(dev, imp.memory, null);
        if (imp.wait_semaphore != .null_handle) vkd.vkDestroySemaphore(dev, imp.wait_semaphore, null);
        if (imp.pending_fence >= 0) _ = import_.close(imp.pending_fence);
        if (imp.release_fence >= 0) _ = import_.close(imp.release_fence);
        if (imp.fd >= 0) _ = import_.close(imp.fd);
        self.gpa.destroy(imp);
    }

    fn createImport(self: *Renderer, key: u64, image: present.DmabufImage) !*Import {
        const ctx = self.ctx;
        const vkd = &ctx.vkd;
        const dev = ctx.device;
        const mapping = import_.mapFourcc(image.format) orelse return error.UnsupportedDmabufFormat;
        // One allocation per image: planes of a multi-plane modifier (e.g. CCS aux) must live
        // in the same dma-buf (disjoint images are not supported).
        for (image.planes[1..image.plane_count]) |p| {
            if (!import_.sameBuffer(image.planes[0].fd, p.fd)) return error.DisjointDmabufUnsupported;
        }
        const use_modifier = ctx.caps.drm_format_modifier;
        if (!use_modifier and (image.modifier != present.modifier_linear or image.plane_count != 1)) return error.DmabufModifierUnsupported;
        if (!import_.importSupported(ctx, mapping.format, image.modifier)) return error.DmabufModifierUnsupported;

        const imp = try self.gpa.create(Import);
        imp.* = .{ .key = key, .width = image.width, .height = image.height, .fourcc = image.format, .modifier = image.modifier };
        errdefer self.destroyImportNow(imp);
        imp.fd = import_.dup(image.planes[0].fd);
        if (imp.fd < 0) return error.InvalidDmabuf;

        var layouts: [present.max_planes]vk.SubresourceLayout = undefined;
        for (image.planes[0..image.plane_count], 0..) |p, i| {
            layouts[i] = .{ .offset = p.offset, .size = 0, .rowPitch = p.stride, .arrayPitch = 0, .depthPitch = 0 };
        }
        const explicit: vk.ImageDrmFormatModifierExplicitCreateInfoEXT = .{
            .drmFormatModifier = image.modifier,
            .drmFormatModifierPlaneCount = image.plane_count,
            .pPlaneLayouts = &layouts,
        };
        const ext_info: vk.ExternalMemoryImageCreateInfo = .{
            .pNext = if (use_modifier) &explicit else null,
            .handleTypes = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext,
        };
        const info: vk.ImageCreateInfo = .{
            .pNext = &ext_info,
            .imageType = .@"2d",
            .format = mapping.format,
            .extent = .{ .width = image.width, .height = image.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SampleCountFlags.@"1",
            .tiling = if (use_modifier) .drm_format_modifier_ext else .linear,
            .usage = import_.usage,
            .sharingMode = .exclusive,
            .initialLayout = .undefined,
        };
        try vk.check(vkd.vkCreateImage(dev, &info, null, &imp.image));
        if (!use_modifier) {
            // Without explicit plane layouts the LINEAR pitch must match the producer's.
            const sub: vk.ImageSubresource = .{ .aspectMask = vk.ImageAspectFlags.color };
            var layout: vk.SubresourceLayout = .{};
            vkd.vkGetImageSubresourceLayout(dev, imp.image, &sub, &layout);
            if (layout.rowPitch != image.planes[0].stride or image.planes[0].offset != 0) return error.DmabufLayoutMismatch;
        }

        // Memory: import a dup of the fd (Vulkan owns it on success).
        var fd_props: vk.MemoryFdPropertiesKHR = .{};
        const mem_fd = import_.dup(image.planes[0].fd);
        if (mem_fd < 0) return error.InvalidDmabuf;
        var mem_fd_owned = true;
        defer if (mem_fd_owned) {
            _ = import_.close(mem_fd);
        };
        try vk.check(vkd.vkGetMemoryFdPropertiesKHR.?(dev, vk.ExternalMemoryHandleTypeFlags.dma_buf_ext, mem_fd, &fd_props));
        var reqs: vk.MemoryRequirements = undefined;
        vkd.vkGetImageMemoryRequirements(dev, imp.image, &reqs);
        const bits = reqs.memoryTypeBits & fd_props.memoryTypeBits;
        const type_index = ctx.findMemoryType(bits, 0, 0) orelse return error.NoSuitableMemoryType;
        const dedicated: vk.MemoryDedicatedAllocateInfo = .{ .image = imp.image, .buffer = .null_handle };
        const import_info: vk.ImportMemoryFdInfoKHR = .{ .pNext = &dedicated, .handleType = vk.ExternalMemoryHandleTypeFlags.dma_buf_ext, .fd = mem_fd };
        const alloc_info: vk.MemoryAllocateInfo = .{ .pNext = &import_info, .allocationSize = reqs.size, .memoryTypeIndex = type_index };
        try vk.check(vkd.vkAllocateMemory(dev, &alloc_info, null, &imp.memory));
        mem_fd_owned = false;
        try vk.check(vkd.vkBindImageMemory(dev, imp.image, imp.memory, 0));

        const one: vk.ComponentSwizzle = if (mapping.alpha_one) .one else .identity;
        const view_info: vk.ImageViewCreateInfo = .{
            .image = imp.image,
            .viewType = .@"2d",
            .format = mapping.format,
            .components = .{ .a = one },
            .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = 1, .layerCount = 1 },
        };
        try vk.check(vkd.vkCreateImageView(dev, &view_info, null, &imp.view));
        const set = try self.allocImageSet();
        imp.set = set.set;
        imp.pool = set.pool;
        const image_info: vk.DescriptorImageInfo = .{ .sampler = self.sampler_linear, .imageView = imp.view, .imageLayout = .shader_read_only_optimal };
        const write: vk.WriteDescriptorSet = .{
            .dstSet = imp.set,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = .combined_image_sampler,
            .pImageInfo = @ptrCast(&image_info),
        };
        vkd.vkUpdateDescriptorSets(dev, 1, @ptrCast(&write), 0, null);
        if (ctx.caps.sync_fd_import) {
            const sem_info: vk.SemaphoreCreateInfo = .{};
            try vk.check(vkd.vkCreateSemaphore(dev, &sem_info, null, &imp.wait_semaphore));
        }
        return imp;
    }

    fn ensureImportSignal(self: *Renderer) bool {
        if (self.import_signal != .null_handle) return true;
        if (!self.ctx.caps.sync_fd_export or self.ctx.vkd.vkGetSemaphoreFdKHR == null) return false;
        const export_sem: vk.ExportSemaphoreCreateInfo = .{ .handleTypes = vk.ExternalSemaphoreHandleTypeFlags.sync_fd };
        const info: vk.SemaphoreCreateInfo = .{ .pNext = &export_sem };
        return self.ctx.vkd.vkCreateSemaphore(self.ctx.device, &info, null, &self.import_signal) == .success;
    }

    /// Collects the imports sampled by this frame's draw runs (into `frame_imports`).
    fn gatherFrameImports(self: *Renderer) !void {
        self.frame_imports.clearRetainingCapacity();
        if (self.imports.count() == 0) return;
        for (self.enc.runs.items) |d| {
            if (d.count == 0 or d.texture == 0) continue;
            const t = self.textures.getPtr(d.texture) orelse continue;
            const imp = t.external orelse continue;
            if (imp.in_frame) continue;
            imp.in_frame = true;
            try self.frame_imports.append(self.gpa, imp);
        }
        for (self.frame_imports.items) |imp| imp.in_frame = false;
    }

    fn recordImportBarriers(self: *Renderer, cmd: vk.CommandBuffer, acquire: bool) void {
        if (self.frame_imports.items.len == 0) return;
        const foreign = if (self.ctx.caps.queue_family_foreign) vk.queue_family_foreign_ext else vk.queue_family_external;
        var barriers: [16]vk.ImageMemoryBarrier = undefined;
        var n: u32 = 0;
        for (self.frame_imports.items) |imp| {
            if (n == barriers.len) break;
            // Ownership round trip per submission (as wlroots does): the producer may
            // write the buffer again as soon as our release fence signals.
            barriers[n] = .{
                .srcAccessMask = if (acquire) 0 else vk.AccessFlags.shader_read,
                .dstAccessMask = if (acquire) vk.AccessFlags.shader_read else 0,
                .oldLayout = if (acquire) .general else .shader_read_only_optimal,
                .newLayout = if (acquire) .shader_read_only_optimal else .general,
                .srcQueueFamilyIndex = if (acquire) foreign else self.ctx.queue_family,
                .dstQueueFamilyIndex = if (acquire) self.ctx.queue_family else foreign,
                .image = imp.image,
                .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = 1, .layerCount = 1 },
            };
            n += 1;
        }
        const S = vk.PipelineStageFlags;
        const src: vk.Flags = if (acquire) S.top_of_pipe else S.fragment_shader;
        const dst: vk.Flags = if (acquire) S.fragment_shader else S.bottom_of_pipe;
        self.ctx.vkd.vkCmdPipelineBarrier(cmd, src, dst, 0, 0, null, 0, null, n, &barriers);
    }

    /// After the submission: export its completion as each sampled buffer's release fence
    /// (and attach it to the dma-buf for implicit-sync producers).
    fn finishFrameImports(self: *Renderer, serial: u64, signalled: bool) void {
        if (self.frame_imports.items.len == 0) return;
        var fd: c_int = -1;
        if (signalled) {
            const get: vk.SemaphoreGetFdInfoKHR = .{ .semaphore = self.import_signal, .handleType = vk.ExternalSemaphoreHandleTypeFlags.sync_fd };
            if (self.ctx.vkd.vkGetSemaphoreFdKHR.?(self.ctx.device, &get, &fd) != .success) fd = -1;
        }
        for (self.frame_imports.items) |imp| {
            imp.last_serial = serial;
            if (imp.release_fence >= 0) _ = import_.close(imp.release_fence);
            imp.release_fence = -1;
            if (fd >= 0) {
                _ = import_.attachReadFence(imp.fd, fd);
                imp.release_fence = import_.dup(fd);
            }
        }
        if (fd >= 0) _ = import_.close(fd);
    }

    // ---- Frame ----------------------------------------------------------------------------

    /// Blocks until submission `serial` finished (e.g. before reading back or reusing a
    /// target outside the renderer).
    pub fn waitSerial(self: *Renderer, serial: u64) !void {
        if (serial == 0 or serial <= self.ctx.completed_serial) return;
        for (self.frames[0..self.frame_count]) |*f| {
            if (f.serial == serial) {
                try vk.check(self.ctx.vkd.vkWaitForFences(self.ctx.device, 1, @ptrCast(&f.fence), vk.true_, std.math.maxInt(u64)));
                self.ctx.markCompleted(serial);
                return;
            }
        }
        try vk.check(self.ctx.vkd.vkDeviceWaitIdle(self.ctx.device));
        self.ctx.markCompleted(self.ctx.submit_serial);
    }

    /// Copies the last frame rendered into `target` to `buffer` (BGRA8, tightly packed) and
    /// waits for it. A synchronous one-shot submission meant for tests, screenshots and tools;
    /// presentation paths never read back.
    pub fn readback(self: *Renderer, target: *Target, buffer: vk.Buffer) !void {
        std.debug.assert(!target.foreign and target.layout == .color_attachment_optimal);
        const vkd = &self.ctx.vkd;
        const dev = self.ctx.device;
        try self.waitSerial(target.last_serial);
        const alloc_info: vk.CommandBufferAllocateInfo = .{ .commandPool = self.command_pool, .level = .primary, .commandBufferCount = 1 };
        var cmd: vk.CommandBuffer = .null_handle;
        try vk.check(vkd.vkAllocateCommandBuffers(dev, &alloc_info, @ptrCast(&cmd)));
        defer vkd.vkFreeCommandBuffers(dev, self.command_pool, 1, @ptrCast(&cmd));
        const begin: vk.CommandBufferBeginInfo = .{ .flags = vk.CommandBufferUsageFlags.one_time_submit };
        try vk.check(vkd.vkBeginCommandBuffer(cmd, &begin));
        const A = vk.AccessFlags;
        const S = vk.PipelineStageFlags;
        barrier(cmd, vkd, target.image, .color_attachment_optimal, .transfer_src_optimal, A.color_attachment_write, A.transfer_read, S.color_attachment_output, S.transfer, 0, 1);
        const region: vk.BufferImageCopy = .{
            .imageSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .layerCount = 1 },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = target.width, .height = target.height, .depth = 1 },
        };
        vkd.vkCmdCopyImageToBuffer(cmd, target.image, .transfer_src_optimal, buffer, 1, @ptrCast(&region));
        barrier(cmd, vkd, target.image, .transfer_src_optimal, .color_attachment_optimal, A.transfer_read, A.color_attachment_read | A.color_attachment_write, S.transfer, S.color_attachment_output, 0, 1);
        const mb: vk.MemoryBarrier = .{ .srcAccessMask = A.transfer_write, .dstAccessMask = A.host_read };
        vkd.vkCmdPipelineBarrier(cmd, S.transfer, S.host, 0, 1, @ptrCast(&mb), 0, null, 0, null);
        try vk.check(vkd.vkEndCommandBuffer(cmd));
        const submit: vk.SubmitInfo = .{ .commandBufferCount = 1, .pCommandBuffers = @ptrCast(&cmd) };
        try vk.check(vkd.vkQueueSubmit(self.ctx.queue, 1, @ptrCast(&submit), .null_handle));
        try vk.check(vkd.vkQueueWaitIdle(self.ctx.queue));
    }

    /// Renders `batch` into `target`. Skips all GPU work when nothing changed and the target
    /// already shows the previous frame (`stats.skipped`).
    pub fn render(self: *Renderer, target: *Target, batch: *const draw.RenderBatch, options: FrameOptions) !FrameResult {
        const t_start = clock.monotonicTimestampNs();
        var stats: FrameStats = .{ .commands = @intCast(batch.commands.items.len) };
        const width = target.width;
        const height = target.height;

        // 1. Build instances + damage (backend-neutral).
        try self.enc.build(batch, width, height, options.clear, TextureGenerations{ .renderer = self }, &stats);
        const t_built = clock.monotonicTimestampNs();
        stats.build_ns = t_built - t_start;

        // 2. Decide what to repaint.
        const plan = try self.enc.plan(target.last_frame, width, height, options.force_full, self.pending_uploads.items.len > 0, &stats);
        if (plan == .skip) {
            target.last_frame = self.enc.damage_frame;
            stats.total_ns = clock.monotonicTimestampNs() - t_start;
            self.fillMemoryStats(&stats);
            self.last_stats = stats;
            return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = 0 };
        }
        const partial = plan == .partial;

        // 3. Frame slot.
        const frame = &self.frames[self.frame_cursor % self.frame_count];
        self.frame_cursor += 1;
        if (frame.serial != 0) {
            const t_wait = clock.monotonicTimestampNs();
            try vk.check(self.ctx.vkd.vkWaitForFences(self.ctx.device, 1, @ptrCast(&frame.fence), vk.true_, std.math.maxInt(u64)));
            stats.wait_ns = clock.monotonicTimestampNs() - t_wait;
            self.ctx.markCompleted(frame.serial);
        }
        try vk.check(self.ctx.vkd.vkResetFences(self.ctx.device, 1, @ptrCast(&frame.fence)));
        frame.serial = self.ctx.nextSerial();
        self.collectDeadImports();
        try self.gatherFrameImports();

        // 4. Upload instances and glyphs.
        const t_upload = clock.monotonicTimestampNs();
        try self.uploadFrameData(frame, &stats);
        const t_encode = clock.monotonicTimestampNs();
        stats.upload_ns = t_encode - t_upload;

        // 5. Record.
        const cmd = frame.cmd;
        const vkd = &self.ctx.vkd;
        try vk.check(vkd.vkResetCommandBuffer(cmd, 0));
        const begin: vk.CommandBufferBeginInfo = .{ .flags = vk.CommandBufferUsageFlags.one_time_submit };
        try vk.check(vkd.vkBeginCommandBuffer(cmd, &begin));
        self.recordTextureUploads(cmd, &stats);
        try self.recordGlyphUploads(cmd, frame, &stats);
        self.updateFrameSet(frame);
        self.recordImportBarriers(cmd, true);
        self.recordTargetAcquire(cmd, target, partial);
        self.recordPass(cmd, frame, target, options.clear, partial);
        self.recordTargetRelease(cmd, target);
        self.recordImportBarriers(cmd, false);
        try vk.check(vkd.vkEndCommandBuffer(cmd));
        const t_submit = clock.monotonicTimestampNs();
        stats.encode_ns = t_submit - t_encode;

        // 6. Submit (waits: the target's, plus producer fences of sampled imports).
        var waits: [17]vk.Semaphore = undefined;
        var wait_stages: [17]vk.Flags = undefined;
        var wait_count: u32 = 0;
        if (target.wait_semaphore != .null_handle) {
            waits[0] = target.wait_semaphore;
            wait_stages[0] = vk.PipelineStageFlags.color_attachment_output | vk.PipelineStageFlags.transfer;
            wait_count = 1;
        }
        for (self.frame_imports.items) |imp| {
            if (imp.pending_fence < 0 or wait_count == waits.len) continue;
            const fence = imp.pending_fence;
            imp.pending_fence = -1;
            if (imp.wait_semaphore == .null_handle) {
                _ = import_.close(fence);
                continue;
            }
            const import_sem: vk.ImportSemaphoreFdInfoKHR = .{
                .semaphore = imp.wait_semaphore,
                .flags = vk.SemaphoreImportFlags.temporary,
                .handleType = vk.ExternalSemaphoreHandleTypeFlags.sync_fd,
                .fd = fence,
            };
            if (vkd.vkImportSemaphoreFdKHR.?(self.ctx.device, &import_sem) != .success) {
                _ = import_.close(fence);
                continue;
            }
            waits[wait_count] = imp.wait_semaphore;
            wait_stages[wait_count] = vk.PipelineStageFlags.fragment_shader;
            wait_count += 1;
        }
        var signals: [2]vk.Semaphore = undefined;
        var signal_count: u32 = 0;
        if (target.signal_semaphore != .null_handle) {
            signals[0] = target.signal_semaphore;
            signal_count = 1;
        }
        const import_signalled = self.frame_imports.items.len > 0 and self.ensureImportSignal();
        if (import_signalled) {
            signals[signal_count] = self.import_signal;
            signal_count += 1;
        }
        const submit: vk.SubmitInfo = .{
            .waitSemaphoreCount = wait_count,
            .pWaitSemaphores = &waits,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&frame.cmd),
            .signalSemaphoreCount = signal_count,
            .pSignalSemaphores = &signals,
        };
        try vk.check(vkd.vkQueueSubmit(self.ctx.queue, 1, @ptrCast(&submit), frame.fence));
        self.finishFrameImports(frame.serial, import_signalled);
        target.layout = target.final_layout;
        target.last_frame = self.enc.damage_frame;
        target.last_serial = frame.serial;
        const t_end = clock.monotonicTimestampNs();
        stats.submit_ns = t_end - t_submit;
        stats.total_ns = t_end - t_start;
        self.fillMemoryStats(&stats);
        self.last_stats = stats;
        return .{ .damage = self.enc.damage_out.items, .stats = stats, .serial = frame.serial };
    }

    /// `core.Encoder.build`'s texture view: generation of an uploaded image.
    const TextureGenerations = struct {
        renderer: *Renderer,
        pub fn textureGeneration(self: TextureGenerations, id: u32) ?u32 {
            const t = self.renderer.textures.getPtr(id) orelse return null;
            return t.generation;
        }
        pub fn textureDamage(self: TextureGenerations, id: u32) ?core.TextureDamage {
            const t = self.renderer.textures.getPtr(id) orelse return null;
            t.damage_seen = true;
            if (t.damage_n == 0) return null;
            return .{ .base = t.damage_base, .width = t.width, .height = t.height, .rects = t.damage[0..t.damage_n] };
        }
    };

    fn fillMemoryStats(self: *Renderer, stats: *FrameStats) void {
        self.enc.fillStats(stats, 0);
        stats.gpu_memory = self.ctx.memory;
    }

    fn uploadFrameData(self: *Renderer, frame: *Frame, stats: *FrameStats) !void {
        const ctx = self.ctx;
        const instances = self.enc.instances.items;
        const inst_bytes = instances.len * @sizeOf(Instance);
        if (inst_bytes > frame.instances.allocation.size or frame.instances.buffer == .null_handle) {
            var cap: u64 = @max(frame.instances.allocation.size, 64 * 1024);
            while (cap < inst_bytes) cap *= 2;
            if (frame.instances.buffer != .null_handle) ctx.retire(.{ .buffer = frame.instances });
            frame.instances = try ctx.createBuffer(cap, vk.BufferUsageFlags.vertex_buffer, vk.MemoryPropertyFlags.host_visible, vk.MemoryPropertyFlags.host_coherent | vk.MemoryPropertyFlags.device_local);
        }
        if (inst_bytes > 0) {
            @memcpy(frame.instances.bytes()[0..inst_bytes], std.mem.sliceAsBytes(instances));
            ctx.flush(frame.instances.allocation, 0, inst_bytes);
        }
        const glyph_cache = &self.enc.glyph_cache;
        const glyph_bytes = glyph_cache.upload_bytes.items.len;
        if (glyph_bytes > 0) {
            if (glyph_bytes > frame.staging.allocation.size or frame.staging.buffer == .null_handle) {
                var cap: u64 = @max(frame.staging.allocation.size, 64 * 1024);
                while (cap < glyph_bytes) cap *= 2;
                if (frame.staging.buffer != .null_handle) ctx.retire(.{ .buffer = frame.staging });
                frame.staging = try ctx.createBuffer(cap, vk.BufferUsageFlags.transfer_src, vk.MemoryPropertyFlags.host_visible, vk.MemoryPropertyFlags.host_coherent);
            }
            @memcpy(frame.staging.bytes()[0..glyph_bytes], glyph_cache.upload_bytes.items);
            ctx.flush(frame.staging.allocation, 0, glyph_bytes);
        }
        stats.glyph_uploads = @intCast(glyph_cache.uploads.items.len);
    }

    fn barrier(cmd: vk.CommandBuffer, vkd: *const vk.DeviceDispatch, image: vk.Image, old: vk.ImageLayout, new: vk.ImageLayout, src_access: vk.Flags, dst_access: vk.Flags, src_stage: vk.Flags, dst_stage: vk.Flags, base_mip: u32, mip_count: u32) void {
        const b: vk.ImageMemoryBarrier = .{
            .srcAccessMask = src_access,
            .dstAccessMask = dst_access,
            .oldLayout = old,
            .newLayout = new,
            .srcQueueFamilyIndex = vk.queue_family_ignored,
            .dstQueueFamilyIndex = vk.queue_family_ignored,
            .image = image,
            .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .baseMipLevel = base_mip, .levelCount = mip_count, .layerCount = 1 },
        };
        vkd.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, @ptrCast(&b));
    }

    fn recordTextureUploads(self: *Renderer, cmd: vk.CommandBuffer, stats: *FrameStats) void {
        const vkd = &self.ctx.vkd;
        const S = vk.PipelineStageFlags;
        const A = vk.AccessFlags;
        for (self.pending_uploads.items) |p| {
            const tex: *Texture = if (p.id == 0) &self.dummy_texture else self.textures.getPtr(p.id) orelse {
                if (p.slot == null) self.ctx.retire(.{ .buffer = p.staging });
                continue;
            };
            if (p.slot) |si| {
                self.recordStreamUpload(cmd, tex, p, si, stats);
                continue;
            }
            const old: vk.ImageLayout = if (tex.ready) .shader_read_only_optimal else .undefined;
            barrier(cmd, vkd, tex.image, old, .transfer_dst_optimal, A.shader_read, A.transfer_write, S.fragment_shader | S.top_of_pipe, S.transfer, 0, tex.mip_levels);
            const region: vk.BufferImageCopy = .{
                .imageSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .mipLevel = 0, .layerCount = 1 },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = tex.width, .height = tex.height, .depth = 1 },
            };
            vkd.vkCmdCopyBufferToImage(cmd, p.staging.buffer, tex.image, .transfer_dst_optimal, 1, @ptrCast(&region));
            // Mip chain by successive linear blits.
            var w: i32 = @intCast(tex.width);
            var h: i32 = @intCast(tex.height);
            var level: u32 = 1;
            while (level < tex.mip_levels) : (level += 1) {
                barrier(cmd, vkd, tex.image, .transfer_dst_optimal, .transfer_src_optimal, A.transfer_write, A.transfer_read, S.transfer, S.transfer, level - 1, 1);
                const nw = @max(w >> 1, 1);
                const nh = @max(h >> 1, 1);
                const blit: vk.ImageBlit = .{
                    .srcSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .mipLevel = level - 1, .layerCount = 1 },
                    .srcOffsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = w, .y = h, .z = 1 } },
                    .dstSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .mipLevel = level, .layerCount = 1 },
                    .dstOffsets = .{ .{ .x = 0, .y = 0, .z = 0 }, .{ .x = nw, .y = nh, .z = 1 } },
                };
                vkd.vkCmdBlitImage(cmd, tex.image, .transfer_src_optimal, tex.image, .transfer_dst_optimal, 1, @ptrCast(&blit), .linear);
                barrier(cmd, vkd, tex.image, .transfer_src_optimal, .shader_read_only_optimal, A.transfer_read, A.shader_read, S.transfer, S.fragment_shader, level - 1, 1);
                w = nw;
                h = nh;
            }
            barrier(cmd, vkd, tex.image, .transfer_dst_optimal, .shader_read_only_optimal, A.transfer_write, A.shader_read, S.transfer, S.fragment_shader, tex.mip_levels - 1, 1);
            tex.ready = true;
            self.ctx.retire(.{ .buffer = p.staging });
            stats.texture_uploads += 1;
            stats.texture_upload_bytes += @as(u64, tex.width) * tex.height * 4;
        }
        self.pending_uploads.clearRetainingCapacity();
    }

    fn recordStreamUpload(self: *Renderer, cmd: vk.CommandBuffer, tex: *Texture, p: PendingUpload, si: u8, stats: *FrameStats) void {
        const vkd = &self.ctx.vkd;
        const S = vk.PipelineStageFlags;
        const A = vk.AccessFlags;
        // Earlier submissions sampling the image are ordered by this barrier (same queue);
        // `undefined` discards the old contents only when everything is rewritten.
        const whole = p.region_count == 0;
        const old: vk.ImageLayout = if (tex.ready and !whole) .shader_read_only_optimal else .undefined;
        barrier(cmd, vkd, tex.image, old, .transfer_dst_optimal, A.shader_read, A.transfer_write, S.fragment_shader | S.top_of_pipe, S.transfer, 0, 1);
        var copies: [max_stream_regions]vk.BufferImageCopy = undefined;
        var n: u32 = 0;
        var bytes: u64 = 0;
        if (whole) {
            copies[0] = .{
                .imageSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .mipLevel = 0, .layerCount = 1 },
                .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
                .imageExtent = .{ .width = tex.width, .height = tex.height, .depth = 1 },
            };
            n = 1;
            bytes = @as(u64, tex.width) * tex.height * 4;
        } else for (p.regions[0..p.region_count]) |r| {
            copies[n] = .{
                .bufferOffset = bytes,
                .bufferRowLength = r.w,
                .imageSubresource = .{ .aspectMask = vk.ImageAspectFlags.color, .mipLevel = 0, .layerCount = 1 },
                .imageOffset = .{ .x = @intCast(r.x), .y = @intCast(r.y), .z = 0 },
                .imageExtent = .{ .width = r.w, .height = r.h, .depth = 1 },
            };
            n += 1;
            bytes += @as(u64, r.w) * r.h * 4;
        }
        vkd.vkCmdCopyBufferToImage(cmd, p.staging.buffer, tex.image, .transfer_dst_optimal, n, @ptrCast(&copies));
        barrier(cmd, vkd, tex.image, .transfer_dst_optimal, .shader_read_only_optimal, A.transfer_write, A.shader_read, S.transfer, S.fragment_shader, 0, 1);
        tex.ready = true;
        const st = tex.stream.?;
        st.slots[si].pending = false;
        st.slots[si].serial = self.ctx.submit_serial;
        stats.texture_uploads += 1;
        stats.texture_upload_bytes += bytes;
    }

    fn recordGlyphUploads(self: *Renderer, cmd: vk.CommandBuffer, frame: *Frame, stats: *FrameStats) !void {
        _ = stats;
        const vkd = &self.ctx.vkd;
        const S = vk.PipelineStageFlags;
        const A = vk.AccessFlags;
        const color_aspect = vk.ImageAspectFlags.color;
        const glyph_cache = &self.enc.glyph_cache;
        for (&self.atlases, 0..) |*a, ki| {
            const kind: text.AtlasKind = @enumFromInt(ki);
            const want = glyph_cache.atlasSize(kind);
            var has_uploads = false;
            for (glyph_cache.uploads.items) |u| {
                if (u.kind == kind) has_uploads = true;
            }
            if (want != a.size) {
                // Grow: copy old -> new, retire old.
                const old = a.*;
                try self.createAtlas(kind, want);
                barrier(cmd, vkd, a.image, .undefined, .transfer_dst_optimal, 0, A.transfer_write, S.top_of_pipe, S.transfer, 0, 1);
                if (old.layout != .undefined) {
                    barrier(cmd, vkd, old.image, old.layout, .transfer_src_optimal, A.shader_read, A.transfer_read, S.fragment_shader, S.transfer, 0, 1);
                    const region: vk.ImageCopy = .{
                        .srcSubresource = .{ .aspectMask = color_aspect, .layerCount = 1 },
                        .srcOffset = .{ .x = 0, .y = 0, .z = 0 },
                        .dstSubresource = .{ .aspectMask = color_aspect, .layerCount = 1 },
                        .dstOffset = .{ .x = 0, .y = 0, .z = 0 },
                        .extent = .{ .width = old.size, .height = old.size, .depth = 1 },
                    };
                    vkd.vkCmdCopyImage(cmd, old.image, .transfer_src_optimal, a.image, .transfer_dst_optimal, 1, @ptrCast(&region));
                }
                a.layout = .transfer_dst_optimal;
                self.ctx.retire(.{ .image = .{ .image = old.image, .view = old.view, .allocation = old.allocation } });
            } else if (has_uploads or a.layout == .undefined) {
                barrier(cmd, vkd, a.image, a.layout, .transfer_dst_optimal, if (a.layout == .undefined) 0 else A.shader_read, A.transfer_write, if (a.layout == .undefined) S.top_of_pipe else S.fragment_shader, S.transfer, 0, 1);
                a.layout = .transfer_dst_optimal;
            }
            if (a.layout != .transfer_dst_optimal) continue;
            for (glyph_cache.uploads.items) |u| {
                if (u.kind != kind) continue;
                const region: vk.BufferImageCopy = .{
                    .bufferOffset = u.offset,
                    .imageSubresource = .{ .aspectMask = color_aspect, .layerCount = 1 },
                    .imageOffset = .{ .x = @intCast(u.x), .y = @intCast(u.y), .z = 0 },
                    .imageExtent = .{ .width = u.w, .height = u.h, .depth = 1 },
                };
                vkd.vkCmdCopyBufferToImage(cmd, frame.staging.buffer, a.image, .transfer_dst_optimal, 1, @ptrCast(&region));
            }
            barrier(cmd, vkd, a.image, .transfer_dst_optimal, .shader_read_only_optimal, A.transfer_write, A.shader_read, S.transfer, S.fragment_shader, 0, 1);
            a.layout = .shader_read_only_optimal;
        }
        glyph_cache.clearUploads();
    }

    fn updateFrameSet(self: *Renderer, frame: *Frame) void {
        if (frame.set0_generation == self.atlas_generation) return;
        const infos = [_]vk.DescriptorImageInfo{
            .{ .sampler = self.sampler_nearest, .imageView = self.atlases[0].view, .imageLayout = .shader_read_only_optimal },
            .{ .sampler = self.sampler_nearest, .imageView = self.atlases[1].view, .imageLayout = .shader_read_only_optimal },
        };
        const writes = [_]vk.WriteDescriptorSet{
            .{ .dstSet = frame.set0, .dstBinding = 0, .descriptorCount = 1, .descriptorType = .combined_image_sampler, .pImageInfo = @ptrCast(&infos[0]) },
            .{ .dstSet = frame.set0, .dstBinding = 1, .descriptorCount = 1, .descriptorType = .combined_image_sampler, .pImageInfo = @ptrCast(&infos[1]) },
        };
        self.ctx.vkd.vkUpdateDescriptorSets(self.ctx.device, writes.len, &writes, 0, null);
        frame.set0_generation = self.atlas_generation;
    }

    fn recordTargetAcquire(self: *Renderer, cmd: vk.CommandBuffer, target: *Target, keep_contents: bool) void {
        const vkd = &self.ctx.vkd;
        const was_released = target.foreign and target.layout != .undefined;
        const old: vk.ImageLayout = if (keep_contents) target.layout else .undefined;
        const b: vk.ImageMemoryBarrier = .{
            .srcAccessMask = 0,
            .dstAccessMask = vk.AccessFlags.color_attachment_read | vk.AccessFlags.color_attachment_write,
            .oldLayout = old,
            .newLayout = .color_attachment_optimal,
            .srcQueueFamilyIndex = if (was_released) target.foreign_family else vk.queue_family_ignored,
            .dstQueueFamilyIndex = if (was_released) self.ctx.queue_family else vk.queue_family_ignored,
            .image = target.image,
            .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = 1, .layerCount = 1 },
        };
        vkd.vkCmdPipelineBarrier(cmd, vk.PipelineStageFlags.top_of_pipe, vk.PipelineStageFlags.color_attachment_output, 0, 0, null, 0, null, 1, @ptrCast(&b));
    }

    fn recordTargetRelease(self: *Renderer, cmd: vk.CommandBuffer, target: *Target) void {
        const vkd = &self.ctx.vkd;
        if (target.final_layout == .color_attachment_optimal and !target.foreign) return;
        const b: vk.ImageMemoryBarrier = .{
            .srcAccessMask = vk.AccessFlags.color_attachment_write,
            .dstAccessMask = 0,
            .oldLayout = .color_attachment_optimal,
            .newLayout = target.final_layout,
            .srcQueueFamilyIndex = if (target.foreign) self.ctx.queue_family else vk.queue_family_ignored,
            .dstQueueFamilyIndex = if (target.foreign) target.foreign_family else vk.queue_family_ignored,
            .image = target.image,
            .subresourceRange = .{ .aspectMask = vk.ImageAspectFlags.color, .levelCount = 1, .layerCount = 1 },
        };
        vkd.vkCmdPipelineBarrier(cmd, vk.PipelineStageFlags.color_attachment_output, vk.PipelineStageFlags.bottom_of_pipe, 0, 0, null, 0, null, 1, @ptrCast(&b));
    }

    fn recordPass(self: *Renderer, cmd: vk.CommandBuffer, frame: *Frame, target: *Target, clear: draw.Color, partial: bool) void {
        const vkd = &self.ctx.vkd;
        const clear_value: vk.ClearValue = .{ .color = .{ .float32 = core.premultipliedClear(clear) } };
        const full: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } };
        const begin: vk.RenderPassBeginInfo = .{
            .renderPass = if (partial) self.render_pass_load else self.render_pass_clear,
            .framebuffer = target.framebuffer,
            .renderArea = full,
            .clearValueCount = 1,
            .pClearValues = @ptrCast(&clear_value),
        };
        vkd.vkCmdBeginRenderPass(cmd, &begin, .@"inline");
        const viewport: vk.Viewport = .{ .width = @floatFromInt(target.width), .height = @floatFromInt(target.height), .maxDepth = 1 };
        vkd.vkCmdSetViewport(cmd, 0, 1, @ptrCast(&viewport));
        vkd.vkCmdBindPipeline(cmd, .graphics, self.pipeline);
        const push = [4]u32{
            @bitCast(2.0 / @as(f32, @floatFromInt(target.width))),
            @bitCast(2.0 / @as(f32, @floatFromInt(target.height))),
            self.enc.shaderFlags(),
            0,
        };
        vkd.vkCmdPushConstants(cmd, self.pipeline_layout, vk.ShaderStageFlags.vertex | vk.ShaderStageFlags.fragment, 0, 16, &push);
        vkd.vkCmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout, 0, 1, @ptrCast(&frame.set0), 0, null);
        const offset: u64 = 0;
        if (frame.instances.buffer != .null_handle) vkd.vkCmdBindVertexBuffers(cmd, 0, 1, @ptrCast(&frame.instances.buffer), @ptrCast(&offset));

        var scissors: [damage.max_rects]vk.Rect2D = undefined;
        var n: usize = 0;
        if (partial) {
            var clears: [damage.max_rects]vk.ClearRect = undefined;
            for (self.enc.damage_out.items) |r| {
                if (r.w <= 0 or r.h <= 0) continue;
                scissors[n] = .{ .offset = .{ .x = r.x, .y = r.y }, .extent = .{ .width = @intCast(r.w), .height = @intCast(r.h) } };
                clears[n] = .{ .rect = scissors[n], .baseArrayLayer = 0, .layerCount = 1 };
                n += 1;
            }
            if (n > 0) {
                const att: vk.ClearAttachment = .{ .aspectMask = vk.ImageAspectFlags.color, .colorAttachment = 0, .clearValue = clear_value };
                vkd.vkCmdClearAttachments(cmd, 1, @ptrCast(&att), @intCast(n), &clears);
            }
        } else {
            scissors[0] = full;
            n = 1;
        }
        for (scissors[0..n]) |sc| {
            vkd.vkCmdSetScissor(cmd, 0, 1, @ptrCast(&sc));
            var bound: vk.DescriptorSet = .null_handle;
            for (self.enc.runs.items) |d| {
                if (d.count == 0) continue;
                const set = self.runSet(d.texture);
                if (set != bound) {
                    vkd.vkCmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout, 1, 1, @ptrCast(&set), 0, null);
                    bound = set;
                }
                vkd.vkCmdDraw(cmd, 4, d.count, 0, d.first);
            }
        }
        vkd.vkCmdEndRenderPass(cmd);
    }

    /// Descriptor set of a draw run's texture (0 = the white dummy). Runs only reference
    /// textures that existed when the batch was built in this same `render` call.
    fn runSet(self: *Renderer, id: u32) vk.DescriptorSet {
        if (id == 0) return self.dummy_texture.set;
        const t = self.textures.getPtr(id) orelse return self.dummy_texture.set;
        return t.set;
    }
};

pub const packColor = core.packColor;
pub const snapRectToPixelGrid = core.snapRectToPixelGrid;
pub const strokePixelWidth = core.strokePixelWidth;
pub const clampedRadius = core.clampedRadius;

