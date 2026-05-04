# Render Order And Per-Frame Work

- Browser:
  - `pollBrowser()` is called every tick.
  - It does not early-return when browser is hidden.
  - It checks launch delay and drains `browser_state.controller.pollEvent()`.
  - Probably cheap if no backend exists, but it should still be guarded better.

- Terminal:
  - `pollTerminals()` is called every tick.
  - It loops over all projects and archived projects every tick.
  - It calls `project.terminal_dock.poll(...)` for each one.
  - This should skip unless a terminal is visible or has a running session.

- DB/storage:
  - Not every frame unconditionally.
  - `flushIfDirty()` is called every rendered frame.
  - It early-returns unless `dirty == true`.
  - When dirty and debounce passes, it serializes/saves state on the UI thread.
  - `pollSend()` also calls `flushDirtyNow()` immediately on completed/failed/aborted provider sends.

- Send polling:
  - `pollSend()` is called every tick.
  - It loops every project and every thread.
  - For every thread it checks provider-thread capture, Codex steer, stop requests, and send-state status.
  - This is likely a major UI slowdown with lots of threads.

- Other likely offenders:
  - Sidebar sorting and committed counts every render.
  - Synchronous `flushDirtyNow()` / `flushIfDirty()` saves on the UI thread.
  - Full root render after every event, including dropdown interaction events.
