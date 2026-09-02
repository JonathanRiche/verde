import { For, Show, createEffect, createSignal, onCleanup, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'

import { store, type SidebarContextAction } from '../lib/store'
import { paneIsActive, type LayoutNode, type LivePane, type Workspace } from '../lib/types'
import { Icon, ProviderGlyph, StatusPip, VerdeLogo } from './Icons'

type SidebarMenuTarget =
  | { kind: 'workspace'; workspace: Workspace; x: number; y: number }
  | { kind: 'thread'; workspace: Workspace; pane: LivePane; x: number; y: number }
  | { kind: 'terminal'; workspace: Workspace; pane: LivePane; x: number; y: number }

interface MenuItem {
  action: SidebarContextAction
  label: string
  disabled?: boolean
  danger?: boolean
}

interface PromptState {
  action: 'workspace-rename' | 'thread-rename'
  workspace: Workspace
  pane?: LivePane
  title: string
  label: string
  initial: string
  placeholder?: string
}

export function Sidebar() {
  const [menu, setMenu] = createSignal<SidebarMenuTarget | null>(null)
  const [prompt, setPrompt] = createSignal<PromptState | null>(null)

  const openWorkspaceMenu = (workspace: Workspace, x: number, y: number) => {
    setMenu({ kind: 'workspace', workspace, x, y })
  }
  const openPaneMenu = (pane: LivePane, x: number, y: number) => {
    if (pane.kind !== 'chat' && pane.kind !== 'terminal') return
    const workspace = store.workspaces().find((item) => item.workspace_id === pane.workspace_id)
    if (workspace) setMenu({ kind: pane.kind === 'chat' ? 'thread' : 'terminal', workspace, pane, x, y })
  }
  const chooseMenuItem = (target: SidebarMenuTarget, item: MenuItem) => {
    setMenu(null)
    if (item.action === 'workspace-rename') {
      setPrompt({
        action: item.action,
        workspace: target.workspace,
        title: 'Rename workspace',
        label: 'Workspace name',
        initial: target.workspace.label,
      })
      return
    }
    if (item.action === 'thread-rename' && target.kind === 'thread') {
      setPrompt({
        action: item.action,
        workspace: target.workspace,
        pane: target.pane,
        title: 'Rename chat',
        label: 'Chat title',
        initial: store.paneTitle(target.pane),
      })
      return
    }
    void store.runSidebarContextAction({
      action: item.action,
      workspace: target.workspace,
      ...(target.kind !== 'workspace' ? { pane: target.pane } : {}),
    })
  }

  return (
    <>
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

        <Show
          when={!store.sidebarCollapsed()}
          fallback={<CollapsedRail onOpenContext={openWorkspaceMenu} />}
        >
          <div
            class="min-h-0 flex-1 overflow-y-auto px-4 scrollbar-thin"
            onScroll={() => setMenu(null)}
          >
            <Show when={store.activePanes().length > 0}>
              <div class="mb-1 text-[11px] tracking-wide text-[var(--text-subtle)]">ACTIVE</div>
              <For each={store.activePanes()}>
                {(pane) => (
                  <PaneRow
                    pane={pane}
                    activeCluster
                    onClick={() => store.focusPane(pane)}
                    onOpenContext={(x, y) => openPaneMenu(pane, x, y)}
                  />
                )}
              </For>
              <div class="my-3 h-px bg-[var(--border-muted)]" />
            </Show>

            <For each={store.workspaces()}>
              {(workspace) => (
                <WorkspaceGroup
                  workspace={workspace}
                  onOpenContext={(x, y) => openWorkspaceMenu(workspace, x, y)}
                  onOpenPaneContext={openPaneMenu}
                />
              )}
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

      <Show when={menu()} keyed>
        {(target) => (
          <SidebarContextMenu
            target={target}
            onClose={() => setMenu(null)}
            onChoose={(item) => chooseMenuItem(target, item)}
          />
        )}
      </Show>
      <Show when={prompt()} keyed>
        {(state) => (
          <SidebarPrompt
            state={state}
            onClose={() => setPrompt(null)}
            onSubmit={(value) => {
              setPrompt(null)
              void store.runSidebarContextAction({
                action: state.action,
                workspace: state.workspace,
                pane: state.pane,
                value,
              })
            }}
          />
        )}
      </Show>
    </>
  )
}

export function PaneActionsButton(props: { pane: LivePane; mobile?: boolean }) {
  const [menu, setMenu] = createSignal<SidebarMenuTarget | null>(null)
  const [prompt, setPrompt] = createSignal<PromptState | null>(null)
  let trigger!: HTMLButtonElement

  const restoreTriggerFocus = () => queueMicrotask(() => trigger?.focus())
  const closeMenu = () => {
    setMenu(null)
    restoreTriggerFocus()
  }
  const openMenu = (event: MouseEvent) => {
    event.stopPropagation()
    const workspace = store.workspaces().find(
      (item) => item.workspace_id === props.pane.workspace_id,
    )
    if (!workspace) return
    const rect = event.currentTarget instanceof HTMLElement
      ? event.currentTarget.getBoundingClientRect()
      : trigger.getBoundingClientRect()
    setMenu({
      kind: props.pane.kind === 'terminal' ? 'terminal' : 'thread',
      workspace,
      pane: props.pane,
      x: rect.right - 268,
      y: rect.bottom + 6,
    })
  }
  const chooseMenuItem = (target: SidebarMenuTarget, item: MenuItem) => {
    setMenu(null)
    if (item.action === 'thread-rename' && target.kind === 'thread') {
      setPrompt({
        action: item.action,
        workspace: target.workspace,
        pane: target.pane,
        title: 'Rename chat',
        label: 'Chat title',
        initial: store.paneTitle(target.pane),
      })
      return
    }
    void store.runSidebarContextAction({
      action: item.action,
      workspace: target.workspace,
      pane: target.kind !== 'workspace' ? target.pane : undefined,
    })
  }

  return (
    <>
      <button
        ref={trigger}
        type="button"
        class={props.mobile
          ? 'grid h-10 w-10 shrink-0 place-items-center rounded-[8px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)] active:bg-[var(--accent-row)]'
          : 'grid h-7 w-7 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--panel-alt)] hover:text-[var(--text)] active:bg-[var(--accent-hover)]'}
        title={props.pane.kind === 'terminal' ? 'Terminal actions' : 'Chat actions'}
        aria-label={`Actions for ${store.paneTitle(props.pane)}`}
        aria-haspopup="menu"
        aria-expanded={menu() != null}
        onMouseDown={(event) => event.stopPropagation()}
        onClick={openMenu}
      >
        <Icon name="more" class={props.mobile ? 'h-[19px] w-[19px]' : 'h-4 w-4'} />
      </button>

      <Show when={menu()} keyed>
        {(target) => (
          <SidebarContextMenu
            target={target}
            placement="trigger"
            onClose={closeMenu}
            onChoose={(item) => chooseMenuItem(target, item)}
          />
        )}
      </Show>
      <Show when={prompt()} keyed>
        {(state) => (
          <SidebarPrompt
            state={state}
            onClose={() => {
              setPrompt(null)
              restoreTriggerFocus()
            }}
            onSubmit={(value) => {
              setPrompt(null)
              void store.runSidebarContextAction({
                action: state.action,
                workspace: state.workspace,
                pane: state.pane,
                value,
              })
            }}
          />
        )}
      </Show>
    </>
  )
}

function WorkspaceGroup(props: {
  workspace: Workspace
  onOpenContext: (x: number, y: number) => void
  onOpenPaneContext: (pane: LivePane, x: number, y: number) => void
}) {
  const selected = () => store.workspace()?.workspace_id === props.workspace.workspace_id
  const context = createContextTrigger(props.onOpenContext)
  return (
    <section class="relative mb-2">
      <Show when={selected()}>
        <span class="absolute top-1 bottom-1 -left-3 w-[3px] rounded-full bg-[var(--accent)]" />
      </Show>
      <div
        class="group flex h-[30px] w-full touch-pan-y select-none items-center rounded-[6px] pr-1 hover:bg-[var(--accent-hover)]"
        style={{ '-webkit-touch-callout': 'none' }}
        onContextMenu={context.onContextMenu}
        onPointerDown={context.onPointerDown}
        onPointerMove={context.onPointerMove}
        onPointerUp={context.onPointerUp}
        onPointerCancel={context.onPointerCancel}
      >
        <button
          type="button"
          class="flex h-full min-w-0 flex-1 items-center text-left"
          onClick={(event) => {
            if (context.consumeClick(event)) return
            store.selectWorkspace(props.workspace.workspace_id)
          }}
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
          <TinyIcon label="New terminal" onClick={(event) => { event.stopPropagation(); void store.runCommand('new-terminal', props.workspace.workspace_id) }}>
            <Icon name="terminal" class="h-3.5 w-3.5" />
          </TinyIcon>
          <TinyIcon label="History" onClick={(event) => { event.stopPropagation(); store.setPaletteOpen(true) }}>
            <Icon name="history" class="h-3.5 w-3.5" />
          </TinyIcon>
        </span>
      </div>
      <Show when={selected()}>
        <div class="mt-1 ml-4">
          <For each={selected() ? store.paneGroups() : []}>
            {(group) => (
              <Show
                when={group.panes.length > 1}
                fallback={<PaneRow
                  pane={group.panes[0]!}
                  onClick={() => store.focusPane(group.panes[0]!)}
                  onOpenContext={(x, y) => props.onOpenPaneContext(group.panes[0]!, x, y)}
                />}
              >
                <div
                  class="mb-1 flex min-h-0 min-w-0 overflow-hidden"
                  style={{ height: `${sidebarGroupRows(group.layout) * 38 + (sidebarGroupRows(group.layout) - 1) * 4}px` }}
                >
                  <SidebarGroupNode
                    node={group.layout}
                    panes={group.panes}
                    onOpenPaneContext={props.onOpenPaneContext}
                  />
                </div>
              </Show>
            )}
          </For>
        </div>
      </Show>
    </section>
  )
}

function sidebarGroupRows(node: LayoutNode): number {
  if ('leaf' in node) return 1
  const first = sidebarGroupRows(node.split.first)
  const second = sidebarGroupRows(node.split.second)
  return node.split.axis === 'horizontal' ? first + second : Math.max(first, second)
}

function SidebarGroupNode(props: {
  node: LayoutNode
  panes: LivePane[]
  onOpenPaneContext: (pane: LivePane, x: number, y: number) => void
}) {
  if ('leaf' in props.node) {
    const leaf_id = props.node.leaf
    const pane = props.panes.find((item) => item.pane_id === leaf_id)
    return (
      <Show when={pane} keyed>
        {(item) => (
          <div class="min-h-0 min-w-0 flex-1 overflow-hidden rounded-[7px] border border-[var(--border-muted)] bg-[var(--panel-alt)]">
            <PaneRow
              pane={item}
              tiled
              onClick={() => store.focusPane(item)}
              onOpenContext={(x, y) => props.onOpenPaneContext(item, x, y)}
            />
          </div>
        )}
      </Show>
    )
  }
  const split = props.node.split
  const ratio = Math.min(0.78, Math.max(0.22, split.ratio))
  return (
    <div class={`flex min-h-0 min-w-0 flex-1 gap-1 ${split.axis === 'vertical' ? 'flex-row' : 'flex-col'}`}>
      <div class="flex min-h-0 min-w-0 overflow-hidden" style={{ flex: `${ratio} 1 0%` }}>
        <SidebarGroupNode node={split.first} panes={props.panes} onOpenPaneContext={props.onOpenPaneContext} />
      </div>
      <div class="flex min-h-0 min-w-0 overflow-hidden" style={{ flex: `${1 - ratio} 1 0%` }}>
        <SidebarGroupNode node={split.second} panes={props.panes} onOpenPaneContext={props.onOpenPaneContext} />
      </div>
    </div>
  )
}

function PaneRow(props: {
  pane: LivePane
  activeCluster?: boolean
  tiled?: boolean
  onClick: () => void
  onOpenContext?: (x: number, y: number) => void
}) {
  const focused = () => store.focusedPaneId() === props.pane.pane_id && store.workspaceId() === props.pane.workspace_id
  const working = () => paneIsActive(props.pane)
  const context = createContextTrigger((x, y) => props.onOpenContext?.(x, y))
  return (
    <button
      type="button"
      class={`${props.tiled ? 'h-full min-h-[38px]' : 'mb-[4px] h-[38px]'} flex w-full touch-pan-y select-none items-center gap-2.5 rounded-[7px] px-2.5 text-left ${focused() ? 'bg-[var(--accent-row)]' : 'hover:bg-[var(--accent-hover)]'}`}
      style={{ '-webkit-touch-callout': 'none' }}
      onClick={(event) => {
        if (context.consumeClick(event)) return
        props.onClick()
      }}
      onContextMenu={context.onContextMenu}
      onPointerDown={context.onPointerDown}
      onPointerMove={context.onPointerMove}
      onPointerUp={context.onPointerUp}
      onPointerCancel={context.onPointerCancel}
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

function CollapsedRail(props: { onOpenContext: (workspace: Workspace, x: number, y: number) => void }) {
  return (
    <div class="flex min-h-0 flex-1 flex-col items-center gap-2 overflow-y-auto pt-1 scrollbar-thin">
      <For each={store.workspaces()}>
        {(workspace) => {
          const selected = () => store.workspace()?.workspace_id === workspace.workspace_id
          const context = createContextTrigger((x, y) => props.onOpenContext(workspace, x, y))
          return (
            <button
              type="button"
              class={`relative grid h-9 w-9 touch-pan-y select-none place-items-center rounded-[6px] ${selected() ? 'bg-[var(--accent-row)]' : 'hover:bg-[var(--accent-hover)]'}`}
              style={{ '-webkit-touch-callout': 'none' }}
              title={workspace.label}
              onClick={(event) => {
                if (context.consumeClick(event)) return
                store.selectWorkspace(workspace.workspace_id)
              }}
              onContextMenu={context.onContextMenu}
              onPointerDown={context.onPointerDown}
              onPointerMove={context.onPointerMove}
              onPointerUp={context.onPointerUp}
              onPointerCancel={context.onPointerCancel}
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

function SidebarContextMenu(props: {
  target: SidebarMenuTarget
  placement?: 'context' | 'trigger'
  onClose: () => void
  onChoose: (item: MenuItem) => void
}) {
  let panel!: HTMLDivElement
  const items = () => contextMenuItems(props.target)
  const position = () => {
    const viewport_w = window.innerWidth
    const viewport_h = window.innerHeight
    if (props.placement === 'trigger' && viewport_w < 1024) {
      return {
        left: '8px',
        bottom: 'calc(8px + var(--safe-bottom))',
        width: `${Math.max(1, viewport_w - 16)}px`,
        'max-height': 'calc(100dvh - 16px - var(--safe-bottom))',
      }
    }
    const width = Math.min(268, Math.max(1, viewport_w - 16))
    const available_h = Math.max(1, viewport_h - 16)
    const estimated_h = Math.min(items().length * 42 + 16, available_h)
    return {
      left: `${Math.max(8, Math.min(props.target.x, viewport_w - width - 8))}px`,
      top: `${Math.max(8, Math.min(props.target.y, viewport_h - estimated_h - 8))}px`,
      width: `${width}px`,
      'max-height': `${available_h}px`,
    }
  }
  const enabledButtons = () => [...panel.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')]
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'Escape') {
      event.preventDefault()
      props.onClose()
      return
    }
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) return
    event.preventDefault()
    const buttons = enabledButtons()
    if (buttons.length === 0) return
    const current = buttons.indexOf(document.activeElement as HTMLButtonElement)
    const next = event.key === 'Home'
      ? 0
      : event.key === 'End'
        ? buttons.length - 1
        : event.key === 'ArrowDown'
          ? (current + 1 + buttons.length) % buttons.length
          : (current - 1 + buttons.length) % buttons.length
    buttons[next]?.focus()
  }
  createEffect(() => {
    props.target
    queueMicrotask(() => enabledButtons()[0]?.focus())
  })
  return (
    <Portal>
      <div
        class={`fixed inset-0 z-50 ${props.placement === 'trigger' ? 'bg-black/40 lg:bg-transparent' : ''}`}
        onContextMenu={(event) => event.preventDefault()}
      >
        <button
          type="button"
          class="absolute inset-0 cursor-default bg-transparent"
          aria-label="Close context menu"
          onPointerDown={props.onClose}
        />
        <div
          ref={panel}
          class={`fixed z-10 overflow-y-auto border border-[var(--border-muted)] bg-[var(--panel-alt)] p-2 shadow-[0_18px_55px_rgba(0,0,0,0.5)] outline-none scrollbar-thin ${
            props.placement === 'trigger' ? 'rounded-[18px] lg:rounded-[12px]' : 'rounded-[12px]'
          }`}
          style={position()}
          role="menu"
          aria-label={props.target.kind === 'workspace'
            ? `${props.target.workspace.label} workspace actions`
            : `${store.paneTitle(props.target.pane)} ${props.target.kind === 'terminal' ? 'terminal' : 'chat'} actions`}
          tabIndex={-1}
          onKeyDown={onKeyDown}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <Show when={props.placement === 'trigger'}>
            <div class="px-2 pb-2 pt-0.5 lg:hidden">
              <div class="mx-auto mb-2 h-1 w-9 rounded-full bg-[var(--text-subtle)] opacity-60" />
              <div class="truncate text-[13px] font-bold text-[var(--text)]">
                {props.target.kind !== 'workspace'
                  ? store.paneTitle(props.target.pane)
                  : props.target.workspace.label}
              </div>
              <div class="mt-0.5 text-[11px] text-[var(--text-subtle)]">
                {props.target.kind === 'terminal' ? 'Terminal actions' : 'Chat actions'}
              </div>
            </div>
          </Show>
          <For each={items()}>
            {(item) => (
              <button
                type="button"
                role="menuitem"
                disabled={item.disabled}
                class={`flex w-full items-center rounded-[8px] px-3 text-left text-[13px] transition-colors disabled:cursor-not-allowed disabled:text-[var(--text-subtle)] ${
                  props.placement === 'trigger' ? 'min-h-11 lg:min-h-10' : 'min-h-10'
                } ${
                  item.danger
                    ? 'text-[var(--danger)] hover:bg-[rgba(255,100,100,0.12)]'
                    : 'text-[var(--text)] hover:bg-[var(--accent-hover)] focus:bg-[var(--accent-hover)]'
                }`}
                onClick={() => props.onChoose(item)}
              >
                {item.label}
              </button>
            )}
          </For>
        </div>
      </div>
    </Portal>
  )
}

function SidebarPrompt(props: {
  state: PromptState
  onClose: () => void
  onSubmit: (value: string) => void
}) {
  const [value, setValue] = createSignal(props.state.initial)
  let input!: HTMLInputElement
  createEffect(() => {
    props.state
    queueMicrotask(() => {
      input.focus()
      input.select()
    })
  })
  return (
    <Portal>
      <div class="fixed inset-0 z-[60] grid place-items-center bg-black/60 p-4" onPointerDown={props.onClose}>
        <form
          class="w-full max-w-[420px] rounded-[14px] border border-[var(--border-muted)] bg-[var(--panel-alt)] p-5 shadow-[0_24px_70px_rgba(0,0,0,0.55)]"
          onPointerDown={(event) => event.stopPropagation()}
          onSubmit={(event) => {
            event.preventDefault()
            const next = value().trim()
            if (next) props.onSubmit(next)
          }}
        >
          <div class="wordmark text-[20px] text-white">{props.state.title}</div>
          <label class="mt-4 block text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">
            {props.state.label}
          </label>
          <input
            ref={input}
            value={value()}
            placeholder={props.state.placeholder}
            class="mt-2 h-11 w-full rounded-[8px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 text-[14px] text-white outline-none focus:border-[var(--accent)]"
            onInput={(event) => setValue(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === 'Escape') {
                event.preventDefault()
                props.onClose()
              }
            }}
          />
          <div class="mt-5 flex justify-end gap-2">
            <button
              type="button"
              class="h-9 rounded-[7px] px-3 text-[13px] text-[var(--text-muted)] hover:bg-white/5"
              onClick={props.onClose}
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!value().trim()}
              class="h-9 rounded-[7px] bg-[var(--accent)] px-4 text-[13px] font-bold text-[#0d1213] hover:bg-[var(--accent-hi)] disabled:cursor-not-allowed disabled:opacity-40"
            >
              Continue
            </button>
          </div>
        </form>
      </div>
    </Portal>
  )
}

function contextMenuItems(target: SidebarMenuTarget): MenuItem[] {
  if (target.kind === 'workspace') {
    const linked = target.workspace.herdr_link != null
    const busy = store.activePanes().some(
      (pane) => pane.workspace_id === target.workspace.workspace_id && pane.kind === 'chat',
    )
    const herdr: MenuItem[] = linked
      ? [
          { action: 'workspace-herdr-focus-terminal', label: target.workspace.herdr_link?.attach_dock_id != null ? 'Focus Herdr terminal' : 'Open Herdr terminal' },
          { action: 'workspace-herdr-handoff', label: 'Refresh Herdr handoff' },
          { action: 'workspace-herdr-unlink', label: 'Run locally (unlink Herdr)' },
        ]
      : [
          { action: 'workspace-herdr-handoff', label: 'Handoff to Herdr' },
        ]
    return [
      { action: 'workspace-new-chat', label: 'Start a new chat' },
      { action: 'workspace-open-codex-tui', label: 'Open Codex TUI' },
      { action: 'workspace-open-terminal', label: 'Open terminal' },
      ...herdr,
      { action: 'workspace-rename', label: 'Rename workspace' },
      { action: 'workspace-import-codex', label: 'Import Codex thread' },
      { action: 'workspace-import-opencode', label: 'Import OpenCode thread' },
      { action: 'workspace-import-claude', label: 'Import Claude thread' },
      { action: 'workspace-close', label: 'Close workspace', disabled: busy, danger: true },
    ]
  }

  const pane = target.pane
  if (target.kind === 'terminal') {
    const desktop_only_disabled = pane.native_pane_id == null
    const close_disabled = desktop_only_disabled && !pane.session_id
    const zoomed = store.maximizedPaneId() === pane.pane_id
    return [
      { action: 'pane-zoom', label: zoomed ? 'Unzoom pane' : 'Zoom pane' },
      { action: 'pane-split-chat-right', label: 'Split with chat to right', disabled: desktop_only_disabled },
      { action: 'pane-split-chat-down', label: 'Split with chat below', disabled: desktop_only_disabled },
      { action: 'pane-split-terminal-right', label: 'Split with terminal to right', disabled: desktop_only_disabled },
      { action: 'pane-split-terminal-down', label: 'Split with terminal below', disabled: desktop_only_disabled },
      { action: 'pane-close', label: 'Close pane', disabled: close_disabled, danger: true },
    ]
  }
  const busy = paneIsActive(pane)
  const desktop_only_disabled = pane.native_pane_id == null
  const provider = pane.provider === 'opencode'
    ? 'OpenCode'
    : pane.provider === 'claude'
      ? 'Claude'
      : pane.provider === 'cursor'
        ? 'Cursor'
        : pane.provider === 'pi'
          ? 'Pi'
          : pane.provider === 'fx'
            ? 'FX'
            : pane.provider === 'grok'
              ? 'Grok'
              : 'Codex'
  return [
    { action: 'thread-rename', label: 'Rename chat', disabled: !pane.thread_id },
    { action: 'thread-regenerate-title', label: 'Regenerate title', disabled: busy || desktop_only_disabled },
    { action: 'thread-sync', label: 'Sync thread', disabled: busy || desktop_only_disabled || !pane.provider_thread_id },
    { action: 'thread-handoff', label: 'Handoff to another agent', disabled: busy || desktop_only_disabled },
    { action: 'thread-open-tui', label: `Open in TUI: ${provider}`, disabled: busy || desktop_only_disabled || !pane.provider_thread_id },
    { action: 'thread-archive', label: 'Archive thread', disabled: busy || !pane.thread_id, danger: true },
    { action: 'pane-close', label: 'Close pane', disabled: desktop_only_disabled, danger: true },
  ]
}

function createContextTrigger(onOpen: (x: number, y: number) => void) {
  const HOLD_MS = 560
  const MOVE_TOLERANCE = 10
  let timer: number | null = null
  let origin_x = 0
  let origin_y = 0
  let held = false

  const cancel = () => {
    if (timer !== null) window.clearTimeout(timer)
    timer = null
  }
  onCleanup(cancel)

  return {
    onContextMenu: (event: MouseEvent) => {
      event.preventDefault()
      cancel()
      onOpen(event.clientX, event.clientY)
    },
    onPointerDown: (event: PointerEvent) => {
      if (event.pointerType === 'mouse' || event.button !== 0) return
      cancel()
      origin_x = event.clientX
      origin_y = event.clientY
      timer = window.setTimeout(() => {
        timer = null
        held = true
        onOpen(origin_x, origin_y)
        navigator.vibrate?.(8)
      }, HOLD_MS)
    },
    onPointerMove: (event: PointerEvent) => {
      if (Math.hypot(event.clientX - origin_x, event.clientY - origin_y) > MOVE_TOLERANCE) cancel()
    },
    onPointerUp: () => {
      cancel()
      if (held) window.setTimeout(() => { held = false }, 500)
    },
    onPointerCancel: cancel,
    consumeClick: (event: MouseEvent) => {
      if (!held) return
      event.preventDefault()
      event.stopPropagation()
      held = false
      return true
    },
  }
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
