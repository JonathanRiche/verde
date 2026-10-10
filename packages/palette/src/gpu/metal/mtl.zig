//! The slice of the Metal API the renderer uses: enum values and by-value structs from the
//! Metal headers (macOS 14 SDK), messaged through the objc runtime shim. Metal.framework is
//! dlopened by `objc.load`; `MTLCreateSystemDefaultDevice` is looked up with dlsym.
const std = @import("std");
pub const objc = @import("../../platform/macos/objc.zig");

pub const Id = objc.Id;
pub const NSUInteger = objc.NSUInteger;
pub const send = objc.send;

pub const PixelFormat = struct {
    pub const r8_unorm: NSUInteger = 10;
    pub const rgba8_unorm: NSUInteger = 70;
    pub const bgra8_unorm: NSUInteger = 80;
};

pub const TextureUsage = struct {
    pub const shader_read: NSUInteger = 1;
    pub const render_target: NSUInteger = 4;
};

pub const StorageMode = struct {
    pub const shared: NSUInteger = 0;
    pub const private: NSUInteger = 2;
};

/// MTLResourceOptions: storage mode << 4 | cpu cache mode.
pub const ResourceOptions = struct {
    pub const shared_default: NSUInteger = 0;
    pub const shared_write_combined: NSUInteger = 1;
};

pub const LoadAction = struct {
    pub const dont_care: NSUInteger = 0;
    pub const load: NSUInteger = 1;
    pub const clear: NSUInteger = 2;
};
pub const store_action_store: NSUInteger = 1;

pub const BlendFactor = struct {
    pub const one: NSUInteger = 1;
    pub const one_minus_source_alpha: NSUInteger = 5;
};

pub const primitive_triangle_strip: NSUInteger = 4;

pub const CommandBufferStatus = struct {
    pub const completed: NSUInteger = 4;
    pub const @"error": NSUInteger = 5;
};

pub const Origin = extern struct { x: NSUInteger = 0, y: NSUInteger = 0, z: NSUInteger = 0 };
pub const Size = extern struct { width: NSUInteger, height: NSUInteger, depth: NSUInteger = 1 };
pub const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
pub const Viewport = extern struct { originX: f64, originY: f64, width: f64, height: f64, znear: f64, zfar: f64 };
pub const ScissorRect = extern struct { x: NSUInteger, y: NSUInteger, width: NSUInteger, height: NSUInteger };
pub const CGSize = extern struct { width: f64, height: f64 };

pub fn createSystemDefaultDevice() ?Id {
    const f = objc.cSymbol(*const fn () callconv(.c) ?Id, "MTLCreateSystemDefaultDevice") orelse return null;
    return f();
}

/// Localized description of an NSError (valid until the enclosing pool drains).
pub fn errorText(err: ?Id) []const u8 {
    const e = err orelse return "(no NSError)";
    return objc.utf8(send(?Id, e, "localizedDescription", .{}));
}

/// `[[cls alloc] init]`-style helpers returning +1 objects.
pub fn newTexture(device: Id, format: NSUInteger, width: u32, height: u32, mipmapped: bool, usage: NSUInteger, storage: NSUInteger) ?Id {
    const desc = send(?Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        format, @as(NSUInteger, width), @as(NSUInteger, height), if (mipmapped) objc.YES else objc.NO,
    }) orelse return null;
    send(void, desc, "setUsage:", .{usage});
    send(void, desc, "setStorageMode:", .{storage});
    return send(?Id, device, "newTextureWithDescriptor:", .{desc});
}

pub fn newBuffer(device: Id, length: usize, options: NSUInteger) ?Id {
    return send(?Id, device, "newBufferWithLength:options:", .{ @as(NSUInteger, @max(length, 16)), options });
}

pub fn contents(buffer: Id) [*]u8 {
    return send([*]u8, buffer, "contents", .{});
}

pub fn bufferLength(buffer: Id) usize {
    return send(NSUInteger, buffer, "length", .{});
}

pub fn mipLevels(texture: Id) u32 {
    return @intCast(send(NSUInteger, texture, "mipmapLevelCount", .{}));
}

pub fn copyBufferToTexture(blit: Id, buffer: Id, offset: usize, bytes_per_row: usize, w: u32, h: u32, texture: Id, x: u32, y: u32) void {
    send(void, blit, "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        buffer,                                     @as(NSUInteger, offset),
        @as(NSUInteger, bytes_per_row),             @as(NSUInteger, bytes_per_row * h),
        Size{ .width = w, .height = h },            texture,
        @as(NSUInteger, 0),                         @as(NSUInteger, 0),
        Origin{ .x = x, .y = y },
    });
}

pub fn copyTextureRegion(blit: Id, src: Id, dst: Id, x: u32, y: u32, w: u32, h: u32) void {
    send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        src,                             @as(NSUInteger, 0),
        @as(NSUInteger, 0),              Origin{ .x = x, .y = y },
        Size{ .width = w, .height = h }, dst,
        @as(NSUInteger, 0),              @as(NSUInteger, 0),
        Origin{ .x = x, .y = y },
    });
}

pub fn copyTextureToBuffer(blit: Id, src: Id, w: u32, h: u32, buffer: Id) void {
    send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
        src,                             @as(NSUInteger, 0),
        @as(NSUInteger, 0),              Origin{},
        Size{ .width = w, .height = h }, buffer,
        @as(NSUInteger, 0),              @as(NSUInteger, @as(usize, w) * 4),
        @as(NSUInteger, @as(usize, w) * h * 4),
    });
}
