# Daemon and IPC

- The session daemon (`verde-sessionizer.sock`) owns chat turns and PTYs. GUI, web gateway, MCP, and CLI are detached clients using `core.snapshot` / `core.changes`, `chat.turn.tail`, and one request per connection.
- Transport limits live in `../platform/ipc.zig` with tests; changes are design decisions. All parking handlers share `long_poll_parked`, capped at half the worker pool so short requests remain serviceable.
- Over-cap/empty long-polls answer immediately without error. Clients must pace immediate heartbeats; never add per-surface park caps or hot retry loops.
- For chat stutter, inspect `main-loop gap` / `SDL thread stall operation=...` logs and measure socket latency before changing UI code. Check for daemon requests blocking the render thread.
- Daemon changes need a restart; never perform it from a Verde-hosted session. Build and ask the user to relaunch.
- Hermetic integration check from the repository root: `zig build headless-daemon-it --release=safe -Dbrowser-backend=native_webview`. It starts an isolated daemon.
