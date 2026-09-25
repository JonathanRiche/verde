# iOS app

Follow the [root rules](../../AGENTS.md), [mobile plan](../../docs/mobile-app-plan.md)
and [core toolchain](../client_core/docs/ios-toolchain.md).

- SwiftUI, iOS 17+, bundle ID `dev.verdeai.app`. `project.yml` is the source
  of truth; never commit generated Xcode projects, plists or build outputs.
- Edit on Linux, commit and push; run builds on the Mac only through
  `ssh mac 'export TERM=xterm-256color GIT_PAGER=cat; cd ~/development/verde && git pull --ff-only && mise run mobile-ios-build'`
  and the same command with `mobile-ios-test`. Both tasks build the core and
  generate the project. Tests create and delete their own simulator.
- Local Xcode is 16.2 (iOS 18.2 SDK); Swift must also compile on newer CI
  SDKs. Use iOS 17-compatible APIs; avoid deprecated APIs and SDK paths.
  Verification is simulator-only and unsigned; no development team is needed.
  Store signing and CI belong to I-12. Mobile versions are independent of desktop.
- Link the static `VerdeClient.xcframework`; do not embed it. Its module map
  supplies `import VerdeClient`. Respect C ownership (`vc_version` is static).
- Keep protocol/state logic in the sans-IO core; Swift owns UI and effects.
  Translate the finished Android screen for subsequent screen tasks.
  Never use desktop-mirror RPCs or run agents/providers on the phone.
- Device credentials live only in Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced or backed up.
  Access tokens stay in memory. No owner-token entry.
- Never put credentials, pair codes, tokens, content or clipboard data in logs,
  crash reports, URLs or analytics. TOFU-pin the host TLS key (or issuer), not
  a rotating leaf certificate, with an explicit re-trust flow.
- Foreground refreshes auth, opens a ticketed socket and catches up; background
  closes the socket and stops polling. Network changes use core backoff.
- Push uses native APNs, no Firebase SDK. The extension is a pass-through
  placeholder until I-10; do not add signing entitlements or secret keys here.
- Tests use temporary state and finite deadlines, never a live host or provider.
