/**
 * Files view of the side panel (a lazily expanded tree over the workspace's
 * folders) and the read-only viewer it opens. Everything is read through the
 * daemon's `workspace.files.*` RPCs, addressed as `(root id, root-relative
 * path)`; selecting lines in a code view opens an inspector-style prompt that
 * messages one of the workspace's chats.
 */
import { For, Match, Show, Switch, batch, createEffect, createMemo, createResource, createSignal, on, onCleanup, onMount } from 'solid-js'

import { workspaceFileUrl, unwrapResult } from '../lib/live'
import { renderMarkdown } from '../lib/markdown'
import { store } from '../lib/store'
import { type LivePane, isSubagentThreadId } from '../lib/types'
import { rpcFailure } from '../lib/workspace_changes'
import {
  type FileEntry, type FileRead, type FilesRoot, type LineSelection,
  MAX_SELECTION_BYTES, READ_MAX_IMAGE_BYTES, READ_MAX_TEXT_BYTES,
  absolutePath, filesErrorText, formatSize, highlightLines, imageObjectUrl, languageForPath, lineRange,
  locateInRoots, parseFileRead, parseFilesListing, rootPath, selectedText, selectionPrompt,
} from '../lib/workspace_files'
import type { DiffSide } from '../lib/diff_lines'
import { PanelMessage } from './PanelMessage'
import { openFileViewer } from './FileViewer'
import { Icon, Spinner } from './Icons'

// ---- Shared listing cache ------------------------------------------------------

type Listing = { status: 'loading' | 'ready' | 'error'; entries: FileEntry[]; truncated: boolean; error?: string }

/// Lists `path` under `root`, or only the roots when `root` is null.
async function listFiles(workspace_id: string, root: string | null, path = '') {
  const response = await store.workspaceCall('workspace.files.list', root ? { workspace_id, root, path } : { workspace_id })
  const failure = rpcFailure(response)
  const listing = failure ? null : parseFilesListing(unwrapResult(response))
  if (!listing) throw new Error(filesErrorText(failure?.code, failure?.message))
  return listing
}

// Roots per workspace for display paths (the viewer may open from Changes
// before the tree has loaded).
const rootsCache = new Map<string, Promise<FilesRoot[]>>()
function workspaceRoots(workspace_id: string): Promise<FilesRoot[]> {
  let roots = rootsCache.get(workspace_id)
  if (!roots) {
    roots = listFiles(workspace_id, null).then((listing) => listing.roots)
    roots.catch(() => rootsCache.delete(workspace_id))
    rootsCache.set(workspace_id, roots)
  }
  return roots
}
// Expanded folders (node keys) per workspace for this page session.
const expandedByWorkspace = new Map<string, Set<string>>()

/// Tree node key: root id and root-relative path ("" for the root itself).
const nodeKey = (root: string, path: string): string => `${root}\u0000${path}`
const splitKey = (key: string): { root: string; path: string } => {
  const cut = key.indexOf('\u0000')
  return { root: key.slice(0, cut), path: key.slice(cut + 1) }
}

// ---- Tree --------------------------------------------------------------------------

