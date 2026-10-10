//! Vulkan instance + device + queue, loaded at runtime (no build-time Vulkan dependency).
//!
//! `Context.init` fails with a clear error (`error.VulkanLoaderNotFound`, `error.NoSuitableGpu`,
//! ...) when Vulkan is unavailable so the host can fall back to a CPU path.

const std = @import("std");
const vk = @import("vk.zig");

const log = std.log.scoped(.gpu);

pub const Options = struct {
    app_name: [:0]const u8 = "palette",
    /// `null`: honour `PALETTE_VK_VALIDATION=1`. Validation is only enabled when the Khronos
    /// layer is installed.
    validation: ?bool = null,
    /// dev_t of the device the compositor wants buffers on (`present.DmabufFeedback.main_device`).
    /// Matched against VK_EXT_physical_device_drm primary/render nodes.
    preferred_device: ?u64 = null,
    /// Fail init when dma-buf export is not available (otherwise only offscreen targets work).
    require_dmabuf: bool = false,
};

pub const Caps = struct {
    api_version: u32 = 0,
    /// VK_KHR_external_memory_fd + VK_EXT_external_memory_dma_buf.
    dmabuf_export: bool = false,
    /// VK_EXT_image_drm_format_modifier (otherwise only LINEAR images can be exported).
    drm_format_modifier: bool = false,
    /// VK_KHR_external_semaphore_fd with SYNC_FD export / import.
    sync_fd_export: bool = false,
    sync_fd_import: bool = false,
    /// VK_EXT_queue_family_foreign (otherwise VK_QUEUE_FAMILY_EXTERNAL is used for transfers).
    queue_family_foreign: bool = false,
    physical_device_drm: bool = false,
    sampler_anisotropy: bool = false,
    max_anisotropy: f32 = 1,
    max_image_dimension_2d: u32 = 4096,
    non_coherent_atom_size: u64 = 64,
    /// Linear-filter blits for B8G8R8A8/R8G8B8A8 (mip generation).
    blit_rgba8: bool = false,
    blit_bgra8: bool = false,
};

pub const DrmNode = struct {
    has_primary: bool = false,
    has_render: bool = false,
    primary_major: i64 = 0,
    primary_minor: i64 = 0,
    render_major: i64 = 0,
    render_minor: i64 = 0,
};

pub const MemoryStats = @import("../core.zig").MemoryStats;

pub const Allocation = struct {
    memory: vk.DeviceMemory = .null_handle,
    size: u64 = 0,
    type_index: u32 = 0,
    mapped: ?[*]u8 = null,
    coherent: bool = true,
    device_local: bool = false,
};

/// Linux dev_t encoding (glibc `gnu_dev_major/minor`).
pub fn devMajor(dev: u64) u64 {
    return ((dev >> 8) & 0xfff) | ((dev >> 32) & ~@as(u64, 0xfff));
}
pub fn devMinor(dev: u64) u64 {
    return (dev & 0xff) | ((dev >> 12) & ~@as(u64, 0xff));
}

pub const InitError = error{
    VulkanLoaderNotFound,
    VulkanEntryPointMissing,
    VulkanTooOld,
    NoSuitableGpu,
    DmabufUnsupported,
    OutOfMemory,
} || vk.Error;

