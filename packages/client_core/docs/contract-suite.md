# Core contract suite (K-14)

`src/contract_test.zig` drives the **real** client core (`Host.handle`, the
same effect/event contract the Android and iOS adapters implement) against a
real temporary `verde-daemon serve` and `verde-web`. Run it from the repository
root:

```sh
mise run mobile-core-contract   # zig build contract --release=safe
```

It is a separate task, not a dependency of `mobile-core-test`. The step first
builds `verde-daemon` (`daemon-exe`, no provider bridge bundle) and `verde-web`
into `zig-out/contract/`, then runs the suite. It runs on Linux only.

## Topology

```
core (test thread) -> adapter workers -> envelope proxy (127.0.0.1:0) -> verde-web (127.0.0.1) -> daemon socket
```

- **Envelope proxy.** A loopback listener stands in for the TLS-terminating
  proxy. It drops client `Host`, `Forwarded` and `X-Forwarded-*` headers and
  sends `Host` and `X-Forwarded-Host: runtime.contract.test`,
  `X-Forwarded-Proto: https` and a single `X-Forwarded-For`. verde-web runs with
  `--trusted-proxy-origin https://runtime.contract.test`. The adapter answers
  `tls_probe` with a fixed test pin and fails the run if any `http_request` or
  `ws_open` carries a different origin or pin.
- **Ports.** The proxy binds port 0. verde-web rejects `--port 0`, so the suite
  reserves a kernel-chosen ephemeral port and passes it on. If the gateway loses
  that race it exits, and the suite retries on a new port (up to 5 attempts).
- **Hermetic state.** Everything lives under `/tmp/verde-k14-<pid>-<rand>`, mode
  0700. That covers the data directory, socket, home, XDG directories, TMPDIR,
  the 0600 gateway token file and the logs.
  - The children get a fresh environment. Nothing is inherited, and `PATH` is an
    empty directory.
  - The daemon runs with `VERDE_SESSION_DAEMON_CHAT_STUB=1`. The thread uses
    `codex`, whose model listing does no provider I/O.
- **Owner-side seeding** uses the daemon socket and CLI, as the desktop does:
  - `state.snapshot.replace` for the workspace;
  - `pair create --json` for the grant, whose code is read from a pipe and
    zeroed after use;
  - `device list --json` to confirm the revoke on the server side.

## Flow and assertions

1. `start` loads an empty secure store, and the host is `unpaired`.
2. `pair` runs the TLS probe, then pinned discovery. It must produce a trust
   proposal for the daemon's `runtime_id`.
3. `trust_decision` runs exchange, credential, access token, ticket, WebSocket,
   `core.status`/`core.capabilities`, snapshot and catalog. The host must reach
   `paired` + `ready` + `ready`.
4. The thread is created through the core's own RPC path
   (`daemon.client.register` + `chat.thread.upsert` via `rpc.request`),
   because the core has no create-thread intent yet. It must then appear in the
   `workspaces` projection.
5. The suite then runs `thread_open`, `draft_set`, `send`, and tails the turn to
   the stub's `orch-approval` request.
6. `approval_decide` approves the request. The turn must reach `completed`,
   with committed user and `stub-ok` assistant rows.
7. D-04 `sign_out` makes the core send targeted `device.self.revoke` over its
   authenticated RPC. The host must then reach `signed_out` with a succeeded
   operation, after acknowledged deletes of the `credential` and `profile`
   secure-store records. The CLI must show `revoked_at_ms` for the device.
8. No hosts, workspace, thread or composer view, and no secure-store record,
   may contain the pairing code.

## Deadlines and teardown

- **Deadlines.** Every wait has a finite deadline (30 s per step). A watchdog
  kills the children and exits after 240 s.
- **Teardown order:**
  1. the core `shutdown` event;
  2. stop flag, which every worker polls in 100 ms slices;
  3. worker joins;
  4. `SIGTERM` to each child, with a 10 s grace before `SIGKILL`. Only an exit
     status of 0 or death by `SIGTERM` counts as graceful.
  5. temp tree removal.
- **Failure output.** A failure prints only non-secret view fields and the
  product log tails. Credentials, tokens, tickets and pairing codes are never
  printed.