export function FilesView(props: { workspaceId: string }) {
  const [roots, setRoots] = createSignal<FilesRoot[] | null>(null)
  const [rootError, setRootError] = createSignal('')
  const [listings, setListings] = createSignal<Record<string, Listing>>({})
  const [expanded, setExpandedSignal] = createSignal<ReadonlySet<string>>(new Set())
  let generation = 0

  const setExpanded = (next: Set<string>) => { expandedByWorkspace.set(props.workspaceId, next); setExpandedSignal(next) }

  const loadDir = async (key: string) => {
    const gen = generation
    const { root, path } = splitKey(key)
    setListings((all) => ({ ...all, [key]: { status: 'loading', entries: all[key]?.entries ?? [], truncated: false } }))
    try {
      const listing = await listFiles(props.workspaceId, root, path)
      if (gen !== generation) return
      setListings((all) => ({ ...all, [key]: { status: 'ready', entries: listing.entries, truncated: listing.truncated } }))
    } catch (err) {
      if (gen !== generation) return
      setListings((all) => ({ ...all, [key]: { status: 'error', entries: [], truncated: false, error: err instanceof Error ? err.message : String(err) } }))
    }
  }

  const loadRoots = async () => {
    const gen = ++generation
    rootsCache.delete(props.workspaceId)
    batch(() => { setRoots(null); setRootError(''); setListings({}) })
    try {
      const next = await workspaceRoots(props.workspaceId)
      if (gen !== generation) return
      const remembered = expandedByWorkspace.get(props.workspaceId)
      // A single root starts open; several start collapsed.
      const ids = new Set(next.map((root) => root.id))
      const open = [...(remembered ?? (next.length === 1 ? [nodeKey(next[0].id, '')] : []))].filter((key) => ids.has(splitKey(key).root))
      batch(() => { setRoots(next); setExpanded(new Set(open)) })
      for (const key of open) void loadDir(key)
    } catch (err) {
      if (gen !== generation) return
      setRootError(err instanceof Error ? err.message : String(err))
    }
  }

  const toggleDir = (key: string) => {
    const next = new Set(expanded())
    if (next.has(key)) {
      // Collapsing forgets descendants so a re-open starts tidy.
      const prefix = splitKey(key).path ? `${key}/` : key
      for (const item of [...next]) if (item === key || item.startsWith(prefix)) next.delete(item)
      setExpanded(next)
      return
    }
    next.add(key)
    setExpanded(next)
    const listing = listings()[key]
    if (!listing || listing.status === 'error') void loadDir(key)
  }

  /// Re-reads every open folder (new files, changed ignore state).
  const refresh = () => {
    generation += 1
    for (const key of expanded()) void loadDir(key)
  }

  createEffect(on(() => props.workspaceId, () => void loadRoots()))

  return (
    <div class="flex h-full min-h-0 flex-col">
      <div class="flex shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-3 py-2">
        <div class="min-w-0 flex-1 truncate text-[12px] text-[var(--text-muted)]">{store.workspace()?.label ?? 'Workspace'}</div>
        <button
          type="button"
          class="grid h-7 w-7 shrink-0 place-items-center rounded-[6px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
          aria-label="Refresh files"
          title="Refresh"
          onClick={() => (roots() ? refresh() : void loadRoots())}
        >
          <Icon name="refresh" class="h-4 w-4" />
        </button>
      </div>
      <div role="tree" aria-label="Workspace files" class="min-h-0 flex-1 overflow-auto py-1 scrollbar-thin">
        <Show when={roots()} fallback={<PanelMessage text={rootError() || 'Loading files…'} action={rootError() ? { label: 'Retry', run: () => void loadRoots() } : undefined} />}>
          {(list) => (
            <Show when={list().length > 0} fallback={<PanelMessage text="This workspace has no folders." />}>
              <For each={list()}>
                {(root) => (
                  <TreeNode
                    rootId={root.id}
                    entry={{ name: root.name, path: '', kind: 'directory', size: 0, ignored: false, symlink: false }}
                    title={root.path}
                    depth={0}
                    expanded={expanded()}
                    listings={listings()}
                    onToggle={toggleDir}
                    onOpen={(path) => openWorkspaceFile(props.workspaceId, root.id, path)}
                    onRetry={(key) => void loadDir(key)}
                  />
                )}
              </For>
            </Show>
          )}
        </Show>
      </div>
    </div>
  )
}