pub const Context = struct {
    gpa: std.mem.Allocator,
    loader: vk.Loader,
    instance: vk.Instance,
    vki: vk.InstanceDispatch,
    messenger: vk.DebugUtilsMessengerEXT = .null_handle,
    physical: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    drm: DrmNode = .{},
    device: vk.Device,
    vkd: vk.DeviceDispatch,
    queue: vk.Queue,
    queue_family: u32,
    caps: Caps,
    memory: MemoryStats = .{},

    /// Monotonic submission counter; `completed_serial` trails it. Resources retired at serial S
    /// are destroyed once `completed_serial >= S`.
    submit_serial: u64 = 0,
    completed_serial: u64 = 0,
    garbage: std.ArrayList(Garbage) = .empty,

    pub fn init(gpa: std.mem.Allocator, options: Options) InitError!*Context {
        var loader = try vk.Loader.open();
        errdefer loader.close();

        var loader_version: u32 = vk.makeApiVersion(0, 1, 0, 0);
        if (loader.base.vkEnumerateInstanceVersion) |f| _ = f(&loader_version);
        if (loader_version < vk.api_version_1_1) {
            log.err("Vulkan loader {d}.{d} is too old (need 1.1)", .{ vk.apiVersionMajor(loader_version), vk.apiVersionMinor(loader_version) });
            return error.VulkanTooOld;
        }
        const api_version = @min(loader_version, vk.api_version_1_3);

        // Instance extensions / layers.
        var inst_exts: [4][*:0]const u8 = undefined;
        var inst_ext_count: u32 = 0;
        var layers: [1][*:0]const u8 = undefined;
        var layer_count: u32 = 0;
        const want_validation = options.validation orelse envFlag("PALETTE_VK_VALIDATION");
        if (want_validation) {
            if (try hasInstanceLayer(gpa, &loader, "VK_LAYER_KHRONOS_validation")) {
                layers[0] = "VK_LAYER_KHRONOS_validation";
                layer_count = 1;
            } else {
                log.warn("PALETTE_VK_VALIDATION=1 but VK_LAYER_KHRONOS_validation is not installed", .{});
            }
        }
        const debug_utils = want_validation and try hasInstanceExtension(gpa, &loader, "VK_EXT_debug_utils");
        if (debug_utils) {
            inst_exts[inst_ext_count] = "VK_EXT_debug_utils";
            inst_ext_count += 1;
        }

        const app_info: vk.ApplicationInfo = .{
            .pApplicationName = options.app_name.ptr,
            .applicationVersion = 1,
            .pEngineName = "palette",
            .engineVersion = 1,
            .apiVersion = api_version,
        };
        const inst_info: vk.InstanceCreateInfo = .{
            .pApplicationInfo = @ptrCast(&app_info),
            .enabledLayerCount = layer_count,
            .ppEnabledLayerNames = &layers,
            .enabledExtensionCount = inst_ext_count,
            .ppEnabledExtensionNames = &inst_exts,
        };
        var instance: vk.Instance = .null_handle;
        try vk.check(loader.base.vkCreateInstance(&inst_info, null, &instance));
        const vki = vk.loadDispatch(vk.InstanceDispatch, instance, loader.getInstanceProcAddr) catch |err| {
            if (@as(?*const fn (vk.Instance, ?*const vk.AllocationCallbacks) callconv(.c) void, @ptrCast(loader.getInstanceProcAddr(instance, "vkDestroyInstance")))) |destroy| destroy(instance, null);
            return err;
        };
        errdefer vki.vkDestroyInstance(instance, null);

        var messenger: vk.DebugUtilsMessengerEXT = .null_handle;
        if (debug_utils) if (vki.vkCreateDebugUtilsMessengerEXT) |create| {
            const info: vk.DebugUtilsMessengerCreateInfoEXT = .{
                .messageSeverity = vk.DebugUtilsMessageSeverityFlagsEXT.warning | vk.DebugUtilsMessageSeverityFlagsEXT.@"error",
                .messageType = vk.DebugUtilsMessageTypeFlagsEXT.general | vk.DebugUtilsMessageTypeFlagsEXT.validation | vk.DebugUtilsMessageTypeFlagsEXT.performance,
                .pfnUserCallback = debugCallback,
            };
            _ = create(instance, &info, null, &messenger);
        };
        errdefer if (messenger != .null_handle) vki.vkDestroyDebugUtilsMessengerEXT.?(instance, messenger, null);

        const pick = try pickPhysicalDevice(gpa, vki, instance, options.preferred_device);
        const physical = pick.device;

        var props: vk.PhysicalDeviceProperties = undefined;
        vki.vkGetPhysicalDeviceProperties(physical, &props);
        var mem_props: vk.PhysicalDeviceMemoryProperties = undefined;
        vki.vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);
        var features: vk.PhysicalDeviceFeatures = undefined;
        vki.vkGetPhysicalDeviceFeatures(physical, &features);

        // Device extensions.
        const dev_exts = try deviceExtensions(gpa, vki, physical);
        defer gpa.free(dev_exts);
        const has = struct {
            fn f(list: []const vk.ExtensionProperties, name: []const u8) bool {
                for (list) |e| if (std.mem.eql(u8, vk.cstr(&e.extensionName), name)) return true;
                return false;
            }
        }.f;
        var enabled: [8][*:0]const u8 = undefined;
        var enabled_count: u32 = 0;
        var caps: Caps = .{ .api_version = @min(api_version, props.apiVersion) };
        const enable = struct {
            fn f(list: []const vk.ExtensionProperties, out: *[8][*:0]const u8, n: *u32, name: [:0]const u8) bool {
                if (!has(list, name)) return false;
                out[n.*] = name.ptr;
                n.* += 1;
                return true;
            }
        }.f;
        const mem_fd = enable(dev_exts, &enabled, &enabled_count, "VK_KHR_external_memory_fd");
        const dma_buf = mem_fd and enable(dev_exts, &enabled, &enabled_count, "VK_EXT_external_memory_dma_buf");
        caps.dmabuf_export = mem_fd and dma_buf;
        if (caps.dmabuf_export) {
            const needs_format_list = caps.api_version < vk.api_version_1_2;
            const format_list_ok = !needs_format_list or enable(dev_exts, &enabled, &enabled_count, "VK_KHR_image_format_list");
            if (format_list_ok) caps.drm_format_modifier = enable(dev_exts, &enabled, &enabled_count, "VK_EXT_image_drm_format_modifier");
            caps.queue_family_foreign = enable(dev_exts, &enabled, &enabled_count, "VK_EXT_queue_family_foreign");
        }
        const sem_fd = enable(dev_exts, &enabled, &enabled_count, "VK_KHR_external_semaphore_fd");
        caps.physical_device_drm = pick.drm != null;
        if (sem_fd) {
            const ext_info: vk.PhysicalDeviceExternalSemaphoreInfo = .{ .handleType = vk.ExternalSemaphoreHandleTypeFlags.sync_fd };
            var ext_props: vk.ExternalSemaphoreProperties = .{};
            vki.vkGetPhysicalDeviceExternalSemaphoreProperties(physical, &ext_info, &ext_props);
            const feats = ext_props.externalSemaphoreFeatures;
            caps.sync_fd_export = feats & vk.ExternalSemaphoreFeatureFlags.exportable != 0;
            caps.sync_fd_import = feats & vk.ExternalSemaphoreFeatureFlags.importable != 0;
        }
        if (options.require_dmabuf and !caps.dmabuf_export) return error.DmabufUnsupported;

        caps.sampler_anisotropy = features.samplerAnisotropy != 0;
        caps.max_anisotropy = @min(props.limits.maxSamplerAnisotropy, 8.0);
        caps.max_image_dimension_2d = props.limits.maxImageDimension2D;
        caps.non_coherent_atom_size = @max(props.limits.nonCoherentAtomSize, 1);
        caps.blit_rgba8 = formatCanBlit(vki, physical, .r8g8b8a8_unorm);
        caps.blit_bgra8 = formatCanBlit(vki, physical, .b8g8r8a8_unorm);

        var enabled_features = std.mem.zeroes(vk.PhysicalDeviceFeatures);
        enabled_features.samplerAnisotropy = features.samplerAnisotropy;
        const priority: f32 = 1.0;
        const queue_info: vk.DeviceQueueCreateInfo = .{
            .queueFamilyIndex = pick.queue_family,
            .queueCount = 1,
            .pQueuePriorities = @ptrCast(&priority),
        };
        const device_info: vk.DeviceCreateInfo = .{
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = @ptrCast(&queue_info),
            .enabledExtensionCount = enabled_count,
            .ppEnabledExtensionNames = &enabled,
            .pEnabledFeatures = @ptrCast(&enabled_features),
        };
        var device: vk.Device = .null_handle;
        try vk.check(vki.vkCreateDevice(physical, &device_info, null, &device));
        const vkd = vk.loadDispatch(vk.DeviceDispatch, device, vki.vkGetDeviceProcAddr) catch |err| {
            if (@as(?*const fn (vk.Device, ?*const vk.AllocationCallbacks) callconv(.c) void, @ptrCast(vki.vkGetDeviceProcAddr(device, "vkDestroyDevice")))) |destroy| destroy(device, null);
            return err;
        };
        errdefer vkd.vkDestroyDevice(device, null);
        if (caps.dmabuf_export and vkd.vkGetMemoryFdKHR == null) caps.dmabuf_export = false;
        if (caps.drm_format_modifier and vkd.vkGetImageDrmFormatModifierPropertiesEXT == null) caps.drm_format_modifier = false;
        if (vkd.vkGetSemaphoreFdKHR == null) caps.sync_fd_export = false;
        if (vkd.vkImportSemaphoreFdKHR == null) caps.sync_fd_import = false;

        var queue: vk.Queue = .null_handle;
        vkd.vkGetDeviceQueue(device, pick.queue_family, 0, &queue);

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .loader = loader,
            .instance = instance,
            .vki = vki,
            .messenger = messenger,
            .physical = physical,
            .props = props,
            .mem_props = mem_props,
            .drm = pick.drm orelse .{},
            .device = device,
            .vkd = vkd,
            .queue = queue,
            .queue_family = pick.queue_family,
            .caps = caps,
        };
        log.info("Vulkan device: {s} (api {d}.{d}, dmabuf={}, modifiers={}, sync_fd={}/{})", .{
            self.deviceName(),               vk.apiVersionMajor(caps.api_version), vk.apiVersionMinor(caps.api_version),
            caps.dmabuf_export,              caps.drm_format_modifier,             caps.sync_fd_export,
            caps.sync_fd_import,
        });
        return self;
    }

    pub fn deinit(self: *Context) void {
        _ = self.vkd.vkDeviceWaitIdle(self.device);
        self.completed_serial = self.submit_serial;
        self.collectGarbage();
        self.garbage.deinit(self.gpa);
        self.vkd.vkDestroyDevice(self.device, null);
        if (self.messenger != .null_handle) self.vki.vkDestroyDebugUtilsMessengerEXT.?(self.instance, self.messenger, null);
        self.vki.vkDestroyInstance(self.instance, null);
        self.loader.close();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn deviceName(self: *const Context) []const u8 {
        return vk.cstr(&self.props.deviceName);
    }

    // ---- Memory ---------------------------------------------------------------------------

    pub fn findMemoryType(self: *const Context, type_bits: u32, required: vk.Flags, preferred: vk.Flags) ?u32 {
        var fallback: ?u32 = null;
        for (0..self.mem_props.memoryTypeCount) |i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const flags = self.mem_props.memoryTypes[i].propertyFlags;
            if (flags & required != required) continue;
            if (flags & preferred == preferred) return @intCast(i);
            if (fallback == null) fallback = @intCast(i);
        }
        return fallback;
    }

    /// Allocates (and maps, when host-visible) one VkDeviceMemory block. Palette's resource
    /// count is small (tens), so each resource gets its own allocation.
    pub fn allocate(self: *Context, reqs: vk.MemoryRequirements, required: vk.Flags, preferred: vk.Flags, p_next: ?*const anyopaque) !Allocation {
        const type_index = self.findMemoryType(reqs.memoryTypeBits, required, preferred) orelse return error.NoSuitableMemoryType;
        const info: vk.MemoryAllocateInfo = .{
            .pNext = p_next,
            .allocationSize = reqs.size,
            .memoryTypeIndex = type_index,
        };
        var memory: vk.DeviceMemory = .null_handle;
        try vk.check(self.vkd.vkAllocateMemory(self.device, &info, null, &memory));
        errdefer self.vkd.vkFreeMemory(self.device, memory, null);
        const flags = self.mem_props.memoryTypes[type_index].propertyFlags;
        var result: Allocation = .{
            .memory = memory,
            .size = reqs.size,
            .type_index = type_index,
            .coherent = flags & vk.MemoryPropertyFlags.host_coherent != 0,
            .device_local = flags & vk.MemoryPropertyFlags.device_local != 0,
        };
        if (flags & vk.MemoryPropertyFlags.host_visible != 0) {
            var ptr: ?*anyopaque = null;
            try vk.check(self.vkd.vkMapMemory(self.device, memory, 0, vk.whole_size, 0, &ptr));
            result.mapped = @ptrCast(ptr);
            self.memory.host_visible_bytes += reqs.size;
        }
        if (result.device_local) self.memory.device_local_bytes += reqs.size;
        self.memory.allocation_count += 1;
        return result;
    }

    pub fn free(self: *Context, allocation: Allocation) void {
        if (allocation.memory == .null_handle) return;
        if (allocation.mapped != null) {
            self.vkd.vkUnmapMemory(self.device, allocation.memory);
            self.memory.host_visible_bytes -|= allocation.size;
        }
        if (allocation.device_local) self.memory.device_local_bytes -|= allocation.size;
        self.memory.allocation_count -|= 1;
        self.vkd.vkFreeMemory(self.device, allocation.memory, null);
    }

    /// Flush a CPU-written range of a mapped allocation (no-op for coherent memory).
    pub fn flush(self: *Context, allocation: Allocation, offset: u64, size: u64) void {
        if (allocation.coherent or size == 0) return;
        const atom = self.caps.non_coherent_atom_size;
        const start = offset / atom * atom;
        const end = @min(std.mem.alignForward(u64, offset + size, atom), allocation.size);
        const range: vk.MappedMemoryRange = .{ .memory = allocation.memory, .offset = start, .size = end - start };
        _ = self.vkd.vkFlushMappedMemoryRanges(self.device, 1, @ptrCast(&range));
    }

    pub fn invalidate(self: *Context, allocation: Allocation) void {
        if (allocation.coherent) return;
        const range: vk.MappedMemoryRange = .{ .memory = allocation.memory, .offset = 0, .size = vk.whole_size };
        _ = self.vkd.vkInvalidateMappedMemoryRanges(self.device, 1, @ptrCast(&range));
    }

    pub const Buffer = struct {
        buffer: vk.Buffer = .null_handle,
        allocation: Allocation = .{},

        pub fn bytes(self: Buffer) []u8 {
            return self.allocation.mapped.?[0..@intCast(self.allocation.size)];
        }
    };

    pub fn createBuffer(self: *Context, size: u64, usage: vk.Flags, required: vk.Flags, preferred: vk.Flags) !Buffer {
        const info: vk.BufferCreateInfo = .{ .size = size, .usage = usage, .sharingMode = .exclusive };
        var buffer: vk.Buffer = .null_handle;
        try vk.check(self.vkd.vkCreateBuffer(self.device, &info, null, &buffer));
        errdefer self.vkd.vkDestroyBuffer(self.device, buffer, null);
        var reqs: vk.MemoryRequirements = undefined;
        self.vkd.vkGetBufferMemoryRequirements(self.device, buffer, &reqs);
        const allocation = try self.allocate(reqs, required, preferred, null);
        errdefer self.free(allocation);
        try vk.check(self.vkd.vkBindBufferMemory(self.device, buffer, allocation.memory, 0));
        return .{ .buffer = buffer, .allocation = allocation };
    }

    pub fn destroyBuffer(self: *Context, buffer: Buffer) void {
        if (buffer.buffer != .null_handle) self.vkd.vkDestroyBuffer(self.device, buffer.buffer, null);
        self.free(buffer.allocation);
    }

    // ---- Submission / deferred destruction -------------------------------------------------

    pub fn nextSerial(self: *Context) u64 {
        self.submit_serial += 1;
        return self.submit_serial;
    }

    /// Called when the fence of submission `serial` is known to be signaled. Fence signal
    /// operations on one queue complete in submission order, so this covers earlier serials.
    pub fn markCompleted(self: *Context, serial: u64) void {
        if (serial > self.completed_serial) self.completed_serial = serial;
        self.collectGarbage();
    }

    /// Destroys `g` once all submissions up to the current serial have completed.
    pub fn retire(self: *Context, g: Garbage.Kind) void {
        if (self.submit_serial <= self.completed_serial) {
            self.destroyGarbage(g);
            return;
        }
        self.garbage.append(self.gpa, .{ .serial = self.submit_serial, .kind = g }) catch {
            // Out of memory: fall back to a full wait, then destroy now.
            _ = self.vkd.vkDeviceWaitIdle(self.device);
            self.completed_serial = self.submit_serial;
            self.destroyGarbage(g);
        };
    }

    fn collectGarbage(self: *Context) void {
        var i: usize = 0;
        while (i < self.garbage.items.len) {
            if (self.garbage.items[i].serial <= self.completed_serial) {
                self.destroyGarbage(self.garbage.items[i].kind);
                _ = self.garbage.swapRemove(i);
            } else i += 1;
        }
    }

    fn destroyGarbage(self: *Context, g: Garbage.Kind) void {
        switch (g) {
            .buffer => |b| self.destroyBuffer(b),
            .image => |img| {
                if (img.view != .null_handle) self.vkd.vkDestroyImageView(self.device, img.view, null);
                if (img.image != .null_handle) self.vkd.vkDestroyImage(self.device, img.image, null);
                self.free(img.allocation);
            },
            .descriptor_set => |d| _ = self.vkd.vkFreeDescriptorSets(self.device, d.pool, 1, @ptrCast(&d.set)),
        }
    }
};

