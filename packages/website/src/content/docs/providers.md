---
title: Provider setup
description: How Verde talks to local coding-agent CLIs, plus per-provider setup and troubleshooting notes for Codex, Claude Code, OpenCode, Cursor, Pi, FX, Grok, and Amp.
section: Get started
order: 2
slug: providers
---

## How providers work

Verde does not host a model and does not relay your prompts through a hosted
backend. It spawns and talks to the coding-agent CLIs you already have on your
machine, and supports each agent in one or both of two modes:

- **GUI chat** — the provider drives Verde's native chat panes over its own
  protocol: streaming transcript, composer, slash commands, approvals.
- **Terminal TUI** — Verde launches the agent's own TUI inside an embedded
  Ghostty terminal pane, wired into the sidebar's live status pips.

| Provider    | GUI chat | Terminal TUI | How the GUI integration talks                                  |
| ----------- | -------- | ------------ | -------------------------------------------------------------- |
| Codex       | ✓        | ✓            | Runs the local `codex` CLI; boots `codex app-server` per thread |
| Claude Code | ✓        | ✓            | Anthropic's Claude Agent SDK against the local runtime          |
| OpenCode    | ✓        | ✓            | Drives the `opencode` CLI; starts `opencode serve` on demand    |
| Cursor      | ✓        | ✓            | Speaks to the Cursor CLI ACP server (`agent acp`)               |
| Pi          | ✓        | ✓            | Drives `pi --mode rpc` (JSONL over stdio), one process per turn |
| FX          | ✓        | ✓            | Speaks ACP to the `fx` CLI (`fx acp`), one process per turn     |
| Grok Build  | ✓        | ✓            | Speaks ACP to the `grok` CLI (`grok agent stdio`), one process per turn |
| Amp         | –        | ✓            | TUI-only — launches the `amp` CLI in a terminal pane            |

All of them run against the project directory you imported into Verde. Tokens,
transcripts, and project files stay on your machine.

## Readiness check

If none of the GUI providers is available at launch, Verde opens **Connect an
AI provider**. Each provider reports **Ready**, **CLI not found**, **Sign-in
needed**, or **Could not verify** while Verde checks its executable and local
authentication. Install or sign in using the instructions below, then choose
**Check again**. **Open setup guide** returns to this page and **Not now**
dismisses the screen.

Amp is excluded from this check because it is TUI-only. A GUI
provider can also become unavailable later—for example, after credentials
expire—in which case sending shows an explicit error instead of dropping the
prompt.

## Codex

