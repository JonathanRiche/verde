# Run the Verde web app on another VM

This is an agent-ready runbook for starting the web app on another VM. Run all commands from the repository root.

There are two supported ways to run it:

1. **Development mode:** run the Zig gateway and Vite as two processes. Use this while editing the frontend because Vite provides hot module reload.
2. **Bundled mode:** run one command. It builds the frontend bundle and Zig gateway, then one `verde-web` process serves the UI, API, and WebSocket endpoint together. Use this when hot reload is unnecessary.

For the shortest deployment path, use bundled mode:

```bash
mise install
mise run web-app-run -- --host 0.0.0.0 --port 6783
```

After the build completes, open `http://<VM-IP>:6783/`.

## What runs

- `verde-web`, the Zig HTTP/WebSocket gateway, listens on `127.0.0.1:7420`.
- Vite serves the browser UI with hot reload on `0.0.0.0:6783` and proxies `/api` and `/ws` to the gateway.
- Port `6783` is the URL users open. Do not substitute Vite's default port `5173`.

The gateway expects the Verde session daemon socket on the same VM. Its usual path is:

```text
~/.local/share/verde/Native/verde-sessionizer.sock
```

If the daemon is unavailable, the gateway can still serve a review snapshot, but live workspaces, chats, and terminals will not be fully functional.

## Prepare the VM

Clone the repository and enter its root, then install the repo-pinned tools:

```bash
mise install
```

Before starting anything, confirm the required ports are free:

```bash
ss -ltnp | rg ':(6783|7420)\b' || true
```

Do not start duplicate servers if either port is already owned by the web app. When working through a Verde-hosted agent session, do not run `mise run dev`, `mise run dev-term`, or `pkill verde`; those commands can terminate the session hosting the agent.

## Option A: frontend development server with HMR

This option requires two running terminals. Vite serves the frontend on `6783`; the Zig gateway serves the API on loopback port `7420`.

### 1. Start the Zig gateway

In terminal A:

```bash
mise run web-app-run
```

The first run installs the Bun dependencies, builds the Zig gateway and SPA, and then listens on `127.0.0.1:7420`.

Wait for this line before continuing:

```text
verde-web listening on http://127.0.0.1:7420/
```

### 2. Start the Vite development server

In terminal B:

```bash
mise run web-app-dev
```

Wait for Vite to report that it is ready on port `6783`.

Keep both terminal processes running. Stop only the processes you started, normally with `Ctrl-C` in their respective terminals.

### 3. Verify development mode

On the VM:

```bash
curl -fsS http://127.0.0.1:7420/api/health
curl -fsS http://127.0.0.1:6783/ | head
ss -ltnp | rg ':(6783|7420)\b'
```

The health response should resemble:

```json
{"ok":true,"source":"daemon"}
```

Open the UI from another machine at:

```text
http://<VM-IP>:6783/
```

Allow inbound TCP port `6783` in the VM firewall or cloud security group if necessary. Do not expose `7420`; it is intentionally loopback-only behind the Vite proxy.

For regular remote use, it is preferable to put port `6783` behind a user-managed **Cloudflare Tunnel** or **Tailscale Funnel**. Both provide an HTTPS URL, which is safer than publicly exposing the VM's plain HTTP port and is required for full PWA installation behavior. The VM owner must authorize and manage the tunnel; an agent should not create, replace, or reset tunnel configuration without explicit permission.

Examples the VM owner may choose to run are:

```bash
# Public Cloudflare HTTPS URL
cloudflared tunnel --url http://127.0.0.1:6783

# Public Tailscale HTTPS URL
sudo tailscale funnel --bg 6783
```

For tailnet-only access rather than a public Funnel, the owner can use `sudo tailscale serve --bg 6783`. Point any existing reverse proxy or named Cloudflare Tunnel at `http://127.0.0.1:6783`.

If direct inbound access is unavailable, create an SSH tunnel from the client machine:

```bash
ssh -N -L 6783:127.0.0.1:6783 <user>@<VM-host>
```

Then open `http://127.0.0.1:6783/` on the client.

## Option B: bundled frontend with one command

For a built UI without hot reload, do not run Vite. This single command installs dependencies if needed, builds the Zig gateway and frontend bundle, and then serves `/`, `/api`, and `/ws` from one `verde-web` process on port `6783`:

```bash
mise run web-app-run -- --host 0.0.0.0 --port 6783
```

Wait for:

```text
verde-web listening on http://0.0.0.0:6783/
```

Then verify it:

```bash
curl -fsS http://127.0.0.1:6783/api/health
curl -fsS http://127.0.0.1:6783/ | head
```

The equivalent expanded commands are:

```bash
mise run web-app
./packages/web_app/zig-out/bin/verde-web \
  --host 0.0.0.0 \
  --port 6783 \
  --static packages/web_app/dist
```

In bundled mode, do not also start `mise run web-app-dev`; both would compete for port `6783`. If port `6783` is reachable beyond a trusted private network, set `VERDE_WEB_TOKEN` before starting the gateway and use the token-bearing URL it requires. Prefer a user-managed Cloudflare Tunnel or Tailscale Funnel for HTTPS remote access; an SSH tunnel is a good private fallback.

## Troubleshooting

- `6783` already in use: inspect the owning process with `ss -ltnp | rg ':6783\b'`; do not kill it unless it belongs to this task.
- `7420` already in use: check `curl -fsS http://127.0.0.1:7420/api/health` before deciding whether another gateway is already usable.
- UI loads but live state is missing: confirm the session daemon socket exists and inspect the gateway startup output for its selected source.
- Vite reports proxy failures: start or repair `verde-web` on `127.0.0.1:7420`.
- Remote browser cannot connect: verify Vite is listening on `0.0.0.0:6783`, then check the VM firewall/security group or use the SSH tunnel above.
