//! Windows Known Folder lookup without depending on process environment state.

const std = @import("std");

const windows = std.os.windows;

pub const Folder = enum {
    local_app_data,
    roaming_app_data,
    profile,
};

/// Returns the current token's Known Folder path as WTF-8.
pub fn pathAlloc(allocator: std.mem.Allocator, folder: Folder) ![]u8 {
    const folder_id = switch (folder) {
        .local_app_data => &FOLDER_ID_LOCAL_APP_DATA,
        .roaming_app_data => &FOLDER_ID_ROAMING_APP_DATA,
        .profile => &FOLDER_ID_PROFILE,
    };
    var path_w: ?[*:0]u16 = null;
    const result = SHGetKnownFolderPath(folder_id, KF_FLAG_DEFAULT, null, &path_w);
    if (result < 0) return error.KnownFolderUnavailable;
    const non_null = path_w orelse return error.KnownFolderUnavailable;
    defer CoTaskMemFree(non_null);
    return std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(non_null));
}

const FOLDER_ID_LOCAL_APP_DATA = windows.GUID.parse("{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}");
const FOLDER_ID_ROAMING_APP_DATA = windows.GUID.parse("{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}");
const FOLDER_ID_PROFILE = windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
const KF_FLAG_DEFAULT: windows.DWORD = 0;

extern "shell32" fn SHGetKnownFolderPath(
    folder_id: *const windows.GUID,
    flags: windows.DWORD,
    token: ?windows.HANDLE,
    path: *?[*:0]u16,
) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

test "known folder ids match the Windows SDK constants" {
    try std.testing.expectEqual(@as(u32, 0xF1B32785), FOLDER_ID_LOCAL_APP_DATA.Data1);
    try std.testing.expectEqual(@as(u32, 0x3EB685DB), FOLDER_ID_ROAMING_APP_DATA.Data1);
    try std.testing.expectEqual(@as(u32, 0x5E6C858F), FOLDER_ID_PROFILE.Data1);
}
