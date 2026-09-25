# Mobile client core (`libverde_client`)

Follow the [root Zig rules](../../AGENTS.md). Design: [mobile app plan §5](../../docs/mobile-app-plan.md).
Android toolchain setup: [docs/android-toolchain.md](docs/android-toolchain.md).
iOS toolchain setup: [docs/ios-toolchain.md](docs/ios-toolchain.md).

- **Sans-IO.** The core never opens sockets, reads files, spawns threads or reads the clock on its own. The platform feeds events in and performs the effects the core returns.
- **C ABI.** Every export uses the `vc_` prefix and is declared in `include/verde_client.h`; keep the header and `src/root.zig` exports in sync (the `test` step compiles `tests/abi_smoke.c` against both). Returned buffers are core-owned and freed with `vc_buf_free`; never keep caller pointers across calls. Static strings (e.g. `vc_version`) are never freed.
- **JNI.** Entry points are written in Zig (`src/jni.zig`, no `jni.h` or C shim), named `Java_dev_verdeai_core_Native_<method>` for `dev.verdeai.core.Native`, and exported on Android only. Declare them in Kotlin as `@JvmStatic external fun` in `object Native` after `System.loadLibrary("verde_client")`. JNI function-table indices come from the JNI specification.
- **Builds.** Use `mise run mobile-core-test` and `mise run mobile-core-android`, or `zig build test|android-libs --release=safe` from this directory. This is a standalone build graph; the root `-Dbrowser-backend` rule does not apply here. Always use LLVM (`use_llvm = true`); never the self-hosted x86 backend. Use LLD except for iOS Mach-O archives, which Zig 0.16 does not support with LLD.
- **Android output.** `zig-out/lib/android/<abi>/libverde_client.so` for `arm64-v8a` and `x86_64`, API level 29 (Android 10), unversioned soname, 16 KB `max-page-size`. `android-libs` fails if the library has `NEEDED` entries beyond `libc.so`, `libdl.so`, `libm.so`, `liblog.so`, or LOAD segments aligned below 16 KB. Adding a dependency means updating `scripts/check-android-lib.sh` deliberately.
- **Security.** No credentials, tokens, pair codes or message content in logs or panics. Tests use temporary state and loopback fixtures only.
