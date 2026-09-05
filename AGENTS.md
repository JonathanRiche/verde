# AGENTS.md

## Working In This Repository

- Read the relevant code path before editing and follow existing patterns.
- Make the smallest correct change; do not add speculative abstractions or unrelated cleanup.
- Preserve user and other-agent work already present in the worktree.
- Use the narrowest useful check during iteration. For routine desktop feature and UI work, finish with `mise run dev-build`; do not automatically run `mise run build`.

## Zig 0.16

Always use `zigdoc` to discover Zig standard-library and dependency APIs. Do not rely on pre-0.16 examples.

Important Zig 0.16 conventions in this repository:

- I/O uses `std.Io`; filesystem operations generally require an `Io` instance.
- Prefer `std.process.executablePathAlloc` and `executableDirPath` over removed `std.fs` equivalents.
- Use `std.mem.trimStart` and `trimEnd`, not `trimLeft` and `trimRight`.
- Containers are unmanaged by default: initialize with `.empty`, pass allocators to operations, and pass the allocator to `deinit`.
- Pass allocators explicitly and use `errdefer` for fallible cleanup.
- `zig ast-check` catches syntax errors but not moved APIs; confirm Zig changes with the build target that owns the changed code.

### Zig style

- Functions/methods: `camelCase`; variables/parameters: `snake_case`; types: `PascalCase`; constants: `SCREAMING_SNAKE_CASE`.
- Prefer explicit type annotations with anonymous literals: `const value: Type = .{ ... };`.
- File order: module doc comment, `const Self = @This()` when needed, imports (`std`, `builtin`, project), then scoped logger.
- Method order: `init`, `deinit`, public API, private helpers.
- Use `///` for public API and `//` for implementation notes. Comments should explain why.
- Keep functions focused (roughly 70 lines or less when practical) and assert meaningful boundaries/state transitions only.
- Keep tests inline and register them in `src/main.zig` when required by the existing test structure.
- UI-rendering methods under `packages/desktop/src/ui` need a short leading comment naming the rendered region; explain non-obvious geometry.

## Build And Runtime Safety

Run commands from the repository root.

- Default for desktop development, including final verification: `mise run dev-build`.
- Full build/install verification: `mise run build` only when the change needs artifacts or installation steps omitted by `dev-build`, or the user requests it.
- Isolated clean-prefix packaging verification: `mise run build-verify-install` (release/packaging work only).
- Real desktop runtime testing: `mise run dev`.
- Do not use bare `zig build`; its Debug + WPE default is known to fail at link time.
- If a lower-level desktop build is needed, use `zig build dev-build --release=safe -Dbrowser-backend=native_webview`; choose the owning target for non-GUI changes.
- Do not run generated desktop binaries directly for normal verification.

Use `zig ast-check` or the narrowest relevant test while iterating, then `mise run dev-build` for routine desktop changes. `dev-build` builds and installs only the private GUI executable; it skips the standalone daemon, launcher/CLI, browser helper, provider bridge installation, runtime-payload copying, tests, and packaging checks. For changes to those components, use their owning build/test target; use `mise run build` when full installation is needed. Do not append a full build solely because a Zig file changed. Keep the production LLVM backend: Zig 0.16's self-hosted x86 backend is known to miscompile this application and crash during startup. Do not run the aggregate desktop `zig build test` merely because a Zig file changed: it is a broad, comparatively slow suite and is required only when the change is cross-cutting, changes test/build infrastructure, or the user explicitly requests it. Prefer `zig build headless-test --release=safe -Dbrowser-backend=native_webview` for headless/core work and `zig build runtime-test --release=safe -Dbrowser-backend=native_webview` for remote-runtime work.

## Module And Build-Graph Boundaries

Put new production code in the lightest artifact that owns it. `verde-gui` may depend only on dependency-light protocol/data contracts and daemon client interfaces; it must never import concrete providers, daemon store/server implementations, SQLite/database implementations, CLI command roots, or test backends. `verde-daemon` owns provider execution, persistence, and session/server implementation. The public `verde` launcher/CLI must not import GUI or rendering code, and shared headless protocol/type modules must remain dependency-light.

