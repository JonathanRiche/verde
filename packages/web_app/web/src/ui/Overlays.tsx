import { For, Show, createEffect, createMemo, createResource, createSignal, onCleanup } from 'solid-js'
import type { JSX } from 'solid-js'

import { fetchRpc, unwrapResult } from '../lib/live'
import { store } from '../lib/store'
import { COMMANDS } from '../lib/commands'
import { notifications } from '../lib/notify'
import { viewportDiagnostics } from '../lib/pwa'
import { openHistory } from './History'
import { loadTheme } from '../lib/theme'
import { UI_CONFIG_LIMITS, type ReducedMotionParts } from '../lib/ui_config'


/** Keep keyboard focus in the visible sheet and return it to its opener. */
function containModalFocus(open: () => boolean, panel: () => HTMLElement | undefined, initial?: () => HTMLElement | undefined) {
  createEffect(() => {
    if (!open()) return
    const restore = document.activeElement instanceof HTMLElement ? document.activeElement : null
    let disposed = false
    const focusable = () => [...(panel()?.querySelectorAll<HTMLElement>(
      'button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), a[href], [tabindex]:not([tabindex="-1"])',
    ) ?? [])].filter((element) => element.tabIndex >= 0 && element.getClientRects().length > 0)
    queueMicrotask(() => {
      if (!disposed) (initial?.() ?? focusable()[0] ?? panel())?.focus()
    })
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Tab' || event.isComposing) return
      // The app maps plain Tab on buttons to focus_prompt. Modal navigation
      // owns this key even when native focus movement needs no wrapping.
      event.stopPropagation()
      const root = panel()
      if (!root) return
      const items = focusable()
      const first = items[0], last = items.at(-1)
      const active = document.activeElement
      if (!first || !root.contains(active) || active === root || (event.shiftKey ? active === first : active === last)) {
        event.preventDefault()
        ;(event.shiftKey ? last : first)?.focus()
        if (!first) root.focus()
      }
    }
    window.addEventListener('keydown', onKey, true)
    onCleanup(() => {
      disposed = true
      window.removeEventListener('keydown', onKey, true)
      if (restore?.isConnected) restore.focus()
    })
  })
}

type PaletteSection = 'threads' | 'panes' | 'workspaces' | 'app'
// Same sections, same order, as the desktop palette (command_palette.zig Section).
const SECTIONS: PaletteSection[] = ['threads', 'panes', 'workspaces', 'app']
const HISTORY_COMMAND = 'thread.history'

interface PaletteItem {
  id: string
  title: string
  section: PaletteSection
  /// Keyboard accelerator, rendered as kbd chips (desktop layouts only).
  keys?: string
  /// Muted trailing label (pane kind, "active").
  hint?: string
  desktop?: boolean
  disabled?: boolean
}

function sectionOf(id: string): PaletteSection {
  const prefix = id.slice(0, id.indexOf('.'))
  return prefix === 'thread' ? 'threads' : prefix === 'pane' ? 'panes' : prefix === 'workspace' ? 'workspaces' : 'app'
}

