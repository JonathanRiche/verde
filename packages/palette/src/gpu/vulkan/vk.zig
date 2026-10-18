//! Minimal hand-written Vulkan bindings: only what Palette's renderer uses.
//!
//! Nothing is linked at build time. `Loader.open()` dlopens the system loader
//! (`libvulkan.so.1`) and every other entry point is resolved through
//! `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` into the dispatch tables below.
//! Struct layouts mirror the C ABI of `vulkan_core.h` (field names kept verbatim so they are
//! greppable against the spec); `sType` defaults are pre-filled.

const std = @import("std");

pub const api_version_1_1: u32 = makeApiVersion(0, 1, 1, 0);
pub const api_version_1_2: u32 = makeApiVersion(0, 1, 2, 0);
pub const api_version_1_3: u32 = makeApiVersion(0, 1, 3, 0);

pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}
pub fn apiVersionMajor(v: u32) u32 {
    return (v >> 22) & 0x7f;
}
pub fn apiVersionMinor(v: u32) u32 {
    return (v >> 12) & 0x3ff;
}

pub const Bool32 = u32;
pub const Flags = u32;
pub const Flags64 = u64;
pub const true_: Bool32 = 1;
pub const false_: Bool32 = 0;

pub const whole_size: u64 = ~@as(u64, 0);
pub const queue_family_ignored: u32 = ~@as(u32, 0);
pub const queue_family_external: u32 = ~@as(u32, 0) - 1;
pub const queue_family_foreign_ext: u32 = ~@as(u32, 0) - 2;
pub const subpass_external: u32 = ~@as(u32, 0);
pub const remaining_mip_levels: u32 = ~@as(u32, 0);
pub const remaining_array_layers: u32 = ~@as(u32, 0);

// ---- Handles ---------------------------------------------------------------------------------
// Dispatchable handles are pointers; non-dispatchable handles are 64-bit on all 64-bit ABIs.
pub const Instance = enum(usize) { null_handle = 0, _ };
pub const PhysicalDevice = enum(usize) { null_handle = 0, _ };
pub const Device = enum(usize) { null_handle = 0, _ };
pub const Queue = enum(usize) { null_handle = 0, _ };
pub const CommandBuffer = enum(usize) { null_handle = 0, _ };

pub const Semaphore = enum(u64) { null_handle = 0, _ };
pub const Fence = enum(u64) { null_handle = 0, _ };
pub const DeviceMemory = enum(u64) { null_handle = 0, _ };
pub const Buffer = enum(u64) { null_handle = 0, _ };
pub const BufferView = enum(u64) { null_handle = 0, _ };
pub const Image = enum(u64) { null_handle = 0, _ };
pub const ImageView = enum(u64) { null_handle = 0, _ };
pub const ShaderModule = enum(u64) { null_handle = 0, _ };
pub const PipelineCache = enum(u64) { null_handle = 0, _ };
pub const PipelineLayout = enum(u64) { null_handle = 0, _ };
pub const RenderPass = enum(u64) { null_handle = 0, _ };
pub const Pipeline = enum(u64) { null_handle = 0, _ };
pub const DescriptorSetLayout = enum(u64) { null_handle = 0, _ };
pub const Sampler = enum(u64) { null_handle = 0, _ };
pub const DescriptorPool = enum(u64) { null_handle = 0, _ };
pub const DescriptorSet = enum(u64) { null_handle = 0, _ };
pub const Framebuffer = enum(u64) { null_handle = 0, _ };
pub const CommandPool = enum(u64) { null_handle = 0, _ };
pub const DebugUtilsMessengerEXT = enum(u64) { null_handle = 0, _ };

// Structs we only ever pass as null.
pub const AllocationCallbacks = opaque {};
pub const CommandBufferInheritanceInfo = opaque {};
pub const PipelineTessellationStateCreateInfo = opaque {};
pub const PipelineDepthStencilStateCreateInfo = opaque {};

// ---- Enums (only the values Palette uses; non-exhaustive) -------------------------------------
pub const Result = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    incomplete = 5,
    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,
    error_out_of_pool_memory = -1000069000,
    error_invalid_external_handle = -1000072003,
    error_invalid_drm_format_modifier_plane_layout_ext = -1000158000,
    _,
};

pub const Error = error{
    VulkanOutOfHostMemory,
    VulkanOutOfDeviceMemory,
    VulkanInitializationFailed,
    VulkanDeviceLost,
    VulkanMemoryMapFailed,
    VulkanLayerNotPresent,
    VulkanExtensionNotPresent,
    VulkanFeatureNotPresent,
    VulkanIncompatibleDriver,
    VulkanTooManyObjects,
    VulkanFormatNotSupported,
    VulkanFragmentedPool,
    VulkanOutOfPoolMemory,
    VulkanInvalidExternalHandle,
    VulkanInvalidDrmModifierLayout,
    VulkanUnknown,
};

/// Maps a failing VkResult to a Zig error. Non-error codes (timeout, incomplete...) pass.
pub fn check(result: Result) Error!void {
    return switch (result) {
        .success, .not_ready, .timeout, .incomplete => {},
        .error_out_of_host_memory => error.VulkanOutOfHostMemory,
        .error_out_of_device_memory => error.VulkanOutOfDeviceMemory,
        .error_initialization_failed => error.VulkanInitializationFailed,
        .error_device_lost => error.VulkanDeviceLost,
        .error_memory_map_failed => error.VulkanMemoryMapFailed,
        .error_layer_not_present => error.VulkanLayerNotPresent,
        .error_extension_not_present => error.VulkanExtensionNotPresent,
        .error_feature_not_present => error.VulkanFeatureNotPresent,
        .error_incompatible_driver => error.VulkanIncompatibleDriver,
        .error_too_many_objects => error.VulkanTooManyObjects,
        .error_format_not_supported => error.VulkanFormatNotSupported,
        .error_fragmented_pool => error.VulkanFragmentedPool,
        .error_out_of_pool_memory => error.VulkanOutOfPoolMemory,
        .error_invalid_external_handle => error.VulkanInvalidExternalHandle,
        .error_invalid_drm_format_modifier_plane_layout_ext => error.VulkanInvalidDrmModifierLayout,
        else => if (@intFromEnum(result) < 0) error.VulkanUnknown else {},
    };
}

pub const StructureType = enum(i32) { _ };

pub const PhysicalDeviceType = enum(i32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
    _,
};

pub const Format = enum(i32) {
    undefined = 0,
    r8_unorm = 9,
    r8g8b8a8_unorm = 37,
    b8g8r8a8_unorm = 44,
    r32g32b32a32_uint = 107,
    r32g32b32a32_sfloat = 109,
    _,
};

pub const ImageLayout = enum(i32) {
    undefined = 0,
    general = 1,
    color_attachment_optimal = 2,
    shader_read_only_optimal = 5,
    transfer_src_optimal = 6,
    transfer_dst_optimal = 7,
    _,
};

