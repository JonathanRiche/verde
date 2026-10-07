import { For, Show, createEffect, createMemo, createSignal, onCleanup, type JSX } from 'solid-js'
import { Portal } from 'solid-js/web'

import { store, type SidebarContextAction } from '../lib/store'
import { paneIsActive, type LivePane, type Workspace } from '../lib/types'
import { fuzzyMatches, sidebarSections, type SidebarScope } from '../lib/workspace_switcher'
import { Icon, ProviderGlyph, StatusPip, VerdeLogo, WorkspaceGlyph } from './Icons'
import { ChatRouting } from './ChatRouting'
import { GitChangesDot } from './GitChanges'
import { openDesktopViewer } from './DesktopViewer'
import { openHistory } from './History'
import { sidebarMenuAvailability } from '../lib/commands'
import { themeTone } from '../lib/theme'
import { WORKSPACE_COLOR_SLOTS, WORKSPACE_ICONS, workspaceIdentity, workspaceSlotColor } from '../lib/workspace_identity'

function sameKeys(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((key, index) => key === b[index])
}

/// Background refreshes (`core.snapshot` pushes, catalog refetches) rebuild
/// pane objects even when only one field changed, and <For> keys rows by
/// object identity, so each refresh remounted every row. Iterate stable
/// string keys instead and read the latest row through an accessor so DOM
/// nodes survive refreshes.
function keyedRows<T>(rows: () => readonly T[], key: (row: T) => string) {
  const keys = createMemo(() => rows().map(key), [], { equals: sameKeys })
  const by_key = createMemo(() => new Map(rows().map((row) => [key(row), row] as const)))
  return {
    keys,
    row(id: string): () => T {
      // A removed row's accessor can still be read before <For> disposes it.
      let last = by_key().get(id)!
      return () => (last = by_key().get(id) ?? last)
    },
  }
}

function paneRowKey(pane: LivePane): string {
  return `${pane.workspace_id}\u0000${pane.pane_id}`
}

function actionWorkspace(pane?: LivePane): Workspace | undefined {
  if (!pane) return undefined
  const workspace_id = pane.kind === 'chat' ? store.owningWorkspaceId(pane) : pane.workspace_id
  return store.workspaces().find((item) => item.workspace_id === workspace_id)
}

type SidebarMenuTarget =
  | { kind: 'workspace'; workspace: Workspace; x: number; y: number }
  | { kind: 'thread'; workspace: Workspace; pane: LivePane; x: number; y: number }
  | { kind: 'terminal'; workspace: Workspace; pane: LivePane; x: number; y: number }

