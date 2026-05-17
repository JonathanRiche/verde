# Verde UI Fixes

This worktree is for UI fixes and interaction polish in Verde.

## Chat Thread Context Menu

Add a right-click context menu for chat threads with the following options:

- `Copy`
  - Show only when text is highlighted or selected.
  - Show only when the current selection can actually be copied.

- `Paste`
  - Show only when the context target is an input.
  - Show only when the clipboard has content available.

- `New Chat Thread`
  - Same behavior as `Ctrl+T`.

- `Refresh Chat Thread`
  - Same behavior as sync or refresh for the current chat thread.

- `Split Pane`
  - Add as a submenu.
  - Include all split options for chat threads and terminal panes.
  - Include directional split options for each supported direction.

## Browser Navigation And Inspector Prompt

For the browser pane:

- Add UI buttons for browser back and forward navigation.
- Support mouse back and forward buttons for browser navigation.
- Fix the inspector prompt box so text can be selected.
- Fix the inspector prompt box so copy and paste work correctly.
- Update the inspector prompt box styling so it matches the chat thread prompt box.

## Sidebar Context Actions

For the sidebar:

- On pencil icons, add a right-click action to open a terminal pane.
  - This should use the same behavior as `Shift+Ctrl+T 1`.

- On any chat thread in the existing right-click context menu, add an `Open in TUI` option.
  - Include an option for each provider.
  - For Codex, this should open a terminal pane and run the appropriate resume command, such as `codex resume <id>`.

## Browser Plus Icon

For the plus icon beside the browser button:

- Update the dot indicator to use a pane/grid icon.

## Prompt Box Image Paste And Steering

Fix prompt box behavior when an image is pasted:

- `Tab` to steer is currently broken after an image is pasted.
- Submitting the steer should work even when pasted images are present.
- The `X` button on pasted images is difficult to click.
  - Review and improve the hitbox.
  - Make the removal affordance feel reliable.

## Chat Thread Completion Rendering

Fix GUI chat thread completion rendering:

- When a GUI chat thread finishes, the final frame does not always visually update.
- The user currently has to type or move the mouse cursor before the final markdown block renders.
- The yellow waiting or abort button can remain visible after completion.
- The button should reliably return to the normal green submit state as soon as the thread is done.
- The current behavior is hard to understand because completion state and rendered content can appear stale.

## Sidebar Running Thread State

Improve how running chat threads are shown in the sidebar:

- While a thread is running, temporarily replace that thread title with `Working...`.
- Make the `Working...` state flash subtly in a different color.
- When the thread finishes, restore the original thread title.
- Handle multiple threads running in parallel so users can see each active thread independently.

## Prompt Box Typing Performance

Improve prompt box typing performance:

- Typing in the prompt box feels slow on this machine.
- The more text is entered, the laggier the textarea becomes.
- Investigate and reduce per-keystroke work so typing remains responsive for long prompts.
