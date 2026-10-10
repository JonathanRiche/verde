# macOS host: opt-in Screen Sharing research and diagnostics

Status: **experimental integration candidate, not validated on a Mac**. The helper
and its fixture tests were developed on Linux. They do not establish that Apple
Screen Sharing works with Verde's bundled noVNC, or that capture/input permissions
are granted. No service or sharing setting is changed by these files.

Research reviewed 2026-09-25. Apple documentation and upstream noVNC links are
living references; their capabilities do not substitute for testing the versions
actually shipped and installed.

## Contract with the common browser desktop gateway

Use the shared owner-authorized gateway and its separate **binary WebSocket** for
RFB bytes. The host configuration must explicitly name a local Unix VNC socket or
a literal loopback TCP endpoint; the browser must not choose arbitrary targets.
Native Apple Screen Sharing is a TCP candidate: Apple assigns TCP 5900 to screen
control/observation. Neither a Unix VNC socket nor a loopback-only binding is
documented in Apple's Sharing UI. Do not invent a native socket path. An
independently installed VNC server with a private socket is a separate backend,
requiring its own setup and validation. See Apple's [port reference](https://support.apple.com/guide/remote-desktop/apd0c903fec/mac).

No new gateway flags, runtime routes, dependencies, or automatic discovery are
introduced here. For a native listener accepting IPv4 loopback, the conceptual
destination is `127.0.0.1:5900`; use `--desktop-port 5900` alongside the usual gateway arguments. The first implementation supports IPv4 loopback only.
An IPv6-only listener needs the corresponding literal `::1` destination if the
gateway supports it. A configured destination is not evidence of a working RFB
session. These instructions assume the gateway runs on the Mac hosting VNC;
loopback on a Linux gateway does not refer to a different Mac.

