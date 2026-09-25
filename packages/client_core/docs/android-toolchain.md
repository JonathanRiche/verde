# Android toolchain (Linux build host)

The core cross-compiles with the repo-pinned Zig. It needs only the NDK
sysroot (bionic headers, crt objects and stub libraries). The Android app
(D-01) also uses the SDK in the same location.

## Installed layout

Everything lives in the user's home directory. Nothing goes under the repo.

| Component | Version | Path |
|---|---|---|
| Command-line tools | build 16111833 (`cmdline-tools;latest`) | `~/Android/Sdk/cmdline-tools/latest` |
| NDK | r30, `ndk;30.0.16248370` | `~/Android/Sdk/ndk/30.0.16248370` |
| Platform tools (`adb`) | current | `~/Android/Sdk/platform-tools` |

`sdkmanager` needs Java 17 or newer. This box already has `java@openjdk-17.0.2`
installed through mise, but it is not a global default. Run the tools through
`mise exec` rather than changing the global Java.

## Install steps

```sh
mkdir -p ~/Android/Sdk/cmdline-tools
curl -fLo /tmp/cmdline-tools.zip \
  https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
mv /tmp/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest
rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip

export ANDROID_HOME="$HOME/Android/Sdk"
SDKM="mise exec java@openjdk-17.0.2 -- $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --sdk_root=$ANDROID_HOME"
yes | $SDKM --licenses
$SDKM "ndk;30.0.16248370" "platform-tools"
```

Recent command-line tools warn that `sdkmanager` is deprecated in favour of
the `android sdk` CLI in the same directory. `sdkmanager` still works, and
`--licenses` is now a no-op.

To find newer versions, fetch
`https://dl.google.com/android/repository/repository2-3.xml` and look for
`commandlinetools-linux-*_latest.zip` and `ndk;<version>` entries on
`channel-0` (stable).

## Environment

| Variable | Value | Used by |
|---|---|---|
| `ANDROID_NDK_HOME` | `$HOME/Android/Sdk/ndk/30.0.16248370` | `zig build android-libs` (or pass `-Dandroid-ndk=<path>`) |
| `ANDROID_HOME` | `$HOME/Android/Sdk` | Gradle and `sdkmanager` (D-01) |

`mise run mobile-core-android` defaults `ANDROID_NDK_HOME` to
`${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/30.0.16248370` when it is unset, so
the pinned NDK works with no shell changes. Put `platform-tools` on `PATH` if
you want `adb` interactively.

## How the build uses the NDK

For each ABI, `build.zig` writes a Zig libc file that points at
`toolchains/llvm/prebuilt/<host>/sysroot`:

- `include_dir`: `usr/include`
- `sys_include_dir`: `usr/include/<triple>`
- `crt_dir`: `usr/lib/<triple>/29`

It then links against those files. The NDK's own clang is not used.
`llvm-readelf` from the same prebuilt directory checks the output.

## Verify

```sh
mise run mobile-core-test
mise run mobile-core-android
readelf -d packages/client_core/zig-out/lib/android/arm64-v8a/libverde_client.so | grep NEEDED
```
