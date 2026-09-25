//! Minimal JNI surface for the Android entry points.
//!
//! Written in Zig so the core needs no C shim or `jni.h`. Only the function
//! table slots the core calls are named; their indices are fixed by the JNI
//! specification ("JNI Functions", interface function table).

pub const JObject = opaque {};
pub const jobject = ?*JObject;
pub const jclass = jobject;
pub const jstring = jobject;

/// The JNI interface function table (`struct JNINativeInterface`).
pub const FunctionTable = [*]const ?*const anyopaque;

/// `JNIEnv *` as received by native methods: a pointer to the table pointer.
pub const Env = *const FunctionTable;

/// `jstring NewStringUTF(JNIEnv *env, const char *bytes)`.
pub const new_string_utf_index: usize = 167;

const NewStringUtfFn = *const fn (env: Env, bytes: [*:0]const u8) callconv(.c) jstring;

/// Creates a Java string from modified UTF-8. Returns null (with a pending
/// Java exception) when the VM is out of memory.
pub fn newStringUtf(env: Env, bytes: [*:0]const u8) jstring {
    const new_string: NewStringUtfFn = @ptrCast(@alignCast(env.*[new_string_utf_index].?));
    return new_string(env, bytes);
}

const std = @import("std");
const abi = @import("root.zig");
const core = @import("host.zig");
// JNI specification indices: GetArrayLength 171, NewByteArray 176,
// GetByteArrayRegion 200, SetByteArrayRegion 208, SetIntArrayRegion 211,
// ExceptionCheck 228. No pinned JVM memory survives a call.
fn function(comptime T: type, env: Env, index: usize) T {
    return @ptrCast(@alignCast(env.*[index].?));
}
fn exception(env: Env) bool {
    return function(*const fn (Env) callconv(.c) u8, env, 228)(env) != 0;
}
fn length(env: Env, array: jobject) i32 {
    return function(*const fn (Env, jobject) callconv(.c) i32, env, 171)(env, array);
}
fn setStatus(env: Env, out: jobject, code: i32) bool {
    if (out == null or exception(env)) return false;
    if (length(env, out) < 1 or exception(env)) return false;
    function(*const fn (Env, jobject, i32, i32, *const i32) callconv(.c) void, env, 211)(env, out, 0, 1, &code);
    return !exception(env);
}
fn copyInput(env: Env, array: jobject, limit: usize) core.ApiError![]u8 {
    if (array == null) return error.InvalidArgument;
    const len = length(env, array);
    if (exception(env) or len < 0) return error.InvalidArgument;
    if (len > limit) return error.ResourceLimit;
    const bytes = try std.heap.c_allocator.alloc(u8, @intCast(len));
    errdefer std.heap.c_allocator.free(bytes);
    function(*const fn (Env, jobject, i32, i32, [*]u8) callconv(.c) void, env, 200)(env, array, 0, len, bytes.ptr);
    if (exception(env)) return error.InvalidArgument;
    return bytes;
}
fn copyOutput(env: Env, bytes: []const u8) jobject {
    if (bytes.len > std.math.maxInt(i32)) return null;
    const array = function(*const fn (Env, i32) callconv(.c) jobject, env, 176)(env, @intCast(bytes.len));
    if (array == null or exception(env)) return null;
    function(*const fn (Env, jobject, i32, i32, [*]const u8) callconv(.c) void, env, 208)(env, array, 0, @intCast(bytes.len), bytes.ptr);
    return if (exception(env)) null else array;
}
fn hostPointer(token: i64) ?*core.Host {
    return if (token == 0) null else @ptrFromInt(@as(u64, @bitCast(token)));
}

