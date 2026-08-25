---
title: Keybinds
description: Every default keybind in Verde, plus how to remap or disable each binding in verde.json.
section: Workspace
order: 6
slug: keybinds
---

## Default keybinds

These are the defaults, read from
`packages/desktop/src/app/keybinds.zig`. Override any of them under `keybinds`
in your Verde config — see [Remapping](#remapping) below.

### App

| Combo                       | Action                                |
| -------------------------- | ------------------------------------- |
| `Ctrl+Shift+P` / `Cmd+Shift+P` | Command palette                    |
| `Ctrl+T` / `Cmd+T`          | New chat thread                       |
| `Ctrl+W` / `Cmd+W`, `Alt+X` | Close the focused pane                |
| `Ctrl+Shift+W` / `Cmd+Shift+W` | Close the current workspace (reopen from the command palette) |
| `Ctrl+Shift+Space`          | Toggle the experimental Companion (when enabled in Settings) |
| `Ctrl+Shift+R` / `Cmd+Shift+R`, `F5` | Refresh / reload app            |
| `Alt+O`                     | Open the default project              |
| `Ctrl+Shift+O`              | Open in external editor               |

### Sidebar & panes

| Combo                       | Action                                |
| -------------------------- | ------------------------------------- |
| `Ctrl+S` / `Cmd+S`          | Toggle the sidebar (visible ↔ icon)   |
| `Ctrl+Shift+S`             | Toggle the sidebar's hidden mode      |
| `Ctrl+Shift+B`              | Toggle the embedded browser pane      |
| `Ctrl+R` / `Cmd+R`          | Reload the active browser tab (browser pane only) |
| `Tab`                       | Inside a chat pane, focus the prompt box |
| `Ctrl+Tab`                  | Focus the next pane in sidebar order     |
| `Ctrl+Shift+Tab`            | Focus the previous pane in sidebar order |
| `Ctrl+1 … Ctrl+9, Ctrl+0`  | Focus a pane in the current workspace by sidebar order |
| `Ctrl+Shift+1 … Ctrl+Shift+9, Ctrl+Shift+0` | Jump to a row in the global Active section by displayed order |
| `Alt+1 … Alt+9, Alt+0`     | Jump between workspaces by sidebar order |
| `Alt+↑` / `Alt+↓`          | Cycle to the previous / next workspace |

Pane cycling wraps at either end. When a pane is zoomed, cycling switches the
zoomed pane without restoring the split layout.

### Focus

| Combo        | Action                                           |
| ------------ | ------------------------------------------------ |
| `Ctrl+Left`  | Focus the pane or horizontal strip item to the left  |
| `Ctrl+Right` | Focus the pane or horizontal strip item to the right |
| `Ctrl+Up`    | Focus the pane or vertical strip item above          |
| `Ctrl+Down`  | Focus the pane or vertical strip item below          |
`Ctrl+H/J/K/L` are intentionally unbound by default. Set the corresponding
`keybinds.workspace.focus_left/down/up/right` values in `verde.json` to opt in.


`Alt+arrow` combos are no longer focus aliases — `Alt+↑` / `Alt+↓` now cycle
between workspaces (see the sidebar table above).

### Swap (rearrange the tiling)

| Combo              | Action                                |
| ------------------ | ------------------------------------- |
| `Ctrl+Shift+H`     | Swap focused pane with the left one   |
| `Ctrl+Shift+L`     | Swap focused pane with the right one  |
| `Ctrl+Shift+K`     | Swap focused pane with the one above  |
| `Ctrl+Shift+J`     | Swap focused pane with the one below  |

### Resize (grow)

| Combo              | Action                       |
| ------------------ | ---------------------------- |
| `Alt+Shift+←`      | Grow the focused pane left   |
| `Alt+Shift+→`      | Grow the focused pane right  |
| `Alt+Shift+↑`      | Grow the focused pane up     |
| `Alt+Shift+↓`      | Grow the focused pane down   |

### Zoom

| Combo   | Action                                              |
| ------- | --------------------------------------------------- |
| `Alt+Z` | Zoom the focused pane to fill the workspace; toggle again to restore |

### Workspace splits

| Combo             | Action                                            |
| ----------------- | ------------------------------------------------- |
| `Ctrl+Shift+T` / `Cmd+Shift+T` | Split a terminal pane next to the focus |

Vertical / horizontal chat splits and terminal-vertical splits have **no
default keybind**. Use the pane header buttons: `C|` / `C-` for chat vertical /
horizontal and `T|` / `T-` for terminal vertical / horizontal. You can bind
these actions yourself — see the table of binding keys below.

### Terminal (inside a focused terminal pane)

| Combo                              | Action                          |
| ---------------------------------- | ------------------------------- |
| `Ctrl+Alt+T` / `Cmd+Alt+T`         | New terminal tab                |
| `Ctrl+Shift+R` / `Cmd+Shift+R`     | Rename the active terminal tab  |
| `Ctrl+Shift+PageUp`                | Previous terminal tab           |
| `Ctrl+Shift+PageDown`              | Next terminal tab               |
| `Ctrl+Alt+↑` / `Cmd+Alt+↑`         | Focus the terminal split above  |
| `Ctrl+Alt+↓` / `Cmd+Alt+↓`         | Focus the terminal split below  |
| `Ctrl+Alt+←` / `Cmd+Alt+←`         | Focus the terminal split left   |
| `Ctrl+Alt+→` / `Cmd+Alt+→`         | Focus the terminal split right   |
| `Ctrl+-` / `Ctrl+=`                | Per-terminal zoom out / in      |

### Chat transcript scrolling

| Combo       | Action                          |
| ----------- | ------------------------------- |
| `↑`         | Scroll up one line               |
| `↓`         | Scroll down one line             |
| `PageUp`    | Scroll up one page               |
| `PageDown`  | Scroll down one page             |

Transcript scrolling is **direct** — no inertia or velocity decay. When input
stops, the view stops. Do not expect a multi-frame glide.

## Prefix mode (tmux-style)

Prefix mode is **off by default**. When enabled, pressing the prefix chord
(`Ctrl+B` by default) arms Verde for one keypress: the next key resolves
against the prefix table below instead of reaching the focused pane. While
armed, a one-line status bar appears along the bottom (`PREFIX  esc cancel
Ctrl+B send prefix  w workspace nav  ? keybinds`); press `?` to open the full cheat sheet of
every second key — including your own `command` scripts — without dropping the
chord. `Esc` cancels,
an unbound key is swallowed, and pressing the prefix twice sends the literal
chord to the focused terminal (tmux `send-prefix`).

Every built-in command has a default seat in the prefix table, so turning it
on exposes the whole command surface without remapping anything:

```json
{ "keybinds": { "prefix": true } }
```

Change the prefix chord with a string (which also enables prefix mode), or use
the object form for full control:

```json
{
  "keybinds": {
    "prefix": {
      "enabled": true,
      "key": ["Ctrl+A", "Ctrl+B"],
      "defaults": true,
      "bindings": {
        "c": "new_thread",
        "g": { "command": "lazygit" },
        "Shift+3": { "action": "workspace.select.3" },
        "z": null
      }
    }
  }
}
```

- `key` — one accelerator or an array. Any of them arms the prefix.
- `defaults` — set to `false` to drop the built-in table and start empty.
- `bindings` — keyed by the second key's accelerator (`"x"`, `"Shift+X"`,
  `"Ctrl+Left"`, `"Comma"`). A string value is an action name; `null`
  removes a default; `{ "command": "..." }` runs a shell script through
  `sh -lc` with the current project as the working directory and the project
  path as `$1` (the same contract as custom `open.default` actions).

