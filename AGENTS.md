# Repository rules

- Read the relevant code and scoped instructions; follow existing patterns.
- Make the smallest correct change. Preserve unrelated user/agent work.
- Finish implementation and relevant verification; report results and limitations briefly.
- Never restart Verde from a Verde-hosted session. Build, then ask the user to relaunch.

## Verification

Run commands from the repository root. Use the narrowest check during iteration.

| Change | Final verification |
| --- | --- |
| Routine desktop feature/UI | `mise run dev-build` |
| Daemon, CLI, provider bridge, or other non-GUI artifact | Owning build/test target; `mise run build` when full installation is needed |
| Packaging, installation, runtime payloads, loader paths | `mise run build-verify-install` |
| Documentation only | Check diff and references; no build |

`dev-build` installs only `verde-gui`; it skips auxiliary executables, payloads, and tests. Do not append a full build merely because Zig changed. Use LLVM; the self-hosted x86 backend miscompiles Verde. Never use bare `zig build` (broken Debug + WPE defaults). Lower-level targets need `--release=safe -Dbrowser-backend=native_webview`.

- Keep tests separate from build/install. Do not add a second isolated-prefix build to routine verification.
- Prefer `headless-test` for core work and `runtime-test` for remote runtime work. Reserve aggregate `test` for cross-cutting/test-infrastructure changes or explicit requests. Use `test-compile` only for targets that cannot execute tests.
- Register tests once per aggregate runner. Use temporary state, loopback fixtures, finite deadlines, and deterministic teardown; no live providers, user daemon, network services, or persistent user state. Closing a descriptor from another thread is not cancellation.
- If a test stalls for 60 seconds, inspect its named test and process/thread wait state.

## Shared resources and runtime safety

- Inspect `list_processes`, then `check_command` before conflicting work. Lease actual shared resources: `build`, `deps`, `db`, `port:<port>`, or `browser`; not ordinary reads or short focused tests.
- Use tracked processes/sessions when available; no hidden `nohup`, `disown`, `setsid`, or bare `&`. Renew leases as needed, clean up owned processes, and release on success, failure, or cancellation. Report resource/process cleanup.
- Never force leases, kill others' processes, reuse their ports, or restart Verde without explicit authorization. Target an explicit workspace for shared browser work; never navigate or close another pane's browser.
- `wait_for_process: completed` is not success: check status, exit code, signal, and cancellation reason.
- Inside Verde, do not run `mise run dev`, `mise run dev-term`, `zig build run`, `pkill verde`, or generated desktop binaries. `mise run dev-build` is safe.
- External runtime checks use `mise run dev`. CLI checks require `verde live status --json` with `ok: true`, stable `--pane` IDs, `--project current`, and both exit-code/JSON checks. Discover commands with `verde capabilities --json`; close test panes and remember sends create real threads.
- Prefer `send_terminal_key`; inspect the target before consequential input. Raw `terminal.write` can restart sessions and execute existing input.
- Logs: `~/.local/share/verde/Native/logs/verde.stderr.log`. Never log clipboard contents.

## Zig 0.16

- Discover standard-library/dependency APIs with `zigdoc`; do not copy older Zig examples.
- Use `std.Io`, `std.process.executablePathAlloc` / `executableDirPath`, and `std.mem.trimStart` / `trimEnd`.
- Containers start `.empty`; pass allocators to operations/deinit and use `errdefer` for fallible cleanup. `zig ast-check` checks syntax, not API compatibility.
- Use `camelCase` functions, `snake_case` values, `PascalCase` types, `SCREAMING_SNAKE_CASE` constants, and explicit typed literals.
- File order: module doc, optional `Self`, imports, logger. Methods: init/deinit, public API, helpers. Keep functions focused; comments explain why (`///` for public API). Follow existing inline-test registration.

## Scoped rules

Read the relevant file before working on that subsystem, including changes from outside its directory:

- [Desktop architecture and subsystem index](packages/desktop/AGENTS.md)
- [Web client and gateway](packages/web_app/AGENTS.md)
- [Website](packages/website/AGENTS.md)
- [Tree-sitter package](packages/zig_treesitter/AGENTS.md)
- [Browser inspector](packages/browser_extensions/inspector/AGENTS.md)
