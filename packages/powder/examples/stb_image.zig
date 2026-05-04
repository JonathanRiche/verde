const c = @cImport({
    @cInclude("stb_image.h");
});

pub const LoadedImage = struct {
    pixels: [*]u8,
    width: i32,
    height: i32,
    channels: i32,

    pub fn deinit(self: LoadedImage) void {
        c.stbi_image_free(self.pixels);
    }
};

pub fn load(path: [:0]const u8) !LoadedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(path.ptr, &width, &height, &channels, 4) orelse return error.DecodeFailed;
    return .{
        .pixels = @ptrCast(pixels),
        .width = width,
        .height = height,
        .channels = 4,
    };
}