Direct shortcuts keep working alongside prefix mode. Modifier state is exact:
`Ctrl+B` then `x` is different from `Ctrl+B` then `Ctrl+X`, so release `Ctrl`
before the second key unless the binding uses it.

### Workspace menu

`prefix w` opens the herdr-style **NAVIGATE** workspace menu. The status bar
switches to `» NAVIGATE  esc back  Up Prev workspace  Down Next workspace  Tab Next pane …`.
Running any bound action closes the menu immediately; an unbound key leaves it
open so you can choose again. Press `Esc` to close it without running anything.

Defaults: `Up`/`Down` previous/next workspace, `Tab`/`Shift+Tab` next/previous
pane, `h j k l` focus, `c` new thread, `v` / `-` split the configured default
pane type, `Shift+V` / `Shift+-` split the other type, `x` close, `z` zoom,
`p` command palette, `1`–`0` select workspace, `?` cheat sheet.

The table is overridable exactly like `bindings`, under `"navigate"`:

```json
{ "keybinds": { "prefix": { "navigate": { "Up": null, "g": { "command": "lazygit" } } } } }
```

### Default prefix table

| After `Ctrl+B`                   | Action                                            |
| -------------------------------- | ------------------------------------------------- |
| `?`                              | `prefix.keybinds` (cheat sheet, stays armed)      |
| `w`                              | `prefix.navigate` (one-shot workspace menu)        |
| `p`                              | `command_palette`                                 |
| `t`                              | `new_thread`                                      |
| `r`                              | `refresh`                                         |
| `o` / `e`                        | `open` / `open_editor`                            |
| `Space`                          | `companion`                                       |
| `s` / `Shift+S`                  | `sidebar` / `sidebar_hidden`                      |
| `b`                              | `browser`                                         |
| `` ` ``                          | `terminal.toggle`                                 |
| `q`                              | `workspace.toggle_quick_pane`                     |
| `x` / `Shift+X`                  | `workspace.close` / `workspace.close_current`     |
| `z`                              | `workspace.toggle_maximize`                       |
| `i`                              | `workspace.focus_prompt`                          |
| `c` / `Shift+C`                  | `workspace.split_chat_vertical` / `_horizontal`   |
| `v` / `-`                        | Configured default pane, vertical / horizontal       |
| `Shift+V` / `Shift+-`            | Other pane type, vertical / horizontal                |
| `h` `j` `k` `l`, arrows          | `workspace.focus_*`                               |
| `Shift+H/J/K/L`                  | `workspace.move_*`                                |
| `Ctrl+H/J/K/L`, `Ctrl+arrows`    | `workspace.grow_*`                                |
| `n` / `Shift+N`                  | `workspace.pane_next` / `pane_previous`           |
| `[` / `]`                        | `workspace.previous` / `next`                     |
| `Shift+[` / `Shift+]`            | `workspace.active_previous` / `active_next`       |
| `1 … 9`, `0`                     | `workspace.pane_select.1 … 10`                    |
| `Shift+1 … Shift+0`              | `workspace.select.1 … 10`                         |
| `Ctrl+1 … Ctrl+0`                | `workspace.active_select.1 … 10`                  |
| `Shift+Up` / `Shift+Down`        | `chat_up` / `chat_down`                           |
| `PageUp` / `PageDown`            | `chat_page_up` / `chat_page_down`                 |
| `m` / `Shift+M`                  | `chat.model_picker` / `chat.run_config`           |
| `Ctrl+T` / `Shift+W`             | `terminal.new_tab` / `terminal.close`             |
| `,`                              | `terminal.rename_tab`                             |
| `Ctrl+PageUp` / `Ctrl+PageDown`  | `terminal.tab_previous` / `tab_next`              |
| `Alt+arrows`                     | `terminal.split_*`                                |
| `Alt+Shift+arrows`               | `terminal.focus_*`                                |

The default pane type is GUI chat. Change **Settings → Workspace → Prefix split pane**
or set `ui.workspace_split_default_pane` to `"terminal"` to invert the pair.

Terminal and chat actions only apply while a pane of that kind is focused,
exactly like their direct shortcuts.

### Prefix action names

Action names mirror the remapping keys below, joined with `.` for nested
groups: `refresh`, `open`, `open_editor`, `new_thread`, `command_palette`,
`companion`, `sidebar`, `sidebar_hidden`, `browser`, `chat_up`, `chat_down`,
`chat_page_up`, `chat_page_down`, `chat.model_picker`, `chat.run_config`,
`terminal.toggle`, `prefix.keybinds`, `prefix.navigate`, and `terminal.<key>`
for every terminal binding. The dynamic split names are `workspace.split_default_*`
and `workspace.split_alternate_*`, alongside every `workspace.<key>`. Positional actions take a
1-based ordinal: `workspace.select.N`, `workspace.pane_select.N`,
`workspace.active_select.N`.

## Remapping

Override any binding under `keybinds` in your `verde.json`. On Unix it is under
`$XDG_CONFIG_HOME/verde` or `~/.config/verde`; on Windows it is under
`%APPDATA%\Verde`. Use a string for one shortcut, or a string array for multiple
shortcuts on the same action:

```json
{
  "keybinds": {
    "new_thread": "CommandOrControl+T",
    "browser": "Ctrl+Shift+B",
    "companion": "Ctrl+Shift+Space",
    "workspace": {
      "close_current": "CommandOrControl+Shift+W",
      "focus_up": "Ctrl+K",
      "focus_down": "Ctrl+J",
      "focus_left": "Ctrl+H",
      "focus_right": "Ctrl+L",
      "pane_previous": "Ctrl+Shift+Tab",
      "pane_next": "Ctrl+Tab",
      "active_select": ["Ctrl+Shift+1", "Ctrl+Shift+2", "Ctrl+Shift+3", "Ctrl+Shift+4", "Ctrl+Shift+5", "Ctrl+Shift+6", "Ctrl+Shift+7", "Ctrl+Shift+8", "Ctrl+Shift+9", "Ctrl+Shift+0"],
      "pane_select": ["Ctrl+1", "Ctrl+2", "Ctrl+3", "Ctrl+4", "Ctrl+5", "Ctrl+6", "Ctrl+7", "Ctrl+8", "Ctrl+9", "Ctrl+0"],
      "previous": "Alt+Up",
      "next": "Alt+Down",
      "move_left": "Ctrl+Shift+H",
      "move_right": "Ctrl+Shift+L",
      "move_up": "Ctrl+Shift+K",
      "move_down": "Ctrl+Shift+J",
      "toggle_maximize": "Alt+Z",
      "close": ["CommandOrControl+W", "Alt+X"],
      "select": ["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0"]
    },
    "terminal": {
      "new_tab": "CommandOrControl+Alt+T",
      "close": "CommandOrControl+Shift+W",
      "rename_tab": "CommandOrControl+Shift+R",
      "tab_previous": "CommandOrControl+Shift+PageUp",
      "tab_next": "CommandOrControl+Shift+PageDown",
      "focus_up": "CommandOrControl+Alt+Up",
      "focus_down": "CommandOrControl+Alt+Down",
      "focus_left": "CommandOrControl+Alt+Left",
      "focus_right": "CommandOrControl+Alt+Right"
    }
  }
}
```

`workspace.pane_select` is positional: the first shortcut focuses the first pane
shown under the current workspace in the sidebar, the second shortcut focuses
the second pane, and so on.

`workspace.active_select` follows the sorted order currently shown in the
sidebar's global Active section, including rows from other workspaces.

## Disabling a binding

Set the binding to `null`, an empty string, or an empty array to disable it:

```json
{
  "keybinds": {
    "terminal": {
      "toggle": null,
      "split_up": null,
      "split_down": null,
      "split_left": null,
      "split_right": null
    }
  }
}
```

## Binding keys reference

The keybinds config uses the same accelerator grammar as the desktop defaults.
The top-level keys group actions by surface; the inner values are one shortcut
or an array of shortcuts.

| Group       | Keys (subset)                                                                                                                                                                                                                     |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| top         | `refresh`, `open_default`, `open_editor`, `new_thread`, `command_palette`, `companion`, `toggle_sidebar`, `toggle_sidebar_hidden`, `toggle_browser`, `toggle_terminal`                                                                       |
| chat        | `chat_up`, `chat_down`, `chat_page_up`, `chat_page_down`                                                                                                                                                                          |
| `workspace` | `split_chat_vertical`, `split_chat_horizontal`, `split_terminal_vertical`, `split_terminal_horizontal`, `toggle_maximize`, `close`, `close_current`, `focus_left`, `focus_right`, `focus_up`, `focus_down`, `focus_prompt`, `pane_previous`, `pane_next`, `active_select`, `pane_select`, `move_*`, `grow_*`, `select`, `previous`, `next` |
| `terminal`  | `new_tab`, `close`, `rename_tab`, `tab_previous`, `tab_next`, `split_up`, `split_down`, `split_left`, `split_right`, `focus_up`, `focus_down`, `focus_left`, `focus_right`                                                       |
| `prefix`    | `enabled`, `key`, `defaults`, `bindings`, `navigate` — see [Prefix mode](#prefix-mode-tmux-style)                                                                                                                                       |

Keybinds are loaded on startup and on app refresh. See [Configuration &
state](/docs/config) for the full `verde.json` schema and where state lives.
