# GUI Chat Slash Commands Plan

## Goal

Add slash commands to GUI chat threads, starting with Codex and leaving a clean path for OpenCode, Claude, and Cursor. Common commands should feel consistent across providers, while provider-specific commands should map to the provider's real protocol instead of pretending every backend accepts the same text prompt.

## Current Findings

- The Palette composer already hints at slash commands with `Ask anything, or use / to show available commands`.
- Submit currently flows through file-search acceptance, `handleWorkspaceCommand`, then `sendDraft`.
- Verde-local slash commands already exist for `/stack` and `/process`.
- Provider slash commands are not modeled in `provider_types.zig` or `harness.zig`.
- Codex app-server exposes real RPC methods for several slash-command behaviors:
  - `/compact` maps to `thread/compact/start`.
  - `/goal` maps to `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear`.
  - `/usage` maps to `account/usage/read`, with live per-thread updates from `thread/tokenUsage/updated`.
  - `/review` maps to `review/start`.
  - `/shell` maps to `thread/shellCommand`, but the protocol documents it as unsandboxed full access, so it should not be enabled without an explicit confirmation UX.

## Architecture

Add a provider-aware slash-command layer rather than special-casing provider commands in the composer or sending raw slash text as a prompt.

This is intended to cover **all GUI chat providers**. Codex is only the first implementation target because its app-server protocol already exposes native command-like RPCs. The shared parser, command discovery metadata, composer menu, routing, and result rendering should be provider-neutral from the beginning so OpenCode, Claude, Cursor, and future providers can expose their own supported commands without rewriting the GUI layer.

Do not force fake parity. If a provider has no native equivalent for a command, show it as unsupported/absent for that provider rather than sending a raw prompt that looks like a command.

1. Add shared command metadata to `provider_types.zig`.
2. Add provider dispatch methods to `harness.zig`.
3. Parse leading slash commands in `state.zig` before `sendDraft`.
4. Render a provider-filtered slash menu from composer state, including Verde-local commands like `/stack` and `/process`.
5. Dispatch commands through the active provider client using background work so blocking provider RPCs do not freeze the UI thread.
6. Write command outcomes to transcript/system UI where useful.

### Implementation Notes From Review

- **All GUI providers are in scope.** The shared layer should be designed for Codex, OpenCode, Claude, Cursor, and future GUI providers, even though Codex commands ship first.
- **Codex first is a rollout choice, not a product limit.** Codex has known app-server RPCs for `/compact`, `/goal`, `/usage`, and `/review`; other providers need protocol/API discovery before claiming support.
- **Keep command discovery provider-owned.** The UI can render a shared menu, but the harness/provider side should say which commands are available, disabled, unsupported, sensitive, or argument-taking for the current thread/provider state.
- **Run provider commands asynchronously.** Slash command execution must not run blocking WebSocket/CLI calls directly inside the Palette composer submit callback. Add a command worker/state path or reuse a send-like background flow.
- **Make result ownership explicit.** Formatted notices/transcript rows from commands like `/usage` and `/goal status` will often be allocated. `RunSlashCommandResult` should either have a `deinit` method or otherwise document which allocator owns returned strings.
- **Parse before executing.** Add parser tests for local commands, provider commands, `//` literal slash escape, and unknown slash commands before wiring provider RPCs.
- **Unknown slash commands should be handled.** Once the parser exists, `/unknown` should show usage/suggestions instead of falling through to `sendDraft` and being sent to the provider as a normal prompt.
- **Local commands belong in the menu too.** `/stack` and `/process` are already supported Verde-local commands, so the slash picker should not only show provider commands.
- **Be explicit about `requires_thread`.** `/usage` is account/provider-level and should not require a provider thread; `/compact`, `/goal`, and `/review` should require an existing provider thread. Avoid a default that accidentally disables account-level commands.
- **Treat `/compact` completion conservatively.** The current generic Codex RPC await path ignores unrelated notifications until the matching response. First implementation should call the RPC, report the observed result, and sync the thread afterward; add richer completion watching only after confirming the exact app-server events.
- **Keep `/shell` deferred.** It maps to an unsandboxed full-access operation and needs an explicit confirmation UX before dispatch.

