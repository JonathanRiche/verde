import { For, Show, type JSX } from 'solid-js'

import { store } from '../lib/store'
import { paneIsActive, type LivePane, type Workspace } from '../lib/types'
import { Icon, ProviderGlyph, StatusPip, VerdeLogo } from './Icons'

export function Sidebar() {
  return (
    <aside class="flex h-full min-h-0 flex-col bg-[var(--panel)] text-[13px]">
      <div class="shrink-0 px-4 pt-3.5 pb-2">
        <div class="flex h-8 items-center">
          <VerdeLogo class="h-7 w-7" />
          <Show when={!store.sidebarCollapsed()}>
            <div class="ml-auto flex items-center gap-1">
              <IconButton label="Add workspace" onClick={() => { store.setNotice(null); store.setWorkspaceDialogOpen(true) }}>
                <Icon name="plus" class="h-3.5 w-3.5" />
              </IconButton>
              <IconButton label="Collapse sidebar" onClick={() => store.setSidebarCollapsed(true)}>
                <Icon name="collapse" class="h-3.5 w-3.5" />
              </IconButton>
            </div>
          </Show>
          <Show when={store.sidebarCollapsed()}>
            <div class="ml-auto">
              <IconButton label="Expand sidebar" onClick={() => store.setSidebarCollapsed(false)}>
                <Icon name="expand" class="h-3.5 w-3.5" />
              </IconButton>
            </div>
          </Show>
        </div>
        <Show when={!store.sidebarCollapsed()}>
          <button
            type="button"
            class="mt-2.5 flex h-[30px] w-full items-center rounded-[6px] px-2 text-[12.5px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white"
            onClick={() => store.setPaletteOpen(true)}
          >
            <Icon name="search" class="h-3.5 w-3.5" />
            <span class="ml-2">Search</span>
            <span class="mono ml-auto text-[10px] text-[var(--text-subtle)]">Ctrl+Shift+P</span>
          </button>
        </Show>
      </div>

      <Show when={!store.sidebarCollapsed()} fallback={<CollapsedRail />}>
        <div class="min-h-0 flex-1 overflow-y-auto px-4 scrollbar-thin">
          <Show when={store.activePanes().length > 0}>
            <div class="mb-1 text-[11px] tracking-wide text-[var(--text-subtle)]">ACTIVE</div>
            <For each={store.activePanes()}>
              {(pane) => (
                <PaneRow pane={pane} activeCluster onClick={() => store.focusPane(pane)} />
              )}
            </For>
            <div class="my-3 h-px bg-[var(--border-muted)]" />
          </Show>

          <For each={store.workspaces()}>
            {(workspace) => <WorkspaceGroup workspace={workspace} />}
          </For>
        </div>
      </Show>

      <div class="flex h-14 shrink-0 items-center justify-end border-t border-[var(--border-muted)] px-4">
        <div class="mr-auto truncate text-[11px] text-[var(--text-subtle)]">
          {store.connected() ? store.source() : 'reconnecting'}
        </div>
        <IconButton label="Settings" onClick={() => store.setSettingsOpen(true)}>
          <Icon name="settings" class="h-4 w-4" />
        </IconButton>
      </div>
    </aside>
  )
}

