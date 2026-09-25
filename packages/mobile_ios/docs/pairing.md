# iOS pairing (I-03)

The screen submits generated `pair`, `trust_decision`, and `retry_connection`
events to `CoreHost`. Native/custom links, pasted text and manually formatted
links all go through the core parser. Swift only recognizes the incoming route;
it never authorizes an origin or parses/exchanges a grant. A fresh random nonce
is supplied once per user submission; the core retains it across safe retries.
No pairing link or secret is written to preferences, logs or analytics. Input
fields clear on submission/background. The only preference is the local host
ID, so the same Keychain records can be reopened after app termination. I-04
will replace this single-host entry point with the host list and switcher.

Core trust proposals display the origin, runtime and SHA-256 SPKI fingerprint.
Profile and credential writes run through I-02's Keychain adapter, with
`AfterFirstUnlockThisDeviceOnly` and synchronization disabled. Pair completion
is rendered only after durable credential acknowledgement. Failed storage is
retryable without a second exchange. Lost replies are retried only by the core;
legacy uncertainty asks for a new grant. TLS checks use canonical lowercase
64-character hex, matching K-07. System certificate validation remains required.

VisionKit scans QR only and stops after one result or dismissal. Unsupported
hardware, denied/restricted permission and scanner failures offer paste/manual
fallbacks. Both SwiftUI `onOpenURL` and browsing `NSUserActivity` handlers are
installed. URL input errors are transactional core rejections, not a fatal
adapter failure, so correcting a link keeps the host usable.

## Follow-ups

- H-04: after the owner supplies the Apple Team ID and signing, add the
  `applinks:verdeai.dev` Associated Domains entitlement to `project.yml`, and
  serve the matching Team-ID + `dev.verdeai.app` AASA entry for `/pair` on the
  website. Do not invent a Team ID. The HTTPS handler and core parser already
  work; automatic Safari/Camera handoff is not enabled without this association.
- H-06: install/sign into Tailscale on the test phone before live verification.
- I-04: multiple hosts, Home/Workspaces navigation, and network monitoring.
  I-03 forwards foreground/background to prevent pairing traffic continuing
  while backgrounded. The paired confirmation is the current destination.
- I-12: repeat build/test on the newer App Store CI SDK.

## Automated and human verification

Run `mise run mobile-ios-build` and `mise run mobile-ios-test` on the Mac via
SSH after pushing Linux edits; run `mise run mobile-models-check` on Linux.
Tests use the real core with an isolated in-memory secure-store substitute and
scripted transport: both link forms, malformed/unsafe input recovery, explicit
trust/denial, durable writes, storage retry, and identical lost-reply exchange.
I-02 separately verifies the actual Keychain queries and TLS delegates. The
unsigned simulator cannot prove device Keychain entitlements or camera behavior.

Once signing and Tailscale are ready:

1. Install the development app via the Mac. Create a fresh grant from the
   desktop or CLI; scan its terminal/desktop QR in the app. Check device label,
   host identity and fingerprint, deny once, then use a new grant and accept.
2. Pair using paste and manual host/grant/code entry. Try a malformed link and
   an expired/used grant; check correction/new-grant guidance. Never send the
   actual link or credentials in verification reports.
3. Disable camera permission and verify paste/manual remain usable; re-enable
   permission via Settings. Dismiss/reopen scanning and background the app.
4. Interrupt Tailscale during exchange; restore it and retry. Confirm one
   device is created when the host advertises idempotent exchange. Lock/unlock
   and relaunch the app; confirm saved pairing is reused.
5. Revoke the phone on the host and verify re-pair guidance. With a controlled
   valid-certificate key change, verify explicit re-trust before authentication.
6. After H-04 association setup, tap the HTTPS App Link from Notes/Camera and
   check cold/warm launch routing; also test the `verde://pair` custom scheme.