The browser client needs an interactive, non-persisted credential prompt wired to
noVNC's `credentialsrequired` event and `sendCredentials()` API for whichever
authentication is selected. ARD needs username **and** password; a password-only
UI cannot complete that mode. Keep credentials out of URLs, arguments, logs,
gateway configuration, analytics, and browser storage. See the [noVNC API](https://github.com/novnc/noVNC/blob/master/docs/API.md).

## Native capabilities and compatibility limits

Apple documents Screen Sharing and Remote Management as mutually exclusive, with
per-user access settings and an optional “VNC viewers may control screen with
password” mode. Manual setup lives under System Settings > General > Sharing.
The native service shares a Mac desktop and can permit substantial control; it is
not a Verde-isolated desktop. See [Apple's Screen Sharing instructions](https://support.apple.com/guide/mac-help/mh11848/mac).

Upstream noVNC advertises Apple's Diffie-Hellman authentication and classic VNC.
Its RFB implementation recognizes Apple's `003.889` banner, negotiates RFB 3.8,
and implements ARD security type 30 and classic VNC security type 2. Thus a blanket
claim that native Apple VNC is incompatible is incorrect. This is source-level
evidence, not a successful session with Verde's pinned version. Record the exact
noVNC version and macOS build when testing. See [noVNC features](https://github.com/novnc/noVNC#features)
and [RFB implementation](https://github.com/novnc/noVNC/blob/master/core/rfb.js).

The TCP RFB bridge does not implement Apple's High Performance Screen Sharing
transport. Do not promise its virtual displays, stereo audio, HDR, or privacy
blanking. Apple describes a Mac-to-Mac facility with Apple silicon/macOS
requirements and UDP 5900–5902 connectivity. Those are outside this gateway's TCP
RFB scope. See [Apple's High Performance requirements](https://support.apple.com/guide/remote-desktop/apdf8e09f5a9/mac).

## Listener exposure is independent of gateway access

An owner-only browser gateway controls who may use **that gateway**. Forwarding
to `127.0.0.1` does not rebind Apple's listener, disable LAN access, or prevent a
second local user from connecting directly to TCP 5900. Wildcard listeners can
also accept loopback connections. IPv4 and IPv6 must both be considered. Apple
explicitly describes sharing with other computers on the network; do not assume
that turning it on is a local-only operation.

Before opting in, the operator must review listener bindings and host/network
access policy. A wildcard listener is not proof that a firewall permits incoming
traffic, but a successful loopback connection is not proof that it blocks it.
This helper cannot certify containment. If the deployment requires a strictly
owner-only backend, native Screen Sharing is not established to meet that
requirement: use a separately validated backend with enforced isolation, or leave
browser desktop disabled. A private socket adapter around an exposed TCP service
would not remove the original exposure.

Apple warns that non-Apple VNC access is less secure, may not encrypt input, and
grants extensive control. For classic VNC, use a separate VNC password, never an
account/admin password. Treat allowed-user settings and the shared VNC password
as different access mechanisms; do not assume the user list limits possession of
that password. Browser HTTPS/WSS protects its own hop, not unrelated direct VNC
clients. See [Apple's third-party VNC guidance](https://support.apple.com/guide/remote-desktop/apde0dd523e/mac).

## Manual opt-in and passive diagnostic

From the repository root:

```sh
bash scripts/remote-desktop/macos-screen-sharing.sh --guide
# On the Mac, after reviewing the exposure implications:
bash scripts/remote-desktop/macos-screen-sharing.sh --diagnose --port 5900
```

The guide works on any OS. Diagnostic mode requires macOS and `lsof`, requires an
explicit numeric port, and inventories only visible TCP listeners. It performs
no connection, RFB handshake, authentication, preference/password read, capture,
firewall edit, permission grant, package installation, or service launch. It does
not invoke `sudo`. It reports counts, not process arguments, hostnames, or raw
diagnostic errors. No endpoint or secret is stored. Rejecting unknown arguments
does not echo them; still never supply credentials on a command line.

| Exit | Meaning |
| --- | --- |
| 0 | Guide/help printed, or all observed listener records were loopback. Not a readiness/security pass. |
| 1 | Wildcard, non-loopback, or unrecognized binding observed; review exposure. |
| 2 | Invalid invocation. |
| 3 | Unknown: non-macOS host, missing tool, tool failure, or no visible listeners. |

An unprivileged inventory can miss system-owned listeners. Empty output does not
prove Screen Sharing is disabled. The helper cannot identify the service behind a
port or verify passwords, permissions, firewall policy, or noVNC compatibility.

To opt in manually, inspect Apple's Sharing UI. Do not replace managed Remote
Management policy with Screen Sharing. Choose access deliberately; only enable
classic VNC password mode if that is the authentication path being tested. Do not
enable anonymous access as a workaround. Configure the explicit gateway endpoint
only after exposure review. Enter credentials through the viewer's interactive
prompt when implemented. To undo the opt-in, disable the setting you enabled in
Sharing and remove the gateway endpoint using its normal configuration UI; do not
disable a pre-existing managed service.

Verde's gateway is a byte relay, not a macOS screen capture or input injector.
Sharing authorization remains with the native host service. This helper neither
requests nor checks Screen Recording/Accessibility permissions and does not
modify TCC. A third-party server may have its own capture/input consent needs;
grant only permissions its documented setup requires. If viewing works but input
does not, inspect host policy and negotiated mode; do not broadly grant Verde or
a shell additional permissions as a guess.

## Required Mac validation before claiming support

Record macOS build, hardware, bundled noVNC version, browser/secure context,
native sharing mode, selected security type, and loopback address family. Do not
record credentials, challenges, clipboard data, or screen contents.

1. Inspect IPv4/IPv6 listeners and independently review direct network exposure.
   Verify the owner-only gateway denies unauthorized access.
2. Test a permitted native authentication mode through the actual binary
   WebSocket gateway. ARD requires a username-capable prompt; classic VNC requires
   the separate opt-in password setting. Report unsupported negotiation exactly.
3. Check initial framebuffer, updates, pointer/buttons, keyboard layout/modifiers,
   disconnect/reconnect, and cancellation. A listening port or RFB banner alone
   is insufficient. Test only a consented session with no sensitive content.
4. Separately record behavior with locked screen, login window, multiple displays,
   sleep/wake, headless operation, and session switching. No support claim for
   these cases follows from a logged-in single-display test. Leave clipboard and
   other unvalidated capabilities out of the support claim.
5. Disable any sharing explicitly enabled for the test and restore only the
   settings you changed. Do not restart Verde from a Verde-hosted session.

Local verification is limited to Bash syntax and mock-command fixtures:

```sh
bash -n scripts/remote-desktop/macos-screen-sharing.sh
bash scripts/remote-desktop/macos-screen-sharing-test.sh
```

The fixtures run without live services, network sockets, or system changes. The
parent feature integration owns aggregate builds and actual Mac sign-off.
