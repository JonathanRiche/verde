---
title: Provider setup
description: How Verde talks to local coding-agent CLIs, plus per-provider setup and troubleshooting notes for Codex, Claude Code, OpenCode, and Cursor.
section: Get started
order: 2
slug: providers
---

## How providers work

Verde does not host a model and does not relay your prompts through a hosted
backend. It spawns and talks to the coding-agent CLIs you already have on your
machine — Codex, Claude Code, OpenCode, and Cursor — over each provider's
native protocol:

- **Codex** runs the local `codex` CLI and boots `codex app-server` automatically when a thread starts.
- **Claude Code** uses Anthropic's Claude Agent SDK against the local Claude Code runtime.
- **OpenCode** drives the `opencode` CLI and starts `opencode serve` on demand.
- **Cursor** speaks to the local Cursor CLI ACP server (`agent acp`).

All four run against the project directory you imported into Verde. Tokens,
transcripts, and project files stay on your machine.

## Codex

Install the [Codex CLI](https://github.com/openai/codex) and authenticate:

```bash
codex login
```

Verify `codex` is on `PATH` from a normal shell. Verde starts `codex app-server`
when a Codex thread begins; you do not need to start it yourself.

Codex threads support the Fast/Default speed toggle in the composer toolbar.
The pill maps to Codex's `service_tier` / `fast_mode`. If you change the
underlying Codex service tier configuration, no Verde change is needed.

## Claude Code

Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in
on your machine. Verde talks to the local runtime through Anthropic's Claude
Agent SDK — there is no Verde-side authentication. Make sure the Claude Code
binary is reachable from the shell environment Verde was launched from.

## OpenCode

Install [OpenCode](https://github.com/anomalyco/opencode) and verify `opencode`
is on `PATH`. Verde starts `opencode serve` on demand when an OpenCode thread
begins.

OpenCode does not have a Codex-style speed tier concept. The composer's
Fast/Default toggle is hidden automatically when OpenCode is the selected
provider — do not expect to see it.

## Cursor

Install the [Cursor CLI](https://cursor.com/docs/cli/installation), make sure
`agent` is on your `PATH`, and authenticate:

```bash
agent login
```

`CURSOR_API_KEY` is also supported for headless environments where interactive
login is not possible. Verde talks to the Cursor ACP server (`agent acp`) over
its native protocol.

## Switching providers

Each chat thread is bound to one provider. The composer's provider switcher
shows the four providers and indicates which are detected and authenticated on
your machine. Picking a provider that is not installed or signed in produces an
explicit failure with a hint — Verde will not silently drop the prompt.

To run several providers side by side, create additional chat threads (one per
provider) and tile them in the same workspace. Each thread keeps its own
provider, model, and transcript; the layout is shared.

## Driving provider CLIs from terminal docks

You can also launch a provider's TUI directly inside a terminal dock — useful
when you want the agent's native UI rather than Verde's chat surface:

```bash
verde live agent open --provider codex
verde live process restart --name codex
```

The first command opens a managed Codex TUI without requiring a `verde.yml`
entry. The second launches or restarts a Codex agent declared in your
`verde.yml` `agents:` block. See [Configuration & state](/docs/config) for the
stack schema and the [CLI reference](/docs/cli) for the full command surface.

## Troubleshooting provider auth

If prompt sending fails, check in this order:

1. **Is the provider installed?** `which codex`, `which opencode`, `which agent`, etc., from the shell Verde was launched in. GUI launches on some platforms inherit a different `PATH` than a terminal — relaunch Verde from a terminal if you suspect this.
2. **Is the provider authenticated?** Re-run the provider's login command (`codex login`, `agent login`, etc.) and confirm credentials are still valid.
3. **Is the project imported?** Verde runs the provider against the imported project directory. A provider CLI in a different working directory will not see the same files.
4. **Check the logs.** Provider helper stderr is written to the runtime log alongside Zig panics. On Linux:
   ```bash
   tail -f ~/.local/share/verde/Native/logs/verde.stderr.log
   ```

For broader install and runtime issues, see [Troubleshooting](/docs/troubleshooting).