function TreeNode(props: {
  rootId: string
  entry: FileEntry
  title?: string
  depth: number
  expanded: ReadonlySet<string>
  listings: Record<string, Listing>
  onToggle: (key: string) => void
  /// Root-relative file path.
  onOpen: (path: string) => void
  onRetry: (key: string) => void
}) {
  const key = () => nodeKey(props.rootId, props.entry.path)
  const dir = () => props.entry.kind === 'directory'
  const open = () => dir() && props.expanded.has(key())
  const listing = () => props.listings[key()]
  const indent = () => ({ 'padding-left': `${8 + props.depth * 14}px` })
  return (
    <div role="treeitem" aria-expanded={dir() ? open() : undefined}>
      <button
        type="button"
        class={`files-row ${props.entry.ignored ? 'files-row-ignored' : ''} ${props.depth === 0 ? 'font-medium' : ''}`}
        style={indent()}
        title={props.title ?? props.entry.path}
        onClick={() => (dir() ? props.onToggle(key()) : props.onOpen(props.entry.path))}
      >
        <Show when={dir()} fallback={<span class="w-3.5 shrink-0" />}>
          <Icon name={open() ? 'chevronDown' : 'chevron'} class="h-3.5 w-3.5 shrink-0 text-[var(--text-subtle)]" />
        </Show>
        <Icon name={dir() ? 'folder' : 'file'} class={`h-3.5 w-3.5 shrink-0 ${dir() ? 'text-[var(--accent)]' : 'text-[var(--text-subtle)]'}`} />
        <span class="min-w-0 flex-1 truncate">{props.entry.name}</span>
        <Show when={props.entry.symlink}><span class="shrink-0 text-[10.5px] text-[var(--text-subtle)]" title="Symbolic link">↪</span></Show>
        <Show when={open() && listing()?.status === 'loading'}><Spinner class="h-3 w-3 shrink-0" /></Show>
      </button>
      <Show when={open() && listing()}>
        {(current) => (
          <div role="group">
            <Show when={current().status === 'error'}>
              <div class="flex items-center gap-2 py-1 pr-3 text-[12px] text-[var(--danger)]" style={{ 'padding-left': `${30 + props.depth * 14}px` }}>
                <span class="min-w-0 flex-1 truncate">{current().error}</span>
                <button type="button" class="underline" onClick={() => props.onRetry(key())}>Retry</button>
              </div>
            </Show>
            <Show when={current().status === 'ready' && current().entries.length === 0}>
              <div class="py-1 text-[12px] text-[var(--text-subtle)]" style={{ 'padding-left': `${30 + props.depth * 14}px` }}>Empty folder</div>
            </Show>
            <For each={current().entries}>
              {(child) => (
                <TreeNode
                  rootId={props.rootId}
                  entry={child}
                  depth={props.depth + 1}
                  expanded={props.expanded}
                  listings={props.listings}
                  onToggle={props.onToggle}
                  onOpen={props.onOpen}
                  onRetry={props.onRetry}
                />
              )}
            </For>
            <Show when={current().truncated}>
              <div class="py-1 text-[12px] text-[var(--warning)]" style={{ 'padding-left': `${30 + props.depth * 14}px` }}>Folder too large; some entries are not shown.</div>
            </Show>
          </div>
        )}
      </Show>
    </div>
  )
}

// ---- Viewer --------------------------------------------------------------------------

type ViewerTarget = { workspace_id: string; root: string; path: string }
const [viewerTarget, setViewerTarget] = createSignal<ViewerTarget | null>(null)
export const workspaceFileViewerOpen = () => viewerTarget() != null

/// Opens `path` (relative to root `root`) in the read-only viewer.
export function openWorkspaceFile(workspace_id: string, root: string, path: string): void {
  setViewerTarget({ workspace_id, root, path })
}

/// Opens a daemon-absolute path (a repository file from Changes) through the
/// workspace root that contains it; outside every root, the confined
/// /api/file preview is the fallback.
export async function openWorkspacePath(workspace_id: string, absolute: string): Promise<void> {
  const roots = await workspaceRoots(workspace_id).catch(() => [] as FilesRoot[])
  const located = locateInRoots(absolute, roots)
  if (located) openWorkspaceFile(workspace_id, located.root, located.path)
  else if (absolute.startsWith('/')) openFileViewer(absolute)
  else store.setNotice('This file is outside the workspace folders.')
}

type Loaded = { read: FileRead; root: FilesRoot | null; roots: FilesRoot[]; image_url: string | null } | { error: string }

