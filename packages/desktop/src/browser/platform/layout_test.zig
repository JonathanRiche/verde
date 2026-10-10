//! The Zig mirror (frame_protocol.zig) must match frame_socket.h byte for byte.
const std = @import("std");
const p = @import("frame_protocol.zig");
const c = @cImport(@cInclude("frame_socket.h"));

fn same(comptime Z: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Z));
    inline for (std.meta.fields(Z)) |f| {
        try std.testing.expectEqual(@offsetOf(C, f.name), @offsetOf(Z, f.name));
    }
}

test "wire structs match the C header" {
    try same(p.Header, c.struct_vbf_header);
    try same(p.Format, c.struct_vbf_format);
    try same(p.Hello, c.struct_vbf_hello);
    try same(p.ModeMsg, c.struct_vbf_mode_msg);
    try same(p.Plane, c.struct_vbf_plane);
    try same(p.Rect, c.struct_vbf_rect);
    try same(p.Frame, c.struct_vbf_frame);
    try same(p.Release, c.struct_vbf_release);
    try std.testing.expectEqual(@as(u32, c.VBF_MAGIC), p.magic);
    try std.testing.expectEqual(@as(c_int, c.VBF_DMABUF_FRAME_SLOT), p.dmabuf_frame_slot);
    try std.testing.expectEqualStrings(c.VBF_SOCKET_ENV, p.socket_env);
}

test {
    _ = p;
}
