# Verde for iOS

The SwiftUI app links the shared client core. See [AGENTS.md](AGENTS.md),
[the mobile task plan](../../docs/mobile-app-tasks.md), and
[the core iOS toolchain](../client_core/docs/ios-toolchain.md).

Settings → Appearance offers System, Light, Dark, eight [website presets](../../assets/mobile/README.md),
and the existing Host theme. The choice is saved on the phone; System follows
the phone’s appearance automatically.

## Simulator verification

Run from the repository root on the Mac:

```sh
mise run mobile-ios-build
mise run mobile-ios-test
```

These targets regenerate the unsigned Xcode project. Tests own and remove their
simulator. They do not require an Apple account. Linux build leases cover Linux
resources, not Mac builds; use separate checkouts and DerivedData for concurrent
Mac work.

## Physical-device signing

Keep `project.yml` unsigned by default. Team IDs, bundle-ID overrides, certificates,
provisioning profiles, passwords, and generated projects belong only on the Mac,
never in Git. Use an isolated Mac device checkout with its own DerivedData.
Do not regenerate an owner-configured project unless its local signing settings
are preserved in a local override or passed to `xcodebuild`.

The owner must initially configure an Apple account in Xcode, pair the iPhone,
enable Developer Mode, and approve developer trust on the phone if requested.
Automatic signing uses `-allowProvisioningUpdates`; include
`-allowProvisioningDeviceRegistration` when registering the connected device.

A GUI Xcode build can sign successfully while SSH fails with
`errSecInternalComponent` / `User interaction is not allowed`: SSH cannot unlock
the login keychain interactively. This Mac uses a dedicated signing keychain:

- `~/Library/Keychains/verde-ci.keychain-db`
- `~/.config/verde-ci/keychain-pass`, a random password stored with mode `0600`

The owner runs the local `~/bin/verde-ci-signing-setup.sh` once. That untracked
script imports the Apple Development identity, configures the code-signing
partition list, and puts the dedicated keychain in the search list. Do not copy
its identity or password into this repository or logs. Verify readiness with
`security find-identity -v -p codesigning` against that keychain.

Every SSH device build/test must unlock the dedicated keychain and explicitly
select it for signing. The following runs **on the Mac**, from a local signed
project directory. Supply `IOS_DEVELOPMENT_TEAM` and `IOS_DEVICE_UDID` from local
configuration (not tracked files); obtain the Xcode destination UDID from
`devicectl device info details`, since it differs from the CoreDevice identifier.

```sh
set +x
: "${IOS_DEVELOPMENT_TEAM:?Set from Mac-only signing configuration}"
: "${IOS_DEVICE_UDID:?Set the connected iPhone Xcode destination UDID}"
ci_keychain="$HOME/Library/Keychains/verde-ci.keychain-db"
security unlock-keychain \
  -p "$(cat "$HOME/.config/verde-ci/keychain-pass")" "$ci_keychain"
xcodebuild -project Verde.xcodeproj -scheme Verde -configuration Debug \
  -derivedDataPath build/DeviceDerivedData \
  -destination "platform=iOS,id=$IOS_DEVICE_UDID" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$IOS_DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES OTHER_CODE_SIGN_FLAGS="--keychain $ci_keychain" build
```

Do not retry signing blindly if the dedicated keychain is unavailable. Finish
independent work, then report the exact failure and required local setup. A local
Xcode Run remains a fallback for app builds.

Install only when a new build or provisioning renewal is needed:

```sh
xcrun devicectl device install app --device "$IOS_COREDEVICE_ID" \
  build/DeviceDerivedData/Build/Products/Debug-iphoneos/App.app
xcrun devicectl device process launch --device "$IOS_COREDEVICE_ID" dev.verdeai.app
```

Use the actual locally configured bundle ID if signing required an override.
Preserve the existing installation and Keychain pairing during ordinary reviews.
Personal Team profiles expire after seven days and cannot support APNs. Inspect
the embedded provisioning profile's expiration before device sessions; rebuild
with automatic provisioning and reinstall before expiry when the device is
available. Do not uninstall first. Profile renewal may require an unlocked phone
and valid Apple account access; a one-time install does not provide scheduled
renewal. I-10 push validation requires an eligible paid team.

## Real-device UI review

The Mac-only `~/development/verde-ios-phone-review/PhoneReview.xcodeproj` contains
an opt-in `Review` UI test scheme using
`XCUIApplication(bundleIdentifier: "dev.verdeai.app")`. It drives the installed
app; it does not rebuild or reinstall Verde. Its helper runner needs signing too.
Use the same unlock step and signing flags above with `-project
PhoneReview.xcodeproj -scheme Review`, an isolated DerivedData path,
`-parallel-testing-enabled NO`, a finite test timeout, and `test`. The GUI
fallback is Product > Test, not Run. Keep the phone connected and unlocked.

This live review is separate from the fixture-based unit tests. Use it only with
explicit owner authorization. Use a dedicated test chat and terminal for sends,
approvals and shell input; never inject test messages or commands into an
unrelated active conversation or terminal. Report approvals, file rendering and
biometric lock as unverified unless actually exercised. Real Face ID/passcode
approval may require the owner's physical presence.

Pair using a fresh, short-lived grant for the intended host. Transfer the link
privately; never print pairing codes, credentials, or clipboard content. A
`devicectl` launch with `--payload-url` can deliver the custom pairing URL; if an
already-running app ignores it, relaunch with `--terminate-existing`. The owner
must confirm the displayed host identity with **Trust and pair**. Successful
launch alone does not prove pairing. Revoke unused grants and temporary review
devices, but preserve the owner's intended permanent pairing.

Inspect results and export review screenshots with:

```sh
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE"
xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" \
  --output-path "$REVIEW_OUTPUT"
```

Keep screenshots private and do not emit chat/terminal content into diagnostic
logs. Export named review images and sanitize diagnostics before sharing.
Connection checks should include foreground observation beyond 30 seconds,
background/resume, and a fresh operation after reconnect. A cached transcript
remaining visible or absence of a sampled Connecting banner alone does not prove
that the socket stayed connected or that synchronization resumed.

### Per-chat Git changes

The chat header opens a frozen Git review, with file/hunk selection, generated
commit messages, new-branch commits, and Commit & push. Chat and Full access can
write; Monitor can review. Shared/unclear/unassigned files require the review
sheet; unassigned files start unticked. Main/default-branch quick commits require
confirmation. Commit-message settings are read-only on paired devices.

The shared core owns scope checks and retained idempotent recovery. If a commit
or push response is lost, the phone checks that same operation rather than
creating a new commit. Pull & push is offered after rejection and never retried
automatically. A system `git` transcript row is rendered as a quiet notice.

`GitChangesTests` uses an injected fake core boundary; its review screenshot is
an XCTest attachment named `git-review-sheet`. No fixture sends a real Git write.
Live Git verification is deferred until the owner relaunches the daemon with the
new `git.changes` protocol. Use a temporary repository/workspace afterward, and
never push a device test to a real remote. The existing local signing/keychain
setup is unchanged.
