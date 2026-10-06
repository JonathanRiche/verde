# Workspace switcher sidebar (cross-client spec)

Shared contract for the desktop GUI, web app, iOS and Android navigation
rails. Every client renders the same structure and derives the same
per-workspace identity so a workspace looks identical everywhere.

## Structure (top to bottom)

1. **Header** – logo + sidebar toggle (desktop: toggle shows the full rail or
   hides it entirely; the old icon-only collapsed rail is gone).
2. **Workspace switcher** – full-width trigger row: scope icon, scope label,
   chevron. Default scope is **All Workspaces**.
3. **Search row** – search pill (opens the existing search / command palette)
   with two compact icon buttons to its right: **New chat**, **New terminal**
   (mobile/web may omit terminal where the client has no terminal surface).
   No history button; search covers history.
4. **Body** – two flat sections, no workspace folder rows, no collapse
   chevrons:
   - **Active** – panes/chats that are working, waiting, failed, or have an
     unread completion.
   - **Open** (inactive) – every other open pane/chat.
   Under *All Workspaces* both sections span every open workspace and each
   row carries a small workspace identity chip (icon on tinted square). Under
   a single-workspace scope both sections list only that workspace and rows
   omit the chip.
5. **Footer** – global settings.

## Scope semantics

- Scope is `all` or one workspace id. It only filters the sidebar list; it
  never changes what the main canvas shows.
- Selecting a workspace in the switcher sets scope to it *and* makes it the
  current workspace (same as today's workspace switch). Selecting a closed
  workspace reopens it first.
- Selecting a pane/chat row under *All Workspaces* focuses it (switching the
  canvas to its workspace) but leaves scope at `all`.
- Desktop keybinds: `Alt+1..9` select open workspace N and set scope to it;
  `Alt+0` sets scope to `all`.
- New chat / new terminal target the current workspace in single scope and
  the **most recently used** workspace under *All Workspaces* (the user can
  still change the workspace from the chat UI).

## Switcher popover

Context-menu styled popover anchored under the trigger:

- Search field, placeholder **"Search workspaces"**, fuzzy filters by label.
- **All Workspaces** row first (hidden while the query is non-empty and does
  not match "all").
- One row per workspace — **open and closed** — sorted by recency (most
  recent first). Closed workspaces render dimmed with a "Closed" hint.
- Row: identity icon, label, Alt+N hint (open workspaces, desktop only),
  and a trailing **gear** that opens that workspace's settings (this replaces
  the per-row gear that used to sit beside each workspace).
- Footer row: **New workspace**.
- Keyboard: Up/Down move, Enter selects, Esc closes.

### Recency

Most-recent-first by `max(last time the workspace was selected/focused,
newest thread activity timestamp)`. Clients without a selection timestamp use
the newest thread activity alone. Closed workspaces without timestamps sort
after open ones in most-recently-closed order.

## Workspace identity (icon + color)

Deterministic from the workspace **id** (UTF-8 bytes), so no persistence or
protocol change is needed and every client agrees:

```
h = 0x811C9DC5                       // FNV-1a 32-bit
for byte b in id: h = (h XOR b) * 0x01000193  (mod 2^32)
icon_index  = h mod 16
color_index = (h >> 8) mod 8
```

### Icon set (index → semantic name)

| # | name | # | name |
|---|------|---|------|
| 0 | folder | 8 | code |
| 1 | rocket | 9 | terminal |
| 2 | flask | 10 | globe |
| 3 | leaf | 11 | heart |
| 4 | bolt | 12 | moon |
| 5 | star | 13 | sun |
| 6 | flame | 14 | compass |
| 7 | cube | 15 | puzzle |

Each client maps the semantic name to its native icon system (desktop: Nerd
Font codicons/FontAwesome; web: the app's icon set; iOS: SF Symbols;
Android: Material icons). Use the closest available glyph; keep the index
order fixed.

### Colors (theme-derived)

Color slot `k` (0..7) is the theme **accent** with its HSL hue rotated by
`k * 45°`, saturation clamped to `[0.45, 0.85]`, lightness clamped to
`[0.55, 0.72]` on dark themes and `[0.38, 0.50]` on light themes. Slot 0 is
the accent itself (after clamping). The icon draws in the slot color on a
square chip filled with the same color at ~18% alpha.
