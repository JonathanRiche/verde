# CLAUDE.md

## How Claude Should Work Here

Own the task through implementation and verification. Inspect enough code to identify the correct ownership path, then make the smallest correct change. Do not stop at a plan unless the user asks for one.

- Prefer existing project patterns over new wrappers, helpers, or abstractions.
- Preserve unrelated worktree changes and never revert work you did not create.
- Use parallel reads/searches when independent; use subagents only for genuinely broad, separable work.
- Keep code editing with the primary agent so implementation decisions remain coherent.
- Diagnose failed commands before changing approach; do not repeat the same failing command blindly.
- Report the result, relevant verification, and any unresolved risk concisely.

## Zig Rules

This repository uses Zig 0.16. Always query unfamiliar standard-library and dependency APIs with `zigdoc`; older Zig examples are commonly invalid.

- I/O uses `std.Io`, and filesystem operations generally take an `Io` instance.
- Prefer `std.process.executablePathAlloc` / `executableDirPath`.
- Use `std.mem.trimStart` / `trimEnd`.
- Containers are usually unmanaged: initialize with `.empty` and pass allocators to operations and `deinit`.
- Pass allocators explicitly and use `errdefer` for fallible cleanup.
- `zig ast-check` is only a syntax check; moved APIs require a real build.

Follow local style: `camelCase` functions, `snake_case` values, `PascalCase` types, `SCREAMING_SNAKE_CASE` constants, explicit typed anonymous literals, and comments that explain why. Keep tests inline and follow the existing `src/main.zig` registration pattern. UI render methods need a short leading region/component comment.

## Build And Session Safety

Run builds from the repository root.

- Use `mise run build` for normal compile/link and install verification. It is intentionally separate from tests.
- Use `mise run dev-build` for focused main-executable iteration; it deliberately skips auxiliary executables and payload verification.
- Use `mise run build-verify-install` only for installation, packaging, runtime-payload, or loader-path changes; it performs the intentionally expensive isolated-prefix rebuild.
- Use `mise run dev` only for real runtime testing from a safe external shell.
- Never use bare `zig build`; the default Debug + WPE configuration is known to fail.
- If a lower-level build is explicitly required: `zig build --release=safe -Dbrowser-backend=native_webview`.

Claude may itself be running inside a Verde terminal. In that case, never run `mise run dev*`, `zig build run`, `pkill verde`, or the generated app: doing so can kill the daemon and Claude's session. Build only and ask the user to relaunch for manual testing.

During iteration, use `zig ast-check`, `mise run dev-build`, or the narrowest relevant test for quick feedback. `dev-build` installs only the main desktop executable and skips the standalone daemon, browser helper, provider bridge installation, runtime-payload copying, tests, and packaging checks. It must use LLVM: Zig 0.16's self-hosted x86 backend is known to miscompile Verde and crash during startup. The default Debug build is currently broken and is not an approved fast path. Before completing any Zig change, run `mise run build`. Do not run the aggregate desktop `zig build test` for every Zig edit; reserve it for cross-cutting changes, test/build infrastructure changes, or an explicit user request. Use the focused `headless-test` or `runtime-test` build steps when they match the edited subsystem.

Keep verification proportional and hermetic. The build/install graph must never depend on test execution, and the aggregate test step must not run the same tests through overlapping roots. Do not append `zig build test-compile` after `mise run build`; use it only for explicit compile-only validation of tests on a target that cannot run them. Tests may not use live provider CLIs, the user's daemon, external network, or persistent user state. Give every test-owned thread, child process, listener, and long poll deterministic cancellation and finite teardown. If a runner makes no progress for 60 seconds, inspect its named test and wait state instead of waiting indefinitely.

For live CLI checks, prefer JSON and stable IDs: wait for `verde live status --json`, use `--pane <id>` and `--project current`, inspect both exit status and JSON `ok`, and close test panes. Sending chat messages creates real threads and requires judgment. Discover the CLI through `verde capabilities --json`, `verde live capabilities --json`, or shell completion.

## MCP Process Monitoring And Shared Browser Safety

When a task starts a browser, dev server, build, test server, or another long-running/shared command through Verde/MCP:

- inspect `list_processes`, then use `check_command` before potentially conflicting work;
- acquire a lease only for the real shared resource—such as `build`, `deps`, `db`, `port:<actual-port>`, or `browser`—rather than for ordinary reads/searches/short focused tests;
- use Verde tracked process/session facilities where available, inspect their pane/process/log state while running, and do not conceal long-lived work behind `nohup`, `disown`, `setsid`, or a bare `&`;
- stop only the exact process/session you started, release the lease on completion/failure/cancellation, and report the process/session, resource, and cleanup outcome;
- never force a conflicting lease, kill another owner's process, or restart Verde without explicit user authority.

`wait_for_process` returning `completed` means the tracked record is final, not
necessarily successful. Inspect `process.status`, `exit_code`, `signal`, and
`cancellation_reason`; terminal final records remain in memory for 15 minutes,
up to 32 per workspace.

For pane-targeted terminal automation, use `send_terminal_key` for a validated
atomic key or chord. It preserves focus and does not restart stopped sessions.
Raw `terminal.write` can restart a session and can execute existing input when
it contains a carriage return, so use a stable pane id and inspect the target
before sending a consequential key.

