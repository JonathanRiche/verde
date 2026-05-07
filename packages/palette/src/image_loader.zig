//! Reusable image decoding backed by Palette's bundled stb_image dependency.

pub const LoadedImage = struct {
    pixels: [*]u8,
    width: i32,
    height: i32,
    channels: i32,

    pub fn deinit(self: LoadedImage) void {
        stbi_image_free(self.pixels);
    }

    pub fn pitch(self: LoadedImage) i32 {
        return self.width * self.channels;
    }
};

pub fn load(path: [:0]const u8) !LoadedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stbi_load(path.ptr, &width, &height, &channels, 4) orelse return error.DecodeFailed;
    return .{
        .pixels = @ptrCast(pixels),
        .width = width,
        .height = height,
        .channels = 4,
    };
}

pub fn loadFromMemory(bytes: []const u8) !LoadedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &channels, 4) orelse return error.DecodeFailed;
    return .{
        .pixels = @ptrCast(pixels),
        .width = width,
        .height = height,
        .channels = 4,
    };
}

extern fn stbi_load(filename: [*:0]const u8, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: *anyopaque) void;
