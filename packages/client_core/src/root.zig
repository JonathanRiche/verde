//! Verde mobile client core.
//!
//! Exports the C ABI declared in `include/verde_client.h` and, on Android (and
//! the `jvm-lib` test build), the JNI entry points for `dev.verdeai.core.Native`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const engine = @import("host.zig");
const jni = @import("jni.zig");
pub const terminal = @import("terminal.zig");
const push = @import("push.zig");

/// Core version from `build.zig.zon`, NUL-terminated for C callers.
pub const version: [:0]const u8 = build_options.version;

comptime {
    @export(&vcVersion, .{ .name = "vc_version" });
    @export(&vcHostNew, .{ .name = "vc_host_new" });
    @export(&vcHostFree, .{ .name = "vc_host_free" });
    @export(&vcHostHandle, .{ .name = "vc_host_handle" });
    @export(&vcHostQuery, .{ .name = "vc_host_query" });
    @export(&vcTermNew, .{ .name = "vc_term_new" });
    @export(&vcTermFree, .{ .name = "vc_term_free" });
    @export(&vcTermWrite, .{ .name = "vc_term_write" });
    @export(&vcTermResize, .{ .name = "vc_term_resize" });
    @export(&vcTermScroll, .{ .name = "vc_term_scroll" });
    @export(&vcTermSnapshot, .{ .name = "vc_term_snapshot" });
    @export(&vcBufFree, .{ .name = "vc_buf_free" });
    @export(&vcPushOpen, .{ .name = "vc_push_open" });
    // `jvm_jni` is the host test library for the Android app's JVM unit tests.
    if (builtin.abi.isAndroid() or build_options.jvm_jni) {
        @export(&jni.termNew, .{ .name = "Java_dev_verdeai_core_Native_termNew" });
        @export(&jni.termFree, .{ .name = "Java_dev_verdeai_core_Native_termFree" });
        @export(&jni.termWrite, .{ .name = "Java_dev_verdeai_core_Native_termWrite" });
        @export(&jni.termResize, .{ .name = "Java_dev_verdeai_core_Native_termResize" });
        @export(&jni.termScroll, .{ .name = "Java_dev_verdeai_core_Native_termScroll" });
        @export(&jni.termSnapshot, .{ .name = "Java_dev_verdeai_core_Native_termSnapshot" });
        @export(&jni.hostNew, .{ .name = "Java_dev_verdeai_core_Native_hostNew" });
        @export(&jni.hostFree, .{ .name = "Java_dev_verdeai_core_Native_hostFree" });
        @export(&jni.hostHandle, .{ .name = "Java_dev_verdeai_core_Native_hostHandle" });
        @export(&jni.hostQuery, .{ .name = "Java_dev_verdeai_core_Native_hostQuery" });
        @export(&javaNativeVersion, .{ .name = "Java_dev_verdeai_core_Native_version" });
        @export(&jni.pushOpen, .{ .name = "Java_dev_verdeai_core_Native_pushOpen" });
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

// Panics contain a fixed diagnostic only. Do not format panic messages, which
// may contain caller data. Mobile libraries must not install signal handlers.
pub const std_options: std.Options = .{ .logFn = quietLog, .enable_segfault_handler = false, .signal_stack_size = 0 };
pub const panic = std.debug.FullPanic(corePanic);
extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
fn corePanic(_: []const u8, _: ?usize) noreturn {
    if (builtin.abi.isAndroid()) {
        _ = __android_log_write(7, "VerdeClient", "core_invariant_failure");
    } else {
        _ = std.c.write(2, "VerdeClient: core_invariant_failure\n", "VerdeClient: core_invariant_failure\n".len);
    }
    std.c.abort();
}

pub const Buf = extern struct { ptr: ?[*]u8 = null, len: usize = 0 };
pub fn status(err: engine.ApiError) i32 {
    return switch (err) {
        error.InvalidArgument => 1,
        error.UnsupportedVersion => 2,
        error.OutOfMemory => 3,
        error.InvalidLifecycle => 4,
        error.ResourceLimit => 5,
    };
}
fn inputSlice(ptr: ?[*]const u8, len: usize) engine.ApiError![]const u8 {
    if (len > engine.MAX_INPUT) return error.ResourceLimit;
    if (ptr) |p| return p[0..len];
    if (len != 0) return error.InvalidArgument;
    return "";
}
pub fn vcHostNew(ptr: ?[*]const u8, len: usize, out: ?*?*engine.Host) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = null;
    const input = inputSlice(ptr, len) catch |err| return status(err);
    const host = std.heap.c_allocator.create(engine.Host) catch return 3;
    host.* = engine.Host.init(std.heap.c_allocator, input) catch |err| {
        std.heap.c_allocator.destroy(host);
        return status(err);
    };
    result.* = host;
    return 0;
}
pub fn vcHostFree(host: ?*engine.Host) callconv(.c) void {
    if (host) |h| {
        h.deinit();
        std.heap.c_allocator.destroy(h);
    }
}
pub fn vcHostHandle(host: ?*engine.Host, ptr: ?[*]const u8, len: usize, out: ?*Buf) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = .{};
    const h = host orelse return 1;
    const input = inputSlice(ptr, len) catch |err| return status(err);
    const bytes = h.handle(input, std.heap.c_allocator) catch |err| return status(err);
    result.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    return 0;
}
pub fn vcHostQuery(host: ?*engine.Host, ptr: ?[*]const u8, len: usize, out: ?*Buf) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = .{};
    const h = host orelse return 1;
    const input = inputSlice(ptr, len) catch |err| return status(err);
    const bytes = h.query(input, std.heap.c_allocator) catch |err| return status(err);
    result.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    return 0;
}
/// Pure K-17 push decrypt; needs no host. See docs/push.md.
pub fn vcPushOpen(ptr: ?[*]const u8, len: usize, out: ?*Buf) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = .{};
    if (len > push.MAX_OPEN_INPUT) return 5;
    const input = inputSlice(ptr, len) catch |err| return status(err);
    const bytes = push.openJson(std.heap.c_allocator, input) catch |err| return status(err);
    result.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    return 0;
}
pub fn vcBufFree(buf: Buf) callconv(.c) void {
    if (buf.ptr) |ptr| std.heap.c_allocator.free(ptr[0..buf.len]);
}
test {
    _ = @import("harness.zig");
    _ = @import("rpc_test.zig");
    _ = @import("allowlist_test.zig");
    _ = @import("sync_test.zig");
    _ = @import("terminal_test.zig");
    _ = @import("chat_test.zig");
    _ = @import("manage_test.zig");
    _ = @import("model_contract_test.zig");
    _ = @import("auth_harness.zig");
    _ = @import("attention_test.zig");
}