- Keep test-only backend imports in `desktop_test_root`, `test_backend`, or other test roots so they never enter production source fingerprints.
- Avoid catch-all imports in `main.zig`, `state.zig`, and `utils.zig`; import the narrow owning interface instead.
- Moving Zig files or modules alone does not create a compilation boundary. Build-speed splits require separate artifacts or a deliberate stable compiled ABI.
- UI edits should rebuild only `verde-gui`; provider or daemon edits should not rebuild it.
- Changes to these boundaries must run the GUI dependency-boundary audit and representative `dev-build` invalidation measurements. Select final verification according to the affected artifacts; a boundary audit alone does not require a full install.

Builds and tests are deliberately separate:

- `mise run build` must compile and link without depending on any test runner. Do not add test steps to the install/build graph.
- `mise run build` validates its existing `zig-out`; do not add a second isolated-prefix rebuild to the routine gate. Use `mise run build-verify-install` only for changes to installation, packaging, runtime payloads, or loader paths.
- Do not append `zig build test-compile` after `mise run build`; the application build is the required compile check. Use `test-compile` only when explicitly validating test compilation for a target that cannot execute tests.
- Register a test in one aggregate runner only. Focused runners may overlap the aggregate suite for opt-in iteration, but the aggregate `test` step must not execute the same tests through multiple roots.
- Unit tests must be hermetic: no live provider CLI, user daemon, external network, or persistent user state. Use temporary state and loopback fixtures with finite deadlines.
- Every test-owned thread, process, listener, and long poll needs deterministic cancellation and teardown. Never rely on closing a descriptor from another thread to interrupt blocking I/O.
- If a test makes no progress for 60 seconds, inspect the named test and process/thread wait state. Do not leave an unexplained `run test` command waiting for ten minutes.

Never run `mise run dev`, `mise run dev-term`, `zig build run`, or `pkill verde` from a Verde terminal pane. Verde hosts the agent session, so these commands can kill the session. In that situation, run the appropriate build target (normally `mise run dev-build`) and ask the user to relaunch for runtime testing.

For CLI smoke tests from an external shell:

- Build first, start the app, and wait for `verde live status --json` to report `ok: true`.
- Use `--json`, deterministic `--pane <id>` selectors, and `--project current` unless testing selection behavior.
- Check both the process exit code and the JSON `ok` field.
- Close panes created by the test. Sending a chat message creates a real thread, so do it only when acceptable.
- Discover commands with `verde capabilities --json`, `verde live capabilities --json`, or `verde completion <shell>` instead of maintaining command lists here.

Runtime logs are at `~/.local/share/verde/Native/logs/verde.stderr.log`. Never log clipboard contents; length-only diagnostics are acceptable.

## MCP Process Coordination, Leases, And Shared Browser Safety

Use Verde's process-coordination facilities when an action starts, owns, or may conflict with a shared/long-running resource. The relevant MCP operations are `list_processes`, `check_command`, `acquire_lease`, `release_lease`, and `wait_for_process`.

1. **Inspect before starting.** Use `list_processes` to see configured processes, active terminal commands, GUI agent turns, and background work. Before starting a potentially conflicting command, use `check_command` and declare the actual resource.
2. **Lease real shared resources.** Acquire a lease before an exclusive build (`build`), dependency mutation (`deps`), database operation (`db`), dev server (`port:<actual-port>`), browser automation/shared browser runtime (`browser`), or another long-running shared command. Do not lease ordinary reads, searches, or short focused tests merely for ceremony.
3. **Keep work observable.** Start long-lived work through Verde's tracked process/session mechanism when available. Do not hide it behind `nohup`, `disown`, `setsid`, or an untracked bare `&`. Monitor via tracked process/pane/log state rather than guessed PIDs.
4. **Release cleanly.** Keep a lease only for the work's necessary lifetime; renew it if the owned task outlives its lifetime, then stop the agent-owned process and release the lease on normal completion, failure, or cancellation. Auto-expiry protects crashes but does not replace normal cleanup.
5. **Respect other owners.** Never force a conflicting lease, kill another owner's process, reuse another owner's port, or restart Verde without explicit user authorization. Report the tracked process/session, resource lease, and cleanup outcome in the handoff.

