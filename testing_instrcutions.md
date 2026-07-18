# Testing Instructions

Run from this directory:

```sh
zig build --release=safe -Dbrowser-backend=native_webview --summary all
zig test packages/desktop/src/stack.zig
zig test packages/desktop/src/cli.zig
```

Manual smoke:

1. Launch Verde:
   ```sh
   ./zig-out/bin/verde
   ```

2. Open a terminal pane and confirm env vars:
   ```sh
   env | rg '^VERDE'
   ```
   Expect `VERDE=1`, `VERDE_SESSION_ID`, workspace/dock/pane ids, and socket paths.

3. Test notify inside that terminal:
   ```sh
   ./zig-out/bin/verde notify --status waiting --title "Needs input" --body "Approve action"
   ./zig-out/bin/verde notify --status done --title "Done"
   ./zig-out/bin/verde notify --clear
   ```
   Expect pane/sidebar attention/status to update and clear.

4. Test terminal-native notifications:
   ```sh
   printf '\a'
   printf '\033]777;notify;Title;Body\a'
   ```
   Expect attention/notification state without broken terminal output.

5. Test live surfaces:
   ```sh
   ./zig-out/bin/verde live surfaces --json
   ```
   Expect the terminal surface to appear with status/attention fields.

6. Test MCP discovery:
   ```sh
   printf '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}\n' | ./zig-out/bin/verde mcp
   ```
   Expect surface tools like `list_surfaces`, `notify_surface`, and process tools.

7. Test integrations CLI:
   ```sh
   ./zig-out/bin/verde integrations list
   ./zig-out/bin/verde integrations doctor --json
   ./zig-out/bin/verde integrations install codex --json
   ./zig-out/bin/verde integrations install claude --json
   ```
   Expect Codex install to create project-local `.codex/hooks.json` plus `.verde/hooks/codex-notify-hook.sh`. Expect Claude install to return `unsupported`.

8. Test `verde.yml` agents with a workspace config:
   ```yaml
   agents:
     codex:
       provider: codex
       command: "codex"
       cwd: "."
       revive: attach_or_create
       notify: true
       mcp: true
       hooks: true
   ```
   Then run:
   ```sh
   ./zig-out/bin/verde live process list --json
   ```
   Expect the agent metadata fields in process output.
   Verde automatically enables `features.hooks=true` for plain `codex` managed commands when `hooks: true` is set. When Codex runs in that pane, `PermissionRequest` hooks should mark the Verde surface `waiting`, and `Stop` hooks should mark it `done`.

9. Test first-class Codex TUI open:
   ```sh
   ./zig-out/bin/verde live agent open --provider codex --json
   ```
   Expect a Codex terminal pane to open for the selected workspace. Also right-click the workspace new-thread/pencil button and choose `Open Codex TUI`; expect the same result.

10. Close Verde and confirm quiet notify no-ops:
   ```sh
   VERDE_SESSION_ID=test ./zig-out/bin/verde notify --quiet --status waiting
   echo $?
   ```
   Expect exit code `0` and no OS notification.

Regression checks:

- Terminal copy/paste still works.
- Mouse selection still works.
- Terminal resizing does not jitter.
- `./zig-out/bin/verde session list`, `attach`, `tail`, and `screen` still work.
