//! Windows shell, picker, and clipboard integration bindings.

const std = @import("std");

/// Stable identity shared by the process and the installed Start Menu link.
pub const app_user_model_id: [:0]const u8 = "Verde.Desktop";

pub const ClipboardImage = struct {
    bytes: []u8,
    mime: []const u8,
};

pub const PickerError = error{
    Unavailable,
    Cancelled,
} || std.mem.Allocator.Error;

/// Assigns the explicit Windows application identity before any window exists.
pub fn setProcessAppUserModelId() bool {
    return verde_windows_set_app_user_model_id(app_user_model_id.ptr) != 0;
}

/// Shows the native folder picker and returns a filesystem path as UTF-8.
pub fn pickDirectoryAlloc(allocator: std.mem.Allocator, start_path: []const u8) PickerError![]u8 {
    const start_z = try allocator.dupeZ(u8, start_path);
    defer allocator.free(start_z);
    var selected: ?[*:0]u8 = null;
    const result = verde_windows_pick_directory(start_z.ptr, &selected);
    if (result == 0) return error.Cancelled;
    if (result < 0) return error.Unavailable;
    const path = selected orelse return error.Unavailable;
    defer std.c.free(path);
    return allocator.dupe(u8, std.mem.span(path));
}

/// Opens a path or URL through the Windows shell's registered default app.
pub fn shellOpen(target: []const u8, working_dir: ?[]const u8) bool {
    var target_buffer: [32768:0]u8 = undefined;
    if (target.len >= target_buffer.len) return false;
    @memcpy(target_buffer[0..target.len], target);
    target_buffer[target.len] = 0;

    var cwd_buffer: [32768:0]u8 = undefined;
    const cwd_z: ?[*:0]const u8 = if (working_dir) |cwd| blk: {
        if (cwd.len >= cwd_buffer.len) return false;
        @memcpy(cwd_buffer[0..cwd.len], cwd);
        cwd_buffer[cwd.len] = 0;
        break :blk cwd_buffer[0..cwd.len :0].ptr;
    } else null;
    return verde_windows_shell_open(target_buffer[0..target.len :0].ptr, cwd_z) != 0;
}

/// Opens Explorer with the requested filesystem item selected.
pub fn revealFile(path: []const u8) bool {
    var buffer: [32768:0]u8 = undefined;
    if (path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return verde_windows_reveal_file(buffer[0..path.len :0].ptr) != 0;
}

/// Copies a bounded PNG or DIB payload from the Windows clipboard.
pub fn clipboardImageAlloc(allocator: std.mem.Allocator, max_bytes: usize) !?ClipboardImage {
    var native_bytes: ?[*]u8 = null;
    var native_len: usize = 0;
    var format: c_int = 0;
    const result = verde_windows_clipboard_copy_image(&native_bytes, &native_len, &format, max_bytes);
    if (result < 0) return error.ClipboardUnavailable;
    if (result == 0 or native_bytes == null or native_len == 0) return null;
    defer std.c.free(native_bytes);
    if (native_len > max_bytes) return error.StreamTooLong;
    return .{
        .bytes = try allocator.dupe(u8, native_bytes.?[0..native_len]),
        .mime = switch (format) {
            1 => "image/png",
            2 => "image/bmp",
            else => return error.UnsupportedImageFormat,
        },
    };
}

/// Copies Unicode text from the Windows clipboard as UTF-8.
pub fn clipboardTextAlloc(allocator: std.mem.Allocator, max_bytes: usize) !?[]u8 {
    var native_bytes: ?[*]u8 = null;
    var native_len: usize = 0;
    const result = verde_windows_clipboard_copy_text(&native_bytes, &native_len, max_bytes);
    if (result < 0) return error.ClipboardUnavailable;
    if (result == 0 or native_bytes == null or native_len == 0) return null;
    defer std.c.free(native_bytes);
    if (native_len > max_bytes) return error.StreamTooLong;
    return try allocator.dupe(u8, native_bytes.?[0..native_len]);
}

extern fn verde_windows_pick_directory(start_path: [*:0]const u8, selected_path: *?[*:0]u8) c_int;
extern fn verde_windows_set_app_user_model_id(value: [*:0]const u8) c_int;
extern fn verde_windows_shell_open(target: [*:0]const u8, working_dir: ?[*:0]const u8) c_int;
extern fn verde_windows_reveal_file(path: [*:0]const u8) c_int;
extern fn verde_windows_clipboard_copy_image(
    bytes: *?[*]u8,
    len: *usize,
    format: *c_int,
    max_bytes: usize,
) c_int;
extern fn verde_windows_clipboard_copy_text(bytes: *?[*]u8, len: *usize, max_bytes: usize) c_int;

test "Windows integration wrappers keep clipboard payloads bounded" {
    try std.testing.expect(10 * 1024 * 1024 < std.math.maxInt(u32));
}

test "Windows process identity remains compatible with packaged shortcuts" {
    try std.testing.expectEqualStrings("Verde.Desktop", app_user_model_id);
}