pub const SharingMode = enum(i32) { exclusive = 0, concurrent = 1, _ };
pub const ImageTiling = enum(i32) { optimal = 0, linear = 1, drm_format_modifier_ext = 1000158000, _ };
pub const ImageType = enum(i32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, _ };
pub const ImageViewType = enum(i32) { @"1d" = 0, @"2d" = 1, @"3d" = 2, _ };
pub const ComponentSwizzle = enum(i32) { identity = 0, zero = 1, one = 2, r = 3, g = 4, b = 5, a = 6, _ };
pub const Filter = enum(i32) { nearest = 0, linear = 1, _ };
pub const SamplerMipmapMode = enum(i32) { nearest = 0, linear = 1, _ };
pub const SamplerAddressMode = enum(i32) { repeat = 0, mirrored_repeat = 1, clamp_to_edge = 2, _ };
pub const BorderColor = enum(i32) { float_transparent_black = 0, _ };
pub const CompareOp = enum(i32) { never = 0, always = 7, _ };
pub const DescriptorType = enum(i32) { sampler = 0, combined_image_sampler = 1, sampled_image = 2, uniform_buffer = 6, storage_buffer = 7, _ };
pub const PrimitiveTopology = enum(i32) { triangle_list = 3, triangle_strip = 4, _ };
pub const PolygonMode = enum(i32) { fill = 0, _ };
pub const FrontFace = enum(i32) { counter_clockwise = 0, clockwise = 1, _ };
pub const BlendFactor = enum(i32) { zero = 0, one = 1, src_alpha = 6, one_minus_src_alpha = 7, _ };
pub const BlendOp = enum(i32) { add = 0, _ };
pub const LogicOp = enum(i32) { clear = 0, copy = 3, _ };
pub const DynamicState = enum(i32) { viewport = 0, scissor = 1, _ };
pub const VertexInputRate = enum(i32) { vertex = 0, instance = 1, _ };
pub const AttachmentLoadOp = enum(i32) { load = 0, clear = 1, dont_care = 2, _ };
pub const AttachmentStoreOp = enum(i32) { store = 0, dont_care = 1, _ };
pub const PipelineBindPoint = enum(i32) { graphics = 0, _ };
pub const SubpassContents = enum(i32) { @"inline" = 0, _ };
pub const CommandBufferLevel = enum(i32) { primary = 0, _ };
pub const ObjectType = enum(i32) { unknown = 0, _ };

// ---- Flag bits --------------------------------------------------------------------------------
pub const QueueFlags = struct {
    pub const graphics: Flags = 0x1;
    pub const compute: Flags = 0x2;
    pub const transfer: Flags = 0x4;
};
pub const MemoryPropertyFlags = struct {
    pub const device_local: Flags = 0x1;
    pub const host_visible: Flags = 0x2;
    pub const host_coherent: Flags = 0x4;
    pub const host_cached: Flags = 0x8;
};
pub const MemoryHeapFlags = struct {
    pub const device_local: Flags = 0x1;
};
pub const ImageUsageFlags = struct {
    pub const transfer_src: Flags = 0x1;
    pub const transfer_dst: Flags = 0x2;
    pub const sampled: Flags = 0x4;
    pub const color_attachment: Flags = 0x10;
};
pub const BufferUsageFlags = struct {
    pub const transfer_src: Flags = 0x1;
    pub const transfer_dst: Flags = 0x2;
    pub const vertex_buffer: Flags = 0x80;
};
pub const ImageAspectFlags = struct {
    pub const color: Flags = 0x1;
    pub const memory_plane_0_ext: Flags = 0x80;
    pub const memory_plane_1_ext: Flags = 0x100;
    pub const memory_plane_2_ext: Flags = 0x200;
    pub const memory_plane_3_ext: Flags = 0x400;
};
pub const AccessFlags = struct {
    pub const none: Flags = 0;
    pub const vertex_attribute_read: Flags = 0x4;
    pub const shader_read: Flags = 0x20;
    pub const color_attachment_read: Flags = 0x80;
    pub const color_attachment_write: Flags = 0x100;
    pub const transfer_read: Flags = 0x800;
    pub const transfer_write: Flags = 0x1000;
    pub const host_read: Flags = 0x2000;
    pub const host_write: Flags = 0x4000;
    pub const memory_read: Flags = 0x8000;
    pub const memory_write: Flags = 0x10000;
};
pub const PipelineStageFlags = struct {
    pub const top_of_pipe: Flags = 0x1;
    pub const vertex_input: Flags = 0x4;
    pub const vertex_shader: Flags = 0x8;
    pub const fragment_shader: Flags = 0x80;
    pub const color_attachment_output: Flags = 0x400;
    pub const transfer: Flags = 0x1000;
    pub const bottom_of_pipe: Flags = 0x2000;
    pub const host: Flags = 0x4000;
    pub const all_commands: Flags = 0x10000;
};
pub const FormatFeatureFlags = struct {
    pub const sampled_image: Flags = 0x1;
    pub const color_attachment: Flags = 0x80;
    pub const color_attachment_blend: Flags = 0x100;
    pub const blit_src: Flags = 0x400;
    pub const blit_dst: Flags = 0x800;
    pub const sampled_image_filter_linear: Flags = 0x1000;
    pub const transfer_src: Flags = 0x4000;
    pub const transfer_dst: Flags = 0x8000;
};
pub const CommandPoolCreateFlags = struct {
    pub const transient: Flags = 0x1;
    pub const reset_command_buffer: Flags = 0x2;
};
pub const CommandBufferUsageFlags = struct {
    pub const one_time_submit: Flags = 0x1;
};
pub const FenceCreateFlags = struct {
    pub const signaled: Flags = 0x1;
};
pub const DescriptorPoolCreateFlags = struct {
    pub const free_descriptor_set: Flags = 0x1;
};
pub const ShaderStageFlags = struct {
    pub const vertex: Flags = 0x1;
    pub const fragment: Flags = 0x10;
};
pub const ColorComponentFlags = struct {
    pub const r: Flags = 0x1;
    pub const g: Flags = 0x2;
    pub const b: Flags = 0x4;
    pub const a: Flags = 0x8;
    pub const rgba: Flags = 0xf;
};
pub const SampleCountFlags = struct {
    pub const @"1": Flags = 0x1;
};
pub const CullModeFlags = struct {
    pub const none: Flags = 0;
};
pub const ExternalMemoryHandleTypeFlags = struct {
    pub const opaque_fd: Flags = 0x1;
    pub const dma_buf_ext: Flags = 0x200;
};
pub const ExternalMemoryFeatureFlags = struct {
    pub const dedicated_only: Flags = 0x1;
    pub const exportable: Flags = 0x2;
    pub const importable: Flags = 0x4;
};
pub const ExternalSemaphoreHandleTypeFlags = struct {
    pub const opaque_fd: Flags = 0x1;
    pub const sync_fd: Flags = 0x10;
};
pub const ExternalSemaphoreFeatureFlags = struct {
    pub const exportable: Flags = 0x1;
    pub const importable: Flags = 0x2;
};
pub const SemaphoreImportFlags = struct {
    pub const temporary: Flags = 0x1;
};
pub const DebugUtilsMessageSeverityFlagsEXT = struct {
    pub const verbose: Flags = 0x1;
    pub const info: Flags = 0x10;
    pub const warning: Flags = 0x100;
    pub const @"error": Flags = 0x1000;
};
pub const DebugUtilsMessageTypeFlagsEXT = struct {
    pub const general: Flags = 0x1;
    pub const validation: Flags = 0x2;
    pub const performance: Flags = 0x4;
};