Install the [Codex CLI](https://github.com/openai/codex) and authenticate:

```bash
codex login
```

Verify `codex` is on `PATH` from a normal shell. Verde starts `codex app-server`
when a Codex thread begins; you do not need to start it yourself.

Codex threads expose **Default** and **Fast** under the composer's **Run** pill.
The setting maps to Codex's `service_tier` / `fast_mode`. The Run menu also
shows the reasoning levels supported by the selected model and the thread's
access setting.

## Claude Code

Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in
on your machine. Verde talks to the local runtime through Anthropic's Claude
Agent SDK — there is no Verde-side authentication. Make sure the Claude Code
binary and `node` are both reachable from the shell environment Verde was
launched from. Packaged Verde installs include the provider bridge; Verde runs
it with the Node.js executable found on `PATH`.

## OpenCode

Install [OpenCode](https://github.com/anomalyco/opencode) and verify `opencode`
is on `PATH`. Verde starts `opencode serve` on demand when an OpenCode thread
begins.

OpenCode does not have a Codex-style speed tier concept, so the **Speed** row is
hidden when OpenCode is selected.

## Cursor

Install the [Cursor CLI](https://cursor.com/docs/cli/installation), make sure
`agent` is on your `PATH`, and authenticate:

```bash
agent login
```

`CURSOR_API_KEY` is also supported for headless environments where interactive
login is not possible. Verde talks to the Cursor ACP server (`agent acp`) over
its native protocol.

Cursor models that advertise fast-mode support show **Default** and **Fast**
under the **Run** pill. The row is hidden for Cursor models without that
capability.

## Pi

Install the [pi coding agent](https://pi.dev) and verify `pi` is on `PATH`.
Verde drives pi in its programmatic RPC mode (`pi --mode rpc`, JSONL over
stdio), starting one process per turn and resuming the same pi session for
follow-up turns, so `pi` in a terminal sees the same project sessions.

Pi authenticates against model providers through its own configuration
(`pi login`, or API keys in pi's settings) — there is no Verde-side
authentication. The readiness check reports **Sign-in needed** when the model
provider currently selected in pi is not authenticated.

The default model entry, **Default (pi config)**, defers to the model
configured in pi itself; the model picker also lists every model pi reports as
available, using pi's `provider/model` refs. Reasoning levels map one-to-one
onto pi thinking levels (low through max). Pi has no Codex-style speed tier,
so the **Speed** row is hidden.

Existing pi sessions for the imported project can be imported as Verde threads
(pi stores them per project directory). Pi does not use Verde's slash-command
surface yet.

To use the interactive TUI instead, open the current Pi thread with **Open
Current Thread in TUI**, or launch `pi` in a terminal pane.

## FX

Install [fx](https://fx.sh) with its setup script and authenticate against
Vercel AI Gateway:

```bash
curl -fsSL https://fx.sh/setup.sh | bash
fx login
```

Verify `fx` is on `PATH` from a normal shell. Desktop launches often miss the
installer location, so Verde also looks for `~/.local/bin/fx`. Verde drives fx
through its Agent Client Protocol server (`fx acp`), starting one process per
turn. The readiness check reports **Sign-in needed** until `fx login` has
cached a usable Vercel AI Gateway credential.

The default model entry, **Default (fx config)**, defers to the model
persisted inside fx itself; the model picker also lists every model fx
reports through ACP `configOptions`. FX has no reasoning-effort or speed-tier
controls, so those rows are hidden. Image attachments are forwarded when the
ACP session advertises image support. FX does not use Verde's slash-command
surface yet, and existing fx sessions cannot be imported as Verde threads
yet.

To use the interactive TUI instead, open the current FX thread with **Open
Current Thread in TUI**, or launch `fx` in a terminal pane.

## Grok Build

Install Grok Build using its
[official setup guide](https://docs.x.ai/build/overview#install) and make sure
`grok` is on the `PATH` inherited by Verde, then run `grok login` once. Verde
drives Grok through its Agent Client Protocol server (`grok agent stdio`),
starting one process per turn and resuming the same grok session for
follow-up turns, so `grok --resume` in a terminal sees the same threads. The
readiness check reports **Sign-in needed** until `grok login` has cached a
token.

The default model entry, **Default (grok config)**, defers to the model
persisted in grok itself; the model picker also lists every model grok
reports (Grok 4.6, Grok 4.5, …). Reasoning levels map onto grok's reasoning
efforts (low through extra high; there is no `max`). Grok has no speed tier,
so the **Speed** row is hidden. Image attachments are forwarded to Grok;
note that grok drops images smaller than about 512 pixels total without
reporting an error. Grok loads
Verde's MCP server from its own global config, so tool calls appear as
command rows in the transcript. Existing grok sessions cannot be imported as
Verde threads yet.

Grok's own slash commands run through Verde's composer: the picker lists the
built-ins (`/compact`, `/context`, `/session-info`, `/always-approve`,
`/feedback`, `/review`, `/implement`, `/design`, `/deep-research`, `/goal`,
`/loop`, `/workflow`, `/plugins`, `/hooks-list`), and any other command or
installed skill grok advertises (for example `/figma-use` or `/omarchy`) is
forwarded as typed. Verde sends the `/name args` text as a prompt turn, grok
resolves it, and the reply lands in the thread as a system row.

If Verde cannot find it, open `Ctrl+Shift+P` and run **Set Up Grok Build**.
To use the interactive TUI instead, use **Start New Grok TUI** or:

```bash
verde live agent open --provider grok
```

Verde checks `PATH` without running Grok and launches managed sessions with
`grok --no-auto-update` so an update check cannot disrupt the PTY. A managed
launch also attempts to install Verde's isolated personal status hook. You can
manage it explicitly in **Settings → Status pip hooks** or from the CLI:

```bash
verde integrations install grok --global
verde integrations remove grok --global
```

The hook lives at `$GROK_HOME/hooks/verde-notify.json`, defaulting to
`~/.grok/hooks/verde-notify.json`, and remains inert unless Grok inherited a
Verde terminal identity. It reports idle, working, waiting, done, and error
activity to the pane and sidebar. After a session completes, Verde also
best-effort synchronizes Grok's generated session title when its summary file
becomes available.

## Amp

Install [Amp](https://ampcode.com) and make sure `amp` is on your `PATH`. Amp
is **TUI-only**: it does not appear in the chat composer's provider switcher.
Instead, launch it from the command palette (`Ctrl+Shift+P` → **Start New Amp
TUI**) and Verde opens the `amp` CLI in a new embedded terminal pane in the
current workspace.

To wire Amp into the sidebar's live status pips, install Verde's Amp plugin:

```bash
verde integrations install amp --global
```

That writes a small lifecycle plugin to `~/.config/amp/plugins/verde-notify.ts`
which reports `working` / `done` / `error` to the pane's status pip as the
agent runs (only when Amp is running inside a Verde pane). You can also toggle
it from the settings modal under **Status pip hooks**, and remove it with
`verde integrations remove amp --global`.

## Models and run settings

The searchable model picker groups models by provider, marks defaults, and
supports `Ctrl+1` through `Ctrl+9` for its visible results. OpenCode, Claude
Code, Cursor, Pi, FX, and Grok model lists are loaded from the installed provider; Codex
uses Verde's supported model list.

Before a new thread sends its first message, choosing a model can also switch
the provider. Once the transcript has started, the provider is locked to keep
the provider session consistent. The **Run** pill contains only controls the
selected provider/model supports: reasoning, **Default/Fast** speed, and
**Supervised/Full access** permissions. See [Chat, models & runs](/docs/chat)
for the complete behavior.

To run several providers side by side, create additional chat threads (one per
provider) and tile them in the same workspace. Each thread keeps its own
provider, model, and transcript; the layout is shared.

## Driving provider CLIs from terminal docks

You can also launch any provider's TUI directly inside a terminal pane — useful
when you want the agent's native UI rather than Verde's chat surface. The
command palette (`Ctrl+Shift+P`) has a **Start New … TUI** entry for each of
Codex, Claude, OpenCode, Cursor, Grok, and Amp, plus **Open Current Thread in TUI**
entries that promote a running GUI chat thread — including Pi, FX, and Grok —
into that provider's terminal TUI. Launch `pi` in a terminal pane for a fresh
Pi TUI. Right-clicking inside a terminal offers configured custom launch profiles
and pane actions; use the palette or CLI for built-in provider TUI actions.

From the CLI:

```bash
verde live agent open --provider codex
verde live agent open --provider grok
verde live process restart --name codex
```

The first two commands open managed provider TUIs without requiring a
`verde.yml` entry. Verde detects Grok from `PATH` without running it, offers a
setup-guide action when it is absent, and launches it with `--no-auto-update`.
The last command launches or restarts a Codex agent declared in your
`verde.yml` `agents:` block. See [Configuration & state](/docs/config) for the
stack schema and the [CLI reference](/docs/cli) for the full command surface.

## Troubleshooting provider auth

If prompt sending fails, check in this order:

1. **Is the provider installed?** `which codex`, `which opencode`, `which agent`, `which pi`, `which fx`, `which grok`, etc., from the shell Verde was launched in. GUI launches on some platforms inherit a different `PATH` than a terminal — relaunch Verde from a terminal if you suspect this.
2. **Is the provider authenticated?** Re-run the provider's login command (`codex login`, `agent login`, `fx login`, `grok login`, `pi login`, etc.) and confirm credentials are still valid.
3. **Is the project imported?** Verde runs the provider against the imported project directory. A provider CLI in a different working directory will not see the same files.
4. **Check the logs.** Provider helper stderr is written to the runtime log alongside Zig panics. On Linux:
   ```bash
   tail -f ~/.local/share/verde/Native/logs/verde.stderr.log
   ```

For broader install and runtime issues, see [Troubleshooting](/docs/troubleshooting).