pub const Garbage = struct {
    serial: u64,
    kind: Kind,

    pub const Kind = union(enum) {
        buffer: Context.Buffer,
        image: struct { image: vk.Image, view: vk.ImageView, allocation: Allocation },
        descriptor_set: struct { pool: vk.DescriptorPool, set: vk.DescriptorSet },
    };
};

// ---- helpers --------------------------------------------------------------------------------

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn envFlag(name: [*:0]const u8) bool {
    const value = getenv(name) orelse return false;
    const s = std.mem.span(value);
    return s.len > 0 and !std.mem.eql(u8, s, "0");
}

fn hasInstanceLayer(gpa: std.mem.Allocator, loader: *vk.Loader, name: []const u8) !bool {
    var count: u32 = 0;
    try vk.check(loader.base.vkEnumerateInstanceLayerProperties(&count, null));
    const list = try gpa.alloc(vk.LayerProperties, count);
    defer gpa.free(list);
    try vk.check(loader.base.vkEnumerateInstanceLayerProperties(&count, list.ptr));
    for (list[0..count]) |l| if (std.mem.eql(u8, vk.cstr(&l.layerName), name)) return true;
    return false;
}

fn hasInstanceExtension(gpa: std.mem.Allocator, loader: *vk.Loader, name: []const u8) !bool {
    var count: u32 = 0;
    try vk.check(loader.base.vkEnumerateInstanceExtensionProperties(null, &count, null));
    const list = try gpa.alloc(vk.ExtensionProperties, count);
    defer gpa.free(list);
    try vk.check(loader.base.vkEnumerateInstanceExtensionProperties(null, &count, list.ptr));
    for (list[0..count]) |e| if (std.mem.eql(u8, vk.cstr(&e.extensionName), name)) return true;
    return false;
}

