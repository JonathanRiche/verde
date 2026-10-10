# Omarchy / Hyprland browser remote desktop host

`scripts/remote-desktop/omarchy.py` prepares and runs an opt-in WayVNC host for
an **existing graphical session owned by the current user**. It requires Linux,
Python 3.9+, `hyprctl`, and WayVNC. It has no Verde GUI, portal, root, or service
manager dependency. Installing packages is a separate administrator action;
this helper does not install anything, modify Hyprland/Omarchy configuration,
start a compositor, or arrange automatic startup.

## Supported interfaces and validation status

The helper supports WayVNC **0.9.1–0.9.x and 0.10.x** command-line interfaces.
Versions outside those families fail closed pending review. Version 0.9.1 uses
`--unix-socket PATH`; 0.10.x uses `unix:PATH`. Both expose raw RFB over the Unix
socket, without WebSocket framing. See the official
[0.9.1 manual](https://github.com/any1/wayvnc/blob/v0.9.1/wayvnc.scd) and
[0.10.1 manual](https://github.com/any1/wayvnc/blob/v0.10.1/wayvnc.scd).

Hyprland must provide the capture and virtual keyboard/pointer protocols needed
by the installed WayVNC. A Hyprland version number alone cannot prove this or
prove that capture permission is granted. The helper checks the inherited
Wayland socket and queries active monitors; WayVNC makes the actual protocol
negotiation. `--view-only` disables virtual input requirements. No Omarchy or
Hyprland release is claimed as end-to-end certified yet: validation here uses
isolated fake binaries and Unix sockets, not a live desktop. Record `doctor`
output and perform a consented browser capture/input check for each deployed
host combination.

## Setup and explicit start

Run these commands as the session owner, from a terminal with the existing
Hyprland environment. Do not use `sudo`. From the repository root:

```sh
python3 scripts/remote-desktop/omarchy.py doctor
python3 scripts/remote-desktop/omarchy.py setup
python3 scripts/remote-desktop/omarchy.py run --output eDP-1 --view-only
```

Replace `eDP-1` with an active output listed by `doctor`. `setup` creates only
`$XDG_RUNTIME_DIR/verde-remote-desktop` with mode 0700. It does not start WayVNC.
`doctor` is read-only and starts no listener. `run` is the explicit consent to
share the selected display; omit `--view-only` to allow keyboard and pointer
control. Keep it in the foreground and use Ctrl-C to stop. Existing inactive
outputs are rejected and automatic remote resizing is disabled.

Environment requirements: `XDG_RUNTIME_DIR` must be an absolute, canonical,
owner-only (0700) directory; `WAYLAND_DISPLAY` must name the owner's actual
Wayland socket; `HYPRLAND_INSTANCE_SIGNATURE` must identify that same session.
If `XDG_SESSION_TYPE` is set, it must be `wayland`. SSH sessions do not necessarily
inherit these values. Obtain them from the intended existing session rather
than guessing a display number or importing another user's environment.

The helper creates a temporary 0600 WayVNC config containing only
`enable_auth=false`, uses umask 077, and overrides the default config. This keeps
unrelated global WayVNC settings from exposing another listener. A separate
private control socket avoids collisions with other WayVNC instances.

## Gateway integration contract

Configure the gateway explicitly with the absolute filesystem path:

```text
/run/user/<uid>/verde-remote-desktop/vnc.sock
```

Pass it using `verde-web --desktop-socket "$XDG_RUNTIME_DIR/verde-remote-desktop/vnc.sock"` alongside the usual gateway arguments. Use the actual `XDG_RUNTIME_DIR` when different. The gateway and helper run as
the **same UID**. The gateway must authenticate and authorize the browser before
opening this endpoint, and carry browser traffic over the deployment's secure
transport. The VNC server uses RFB security type None: local Unix filesystem
permissions are its access boundary, not a VNC password. Processes running as
the same user (and root) can access the desktop through it.

Validate that the endpoint is an owned Unix socket, its directory is owned and
0700, and neither is a symlink. Do not accept browser-supplied paths, discover
arbitrary VNC servers, or fall back to TCP. The helper intentionally offers no
loopback mode: loopback TCP alone cannot restrict access to the owning user.
Proxy raw RFB bytes bidirectionally to/from the browser's authenticated
WebSocket. Do not connect to `control.sock`, which is WayVNC's separate JSON IPC
interface. No websockify process is required for this contract.

Exact host launch equivalents (the helper selects the appropriate one):

```sh
# WayVNC 0.9.1–0.9.x:
wayvnc --config="$private_config" --socket="$private_dir/control.sock" \
  --disable-resizing --output=eDP-1 --unix-socket "$private_dir/vnc.sock"
# WayVNC 0.10.x:
wayvnc --config="$private_config" --socket="$private_dir/control.sock" \
  --disable-resizing --output=eDP-1 "unix:$private_dir/vnc.sock"
```

Add `--disable-input` for keyboard/pointer view-only operation. This is not a
general RFB data-loss policy: do not infer that clipboard traffic is disabled.
The gateway/UI must separately enforce any clipboard restrictions.

The printed endpoint is a destination, **not a readiness acknowledgment**.
The gateway should handle missing/refused sockets and require a successful RFB
handshake. A socket file's presence does not prove the server is alive. Output
selection does not isolate applications: anything visible on that monitor is
shared, and remote keyboard/pointer control acts on the user's real session.

## Stop and cleanup

Ctrl-C, SIGTERM, or SIGHUP stops the helper's child, waits up to five seconds,
then kills only that child if necessary. It removes the sockets created by that
run and its temporary config. The 0700 directory and empty `run.lock` remain
for reuse. The lock prevents concurrent helper instances and is inherited by
WayVNC so killing only the wrapper cannot allow a second host to replace it.
Never delete `run.lock` while a host may be running.

SIGKILL, power loss, or an independently launched server can leave artifacts.
The helper refuses existing endpoints instead of unlinking them automatically.
Inspect the explicit paths with `ss -xlpn` and the owning process first. Once
you have confirmed that no host uses this directory, remove only its stale
`vnc.sock`, `control.sock`, and `wayvnc-*.conf` files. Do not kill other WayVNC
instances or remove their control sockets. Runtime files normally disappear
when the user's runtime directory is removed at logout.

## Headless, lock and permissions limitations

This shares the logged-in desktop; it is not a login manager, remote unlock
service, or unattended recovery mechanism. Logging out, suspending, locking,
DPMS, or removing a display can interrupt capture or input. Lock-screen behavior
depends on the compositor, locker, and protocol versions; it is not certified
here. Keep a local/SSH recovery path, and stop sharing before locking when
remote access is no longer desired. The helper does not bypass locks, inhibit
idle, change power management, or keep a session alive.

Hyprland can create virtual outputs through its
[hyprctl output interface](https://wiki.hypr.land/configuring/core/advanced-configuration/using-hyprctl/),
and its [virtual GPU guide](https://wiki.hypr.land/configuring/extra/virtual-gpu/)
discusses remote display access. Those are separate host provisioning tasks.
This helper neither creates headless outputs nor starts a second compositor.
An already-created active virtual output may be selected explicitly. Do not
copy wlroots `WLR_BACKENDS` recipes into modern Hyprland setup without checking
the installed compositor's documentation.

When Hyprland permission enforcement is enabled, direct capture may require
local approval. A black image with permission-denied text indicates a capture
permission issue. Consult the
[current permission guide](https://wiki.hypr.land/configuring/core/advanced-configuration/permissions/)
or the [0.54 configuration guide](https://wiki.hypr.land/0.54.0/Configuring/Permissions/)
matching the installed release. Syntax differs between Lua and older config
formats, and permission rule changes require a compositor restart. The helper
does not edit these rules, disable enforcement, approve prompts, or restart
Hyprland/Verde. Its CLI itself requires no permission-dialog GUI, but local
policy may still require an interactive approval before capture works.

## Troubleshooting and verification

- Missing dependencies: provision Python, Hyprland tools, and a supported
  WayVNC separately; `doctor` reports missing executables.
- Missing environment/socket: use the intended graphical session's environment;
  do not launch a second compositor or use root to work around ownership.
- Unsafe directory: inspect ownership, mode and symlinks. The helper deliberately
  does not repair existing paths or follow symlinks.
- Unsupported protocols: read WayVNC's foreground error. Try `--view-only` for
  missing input protocols; it cannot repair missing capture protocols.
- Wrong/blank monitor: verify `hyprctl monitors`, output name, capture permission,
  lock and power state locally. A successful `doctor` is only a preflight.
- Browser unavailable: verify gateway authentication/configuration, same UID,
  socket permissions and actual WayVNC process readiness. Do not expose port 5900.
- Keyboard mismatch: compare the host's XKB environment with the client layout.
  This minimal helper does not modify keyboard configuration.

Focused verification, with no real server or desktop capture:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/remote-desktop/omarchy_test.py
python3 scripts/remote-desktop/omarchy.py --help
```