async function loadRead(target: ViewerTarget): Promise<Loaded> {
  try {
    const [response, roots] = await Promise.all([
      store.workspaceCall('workspace.files.read', {
        workspace_id: target.workspace_id, root: target.root, path: target.path,
        max_bytes: READ_MAX_TEXT_BYTES, max_image_bytes: READ_MAX_IMAGE_BYTES,
      }),
      workspaceRoots(target.workspace_id).catch(() => [] as FilesRoot[]),
    ])
    const failure = rpcFailure(response)
    const read = failure ? null : parseFileRead(unwrapResult(response))
    if (!read) return { error: filesErrorText(failure?.code, failure?.message) }
    const root = roots.find((item) => item.id === target.root) ?? null
    return { read, root, roots, image_url: read.kind === 'image' ? imageObjectUrl(read) : null }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Could not read the file.' }
  }
}

/// Modal viewer mounted once at the app root.
export function WorkspaceFileViewer() {
  const [loaded] = createResource(viewerTarget, loadRead)
  const [mode, setMode] = createSignal<'preview' | 'source'>('preview')
  const [sent, setSent] = createSignal<string | null>(null)
  const close = () => setViewerTarget(null)

  createEffect(on(viewerTarget, () => { setMode('preview'); setSent(null) }))
  createEffect(() => {
    const current = loaded()
    onCleanup(() => { if (current && 'image_url' in current && current.image_url) URL.revokeObjectURL(current.image_url) })
  })
  createEffect(() => {
    if (!sent()) return
    const timer = setTimeout(() => setSent(null), 3000)
    onCleanup(() => clearTimeout(timer))
  })

  onMount(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || !viewerTarget()) return
      // Escape in the line prompt closes only the prompt.
      if (event.target instanceof Element && event.target.closest('.line-prompt')) return
      event.stopPropagation()
      close()
    }
    window.addEventListener('keydown', onKey, true)
    onCleanup(() => window.removeEventListener('keydown', onKey, true))
  })

  const read = () => { const value = loaded(); return value && 'read' in value ? value.read : null }
  /// Daemon-host absolute path for the /api/file fallback; null until the
  /// roots are known.
  const absolute = () => {
    const value = loaded()
    const target = viewerTarget()
    return target && value && 'root' in value && value.root ? absolutePath(value.root, target.path) : null
  }
  const shownPath = () => {
    const target = viewerTarget()
    if (!target) return ''
    const value = loaded()
    // Root ids of extra folders are their names, so the id stands in until the roots load.
    const root = value && 'root' in value && value.root ? value.root : { id: target.root, name: target.root }
    return rootPath(root, target.path)
  }

  return (
    <Show when={viewerTarget()}>
      {(target) => (
        <div class="anim-fade fixed inset-0 z-40 bg-black/55" onClick={close}>
          <div
            class="anim-pop mx-auto flex h-full w-full flex-col overflow-hidden bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)] pt-[var(--safe-top)] md:mt-[5vh] md:h-[90vh] md:w-[min(1100px,calc(100vw-1.5rem))] md:rounded-[10px] md:border md:border-[var(--border-muted)] md:pt-0"
            onClick={(event) => event.stopPropagation()}
            role="dialog"
            aria-modal="true"
            aria-label={`File ${shownPath()}`}
          >
            <header class="flex shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-4 py-2.5">
              <div class="min-w-0 flex-1">
                <div class="truncate text-[14px] font-medium">{read()?.name ?? target().path.split('/').at(-1)}</div>
                <div class="mono truncate text-[11px] text-[var(--text-subtle)]" title={absolute() ?? shownPath()}>
                  {shownPath()}
                  <Show when={read()}>{(file) => <> · {formatSize(file().size)}</>}</Show>
                </div>
              </div>
              <Show when={sent()}>
                {(text) => <span role="status" class="hidden shrink-0 text-[12px] text-[var(--accent)] sm:inline">{text()}</span>}
              </Show>
              <Show when={read()?.kind === 'markdown'}>
                <div role="group" aria-label="Markdown view" class="flex shrink-0 overflow-hidden rounded-[6px] bg-[var(--panel-muted)] text-[11px]">
                  <For each={['preview', 'source'] as const}>
                    {(value) => (
                      <button
                        type="button"
                        aria-pressed={mode() === value}
                        class={`px-2.5 py-1 capitalize ${mode() === value ? 'bg-[var(--accent-wash)] text-[var(--text)]' : 'text-[var(--text-muted)] hover:text-[var(--text)]'}`}
                        onClick={() => setMode(value)}
                      >{value}</button>
                    )}
                  </For>
                </div>
              </Show>
              <Show when={read() && (completeContent(read()!) || absolute())}>
                <button
                  type="button"
                  class="shrink-0 rounded-[7px] border border-[var(--border-muted)] px-3 py-1.5 text-[12px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
                  onClick={() => downloadFile(read()!, absolute())}
                >
                  Download
                </button>
              </Show>
              <button
                type="button"
                class="grid h-8 w-8 shrink-0 place-items-center rounded-[7px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
                onClick={close}
                aria-label="Close file viewer"
              >
                <Icon name="close" class="h-4 w-4" />
              </button>
            </header>
            <div class="relative min-h-0 flex-1 overflow-hidden bg-[var(--chat-black)]">
              <Show when={!loaded.loading} fallback={<p class="px-5 py-6 text-[13px] text-[var(--text-subtle)]">Loading…</p>}>
                <Show when={read()} fallback={<PanelMessage text={(loaded() as { error?: string } | undefined)?.error ?? 'Could not read the file.'} />}>
                  {(file) => (
                    <Switch fallback={<ExternalFile read={file()} path={absolute()} />}>
                      <Match when={file().kind === 'image'}>
                        <Show when={(loaded() as { image_url: string | null }).image_url} fallback={<ExternalFile read={file()} path={absolute()} />}>
                          {(url) => (
                            <div class="grid h-full place-items-center overflow-auto p-4">
                              <img src={url()} alt={file().name} class="max-h-full max-w-full rounded-[8px] bg-white object-contain" />
                            </div>
                          )}
                        </Show>
                      </Match>
                      <Match when={file().kind === 'markdown' && mode() === 'preview'}>
                        <div class="h-full overflow-y-auto scrollbar-thin">
                          <Truncated read={file()} />
                          <div class="markdown px-5 py-4" innerHTML={renderMarkdown(file().content)} />
                        </div>
                      </Match>
                      <Match when={file().kind === 'text' || file().kind === 'markdown'}>
                        <CodeView
                          read={file()}
                          workspaceId={target().workspace_id}
                          displayPath={shownPath()}
                          onSent={(chat) => setSent(`Sent to ${chat}`)}
                        />
                      </Match>
                    </Switch>
                  )}
                </Show>
              </Show>
            </div>
          </div>
        </div>
      )}
    </Show>
  )
}

