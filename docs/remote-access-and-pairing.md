# Remote Access and Pairing Without Commands

Status: design. Builds on [Serve, Pair, and Connect](serve-pair-connect.md)
and [Multi-Machine Workspaces](multi-machine-workspaces.md).

## Goal

Users never run a command to reach or pair a machine. Everything happens in
the desktop app (and the phone app). Agents and power users keep the
command-line path (`verde-daemon pair create --link-host`, `verde runtime
pair`, `pair_runtime` MCP tool).

Three kinds of "machine" a user can run chats on:

| Kind | Who has it | How it is reached |
| --- | --- | --- |
| This computer | everyone | Local, built in |
| Another computer of mine | users with 2+ machines | Remote access (Tailscale) + pairing |
| Verde Cloud | users without their own machines, or who want one always on | Connect (account sign-in) |

Verde Cloud must stay a first-class option everywhere a machine can be
chosen. A user with one laptop and Verde Cloud never sees Tailscale.

## Decisions

- **Tailscale only** for own machines, for now. It provides HTTPS and limits
  reach to the user's own tailnet. Plain LAN may come later.
- **Approval on the other machine** replaces the one-time code for
  computer-to-computer pairing: "lightning wants to connect · Allow / Deny".
  A short code shown on both screens is the fallback when nobody is at the
  other machine (for example a headless box), together with the existing
  link flow.

## 1. Remote access switch

Settings → **Remote access** on the machine being reached:

- **Off → On** runs the existing `verde-server serve --tailscale` flow from the
  app: user service (systemd user unit / launchd agent) for `verde-web` on
  loopback, Tailscale Serve mapping, idempotent. The app reads its JSON
  result; no terminal.
- Shows status: "Reachable at https://richetech.tail….ts.net", or the precise
  blocker with one action: Tailscale not installed (link), not signed in
  ("Open Tailscale"), Serve port taken by another app (offer the suggested
  port, never `tailscale serve reset`), Windows unsupported for now.
- **On → Off** uninstalls the Verde service and removes only Verde's own
  Serve mapping.
- Stays running after the app quits and across reboots, until switched off.
- **Version sync:** on every app start with Remote access on, if the
  installed service binary/dist differ from the app's, re-run the idempotent
  serve so the gateway always matches the app. (A stale gateway that did not
  know `workspace.attach` broke multi-machine setup on 2026-10-22.)
- The phone pairing card uses this origin automatically; the "paste host URL"
  step disappears.

## 2. Pairing another computer by approval

On the computer that wants to connect (Add connection):

1. **Nearby machines** lists Verde machines on the same tailnet: tailnet peers
   from the local Tailscale LocalAPI, probed over HTTPS for Verde's public
   runtime metadata. Each row: machine name, OS, "Connect".
2. **Connect** sends a pairing request to that machine's gateway with this
   computer's name and a fresh request id. The gateway accepts these requests
   only via Tailscale Serve (it records the Tailscale-User-Login / node
   headers Serve adds), rate-limits them, and expires them after 2 minutes.
3. The other machine's desktop shows a prompt: "lightning (j.riche64@) wants
   to connect · Allow / Deny", with the permission preset (default Full,
   changeable). Both screens show the same short code so the user can match
   them.
4. **Allow** mints the device credential exactly as a pairing grant exchange
   would; the requester polls with its request id and receives it once. The
   runtime identity is pinned without a separate confirm click, because the
   user just approved on the machine itself.
5. Deny, timeout, or closing the prompt fails the request with a clear
   message on the requesting side.

If no desktop app is open on the other machine, the request shows as a
notification when it next opens, until it expires. Headless machines use the
link or code flow.

## 3. Connection options audit

Every Add connection path must work end to end and say clearly what it is:

- **Nearby machine** (new, section 2).
- **Verde Cloud** (Connect): sign in, pick or create a runtime. Its
  reconnect loop on 2026-10-22 ("Connection lost; reconnecting") must be
  diagnosed as part of this work.
- **Pairing link** (paste a `verde://pair` link).
- **SSH** (advanced).

## Interaction with multi-machine workspaces

- Cloud runtimes have no existing checkouts. Their setup card offers
  **Clone** instead of **Pick folder**, which moves multi-machine phase 7
  (clone on a remote machine) ahead of phases 4–6.
- Run on lists Verde Cloud runtimes alongside own machines.

## Phases

1. Remote access switch with version sync; phone pairing uses its origin.
2. Nearby machines + approval pairing (gateway endpoint, daemon prompt
   event, desktop prompt, requester polling).
3. Connection options audit, including the Verde Cloud reconnect loop.
4. Clone for remote and cloud runtimes (multi-machine phase 7).