`wait_for_process` returning `completed` means the tracked record reached a
final state, not necessarily that the command succeeded. Inspect the returned
`process.status`, `exit_code`, `signal`, and `cancellation_reason`. Terminal
final records are retained in memory for 15 minutes, up to 32 per workspace.

For pane-targeted terminal automation, prefer `send_terminal_key` for one
validated key or chord. It does not change focus or restart stopped sessions.
`terminal.write` is raw input, can restart a stopped session, and can execute
existing input when it includes a carriage return. Use a stable pane id and
inspect the target before sending Enter or another consequential key.

### Shared Verde browser runtime

The embedded browser is a shared Verde runtime and can be rebound by open/navigate operations. Always target an explicit workspace; do not casually reset, restart, close, or navigate a browser bound to another active pane/workspace. Browser tests must clean up only the exact browser/test-server process or session they started. Never use broad `pkill chrome` / `pkill chromium` commands or otherwise terminate a user, shared, or other-agent browser session.

## Native Desktop UI

`packages/desktop` is a native Palette application:

- SDL3 owns windows, events, logical window size, drawable pixel size, and display scale.
- SDL_GPU performs final rendering.
- Palette owns UI primitives, layout, hit regions, and render batches.
- `main.zig` coordinates SDL sizing/events with Palette; `palette_frame_renderer.zig` owns Palette's SDL_GPU renderer and fonts.

Treat it as native UI, not HTML/CSS or ImGui.

### Coordinate and layout invariants

- Distinguish SDL logical window size, drawable framebuffer size, and display scale.
- Keep root Palette layout, command coordinates, and renderer dimensions in a consistent coordinate space.
- Render against drawable pixel dimensions. If content occupies only the top-left or leaves black space, investigate coordinate-space mismatch before adding scale factors.
- Before changing sizing, inspect `window.getSize`, `SDL_GetWindowSizeInPixels`, and `SDL_GetWindowDisplayScale`.
- Pass explicit `palette.Rect` values. Prefer shared theme spacing, measured text, and ratios with clamps over implicit cursor layout or arbitrary subtraction.
- Hard-coded values must represent intentional tokens such as minimums, maximums, touch targets, or icon affordances; name and explain unusual values.
- Use Palette text metrics for truncation and caret placement, never guessed character widths.
- For major layout changes, check wide, laptop-width, short-height, and differing-scale layouts. Rebalance panel ratios rather than merely shrinking text.

Use the real app for runtime layout, input, rendering, resize, or Palette migration checks. When safe to launch externally, use `mise run dev`, interact through the compositor, and verify with screenshots rather than logs alone.

## Terminal Engine (ghostty-vt)

There is no vendored ghostty tree. Both apps consume upstream `ghostty-org/ghostty` pinned to one commit:

- Desktop: a hash-verified Zig package pin in `packages/desktop/build.zig.zon`. `packages/desktop/src/terminal/engine.zig` is the ONLY file that imports the `ghostty-vt` module; name engine types through it so a pin bump stays a one-file audit.
- Web: the official pre-built `ghostty-vt.wasm` from the SAME commit, vendored at `packages/web_app/web/src/assets/` with a Verde-owned binding in `web/src/lib/ghostty_vt.ts`. Pin, SHA-256, and the bump procedure live in `ghostty-vt.NOTICE.md` next to the wasm.

To bump: update the archive URL + hash in `build.zig.zon` (verify with `zig fetch` from a scratch project) and swap the wasm from `https://tip.files.ghostty.org/<commit>/ghostty-vt.wasm` — always the same commit for both. Expect upstream API drift at the `engine.zig`/`terminal.zig` seam; finish with `mise run build`. Do not reintroduce third-party wasm wrappers.

## Headless Daemon And IPC Transport

Chat turns and PTY sessions are owned by the session daemon (`verde-sessionizer.sock`). The GUI, web gateway (`verde-web`), MCP servers, and CLI are all detached clients: they project `core.snapshot` / `core.changes`, tail turns via `chat.turn.tail`, and speak one request per connection.