function WorkspaceGroup(props: { workspace: Workspace }) {
  const selected = () => store.workspace()?.workspace_id === props.workspace.workspace_id
  return (
    <section class="relative mb-2">
      <Show when={selected()}>
        <span class="absolute top-1 bottom-1 -left-3 w-[3px] rounded-full bg-[var(--accent)]" />
      </Show>
      <div class="group flex h-[30px] w-full items-center rounded-[6px] pr-1 hover:bg-[var(--accent-hover)]">
        <button
          type="button"
          class="flex h-full min-w-0 flex-1 items-center text-left"
          onClick={() => store.selectWorkspace(props.workspace.workspace_id)}
        >
          <Icon
            name={selected() ? 'chevronDown' : 'chevron'}
            class={`h-3.5 w-3.5 ${selected() ? 'text-white' : 'text-[var(--text-subtle)]'}`}
          />
          <Icon
            name="folder"
            class={`ml-1 h-3.5 w-3.5 ${selected() ? 'text-[var(--accent)]' : 'text-[var(--text-subtle)]'}`}
          />
          <span class={`ml-2 min-w-0 flex-1 truncate text-[15px] ${selected() ? 'text-white' : 'text-[var(--text-muted)]'}`}>
            {props.workspace.label}
          </span>
        </button>
        <span class="hidden items-center gap-0.5 group-hover:flex">
          <TinyIcon label="New chat" onClick={(event) => { event.stopPropagation(); void store.runCommand('new-thread', props.workspace.workspace_id) }}>
            <Icon name="chat" class="h-3.5 w-3.5" />
          </TinyIcon>
          <TinyIcon label="New terminal" onClick={(event) => { event.stopPropagation(); void store.runCommand('new-terminal') }}>
            <Icon name="terminal" class="h-3.5 w-3.5" />
          </TinyIcon>
          <TinyIcon label="History" onClick={(event) => { event.stopPropagation(); store.setPaletteOpen(true) }}>
            <Icon name="history" class="h-3.5 w-3.5" />
          </TinyIcon>
        </span>
      </div>
      <Show when={selected()}>
        <div class="mt-1 ml-4">
          <For each={selected() ? store.openPanes() : []}>
            {(pane) => (
              <PaneRow pane={pane} onClick={() => store.focusPane(pane)} />
            )}
          </For>
        </div>
      </Show>
    </section>
  )
}

function PaneRow(props: { pane: LivePane; activeCluster?: boolean; onClick: () => void }) {
  const focused = () => store.focusedPaneId() === props.pane.pane_id && store.workspaceId() === props.pane.workspace_id
  const working = () => paneIsActive(props.pane)
  return (
    <button
      type="button"
      class={`mb-[4px] flex h-[38px] w-full items-center gap-2.5 rounded-[7px] px-2.5 text-left ${focused() ? 'bg-[var(--accent-row)]' : 'hover:bg-[var(--accent-hover)]'}`}
      onClick={props.onClick}
    >
      {/* Terminal panes hosting a TUI agent carry its provider, mirroring the
          desktop's agent-terminal glyph; plain shells keep the terminal icon. */}
      <Show
        when={props.pane.kind === 'chat' || (props.pane.kind === 'terminal' && props.pane.provider)}
        fallback={<Icon name="terminal" class="h-[18px] w-[18px] text-[var(--text-muted)]" />}
      >
        <ProviderGlyph provider={props.pane.provider} />
      </Show>
      <span class="min-w-0 flex-1 truncate text-[13px] text-[var(--text-muted)]">{store.paneTitle(props.pane)}</span>
      <Show when={working()}>
        <StatusPip active />
      </Show>
    </button>
  )
}

function CollapsedRail() {
  return (
    <div class="flex min-h-0 flex-1 flex-col items-center gap-2 overflow-y-auto pt-1 scrollbar-thin">
      <For each={store.workspaces()}>
        {(workspace) => {
          const selected = () => store.workspace()?.workspace_id === workspace.workspace_id
          return (
            <button
              type="button"
              class={`relative grid h-9 w-9 place-items-center rounded-[6px] ${selected() ? 'bg-[var(--accent-row)]' : 'hover:bg-[var(--accent-hover)]'}`}
              title={workspace.label}
              onClick={() => store.selectWorkspace(workspace.workspace_id)}
            >
              <Show when={selected()}>
                <span class="absolute top-1 bottom-1 left-0 w-[3px] rounded-full bg-[var(--accent)]" />
              </Show>
              <span class="text-[11px] font-bold text-[var(--text-muted)]">{workspace.label.slice(0, 1).toUpperCase()}</span>
            </button>
          )
        }}
      </For>
    </div>
  )
}

function IconButton(props: { label: string; onClick: () => void; children: JSX.Element }) {
  return (
    <button
      type="button"
      class="grid h-7 w-7 place-items-center rounded-[6px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white"
      aria-label={props.label}
      onClick={props.onClick}
    >
      {props.children}
    </button>
  )
}

function TinyIcon(props: { label: string; onClick: (event: MouseEvent) => void; children: JSX.Element }) {
  return (
    <button
      type="button"
      class="grid h-[30px] w-[30px] place-items-center text-[var(--text-subtle)] hover:text-white"
      aria-label={props.label}
      onClick={props.onClick}
    >
      {props.children}
    </button>
  )
}
