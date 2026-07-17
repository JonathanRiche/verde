---
title: Chat, models & runs
description: Provider readiness, searchable model selection, run controls, follow-ups, approvals, and transcript tool-call groups.
section: Workspace
order: 3
slug: chat
---

## Connect a provider

Verde checks the four GUI-chat providers—Codex, Claude Code, OpenCode, and
Cursor—when the app opens. If none is ready, the **Connect an AI provider**
screen reports one of these states for each provider:

- **Ready** — the CLI is installed and authenticated.
- **CLI not found** — install the provider and make sure its executable is on
  the `PATH` inherited by Verde.
- **Sign-in needed** — run the provider's login flow, then return to Verde.
- **Could not verify** — the readiness check failed or timed out.

After installing or signing in, choose **Check again**. **Not now** dismisses
the screen without changing provider configuration. Amp is not listed because
it runs as a terminal TUI rather than a native chat provider. See
[Provider setup](/docs/providers) for the exact install and login commands.

## Choose a provider and model

Create a chat with `Ctrl+T`, then open the model pill in the composer. The
picker has a provider rail, model search, default-model badges, and `Ctrl+1`
through `Ctrl+9` shortcuts for the visible results.

Before the first message is sent, selecting a model from another provider also
switches the thread's provider. Once a thread has messages, its provider is
locked so the transcript and provider session stay consistent; create another
thread to use a different provider.

Verde loads the available models from OpenCode, Claude Code, and Cursor at
runtime. Codex models come from Verde's supported model list. A provider that
is missing or signed out remains visible with a readiness hint instead of
silently accepting a prompt it cannot send.

## Configure a run

The **Run** pill groups the settings that affect the next agent run:

- **Reasoning** appears only when the selected provider and model expose a
  reasoning-effort control.
- **Speed** appears for Codex and for Cursor models that support fast mode.
  Choose **Default** or **Fast**.
- **Access** is always available. **Supervised** asks before risky commands;
  **Full access** lets the agent run commands without asking first.

Access is saved per thread. Reasoning and speed options can change when you
switch models because not every provider exposes equivalent controls.

## Send, steer, and stop

Press `Enter` to send the composer. While an agent is working, a new prompt can
be queued as a follow-up; **Stop** aborts the active run. Verde keeps the draft
with its thread, so changing panes does not discard unfinished text.

The same paths are scriptable with `verde live chat send`, `followup`, `stop`,
and `draft`. See [CLI reference](/docs/cli#chat-control).

## Approvals and input requests

Providers can pause a run for approval. Verde renders the request in the
transcript and lets you approve or deny it without leaving the chat pane.
Codex MCP yes/no confirmations use this same approval surface. Structured MCP
forms are not supported yet; Verde marks the input request unsupported and
declines it rather than guessing an answer.

**Full access** reduces command approvals, so use it only for workspaces and
instructions you trust.

## Tool-call groups

Consecutive tool calls collapse into a summary row showing the number of calls
and their completed, failed, or running state. Click the row to inspect the
individual calls. A group containing a failure opens by default so the error is
not hidden.

Choose the default under **Settings → Transcript → Tool call groups**:

- **Collapsed** — start each group closed unless it failed.
- **Expanded** — start each group open.
- **Remember last** — reuse the last state you chose.

The same preference is available as `transcript.tool_call_groups` in
[`verde.json`](/docs/config#verdejson).

## Design feedback from the browser

For UI work, Design Mode can select an element or region in the browser and
send its DOM context—and, where supported, a screenshot—straight to a chat or
terminal agent. See [Design Mode](/docs/design-mode).
