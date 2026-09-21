import { createEffect, createSignal, onCleanup } from 'solid-js'
import { paneKey, paneTitle, type LivePane, type Workspace } from './types'

export type AttentionStatus = 'working' | 'done' | 'waiting' | 'error' | 'idle'
export interface AttentionPane { key: string; status: AttentionStatus }
export interface AttentionState {
  previous: Map<string, AttentionStatus>
  attention: Set<string>
}

/** Seed existing panes silently; only observed work transitions create attention. */
export function advanceAttention(state: AttentionState, panes: AttentionPane[], focused: string | null) {
  const previous = new Map<string, AttentionStatus>()
  const attention = new Set(state.attention)
  const notifications: string[] = []
  for (const { key, status } of panes) {
    previous.set(key, status)
    if (key === focused || status === 'working' || status === 'idle') attention.delete(key)
    const before = state.previous.get(key)
    const needsAttention = (before === 'working' && ['done', 'waiting', 'error'].includes(status)) ||
      (before === 'waiting' && (status === 'done' || status === 'error'))
    if (needsAttention && key !== focused) {
      attention.add(key)
      notifications.push(key)
    }
  }
  for (const key of attention) if (!previous.has(key)) attention.delete(key)
  return { previous, attention, notifications }
}

export function notificationBody(status: AttentionStatus, workspace?: Pick<Workspace, 'label'>): string {
  return status === 'waiting' ? 'Needs approval' : status === 'error' ? 'Turn failed' : `Reply ready in ${workspace?.label || 'workspace'}`
}

interface Turn { workspace_id?: string; local_thread_id?: string; status?: string }
export function notificationStatus(pane: LivePane, turn?: Turn, approval = false): AttentionStatus {
  if (approval || pane.pending_approval || turn?.status === 'waiting_approval') return 'waiting'
  if (turn?.status === 'failed' || pane.attention_reasons?.includes('error')) return 'error'
  if (turn?.status === 'aborted') return 'idle'
  if (pane.send_pending || pane.working || ['working', 'running', 'accepted', 'waiting'].includes(turn?.status ?? '')) return 'working'
  return 'done'
}

const STORAGE_KEY = 'verde:web:notifications:enabled'
const permissionNow = () => typeof Notification === 'undefined' ? 'unsupported' as const : Notification.permission
const [permission, setPermission] = createSignal<NotificationPermission | 'unsupported'>(permissionNow())
const [enabled, updateEnabled] = createSignal((() => {
  try { return localStorage.getItem(STORAGE_KEY) !== 'false' } catch { return true }
})())
const [attentionCount, setAttentionCount] = createSignal(0)

/** Call requestPermission directly from a click/tap handler, never from an effect. */
export const notifications = {
  permission, enabled, attentionCount,
  setEnabled(value: boolean) {
    updateEnabled(value)
    try { localStorage.setItem(STORAGE_KEY, String(value)) } catch { /* Storage is optional. */ }
  },
  async requestPermission() {
    if (typeof Notification === 'undefined') return 'unsupported' as const
    try { setPermission(await Notification.requestPermission()) } catch { setPermission(permissionNow()) }
    return permission()
  },
}

export function watchNotifications(input: {
  panes: () => Record<string, LivePane[]>
  workspaces: () => Workspace[]
  focused: () => LivePane | null | undefined
  turns: () => Turn[]
  approval: (pane: LivePane) => unknown
  focus: (pane: LivePane) => void
}) {
  if (typeof window === 'undefined') return
  let state: AttentionState = { previous: new Map(), attention: new Set() }
  const [visible, setVisible] = createSignal(document.visibilityState !== 'hidden')
  const syncVisibility = () => { setVisible(document.visibilityState !== 'hidden'); setPermission(permissionNow()) }
  let pendingKey = new URL(location.href).searchParams.get('notification-pane')
  const receive = (event: MessageEvent) => {
    if (event.data?.type !== 'verde:notification-focus' || typeof event.data.key !== 'string') return
    pendingKey = event.data.key
    focusPending()
  }
  const focusPending = () => {
    const pane = Object.values(input.panes()).flat().find((pane) => paneKey(pane.workspace_id, pane.pane_id) === pendingKey)
    if (!pane) return
    pendingKey = null
    const url = new URL(location.href)
    url.searchParams.delete('notification-pane')
    history.replaceState(history.state, '', url)
    input.focus(pane)
  }
  const show = async (pane: LivePane, status: AttentionStatus) => {
    const key = paneKey(pane.workspace_id, pane.pane_id)
    const workspace = input.workspaces().find((row) => row.workspace_id === pane.workspace_id)
    const options: NotificationOptions = {
      body: notificationBody(status, workspace),
      tag: `verde:${key}`, data: { key }, icon: '/icons/icon-192.png',
    }
    try {
      const registration = await navigator.serviceWorker?.getRegistration()
      if (!enabled() || permissionNow() !== 'granted' || !state.attention.has(key)) return
      if (registration) {
        try { await registration.showNotification(paneTitle(pane), options); return } catch { /* Try the window API. */ }
      }
      const notification = new Notification(paneTitle(pane), options)
      notification.onclick = () => { window.focus(); input.focus(pane); notification.close() }
    } catch { /* Unsupported/blocked notifications must not interrupt chat. */ }
  }
  document.addEventListener('visibilitychange', syncVisibility)
  window.addEventListener('focus', syncVisibility)
  navigator.serviceWorker?.addEventListener('message', receive)
  createEffect(() => {
    const panes = Object.values(input.panes()).flat().filter((pane) => pane.kind === 'chat')
    const turns = input.turns()
    const rows = panes.map((pane) => ({
      key: paneKey(pane.workspace_id, pane.pane_id),
      status: notificationStatus(pane, turns.filter((turn) => turn.workspace_id === pane.workspace_id && turn.local_thread_id === pane.thread_id).at(-1), Boolean(input.approval(pane))),
    }))
    const focused = input.focused()
    const next = advanceAttention(state, rows, visible() && focused ? paneKey(focused.workspace_id, focused.pane_id) : null)
    state = next
    setAttentionCount(state.attention.size)
    if (enabled() && permission() === 'granted') {
      for (const key of next.notifications) {
        const index = rows.findIndex((row) => row.key === key)
        void show(panes[index]!, rows[index]!.status)
      }
    }
    focusPending()
  })
  createEffect(() => {
    const count = enabled() ? attentionCount() : 0
    const badge = navigator as Navigator & { setAppBadge?: (count: number) => Promise<void>; clearAppBadge?: () => Promise<void> }
    try { void (count ? badge.setAppBadge?.(count) : badge.clearAppBadge?.())?.catch(() => {}) } catch { /* Optional platform API. */ }
  })
  onCleanup(() => {
    document.removeEventListener('visibilitychange', syncVisibility)
    window.removeEventListener('focus', syncVisibility)
    navigator.serviceWorker?.removeEventListener('message', receive)
  })
}
