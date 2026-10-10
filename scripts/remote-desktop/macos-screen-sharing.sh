#!/usr/bin/env bash
# Passive macOS VNC listener inventory. Never connects or changes host settings.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: macos-screen-sharing.sh --guide
       macos-screen-sharing.sh --diagnose --port PORT

--guide prints manual, opt-in setup guidance on any platform.
--diagnose inventories visible TCP listeners on macOS; PORT is required.
No connections, authentication, credentials, sudo, or system changes.
Exit: 0 guide/help or observed loopback-only; 1 non-loopback binding;
      2 invalid arguments; 3 unknown (unsupported host/tool/visibility).
Exit 0 is NOT proof of VNC compatibility, reachability, or safe configuration.
EOF
}

guide() {
  cat <<'EOF'
macOS browser desktop: experimental, requires manual Mac validation.

1. Review docs/remote-desktop-macos.md before enabling anything.
2. In System Settings > General > Sharing, inspect Screen Sharing or
   Remote Management. They cannot both be enabled. Do not change a managed
   Mac's existing policy just to use Verde.
3. If you choose to enable sharing, configure access in Apple's UI yourself.
   Classic VNC uses the separate "VNC viewers may control screen with password"
   option. Never reuse an account password for that option. ARD authentication
   instead needs a client/UI supporting both username and password.
4. Run this helper with --diagnose --port 5900 (or your explicit VNC port).
   A wildcard/LAN listener is outside Verde's private gateway boundary.
   Review IPv4/IPv6 exposure and firewall/network policy before connecting.
5. Configure Verde's common gateway with an explicit literal loopback endpoint
   for the actual listener. Native Screen Sharing has no documented Unix-socket
   or loopback-only bind option in Apple's Sharing UI. No endpoint is installed
   or auto-discovered by this helper.
6. Enter credentials only in the private viewer's interactive authentication
   prompt, when supported. Never put them in commands, URLs, logs, or config.

The gateway's owner-only access does not protect direct access to Apple's VNC
listener, including from other local users. This inventory does not inspect
firewall policy, permissions, passwords, RFB negotiation, or screen contents.
No service is started, stopped, enabled, disabled, or contacted.
EOF
}

case "${1:-}" in
  --help|-h) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
  --guide) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; guide; exit 0 ;;
  --diagnose) ;;
  *) usage >&2; exit 2 ;;
esac

# Reject arbitrary inputs without echoing them: a mistaken argument may be a secret.
if [[ $# -ne 3 || "$2" != --port || ! "$3" =~ ^[1-9][0-9]{0,4}$ ]]; then
  usage >&2
  exit 2
fi
port="$3"
if (( port > 65535 )); then
  usage >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'UNKNOWN: diagnostic requires macOS; no host support was validated.'
  exit 3
fi
if ! command -v lsof >/dev/null 2>&1; then
  echo 'UNKNOWN: lsof unavailable; inspect sharing and listener exposure manually.'
  exit 3
fi

echo "Passive inventory of TCP port $port; no connection or authentication attempted."
# -a intersects port and LISTEN selection; -nP prevents DNS/service lookup.
# Only name fields are consumed, never process command lines or preferences.
# Without elevated privileges the result may be incomplete. Keep errors private.
inventory_status=0
inventory="$(lsof -nP -a "-iTCP:$port" -sTCP:LISTEN -Fn 2>/dev/null)" || inventory_status=$?
loopback=0
other=0
while IFS= read -r field; do
  case "$field" in
    n*)
      address="${field#n}"
      if [[ "$address" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+:$port$ || "$address" == "[::1]:$port" ]]; then
        loopback=$((loopback + 1))
      else
        other=$((other + 1))
      fi
      ;;
  esac
done <<< "$inventory"

echo "Visible loopback listener records: $loopback; wildcard/non-loopback/unrecognized records: $other."
echo 'Visibility may be incomplete; no firewall, sharing permission, or VNC compatibility check was performed.'
if (( other > 0 )); then
  echo 'REVIEW: a binding outside recognized loopback was observed; direct VNC access can bypass Verde.'
  echo 'A loopback gateway destination does not restrict the native listener. Review host/network policy.'
  exit 1
fi
if (( inventory_status != 0 || loopback == 0 )); then
  echo 'UNKNOWN: no reliable listener inventory; sharing may be off or listeners may be hidden.'
  echo 'Do not treat this as proof that Screen Sharing is disabled or inaccessible.'
  exit 3
fi
echo 'OBSERVED: only loopback records were visible. Other local users can still access TCP listeners.'
echo 'This is not a readiness or security pass. Verify the actual Mac and bundled viewer manually.'
