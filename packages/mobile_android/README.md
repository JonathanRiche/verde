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

## Core bridge

`CoreHost.create(config, EffectExecutor(store, config.host_id))` allocates one
native handle on its own single-thread dispatcher and replaces the config's
session nonce/jitter seed with fresh platform entropy. Share one
`AndroidSecureStore(applicationContext)` across hosts. Call `send { now, wall ->
EventStart(now_ms = now, wall_time_ms = wall, foreground = true,
network_available = true) }`; construct other generated `Event` values the same
way so timestamps are sampled on the host thread. Always call the suspending
`close()` when unloading a host. The app owner closes the shared store last.

`hosts`, `home`, and `workspaces` are typed StateFlows of query envelopes;
`views` contains all refreshed selectors, including future per-thread views.
`failed` flags a fatal boundary/batch failure and closes that host's resources.
JNI failures use fixed diagnostics, never native payloads. Tests inject
`CoreBridge`; they do not load JNI.

TLS pins use canonical lowercase hex SHA-256 of DER SPKI, as required by
[K-07](../client_core/docs/auth.md); the executor converts that digest to
OkHttp's `sha256/<base64>` format.
A TLS probe performs only a system-trusted, hostname-verified handshake. Every
HTTP/WS effect additionally pins the actual connection before sending request
headers/body. Each effect has its own pool, so a changed pin cannot inherit a
connection approved under an earlier decision. Redirects, cookies, authentication
fallbacks and automatic request replay are disabled. HTTP limits are enforced
while streaming; oversized/binary WS messages close the socket. No transport or
core diagnostics are logged. The injected client parameter exists for loopback
CA fixtures; production uses the default platform trust manager.

The secure store is an atomically replaced DataStore file in `noBackupFilesDir`,
with each commit AES-256-GCM encrypted under a fresh data key wrapped by a
non-exportable Android Keystore AES key. Keys/records are never copied to cloud
storage; the manifest also keeps `allowBackup=false`. Storage operations run in
issue order and acknowledge only after DataStore completes. The store interface
accepts opaque core records, never independently persists access tokens/tickets.

Native notification presentation is a callback for the later notification lane;
the default suppresses presentation. Until the terminal lane installs VT support,
terminal-output effects receive a typed `unavailable` acknowledgement.
