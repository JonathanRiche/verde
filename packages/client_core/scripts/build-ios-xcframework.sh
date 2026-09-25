#!/usr/bin/env bash
# Invoked by the ios-xcframework build step; run from packages/client_core.
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo 'ios-xcframework requires macOS with Xcode selected by xcode-select.' >&2
    exit 1
fi

zig=$1
optimize=$2
prefix=$3
device_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
simulator_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

"$zig" build ios-libs "-Doptimize=$optimize" --prefix "$prefix" \
    "-Dios-sdk=$device_sdk" "-Dios-simulator-sdk=$simulator_sdk"

# Build in a temporary directory: xcodebuild refuses an existing output, and
# a failed package must not replace the last successful xcframework.
staging=$(mktemp -d "${TMPDIR:-/tmp}/verde-client-ios.XXXXXX")
trap 'rm -rf "$staging"' EXIT
xcodebuild -create-xcframework \
    -library "$prefix/lib/ios/device/libverde_client.a" -headers "$PWD/include" \
    -library "$prefix/lib/ios/simulator/libverde_client.a" -headers "$PWD/include" \
    -output "$staging/VerdeClient.xcframework"

# Check Swift can import the module and link its C symbol for both platforms.
for slice in device simulator; do
    if [[ $slice == device ]]; then
        sdk_name=iphoneos
        sdk=$device_sdk
        target=arm64-apple-ios17.0
        identifier=ios-arm64
    else
        sdk_name=iphonesimulator
        sdk=$simulator_sdk
        target=arm64-apple-ios17.0-simulator
        identifier=ios-arm64-simulator
    fi
    library="$staging/VerdeClient.xcframework/$identifier"
    xcrun --sdk "$sdk_name" swiftc -sdk "$sdk" -target "$target" \
        -I "$library/Headers" -L "$library" -lverde_client \
        tests/ios_smoke.swift -o "$staging/smoke-$slice"
    echo "Swift import/link smoke passed: $target"
done

mkdir -p "$prefix/lib"
rm -rf "$prefix/lib/VerdeClient.xcframework"
mv "$staging/VerdeClient.xcframework" "$prefix/lib/VerdeClient.xcframework"
echo "Installed $prefix/lib/VerdeClient.xcframework"