fn deviceExtensions(gpa: std.mem.Allocator, vki: vk.InstanceDispatch, physical: vk.PhysicalDevice) ![]vk.ExtensionProperties {
    var count: u32 = 0;
    try vk.check(vki.vkEnumerateDeviceExtensionProperties(physical, null, &count, null));
    const list = try gpa.alloc(vk.ExtensionProperties, count);
    errdefer gpa.free(list);
    try vk.check(vki.vkEnumerateDeviceExtensionProperties(physical, null, &count, list.ptr));
    return list[0..count];
}

fn formatCanBlit(vki: vk.InstanceDispatch, physical: vk.PhysicalDevice, format: vk.Format) bool {
    var fp: vk.FormatProperties = undefined;
    vki.vkGetPhysicalDeviceFormatProperties(physical, format, &fp);
    const need = vk.FormatFeatureFlags.blit_src | vk.FormatFeatureFlags.blit_dst | vk.FormatFeatureFlags.sampled_image_filter_linear;
    return fp.optimalTilingFeatures & need == need;
}

const Pick = struct {
    device: vk.PhysicalDevice,
    queue_family: u32,
    drm: ?DrmNode,
};

fn pickPhysicalDevice(gpa: std.mem.Allocator, vki: vk.InstanceDispatch, instance: vk.Instance, preferred: ?u64) InitError!Pick {
    var count: u32 = 0;
    try vk.check(vki.vkEnumeratePhysicalDevices(instance, &count, null));
    if (count == 0) return error.NoSuitableGpu;
    const devices = try gpa.alloc(vk.PhysicalDevice, count);
    defer gpa.free(devices);
    try vk.check(vki.vkEnumeratePhysicalDevices(instance, &count, devices.ptr));

    var best: ?Pick = null;
    var best_score: i32 = -1;
    for (devices[0..count]) |pd| {
        var props: vk.PhysicalDeviceProperties = undefined;
        vki.vkGetPhysicalDeviceProperties(pd, &props);
        if (props.apiVersion < vk.api_version_1_1) continue;
        const family = graphicsQueueFamily(gpa, vki, pd) orelse continue;
        const drm = queryDrm(gpa, vki, pd);

        var score: i32 = switch (props.deviceType) {
            .discrete_gpu => 40,
            .integrated_gpu => 30,
            .virtual_gpu => 20,
            .cpu => 1,
            else => 10,
        };
        if (preferred) |dev| if (drm) |node| {
            const major: i64 = @intCast(devMajor(dev));
            const minor: i64 = @intCast(devMinor(dev));
            const matches = (node.has_render and node.render_major == major and node.render_minor == minor) or
                (node.has_primary and node.primary_major == major and node.primary_minor == minor);
            if (matches) score += 1000;
        };
        if (score > best_score) {
            best_score = score;
            best = .{ .device = pd, .queue_family = family, .drm = drm };
        }
    }
    return best orelse error.NoSuitableGpu;
}

