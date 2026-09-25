//! Raw cImport surface for the Tree-sitter C API.

const std = @import("std");
const builtin = @import("builtin");

pub const bindings = @cImport({
    if (builtin.abi.isAndroid()) {
        // Zig 0.16's header translator does not set the NDK API macro and
        // cannot represent bionic's nullability/fortify overloads. These only
        // affect header translation, not the separately compiled C runtime.
        @cDefine("__ANDROID_MIN_SDK_VERSION__", std.fmt.comptimePrint("{d}", .{builtin.target.os.version_range.linux.android}));
        @cDefine("__ANDROID_API__", std.fmt.comptimePrint("{d}", .{builtin.target.os.version_range.linux.android}));
        @cUndef("_FORTIFY_SOURCE");
        @cDefine("_Nonnull", "");
        @cDefine("_Nullable", "");
        @cDefine("_Null_unspecified", "");
    }
    @cInclude("tree_sitter/api.h");
});