/// Kotlin: @JvmStatic external fun hostNew(json: ByteArray, status: IntArray): Long
/// status must have at least one element; receives the exact vc_status.
pub fn hostNew(env: Env, _: jclass, array: jobject, out_status: jobject) callconv(.c) i64 {
    if (!setStatus(env, out_status, 1)) return 0;
    const bytes = copyInput(env, array, core.MAX_INPUT) catch |err| {
        _ = setStatus(env, out_status, abi.status(err));
        return 0;
    };
    defer std.heap.c_allocator.free(bytes);
    var host: ?*core.Host = null;
    const code = abi.vcHostNew(bytes.ptr, bytes.len, &host);
    if (!setStatus(env, out_status, code)) {
        abi.vcHostFree(host);
        return 0;
    }
    return if (host) |h| @bitCast(@as(u64, @intFromPtr(h))) else 0;
}
/// Kotlin: @JvmStatic external fun hostFree(host: Long)
pub fn hostFree(_: Env, _: jclass, token: i64) callconv(.c) void {
    abi.vcHostFree(hostPointer(token));
}
/// Kotlin: @JvmStatic external fun hostHandle(host: Long, json: ByteArray, status: IntArray): ByteArray?
pub fn hostHandle(env: Env, _: jclass, token: i64, array: jobject, out_status: jobject) callconv(.c) jobject {
    return hostCall(env, token, array, out_status, false);
}
/// Kotlin: @JvmStatic external fun hostQuery(host: Long, selector: ByteArray, status: IntArray): ByteArray?
/// Returned arrays are JVM-owned; vc_buf_free is performed inside the wrapper.
pub fn hostQuery(env: Env, _: jclass, token: i64, array: jobject, out_status: jobject) callconv(.c) jobject {
    return hostCall(env, token, array, out_status, true);
}
fn hostCall(env: Env, token: i64, array: jobject, out_status: jobject, query: bool) jobject {
    if (!setStatus(env, out_status, 1)) return null;
    const host = hostPointer(token) orelse return null;
    const input = copyInput(env, array, if (query) core.MAX_INPUT else core.MAX_HTTP_INPUT) catch |err| {
        _ = setStatus(env, out_status, abi.status(err));
        return null;
    };
    defer std.heap.c_allocator.free(input);
    // Stage a private host until the JVM also owns a complete result. JNI OOM
    // cannot consume the event or lose the batch after the C allocation succeeds.
    const tx = core.Transaction.init(host) catch |err| {
        _ = setStatus(env, out_status, abi.status(err));
        return null;
    };
    var staged: core.Host = .{ .allocator = host.allocator, .arena = tx.arena, .state = tx.state };
    defer staged.deinit();
    var buf: abi.Buf = .{};
    const code = if (query) abi.vcHostQuery(&staged, input.ptr, input.len, &buf) else abi.vcHostHandle(&staged, input.ptr, input.len, &buf);
    defer abi.vcBufFree(buf);
    if (code != 0) {
        _ = setStatus(env, out_status, code);
        return null;
    }
    const result = copyOutput(env, buf.ptr.?[0..buf.len]) orelse {
        _ = setStatus(env, out_status, 3);
        return null;
    };
    if (!setStatus(env, out_status, 0)) return null;
    if (!query) {
        const old = host.*;
        host.* = staged;
        staged = old;
    }
    return result;
}

// A fake JVM exercises actual table indices, byte ownership, status propagation
// and failure after native output allocation without needing a phone.
test "JNI host wrappers copy inputs and outputs and roll back JVM allocation failure" {
    const Vm = struct {
        var input: []const u8 = "";
        var output: [8192]u8 = undefined;
        var output_len: usize = 0;
        var code: i32 = -1;
        var fail_output = false;
        var input_object: u8 = 0;
        var output_object: u8 = 0;
        var status_object: u8 = 0;
        fn check(_: Env) callconv(.c) u8 {
            return 0;
        }
        fn getLength(_: Env, array: jobject) callconv(.c) i32 {
            return if (array == @as(jobject, @ptrCast(&status_object))) 1 else @intCast(input.len);
        }
        fn getRegion(_: Env, _: jobject, _: i32, len: i32, ptr: [*]u8) callconv(.c) void {
            @memcpy(ptr[0..@intCast(len)], input);
        }
        fn newArray(_: Env, len: i32) callconv(.c) jobject {
            if (fail_output) return null;
            output_len = @intCast(len);
            return @ptrCast(&output_object);
        }
        fn setRegion(_: Env, _: jobject, _: i32, len: i32, ptr: [*]const u8) callconv(.c) void {
            @memcpy(output[0..@intCast(len)], ptr[0..@intCast(len)]);
        }
        fn setInt(_: Env, _: jobject, _: i32, _: i32, ptr: *const i32) callconv(.c) void {
            code = ptr.*;
        }
    };
    var slots: [229]?*const anyopaque = @splat(null);
    slots[171] = @ptrCast(&Vm.getLength);
    slots[176] = @ptrCast(&Vm.newArray);
    slots[200] = @ptrCast(&Vm.getRegion);
    slots[208] = @ptrCast(&Vm.setRegion);
    slots[211] = @ptrCast(&Vm.setInt);
    slots[228] = @ptrCast(&Vm.check);
    const table: FunctionTable = &slots;
    const input: jobject = @ptrCast(&Vm.input_object);
    const out_status: jobject = @ptrCast(&Vm.status_object);
    Vm.input = "{\"api_version\":1,\"host_id\":\"jni\",\"label\":\"JNI\",\"https_url\":null,\"wss_url\":null,\"client_revision\":1,\"session_nonce\":\"0123456789abcdef0123456789abcdef\",\"jitter_seed\":0}";
    const token = hostNew(&table, null, input, out_status);
    try std.testing.expect(token != 0 and Vm.code == 0);
    defer hostFree(&table, null, token);
    Vm.input = "{\"api_version\":1,\"type\":\"start\",\"now_ms\":0,\"wall_time_ms\":0,\"foreground\":true,\"network_available\":true}";
    Vm.fail_output = true;
    try std.testing.expect(hostHandle(&table, null, token, input, out_status) == null);
    try std.testing.expect(Vm.code == 3 and hostPointer(token).?.state.lifecycle == .created);
    Vm.fail_output = false;
    try std.testing.expect(hostHandle(&table, null, token, input, out_status) != null);
    try std.testing.expect(Vm.code == 0 and hostPointer(token).?.state.lifecycle == .foreground);
    Vm.input = "hosts";
    try std.testing.expect(hostQuery(&table, null, token, input, out_status) != null);
    try std.testing.expect(std.mem.indexOf(u8, Vm.output[0..Vm.output_len], "jni") != null);
    Vm.input = "{}";
    try std.testing.expect(hostHandle(&table, null, token, input, out_status) == null and Vm.code == 1);
    Vm.input = "{\"api_version\":1,\"cols\":8,\"rows\":2,\"scrollback_rows\":0}";
    const term_token = termNew(&table, null, input, out_status);
    try std.testing.expect(term_token != 0 and Vm.code == 0);
    defer termFree(&table, null, term_token);
    Vm.input = "\x1b[6n";
    try std.testing.expect(termWrite(&table, null, term_token, input) == 0);
    Vm.fail_output = true;
    try std.testing.expect(termSnapshot(&table, null, term_token, out_status) == null and Vm.code == 3);
    try std.testing.expect(termPointer(term_token).?.replies.items.len > 0);
    Vm.fail_output = false;
    try std.testing.expect(termSnapshot(&table, null, term_token, out_status) != null and Vm.code == 0);
    try std.testing.expect(termPointer(term_token).?.replies.items.len == 0);
    try std.testing.expect(termResize(&table, null, term_token, 0, 2) == 1);
    try std.testing.expect(termResize(&table, null, term_token, 10, 2) == 0);
    try std.testing.expect(termScroll(&table, null, term_token, 1) == 0);
}

