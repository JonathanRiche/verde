//! Verde mobile client core.
//!
//! Exports the C ABI declared in `include/verde_client.h` and, on Android, the
//! JNI entry points for `dev.verdeai.core.Native`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const jni = @import("jni.zig");

/// Core version from `build.zig.zon`, NUL-terminated for C callers.
pub const version: [:0]const u8 = build_options.version;

comptime {
    @export(&vcVersion, .{ .name = "vc_version" });
    if (builtin.abi.isAndroid()) {
        @export(&javaNativeVersion, .{ .name = "Java_dev_verdeai_core_Native_version" });
    }
}

/// Returns the core version as a static NUL-terminated UTF-8 string.
/// Callers must not free it.
pub fn vcVersion() callconv(.c) [*:0]const u8 {
    return version.ptr;
}

/// JNI: `dev.verdeai.core.Native.version(): String`.
pub fn javaNativeVersion(env: jni.Env, class: jni.jclass) callconv(.c) jni.jstring {
    _ = class;
    return jni.newStringUtf(env, vcVersion());
}

test "vc_version returns the package version" {
    try std.testing.expectEqualStrings(build_options.version, std.mem.span(vcVersion()));
    _ = try std.SemanticVersion.parse(version);
}

test "JNI version entry point returns the version through NewStringUTF" {
    const FakeVm = struct {
        var received: ?[*:0]const u8 = null;
        var java_string: u8 = 0;

        fn newStringUtf(env: jni.Env, bytes: [*:0]const u8) callconv(.c) jni.jstring {
            _ = env;
            received = bytes;
            return @ptrCast(&java_string);
        }
    };

    var slots: [jni.new_string_utf_index + 1]?*const anyopaque = @splat(null);
    slots[jni.new_string_utf_index] = @ptrCast(&FakeVm.newStringUtf);
    const table: jni.FunctionTable = &slots;

    const result = javaNativeVersion(&table, null);
    try std.testing.expectEqual(@as(jni.jstring, @ptrCast(&FakeVm.java_string)), result);
    try std.testing.expectEqualStrings(version, std.mem.span(FakeVm.received.?));
}
