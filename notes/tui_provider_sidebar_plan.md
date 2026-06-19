# TUI Provider Sidebar Integration Plan (logos + titles + hooks)

**Status:** plan only — not implemented yet.

Goal: bring the remaining TUI agents (amp first; cursor / opencode parity;
future PI) up to the same sidebar treatment that codex and claude already get
— correct **provider logo glyph** and **live title** on terminal panes — and
lay the groundwork for an eventual **Amp SDK GUI chat provider**.

---

## 1. How codex / claude work today (the model to copy)

There are two *separate* notions of "provider" in the codebase, and the
distinction is the whole reason amp behaves the way it does.

### a) Chat/harness `Provider` enums

There are two closely-related chat-provider enums today:

```zig
pub const Provider = enum(u8) { opencode, codex, claude, cursor };
```

- `packages/desktop/src/db/types.zig` owns the **persisted** SQLite provider
  enum. It has explicit integer tags; do not casually add/reorder values.
- `packages/desktop/src/provider_types.zig` owns the provider enum used by the
  native harness layer. It is the discriminant for the harness unions in
  [harness.zig](../packages/desktop/src/harness.zig) (`ProviderConfig`,
  `ProviderClient` are `union(Provider)`).

The current enum order is not identical between those two files, so treat them
as two contracts that must be updated deliberately when adding a real GUI chat
provider. A value in either one effectively means a first-class native chat
harness exists. **amp is not in either enum** today — amp has no chat harness.

### b) Sidebar terminal-pane agent glyph + title