/// The whole file came back in the read (not truncated, not metadata-only).
const completeContent = (read: FileRead): boolean => read.encoding !== 'none' && !read.truncated

/// Saves the loaded bytes; files the read did not return in full fall back
/// to the confined /api/file download.
function downloadFile(read: FileRead, absolute: string | null): void {
  let url: string | null = null
  if (completeContent(read)) {
    url = read.encoding === 'base64' ? imageObjectUrl({ ...read, mime: 'application/octet-stream' }) : URL.createObjectURL(new Blob([read.content], { type: 'text/plain;charset=utf-8' }))
  }
  const link = document.createElement('a')
  link.href = url ?? (absolute ? workspaceFileUrl(absolute, true) : '')
  if (!link.href) return
  link.download = read.name
  link.click()
  if (url) setTimeout(() => URL.revokeObjectURL(url), 30_000)
}

function Truncated(props: { read: FileRead }) {
  return (
    <Show when={props.read.truncated}>
      <p class="border-b border-[var(--border-muted)] px-5 py-2 text-[12px] text-[var(--warning)]">
        Showing the first part of this {formatSize(props.read.size)} file.
      </p>
    </Show>
  )
}

const PREVIEWABLE = /\.(pdf|pptx?|odp|docx?|odt|xlsx?|ods|rtf|svg|png|jpe?g|gif|webp|bmp)$/i

