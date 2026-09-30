# Google Play release preparation

Package: `dev.verdeai.app`. First destination: Internal testing; production remains a separate rollout. Integrate separately reviewed Android fixes before selecting a public-release commit.
Organization accounts are not subject to the new-personal-account 12-testers/14-days gate.

## Build and signing

Install Android SDK platform 36 and build-tools 36.0.0. Run the normal Android build/tests from the repository root under a build lease.

Use Play App Signing and a separate upload key. Keep the upload keystore and its backup outside the repository, with restricted access. Have the owner retain the passwords in their password manager. Do not paste them into chat, commits, or command-line arguments.

The release build reads these environment variables from a local secret manager or CI secret store:

- `VERDE_ANDROID_UPLOAD_KEYSTORE`: absolute path to the external upload keystore.
- `VERDE_ANDROID_STORE_PASSWORD`
- `VERDE_ANDROID_KEY_ALIAS`
- `VERDE_ANDROID_KEY_PASSWORD`
- `VERDE_ANDROID_VERSION_CODE`: positive integer, greater than every previously uploaded version.
- `VERDE_ANDROID_VERSION_NAME`: user-visible release version.

Run `mise run mobile-android-play-bundle`. It refuses to run when signing/version inputs are missing. Output: `packages/mobile_android/app/build/outputs/bundle/release/app-release.aab`.

For local packaging verification without credentials, `bash packages/mobile_android/run-gradle.sh bundleRelease` produces an **unsigned** bundle. It is not upload-ready. Never substitute the debug signing key for the release upload key.

After Google creates the app-signing certificate, use its SHA-256 certificate fingerprint for the website's Android App Links association (`/.well-known/assetlinks.json`). The upload certificate and debug certificate are different. Test pairing links with a Play-installed build.

A Play-signed app may not replace a debug-signed installation of the same package. Plan the tester transition: removing the debug app loses its local pairing, so it needs pairing again. Do not uninstall the owner's app automatically.

## Console setup and remaining owner inputs

1. Create Verde as an app, choose language and free/paid distribution, and enter a public support email.
2. Configure Play App Signing and upload the signed AAB to Internal testing.
3. Add tester Google accounts and share the opt-in link.
4. Supply store text, 512×512 icon, 1024×500 feature graphic and actual phone screenshots.
5. Complete privacy policy, Data safety, target audience, content rating, ads and app-access declarations based on the actual release and included SDKs. Do not assume “no data collected” merely because workspace processing happens on a paired host.
6. Provide review access to an isolated demo host and scratch workspace. Reviewers need usable access throughout review, not a short-lived pairing code or access to the owner's real machine.
7. Check pre-launch findings before a production rollout.

Pending: support email; public privacy-policy URL and organizational privacy details; owner backup of the upload key; Console/browser access; reviewer-host setup; store graphics/screenshots; final policy declarations. This preparation does not create a Console app or publish any release.

## Listing draft

Name: Verde

Short description: Manage AI coding chats and terminals from your phone.

Full description:

Verde brings your paired Verde host to your Android phone. Browse workspaces, follow AI coding conversations, send prompts and follow-ups, and review progress while away from your computer.

- Find and switch between workspace chats.
- Follow responses, tool activity and approval requests.
- Attach images and reference workspace files in your prompts.
- Open host terminals when your device has terminal access.
- Review and commit chat changes when your paired-device permissions allow it.

Verde is a companion app. You need a running Verde host and network access to that host. Pair your phone with your host to get started. Available actions depend on the permissions granted to your device and the capabilities of your host.

## Official references

- https://support.google.com/googleplay/android-developer/answer/9859152
- https://support.google.com/googleplay/android-developer/answer/9842756
- https://support.google.com/googleplay/android-developer/answer/9845334
- https://developer.android.com/about/versions/16/setup-sdk
