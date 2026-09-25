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
    const function: NewStringUtfFn = @ptrCast(@alignCast(env.*[new_string_utf_index].?));
    return function(env, bytes);
}