export function Palette() {
  const [query, setQuery] = createSignal('')
  const [active, setActive] = createSignal(0)
  let list: HTMLUListElement | undefined
  let panel: HTMLDivElement | undefined
  let field: HTMLInputElement | undefined
  containModalFocus(store.paletteOpen, () => panel, () => field)

  const results = createMemo(() => {
    const needle = query().trim().toLowerCase()
    const has_workspace = Boolean(store.workspace())
    const desktop_pane = store.focusedPane()?.native_pane_id != null
    const commands: PaletteItem[] = COMMANDS.map((command) => ({
      id: command.id,
      // The catalog suffixes desktop-only titles; the row shows a tag instead.
      title: command.title.replace(/ \(desktop\)$/, ''),
      section: sectionOf(command.id),
      keys: command.hint || undefined,
      desktop: command.desktop,
      disabled: command.desktop && !desktop_pane,
    }))
    const history: PaletteItem = { id: HISTORY_COMMAND, title: 'History', section: 'threads', disabled: !has_workspace }
    const panes: PaletteItem[] = [
      ...store.activePanes().map((pane) => ({ pane, hint: 'active' })),
      ...store.openPanes().map((pane) => ({ pane, hint: pane.kind as string })),
    ].map(({ pane, hint }) => ({
      id: `pane:${pane.workspace_id}:${pane.pane_id}`,
      title: store.paneTitle(pane),
      section: 'panes',
      hint,
    }))
    const workspaces: PaletteItem[] = store.workspaces().map((workspace) => ({
      id: `workspace:${workspace.workspace_id}`,
      title: workspace.label,
      section: 'workspaces',
    }))
    const seen = new Set<string>()
    const matched = [history, ...commands, ...panes, ...workspaces].filter((item) => {
      if (seen.has(item.id)) return false
      seen.add(item.id)
      return item.title.toLowerCase().includes(needle)
    })
    // Flat, section-ordered list: row index doubles as the keyboard cursor.
    return SECTIONS.flatMap((section) => matched.filter((item) => item.section === section))
  })

  const close = () => {
    setQuery('')
    setActive(0)
    store.setPaletteOpen(false)
  }

  const run = (item: PaletteItem | undefined) => {
    if (!item || item.disabled) return
    const id = item.id
    if (id === HISTORY_COMMAND) {
      const workspace = store.workspace()
      close()
      if (workspace) openHistory(workspace.workspace_id)
      return
    }
    if (id.startsWith('pane:')) {
      const [, workspaceId, paneId] = id.split(':')
      const pane = [...store.openPanes(), ...store.activePanes()].find(
        (row) => row.workspace_id === workspaceId && row.pane_id === Number(paneId),
      )
      if (pane) store.focusPane(pane)
      close()
      return
    }
    if (id.startsWith('workspace:')) {
      store.selectWorkspace(id.slice('workspace:'.length))
      close()
      return
    }
    close()
    void store.runCommand(id)
  }

  /// Move the cursor, skipping rows that cannot run.
  const step = (delta: number) => {
    const rows = results()
    if (!rows.length) return
    let next = active()
    for (let tries = 0; tries < rows.length; tries += 1) {
      next = (next + delta + rows.length) % rows.length
      if (!rows[next].disabled) break
    }
    setActive(next)
  }

  createEffect(() => {
    const rows = results()
    // A new query (or a vanished row) lands on the first runnable result.
    const index = active()
    if (index >= rows.length || rows[index]?.disabled) {
      const first = rows.findIndex((row) => !row.disabled)
      setActive(first < 0 ? 0 : first)
    }
  })
  createEffect(() => {
    const index = active()
    if (!store.paletteOpen()) return
    queueMicrotask(() => list?.querySelector(`[data-index="${index}"]`)?.scrollIntoView({ block: 'nearest' }))
  })

  return (
    <Show when={store.paletteOpen()}>
      {/* absolute, not fixed: iOS standalone clips fixed boxes to its short
          layout viewport; the app root is already sized from --app-height. */}
      <div class="anim-fade absolute inset-0 z-40 bg-black/55" onClick={close}>
        <div
          class="palette-panel anim-pop mx-auto flex max-w-[560px] flex-col overflow-hidden border-[var(--border-muted)] bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)] max-md:h-full max-md:pt-[var(--safe-top)] max-md:pb-[var(--safe-bottom)] md:mt-[12vh] md:max-h-[70%] md:rounded-[10px] md:border"
          role="dialog"
          aria-label="Command palette"
          aria-modal="true"
          tabindex="-1"
          ref={node => { panel = node }}
          onClick={(event) => event.stopPropagation()}
        >
          <div class="flex shrink-0 items-center border-b border-[var(--border-muted)]">
            <input
              class="min-w-0 flex-1 bg-transparent px-4 py-3 text-[16px] outline-none placeholder:text-[var(--text-subtle)] md:text-[15px]"
              placeholder="Jump to a pane, workspace, or command"
              role="combobox"
              aria-expanded="true"
              aria-controls="palette-results"
              aria-activedescendant={results().length ? `palette-row-${active()}` : undefined}
              autocomplete="off"
              autocapitalize="none"
              spellcheck={false}
              ref={node => { field = node }}
              onInput={(event) => {
                setQuery(event.currentTarget.value)
                setActive(0)
              }}
              onKeyDown={(event) => {
                if (event.isComposing || event.keyCode === 229) return
                if (event.key === 'Escape') close()
                else if (event.key === 'ArrowDown') step(1)
                else if (event.key === 'ArrowUp') step(-1)
                else if (event.key === 'Enter') run(results()[active()])
                else return
                event.preventDefault()
              }}
            />
            <button
              type="button"
              class="mr-1 min-h-[44px] shrink-0 rounded-[7px] px-3 text-[13px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] md:hidden"
              onClick={close}
            >
              Cancel
            </button>
          </div>
          <ul
            id="palette-results"
            role="listbox"
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-1.5 scrollbar-thin"
            ref={(node) => {
              list = node
            }}
          >
            <For
              each={results()}
              fallback={
                <li class="px-3 py-10 text-center text-[13px] text-[var(--text-subtle)]">
                  <div class="text-[var(--text-muted)]">No matches for “{query().trim()}”</div>
                  <div class="mt-1">Try a pane title, a workspace name, or a command.</div>
                </li>
              }
            >
              {(item, index) => (
                <>
                  <Show when={index() === 0 || results()[index() - 1].section !== item.section}>
                    <li role="presentation" class="palette-section">{item.section}</li>
                  </Show>
                  <li
                    id={`palette-row-${index()}`}
                    data-index={index()}
                    role="option"
                    aria-selected={index() === active()}
                    aria-disabled={item.disabled}
                    title={item.disabled && item.desktop ? 'Needs a focused pane in the running desktop app' : undefined}
                    class={`palette-row ${index() === active() ? 'palette-row-active' : ''} ${item.disabled ? 'palette-row-disabled' : ''}`}
                    onMouseMove={() => {
                      if (!item.disabled && active() !== index()) setActive(index())
                    }}
                    onClick={() => run(item)}
                  >
                    <span class="min-w-0 flex-1 truncate">{item.title}</span>
                    <Show when={item.desktop}>
                      <span class="palette-tag">Desktop</span>
                    </Show>
                    <Show when={item.hint}>
                      <span class="mono shrink-0 text-[10px] text-[var(--text-subtle)]">{item.hint}</span>
                    </Show>
                    <Show when={item.keys}>
                      <span class="hidden shrink-0 items-center gap-1 lg:flex" aria-hidden="true">
                        <For each={item.keys!.split('+')}>{(key) => <kbd class="palette-kbd">{key}</kbd>}</For>
                      </span>
                    </Show>
                  </li>
                </>
              )}
            </For>
          </ul>
        </div>
      </div>
    </Show>
  )
}