pub const PfnDebugUtilsMessengerCallbackEXT = *const fn (
    severity: Flags,
    types: Flags,
    data: ?*const DebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(.c) Bool32;

// ---- Structs (C layout; generated from the registry header once, then curated) ---------------
pub const ApplicationInfo = extern struct {
    sType: StructureType = @enumFromInt(0),
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = 0,
};
pub const InstanceCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(1),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    pApplicationInfo: ?[*]const ApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};
pub const PhysicalDeviceProperties = extern struct {
    apiVersion: u32 = 0,
    driverVersion: u32 = 0,
    vendorID: u32 = 0,
    deviceID: u32 = 0,
    deviceType: PhysicalDeviceType = @enumFromInt(0),
    deviceName: [256]u8,
    pipelineCacheUUID: [16]u8,
    limits: PhysicalDeviceLimits,
    sparseProperties: PhysicalDeviceSparseProperties,
};
pub const PhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32 = 0,
    maxImageDimension2D: u32 = 0,
    maxImageDimension3D: u32 = 0,
    maxImageDimensionCube: u32 = 0,
    maxImageArrayLayers: u32 = 0,
    maxTexelBufferElements: u32 = 0,
    maxUniformBufferRange: u32 = 0,
    maxStorageBufferRange: u32 = 0,
    maxPushConstantsSize: u32 = 0,
    maxMemoryAllocationCount: u32 = 0,
    maxSamplerAllocationCount: u32 = 0,
    bufferImageGranularity: u64 = 0,
    sparseAddressSpaceSize: u64 = 0,
    maxBoundDescriptorSets: u32 = 0,
    maxPerStageDescriptorSamplers: u32 = 0,
    maxPerStageDescriptorUniformBuffers: u32 = 0,
    maxPerStageDescriptorStorageBuffers: u32 = 0,
    maxPerStageDescriptorSampledImages: u32 = 0,
    maxPerStageDescriptorStorageImages: u32 = 0,
    maxPerStageDescriptorInputAttachments: u32 = 0,
    maxPerStageResources: u32 = 0,
    maxDescriptorSetSamplers: u32 = 0,
    maxDescriptorSetUniformBuffers: u32 = 0,
    maxDescriptorSetUniformBuffersDynamic: u32 = 0,
    maxDescriptorSetStorageBuffers: u32 = 0,
    maxDescriptorSetStorageBuffersDynamic: u32 = 0,
    maxDescriptorSetSampledImages: u32 = 0,
    maxDescriptorSetStorageImages: u32 = 0,
    maxDescriptorSetInputAttachments: u32 = 0,
    maxVertexInputAttributes: u32 = 0,
    maxVertexInputBindings: u32 = 0,
    maxVertexInputAttributeOffset: u32 = 0,
    maxVertexInputBindingStride: u32 = 0,
    maxVertexOutputComponents: u32 = 0,
    maxTessellationGenerationLevel: u32 = 0,
    maxTessellationPatchSize: u32 = 0,
    maxTessellationControlPerVertexInputComponents: u32 = 0,
    maxTessellationControlPerVertexOutputComponents: u32 = 0,
    maxTessellationControlPerPatchOutputComponents: u32 = 0,
    maxTessellationControlTotalOutputComponents: u32 = 0,
    maxTessellationEvaluationInputComponents: u32 = 0,
    maxTessellationEvaluationOutputComponents: u32 = 0,
    maxGeometryShaderInvocations: u32 = 0,
    maxGeometryInputComponents: u32 = 0,
    maxGeometryOutputComponents: u32 = 0,
    maxGeometryOutputVertices: u32 = 0,
    maxGeometryTotalOutputComponents: u32 = 0,
    maxFragmentInputComponents: u32 = 0,
    maxFragmentOutputAttachments: u32 = 0,
    maxFragmentDualSrcAttachments: u32 = 0,
    maxFragmentCombinedOutputResources: u32 = 0,
    maxComputeSharedMemorySize: u32 = 0,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32 = 0,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32 = 0,
    subTexelPrecisionBits: u32 = 0,
    mipmapPrecisionBits: u32 = 0,
    maxDrawIndexedIndexValue: u32 = 0,
    maxDrawIndirectCount: u32 = 0,
    maxSamplerLodBias: f32 = 0,
    maxSamplerAnisotropy: f32 = 0,
    maxViewports: u32 = 0,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32 = 0,
    minMemoryMapAlignment: usize = 0,
    minTexelBufferOffsetAlignment: u64 = 0,
    minUniformBufferOffsetAlignment: u64 = 0,
    minStorageBufferOffsetAlignment: u64 = 0,
    minTexelOffset: i32 = 0,
    maxTexelOffset: u32 = 0,
    minTexelGatherOffset: i32 = 0,
    maxTexelGatherOffset: u32 = 0,
    minInterpolationOffset: f32 = 0,
    maxInterpolationOffset: f32 = 0,
    subPixelInterpolationOffsetBits: u32 = 0,
    maxFramebufferWidth: u32 = 0,
    maxFramebufferHeight: u32 = 0,
    maxFramebufferLayers: u32 = 0,
    framebufferColorSampleCounts: Flags = 0,
    framebufferDepthSampleCounts: Flags = 0,
    framebufferStencilSampleCounts: Flags = 0,
    framebufferNoAttachmentsSampleCounts: Flags = 0,
    maxColorAttachments: u32 = 0,
    sampledImageColorSampleCounts: Flags = 0,
    sampledImageIntegerSampleCounts: Flags = 0,
    sampledImageDepthSampleCounts: Flags = 0,
    sampledImageStencilSampleCounts: Flags = 0,
    storageImageSampleCounts: Flags = 0,
    maxSampleMaskWords: u32 = 0,
    timestampComputeAndGraphics: Bool32 = 0,
    timestampPeriod: f32 = 0,
    maxClipDistances: u32 = 0,
    maxCullDistances: u32 = 0,
    maxCombinedClipAndCullDistances: u32 = 0,
    discreteQueuePriorities: u32 = 0,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32 = 0,
    lineWidthGranularity: f32 = 0,
    strictLines: Bool32 = 0,
    standardSampleLocations: Bool32 = 0,
    optimalBufferCopyOffsetAlignment: u64 = 0,
    optimalBufferCopyRowPitchAlignment: u64 = 0,
    nonCoherentAtomSize: u64 = 0,
};
pub const PhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: Bool32 = 0,
    residencyStandard2DMultisampleBlockShape: Bool32 = 0,
    residencyStandard3DBlockShape: Bool32 = 0,
    residencyAlignedMipSize: Bool32 = 0,
    residencyNonResidentStrict: Bool32 = 0,
};
pub const QueueFamilyProperties = extern struct {
    queueFlags: Flags = 0,
    queueCount: u32 = 0,
    timestampValidBits: u32 = 0,
    minImageTransferGranularity: Extent3D,
};
pub const PhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32 = 0,
    memoryTypes: [32]MemoryType,
    memoryHeapCount: u32 = 0,
    memoryHeaps: [16]MemoryHeap,
};
pub const MemoryType = extern struct {
    propertyFlags: Flags = 0,
    heapIndex: u32 = 0,
};
pub const MemoryHeap = extern struct {
    size: u64 = 0,
    flags: Flags = 0,
};
pub const ExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32 = 0,
};
pub const LayerProperties = extern struct {
    layerName: [256]u8,
    specVersion: u32 = 0,
    implementationVersion: u32 = 0,
    description: [256]u8,
};
pub const DeviceQueueCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(2),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    queueFamilyIndex: u32 = 0,
    queueCount: u32 = 0,
    pQueuePriorities: ?[*]const f32 = null,
};
pub const DeviceCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(3),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    queueCreateInfoCount: u32 = 0,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?[*]const PhysicalDeviceFeatures = null,
};
pub const PhysicalDeviceFeatures = extern struct {
    robustBufferAccess: Bool32 = 0,
    fullDrawIndexUint32: Bool32 = 0,
    imageCubeArray: Bool32 = 0,
    independentBlend: Bool32 = 0,
    geometryShader: Bool32 = 0,
    tessellationShader: Bool32 = 0,
    sampleRateShading: Bool32 = 0,
    dualSrcBlend: Bool32 = 0,
    logicOp: Bool32 = 0,
    multiDrawIndirect: Bool32 = 0,
    drawIndirectFirstInstance: Bool32 = 0,
    depthClamp: Bool32 = 0,
    depthBiasClamp: Bool32 = 0,
    fillModeNonSolid: Bool32 = 0,
    depthBounds: Bool32 = 0,
    wideLines: Bool32 = 0,
    largePoints: Bool32 = 0,
    alphaToOne: Bool32 = 0,
    multiViewport: Bool32 = 0,
    samplerAnisotropy: Bool32 = 0,
    textureCompressionETC2: Bool32 = 0,
    textureCompressionASTC_LDR: Bool32 = 0,
    textureCompressionBC: Bool32 = 0,
    occlusionQueryPrecise: Bool32 = 0,
    pipelineStatisticsQuery: Bool32 = 0,
    vertexPipelineStoresAndAtomics: Bool32 = 0,
    fragmentStoresAndAtomics: Bool32 = 0,
    shaderTessellationAndGeometryPointSize: Bool32 = 0,
    shaderImageGatherExtended: Bool32 = 0,
    shaderStorageImageExtendedFormats: Bool32 = 0,
    shaderStorageImageMultisample: Bool32 = 0,
    shaderStorageImageReadWithoutFormat: Bool32 = 0,
    shaderStorageImageWriteWithoutFormat: Bool32 = 0,
    shaderUniformBufferArrayDynamicIndexing: Bool32 = 0,
    shaderSampledImageArrayDynamicIndexing: Bool32 = 0,
    shaderStorageBufferArrayDynamicIndexing: Bool32 = 0,
    shaderStorageImageArrayDynamicIndexing: Bool32 = 0,
    shaderClipDistance: Bool32 = 0,
    shaderCullDistance: Bool32 = 0,
    shaderFloat64: Bool32 = 0,
    shaderInt64: Bool32 = 0,
    shaderInt16: Bool32 = 0,
    shaderResourceResidency: Bool32 = 0,
    shaderResourceMinLod: Bool32 = 0,
    sparseBinding: Bool32 = 0,
    sparseResidencyBuffer: Bool32 = 0,
    sparseResidencyImage2D: Bool32 = 0,
    sparseResidencyImage3D: Bool32 = 0,
    sparseResidency2Samples: Bool32 = 0,
    sparseResidency4Samples: Bool32 = 0,
    sparseResidency8Samples: Bool32 = 0,
    sparseResidency16Samples: Bool32 = 0,
    sparseResidencyAliased: Bool32 = 0,
    variableMultisampleRate: Bool32 = 0,
    inheritedQueries: Bool32 = 0,
};
pub const Extent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};
pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};
pub const Offset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};
pub const Offset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};
pub const Rect2D = extern struct {
    offset: Offset2D,
    extent: Extent2D,
};
pub const PhysicalDeviceProperties2 = extern struct {
    sType: StructureType = @enumFromInt(1000059001),
    pNext: ?*anyopaque = null,
    properties: PhysicalDeviceProperties,
};
pub const PhysicalDeviceDrmPropertiesEXT = extern struct {
    sType: StructureType = @enumFromInt(1000353000),
    pNext: ?*anyopaque = null,
    hasPrimary: Bool32 = 0,
    hasRender: Bool32 = 0,
    primaryMajor: i64 = 0,
    primaryMinor: i64 = 0,
    renderMajor: i64 = 0,
    renderMinor: i64 = 0,
};
pub const FormatProperties = extern struct {
    linearTilingFeatures: Flags = 0,
    optimalTilingFeatures: Flags = 0,
    bufferFeatures: Flags = 0,
};
pub const FormatProperties2 = extern struct {
    sType: StructureType = @enumFromInt(1000059002),
    pNext: ?*anyopaque = null,
    formatProperties: FormatProperties,
};
pub const DrmFormatModifierPropertiesListEXT = extern struct {
    sType: StructureType = @enumFromInt(1000158000),
    pNext: ?*anyopaque = null,
    drmFormatModifierCount: u32 = 0,
    pDrmFormatModifierProperties: ?[*]DrmFormatModifierPropertiesEXT = null,
};
pub const DrmFormatModifierPropertiesEXT = extern struct {
    drmFormatModifier: u64 = 0,
    drmFormatModifierPlaneCount: u32 = 0,
    drmFormatModifierTilingFeatures: Flags = 0,
};
pub const PhysicalDeviceImageFormatInfo2 = extern struct {
    sType: StructureType = @enumFromInt(1000059004),
    pNext: ?*const anyopaque = null,
    format: Format = @enumFromInt(0),
    type: ImageType = @enumFromInt(0),
    tiling: ImageTiling = @enumFromInt(0),
    usage: Flags = 0,
    flags: Flags = 0,
};
pub const PhysicalDeviceExternalImageFormatInfo = extern struct {
    sType: StructureType = @enumFromInt(1000071000),
    pNext: ?*const anyopaque = null,
    handleType: Flags = 0,
};
pub const PhysicalDeviceImageDrmFormatModifierInfoEXT = extern struct {
    sType: StructureType = @enumFromInt(1000158002),
    pNext: ?*const anyopaque = null,
    drmFormatModifier: u64 = 0,
    sharingMode: SharingMode = @enumFromInt(0),
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};
pub const ImageFormatProperties = extern struct {
    maxExtent: Extent3D,
    maxMipLevels: u32 = 0,
    maxArrayLayers: u32 = 0,
    sampleCounts: Flags = 0,
    maxResourceSize: u64 = 0,
};
pub const ImageFormatProperties2 = extern struct {
    sType: StructureType = @enumFromInt(1000059003),
    pNext: ?*anyopaque = null,
    imageFormatProperties: ImageFormatProperties,
};
pub const ExternalImageFormatProperties = extern struct {
    sType: StructureType = @enumFromInt(1000071001),
    pNext: ?*anyopaque = null,
    externalMemoryProperties: ExternalMemoryProperties,
};
pub const ExternalMemoryProperties = extern struct {
    externalMemoryFeatures: Flags = 0,
    exportFromImportedHandleTypes: Flags = 0,
    compatibleHandleTypes: Flags = 0,
};
pub const PhysicalDeviceExternalSemaphoreInfo = extern struct {
    sType: StructureType = @enumFromInt(1000076000),
    pNext: ?*const anyopaque = null,
    handleType: Flags = 0,
};
pub const ExternalSemaphoreProperties = extern struct {
    sType: StructureType = @enumFromInt(1000076001),
    pNext: ?*anyopaque = null,
    exportFromImportedHandleTypes: Flags = 0,
    compatibleHandleTypes: Flags = 0,
    externalSemaphoreFeatures: Flags = 0,
};
pub const CommandPoolCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(39),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    queueFamilyIndex: u32 = 0,
};
pub const CommandBufferAllocateInfo = extern struct {
    sType: StructureType = @enumFromInt(40),
    pNext: ?*const anyopaque = null,
    commandPool: CommandPool,
    level: CommandBufferLevel = @enumFromInt(0),
    commandBufferCount: u32 = 0,
};
pub const CommandBufferBeginInfo = extern struct {
    sType: StructureType = @enumFromInt(42),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    pInheritanceInfo: ?*const CommandBufferInheritanceInfo = null,
};
pub const FenceCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(8),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
};
pub const SemaphoreCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(9),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
};
pub const ExportSemaphoreCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(1000077000),
    pNext: ?*const anyopaque = null,
    handleTypes: Flags = 0,
};
pub const SemaphoreGetFdInfoKHR = extern struct {
    sType: StructureType = @enumFromInt(1000079001),
    pNext: ?*const anyopaque = null,
    semaphore: Semaphore,
    handleType: Flags = 0,
};
pub const ImportSemaphoreFdInfoKHR = extern struct {
    sType: StructureType = @enumFromInt(1000079000),
    pNext: ?*const anyopaque = null,
    semaphore: Semaphore,
    flags: Flags = 0,
    handleType: Flags = 0,
    fd: c_int,
};
pub const SubmitInfo = extern struct {
    sType: StructureType = @enumFromInt(4),
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?[*]const Semaphore = null,
    pWaitDstStageMask: ?[*]const Flags = null,
    commandBufferCount: u32 = 0,
    pCommandBuffers: ?[*]const CommandBuffer = null,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?[*]const Semaphore = null,
};
pub const BufferCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(12),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    size: u64 = 0,
    usage: Flags = 0,
    sharingMode: SharingMode = @enumFromInt(0),
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
};
pub const MemoryRequirements = extern struct {
    size: u64 = 0,
    alignment: u64 = 0,
    memoryTypeBits: u32 = 0,
};
pub const MemoryAllocateInfo = extern struct {
    sType: StructureType = @enumFromInt(5),
    pNext: ?*const anyopaque = null,
    allocationSize: u64 = 0,
    memoryTypeIndex: u32 = 0,
};
pub const MappedMemoryRange = extern struct {
    sType: StructureType = @enumFromInt(6),
    pNext: ?*const anyopaque = null,
    memory: DeviceMemory,
    offset: u64 = 0,
    size: u64 = 0,
};
pub const ImageCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(14),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    imageType: ImageType = @enumFromInt(0),
    format: Format = @enumFromInt(0),
    extent: Extent3D,
    mipLevels: u32 = 0,
    arrayLayers: u32 = 0,
    samples: Flags = 0,
    tiling: ImageTiling = @enumFromInt(0),
    usage: Flags = 0,
    sharingMode: SharingMode = @enumFromInt(0),
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
    initialLayout: ImageLayout = @enumFromInt(0),
};
pub const ExternalMemoryImageCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(1000072001),
    pNext: ?*const anyopaque = null,
    handleTypes: Flags = 0,
};
pub const ImageDrmFormatModifierListCreateInfoEXT = extern struct {
    sType: StructureType = @enumFromInt(1000158003),
    pNext: ?*const anyopaque = null,
    drmFormatModifierCount: u32 = 0,
    pDrmFormatModifiers: ?[*]const u64 = null,
};
pub const ImageDrmFormatModifierPropertiesEXT = extern struct {
    sType: StructureType = @enumFromInt(1000158005),
    pNext: ?*anyopaque = null,
    drmFormatModifier: u64 = 0,
};
pub const ExportMemoryAllocateInfo = extern struct {
    sType: StructureType = @enumFromInt(1000072002),
    pNext: ?*const anyopaque = null,
    handleTypes: Flags = 0,
};
pub const MemoryDedicatedAllocateInfo = extern struct {
    sType: StructureType = @enumFromInt(1000127001),
    pNext: ?*const anyopaque = null,
    image: Image,
    buffer: Buffer,
};
pub const MemoryGetFdInfoKHR = extern struct {
    sType: StructureType = @enumFromInt(1000074002),
    pNext: ?*const anyopaque = null,
    memory: DeviceMemory,
    handleType: Flags = 0,
};
pub const ImportMemoryFdInfoKHR = extern struct {
    sType: StructureType = @enumFromInt(1000074000),
    pNext: ?*const anyopaque = null,
    handleType: Flags = 0,
    fd: c_int,
};
pub const MemoryFdPropertiesKHR = extern struct {
    sType: StructureType = @enumFromInt(1000074001),
    pNext: ?*anyopaque = null,
    memoryTypeBits: u32 = 0,
};
pub const ImageDrmFormatModifierExplicitCreateInfoEXT = extern struct {
    sType: StructureType = @enumFromInt(1000158004),
    pNext: ?*const anyopaque = null,
    drmFormatModifier: u64 = 0,
    drmFormatModifierPlaneCount: u32 = 0,
    pPlaneLayouts: ?[*]const SubresourceLayout = null,
};
pub const ImageSubresource = extern struct {
    aspectMask: Flags = 0,
    mipLevel: u32 = 0,
    arrayLayer: u32 = 0,
};
pub const SubresourceLayout = extern struct {
    offset: u64 = 0,
    size: u64 = 0,
    rowPitch: u64 = 0,
    arrayPitch: u64 = 0,
    depthPitch: u64 = 0,
};
pub const ImageViewCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(15),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    image: Image,
    viewType: ImageViewType = @enumFromInt(0),
    format: Format = @enumFromInt(0),
    components: ComponentMapping,
    subresourceRange: ImageSubresourceRange,
};
pub const ComponentMapping = extern struct {
    r: ComponentSwizzle = @enumFromInt(0),
    g: ComponentSwizzle = @enumFromInt(0),
    b: ComponentSwizzle = @enumFromInt(0),
    a: ComponentSwizzle = @enumFromInt(0),
};
pub const ImageSubresourceRange = extern struct {
    aspectMask: Flags = 0,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const ImageSubresourceLayers = extern struct {
    aspectMask: Flags = 0,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const SamplerCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(31),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    magFilter: Filter = @enumFromInt(0),
    minFilter: Filter = @enumFromInt(0),
    mipmapMode: SamplerMipmapMode = @enumFromInt(0),
    addressModeU: SamplerAddressMode = @enumFromInt(0),
    addressModeV: SamplerAddressMode = @enumFromInt(0),
    addressModeW: SamplerAddressMode = @enumFromInt(0),
    mipLodBias: f32 = 0,
    anisotropyEnable: Bool32 = 0,
    maxAnisotropy: f32 = 0,
    compareEnable: Bool32 = 0,
    compareOp: CompareOp = @enumFromInt(0),
    minLod: f32 = 0,
    maxLod: f32 = 0,
    borderColor: BorderColor = @enumFromInt(0),
    unnormalizedCoordinates: Bool32 = 0,
};
pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32 = 0,
    descriptorType: DescriptorType = @enumFromInt(0),
    descriptorCount: u32 = 0,
    stageFlags: Flags = 0,
    pImmutableSamplers: ?[*]const Sampler = null,
};
pub const DescriptorSetLayoutCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(32),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    bindingCount: u32 = 0,
    pBindings: ?[*]const DescriptorSetLayoutBinding = null,
};
pub const DescriptorPoolSize = extern struct {
    type: DescriptorType = @enumFromInt(0),
    descriptorCount: u32 = 0,
};
pub const DescriptorPoolCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(33),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    maxSets: u32 = 0,
    poolSizeCount: u32 = 0,
    pPoolSizes: ?[*]const DescriptorPoolSize = null,
};
pub const DescriptorSetAllocateInfo = extern struct {
    sType: StructureType = @enumFromInt(34),
    pNext: ?*const anyopaque = null,
    descriptorPool: DescriptorPool,
    descriptorSetCount: u32 = 0,
    pSetLayouts: ?[*]const DescriptorSetLayout = null,
};
pub const DescriptorImageInfo = extern struct {
    sampler: Sampler,
    imageView: ImageView,
    imageLayout: ImageLayout = @enumFromInt(0),
};
pub const DescriptorBufferInfo = extern struct {
    buffer: Buffer,
    offset: u64 = 0,
    range: u64 = 0,
};
pub const WriteDescriptorSet = extern struct {
    sType: StructureType = @enumFromInt(35),
    pNext: ?*const anyopaque = null,
    dstSet: DescriptorSet,
    dstBinding: u32 = 0,
    dstArrayElement: u32 = 0,
    descriptorCount: u32 = 0,
    descriptorType: DescriptorType = @enumFromInt(0),
    pImageInfo: ?[*]const DescriptorImageInfo = null,
    pBufferInfo: ?[*]const DescriptorBufferInfo = null,
    pTexelBufferView: ?[*]const BufferView = null,
};
pub const PushConstantRange = extern struct {
    stageFlags: Flags = 0,
    offset: u32 = 0,
    size: u32 = 0,
};
pub const PipelineLayoutCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(30),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    setLayoutCount: u32 = 0,
    pSetLayouts: ?[*]const DescriptorSetLayout = null,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: ?[*]const PushConstantRange = null,
};
pub const ShaderModuleCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(16),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    codeSize: usize = 0,
    pCode: ?[*]const u32 = null,
};
pub const PipelineShaderStageCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(18),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    stage: Flags = 0,
    module: ShaderModule,
    pName: ?[*:0]const u8 = null,
    pSpecializationInfo: ?[*]const SpecializationInfo = null,
};
pub const SpecializationInfo = extern struct {
    mapEntryCount: u32 = 0,
    pMapEntries: ?[*]const SpecializationMapEntry = null,
    dataSize: usize = 0,
    pData: ?*const anyopaque = null,
};
pub const SpecializationMapEntry = extern struct {
    constantID: u32 = 0,
    offset: u32 = 0,
    size: usize = 0,
};
pub const VertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32 = 0,
    inputRate: VertexInputRate = @enumFromInt(0),
};
pub const VertexInputAttributeDescription = extern struct {
    location: u32 = 0,
    binding: u32 = 0,
    format: Format = @enumFromInt(0),
    offset: u32 = 0,
};
pub const PipelineVertexInputStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(19),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    vertexBindingDescriptionCount: u32 = 0,
    pVertexBindingDescriptions: ?[*]const VertexInputBindingDescription = null,
    vertexAttributeDescriptionCount: u32 = 0,
    pVertexAttributeDescriptions: ?[*]const VertexInputAttributeDescription = null,
};
pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(20),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    topology: PrimitiveTopology = @enumFromInt(0),
    primitiveRestartEnable: Bool32 = 0,
};
pub const PipelineViewportStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(22),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    viewportCount: u32 = 0,
    pViewports: ?[*]const Viewport = null,
    scissorCount: u32 = 0,
    pScissors: ?[*]const Rect2D = null,
};
pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minDepth: f32 = 0,
    maxDepth: f32 = 0,
};
pub const PipelineRasterizationStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(23),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    depthClampEnable: Bool32 = 0,
    rasterizerDiscardEnable: Bool32 = 0,
    polygonMode: PolygonMode = @enumFromInt(0),
    cullMode: Flags = 0,
    frontFace: FrontFace = @enumFromInt(0),
    depthBiasEnable: Bool32 = 0,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 0,
};
pub const PipelineMultisampleStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(24),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    rasterizationSamples: Flags = 0,
    sampleShadingEnable: Bool32 = 0,
    minSampleShading: f32 = 0,
    pSampleMask: ?[*]const u32 = null,
    alphaToCoverageEnable: Bool32 = 0,
    alphaToOneEnable: Bool32 = 0,
};
pub const PipelineColorBlendAttachmentState = extern struct {
    blendEnable: Bool32 = 0,
    srcColorBlendFactor: BlendFactor = @enumFromInt(0),
    dstColorBlendFactor: BlendFactor = @enumFromInt(0),
    colorBlendOp: BlendOp = @enumFromInt(0),
    srcAlphaBlendFactor: BlendFactor = @enumFromInt(0),
    dstAlphaBlendFactor: BlendFactor = @enumFromInt(0),
    alphaBlendOp: BlendOp = @enumFromInt(0),
    colorWriteMask: Flags = 0,
};
pub const PipelineColorBlendStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(26),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    logicOpEnable: Bool32 = 0,
    logicOp: LogicOp = @enumFromInt(0),
    attachmentCount: u32 = 0,
    pAttachments: ?[*]const PipelineColorBlendAttachmentState = null,
    blendConstants: [4]f32,
};
pub const PipelineDynamicStateCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(27),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    dynamicStateCount: u32 = 0,
    pDynamicStates: ?[*]const DynamicState = null,
};
pub const GraphicsPipelineCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(28),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    stageCount: u32 = 0,
    pStages: ?[*]const PipelineShaderStageCreateInfo = null,
    pVertexInputState: ?[*]const PipelineVertexInputStateCreateInfo = null,
    pInputAssemblyState: ?[*]const PipelineInputAssemblyStateCreateInfo = null,
    pTessellationState: ?*const PipelineTessellationStateCreateInfo = null,
    pViewportState: ?[*]const PipelineViewportStateCreateInfo = null,
    pRasterizationState: ?[*]const PipelineRasterizationStateCreateInfo = null,
    pMultisampleState: ?[*]const PipelineMultisampleStateCreateInfo = null,
    pDepthStencilState: ?*const PipelineDepthStencilStateCreateInfo = null,
    pColorBlendState: ?[*]const PipelineColorBlendStateCreateInfo = null,
    pDynamicState: ?[*]const PipelineDynamicStateCreateInfo = null,
    layout: PipelineLayout,
    renderPass: RenderPass,
    subpass: u32 = 0,
    basePipelineHandle: Pipeline,
    basePipelineIndex: i32 = 0,
};
pub const AttachmentDescription = extern struct {
    flags: Flags = 0,
    format: Format = @enumFromInt(0),
    samples: Flags = 0,
    loadOp: AttachmentLoadOp = @enumFromInt(0),
    storeOp: AttachmentStoreOp = @enumFromInt(0),
    stencilLoadOp: AttachmentLoadOp = @enumFromInt(0),
    stencilStoreOp: AttachmentStoreOp = @enumFromInt(0),
    initialLayout: ImageLayout = @enumFromInt(0),
    finalLayout: ImageLayout = @enumFromInt(0),
};
pub const AttachmentReference = extern struct {
    attachment: u32 = 0,
    layout: ImageLayout = @enumFromInt(0),
};
pub const SubpassDescription = extern struct {
    flags: Flags = 0,
    pipelineBindPoint: PipelineBindPoint = @enumFromInt(0),
    inputAttachmentCount: u32 = 0,
    pInputAttachments: ?[*]const AttachmentReference = null,
    colorAttachmentCount: u32 = 0,
    pColorAttachments: ?[*]const AttachmentReference = null,
    pResolveAttachments: ?[*]const AttachmentReference = null,
    pDepthStencilAttachment: ?[*]const AttachmentReference = null,
    preserveAttachmentCount: u32 = 0,
    pPreserveAttachments: ?[*]const u32 = null,
};
pub const SubpassDependency = extern struct {
    srcSubpass: u32 = 0,
    dstSubpass: u32 = 0,
    srcStageMask: Flags = 0,
    dstStageMask: Flags = 0,
    srcAccessMask: Flags = 0,
    dstAccessMask: Flags = 0,
    dependencyFlags: Flags = 0,
};
pub const RenderPassCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(38),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    attachmentCount: u32 = 0,
    pAttachments: ?[*]const AttachmentDescription = null,
    subpassCount: u32 = 0,
    pSubpasses: ?[*]const SubpassDescription = null,
    dependencyCount: u32 = 0,
    pDependencies: ?[*]const SubpassDependency = null,
};
pub const FramebufferCreateInfo = extern struct {
    sType: StructureType = @enumFromInt(37),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    renderPass: RenderPass,
    attachmentCount: u32 = 0,
    pAttachments: ?[*]const ImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    layers: u32 = 0,
};
pub const RenderPassBeginInfo = extern struct {
    sType: StructureType = @enumFromInt(43),
    pNext: ?*const anyopaque = null,
    renderPass: RenderPass,
    framebuffer: Framebuffer,
    renderArea: Rect2D,
    clearValueCount: u32 = 0,
    pClearValues: ?[*]const ClearValue = null,
};
pub const ClearValue = extern union {
    color: ClearColorValue,
    depthStencil: ClearDepthStencilValue,
};
pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};
pub const ClearDepthStencilValue = extern struct {
    depth: f32 = 0,
    stencil: u32 = 0,
};
pub const ClearAttachment = extern struct {
    aspectMask: Flags = 0,
    colorAttachment: u32 = 0,
    clearValue: ClearValue,
};
pub const ClearRect = extern struct {
    rect: Rect2D,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const ImageMemoryBarrier = extern struct {
    sType: StructureType = @enumFromInt(45),
    pNext: ?*const anyopaque = null,
    srcAccessMask: Flags = 0,
    dstAccessMask: Flags = 0,
    oldLayout: ImageLayout = @enumFromInt(0),
    newLayout: ImageLayout = @enumFromInt(0),
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    image: Image,
    subresourceRange: ImageSubresourceRange,
};
pub const MemoryBarrier = extern struct {
    sType: StructureType = @enumFromInt(46),
    pNext: ?*const anyopaque = null,
    srcAccessMask: Flags = 0,
    dstAccessMask: Flags = 0,
};
pub const BufferMemoryBarrier = extern struct {
    sType: StructureType = @enumFromInt(44),
    pNext: ?*const anyopaque = null,
    srcAccessMask: Flags = 0,
    dstAccessMask: Flags = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    buffer: Buffer,
    offset: u64 = 0,
    size: u64 = 0,
};
pub const BufferImageCopy = extern struct {
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: ImageSubresourceLayers,
    imageOffset: Offset3D,
    imageExtent: Extent3D,
};
pub const ImageCopy = extern struct {
    srcSubresource: ImageSubresourceLayers,
    srcOffset: Offset3D,
    dstSubresource: ImageSubresourceLayers,
    dstOffset: Offset3D,
    extent: Extent3D,
};
pub const ImageBlit = extern struct {
    srcSubresource: ImageSubresourceLayers,
    srcOffsets: [2]Offset3D,
    dstSubresource: ImageSubresourceLayers,
    dstOffsets: [2]Offset3D,
};
pub const DebugUtilsMessengerCreateInfoEXT = extern struct {
    sType: StructureType = @enumFromInt(1000128004),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    messageSeverity: Flags = 0,
    messageType: Flags = 0,
    pfnUserCallback: ?PfnDebugUtilsMessengerCallbackEXT = null,
    pUserData: ?*anyopaque = null,
};
pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    sType: StructureType = @enumFromInt(1000128003),
    pNext: ?*const anyopaque = null,
    flags: Flags = 0,
    pMessageIdName: ?[*:0]const u8 = null,
    messageIdNumber: i32 = 0,
    pMessage: ?[*:0]const u8 = null,
    queueLabelCount: u32 = 0,
    pQueueLabels: ?[*]const DebugUtilsLabelEXT = null,
    cmdBufLabelCount: u32 = 0,
    pCmdBufLabels: ?[*]const DebugUtilsLabelEXT = null,
    objectCount: u32 = 0,
    pObjects: ?[*]const DebugUtilsObjectNameInfoEXT = null,
};
pub const DebugUtilsLabelEXT = extern struct {
    sType: StructureType = @enumFromInt(1000128002),
    pNext: ?*const anyopaque = null,
    pLabelName: ?[*:0]const u8 = null,
    color: [4]f32,
};
pub const DebugUtilsObjectNameInfoEXT = extern struct {
    sType: StructureType = @enumFromInt(1000128000),
    pNext: ?*const anyopaque = null,
    objectType: ObjectType = @enumFromInt(0),
    objectHandle: u64 = 0,
    pObjectName: ?[*:0]const u8 = null,
};
pub const MemoryDedicatedRequirements = extern struct {
    sType: StructureType = @enumFromInt(1000127000),
    pNext: ?*anyopaque = null,
    prefersDedicatedAllocation: Bool32 = 0,
    requiresDedicatedAllocation: Bool32 = 0,
};
pub const MemoryRequirements2 = extern struct {
    sType: StructureType = @enumFromInt(1000146003),
    pNext: ?*anyopaque = null,
    memoryRequirements: MemoryRequirements,
};
pub const ImageMemoryRequirementsInfo2 = extern struct {
    sType: StructureType = @enumFromInt(1000146001),
    pNext: ?*const anyopaque = null,
    image: Image,
};