/// No inline preview. `path` is the daemon-absolute path for the confined
/// /api/file preview and download; null when the roots could not be loaded.
function ExternalFile(props: { read: FileRead; path: string | null }) {
  const reason = () => {
    switch (props.read.kind) {
      case 'too_large': return `This image is too large to show inline (${formatSize(props.read.size)}).`
      case 'binary': return 'Binary file — no preview.'
      default: return 'This file type opens in a document preview.'
    }
  }
  return (
    <div class="grid h-full place-items-center p-6 text-center">
      <div>
        <p class="text-[14px] text-[var(--text-muted)]">{reason()}</p>
        <div class="mt-3 flex justify-center gap-2">
          <Show when={props.path && PREVIEWABLE.test(props.path) ? props.path : null}>
            {(path) => (
              <button
                type="button"
                class="rounded-[7px] bg-[var(--accent)] px-4 py-2 text-[13px] text-[#06210f]"
                onClick={() => { const full = path(); setViewerTarget(null); openFileViewer(full) }}
              >
                Open preview
              </button>
            )}
          </Show>
          <Show when={props.path}>
            {(path) => (
              <a
                class="rounded-[7px] border border-[var(--border-muted)] px-4 py-2 text-[13px] text-[var(--text)] hover:bg-[var(--accent-hover)]"
                href={workspaceFileUrl(path(), true)}
                download={props.read.name}
              >
                Download
              </a>
            )}
          </Show>
        </div>
      </div>
    </div>
  )
}

// ---- Code view with line prompts ------------------------------------------------------

const CODE_WINDOW_LINES = 5000