/// iOS only delivers web notifications to a Home Screen install.
function iosNeedsInstall(): boolean {
  const ios =
    /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  const standalone =
    (navigator as Navigator & { standalone?: boolean }).standalone === true ||
    window.matchMedia('(display-mode: standalone)').matches
  return ios && !standalone
}

export function Settings() {
  let panel: HTMLDivElement | undefined
  containModalFocus(store.settingsOpen, () => panel)
  const [theme] = createResource(loadTheme)
  const permission = () => notifications.permission()
  const blocked = () => permission() === 'denied' || permission() === 'unsupported'
  const on = () => notifications.enabled() && permission() === 'granted'
  // Permission is requested only from this tap, never on open.
  const toggle = async () => {
    if (on()) return notifications.setEnabled(false)
    const state = permission() === 'default' ? await notifications.requestPermission() : permission()
    notifications.setEnabled(state === 'granted')
  }
  const explain = () => {
    if (permission() === 'unsupported') {
      return iosNeedsInstall()
        ? 'On iPhone and iPad, notifications need the installed app: tap Share, then Add to Home Screen, and open Verde from its icon.'
        : 'This browser does not support notifications.'
    }
    if (permission() === 'denied') {
      return 'Notifications are blocked for this site. Re-enable them from the lock icon in the address bar (or Settings → Notifications → Verde for the installed app), then reload.'
    }
    if (permission() === 'default') return 'Turning this on asks your browser for permission.'
    return on()
      ? 'You are told when an agent finishes, needs approval, or fails while you are looking elsewhere.'
      : 'Permission is granted; notifications are switched off here.'
  }
  return (
    <Show when={store.settingsOpen()}>
      <div class="anim-fade absolute inset-0 z-40 bg-black/55" onClick={() => store.setSettingsOpen(false)}>
        <div
          class="anim-pop absolute top-16 right-8 flex max-h-[calc(100%-5rem)] w-[28rem] max-w-[calc(100vw-2rem)] flex-col rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] max-md:top-auto max-md:right-3 max-md:bottom-[calc(0.75rem+var(--safe-bottom))] max-md:left-3 max-md:max-h-[calc(100%-1.5rem-var(--safe-top)-var(--safe-bottom))] max-md:w-auto max-md:rounded-[14px]"
          role="dialog"
          aria-label="Settings"
          aria-modal="true"
          tabindex="-1"
          ref={node => { panel = node }}
          onClick={(event) => event.stopPropagation()}
        >
          <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-5 pb-2 scrollbar-thin">
            <div class="wordmark text-[28px] leading-none">Settings</div>
            <p class="mt-2 text-[13px] text-[var(--text-muted)]">
              This client is a live projection of the running desktop daemon.
            </p>

            <SettingsSection title="Appearance" note="Colors come from the same verde.json / Omarchy path as the desktop app.">
              <Row label="Theme" value={theme()?.active ?? '…'} />
              <Row label="Theme source" value={theme()?.source ?? '…'} />
            </SettingsSection>

            <MotionSettings />
            <WorkspaceSettings />

            <SettingsSection title="Notifications">
              <div class="flex min-h-[44px] items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2">
                <span id="settings-notify-label">Agent notifications</span>
                <button
                  type="button"
                  role="switch"
                  aria-checked={on()}
                  aria-labelledby="settings-notify-label"
                  aria-describedby="settings-notify-help"
                  class="settings-switch"
                  disabled={blocked()}
                  onClick={() => void toggle()}
                />
              </div>
              <p
                id="settings-notify-help"
                class={`mt-2 text-[12px] leading-[1.45] ${blocked() ? 'text-[var(--warning)]' : 'text-[var(--text-muted)]'}`}
              >
                {explain()}
              </p>
            </SettingsSection>

            <SettingsSection
              title="Connection"
              note="On a phone, open this URL over HTTPS (Tailscale) and use Add to Home Screen (Safari) or Install app (Chrome) for a standalone Verde icon."
            >
              <Row label="Daemon" value={store.source()} />
              <Row label="Socket" value={store.connected() ? 'websocket open' : 'reconnecting'} />
              <Row label="Workspace" value={store.workspace()?.label ?? '—'} />
            </SettingsSection>

            <SettingsSection title="Diagnostics">
              <Row label="Open panes" value={String(store.openPanes().length)} />
              <Row label="Focused pane" value={store.focusedPane() ? store.paneTitle(store.focusedPane()!) : '—'} />
              <Row label="Viewport" value={viewportDiagnostics()} />
            </SettingsSection>
          </div>
          <div class="shrink-0 p-5 pt-3">
            <button
              type="button"
              class="min-h-[44px] w-full rounded-[7px] border border-[var(--border-muted)] text-[14px] hover:bg-[var(--accent-hover)] lg:min-h-0 lg:py-2"
              onClick={() => store.setSettingsOpen(false)}
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Show>
  )
}

