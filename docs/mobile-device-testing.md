# Mobile device testing

How to install the Android app on a phone (or the emulator) and pair it with
this machine's Verde runtime over Tailscale.

## 1. Phone setup (once)

1. Install the Tailscale app on the phone and sign in to the same tailnet as
   the host. The host (`richetech`) must appear in the device list.
2. Settings → About phone → tap **Build number** 7 times to enable Developer
   options.
3. Settings → Developer options → enable **USB debugging**. For cable-free
   installs later, also enable **Wireless debugging** (see section 5).

## 2. Install the app

The cable is needed only for the first connection (or use wireless debugging).
Once installed, the app talks to the host over Tailscale.

1. Plug in the phone and accept "Allow USB debugging?" with **Always allow**.
2. On the host, adb lives in the Android SDK:

   ```bash
   export PATH="$HOME/Android/Sdk/platform-tools:$PATH"
   adb devices        # the phone must show as "device", not "unauthorized"
   adb install -r /home/rtg/development/verde-wt/artifacts/<task>/<sha>/app-debug.apk
   ```

   Agents copy each debug APK to
   `/home/rtg/development/verde-wt/artifacts/<task>/<sha>/app-debug.apk`; use
   the newest one.
3. Unplug. Reconnect only to install a new build or to collect logs with
   `adb logcat`.

## 3. Update the host runtime

The phone needs a daemon and web gateway built from current `master`. Agents
must not restart Verde, so the owner does this.

1. Quit Verde.
2. Update the checkout and build:

   ```bash
   cd ~/development/verde
   git stash && git pull --ff-only && git stash pop   # only if you have local edits
   mise run build
   ```

3. Relaunch Verde.
4. Restart the web gateway. It runs by hand from `packages/web_app`:

   ```bash
   cd ~/development/verde/packages/web_app
   mise run web-app    # rebuild
   ./zig-out/bin/verde-web --static dist --host 127.0.0.1 --port 6783 \
     --token-file ~/.local/share/verde/web/token \
     --trusted-proxy-origin https://richetech.tailc28f01.ts.net
   ```

   Tailscale Serve already maps `https://richetech.tailc28f01.ts.net` to
   `127.0.0.1:6783`; check with `tailscale serve status`.

## 4. Pair

1. Desktop: **Settings → Connections → Pair a phone**.
2. Paste `https://richetech.tailc28f01.ts.net` as the gateway URL, keep the
   **Full** preset, and create the link.
3. In the app, scan the QR code (or paste the link), confirm the host, then tap
   **Use richetech** to open Home.

Tailscale must be connected on the phone whenever the app is used.

## 5. Cable-free installs (wireless debugging)

Android 11+ can install over Wi-Fi.

1. Developer options → **Wireless debugging** → on → **Pair device with
   pairing code**.
2. On the host: `adb pair <ip>:<pairing-port>` and enter the code.
3. Then `adb connect <ip>:<port>` (the port shown on the Wireless debugging
   screen) and use `adb install -r ...` as above.

## Troubleshooting

- `adb devices` shows `unauthorized`: unlock the phone and accept the prompt.
- Pairing fails: confirm the phone's Tailscale is connected, and that
  `https://richetech.tailc28f01.ts.net` opens in the phone's browser.
- Collect logs: `adb logcat | grep -i verde` (the app never logs tokens,
  URLs or pair links).

## Emulator

A local emulator replaces the phone for install and UI checks. It needs no
Tailscale app, because its traffic goes out through the host's network stack.

### One-time setup (already done on `richetech`)

Everything is user-level under `~/Android/Sdk`; the AVD lives in
`~/.android/avd`. `/dev/kvm` must be readable and writable by your user
(`ls -l /dev/kvm`; otherwise `sudo usermod -aG kvm $USER` and log in again).

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
sdk="mise exec java@openjdk-17 -- $ANDROID_HOME/cmdline-tools/latest/bin"
yes | $sdk/sdkmanager emulator 'system-images;android-35;google_apis;x86_64'
echo no | ANDROID_AVD_HOME="$HOME/.android/avd" $sdk/avdmanager create avd \
  -n verde-pixel -k 'system-images;android-35;google_apis;x86_64' -d pixel_8