fn graphicsQueueFamily(gpa: std.mem.Allocator, vki: vk.InstanceDispatch, pd: vk.PhysicalDevice) ?u32 {
    var count: u32 = 0;
    vki.vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, null);
    const families = gpa.alloc(vk.QueueFamilyProperties, count) catch return null;
    defer gpa.free(families);
    vki.vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, families.ptr);
    for (families[0..count], 0..) |f, i| {
        if (f.queueFlags & vk.QueueFlags.graphics != 0 and f.queueCount > 0) return @intCast(i);
    }
    return null;
}

fn queryDrm(gpa: std.mem.Allocator, vki: vk.InstanceDispatch, pd: vk.PhysicalDevice) ?DrmNode {
    const exts = deviceExtensions(gpa, vki, pd) catch return null;
    defer gpa.free(exts);
    var supported = false;
    for (exts) |e| {
        if (std.mem.eql(u8, vk.cstr(&e.extensionName), "VK_EXT_physical_device_drm")) supported = true;
    }
    if (!supported) return null;
    var drm: vk.PhysicalDeviceDrmPropertiesEXT = .{};
    var props2: vk.PhysicalDeviceProperties2 = .{ .pNext = &drm, .properties = undefined };
    vki.vkGetPhysicalDeviceProperties2(pd, &props2);
    return .{
        .has_primary = drm.hasPrimary != 0,
        .has_render = drm.hasRender != 0,
        .primary_major = drm.primaryMajor,
        .primary_minor = drm.primaryMinor,
        .render_major = drm.renderMajor,
        .render_minor = drm.renderMinor,
    };
}