const MOTION_PART_ROWS: Array<{ part: keyof ReducedMotionParts; label: string }> = [
  { part: 'pane_scroll', label: 'Pane scrolling' },
  { part: 'pane_layout', label: 'Pane resize & focus' },
  { part: 'status_pulse', label: 'Status pulses' },
  { part: 'chat', label: 'Chat animations' },
  { part: 'chrome', label: 'Sidebar & dialogs' },
]

/// Same switches as desktop Settings > Appearance, written to verde.json.
function MotionSettings() {
  const parts = () => store.uiConfig().reduced_motion_parts
  const setAll = (enabled: boolean) => {
    const next: Partial<ReducedMotionParts> = {}
    for (const row of MOTION_PART_ROWS) next[row.part] = enabled
    store.updateUiConfig({ reduced_motion_parts: next })
  }
  return (
    <SettingsSection title="Motion" note="Shared with the desktop app through verde.json.">
      <SwitchRow id="settings-motion-all" label="Reduce motion" checked={store.uiConfig().reduced_motion} onChange={setAll} />
      <For each={MOTION_PART_ROWS}>
        {(row) => (
          <SwitchRow
            id={`settings-motion-${row.part}`}
            label={row.label}
            indent
            checked={parts()[row.part]}
            onChange={(enabled) => store.updateUiConfig({ reduced_motion_parts: { [row.part]: enabled } })}
          />
        )}
      </For>
    </SettingsSection>
  )
}

