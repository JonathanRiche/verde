import { For, Show, createEffect, createSignal, onMount } from 'solid-js'

import { workspaceSelectIntent } from '../lib/selection'
import { ChatCwdPicker } from './ChatCwdPicker'
import { store } from '../lib/store'
import type { LivePane } from '../lib/types'

/** Per-chat routing in both the full-size and mobile action menus. */
export function ChatRouting(props: { pane: LivePane; onClose: () => void }) {
  const [saving, setSaving] = createSignal(false)
  let workspaceSelect: HTMLSelectElement | undefined
  let connectionSelect: HTMLSelectElement | undefined
  let pickingWorkspace = false
  let pickingConnection = false
  onMount(() => { void store.refreshConnections() })
  const owningWorkspaceId = () => store.owningWorkspaceId(props.pane)
  const profile = () => store.connectionFor(props.pane)
  const defaultLabel = () => {
    const id = store.connections()?.defaults.find((entry) => entry.workspace_id === owningWorkspaceId())?.profile_id
    return !id || id === 'local' ? 'Local' : store.connections()?.connections.find((row) => row.profile_id === id)?.label ?? 'Unavailable'
  }
  const locked = () => store.paneWorking(props.pane) || props.pane.committed || Boolean(props.pane.provider_thread_id)
  const selectClass = 'h-10 w-full min-w-0 rounded-[7px] border border-[var(--border-muted)] bg-[var(--panel)] px-2 text-[13px] text-[var(--text)] outline-none focus-visible:border-[var(--accent)] disabled:opacity-50'
  const connectionValue = () => store.inheritsConnection(props.pane) ? '' : profile()
  const applyWorkspaceSelect = () => {
    const id = owningWorkspaceId()
    if (pickingWorkspace || !workspaceSelect || workspaceSelect.value === id) return
    workspaceSelect.value = id
  }
  const applyConnectionSelect = () => {
    const next = connectionValue()
    if (pickingConnection || !connectionSelect || connectionSelect.value === next) return
    connectionSelect.value = next
  }
  createEffect(() => {
    owningWorkspaceId()
    applyWorkspaceSelect()
  })
  createEffect(() => {
    connectionValue()
    applyConnectionSelect()
  })
  return (
    <div class="mb-2 space-y-3 border-b border-[var(--border-muted)] px-2 pb-3 pt-1" role="group" aria-label="Chat routing">
      <label class="block">
        <span class="mb-1 block text-[11px] font-medium text-[var(--text-subtle)]">Workspace</span>
        <select
          ref={(node) => { workspaceSelect = node; if (node) node.value = owningWorkspaceId() }}
          aria-label="Chat workspace"
          class={selectClass}
          disabled={saving() || store.paneWorking(props.pane)}
          onPointerDown={() => { pickingWorkspace = true }}
          onFocus={() => { pickingWorkspace = true }}
          onBlur={() => {
            pickingWorkspace = false
            applyWorkspaceSelect()
          }}
          onChange={async (event) => {
            const id = event.currentTarget.value
            const intent = workspaceSelectIntent(owningWorkspaceId(), id)
            if (!pickingWorkspace || intent.kind === 'keep') {
              event.currentTarget.value = owningWorkspaceId()
              pickingWorkspace = false
              return
            }
            pickingWorkspace = false
            setSaving(true)
            try {
              await store.newThread(intent.workspace_id)
              props.onClose()
            } finally {
              setSaving(false)
            }
          }}
        >
          <For each={store.workspaces().filter((workspace) => !workspace.archived)}>
            {(workspace) => (
              <option value={workspace.workspace_id}>
                {workspace.label}
              </option>
            )}
          </For>
        </select>
        <span class="mt-1 block text-[11px] leading-4 text-[var(--text-subtle)]">Changing workspace opens a new chat with its defaults.</span>
      </label>
      <label class="block">
        <span class="mb-1 block text-[11px] font-medium text-[var(--text-subtle)]">Connection</span>
        <select
          ref={(node) => { connectionSelect = node; if (node) node.value = connectionValue() }}
          aria-label="Chat connection"
          class={selectClass}
          disabled={saving() || locked() || !store.connections()}
          onPointerDown={() => { pickingConnection = true }}
          onFocus={() => { pickingConnection = true }}
          onBlur={() => {
            pickingConnection = false
            applyConnectionSelect()
          }}
          onChange={async (event) => {
            const value = event.currentTarget.value
            pickingConnection = false
            setSaving(true)
            try { await store.setChatConnection(props.pane, value || null) }
            finally { setSaving(false) }
          }}
        >
          <option value="">Workspace default ({defaultLabel()})</option>
          <option value="local">Local</option>
          <Show when={!store.inheritsConnection(props.pane) && profile() !== 'local' && !store.connections()?.connections.some((row) => row.profile_id === profile())}>
            <option value={profile()}>Saved connection unavailable</option>
          </Show>
          <For each={store.connections()?.connections ?? []}>
            {(connection) => <option value={connection.profile_id}>{connection.label}{connection.ready ? '' : ` · ${connection.failure ?? connection.phase}`}</option>}
          </For>
        </select>
        <span class="mt-1 block text-[11px] leading-4 text-[var(--text-subtle)]">
          {locked() ? 'This conversation keeps its original connection.' : 'New chats inherit the workspace’s default connection.'}
        </span>
      </label>
      <ChatCwdPicker pane={props.pane} />
      <Show when={store.connectionError()}>
        <p role="status" class="text-[12px] leading-4 text-[var(--accent)]">{store.connectionError()}</p>
      </Show>
    </div>
  )
}