fn debugCallback(severity: vk.Flags, types: vk.Flags, data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user: ?*anyopaque) callconv(.c) vk.Bool32 {
    _ = types;
    _ = user;
    const msg: []const u8 = if (data) |d| if (d.pMessage) |m| std.mem.span(m) else "" else "";
    if (severity & vk.DebugUtilsMessageSeverityFlagsEXT.@"error" != 0) {
        log.err("vulkan: {s}", .{msg});
    } else {
        log.warn("vulkan: {s}", .{msg});
    }
    return vk.false_;
}

test "dev_t decoding matches glibc" {
    // makedev(226, 128) == 0xe280
    try std.testing.expectEqual(@as(u64, 226), devMajor(0xe280));
    try std.testing.expectEqual(@as(u64, 128), devMinor(0xe280));
}

test "context smoke: create device (skipped without Vulkan)" {
    const ctx = Context.init(std.testing.allocator, .{}) catch |err| switch (err) {
        error.VulkanLoaderNotFound, error.NoSuitableGpu => return error.SkipZigTest,
        else => return err,
    };
    defer ctx.deinit();
    try std.testing.expect(ctx.deviceName().len > 0);
    const buf = try ctx.createBuffer(4096, vk.BufferUsageFlags.transfer_src, vk.MemoryPropertyFlags.host_visible, 0);
    ctx.destroyBuffer(buf);
}
