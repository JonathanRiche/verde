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
