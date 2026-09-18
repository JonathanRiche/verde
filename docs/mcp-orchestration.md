# MCP chat orchestration

Verde records delegated chats and per-turn tasks in the session daemon. The
parent pane's **Linked chats** drawer lists the latest status of each child.
Clearing a row hides that link; it does not cancel work, delete the conversation,
or turn off completion delivery. The panel sits above the composer, fits its
content up to three visible rows, and scrolls longer lists. The composer keeps
its full width. Small panes use an expandable overlay.
Drawer expansion is a GUI-session preference; links and hidden rows are durable.
Child threads use the same drawer to show **Parent chat** (or **Parent chats**)
above their children. Parent rows show the saved title and provider and open
the parent conversation. These reverse links survive clearing the parent's
child row. The collapsed drawer uses the same expand chevron for all chats.
The `chat.links.list` result includes a separate `parents` array.

## Native parents

Pass the parent's `local_thread_id` as `parent_thread_id` to `open_chat` or
`send_chat_message`. Native turns receive their workspace, thread, and turn IDs
in their execution context. Verde also recognizes structured Verde MCP tool
results in provider streams and attaches the returned child to the executing
parent. This fallback depends on the provider exposing tool-result content.

Completion, failure, cancellation, and approval-needed events enter a durable
outbox. A running parent receives a steering message when its provider supports
steering. Otherwise delivery stays queued until that turn finishes. An idle
parent gets a new turn using its saved provider/model/reasoning settings.
Explicitly stopping the parent disables automatic continuations for its links;
a new user turn or explicit delegation enables them again. Delivery uses stable
event IDs to reconcile retries. Pending events survive a daemon restart.

A child blocked on a decision or dependency can call `report_chat_blocked` with
its current `turn_id` and a precise `reason`, then yield. This produces an
immediate status event and a parent notification. The next follow-up is a new
turn. A reported blocker is distinct from a tool approval, which can be answered
with `approve_chat_turn` or the MCP Tasks input-response mechanism.

`list_linked_chats` and `clear_linked_chats` expose the same panel operations to
agents. Both require a workspace and parent thread ID. Clear accepts a specific
`link_id`; without one it hides finished rows.

## External MCP clients

Verde's Streamable HTTP endpoint supports the
[2026-07-28 Tasks extension](https://tasks.extensions.modelcontextprotocol.io/specification/2026-07-28/tasks).
On each request declare `io.modelcontextprotocol/tasks` in
`_meta["io.modelcontextprotocol/clientCapabilities"].extensions` and the protocol
version in `_meta["io.modelcontextprotocol/protocolVersion"]`.

1. `tools/call` for `send_chat_message` returns `resultType: "task"` and a durable
   `taskId` (the Verde turn ID).
2. `subscriptions/listen` with `notifications: {taskIds: [...]}` opens an SSE
   response. It acknowledges the selected IDs, immediately sends their current
   state, and sends `notifications/tasks` on changes. Reconnect using the same
   IDs; the initial snapshot includes a result that completed while disconnected.
3. `tasks/get` provides reconciliation. `tasks/update` answers pending approval
   input requests. `tasks/cancel` requests cancellation. These methods require
   `Mcp-Name` to equal `taskId`, plus the normal matching protocol/method headers.

Subscriptions are bounded to 64 task IDs per stream and 32 concurrent streams.
Daemon waits share the existing parking budget; heartbeats are transport-level,
not repeated model tool calls. Results are published after durable transcript
commit. A reported blocker maps to a working task with a status message until
the child yields; the finished tool result then has `isError: true`. Provider
failures likewise use a completed task with an error tool result, as required
by the extension. Approval waits use `input_required` with an elicitation request.

The external host must consume notifications and deliver them into its agent
loop; protocol notifications cannot independently wake an unsupported host.
Legacy clients keep ordinary tool responses and `tail_chat_turn`. Push streams
are implemented on Streamable HTTP; the legacy stdio transport retains reads.

## Verification

`VERDE_IT_SCENARIO=orchestration zig build headless-daemon-it --release=safe -Dbrowser-backend=native_webview`
exercises the real task tool adapter and daemon with an isolated database and
stub providers. It covers parent continuation, approval replies, blocked reports,
cancellation, restart recovery, clearing links, cycle rejection, live SSE delivery,
and reconnect snapshots. No live providers, user daemon, or GUI restart is involved.
