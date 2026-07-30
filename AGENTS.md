# AGENTS.md

## Working In This Repository

- Read the relevant code path before editing and follow existing patterns.
- Make the smallest correct change; do not add speculative abstractions or unrelated cleanup.
- Preserve user and other-agent work already present in the worktree.
- During iteration, use the narrowest useful check. Before finishing any Zig change, run the configured full build.

## Zig 0.16

Always use `zigdoc` to discover Zig standard-library and dependency APIs. Do not rely on pre-0.16 examples.

Important Zig 0.16 conventions in this repository:

- I/O uses `std.Io`; filesystem operations generally require an `Io` instance.
- Prefer `std.process.executablePathAlloc` and `executableDirPath` over removed `std.fs` equivalents.
- Use `std.mem.trimStart` and `trimEnd`, not `trimLeft` and `trimRight`.
- Containers are unmanaged by default: initialize with `.empty`, pass allocators to operations, and pass the allocator to `deinit`.
- Pass allocators explicitly and use `errdefer` for fallible cleanup.
- `zig ast-check` catches syntax errors but not moved APIs; confirm Zig changes with a full build.

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

- Normal build/install verification: `mise run build`.
- Real desktop runtime testing: `mise run dev`.
- Do not use bare `zig build`; its Debug + WPE default is known to fail in vendored Ghostty and at link time.
- If a lower-level build is explicitly needed, use `zig build --release=safe -Dbrowser-backend=native_webview`.
- Do not run generated desktop binaries directly for normal verification.

For speed, use focused tests or `zig ast-check` while iterating, but do not treat them as final verification. The default Debug build is currently broken and is not an approved fast path; every completed Zig change must finish with `mise run build`.

Never run `mise run dev`, `mise run dev-term`, `zig build run`, or `pkill verde` from a Verde terminal pane. Verde hosts the agent session, so these commands can kill the session. In that situation, run `mise run build` and ask the user to relaunch for runtime testing.

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

## Text Input Contract

Every new or changed text input must support complete editing behavior:

- Focused caret rendered with the same font metrics as the text.
- Click positioning, drag selection, double-click word selection, and triple-click field/line selection.
- Left/Right/Home/End navigation, with Shift to extend selection.
- Platform select-all, copy, cut, and paste; strip control characters in single-line fields.
- Backspace, Delete, and insertion must replace/delete the active selection first.
- Blur must clear selection and drag state.

Mirror `packages/desktop/src/ui/browser.zig` for the URL bar and `packages/desktop/src/ui/layout.zig` for modal fields.

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