interface MenuItem {
  // View-only actions open overlays, not store actions.
  action: SidebarContextAction | 'workspace-history' | 'workspace-edit-identity'
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

export function Sidebar(props: { drawer?: boolean }) {
  const [menu, setMenu] = createSignal<SidebarMenuTarget | null>(null)
  const [prompt, setPrompt] = createSignal<PromptState | null>(null)
  const [identityTarget, setIdentityTarget] = createSignal<Workspace | null>(null)
  const [switcherOpen, setSwitcherOpen] = createSignal(false)
  let switcherTrigger!: HTMLButtonElement

  const scope = () => store.sidebarScope()
  // Active is global (spec section 4) and keeps store.activePanes() order so
  // active_select ordinals match; only Open follows the switcher scope, and
  // under All it interleaves workspaces newest activity first.
  const sections = createMemo(() => sidebarSections(
    store.activePanes(),
    store.sidebarPanes().filter((pane) => !paneIsActive(pane)),
    scope(),
    store.paneActivityMs,
  ))
  const active_rows = keyedRows(() => sections().active, paneRowKey)
  const open_rows = keyedRows(() => sections().open, paneRowKey)
  const scopedWorkspace = () => {
    const id = scope()
    return id === 'all' ? null : store.workspaces().find((row) => row.workspace_id === id) ?? null
  }
  const newInScope = (command: 'new-thread' | 'new-terminal') => {
    const target = store.sidebarTargetWorkspaceId()
    if (!target) {
      store.setNotice(null)
      store.setWorkspaceDialogOpen(true)
      return
    }
    void store.runCommand(command, target)
  }

  const openPaneMenu = (pane: LivePane, x: number, y: number) => {
    if (pane.kind !== 'chat' && pane.kind !== 'terminal') return
    const workspace = actionWorkspace(pane)
    if (workspace) setMenu({ kind: pane.kind === 'chat' ? 'thread' : 'terminal', workspace, pane, x, y })
  }
  const chooseMenuItem = (target: SidebarMenuTarget, item: MenuItem) => {
    setMenu(null)
    const workspace = actionWorkspace(target.kind === 'workspace' ? undefined : target.pane) ?? target.workspace
    if (item.action === 'workspace-history') {
      openHistory(workspace.workspace_id)
      return
    }
    if (item.action === 'workspace-edit-identity') {
      setIdentityTarget(workspace)
      return
    }
    if (item.action === 'workspace-rename') {
      setPrompt({
        action: item.action,
        workspace,
        title: 'Rename workspace',
        label: 'Workspace name',
        initial: workspace.label,
      })
      return
    }
    if (item.action === 'thread-rename' && target.kind === 'thread') {
      setPrompt({
        action: item.action,
        workspace,
        pane: target.pane,
        title: 'Rename chat',
        label: 'Chat title',
        initial: store.paneTitle(target.pane),
      })
      return
    }
    void store.runSidebarContextAction({
      action: item.action,
      workspace,
      ...(target.kind !== 'workspace' ? { pane: target.pane } : {}),
    })
  }

  const renderRow = (rows: typeof active_rows, chip: () => boolean) => (key: string) => {
    const pane = rows.row(key)
    return (
      <PaneRow
        pane={pane()}
        chip={chip()}
        onClick={() => store.focusPane(pane())}
        onOpenContext={(x, y) => openPaneMenu(pane(), x, y)}
      />
    )
  }

  return (
    <>
      <aside class="flex h-full min-h-0 flex-col bg-[var(--panel)] text-[13px]">
        <div class="shrink-0 px-4 pt-3.5 pb-2">
          <div class="flex h-8 items-center">
            <VerdeLogo class="h-7 w-7" />
            <div class="ml-auto flex items-center gap-1">
              <IconButton
                label={props.drawer ? 'Close menu' : 'Hide sidebar'}
                onClick={() => (props.drawer ? store.setDrawerOpen(false) : store.setSidebarHidden(true))}
              >
                <Icon name={props.drawer ? 'close' : 'collapse'} class="h-4 w-4 lg:h-3.5 lg:w-3.5" />
              </IconButton>
            </div>
          </div>

          <button
            ref={switcherTrigger}
            type="button"
            class={`mt-2.5 flex h-11 w-full items-center gap-2 rounded-[7px] border border-[var(--border-muted)] px-2 text-left lg:h-[34px] ${
              switcherOpen() ? 'bg-[var(--accent-hover)]' : 'hover:bg-[var(--accent-hover)]'
            }`}
            aria-haspopup="listbox"
            aria-expanded={switcherOpen()}
            onClick={() => { setMenu(null); setSwitcherOpen((open) => !open) }}
          >
            <Show
              when={scopedWorkspace()}
              fallback={(
                <span class="grid h-5 w-5 shrink-0 place-items-center rounded-[5px] bg-[var(--accent-dim)] text-[var(--accent)]">
                  <Icon name="layers" class="h-3.5 w-3.5" />
                </span>
              )}
            >
              {(workspace) => <WorkspaceGlyph workspace={workspace()} />}
            </Show>
            <span class="min-w-0 flex-1 truncate text-[15px] text-[var(--text)] lg:text-[13px]">
              {scopedWorkspace()?.label ?? 'All Workspaces'}
            </span>
            <Icon name="chevronDown" class="h-4 w-4 shrink-0 text-[var(--text-subtle)]" />
          </button>

          <div class="mt-2 flex items-center gap-1">
            <button
              type="button"
              class="flex h-10 min-w-0 flex-1 items-center rounded-[6px] bg-[var(--panel-alt)] px-2 text-[15px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white lg:h-[30px] lg:text-[12.5px]"
              onClick={() => store.setPaletteOpen(true)}
            >
              <Icon name="search" class="h-3.5 w-3.5 shrink-0" />
              <span class="ml-2 truncate">Search</span>
              <span class="mono ml-auto hidden text-[10px] text-[var(--text-subtle)] lg:inline">Ctrl+Shift+P</span>
            </button>
            <IconButton label="New chat" onClick={() => newInScope('new-thread')}>
              <Icon name="chat" class="h-[18px] w-[18px]" />
            </IconButton>
            <IconButton label="New terminal" onClick={() => newInScope('new-terminal')}>
              <Icon name="terminal" class="h-[18px] w-[18px]" />
            </IconButton>
          </div>
        </div>

        <div
          class="min-h-0 flex-1 overflow-y-auto px-4 scrollbar-thin"
          onScroll={() => setMenu(null)}
        >
          <Show when={active_rows.keys().length > 0}>
            <SectionLabel>ACTIVE</SectionLabel>
            <For each={active_rows.keys()}>{renderRow(active_rows, () => true)}</For>
          </Show>
          <Show when={open_rows.keys().length > 0}>
            <Show when={active_rows.keys().length > 0}>
              <div class="my-3 h-px bg-[var(--border-muted)]" />
            </Show>
            <SectionLabel>OPEN</SectionLabel>
            <For each={open_rows.keys()}>{renderRow(open_rows, () => sections().open_chips)}</For>
          </Show>
          <Show when={active_rows.keys().length === 0 && open_rows.keys().length === 0}>
            <div class="px-1 py-3 text-[12px] text-[var(--text-subtle)]">
              {store.workspaces().length === 0 ? 'No open workspaces.' : 'Nothing open here yet.'}
            </div>
          </Show>
        </div>

        <div class="flex h-14 shrink-0 items-center justify-end border-t border-[var(--border-muted)] px-4">
          <div class="mr-auto truncate text-[11px] text-[var(--text-subtle)]">
            {store.connected() ? store.source() : 'reconnecting'}
          </div>
          <button type="button" class="mr-2 rounded-[7px] px-2 py-1.5 text-[12px] text-[var(--text-subtle)] hover:bg-[var(--accent-row)] hover:text-[var(--text)]" onClick={() => { store.setDrawerOpen(false); openDesktopViewer() }}>Host desktop</button>
          <IconButton label="Settings" onClick={() => store.setSettingsOpen(true)}>
            <Icon name="settings" class="h-4 w-4" />
          </IconButton>
        </div>
      </aside>

      <Show when={switcherOpen()}>
        <WorkspaceSwitcher
          anchor={switcherTrigger}
          onClose={() => {
            setSwitcherOpen(false)
            queueMicrotask(() => switcherTrigger?.focus())
          }}
          onSelect={(next) => {
            setSwitcherOpen(false)
            void store.selectSidebarScope(next)
          }}
          onSettings={(workspace, x, y) => {
            setSwitcherOpen(false)
            setMenu({ kind: 'workspace', workspace, x, y })
          }}
          onNewWorkspace={() => {
            setSwitcherOpen(false)
            store.setNotice(null)
            store.setWorkspaceDialogOpen(true)
          }}
        />
      </Show>
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
      <Show when={identityTarget()} keyed>
        {(workspace) => (
          <WorkspaceIdentityDialog
            workspace={store.workspaces().find((row) => row.workspace_id === workspace.workspace_id) ?? workspace}
            onClose={() => setIdentityTarget(null)}
            onSave={(identity) => {
              setIdentityTarget(null)
              void store.setWorkspaceIdentity(workspace, identity)
            }}
          />
        )}
      </Show>
    </>
  )
}

function SectionLabel(props: { children: JSX.Element }) {
  return <div class="mb-1 text-[11px] tracking-wide text-[var(--text-subtle)]">{props.children}</div>
}

type SwitcherItem =
  | { kind: 'all' }
  | { kind: 'workspace'; workspace: Workspace; closed: boolean }
  | { kind: 'new' }

/// Context-menu styled workspace picker anchored under the sidebar trigger.
function WorkspaceSwitcher(props: {
  anchor: HTMLElement
  onClose: () => void
  onSelect: (scope: SidebarScope) => void
  onSettings: (workspace: Workspace, x: number, y: number) => void
  onNewWorkspace: () => void
}) {
  const [query, setQuery] = createSignal('')
  const [highlight, setHighlight] = createSignal(0)
  let input!: HTMLInputElement
  let list!: HTMLDivElement

  const items = createMemo((): SwitcherItem[] => {
    const text = query()
    const rows = store.switcherRows()
      .filter((row) => fuzzyMatches(row.workspace.label, text))
      .map((row): SwitcherItem => ({ kind: 'workspace', workspace: row.workspace, closed: row.closed }))
    return [
      ...(fuzzyMatches('all workspaces', text) ? [{ kind: 'all' } as const] : []),
      ...rows,
      { kind: 'new' } as const,
    ]
  })
  createEffect(() => {
    query()
    setHighlight(0)
  })
  createEffect(() => {
    const index = highlight()
    list?.querySelector<HTMLElement>(`[data-switcher-index="${index}"]`)?.scrollIntoView({ block: 'nearest' })
  })
  queueMicrotask(() => input?.focus())

  const position = () => {
    const rect = props.anchor.getBoundingClientRect()
    const width = Math.min(Math.max(rect.width, 260), window.innerWidth - 16)
    return {
      left: `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`,
      top: `${rect.bottom + 6}px`,
      width: `${width}px`,
      'max-height': `${Math.max(160, window.innerHeight - rect.bottom - 16)}px`,
    }
  }
  const choose = (item: SwitcherItem | undefined) => {
    if (!item) return
    if (item.kind === 'all') props.onSelect('all')
    else if (item.kind === 'new') props.onNewWorkspace()
    else props.onSelect(item.workspace.workspace_id)
  }
  const onKeyDown = (event: KeyboardEvent) => {
    const count = items().length
    if (event.key === 'Escape') {
      event.preventDefault()
      props.onClose()
    } else if (event.key === 'ArrowDown') {
      event.preventDefault()
      setHighlight((index) => (index + 1) % count)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setHighlight((index) => (index - 1 + count) % count)
    } else if (event.key === 'Enter') {
      event.preventDefault()
      choose(items()[highlight()])
    }
  }
  const isCurrent = (item: SwitcherItem) => {
    const scope = store.sidebarScope()
    return item.kind === 'all' ? scope === 'all' : item.kind === 'workspace' && scope === item.workspace.workspace_id
  }

  return (
    <Portal>
      <div class="anim-fade fixed inset-0 z-50" onContextMenu={(event) => event.preventDefault()}>
        <button
          type="button"
          class="absolute inset-0 cursor-default bg-transparent"
          aria-label="Close workspace switcher"
          onPointerDown={props.onClose}
        />
        <div
          class="anim-menu fixed z-10 flex flex-col overflow-hidden rounded-[12px] border border-[var(--border-muted)] bg-[var(--panel-alt)] shadow-[0_18px_55px_rgba(0,0,0,0.5)]"
          style={position()}
          onKeyDown={onKeyDown}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <div class="flex shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-3">
            <Icon name="search" class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
            <input
              ref={input}
              class="h-10 min-w-0 flex-1 bg-transparent text-[14px] text-[var(--text)] outline-none placeholder:text-[var(--text-subtle)] lg:h-9 lg:text-[13px]"
              placeholder="Search workspaces"
              aria-label="Search workspaces"
              aria-controls="workspace-switcher-list"
              aria-activedescendant={`workspace-switcher-${highlight()}`}
              value={query()}
              onInput={(event) => setQuery(event.currentTarget.value)}
            />
          </div>
          <div ref={list} id="workspace-switcher-list" role="listbox" aria-label="Workspaces" class="min-h-0 flex-1 overflow-y-auto p-1.5 scrollbar-thin">
            <For each={items()}>
              {(item, index) => (
                <div
                  id={`workspace-switcher-${index()}`}
                  data-switcher-index={index()}
                  role="option"
                  aria-selected={highlight() === index()}
                  class={`group flex min-h-11 cursor-pointer items-center gap-2 rounded-[8px] px-2 lg:min-h-9 ${
                    highlight() === index() ? 'bg-[var(--accent-hover)]' : ''
                  } ${item.kind === 'new' ? 'mt-1' : ''}`}
                  onPointerMove={() => setHighlight(index())}
                  onClick={() => choose(item)}
                >
                  <Show when={item.kind === 'new'}>
                    <span class="grid h-5 w-5 shrink-0 place-items-center text-[var(--text-subtle)]">
                      <Icon name="plus" class="h-3.5 w-3.5" />
                    </span>
                    <span class="min-w-0 flex-1 truncate text-[14px] text-[var(--text-muted)] lg:text-[13px]">New workspace</span>
                  </Show>
                  <Show when={item.kind === 'all'}>
                    <span class="grid h-5 w-5 shrink-0 place-items-center rounded-[5px] bg-[var(--accent-dim)] text-[var(--accent)]">
                      <Icon name="layers" class="h-3.5 w-3.5" />
                    </span>
                    <span class="min-w-0 flex-1 truncate text-[14px] text-[var(--text)] lg:text-[13px]">All Workspaces</span>
                  </Show>
                  <Show when={item.kind === 'workspace' ? item : null}>
                    {(row) => (
                      <>
                        <WorkspaceGlyph workspace={row().workspace} dim={row().closed} />
                        <span class={`min-w-0 flex-1 truncate text-[14px] lg:text-[13px] ${row().closed ? 'text-[var(--text-subtle)]' : 'text-[var(--text)]'}`}>
                          {row().workspace.label}
                        </span>
                        <Show when={row().closed}>
                          <span class="shrink-0 text-[11px] text-[var(--text-subtle)]">Closed</span>
                        </Show>
                        <Show when={!row().closed}>
                          <button
                            type="button"
                            class="grid h-8 w-8 shrink-0 place-items-center rounded-[6px] text-[var(--text-subtle)] hover:bg-[var(--accent-row)] hover:text-[var(--text)] lg:h-6 lg:w-6"
                            aria-label={`${row().workspace.label} workspace settings`}
                            title="Workspace settings"
                            onClick={(event) => {
                              event.stopPropagation()
                              const rect = event.currentTarget.getBoundingClientRect()
                              props.onSettings(row().workspace, rect.left, rect.bottom + 4)
                            }}
                          >
                            <Icon name="settings" class="h-3.5 w-3.5" />
                          </button>
                        </Show>
                      </>
                    )}
                  </Show>
                  <Show when={item.kind !== 'new' && isCurrent(item)}>
                    <Icon name="check" class="h-3.5 w-3.5 shrink-0 text-[var(--accent)]" />
                  </Show>
                </div>
              )}
            </For>
          </div>
        </div>
      </div>
    </Portal>
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
    const workspace = actionWorkspace(props.pane)
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
    const workspace = actionWorkspace(target.kind === 'workspace' ? undefined : target.pane) ?? target.workspace
    if (item.action === 'thread-rename' && target.kind === 'thread') {
      setPrompt({
        action: item.action,
        workspace,
        pane: target.pane,
        title: 'Rename chat',
        label: 'Chat title',
        initial: store.paneTitle(target.pane),
      })
      return
    }
    if (item.action === 'workspace-history') {
      openHistory(workspace.workspace_id)
      return
    }
    // Pane menus carry no workspace items; the identity editor lives in the sidebar.
    if (item.action === 'workspace-edit-identity') return
    void store.runSidebarContextAction({
      action: item.action,
      workspace,
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

function PaneRow(props: {
  pane: LivePane
  /// Active rows always, and Open rows under All Workspaces, carry their
  /// workspace identity chip.
  chip?: boolean
  onClick: () => void
  onOpenContext?: (x: number, y: number) => void
}) {
  const focused = () => store.focusedPaneId() === props.pane.pane_id && store.workspaceId() === props.pane.workspace_id
  const working = () => paneIsActive(props.pane)
  const context = createContextTrigger((x, y) => props.onOpenContext?.(x, y))
  return (
    <button
      type="button"
      class={`mb-[4px] h-[46px] lg:h-[38px] flex w-full touch-pan-y select-none items-center gap-2.5 rounded-[7px] px-2.5 text-left ${focused() ? 'bg-[var(--accent-row)]' : 'hover:bg-[var(--accent-hover)]'}`}
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
      <span class="min-w-0 flex-1 truncate text-[15px] text-[var(--text-muted)] lg:text-[13px]">{store.paneTitle(props.pane)}</span>
      <GitChangesDot pane={props.pane} />
      <Show when={props.chip}>
        <WorkspaceGlyph
          workspace={store.workspaces().find((row) => row.workspace_id === props.pane.workspace_id) ?? { workspace_id: props.pane.workspace_id }}
          class="h-[18px] w-[18px]"
          iconClass="h-3 w-3"
        />
      </Show>
      <Show when={working()}>
        <StatusPip active />
      </Show>
    </button>
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
    const estimated_h = Math.min(items().length * 42 + 16 + (props.target.kind === 'thread' ? 220 : 0), available_h)
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
    if (event.target instanceof HTMLSelectElement) return
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
        class={`anim-fade fixed inset-0 z-50 ${props.placement === 'trigger' ? 'bg-black/40 lg:bg-transparent' : ''}`}
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
          class={`anim-menu fixed z-10 overflow-y-auto border border-[var(--border-muted)] bg-[var(--panel-alt)] p-2 shadow-[0_18px_55px_rgba(0,0,0,0.5)] outline-none scrollbar-thin ${
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
          <Show when={props.target.kind === 'thread' ? props.target.pane : null} keyed>
            {(pane) => <ChatRouting pane={pane} onClose={props.onClose} />}
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
      input.value = props.state.initial
      setValue(props.state.initial)
      input.focus()
      input.select()
    })
  })
  return (
    <Portal>
      <div class="anim-fade fixed inset-0 z-[60] grid place-items-center bg-black/60 p-4" onPointerDown={props.onClose}>
        <form
          class="anim-pop w-full max-w-[420px] rounded-[14px] border border-[var(--border-muted)] bg-[var(--panel-alt)] p-5 shadow-[0_24px_70px_rgba(0,0,0,0.55)]"
          onPointerDown={(event) => event.stopPropagation()}
          onSubmit={(event) => {
            event.preventDefault()
            const next = (input.value || value()).trim()
            if (next) props.onSubmit(next)
          }}
        >
          <div class="wordmark text-[20px] text-white">{props.state.title}</div>
          <label class="mt-4 block text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">
            {props.state.label}
          </label>
          <input
            ref={input}
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

/// Icon/color picker for one workspace. Edits a draft with a live preview;
/// Save persists both slots (null = automatic hash-derived slot).
function WorkspaceIdentityDialog(props: {
  workspace: Workspace
  onClose: () => void
  onSave: (identity: { icon_index: number | null; color_index: number | null }) => void
}) {
  const [icon, setIcon] = createSignal<number | null>(props.workspace.icon_index ?? null)
  const [color, setColor] = createSignal<number | null>(props.workspace.color_index ?? null)
  const automatic = () => icon() === null && color() === null
  const identity = createMemo(() => workspaceIdentity(
    props.workspace.workspace_id, themeTone().accent, themeTone().dark, { icon_index: icon(), color_index: color() },
  ))
  const slotColor = (slot: number) => workspaceSlotColor(themeTone().accent, slot, themeTone().dark)
  let panel!: HTMLFormElement
  queueMicrotask(() => panel?.querySelector<HTMLButtonElement>('[role="radio"][aria-checked="true"]')?.focus())
  return (
    <Portal>
      <div class="anim-fade fixed inset-0 z-[60] grid place-items-center bg-black/60 p-4" onPointerDown={props.onClose}>
        <form
          ref={panel}
          class="anim-pop w-full max-w-[340px] rounded-[14px] border border-[var(--border-muted)] bg-[var(--panel-alt)] p-5 shadow-[0_24px_70px_rgba(0,0,0,0.55)]"
          role="dialog"
          aria-label={`Edit ${props.workspace.label} icon`}
          onPointerDown={(event) => event.stopPropagation()}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.preventDefault()
              props.onClose()
            }
          }}
          onSubmit={(event) => {
            event.preventDefault()
            props.onSave({ icon_index: icon(), color_index: color() })
          }}
        >
          <div class="flex items-center gap-3">
            <WorkspaceGlyph
              workspace={{ workspace_id: props.workspace.workspace_id, icon_index: icon(), color_index: color() }}
              class="h-9 w-9"
              iconClass="h-5 w-5"
            />
            <div class="min-w-0">
              <div class="wordmark text-[20px] text-white">Workspace icon</div>
              <div class="truncate text-[12px] text-[var(--text-subtle)]">{props.workspace.label}</div>
            </div>
          </div>

          <div class="mt-4 text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">Icon</div>
          <div class="mt-2 grid grid-cols-4 gap-1.5" role="radiogroup" aria-label="Icon">
            <For each={[...WORKSPACE_ICONS]}>
              {(name, index) => (
                <button
                  type="button"
                  role="radio"
                  aria-checked={identity().icon_index === index()}
                  aria-label={name}
                  title={name}
                  class={`grid h-11 place-items-center rounded-[8px] border lg:h-10 ${
                    identity().icon_index === index()
                      ? 'border-[var(--accent)]'
                      : 'border-transparent hover:bg-[var(--accent-hover)]'
                  }`}
                  style={{
                    color: identity().color,
                    background: identity().icon_index === index() ? `${identity().color}2e` : undefined,
                  }}
                  onClick={() => setIcon(index())}
                >
                  <Icon name={`ws-${name}`} class="h-5 w-5" />
                </button>
              )}
            </For>
          </div>

          <div class="mt-4 text-[11px] font-bold uppercase tracking-[0.08em] text-[var(--text-subtle)]">Color</div>
          <div class="mt-2 flex justify-between" role="radiogroup" aria-label="Color">
            <For each={Array.from({ length: WORKSPACE_COLOR_SLOTS }, (_, slot) => slot)}>
              {(slot) => (
                <button
                  type="button"
                  role="radio"
                  aria-checked={identity().color_index === slot}
                  aria-label={`Color ${slot + 1}`}
                  class={`grid h-9 w-9 place-items-center rounded-full border-2 lg:h-8 lg:w-8 ${
                    identity().color_index === slot ? 'border-[var(--text)]' : 'border-transparent'
                  }`}
                  onClick={() => setColor(slot)}
                >
                  <span class="h-6 w-6 rounded-full lg:h-5 lg:w-5" style={{ background: slotColor(slot) }} />
                </button>
              )}
            </For>
          </div>

          <div class="mt-5 flex items-center gap-2">
            <button
              type="button"
              aria-pressed={automatic()}
              title="Derive icon and color from the workspace id"
              class={`h-9 rounded-[7px] px-3 text-[13px] ${
                automatic()
                  ? 'bg-[var(--accent-dim)] text-[var(--accent)]'
                  : 'text-[var(--text-muted)] hover:bg-white/5'
              }`}
              onClick={() => { setIcon(null); setColor(null) }}
            >
              Automatic
            </button>
            <button
              type="button"
              class="ml-auto h-9 rounded-[7px] px-3 text-[13px] text-[var(--text-muted)] hover:bg-white/5"
              onClick={props.onClose}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="h-9 rounded-[7px] bg-[var(--accent)] px-4 text-[13px] font-bold text-[#0d1213] hover:bg-[var(--accent-hi)]"
            >
              Save
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
    return ([
      { action: 'workspace-new-chat', label: 'Start a new chat' },
      { action: 'workspace-open-codex-tui', label: 'Open Codex TUI' },
      { action: 'workspace-open-terminal', label: 'Open terminal' },
      { action: 'workspace-history', label: 'History' },
      ...herdr,
      { action: 'workspace-rename', label: 'Rename workspace' },
      { action: 'workspace-edit-identity', label: 'Edit icon…' },
      { action: 'workspace-import-codex', label: 'Import Codex thread' },
      { action: 'workspace-import-opencode', label: 'Import OpenCode thread' },
      { action: 'workspace-import-claude', label: 'Import Claude thread' },
      { action: 'workspace-close', label: 'Close workspace', disabled: busy, danger: true },
    ] satisfies MenuItem[]).map((item) => sidebarMenuAvailability(item))
  }

  const pane = target.pane
  if (target.kind === 'terminal') {
    const close_disabled = pane.native_pane_id == null && !pane.session_id
    return ([
      paneZoomItem(pane),
      { action: 'pane-split-chat-right', label: 'Split with chat to right' },
      { action: 'pane-split-chat-down', label: 'Split with chat below' },
      { action: 'pane-split-terminal-right', label: 'Split with terminal to right' },
      { action: 'pane-split-terminal-down', label: 'Split with terminal below' },
      { action: 'pane-close', label: 'Close pane', disabled: close_disabled, danger: true },
    ] satisfies MenuItem[]).map((item) => sidebarMenuAvailability(item, pane))
  }
  const busy = paneIsActive(pane)
  const remote = store.connectionFor(pane) !== 'local'
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
  return ([
    paneZoomItem(pane),
    { action: 'thread-rename', label: 'Rename chat', disabled: !pane.thread_id },
    { action: 'thread-regenerate-title', label: 'Regenerate title', disabled: busy || !pane.thread_id },
    { action: 'thread-sync', label: 'Sync thread', disabled: busy || !pane.thread_id || !pane.provider_thread_id || remote },
    { action: 'thread-handoff', label: 'Handoff to another agent', disabled: busy || !pane.thread_id },
    { action: 'thread-open-tui', label: `Open in TUI: ${provider}`, disabled: busy || !pane.provider_thread_id || remote },
    // Chats close through chat.thread.close.
    { action: 'pane-close', label: 'Close pane', danger: true },
  ] satisfies MenuItem[]).map((item) => sidebarMenuAvailability(item, { ...pane, profile_id: store.connectionFor(pane) }))
}

function paneZoomItem(pane: LivePane): MenuItem {
  const zoomed = store.maximizedPaneId() === pane.pane_id
  return { action: 'pane-zoom', label: zoomed ? 'Unzoom pane' : 'Zoom pane' }
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
      class="grid h-10 w-10 place-items-center rounded-[6px] text-[var(--text-subtle)] hover:bg-[var(--accent-hover)] hover:text-white lg:h-7 lg:w-7"
      aria-label={props.label}
      onClick={props.onClick}
    >
      {props.children}
    </button>
  )
}
