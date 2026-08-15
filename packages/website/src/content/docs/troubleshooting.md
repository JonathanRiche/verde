---
title: Troubleshooting
description: Provider readiness, browser and Design Mode support, updates, source-build errors, and runtime logs.
section: Reference
order: 9
slug: troubleshooting
---

## Provider prompt sending fails

If sending a prompt produces an error instead of streaming a reply, check in
this order:

1. **Is the provider installed?** Run `which codex`, `which opencode`, `which agent`, etc., from the shell Verde was launched in. GUI launches on some platforms inherit a different `PATH` than a terminal — relaunch Verde from a terminal if you suspect this.

   ```bash
   which codex
   which opencode
   which agent
   ```

2. **Is the provider authenticated?** Re-run the provider's login command and confirm credentials are still valid:

   ```bash
   codex login
   agent login
   ```

   Claude Code is authenticated through its own SDK; Verde has no Verde-side
   login for it. Make sure the Claude Code binary and `node` are both reachable
   from the shell environment Verde was launched from.

3. **Is the project imported?** Verde runs the provider against the imported project directory. A provider CLI in a different working directory will not see the same files.

4. **Check the logs.** Provider helper stderr is written to the runtime log alongside Zig panics. On Linux:

   ```bash
   tail -f ~/.local/share/verde/Native/logs/verde.stderr.log
   ```

For provider-specific setup, see [Provider setup](/docs/providers).

## Provider readiness does not update

After installing a provider CLI or completing its login flow, return to
**Connect an AI provider** and choose **Check again**. If its state still says
**CLI not found**, launch Verde from the same shell where the provider command
works; desktop launchers can inherit a different `PATH`. If it says **Sign-in
needed**, run the provider's login command outside Verde and retry. A timed-out
or failed probe appears as **Could not verify** and should be checked against
the runtime log.

Grok and Amp never appear on this screen because they are terminal-only
providers.

## Linux browser runtime missing

The embedded browser pane on Linux uses the system WPE WebKit runtime — there
is no bundled Chromium. If the required libraries are missing, the installer
warns and prints the install command for your distribution. The libraries
Verde looks for are:

- `libWPEWebKit-2.0.so`
- `libWPEBackend-fdo-1.0.so`
- `libjavascriptcoregtk-6.0.so`
- `libEGL.so.1`
- `libGLESv2.so.2`

Install them by distribution:

| Distro       | Command                                                                                       |
| ------------ | --------------------------------------------------------------------------------------------- |
| Arch         | `sudo pacman -S wpewebkit wpebackend-fdo`                                                    |
| Debian 13+   | `sudo apt-get update && sudo apt-get install libwpewebkit-2.0-1 libwpebackend-fdo-1.0-1 libjavascriptcoregtk-6.0-1 libegl1 libgles2` |
| Fedora       | `sudo dnf install wpewebkit wpebackend-fdo`                                                   |
| openSUSE     | `sudo zypper install libWPEWebKit-2_0-1 libwpebackend-fdo-1_0-1 libjavascriptcoregtk-6_0-1 libEGL1 libGLESv2-2` |

You can also let the installer install them by setting
`VERDE_INSTALL_BROWSER_DEPS=1` before running it:

```bash
curl -fsSL https://verdeai.dev/install.sh | VERDE_INSTALL_BROWSER_DEPS=1 sh
```

## WebView2 on Windows

Windows native-webview builds use Microsoft WebView2. Windows systems that do
not include WebView2 need the Microsoft WebView2 Runtime installed separately,
and packaged builds must ship or locate `WebView2Loader.dll` next to
`verde.exe` or on the DLL search path. The Windows native-webview build also
requires the Microsoft WebView2 SDK headers at compile time.

## Design Mode has no screenshot

The element and region selector works with WPE WebKit on Linux, WKWebView on
macOS, and WebView2 on Windows. Selection screenshots currently require the
Linux WPE backend's frame-copy support. On macOS and Windows, Verde sends the
instruction and DOM context without an image; this is expected. See
[Design Mode](/docs/design-mode) for routing details.

## Update check or install fails

Open **Settings → Updates** and choose **Check now** again. Update checks and
installers need access to GitHub release metadata and assets. If the in-app
flow still fails, run:

```bash
verde update --json
```

The JSON error is suitable for scripts and issue reports. Standalone
Linux/macOS installs need `curl`; Windows uses PowerShell. A `verde-bin`
installation owned by pacman needs either `yay` or `paru`, and the in-app flow
opens that helper in a terminal pane. You can always use the install command on
the [homepage](/#install) to replace a standalone installation manually.

## Source-build errors

Source builds require Zig `0.16.0` and SDL3 development files for your
platform. The default browser backend uses the host platform webview instead
of bundled Chromium. Linux builds also require WPE WebKit development
packages. The supported invocation from the repo root is:

```bash
mise run build
```

If you must call the build directly:

```bash
zig build --release=safe -Dbrowser-backend=native_webview
```

Common pitfalls:

- **Bare `zig build` does not compile.** It defaults to Debug + the WPE `verde-browser-linux` helper, which hits a `crt1.o` linker error. Always pass `--release=safe -Dbrowser-backend=native_webview`, or use `mise run build`.
- **Running `zig build` from `packages/desktop`.** That installs to `packages/desktop/zig-out`, not the top-level `zig-out/bin/verde` the app launches from. Always build from the repo root.
For release-style local installs, use the packaged install scripts:

```bash
bash ./scripts/release/install-linux-local.sh
./scripts/release/install-macos-local.sh
```

## Reading the runtime logs

Verde writes runtime logs under SDL's platform pref path. On Linux, the usual
paths are:

- `~/.local/share/verde/Native/logs/verde.stderr.log`
- `~/.local/share/verde/Native/logs/last-crash.log`

Those files capture Zig panic output, provider helper stderr, and the last
panic marker written before the app aborted. If the app crashes, the
`last-crash.log` is the single best place to start.

Discover the exact pref path on your machine:

```bash
verde state path --json
```

## Inspecting the live app

While the app is running, you can inspect a lot without touching the UI:

```bash
verde live status --json | jq '.result.browser'
verde live panes --project current --json
verde live processes --json
verde live inspect --focused --json
```

Exit code `3` means the live server is not running or not ready — start the app
first. See [CLI reference](/docs/cli) for the full command surface and exit
codes.

## Getting help

- [GitHub issues](https://github.com/JonathanRiche/verde/issues) for bugs and feature requests.
- [CLI reference](/docs/cli) and [Configuration & state](/docs/config) for the full programmatic surface.
- [Provider setup](/docs/providers) for provider-specific setup and authentication.
