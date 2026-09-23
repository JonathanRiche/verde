import { paneKey, type LivePane, type Workspace, type Thread, type RpcEnvelope } from './types'

type Target = 'none' | 'workspace' | 'pane' | 'chat'
const native = <Id extends string>(id: Id, title: string, target: Target, hint = '') => ({ id, title, target, hint, desktop: false as const, available: true as const, unavailableReason: '' })
const desktop = <Id extends string>(id: Id, title: string) => ({ id, title: `${title} (desktop)`, target: 'pane' as const, hint: '', desktop: true as const, available: false as const, unavailableReason: 'This command is unavailable in the web client. Use the desktop app; the daemon has no supported operation for it.' })

/** One catalog drives both the palette and dispatch; unavailable commands never reach a transport. */
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
  desktop('pane.browser', 'Toggle browser pane'),
  desktop('pane.quick_toggle', 'New or toggle quick terminal'),
  desktop('pane.split_chat_right', 'Split chat right'),
  desktop('pane.split_chat_down', 'Split chat down'),
  desktop('pane.split_terminal_right', 'Split terminal right'),
  desktop('pane.split_terminal_down', 'Split terminal down'),
] as const

export type NativeCommandId = Extract<typeof COMMANDS[number], { desktop: false }>['id']
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
  if (!command.available) { context.notice(command.unavailableReason); return }
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


export const DESKTOP_ACTION_REASON = 'Available in the desktop app'
const DESKTOP_SIDEBAR_ACTIONS = new Set([
  'workspace-open-codex-tui', 'workspace-herdr-handoff',
  'workspace-herdr-focus-terminal', 'workspace-herdr-unlink',
  'workspace-import-codex', 'workspace-import-opencode', 'workspace-import-claude',
  'thread-regenerate-title', 'thread-handoff', 'thread-open-tui', 'thread-open-chat',
  'pane-split-chat-right', 'pane-split-chat-down',
  'pane-split-terminal-right', 'pane-split-terminal-down',
])

export function sidebarActionUnavailableReason(action: string, pane?: LivePane): string | null {
  if (DESKTOP_SIDEBAR_ACTIONS.has(action)) return DESKTOP_ACTION_REASON
  if (action === 'thread-sync' && pane?.profile_id && pane.profile_id !== 'local') return DESKTOP_ACTION_REASON
  if (action === 'pane-close' && pane?.native_pane_id != null && !(pane.kind === 'terminal' && pane.session_id)) return DESKTOP_ACTION_REASON
  return null
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
  if (thread.profile_id && thread.profile_id !== 'local') throw new Error('Syncing a remote chat is available in the desktop app.')
  return call('provider.thread.sync', {
    workspace_id: workspaceId, local_thread_id: thread.local_thread_id,
    provider_thread_id: thread.provider_thread_id,
  })
}