- Transport concurrency limits (worker pool, accept queue, long-poll park cap) are pinned in `packages/desktop/src/platform/ipc.zig` with tests. Changing them is a design decision, not a patch.
- The park cap is SHARED across every parking handler (`core.changes` and `chat.turn.tail wait_ms`) and bounds total parked waiters to half the pool, so short requests always find a free worker. New long-poll surfaces must reuse `long_poll_parked`; per-surface counters can starve the whole transport.
- Over-cap or empty long-polls answer immediately (never an error). Clients must pace retries after an immediate heartbeat — hot retry loops saturate the pool for every client on the machine.
- The GUI polls the daemon from the render thread. Daemon request latency is therefore frame latency: if streamed chat text "chunks in" or the UI stutters, check `main-loop gap` and `SDL thread stall operation=...` diagnostics in `verde.stderr.log`, then measure a raw round trip against the socket before touching UI code.
- Daemon-side changes only take effect after the daemon restarts. Never restart it yourself from a Verde-hosted session; build and ask the user to relaunch.
- Hermetic end-to-end coverage: `zig build headless-daemon-it --release=safe -Dbrowser-backend=native_webview` (spawns an isolated daemon; safe to run anywhere).

## Text Input Contract

Every new or changed text input must support complete editing behavior:

- Focused caret rendered with the same font metrics as the text.
- Click positioning, drag selection, double-click word selection, and triple-click field/line selection.
- Left/Right/Home/End navigation, with Shift to extend selection.
- Platform select-all, copy, cut, and paste; strip control characters in single-line fields.
- Backspace, Delete, and insertion must replace/delete the active selection first.
- Blur must clear selection and drag state.

Mirror `packages/desktop/src/ui/browser.zig` for the URL bar and `packages/desktop/src/ui/layout.zig` for modal fields.

## Provider Surfaces, MCP Registration, And Hooks

Verde has multiple provider surfaces. Do not treat the lifecycle-hook list as
the complete provider list:

- Native chat providers: Codex, Claude, Cursor, OpenCode, Pi, FX, and Grok.
  The source of truth is `providers/types.zig` / `app/config.zig`.
- User-scoped Verde MCP registration/proxy support: Codex, Claude, Cursor,
  OpenCode, Amp, Pi, FX, and Grok. The source of truth is
  `providers/mcp.zig`; all eight registrations target the authenticated Verde
  daemon HTTP endpoint. Pi uses a managed extension; FX uses its native
  `~/.fx/mcp.json` profile rather than the JSON/TOML shapes used by the other
  providers.
- Managed terminal TUI lifecycle status integrations: Codex, Claude, Cursor,
  OpenCode, Amp, Grok, Pi, and FX. The source of truth is `providers/hooks.zig`
  and the CLI `integration_providers` table. Pi uses a global extension; FX
  reports lifecycle natively through Verde's compatibility endpoint and keeps
  its own OSC session title authoritative. Amp has terminal/MCP integration but
  is not a native chat provider.

Keep those sets intentionally distinct. When adding or changing a provider,
audit every applicable surface instead of copying one provider list blindly:
native harness/config, MCP registration, terminal stack/default launcher,
lifecycle hooks/plugins, CLI integration reporting, settings UI, and tests.
Generated hooks must treat `VERDE_SESSION_ID` as opaque; derive a
filesystem-safe state key rather than restricting its characters.

## Provider And Transcript Contracts

When adding or changing a provider:

- Use the shared provider request/harness contract.
- Preserve all images in `SendPromptRequest.images` and legacy `SendPromptRequest.image` compatibility. If local attachments are unsupported, fail visibly rather than dropping them.
- Validate text-only and multiple-image prompts.
- Show the Fast/Default toggle only for providers with an equivalent speed/service-tier capability; ignore unsupported `fast_changed` events.
- Send assistant streaming text through `on_stream_delta` and tool/system events through `on_stream_event`.
- Use stable, short event titles. Shell executions should emit `.system` rows authored exactly `Ran command` or `Command failed`; the latter controls failure styling.
- If introducing a genuinely new transcript category, extend one documented rendering decision point in `src/ui/chat_panel.zig` rather than scattering provider-specific branches.
- Verify tail auto-scroll, command rows, failure styling, and happy/error paths.

Palette transcript scrolling is direct and non-inertial. Wheel/keyboard input changes saved offsets once; it must not add velocity decay or force continuous frames. Preserve pending-scroll cleanup on thread switches and jump-to-bottom.
