# iOS client core toolchain

On a Mac with Xcode selected by `xcode-select`, run from the repository root:

```sh
mise run mobile-core-ios
```

This runs `zig build ios-xcframework --release=safe` in `packages/client_core`.
The packaging script discovers the iPhoneOS and iPhoneSimulator SDKs with
`xcrun --sdk <sdk> --show-sdk-path`, then invokes the `ios-libs` build step
with those paths. Both static libraries use LLVM/LLD, arm64 and a minimum
deployment target of iOS 17. No signing identity or simulator runtime is
required to build the framework.

Output: `packages/client_core/zig-out/lib/VerdeClient.xcframework` with
`ios-arm64` and `ios-arm64-simulator` slices. Each contains
`libverde_client.a`, `verde_client.h` and the `VerdeClient` module map.
The build compiles and links `tests/ios_smoke.swift` against each packaged
slice, verifying `import VerdeClient` and `vc_version()` without running it.
Link the xcframework in the iOS app (I-01); do not embed the static library.

The Mac mini uses Xcode 16.2 / iOS 18.2 SDKs. Store builds will use the newer
Xcode on CI (I-12). SDK paths are discovered, never pinned to an Xcode install.
Generated outputs remain under the ignored `zig-out/` directory.