```

`verde-pixel` is a Pixel 8 profile (1080×2400) with 4 GB RAM, 4 cores and an
8 GB data partition (`~/.android/avd/verde-pixel.avd/config.ini`). Set
`ANDROID_AVD_HOME` when creating it: without it, `avdmanager` follows
`XDG_CONFIG_HOME` to `~/.config/.android/avd`, where the emulator cannot find it.

### Start, install, stop

```bash
mise run mobile-android-emulator                  # window; waits for boot (300 s deadline)
mise run mobile-android-emulator -- --headless    # no window, for agents
mise run mobile-android-install                   # newest APK, install -r, launch
mise run mobile-android-install -- --build        # assembleDebug first
mise run mobile-android-install -- --apk path/to/app-debug.apk
~/Android/Sdk/platform-tools/adb emu kill         # stop (or Ctrl+C in the emulator task)
```

- The emulator task runs in the foreground and owns the emulator. It prints
  `BOOTED verde-pixel as emulator-5554` once `sys.boot_completed` is set, then
  keeps running until the emulator stops. Run it in its own terminal or as a
  tracked process. If the AVD is already running, the task reports its serial
  and exits. Other options: `--timeout SECONDS`, `--wipe` (fresh data),
  `--avd NAME`, `--dns-server IP`.
- Without `--apk`, the install task picks the newest `app-debug.apk` under
  `../verde-wt/artifacts/` (next to the main checkout, including from
  worktrees) or `packages/mobile_android/app/build/outputs/apk/debug/`. It
  installs to `$ANDROID_SERIAL` or to the only connected device, and refuses
  to guess when several are connected.
- Each boot is a cold boot (about 40–50 s); installed apps and app data persist.
  On a busy host, a "System UI isn't responding" dialog can appear right after
  boot; tap **Wait**.
- The emulator ships only the X11 (xcb) Qt plugin, so the windowed mode
  starts after Qt logs a missing `wayland` plugin. That message is harmless.

### Screenshots

`adb exec-out screencap -p` returns an all-black image on this emulator build,
both windowed and headless. Use the emulator console instead:

```bash
adb emu screenrecord screenshot /home/rtg/development/verde-wt/artifacts/emulator/
```

This writes `Screenshot_<time>.png` (1080×2400) into that directory. Use
`adb shell uiautomator dump` to read on-screen text.

### Networking

Verified on 2026-09-26 with `verde-pixel` (API 35, google_apis):

- The emulator uses the host's resolver (systemd-resolved `127.0.0.53`), which
  forwards `*.tailc28f01.ts.net` to Tailscale MagicDNS. Inside the emulator,
  `richetech.tailc28f01.ts.net` resolves to `100.105.26.102` and responds to
  ping. `100.100.100.100` is reachable too.
- Chrome in the emulator opens `https://richetech.tailc28f01.ts.net`, is
  redirected to the verde-web `/login` page, and shows "Connection is secure".
  The Tailscale Let's Encrypt certificate is trusted by the Android system
  store. The app's TLS probe uses the same trust store.
- No `-dns-server` flag, Play Store image or Tailscale app is needed. Pair with
  the same gateway URL as a phone, `https://richetech.tailc28f01.ts.net`.
  Section 4 applies unchanged, except that you paste the pair link: the
  emulator's default camera is a virtual scene and can't scan the desktop QR
  code.
- If the host resolver changes and MagicDNS stops resolving inside the
  emulator, start it with `-- --dns-server 100.100.100.100`.
- `10.0.2.2` is the host's loopback from inside the emulator. Don't pair
  against `http://10.0.2.2:6783`: the app refuses cleartext traffic and the
  gateway expects the Tailscale origin.