## Shared Types

Add provider-neutral types similar to:

```zig
pub const SlashCommandScope = enum(u8) {
    local,
    provider,
};

pub const ProviderSlashCommandId = enum(u8) {
    compact,
    goal,
    usage,
    review,
    shell,
};

pub const ProviderSlashCommand = struct {
    id: ProviderSlashCommandId,
    name: []const u8,
    summary: []const u8,
    usage: []const u8,
    requires_thread: bool,
    destructive_or_sensitive: bool = false,
};

pub const RunSlashCommandRequest = struct {
    thread_id: ?[]const u8,
    cwd: ?[]const u8 = null,
    command: ProviderSlashCommandId,
    raw_text: []const u8,
    args: []const u8,
};

pub const RunSlashCommandResult = struct {
    handled: bool,
    notice: ?[]const u8 = null,
    transcript_title: ?[]const u8 = null,
    transcript_body: ?[]const u8 = null,

    // Implementation should document ownership for allocated strings and add
    // a deinit helper if these fields are allocator-owned.
};
```

Exact names can change during implementation, but the important part is keeping command discovery and command execution on the harness/provider side.

## Codex Phase 1

Implement Codex commands first because the app-server protocol already exposes the needed operations.

### `/compact`

- Require an existing provider thread.
- Ensure the thread is loaded.
- Call `thread/compact/start` with `{ threadId }`.
- Watch for completion through the normal Codex notification loop if the call starts an active operation.
- Refresh the thread afterward so persisted compaction/history state is visible.
- Add a system row such as `Codex command` / `Compacted thread context.`.

### `/goal`

Support:

- `/goal` or `/goal status`: call `thread/goal/get`.
- `/goal <objective>`: call `thread/goal/set` with `objective`.
- `/goal active|paused|blocked|complete`: call `thread/goal/set` with `status`.
- `/goal clear`: call `thread/goal/clear`.
- Optional later: `/goal budget <tokens>` maps to `thread/goal/set` with `tokenBudget`.

Show concise results in the sidebar notice and optionally as a system transcript row.

### `/usage`

- Call `account/usage/read`.
- Format lifetime/current usage and daily buckets when present.
- Later, persist the latest `thread/tokenUsage/updated` notification on the thread so `/usage` can include current context-window usage.

### `/review`

- Map to `review/start`.
- Keep the first version conservative:
  - require an existing thread,
  - use the provider default target only after confirming the generated protocol's `ReviewTarget` shape,
  - otherwise show usage instead of guessing.

### `/shell`

Do not enable in the first pass. Codex documents `thread/shellCommand` as unsandboxed full access. Add it only after there is an explicit confirmation path that makes the risk visible before dispatch.

## Composer UX

Add a small slash-command picker to the Palette composer:

- Open when the current draft is `/` or starts with `/prefix`.
- Filter commands by active provider and current thread state.
- Include Verde-local commands (`/stack`, `/process`) as first-class entries alongside provider commands.
- Show command name, provider badge, and one-line summary.
- Selecting a zero-argument command can submit immediately.
- Selecting an argument-taking command inserts the command template and keeps focus in the composer.
- Unknown slash commands should show suggestions instead of silently sending.
- Allow literal slash text by escaping with `//`, which sends the message after removing one leading slash.

Commands that require an existing provider thread should be disabled on uncommitted threads. For `/compact`, `/goal`, and `/review`, the user should first send at least one real prompt so the provider thread exists.

## Submit Routing

Update submit routing in `paletteComposerPromptEvent`:

1. If file-search has a primary result, accept it.
2. If `handleWorkspaceCommand` handles `/stack` or `/process`, stop.
3. If the draft is a provider slash command, run it.
4. Otherwise call `sendDraft`.

