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
The D-04 catalog migrates the stable `primary` slot and restores encrypted pairing
on process restart. Home/workspace browsing remains D-05.

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

## Hosts and sign-out (D-04)

`HostsModel` owns a separate `PairingModel`/`CoreHost` per catalog entry. The
Keystore-backed store holds the native catalog under `android/1/hosts`; it
contains only local IDs, labels and the active ID. Core records remain opaque.
New profiles use UUIDs; the first launch without a catalog preserves D-03's
`primary` slot. Catalog writes must succeed before selection/add/remove commits.
A locked or unreadable catalog shows a retry action, never silently replaces it.
The list concatenates each handle's host projection and shows a text status plus
a dot. Selection survives recreation and process restart. `activeCore()` is the
D-05 integration point for Home/workspace projections; never merge those across
hosts. Activity foreground/background continues to reach every loaded handle;
process lifecycle/connectivity refinement belongs to D-05.

Sign-out sends only generated `EventSignOut` to the chosen core. Kotlin does not
construct RPCs, interpret credentials or delete core storage directly. The core
owns revocation, uncertainty, cancellation, and acknowledged credential/pin
deletion. Unconfirmed sign-out offers an explicit “Remove from this phone anyway”
confirmation and warns about revoking the device on the desktop. That sends
`EventForgetHost`. A delete error offers `EventRetryConnection`. The host remains
visible until the core reports `signed_out`; only then can its catalog entry be
removed, or the same host slot paired again. Removing the active entry selects
the next saved host; other credentials stay untouched. The app retains no local
workspace cache yet. The catalog is capped at 32 entries.

JVM/Robolectric tests use fake cores on API 29 and 35. They exercise multiple
handles, restored selection, primary-slot migration, confirmation/cancellation,
offline/repair states, host-scoped storage effects, blocked delete acknowledgements,
failed-delete retry and catalog failure recovery. Core harness tests separately
exercise the real revoke RPC and storage protocol. No phone/emulator was available.

### Exact on-phone checks (H-06/H-07 pending)

1. Install the retained APK with `adb -s SERIAL install -r /home/rtg/development/verde-wt/artifacts/D-04/SHA/app-debug.apk`.
   Launch with `adb -s SERIAL shell am start -n dev.verdeai.app/.MainActivity`.
2. For an upgrade from D-03, confirm “My host” restores its existing pairing.
   Otherwise open “Pair / review host” and pair using a fresh host QR/link; confirm
   the displayed trust proposal. Return using “Back to hosts”.
3. Tap “Add host”, enter a distinct label, continue and pair a second runtime.
   Confirm both rows and their status text/dots. Use each host, then “Switch host”.
   Rotate, background/foreground, and force-stop/reopen; confirm selection and both
   pairings survive and the selected label always belongs to the intended host.
4. With both hosts reachable, tap “Sign out of host” on one row. Cancel once and
   confirm it stays connected. Confirm sign-out the second time; verify the row
   becomes “Signed out” only after removal, and desktop Paired devices shows that
   device revoked. The other host must remain usable. Tap “Pair again”, use a fresh
   grant and confirm a new trust prompt and successful pairing in the same slot.
5. Turn off Tailscale or stop that host, then sign out. Verify unconfirmed wording;
   cancel “Remove from this phone anyway” once and confirm the pairing persists.
   Restore connectivity and retry sign-out, or repeat offline and confirm “Remove
   anyway”. Verify the desktop warning and eventual local Signed out state. If
   forgotten offline, revoke the orphaned device from desktop Paired devices.
6. Revoke a paired phone from the desktop, then foreground/retry on Android.
   Confirm “Pair again” authorization status rather than a generic network error;
   local sign-out must still finish. Remove the active signed-out row and confirm
   selection falls back to the other host. Remove the last row and confirm the
   empty list offers Add host.
7. Keystore locked/failing writes and delayed deletion acknowledgements are
   deterministically covered by Robolectric. On a device, verify credential restore
   after lock/unlock and process restart; do not induce failure by deleting app
   files or keys. Native JNI, real Keystore, VPN and TLS behavior remain phone checks.