The embedded browser is a shared Verde runtime: always target an explicit workspace and do not reset, restart, close, or navigate a browser bound to another active pane/workspace. Clean up only your own browser/test-server session; never use broad `pkill chrome` / `pkill chromium` commands.

## Desktop UI Invariants

Verde's desktop app is SDL3 + SDL_GPU + Palette, not web UI or ImGui. SDL owns logical window size, drawable pixels, display scale, and events; Palette owns layout and render commands.

When editing UI:

1. Read the surrounding render/event path, not only the widget.
2. Identify whether the issue is logical window sizing, framebuffer sizing, display scale, or widget layout.
3. Keep Palette layout coordinates and renderer dimensions in the same space; render against drawable pixels.
4. Investigate `window.getSize`, `SDL_GetWindowSizeInPixels`, and `SDL_GetWindowDisplayScale` before introducing scale compensation.
5. Prefer explicit `palette.Rect`s, measured text, shared tokens, and clamped ratios. Avoid arbitrary `width - N` layout and guessed text widths.
6. Name and explain hard-coded geometry when it represents a real minimum, maximum, touch target, or visual token.
7. Check wide, laptop-width, short-height, and scaled-display behavior for major layout changes.

Runtime UI changes require the real app when it is safe to launch it. Use compositor interaction/screenshots rather than inferring visual correctness from logs. Logs live at `~/.local/share/verde/Native/logs/verde.stderr.log`; never log clipboard contents.

## Terminal Engine And Daemon Transport

There is no vendored ghostty tree. Desktop pins upstream `ghostty-org/ghostty` in `packages/desktop/build.zig.zon`; `packages/desktop/src/terminal/engine.zig` is the only `ghostty-vt` import boundary. Web vendors the official `ghostty-vt.wasm` from the same commit at `packages/web_app/web/src/assets/` (bump procedure in `ghostty-vt.NOTICE.md`). Keep both on one commit and do not add third-party wrappers.

Chat turns and PTY sessions live in the session daemon; GUI, web gateway, MCP servers, and CLI are detached clients speaking one request per connection. Transport limits (worker pool, accept queue, shared long-poll park cap) are pinned with tests in `packages/desktop/src/platform/ipc.zig` — changing them is a design decision. New long-poll surfaces must reuse the shared `long_poll_parked` cap, and clients must pace retries after an immediate heartbeat. The GUI polls the daemon from the render thread, so daemon latency shows up as frame stutter: check `main-loop gap` and `SDL thread stall` lines in `verde.stderr.log` before touching UI code. Daemon changes require a restart the user must perform. Hermetic coverage: `zig build headless-daemon-it --release=safe -Dbrowser-backend=native_webview`.

## Text Inputs

Treat every text field as a real editor. New or changed inputs must include:

- Metric-aligned focused caret.
- Click/drag selection, double-click words, and triple-click field/line selection.
- Left/Right/Home/End navigation with Shift extension.
- Platform select-all/copy/cut/paste, with control-character stripping for single-line paste.
- Selection-aware insertion, Backspace, and Delete.
- Selection/drag cleanup on blur.

Use `packages/desktop/src/ui/browser.zig` and `packages/desktop/src/ui/layout.zig` as reference implementations.

## Provider Surfaces And Integrations

Verde's provider lists are intentionally different across features:

- Native chat: Codex, Claude, Cursor, OpenCode, Pi, FX, and Grok
  (`providers/types.zig`, `app/config.zig`).
- User-scoped MCP registration/proxy: Codex, Claude, Cursor, OpenCode, Amp,
  Pi, FX, and Grok (`providers/mcp.zig`). All eight connect to the authenticated
  Verde daemon HTTP endpoint; Pi uses a managed extension and FX its native
  `~/.fx/mcp.json` profile.
- Managed terminal lifecycle integrations: Codex, Claude, Cursor, OpenCode,
  Amp, Grok, Pi, and FX (`providers/hooks.zig` and the CLI integration table).
  Pi uses a global extension; FX reports lifecycle natively through Verde's
  compatibility endpoint and keeps its own OSC session title authoritative.
  Amp is not a native chat provider.

Do not use one integration surface as the complete provider inventory. For
provider changes, audit each applicable native-harness, MCP, terminal-stack,
hook/plugin, CLI/settings, and test surface. Treat `VERDE_SESSION_ID` as opaque
inside generated integrations and derive filesystem-safe state keys.

## Providers And Transcript

- Integrate through the shared request/harness contract.
- Preserve multiple `SendPromptRequest.images` plus legacy `image`; visibly reject unsupported attachments instead of dropping them.
- Validate text-only and multiple-image prompts.
- Hide and ignore Fast/Default controls for providers without an equivalent capability.
- Stream assistant text through `on_stream_delta`; emit tool/system events through `on_stream_event` with stable, short titles.
- Author command events exactly `Ran command` or `Command failed` so Palette uses compact command rows and failure styling.
- Keep new transcript categories centralized in `src/ui/chat_panel.zig`.

Transcript scrolling is intentionally direct and non-inertial. Do not add velocity decay, continuous-frame rendering, or stale pending scroll across thread switches.
