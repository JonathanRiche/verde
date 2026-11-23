# Verde CLI cheat-sheet

Use `verde` from `PATH`, or `"$VERDE_CLI"` inside a Verde terminal. The installed
binary is the authority: run `verde --help` and `verde capabilities --json`.
Do not run bare `verde` or `verde app`; they launch the desktop app.

Rules for scripting:

- Pass `--json` and check both the exit code and the envelope
  (`{"ok": true, "result": ...}` or `{"ok": false, "error": {"code", "message"}}`).
- Exit codes: `0` ok, `1` command failed or `ok: false`, `2` invalid arguments,
  `3` live app not running, `4` offline state target not found.
- Pass `--workspace <id>` (alias `--project`) and `--pane <id>` explicitly.
  `--focused` is for interactive smoke tests only.

## Discovery (read-only)

```bash
verde capabilities --json
verde live status --json              # require ok: true before any live command
verde live workspaces --json
verde live panes --workspace <id> --json
verde live threads --workspace <id> --json
verde live terminals --workspace <id> --json
verde live processes --json
verde live inspect --workspace <id> --pane <pane-id> --json
verde state workspaces --json         # persisted state, works with the app closed
```

## Leased builds

```bash
verde lease run [--resource build|deps|db|browser|port:<n>]... [--workspace <id|path>] \
  [--owner <thread-id>] [--no-reuse] [--wait-timeout <sec>] -- <command> [args...]
```

Waits in line, reuses an identical run on unchanged sources, releases on exit,
and exits with the command's status (`124` if `--wait-timeout` expires). Read
the `verde lease:` lines. Run it in the background when your shell timeout is
short.

## Chats

```bash
verde live chat open --workspace <id> --provider <claude|codex|opencode|cursor|...> \
  [--model <id>] [--reasoning low|medium|high|xhigh] [--fast|--no-fast] \
  [--parent-thread-id <your-thread-id>] --no-focus --json
verde live chat send --workspace <id> --thread <thread-id> --prompt "..." [--turn <id>] [--path <dir>] --json
verde live chat tail --turn <turn-id> [--after <seq>] --json
verde live chat read --workspace <id> --thread <thread-id> --json
verde live chat stop --turn <turn-id> --json
verde live chat approve --turn <turn-id> --call <call-id> --decision approve|deny --json
verde live chat present --workspace <id> --thread <thread-id> --json
verde live chat followup --workspace <id> --pane <pane-id> --prompt "..." --json
verde live chat status --workspace <id> --pane <pane-id> --json
```

`chat open` focuses the new pane unless you pass `--no-focus`. `chat send
--thread` goes daemon-direct but does not link a parent; use MCP
`send_chat_message` with `parent_thread_id` when you want results delivered back
to you.

## Terminals and sessions

```bash
verde live terminal screen --workspace <id> --pane <pane-id> --json
verde live terminal tail   --workspace <id> --pane <pane-id> [--lines <n>] --json
verde live terminal key    --workspace <id> --pane <pane-id> --chord ctrl+c --json
verde live terminal key    --workspace <id> --pane <pane-id> --key enter --json
verde live terminal submit --workspace <id> --pane <pane-id> --json
verde live terminal write  --workspace <id> --pane <pane-id> --text $'make test\r' --json   # raw; restarts stopped sessions

verde session list --json
verde session new --workspace <id> --cwd <path> --name <name> -- <command...>
verde session tail --id <session-id> [--lines <n>] --json
verde session screen --id <session-id> --json
verde session write --id <session-id> --text $'q\r'
verde session kill --id <session-id>    # only sessions you started
```

Sessions live in the session daemon, so they survive window restarts. Use them
instead of `nohup`, `&`, `setsid`, or `disown`.

## Configured processes and stacks (`verde.toml`)

```bash
verde live process list    --workspace <id> --json
verde live process start   --workspace <id> --name <name> --json
verde live process restart --workspace <id> --name <name> --json
verde live process stop    --workspace <id> --name <name> --json
verde live process logs    --workspace <id> --name <name> [--lines <n>] --json
verde live stack status    --workspace <id> --json   # start|stop|restart act on every process and agent
```

## Browser

```bash
verde live browser status --json
verde live browser open --workspace <id> --url http://localhost:3000 --json
verde live browser eval --script "document.title" --json
verde live browser screenshot --json
```

Apart from `open`, `verde live browser` subcommands take no workspace selector.
Prefer the MCP browser tools, which address a workspace or your own tab.

## Schedules

```bash
verde schedule list [--workspace <id>] --json
verde schedule add --prompt "Check CI and summarize failures" --workspace <id> \
  (--thread <thread-id> | --provider <provider> [--model <model>]) \
  (--at "YYYY-MM-DD HH:MM" | --in 30m | --every 2h | --daily 09:00 [--weekdays mon-fri]) \
  [--parent-thread-id <your-thread-id>] [--disabled] --json
verde schedule enable|disable|remove|run <schedule-id> --json
```

## Surface status (from hooks and scripts)

```bash
verde notify --status working --progress 0.4 --label "Running tests"
verde notify --status done --title "Agent finished"
verde notify --clear
```

## Do not run from inside Verde

`verde`, `verde app`, `verde update`, `pkill verde`, generated desktop binaries,
`verde live workspace close|select`, `verde live pane focus|close`, or
`verde live browser focus` unless the user explicitly asked for that action.
