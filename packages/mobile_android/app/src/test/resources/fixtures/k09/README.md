# K-09 projection fixtures

These are `home` and `workspaces` query envelopes produced by the real client
core, not hand-written views. They were captured from the K-09 sync harness
(`packages/client_core/src/sync_test.zig`, `fixture()` helper) after it applied
the recorded temporary-daemon responses in
`packages/client_core/src/fixtures/sync/` (`snapshot.json`, `threads-0.json`,
`threads-1.json`) with wall time `1700000050000`.

- `home.json`, `workspaces.json`: the recorded snapshot and catalog as-is.
- `home-live.json`, `workspaces-live.json`: **derived**, not a daemon recording.
  Before projection, the recorded snapshot's empty `sessions` and `turns` were
  replaced with one running `htop` session on dock 7 and two turns
  (`layout-thread` `waiting_approval` started at `1700000040000`,
  `web-thread-fixture` `working` started at `1700000045000`, provider `codex`).

To regenerate, add a temporary test to `sync_test.zig` that runs `fixture()`
(or the substituted snapshot), commits, and prints `h.query("home" | "workspaces")`.
