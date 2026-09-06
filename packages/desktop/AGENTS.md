# Desktop

Follow the [root rules](../../AGENTS.md).
## Artifact boundaries

- Put code in the lightest owning artifact. `verde-gui` may use lightweight contracts and daemon clients, never concrete providers, daemon server/store, SQLite, CLI roots, or test backends.
- `verde-daemon` owns provider execution, persistence, and sessions. The public launcher/CLI must not import GUI/rendering code. Shared headless contracts stay dependency-light.
- Import narrow interfaces, especially from `main.zig`, `state.zig`, and `utils.zig`. Keep test backends in test roots.
- UI changes should rebuild only the GUI; provider/daemon changes should not rebuild it. File moves alone do not create compilation boundaries.
- Boundary changes require `scripts/dev/check-gui-dependency-boundary.sh` and representative `dev-build` invalidation measurements. Choose final verification from the root table.

## Subsystem rules

Read these for matching work, even when editing callers elsewhere:

| Work | Instructions |
| --- | --- |
| Layout, rendering, text input, scrolling (including `main.zig` / state) | [UI](src/ui/AGENTS.md) |
| Providers, configuration, hooks, MCP, transcript events | [Providers](src/providers/AGENTS.md) |
| Daemon, IPC, polling, detached clients | [Daemon](src/daemon/AGENTS.md) |
| Terminal engine or dependency pin | [Terminal](src/terminal/AGENTS.md) |