function CodeView(props: {
  read: FileRead
  workspaceId: string
  /// Root path (`src/a.ts`, `<folder>/a.ts`): shown and sent to chats.
  displayPath: string
  onSent: (chat: string) => void
}) {
  const lang = () => languageForPath(props.read.path)
  const lines = createMemo(() => highlightLines(props.read.content, lang()))
  const [showAll, setShowAll] = createSignal(false)
  const visible = createMemo(() => (showAll() ? lines() : lines().slice(0, CODE_WINDOW_LINES)))
  const [selection, setSelection] = createSignal<(LineSelection & { text: string }) | null>(null)
  const [drag, setDrag] = createSignal<{ anchor: number } | null>(null)
  let anchor: number | null = null
  let container: HTMLDivElement | undefined

  const selectLines = (range: LineSelection, text?: string) =>
    setSelection({ ...range, text: text ?? selectedText(props.read.content, range) })

  const onGutterDown = (event: PointerEvent, line: number) => {
    event.preventDefault()
    if (event.shiftKey && anchor != null) { selectLines(lineRange(anchor, line)); return }
    anchor = line
    setDrag({ anchor: line })
    selectLines({ start: line, end: line })
  }
  const onLineEnter = (line: number) => {
    const current = drag()
    if (current) selectLines(lineRange(current.anchor, line))
  }
  // A mouse text selection is read once the button is released, so the
  // prompt never takes focus (collapsing the selection) mid-drag.
  let pressed = false
  onMount(() => {
    const down = (event: PointerEvent) => {
      const target = event.target instanceof Element ? event.target : null
      pressed = !!target && !!container?.contains(target) && !target.closest('.line-prompt')
    }
    const up = () => {
      const was_text = pressed && !drag()
      pressed = false
      setDrag(null)
      if (was_text) captureTextSelection()
    }
    window.addEventListener('pointerdown', down, true)
    window.addEventListener('pointerup', up)
    onCleanup(() => { window.removeEventListener('pointerdown', down, true); window.removeEventListener('pointerup', up) })
  })

  /// A text selection inside the code becomes a line selection with exactly
  /// the selected text (desktop inspector parity).
  const captureTextSelection = () => {
    const picked = window.getSelection()
    if (!picked || picked.isCollapsed || !container) return
    const lineOf = (node: Node | null) => {
      const element = node instanceof Element ? node : node?.parentElement
      const row = element?.closest<HTMLElement>('[data-line]')
      return row && container!.contains(row) ? Number(row.dataset.line) : null
    }
    const a = lineOf(picked.anchorNode)
    const b = lineOf(picked.focusNode)
    if (a == null || b == null) return
    const text = picked.toString()
    if (!text.trim()) return
    anchor = a
    selectLines(lineRange(a, b), text.replace(/\n$/, ''))
  }
  let selectionTimer: ReturnType<typeof setTimeout> | undefined
  onMount(() => {
    // Touch selections finish without a pointerup on the text; settle first.
    const onChange = () => { clearTimeout(selectionTimer); selectionTimer = setTimeout(() => { if (!drag() && !pressed) captureTextSelection() }, 350) }
    document.addEventListener('selectionchange', onChange)
    onCleanup(() => { clearTimeout(selectionTimer); document.removeEventListener('selectionchange', onChange) })
  })

  const selected = (line: number) => { const range = selection(); return !!range && line >= range.start && line <= range.end }
  const boxTop = () => {
    const range = selection()
    if (!range || !container) return 0
    const row = container.querySelector<HTMLElement>(`[data-line="${range.end}"]`)
    return row ? row.offsetTop + row.offsetHeight + 4 : 0
  }

  return (
    <div class="h-full overflow-auto scrollbar-thin" ref={(node) => { container = node }}>
      <Truncated read={props.read} />
      <div class="relative min-w-max pb-4">
        <div class="mono code-view text-[12.5px] leading-[1.5]" classList={{ 'select-none': !!drag() }}>
          <For each={visible()}>
            {(tokens, index) => {
              const line = index() + 1
              return (
                <div class="code-line" data-line={line} classList={{ 'code-line-selected': selected(line) }} onPointerEnter={() => onLineEnter(line)}>
                  <span
                    class="code-no"
                    role="button"
                    aria-label={`Select line ${line}`}
                    onPointerDown={(event) => onGutterDown(event, line)}
                  >{line}</span>
                  <span class="code-text">
                    <For each={tokens}>{(token) => (token.cls ? <span class={token.cls}>{token.text}</span> : token.text)}</For>
                    {tokens.length === 0 ? ' ' : ''}
                  </span>
                </div>
              )
            }}
          </For>
        </div>
        <Show when={!showAll() && lines().length > CODE_WINDOW_LINES}>
          <button type="button" class="diff-show-all" onClick={() => setShowAll(true)}>
            Showing {CODE_WINDOW_LINES.toLocaleString()} of {lines().length.toLocaleString()} lines · Show all
          </button>
        </Show>
        <Show when={selection() && !drag() ? selection() : null} keyed>
          {(range) => (
            <LinePrompt
              top={boxTop()}
              range={range}
              workspaceId={props.workspaceId}
              displayPath={props.displayPath}
              onClose={() => setSelection(null)}
              onSent={(chat) => { setSelection(null); window.getSelection()?.removeAllRanges(); props.onSent(chat) }}
            />
          )}
        </Show>
      </div>
    </div>
  )
}

