# Verde Android scaffold

Requires repo-pinned Zig, mise `java@openjdk-17`, Android SDK platform 35 /
Build Tools 35.0.0 and NDK 30.0.16248370. See the
[toolchain setup](../client_core/docs/android-toolchain.md).

From the repository root:

```sh
mise run mobile-android-build
mise run mobile-android-test
```

The tasks use Java 17 through mise without changing shell configuration and
supply default `ANDROID_HOME` / `ANDROID_NDK_HOME` paths under `~/Android/Sdk`.
The Gradle wrapper pins Gradle and verifies its distribution checksum.
`assembleDebug` builds the Zig core with LLVM, checks its Android ELF files,
and packages both arm64-v8a and x86_64 libraries from generated `jniLibs`.
Tests run the Compose version screen through Robolectric on APIs 29 and 35;
they do not load the Android JNI library into the host JVM.

For the JNI smoke check, use an explicitly selected emulator/device:

```sh
adb -s SERIAL install -r packages/mobile_android/app/build/outputs/apk/debug/app-debug.apk
adb -s SERIAL shell am start -n dev.verdeai.app/.MainActivity
```

Verify that the screen displays `Core version: 0.1.0` (or the current version
from `packages/client_core/build.zig.zon`) without a native loading crash.