The sidebar row renderer is `renderOpenPaneRow` in
[sidebar.zig](../packages/desktop/src/ui/sidebar.zig#L1062-L1104). For a
`.terminal` pane it picks an agent in this priority order:

1. `surface.provider` (`?Provider`) — set from a notify hook.
2. `providerFromComm(comm)` — matches the live foreground process name
   ([sidebar.zig#L1586](../packages/desktop/src/ui/sidebar.zig#L1586)):
   `claude`, `codex`, `opencode`, `cursor*`.
3. `dock.activeTabPinnedProvider()` → `std.meta.stringToEnum(Provider, name)`
   — the provider tag pinned on the tab, persisted across restarts.

The glyph is drawn by `queuePaletteAgentTerminalGlyph` →
`queuePaletteProviderGlyphInRect`
([sidebar.zig#L1556](../packages/desktop/src/ui/sidebar.zig#L1556)), which
switches on `Provider` to choose a logo texture, with a single-letter fallback
(`C`, `O`, `Cl`, `Cu`) when the texture is missing.

The **title** comes from (in order): the surface title (hook-pinned), the live
terminal OSC title / process label, then `"Terminal"`.

### c) The notify-hook pipeline (where titles + provider get pinned)

```diagram
╭──────────────────────╮   OSC / spawn    ╭───────────────────────────╮
│ agent CLI (codex,     │ ───────────────▶ │ .verde/hooks/*-notify.sh  │
│ claude) runs in pane  │   hook fires     │ (installed per project)   │
╰──────────────────────╯                  ╰───────────┬───────────────╯
                                                       │ verde notify
                                                       │ --status --title
                                                       │ --provider <name>
                                                       ▼
                              ╭───────────────────────────────────────╮
                              │ cli.zig handleNotify → IPC             │
                              │ notification.create                    │
                              ╰───────────────┬───────────────────────╯
                                              ▼
              ╭──────────────────────────────────────────────────────╮
              │ ipc/server.zig notificationUpdateResponse             │
              │  • parseProvider(value) → ?Provider   ◀── GATE        │
              │  • state.updateSurface(...)                           │
              ╰───────────────┬──────────────────────────────────────╯
                              ▼
   state.zig updateSurface (#L6225): s.provider = value;
        dock.setActiveTabPinnedProvider(@tagName(value))  → tab pinned string
                              ▼
            sidebar reads surface.provider / pinned string → logo + title
```

- Hook scripts are generated in
  [provider_hooks.zig](../packages/desktop/src/provider_hooks.zig):
  `ensureCodexProjectHooks` writes `.verde/hooks/codex-notify-hook.sh` +
  `.codex/hooks.json`; `ensureClaudeProjectHooks` writes the hook +
  `.claude/settings.local.json`. Both map agent lifecycle events
  (`SessionStart`/`UserPromptSubmit`/`Stop`/permission) to
  `verde notify --status … --provider …`, and the codex hook even derives a
  sidebar title from the prompt text.
- `verde.yml` `agents:` entries carry `notify: true` / `hooks: true`
  ([stack.zig](../packages/desktop/src/stack.zig#L33)).
- `verde integrations doctor` reports hook state per provider
  ([cli.zig#L655](../packages/desktop/src/cli.zig)): claude/codex =
  `project-local`, opencode/cursor = `unsupported`.

### Why amp "titles work" but there is no logo

amp running in a terminal has **no** entry in `Provider`, **no** `providerFromComm`
match, and **no** hook — so step (a/b/c) all yield `null`. The sidebar falls
back to the plain terminal glyph + the live **OSC title**, which is why you see
a correct title but a generic `>_` icon instead of an amp logo.

---

## 2. Decision: keep TUI-agent identity separate from chat `Provider`

Do **not** add `amp` to the persisted `Provider` enum to fix the sidebar. That
enum implies a chat harness + DB serialization + every `union(Provider)` switch,
and would be a large, risky change for something amp doesn't need yet.

Instead introduce a small, sidebar-scoped enum for "which agent CLI is running
in this terminal pane", a **superset** of `Provider` plus TUI-only agents:

```zig
// sidebar.zig
/// Agents that can run inside a terminal pane. Superset of the persisted chat
/// `Provider` enum: also covers TUI-only agents (amp, …) that have no chat
/// harness yet but should still show a logo + split glyph in the sidebar.
const TuiAgentKind = enum { codex, claude, opencode, cursor, amp };
```

This decouples "agent visible in a terminal" from "provider with a chat
harness", and is where future TUI agents (PI) get added cheaply.

---

## 3. Work plan — amp sidebar (logo + title)

Scope: terminal-pane glyph only. No DB/harness changes.

1. **Asset**: add an amp logo PNG to
   `packages/desktop/src/assets/` (e.g. `amp-logo.png`). The 32×32 favicon from
   ampcode.com is a usable stopgap (the orange three-chevron mark; a candidate
   is saved at `/tmp/amp_frame-1.png`), but prefer a higher-res source to match
   the existing 128–512px logos. Wire it like the others in
   [state.zig](../packages/desktop/src/state.zig): `@embedFile` const (#L801),
   `amp_logo_texture` field (#L3404), null-init (#L3636), and
   `loadEmbeddedTexture` (#L3757).
2. **Detection** (sidebar.zig):
   - Replace the terminal branch's `?Provider` locals with `?TuiAgentKind`.
   - Add `tuiAgentFromComm` covering `amp` (and existing four). Start with a
     narrow exact match (`comm == "amp"`) and verify the real foreground `comm`
     name in a Verde terminal; avoid broad substring matching.
   - Add `tuiAgentFromName` (replaces `stringToEnum(Provider, …)`) so a pinned
     `"amp"` string resolves.
   - Map `surface.provider` (`?Provider`) into `TuiAgentKind` via a
     `fromProvider` helper.
3. **Glyph** (sidebar.zig): add a `TuiAgentKind` texture/letter map
   (parallel to `queuePaletteProviderGlyphInRect`, amp → `amp_logo_texture`,
   letter fallback `A`); point `queuePaletteAgentTerminalGlyph` at it.
4. **Title**: already works via OSC fallback. Optional improvement comes for
   free once amp hooks (section 5) pin a title via `verde notify --title`.
5. **Future-provider comment**: at the `TuiAgentKind` definition, document the
   exact add-a-provider checklist (enum tag → comm match → name match →
   texture/letter → optional logo asset), calling out **PI** as the next
   expected addition.

This first slice should not touch DB provider enums, harness unions, IPC notify
parsing, hook installers, stack config parsing, or composer/model picker code.
It is only the live terminal sidebar glyph path.

> Note: `providerFromComm` already matches `cursor*` and `opencode`, so cursor
> and opencode terminal panes *should* already get logos via the live-process
> path. If they don't in practice, the gap is that they have **no notify hook**
> (section 5), so `surface.provider`/pinned-provider stay null and only the
> live-process path can light them up — verify during testing.

---

## 4. Cursor / opencode parity (mostly title/hook, logo already mapped)

Their logos are already in `Provider` + the glyph switch, and `providerFromComm`
matches them. The real parity gap vs codex/claude is **hooks**: both are
`unsupported` in `integration_providers`
([cli.zig#L658](../packages/desktop/src/cli.zig)), so they get no pinned
title/provider and no busy/done status — only live-process detection + OSC
title. Closing that gap = give them notify hooks (section 5) if/when each tool
exposes a stable hook mechanism.

---

## 5. Amp hooks — mirror the codex/claude pattern (toward an Amp SDK GUI)

Three follow-up layers, in order of effort:

### Layer 0 — managed `verde.yml` stack identity (optional, before hooks)

If we want this in `verde.yml`:

```yaml
agents:
  amp:
    provider: amp
    command: "amp"
    notify: true
    hooks: true
```

then `packages/desktop/src/stack.zig` also needs a TUI/process-provider entry:

- Add `.amp` to `stack.AgentProvider` and `parseProvider`.
- Keep `state.zig` `providerFromStack(.amp)` returning `null` until there is a
  GUI chat harness. This stack enum identifies managed TUI processes; it is not
  the persisted chat `Provider` enum.
- If the stack provider is used for sidebar identity before hooks exist, route it
  through the same `TuiAgentKind` mapping rather than promoting amp into DB or
  harness provider enums.

### Layer A — amp notify hook (cheap, big UX win)

Add `ensureAmpProjectHooks` in
[provider_hooks.zig](../packages/desktop/src/provider_hooks.zig) mirroring the
codex installer:

- Write `.verde/hooks/amp-notify-hook.sh` guarded by `VERDE=1` /
  `VERDE_SESSION_ID`.
- Map amp's hook/lifecycle events to
  `verde notify --status {working|waiting|done} --title <derived> --provider amp`.
  - Confirm amp's hook surface: amp supports config-defined tool/agent hooks and
    settings; identify the events analogous to
    `SessionStart`/`UserPromptSubmit`/`Stop`/permission and the JSON payload
    shape (so the title can be derived from the prompt like the codex hook does).
- Install location: amp's settings/config file (analogous to
  `.codex/hooks.json` / `.claude/settings.local.json`), with a managed marker
  (`verde-amp-notify-hook`) so re-runs are idempotent and user hooks are
  preserved.
- Register amp in `integration_providers` (cli.zig) as `project-local` and add
  it to the `verde integrations doctor` summary.
- Add an `amp` entry to `verde.yml` `agents:` (`provider: amp`,
  `notify: true`, `hooks: true`).

**Blocker to resolve first:** `notification.create` runs the provider string
through `parseProvider` → `?Provider`
([ipc/server.zig#L556](../packages/desktop/src/ipc/server.zig#L556),
[#L1769](../packages/desktop/src/ipc/server.zig#L1769)), and `updateSurface`
stores `@tagName(Provider)`. Since amp isn't a `Provider`, `--provider amp`
is currently dropped. Options:

- **(preferred, minimal)** Let the notify path carry an *agent tag string* for
  the sidebar that is independent of `Provider`. Concretely, add a field like
  `agent_tag: ?[]const u8` to `SurfaceUpdate`, set it from the raw
  `provider`/agent string in `notificationUpdateResponse`, and keep
  `.provider = parseProvider(value)` for real chat providers only. In
  `updateSurface`, pin the raw tag with `setActiveTabPinnedProvider` after
  validating it with the TUI-agent-name resolver. The sidebar then resolves the
  pinned string through `tuiAgentFromName`. This keeps `surface.provider`
  (`?Provider`) clean while letting amp pin `"amp"` for the glyph.
- (heavier) Promote agent identity to its own persisted enum end-to-end. Defer
  until the SDK provider (Layer B) actually needs a harness.

Implementation note: keep `TuiAgentKind` private to `sidebar.zig` for the first
glyph-only slice. When IPC/state needs to validate `agent_tag`, move the enum or
just the string resolver to a small non-UI/shared location; `ipc/server.zig` and
`state.zig` should not import sidebar UI code.

### Layer B — Amp SDK chat provider (the eventual Amp GUI)

This is the path to a first-class amp chat experience (not just a TUI pane),
mirroring how claude uses the Agent SDK bridge
([provider_bridge.ts](../packages/desktop/src/providers/provider_bridge.ts), which
wraps `@anthropic-ai/claude-agent-sdk`) and how codex talks to `codex app-server`.

Steps when ready:

1. Promote `amp` into the persisted/chat `Provider` enums
   (`provider_types.zig` + `db/types.zig`, new explicit integer tag) and handle
   every `union(Provider)` / `switch (provider)` site (harness.zig, ipc/server
   `parseProvider`, model picker, composer toolbar gating, etc.).
2. Add `providers/amp.zig` implementing the harness contract
   (`connect`/`authState`/`listThreads`/`sendPrompt`/stream events) over the
   Amp SDK — either an SDK bridge process like `provider_bridge.ts` or a direct
   transport, following the thin-harness rules in
   [providers/plan.md](../packages/desktop/src/providers/plan.md).
3. Map amp streaming to `on_stream_delta` (assistant text) and
   `on_stream_event` (`.message{title,body}` / `.diff{files}`) per the
   "Provider transcript UI contract" in `packages/desktop/AGENTS.md`; reuse the
   codex-style `Ran command` / `Command failed` authors so the compact command
   rows render without new heuristics.
4. Honor the provider rules in AGENTS.md: multi-image attachments, Fast/Default
   pill only if amp has a comparable concept (else hide it), explicit failure if
   a capability is unsupported.
5. Once amp is a real `Provider`, the sidebar `TuiAgentKind` amp case can map
   straight from `Provider.amp` and the Layer-A string-pin shim can be removed.

### Sequencing

```diagram
Layer A (notify hook + sidebar glyph)         Layer B (SDK chat provider)
  ├─ amp logo asset + TuiAgentKind             ├─ add amp to Provider enum
  ├─ amp-notify-hook.sh + verde.yml            ├─ providers/amp.zig (SDK bridge)
  ├─ string-pin shim in notify path            ├─ stream → transcript contract
  └─ doctor/integrations entry                 └─ retire shim, glyph maps direct
        (ships independently, low risk)              (larger, gated change)
```

---

## 6. Verification (per AGENTS.md — real app, not unit tests)

Use `mise run build` then `mise run dev`, and the `verde live …` CLI. For each
of amp / cursor / opencode in a terminal pane, confirm:

- correct provider logo in the sidebar split glyph (not the letter fallback),
- live title updates while the agent runs,
- (after hooks) busy → done status color + pinned title persists across restart.

Run the `agent-ci` skill before considering any of this done.