// Upstream parser diagnostics can include escape payloads. Never log them.
fn quietLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}
pub fn vcTermNew(ptr: ?[*]const u8, len: usize, out: ?*?*terminal.Terminal) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = null;
    const input = inputSlice(ptr, len) catch |err| return status(err);
    result.* = terminal.Terminal.create(std.heap.c_allocator, input) catch |err| return status(err);
    return 0;
}
pub fn vcTermFree(term: ?*terminal.Terminal) callconv(.c) void {
    if (term) |t| t.destroy();
}
pub fn vcTermWrite(term: ?*terminal.Terminal, ptr: ?[*]const u8, len: usize) callconv(.c) i32 {
    const t = term orelse return 1;
    const bytes = inputSlice(ptr, len) catch |err| return status(err);
    t.write(bytes) catch |err| return status(err);
    return 0;
}
pub fn vcTermResize(term: ?*terminal.Terminal, cols: u16, rows: u16) callconv(.c) i32 {
    const t = term orelse return 1;
    t.resize(cols, rows) catch |err| return status(err);
    return 0;
}
pub fn vcTermScroll(term: ?*terminal.Terminal, delta: i32) callconv(.c) i32 {
    const t = term orelse return 1;
    t.scroll(delta) catch |err| return status(err);
    return 0;
}
pub fn vcTermSnapshot(term: ?*terminal.Terminal, out: ?*Buf) callconv(.c) i32 {
    const result = out orelse return 1;
    result.* = .{};
    const t = term orelse return 1;
    const bytes = t.snapshot(std.heap.c_allocator) catch |err| return status(err);
    result.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    t.consumeReplies();
    return 0;
}
