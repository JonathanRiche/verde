# Suite: smoke (~5 min) — is the app fundamentally healthy?

Run these in order; every step compares against expectations.md.

S1 HEADLESS CLI: zero GUI. `./zig-out/bin/verde core status --json`,
`core capabilities`, `core changes`, and a scoped snapshot
(`--scope registry --scope sessions --scope turns`). Record latencies and the
daemon PID/protocol.

S2 MCP: `./zig-out/bin/verde mcp` over stdio — JSON-RPC initialize +
tools/list with `timeout 10`. Record latency and tool count. Still zero GUI.

S3 LAUNCH + ATTACH: launch on workspace 2. Time spawn → window mapped
(hyprctl clients polling) and note when the restored UI replaces the loading
frame. Verify: no persistence banner (screenshot top bar), exactly one
session daemon, attached read-write.

S4 ONE CLOSE: `hyprctl dispatch closewindow address:<addr>` on the focused
window. Measure window-gone and process-exit separately; grep the log for the
`close durability handoff complete elapsed_ms=` marker. Daemon must survive.

Cleanup per charter. Report per charter.