// ---- Function pointers ------------------------------------------------------------------------
const Cb = ?*const AllocationCallbacks;

pub const PfnGetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;
pub const PfnGetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void;

/// Entry points available before an instance exists.
pub const BaseDispatch = struct {
    vkCreateInstance: *const fn (*const InstanceCreateInfo, Cb, *Instance) callconv(.c) Result,
    vkEnumerateInstanceExtensionProperties: *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result,
    vkEnumerateInstanceLayerProperties: *const fn (*u32, ?[*]LayerProperties) callconv(.c) Result,
    vkEnumerateInstanceVersion: ?*const fn (*u32) callconv(.c) Result,
};

pub const InstanceDispatch = struct {
    vkDestroyInstance: *const fn (Instance, Cb) callconv(.c) void,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result,
    vkGetPhysicalDeviceProperties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void,
    vkGetPhysicalDeviceProperties2: *const fn (PhysicalDevice, *PhysicalDeviceProperties2) callconv(.c) void,
    vkGetPhysicalDeviceFeatures: *const fn (PhysicalDevice, *PhysicalDeviceFeatures) callconv(.c) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void,
    vkGetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void,
    vkGetPhysicalDeviceFormatProperties: *const fn (PhysicalDevice, Format, *FormatProperties) callconv(.c) void,
    vkGetPhysicalDeviceFormatProperties2: *const fn (PhysicalDevice, Format, *FormatProperties2) callconv(.c) void,
    vkGetPhysicalDeviceImageFormatProperties2: *const fn (PhysicalDevice, *const PhysicalDeviceImageFormatInfo2, *ImageFormatProperties2) callconv(.c) Result,
    vkGetPhysicalDeviceExternalSemaphoreProperties: *const fn (PhysicalDevice, *const PhysicalDeviceExternalSemaphoreInfo, *ExternalSemaphoreProperties) callconv(.c) void,
    vkEnumerateDeviceExtensionProperties: *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, Cb, *Device) callconv(.c) Result,
    vkGetDeviceProcAddr: PfnGetDeviceProcAddr,
    vkCreateDebugUtilsMessengerEXT: ?*const fn (Instance, *const DebugUtilsMessengerCreateInfoEXT, Cb, *DebugUtilsMessengerEXT) callconv(.c) Result = null,
    vkDestroyDebugUtilsMessengerEXT: ?*const fn (Instance, DebugUtilsMessengerEXT, Cb) callconv(.c) void = null,
};