/// Inspector-style "ask a chat about these lines" box. Floats below the
/// selection when `top` is given, else sits inline (Changes diffs).
export function LinePrompt(props: {
  top?: number
  range: LineSelection & { text: string }
  /// Diff selections name their side in the message.
  side?: DiffSide
  workspaceId: string
  /// Workspace path shown and sent (`src/a.ts`, `<folder>/a.ts`).
  displayPath: string
  onClose: () => void
  onSent: (chat: string) => void
}) {
  const chats = createMemo(() => store.openPanes().filter((pane): pane is LivePane & { thread_id: string } =>
    pane.kind === 'chat' && !!pane.thread_id && !isSubagentThreadId(pane.thread_id) && pane.workspace_id === props.workspaceId))
  const initial = () => {
    const focused = store.focusedChat()
    return chats().find((pane) => pane.pane_id === focused?.pane_id) ?? chats()[0] ?? null
  }
  const [paneId, setPaneId] = createSignal<number | null>(initial()?.pane_id ?? null)
  const target = () => chats().find((pane) => pane.pane_id === paneId()) ?? initial()
  const [text, setText] = createSignal('')
  const [busy, setBusy] = createSignal(false)
  const [error, setError] = createSignal('')
  let field: HTMLTextAreaElement | undefined

  onMount(() => queueMicrotask(() => field?.focus({ preventScroll: true })))

  const lines = () => (props.range.start === props.range.end ? `Line ${props.range.start}` : `Lines ${props.range.start}–${props.range.end}`)
  const send = async () => {
    const pane = target()
    if (!pane || !text().trim() || busy()) return
    const message = selectionPrompt({
      path: props.displayPath, roots: [], start_line: props.range.start, end_line: props.range.end, side: props.side ?? null,
      text: props.range.text, instruction: text(),
    })
    if (!message) { setError(`Select at most ${formatSize(MAX_SELECTION_BYTES)} and keep the question short.`); return }
    setError('')
    setBusy(true)
    const ok = await store.sendPromptTo(pane, message)
    setBusy(false)
    if (ok) props.onSent(store.paneTitle(pane))
  }

  return (
    <div
      class="line-prompt anim-reveal"
      classList={{ 'line-prompt-inline': props.top == null }}
      style={props.top == null ? undefined : { top: `${props.top}px` }}
      onPointerDown={(event) => event.stopPropagation()}
      onKeyDown={(event) => {
        if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); props.onClose() }
      }}
    >
      <div class="flex items-center gap-2 text-[11.5px] text-[var(--text-subtle)]">
        <span class="mono shrink-0 text-[var(--text-muted)]">{lines()}{props.side ? ` · ${props.side}` : ''}</span>
        <span class="min-w-0 flex-1 truncate">{props.displayPath}</span>
        <button type="button" class="grid h-6 w-6 place-items-center rounded-[5px] hover:bg-[var(--accent-hover)]" aria-label="Close prompt" onClick={() => props.onClose()}>
          <Icon name="close" class="h-3.5 w-3.5" />
        </button>
      </div>
      <Show
        when={chats().length > 0}
        fallback={<p class="py-2 text-[12.5px] text-[var(--text-muted)]">Open a chat in this workspace to ask about these lines.</p>}
      >
        <textarea
          ref={(node) => { field = node }}
          class="mt-1.5 block max-h-40 min-h-[3.25rem] w-full resize-y rounded-[7px] border border-[var(--border-muted)] bg-[var(--chat-black)] px-2.5 py-2 text-[13px] text-[var(--text)] outline-none focus:border-[var(--accent)]"
          placeholder={`Ask ${target() ? store.paneTitle(target()!) : 'the chat'} about ${lines().toLowerCase()}…`}
          value={text()}
          onInput={(event) => { setText(event.currentTarget.value); setError('') }}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) { event.preventDefault(); void send() }
          }}
        />
        <Show when={error()}>{(message) => <p role="alert" class="mt-1.5 text-[12px] text-[var(--danger)]">{message()}</p>}</Show>
        <div class="mt-2 flex items-center gap-2">
          <Show
            when={chats().length > 1}
            fallback={<span class="min-w-0 flex-1 truncate text-[12px] text-[var(--text-muted)]">to {target() ? store.paneTitle(target()!) : ''}</span>}
          >
            <select
              class="min-w-0 flex-1 truncate rounded-[6px] border border-[var(--border-muted)] bg-[var(--panel)] px-2 py-1 text-[12px] text-[var(--text)]"
              aria-label="Chat to send to"
              value={String(target()?.pane_id ?? '')}
              onChange={(event) => setPaneId(Number(event.currentTarget.value))}
            >
              <For each={chats()}>{(pane) => <option value={String(pane.pane_id)}>{store.paneTitle(pane)}</option>}</For>
            </select>
          </Show>
          <button
            type="button"
            class="flex h-7 shrink-0 items-center gap-1.5 rounded-[6px] bg-[var(--accent)] px-3 text-[12px] font-medium text-[#06210f] disabled:opacity-50"
            disabled={!text().trim() || busy()}
            onClick={() => void send()}
          >
            <Show when={busy()} fallback={<Icon name="send" class="h-3.5 w-3.5" />}><Spinner class="h-3.5 w-3.5" /></Show>
            Send
          </button>
        </div>
      </Show>
    </div>
  )
}