fn termPointer(token: i64) ?*abi.terminal.Terminal {
    return if (token == 0) null else @ptrFromInt(@as(u64, @bitCast(token)));
}
pub fn termNew(env: Env, _: jclass, array: jobject, out_status: jobject) callconv(.c) i64 {
    if (!setStatus(env, out_status, 1)) return 0;
    const bytes = copyInput(env, array, core.MAX_INPUT) catch |err| {
        _ = setStatus(env, out_status, abi.status(err));
        return 0;
    };
    defer std.heap.c_allocator.free(bytes);
    var term: ?*abi.terminal.Terminal = null;
    const code = abi.vcTermNew(bytes.ptr, bytes.len, &term);
    if (!setStatus(env, out_status, code)) {
        abi.vcTermFree(term);
        return 0;
    }
    return if (term) |t| @bitCast(@as(u64, @intFromPtr(t))) else 0;
}
pub fn termFree(_: Env, _: jclass, token: i64) callconv(.c) void {
    abi.vcTermFree(termPointer(token));
}
pub fn termWrite(env: Env, _: jclass, token: i64, array: jobject) callconv(.c) i32 {
    const bytes = copyInput(env, array, core.MAX_INPUT) catch |err| return abi.status(err);
    defer std.heap.c_allocator.free(bytes);
    return abi.vcTermWrite(termPointer(token), bytes.ptr, bytes.len);
}
pub fn termResize(_: Env, _: jclass, token: i64, cols: i32, rows: i32) callconv(.c) i32 {
    if (cols <= 0 or rows <= 0 or cols > 65535 or rows > 65535) return 1;
    return abi.vcTermResize(termPointer(token), @intCast(cols), @intCast(rows));
}
pub fn termScroll(_: Env, _: jclass, token: i64, delta: i32) callconv(.c) i32 {
    return abi.vcTermScroll(termPointer(token), delta);
}
pub fn termSnapshot(env: Env, _: jclass, token: i64, out_status: jobject) callconv(.c) jobject {
    if (!setStatus(env, out_status, 1)) return null;
    const term = termPointer(token) orelse return null;
    const bytes = term.snapshot(std.heap.c_allocator) catch |err| {
        _ = setStatus(env, out_status, abi.status(err));
        return null;
    };
    defer std.heap.c_allocator.free(bytes);
    const result = copyOutput(env, bytes) orelse {
        _ = setStatus(env, out_status, 3);
        return null;
    };
    if (!setStatus(env, out_status, 0)) return null;
    term.consumeReplies();
    return result;
}