pub const DeviceDispatch = struct {
    vkDestroyDevice: *const fn (Device, Cb) callconv(.c) void,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(.c) void,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) Result,
    vkQueueSubmit: *const fn (Queue, u32, ?[*]const SubmitInfo, Fence) callconv(.c) Result,
    vkQueueWaitIdle: *const fn (Queue) callconv(.c) Result,

    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, Cb, *CommandPool) callconv(.c) Result,
    vkDestroyCommandPool: *const fn (Device, CommandPool, Cb) callconv(.c) void,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(.c) Result,
    vkFreeCommandBuffers: *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(.c) void,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(.c) Result,
    vkResetCommandBuffer: *const fn (CommandBuffer, Flags) callconv(.c) Result,

    vkCreateFence: *const fn (Device, *const FenceCreateInfo, Cb, *Fence) callconv(.c) Result,
    vkDestroyFence: *const fn (Device, Fence, Cb) callconv(.c) void,
    vkWaitForFences: *const fn (Device, u32, [*]const Fence, Bool32, u64) callconv(.c) Result,
    vkResetFences: *const fn (Device, u32, [*]const Fence) callconv(.c) Result,
    vkGetFenceStatus: *const fn (Device, Fence) callconv(.c) Result,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, Cb, *Semaphore) callconv(.c) Result,
    vkDestroySemaphore: *const fn (Device, Semaphore, Cb) callconv(.c) void,

    vkAllocateMemory: *const fn (Device, *const MemoryAllocateInfo, Cb, *DeviceMemory) callconv(.c) Result,
    vkFreeMemory: *const fn (Device, DeviceMemory, Cb) callconv(.c) void,
    vkMapMemory: *const fn (Device, DeviceMemory, u64, u64, Flags, *?*anyopaque) callconv(.c) Result,
    vkUnmapMemory: *const fn (Device, DeviceMemory) callconv(.c) void,
    vkFlushMappedMemoryRanges: *const fn (Device, u32, [*]const MappedMemoryRange) callconv(.c) Result,
    vkInvalidateMappedMemoryRanges: *const fn (Device, u32, [*]const MappedMemoryRange) callconv(.c) Result,

    vkCreateBuffer: *const fn (Device, *const BufferCreateInfo, Cb, *Buffer) callconv(.c) Result,
    vkDestroyBuffer: *const fn (Device, Buffer, Cb) callconv(.c) void,
    vkGetBufferMemoryRequirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(.c) void,
    vkBindBufferMemory: *const fn (Device, Buffer, DeviceMemory, u64) callconv(.c) Result,
    vkCreateImage: *const fn (Device, *const ImageCreateInfo, Cb, *Image) callconv(.c) Result,
    vkDestroyImage: *const fn (Device, Image, Cb) callconv(.c) void,
    vkGetImageMemoryRequirements: *const fn (Device, Image, *MemoryRequirements) callconv(.c) void,
    vkGetImageMemoryRequirements2: *const fn (Device, *const ImageMemoryRequirementsInfo2, *MemoryRequirements2) callconv(.c) void,
    vkBindImageMemory: *const fn (Device, Image, DeviceMemory, u64) callconv(.c) Result,
    vkGetImageSubresourceLayout: *const fn (Device, Image, *const ImageSubresource, *SubresourceLayout) callconv(.c) void,
    vkCreateImageView: *const fn (Device, *const ImageViewCreateInfo, Cb, *ImageView) callconv(.c) Result,
    vkDestroyImageView: *const fn (Device, ImageView, Cb) callconv(.c) void,
    vkCreateSampler: *const fn (Device, *const SamplerCreateInfo, Cb, *Sampler) callconv(.c) Result,
    vkDestroySampler: *const fn (Device, Sampler, Cb) callconv(.c) void,

    vkCreateDescriptorSetLayout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, Cb, *DescriptorSetLayout) callconv(.c) Result,
    vkDestroyDescriptorSetLayout: *const fn (Device, DescriptorSetLayout, Cb) callconv(.c) void,
    vkCreateDescriptorPool: *const fn (Device, *const DescriptorPoolCreateInfo, Cb, *DescriptorPool) callconv(.c) Result,
    vkDestroyDescriptorPool: *const fn (Device, DescriptorPool, Cb) callconv(.c) void,
    vkAllocateDescriptorSets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(.c) Result,
    vkFreeDescriptorSets: *const fn (Device, DescriptorPool, u32, [*]const DescriptorSet) callconv(.c) Result,
    vkUpdateDescriptorSets: *const fn (Device, u32, ?[*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    vkCreatePipelineLayout: *const fn (Device, *const PipelineLayoutCreateInfo, Cb, *PipelineLayout) callconv(.c) Result,
    vkDestroyPipelineLayout: *const fn (Device, PipelineLayout, Cb) callconv(.c) void,
    vkCreateShaderModule: *const fn (Device, *const ShaderModuleCreateInfo, Cb, *ShaderModule) callconv(.c) Result,
    vkDestroyShaderModule: *const fn (Device, ShaderModule, Cb) callconv(.c) void,
    vkCreateGraphicsPipelines: *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, Cb, [*]Pipeline) callconv(.c) Result,
    vkDestroyPipeline: *const fn (Device, Pipeline, Cb) callconv(.c) void,
    vkCreateRenderPass: *const fn (Device, *const RenderPassCreateInfo, Cb, *RenderPass) callconv(.c) Result,
    vkDestroyRenderPass: *const fn (Device, RenderPass, Cb) callconv(.c) void,
    vkCreateFramebuffer: *const fn (Device, *const FramebufferCreateInfo, Cb, *Framebuffer) callconv(.c) Result,
    vkDestroyFramebuffer: *const fn (Device, Framebuffer, Cb) callconv(.c) void,

    vkCmdBeginRenderPass: *const fn (CommandBuffer, *const RenderPassBeginInfo, SubpassContents) callconv(.c) void,
    vkCmdEndRenderPass: *const fn (CommandBuffer) callconv(.c) void,
    vkCmdBindPipeline: *const fn (CommandBuffer, PipelineBindPoint, Pipeline) callconv(.c) void,
    vkCmdBindDescriptorSets: *const fn (CommandBuffer, PipelineBindPoint, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    vkCmdBindVertexBuffers: *const fn (CommandBuffer, u32, u32, [*]const Buffer, [*]const u64) callconv(.c) void,
    vkCmdDraw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    vkCmdSetViewport: *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(.c) void,
    vkCmdSetScissor: *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(.c) void,
    vkCmdPushConstants: *const fn (CommandBuffer, PipelineLayout, Flags, u32, u32, *const anyopaque) callconv(.c) void,
    vkCmdPipelineBarrier: *const fn (CommandBuffer, Flags, Flags, Flags, u32, ?[*]const MemoryBarrier, u32, ?[*]const BufferMemoryBarrier, u32, ?[*]const ImageMemoryBarrier) callconv(.c) void,
    vkCmdCopyBufferToImage: *const fn (CommandBuffer, Buffer, Image, ImageLayout, u32, [*]const BufferImageCopy) callconv(.c) void,
    vkCmdCopyImageToBuffer: *const fn (CommandBuffer, Image, ImageLayout, Buffer, u32, [*]const BufferImageCopy) callconv(.c) void,
    vkCmdCopyImage: *const fn (CommandBuffer, Image, ImageLayout, Image, ImageLayout, u32, [*]const ImageCopy) callconv(.c) void,
    vkCmdBlitImage: *const fn (CommandBuffer, Image, ImageLayout, Image, ImageLayout, u32, [*]const ImageBlit, Filter) callconv(.c) void,
    vkCmdClearAttachments: *const fn (CommandBuffer, u32, [*]const ClearAttachment, u32, [*]const ClearRect) callconv(.c) void,

    // Extensions (null when the extension is not enabled).
    vkGetMemoryFdKHR: ?*const fn (Device, *const MemoryGetFdInfoKHR, *c_int) callconv(.c) Result = null,
    vkGetSemaphoreFdKHR: ?*const fn (Device, *const SemaphoreGetFdInfoKHR, *c_int) callconv(.c) Result = null,
    vkImportSemaphoreFdKHR: ?*const fn (Device, *const ImportSemaphoreFdInfoKHR) callconv(.c) Result = null,
    vkGetImageDrmFormatModifierPropertiesEXT: ?*const fn (Device, Image, *ImageDrmFormatModifierPropertiesEXT) callconv(.c) Result = null,
    vkGetMemoryFdPropertiesKHR: ?*const fn (Device, Flags, c_int, *MemoryFdPropertiesKHR) callconv(.c) Result = null,
};

/// Fills every function-pointer field of `T` by name. Required (non-optional) entries that
/// the driver does not expose produce `error.VulkanEntryPointMissing`.
pub fn loadDispatch(comptime T: type, handle: anytype, getProcAddr: anytype) error{VulkanEntryPointMissing}!T {
    var table: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const raw = getProcAddr(handle, field.name ++ "");
        const is_optional = @typeInfo(field.type) == .optional;
        if (is_optional) {
            @field(table, field.name) = if (raw) |p| @ptrCast(p) else null;
        } else {
            const p = raw orelse {
                std.log.scoped(.gpu).err("missing Vulkan entry point {s}", .{field.name});
                return error.VulkanEntryPointMissing;
            };
            @field(table, field.name) = @ptrCast(p);
        }
    }
    return table;
}

/// The dlopened system loader.
pub const Loader = struct {
    lib: std.DynLib,
    getInstanceProcAddr: PfnGetInstanceProcAddr,
    base: BaseDispatch,

    pub const OpenError = error{ VulkanLoaderNotFound, VulkanEntryPointMissing };

    pub fn open() OpenError!Loader {
        const candidates = [_][:0]const u8{ "libvulkan.so.1", "libvulkan.so" };
        for (candidates) |name| {
            var lib = std.DynLib.openZ(name.ptr) catch continue;
            const gipa = lib.lookup(PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
                lib.close();
                continue;
            };
            const base = try loadDispatch(BaseDispatch, Instance.null_handle, gipa);
            return .{ .lib = lib, .getInstanceProcAddr = gipa, .base = base };
        }
        return error.VulkanLoaderNotFound;
    }

    pub fn close(self: *Loader) void {
        self.lib.close();
    }
};

/// Zero-terminated fixed-size C string field -> slice.
pub fn cstr(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}
