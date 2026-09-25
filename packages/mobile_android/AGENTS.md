# Android app

Follow [root rules](../../AGENTS.md), the [mobile plan](../../docs/mobile-app-plan.md)
and [core rules](../client_core/AGENTS.md) when changing the native bridge.

- Kotlin, Jetpack Compose, Material 3; min SDK 29; application ID `dev.verdeai.app`.
- Thin native UI over the sans-IO Zig core. No agents, providers, PTYs or workspace
  files on the phone. No desktop-mirror RPCs.
- JNI uses `dev.verdeai.core.Native`, `System.loadLibrary("verde_client")`, and
  `@JvmStatic external fun` declarations. Never hide native load failures.
- Run `mise run mobile-android-build` and `mise run mobile-android-test` from the
  repo root. Lease `build` for the Zig builds. Generated `.so` files belong under
  `app/build/generated/jniLibs`, never in source control.
- Test with fixtures and Robolectric; JNI requires an emulator or device.

## Security contract (plan §7)

- The device credential exists only in secure storage (Android Keystore-backed
  encryption); no cloud backup. Keep `android:allowBackup="false"`.
- Tokens are held in memory only.
- Nothing sensitive in logs, crash reports, URLs or analytics (including
  credentials, pair codes, message content and clipboard contents).
- TOFU-pin the host's TLS key on first pair, with a clear re-trust flow.
  Tailscale certificates rotate, so pin the key or issuer, not the leaf.
- No owner token entry at all. No cleartext traffic.

## Lifecycle contract

- Foreground: refresh token if needed, mint ticket, open WS, catch up from the
  cursor, resume tails.
- Background: close WS within a few seconds and stop polling; push takes over.
- Network change: reconnect with the core's jittered backoff.