/// Desktop Settings > Workspace: the strip/split settings the web projects.
function WorkspaceSettings() {
  const ui = () => store.uiConfig()
  return (
    <SettingsSection title="Workspace" note="Shared with the desktop app through verde.json.">
      <SegmentRow
        label="New pane"
        value={ui().workspace_split_default_pane}
        options={[{ value: 'chat', label: 'Chat' }, { value: 'terminal', label: 'Terminal' }]}
        onChange={(value) => store.updateUiConfig({ workspace_split_default_pane: value })}
      />
      <SwitchRow
        id="settings-unzoom-on-navigate"
        label="Unzoom on navigate"
        checked={ui().unzoom_on_pane_navigation}
        onChange={(enabled) => store.updateUiConfig({ unzoom_on_pane_navigation: enabled })}
      />
      <StepperRow
        label="Pane gap"
        value={ui().workspace_pane_gap}
        {...UI_CONFIG_LIMITS.pane_gap}
        onChange={(value) => store.updateUiConfig({ workspace_pane_gap: value })}
      />
      <StepperRow
        label="Panes per view"
        value={ui().workspace_panes_per_view}
        {...UI_CONFIG_LIMITS.panes_per_view}
        onChange={(value) => store.updateUiConfig({ workspace_panes_per_view: value })}
      />
      <SegmentRow
        label="Scrolling"
        value={ui().workspace_scroll_mode}
        options={[
          { value: 'automatic', label: 'Auto' },
          { value: 'always', label: 'Always' },
          { value: 'disabled', label: 'Off' },
        ]}
        onChange={(value) => store.updateUiConfig({ workspace_scroll_mode: value })}
      />
      <Show when={ui().workspace_scroll_mode === 'automatic'}>
        <StepperRow
          label="Start after"
          value={ui().workspace_scroll_threshold}
          {...UI_CONFIG_LIMITS.scroll_threshold}
          onChange={(value) => store.updateUiConfig({ workspace_scroll_threshold: value })}
        />
      </Show>
      <SegmentRow
        label="Direction"
        value={ui().workspace_scroll_direction}
        options={[{ value: 'horizontal', label: 'Horizontal' }, { value: 'vertical', label: 'Vertical' }]}
        onChange={(value) => store.updateUiConfig({ workspace_scroll_direction: value })}
      />
    </SettingsSection>
  )
}

function SwitchRow(props: { id: string; label: string; checked: boolean; indent?: boolean; onChange: (checked: boolean) => void }) {
  return (
    <div class={`flex min-h-[44px] items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2 ${props.indent ? 'pl-4' : ''}`}>
      <span id={`${props.id}-label`} class={props.indent ? 'text-[var(--text-muted)]' : ''}>{props.label}</span>
      <button
        type="button"
        role="switch"
        aria-checked={props.checked}
        aria-labelledby={`${props.id}-label`}
        class="settings-switch"
        onClick={() => props.onChange(!props.checked)}
      />
    </div>
  )
}

function SegmentRow<T extends string>(props: {
  label: string
  value: T
  options: Array<{ value: T; label: string }>
  onChange: (value: T) => void
}) {
  return (
    <div class="flex min-h-[44px] items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2">
      <span>{props.label}</span>
      <div role="radiogroup" aria-label={props.label} class="flex overflow-hidden rounded-[7px] border border-[var(--border-muted)]">
        <For each={props.options}>
          {(option) => (
            <button
              type="button"
              role="radio"
              aria-checked={props.value === option.value}
              class={`min-h-[32px] px-3 text-[12px] ${
                props.value === option.value
                  ? 'bg-[var(--accent-dim)] text-[var(--accent)]'
                  : 'text-[var(--text-muted)] hover:bg-[var(--accent-hover)]'
              }`}
              onClick={() => props.onChange(option.value)}
            >
              {option.label}
            </button>
          )}
        </For>
      </div>
    </div>
  )
}

function StepperRow(props: { label: string; value: number; min: number; max: number; onChange: (value: number) => void }) {
  const step = (delta: number) => props.onChange(Math.min(props.max, Math.max(props.min, Math.round(props.value) + delta)))
  const button = 'grid h-8 w-8 place-items-center rounded-[7px] border border-[var(--border-muted)] text-[14px] hover:bg-[var(--accent-hover)] disabled:opacity-40'
  return (
    <div class="flex min-h-[44px] items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2">
      <span>{props.label}</span>
      <div class="flex items-center gap-2">
        <button type="button" class={button} aria-label={`Decrease ${props.label}`} disabled={props.value <= props.min} onClick={() => step(-1)}>−</button>
        <span class="mono w-8 text-center text-[12px]" aria-live="polite">{Math.round(props.value)}</span>
        <button type="button" class={button} aria-label={`Increase ${props.label}`} disabled={props.value >= props.max} onClick={() => step(1)}>+</button>
      </div>
    </div>
  )
}