Provider slash handling should live in a separate helper, for example `handleProviderSlashCommand`, so workspace commands stay isolated.

Provider command execution should enqueue/start background work and return quickly from the submit callback. Do not block the UI event handler on provider RPC calls.

## Transcript And Notices

Use transcript rows for command effects that matter later:

- `Codex command`: compact started/completed.
- `Goal`: goal set, status changed, or cleared.
- `Usage`: token/rate-limit summary.

Use sidebar notices for short status or errors:

- `Usage: /goal <objective>|status|clear|active|paused|blocked|complete`
- `Start a Codex thread before using /compact.`
- `Shell commands require confirmation and are not enabled yet.`

## Other Providers

Do not force parity where the provider API does not expose equivalent behavior.

### OpenCode

- `/usage`: likely maps to `opencode stats` or a server stats endpoint if available.
- `/compact`: verify whether the OpenCode server exposes a session compaction endpoint. If not, mark unsupported.
- Provider-specific candidates later: session export/import, agent switching, model/agent selection.

### Claude

- The current bridge uses the Claude Agent SDK for prompts, sessions, models, and streaming.
- Claude CLI has interactive slash commands, but the current bridge does not expose a command-dispatch API.
- `/compact` should only be added if the SDK or stream-json input supports a documented command event.
- `/usage` can be derived from message usage metadata if available.

### Cursor

- Current provider uses Cursor CLI/ACP-style prompt and session behavior.
- Cursor has user skills and commands in config, but those look more like prompt templates than provider RPC commands.
- Treat custom slash commands as future discovery work:
  - read `.cursor/commands`,
  - read user commands,
  - show them as prompt-template insertions,
  - avoid presenting them as native provider commands unless Cursor exposes a command API.

## Initial Command Matrix

| Command | Codex | OpenCode | Claude | Cursor |
| --- | --- | --- | --- | --- |
| `/compact` | `thread/compact/start` | Investigate | Investigate SDK support | Investigate |
| `/goal` | `thread/goal/*` | Unsupported initially | Unsupported initially | Unsupported initially |
| `/usage` | `account/usage/read` + token updates | Investigate stats | Derive from usage metadata | Derive if available |
| `/review` | `review/start` | Unsupported initially | Maybe provider-specific later | Maybe provider-specific later |
| `/shell` | Defer pending confirmation UX | Unsupported initially | Unsupported initially | Existing skill/template only |

## Testing Plan

- Add parser tests for:
  - `/compact`
  - `/goal`
  - `/goal clear`
  - `/goal complete`
  - `/usage`
  - `//literal slash`
  - unknown slash commands
- Add Codex payload tests for:
  - `thread/compact/start`
  - `thread/goal/get`
  - `thread/goal/set`
  - `thread/goal/clear`
  - `account/usage/read`
- Add UI tests or manual smoke coverage for:
  - menu opens on `/`,
  - filtering works,
  - disabled commands stay disabled,
  - selection inserts or submits correctly,
  - normal prompt sending still works.
- Verify with `mise run build`.
- For runtime UI behavior, use `mise run dev` from outside a Verde terminal pane and test the real Palette composer.

## Rollout Order

1. Add command metadata and parser with tests for local commands, provider commands, literal `//`, and unknown slash commands.
2. Add provider command discovery/dispatch APIs in `provider_types.zig` and `harness.zig`.
3. Add async/background command execution plumbing in `state.zig`.
4. Add Codex `/usage` first because it is account-level and lowest risk.
5. Add Codex `/goal`.
6. Add Codex `/compact`, then sync the thread after the command result.
7. Add slash picker UI for both local and provider commands.
8. Add `/review` after confirming `ReviewTarget`.
9. Investigate provider-specific OpenCode, Claude, and Cursor commands.
10. Revisit `/shell` only after confirmation UX exists.
