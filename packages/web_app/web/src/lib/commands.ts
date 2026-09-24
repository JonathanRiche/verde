import { paneKey, type LivePane, type Workspace, type Thread, type RpcEnvelope } from './types'

type Target = 'none' | 'workspace' | 'pane' | 'chat'
const native = <Id extends string>(id: Id, title: string, target: Target, hint = '') => ({ id, title, target, hint })

/** One catalog drives both the palette and dispatch. */
export const COMMANDS = [
  native('thread.new', 'New chat', 'workspace'),
  native('thread.rename_current', 'Rename current chat', 'chat'),
  native('thread.choose_model', 'Choose chat model', 'chat'),
  native('thread.run_config', 'Configure reasoning and run settings', 'chat'),
  native('pane.terminal', 'Open terminal pane', 'workspace', 'Ctrl+Alt+T'),
  native('pane.close', 'Close pane', 'pane'),
  native('pane.zoom', 'Zoom / unzoom pane', 'pane', 'Alt+Z'),
  native('pane.previous', 'Previous pane', 'pane', 'Ctrl+Shift+Tab'),
  native('pane.next', 'Next pane', 'pane', 'Ctrl+Tab'),
  native('pane.focus_left', 'Focus pane left', 'pane', 'Ctrl+Left'),
  native('pane.focus_right', 'Focus pane right', 'pane', 'Ctrl+Right'),
  native('pane.focus_up', 'Focus pane up', 'pane', 'Ctrl+Up'),
  native('pane.focus_down', 'Focus pane down', 'pane', 'Ctrl+Down'),
  native('pane.focus_prompt', 'Focus chat prompt', 'chat'),
  native('workspace.add', 'Add workspace', 'none'),
  native('workspace.rename', 'Rename workspace', 'workspace'),
  native('workspace.close', 'Close workspace', 'workspace'),
  native('workspace.previous', 'Previous workspace', 'workspace', 'Alt+Up'),
  native('workspace.next', 'Next workspace', 'workspace', 'Alt+Down'),
  native('app.settings', 'Open settings', 'none', 'Ctrl+,'),
  native('app.sidebar', 'Toggle sidebar', 'none', 'Ctrl+S'),
  native('thread.handoff', 'Handoff chat to another agent', 'chat'),
  native('thread.open_tui', 'Open chat in its agent TUI', 'chat'),
  native('thread.regenerate_title', 'Regenerate chat title', 'chat'),
  native('workspace.open_codex_tui', 'Open Codex TUI', 'workspace'),
  native('workspace.open_editor', 'Open in editor', 'workspace'),
  native('pane.quick_toggle', 'New or toggle quick terminal', 'workspace'),
  native('pane.browser', 'Open in browser', 'none'),
  native('pane.split_chat_right', 'Split chat right', 'workspace'),
  native('pane.split_chat_down', 'Split chat down', 'workspace'),
  native('pane.split_terminal_right', 'Split terminal right', 'workspace'),
  native('pane.split_terminal_down', 'Split terminal down', 'workspace'),
] as const

export type NativeCommandId = typeof COMMANDS[number]['id']
export type CommandHandlers = Record<NativeCommandId, () => unknown | Promise<unknown>>
const ALIASES: Record<string, string> = {
  'new-thread': 'thread.new', 'new-terminal': 'pane.terminal',
  'toggle-sidebar': 'app.sidebar', settings: 'app.settings', maximize: 'pane.zoom',
  'workspace.focus_left': 'pane.focus_left', 'workspace.focus_right': 'pane.focus_right',
  'workspace.focus_up': 'pane.focus_up', 'workspace.focus_down': 'pane.focus_down',
  'workspace.focus_prompt': 'pane.focus_prompt',
}

export async function dispatchWebCommand(id: string, context: {
  workspace?: Workspace | null
  pane?: LivePane | null
  handlers: CommandHandlers
  accepted?: () => void
  notice: (message: string) => void
}): Promise<void> {
  const command = COMMANDS.find((row) => row.id === (ALIASES[id] ?? id))
  if (!command) { context.notice(`Command “${id}” is not available in the web client.`); return }
  const { workspace, pane } = context
  if (command.target !== 'none' && !workspace) { context.notice('Select a workspace first.'); return }
  if ((command.target === 'pane' || command.target === 'chat') && (!pane || pane.workspace_id !== workspace?.workspace_id)) {
    context.notice('Focus a pane in this workspace first.'); return
  }
  if (command.target === 'chat' && (pane?.kind !== 'chat' || !pane.thread_id)) {
    context.notice('Focus a chat first.'); return
  }
  try {
    context.accepted?.()
    await context.handlers[command.id]()
  } catch {
    context.notice(`Could not run “${command.title}”. Please try again.`)
  }
}

export type ChatPickerCommand = 'model' | 'run_config'
const pickers = new Map<string, (command: ChatPickerCommand) => void>()
export function registerChatCommandPickers(pane: LivePane, open: (command: ChatPickerCommand) => void) {
  const key = paneKey(pane.workspace_id, pane.pane_id)
  pickers.set(key, open)
  return () => { if (pickers.get(key) === open) pickers.delete(key) }
}
export function openChatCommandPicker(pane: LivePane, command: ChatPickerCommand): boolean {
  const open = pickers.get(paneKey(pane.workspace_id, pane.pane_id))
  if (!open) return false
  open(command)
  return true
}


export function sidebarActionUnavailableReason(action: string, pane?: LivePane): string | null {
  // provider.thread.sync runs on the runtime that owns the chat's provider
  // binding; a chat routed to another machine syncs there.
  if (action === 'thread-sync' && pane?.profile_id && pane.profile_id !== 'local') return 'This chat runs on another machine. Sync it from that machine’s Verde.'
  // Chats close through the daemon store (which also prunes the stored
  // layout), and daemon-backed terminals through session.kill. A stopped
  // terminal pane with no session has nothing left to close.
  if (action === 'pane-close' && pane?.native_pane_id != null && !paneClosableFromWeb(pane)) return 'This pane has no running session to close.'
  return null
}

function paneClosableFromWeb(pane: LivePane): boolean {
  if (pane.kind === 'terminal') return Boolean(pane.session_id)
  return pane.kind === 'chat' && Boolean(pane.thread_id)
}

/** Keep the menu and direct dispatch in agreement without a desktop transport. */
export function sidebarMenuAvailability<T extends { action: string; label: string; disabled?: boolean }>(item: T, pane?: LivePane): T {
  const reason = sidebarActionUnavailableReason(item.action, pane)
  return reason ? { ...item, disabled: true, label: `${item.label} — ${reason}` } : item
}

export async function requestSidebarThreadSync(
  call: (method: string, params: unknown) => Promise<RpcEnvelope>,
  workspaceId: string, thread: Thread, busy: boolean,
): Promise<RpcEnvelope> {
  if (busy) throw new Error('Wait for this chat to finish before syncing.')
  if (!workspaceId || !thread.local_thread_id || !thread.provider_thread_id) throw new Error('This chat has no saved provider thread to sync.')
  // The daemon sync handler requires a local binding; do not redirect a
  // remote thread to this host or guess a matching remote store record.
  if (thread.profile_id && thread.profile_id !== 'local') throw new Error('This chat runs on another machine. Sync it from that machine’s Verde.')
  return call('provider.thread.sync', {
    workspace_id: workspaceId, local_thread_id: thread.local_thread_id,
    provider_thread_id: thread.provider_thread_id,
  })
}