function SettingsSection(props: { title: string; note?: string; children: JSX.Element }) {
  return (
    <section class="mt-5 text-[13px]">
      <h3 class="palette-section !px-0">{props.title}</h3>
      <dl>{props.children}</dl>
      <Show when={props.note}>
        <p class="mt-2 text-[12px] leading-[1.45] text-[var(--text-subtle)]">{props.note}</p>
      </Show>
    </section>
  )
}

export function WorkspaceDialog() {
  let pathField: HTMLInputElement | undefined
  const [path, setPath] = createSignal('')
  const [submitting, setSubmitting] = createSignal(false)
  const [browserOpen, setBrowserOpen] = createSignal(false)
  const [browserLoading, setBrowserLoading] = createSignal(false)
  const [browserError, setBrowserError] = createSignal<string | null>(null)
  // The gateway refuses directory listing by design (security contract), so
  // once it says so the Browse button is replaced by known-parent shortcuts.
  const [browseUnsupported, setBrowseUnsupported] = createSignal(false)
  const parentFolders = () => {
    const parents = new Set<string>()
    for (const workspace of store.workspaces()) {
      const path = workspace.path ?? ''
      const cut = path.lastIndexOf('/')
      if (path.startsWith('/') && cut > 0) parents.add(`${path.slice(0, cut)}/`)
    }
    return [...parents].sort().slice(0, 6)
  }
  const [directoryListing, setDirectoryListing] = createSignal<{
    path: string
    parent?: string | null
    directories: Array<{ name: string; path: string }>
  } | null>(null)

  const close = () => {
    if (submitting()) return
    setPath('')
    setBrowserOpen(false)
    setBrowserError(null)
    setDirectoryListing(null)
    store.setWorkspaceDialogOpen(false)
  }

  const browse = async (requested_path?: string) => {
    // The projected workspace can belong to a different host than verde-web,
    // so an empty browser must start from the gateway machine's filesystem.
    const target = requested_path ?? ((pathField?.value ?? path()).trim() || '/')
    setBrowserOpen(true)
    setBrowserLoading(true)
    setBrowserError(null)
    try {
      // HTTP on purpose: the shared websocket answers RPCs serially, so this
      // interactive browse must not queue behind a background projection sweep.
      const response = await fetchRpc('web.directory.list', { path: target })
      if (response.error || response.ok === false) {
        if (response.error?.code === 'unsupported') {
          setBrowseUnsupported(true)
          setBrowserOpen(false)
          setBrowserError('Folder browsing is turned off for web access. Type the full path, or tap a folder below to start from it.')
          return
        }
        setBrowserError(response.error?.message ?? 'could not list directory')
        return
      }
      const listing = unwrapResult<{
        path: string
        parent?: string | null
        directories: Array<{ name: string; path: string }>
      }>(response)
      if (!listing || !Array.isArray(listing.directories)) {
        setBrowserError('directory listing was invalid')
        return
      }
      setDirectoryListing(listing)
      setPath(listing.path)
      if (pathField) pathField.value = listing.path
    } catch (err) {
      setBrowserError(err instanceof Error ? err.message : 'could not list directory')
    } finally {
      setBrowserLoading(false)
    }
  }

  const submit = async (event: SubmitEvent) => {
    event.preventDefault()
    const next = (pathField?.value ?? path()).trim()
    if (!next || submitting()) return
    setPath(next)
    setSubmitting(true)
    const created = await store.createWorkspace(next)
    setSubmitting(false)
    if (created) {
      setPath('')
      if (pathField) pathField.value = ''
    }
  }

  return (
    <Show when={store.workspaceDialogOpen()}>
      <div class="anim-fade fixed inset-0 z-40 bg-black/55" onClick={close}>
        <form
          class="anim-pop mx-auto mt-[16vh] w-[32rem] max-w-[calc(100vw-2rem)] rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] p-5 shadow-[0_24px_80px_rgba(0,0,0,0.55)]"
          onClick={(event) => event.stopPropagation()}
          onSubmit={submit}
        >
          <div class="wordmark text-[28px] leading-none">Add Workspace</div>
          <p class="mt-2 text-[13px] text-[var(--text-muted)]">
            Enter the absolute path to a project directory on the machine running Verde.
          </p>
          <div class="mt-4 flex gap-2">
            <input
              ref={(node) => { pathField = node }}
              class="mono min-w-0 flex-1 rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-3 py-2 text-[16px] outline-none lg:text-[13px] focus:border-[var(--accent)]"
              aria-label="Workspace path"
              placeholder="/path/to/project"
              autofocus
              onInput={(event) => setPath(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key === 'Escape') close()
              }}
            />
            <Show when={!browseUnsupported()}>
              <button
                type="button"
                class="shrink-0 rounded-[7px] border border-[var(--border-muted)] px-3 py-2 text-[13px] hover:bg-[var(--accent-hover)]"
                onClick={() => void browse()}
              >
                Browse…
              </button>
            </Show>
          </div>
          <Show when={parentFolders().length > 0}>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <For each={parentFolders()}>
                {(folder) => (
                  <button
                    type="button"
                    class="mono max-w-full truncate rounded-[6px] border border-[var(--border-muted)] px-2 py-1.5 text-[12px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)]"
                    onClick={() => {
                      setPath(folder)
                      if (pathField) {
                        pathField.value = folder
                        pathField.focus()
                      }
                    }}
                  >
                    {folder}
                  </button>
                )}
              </For>
            </div>
          </Show>
          <Show when={browserOpen()}>
            <div class="anim-reveal mt-3 overflow-hidden rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)]">
              <div class="flex items-center gap-2 border-b border-[var(--border-muted)] p-2">
                <button
                  type="button"
                  class="rounded px-2 py-1 text-[12px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] disabled:opacity-40"
                  disabled={!directoryListing()?.parent || browserLoading()}
                  onClick={() => {
                    const parent = directoryListing()?.parent
                    if (parent) void browse(parent)
                  }}
                >
                  Up
                </button>
                <span class="mono min-w-0 flex-1 truncate text-[11px] text-[var(--text-subtle)]">
                  {directoryListing()?.path ?? 'Loading…'}
                </span>
              </div>
              <div class="max-h-[32vh] overflow-y-auto p-1 scrollbar-thin">
                <Show when={!browserLoading()} fallback={<p class="px-3 py-4 text-xs text-[var(--text-subtle)]">Loading folders…</p>}>
                  <For
                    each={directoryListing()?.directories ?? []}
                    fallback={<p class="px-3 py-4 text-xs text-[var(--text-subtle)]">No subfolders.</p>}
                  >
                    {(directory) => (
                      <button
                        type="button"
                        class="flex w-full items-center gap-2 rounded-[5px] px-3 py-1.5 text-left text-[13px] hover:bg-[var(--accent-hover)]"
                        onClick={() => void browse(directory.path)}
                      >
                        <span class="text-[var(--accent)]">▸</span>
                        <span class="truncate">{directory.name}</span>
                      </button>
                    )}
                  </For>
                </Show>
              </div>
            </div>
          </Show>
          <Show when={browserError()}>
            <p class="mt-2 text-xs text-[var(--warning)]">{browserError()}</p>
          </Show>
          <Show when={store.notice()}>
            <p class="mt-2 text-xs text-[var(--warning)]">{store.notice()}</p>
          </Show>
          <div class="mt-4 flex justify-end gap-2">
            <button
              type="button"
              class="rounded-[7px] border border-[var(--border-muted)] px-4 py-2 text-[13px] hover:bg-[var(--accent-hover)]"
              disabled={submitting()}
              onClick={close}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="rounded-[7px] bg-[var(--accent)] px-4 py-2 text-[13px] text-white disabled:opacity-50"
              disabled={!path().trim() || submitting()}
            >
              {submitting() ? 'Adding…' : 'Add Workspace'}
            </button>
          </div>
        </form>
      </div>
    </Show>
  )
}

function Row(props: { label: string; value: string }) {
  return (
    <div class="flex items-center justify-between gap-4 border-b border-[var(--border-muted)] py-2">
      <dt class="text-[var(--text-subtle)]">{props.label}</dt>
      <dd class="mono min-w-0 break-words text-right text-[12px]">{props.value}</dd>
    </div>
  )
}
