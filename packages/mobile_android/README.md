# Verde Android

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
Tests run the pairing UI with a fake core through Robolectric on APIs 29 and 35;
they do not load the Android JNI library into the host JVM.

For the JNI smoke check, use an explicitly selected emulator/device:

```sh
adb -s SERIAL install -r packages/mobile_android/app/build/outputs/apk/debug/app-debug.apk
adb -s SERIAL shell am start -n dev.verdeai.app/.MainActivity
```

Verify that the pairing screen opens without a native loading crash.

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
Rejected input/lifecycle calls throw `CoreInputRejected` without destroying the
host; failures while decoding/executing a returned batch remain fatal.
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

## Pairing (D-03)

The onboarding screen accepts the custom pair route and HTTPS App Link, pasted
links, a CameraX/ML Kit QR scan, or manually entered HTTPS host/grant/code.
Manual entry only percent-encodes the existing link format; the core validates
it. Camera scanning uses the bundled barcode model (no first-scan download),
binds to the screen lifecycle, and releases frames and camera use cases on exit.
Camera denial leaves paste/manual entry available.

Continue passes the link, phone-model device label and fresh 128-bit nonce to
the core. Trust UI displays the core's origin/runtime/SPKI proposal and echoes
its opaque proposal ID. Retry sends only `retry_connection`; the core retains
its nonce and controls exchange retries. Home is shown after the credential's
durable storage acknowledgement. The core currently groups expired/used/rejected
grants together; the UI states those alternatives. Presets and nullable access
caps remain core/host protocol fields, not a second Kotlin protocol decoder.

Pair inputs are memory-only, masked, never saved in instance state, and cleared
when submitted. Incoming Intent data is consumed once and removed; a link never
automatically confirms trust or replaces an exchange in progress. Screenshots
and recent-task previews are protected. Rotation retains the ViewModel/host;
background stops transport through the core, and finishing closes the handle.
A stable `primary` host slot restores encrypted pairing on process restart;
D-04 will add the host catalog/switcher. No Home/workspace browsing is added here.

The manifest requests HTTPS App Link verification. OS auto-opening also requires
W-01's deployed `/.well-known/assetlinks.json` to contain the installed signing
certificate; a debug APK is not automatically covered by a release certificate.
Until then, use the in-app scanner/paste or enable the supported link in Android's
app settings. No website or signing association is changed by D-03.

### On-phone verification (after H-06 / H-07)

1. Connect phone and host to the same Tailscale network. Install this debug APK
   with `adb -s SERIAL install -r .../app-debug.apk` using the full output path
   above, then launch Verde. Confirm the phone-model label can be edited.
2. Create a fresh grant via the host's Pair a phone UI or `verde-server pair
   create`. In Verde, tap Scan QR code, grant camera permission and scan it.
   Confirm the host origin/runtime/key, then Trust and pair. Verify Home appears
   and the host's paired-device list contains the chosen device label once.
3. On a fresh app install/test profile and with fresh grants, repeat using Paste
   link, manual host/grant/code, the `verde://pair` link, and the HTTPS App Link.
   Check both cold launch and an already-open app. Use links directly on-device;
   do not put real grants in adb commands, shell history or diagnostic logs.
4. Deny camera permission, cancel scanning and deny host trust in separate fresh
   attempts. Confirm paste/manual remain usable, scanning releases the camera,
   and denial does not exchange a credential. Scan an unrelated QR and paste a
   malformed link: both must show a recoverable error without crashing.
5. Use an expired grant and a grant already consumed by another device. Confirm
   the rejection message asks for a fresh grant. Disable Tailscale, try pairing,
   then restore it and Retry; confirm the unreachable hint and no duplicate device.
6. Rotate during entry, trust and exchange; background/foreground during pairing.
   After successful pairing, close/reopen and force-stop/relaunch the app: it
   restores Home without a new grant. Killing before credential persistence may
   require a fresh grant, since the grant and nonce are deliberately memory-only.
7. On an isolated test host, rotate the TLS key (with a valid system certificate)
   and reconnect. Verify an explicit changed-identity prompt, and that declining
   never bypasses TLS validation. Confirm invalid certificates fail closed.

No phone or local emulator was available during D-03 automation. Secure-store
failure/retry and pending-link protection are covered by fake-core JVM tests;
real Keystore, camera, JNI and OS App Link verification require these phone checks.
