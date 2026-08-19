import { Match, Show, Switch, createResource, createSignal, onCleanup, onMount } from 'solid-js'
import { marked } from 'marked'

import { fileCitationName } from '../lib/citations'
import { officePreviewUrl, readToken, workspaceFileUrl } from '../lib/live'
import { Icon } from './Icons'

// Module-level signal so transcript rows can open the viewer without
// threading state through the pane tree (mirrors cardExpanded's approach).
const [viewerPath, setViewerPath] = createSignal<string | null>(null)

export function openFileViewer(path: string): void {
  setViewerPath(path)
}

/// Delegated click handler for markdown bodies: file-citation chips open the
/// in-app viewer instead of navigating to the raw gateway URL.
export function handleFileCitationClick(event: MouseEvent): void {
  const target = event.target as HTMLElement | null
  const anchor = target?.closest?.('a[data-verde-file]')
  const path = anchor?.getAttribute('data-verde-file')
  if (!path) return
  event.preventDefault()
  openFileViewer(path)
}

const IMAGE_EXTS = new Set(['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'svg'])
const MARKDOWN_EXTS = new Set(['md', 'markdown'])
// Previewed as PDFs converted by the gateway (LibreOffice headless); must
// match the allowlist in src/office_preview.zig.
const OFFICE_EXTS = new Set(['pptx', 'ppt', 'odp', 'docx', 'doc', 'odt', 'xlsx', 'xls', 'ods', 'rtf'])

function extOf(path: string): string {
  const name = fileCitationName(path)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

type Preview =
  | { kind: 'image' | 'pdf' | 'office' }
  | { kind: 'markdown' | 'text'; text: string }
  | { kind: 'none'; reason: string }

async function loadPreview(path: string): Promise<Preview> {
  const ext = extOf(path)
  // Images and PDFs render straight off the gateway URL (token in query, the
  // same pattern as chatImageUrl) — no need to pull the bytes twice.
  if (IMAGE_EXTS.has(ext)) return { kind: 'image' }
  if (ext === 'pdf') return { kind: 'pdf' }
  if (OFFICE_EXTS.has(ext)) {
    // Probe the conversion first so a failure surfaces as a readable message
    // instead of an error JSON rendered inside the PDF iframe. On success the
    // body is cancelled — the iframe re-request hits the gateway's cache.
    const token = readToken()
    const probe = await fetch(officePreviewUrl(path), {
      headers: token ? { 'x-verde-token': token } : {},
    })
    if (!probe.ok) {
      const payload = (await probe.json().catch(() => null)) as { error?: string } | null
      return {
        kind: 'none',
        reason: payload?.error?.replaceAll('_', ' ') ?? `could not convert document (${probe.status})`,
      }
    }
    void probe.body?.cancel()
    return { kind: 'office' }
  }
  const token = readToken()
  const response = await fetch(workspaceFileUrl(path), {
    headers: token ? { 'x-verde-token': token } : {},
  })
  if (!response.ok) {
    const payload = (await response.json().catch(() => null)) as { error?: string } | null
    return {
      kind: 'none',
      reason: payload?.error?.replaceAll('_', ' ') ?? `could not load file (${response.status})`,
    }
  }
  const text = await response.text()
  if (text.includes('\u0000')) return { kind: 'none', reason: 'No preview for binary files.' }
  return { kind: MARKDOWN_EXTS.has(ext) ? 'markdown' : 'text', text }
}

export function FileViewer() {
  const [preview] = createResource(viewerPath, loadPreview)
  const close = () => setViewerPath(null)

  onMount(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && viewerPath()) {
        event.stopPropagation()
        close()
      }
    }
    window.addEventListener('keydown', onKey, true)
    onCleanup(() => window.removeEventListener('keydown', onKey, true))
  })

  return (
    <Show when={viewerPath()}>
      {(path) => (
        <div class="fixed inset-0 z-40 bg-black/55" onClick={close}>
          <div
            class={`mx-auto mt-[6vh] flex h-[86vh] flex-col overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)] ${
              // PDFs and converted office docs get a wider stage: page-fit
              // zoom in a narrow dialog renders pages thumbnail-sized.
              extOf(path()) === 'pdf' || OFFICE_EXTS.has(extOf(path()))
                ? 'w-[min(1360px,calc(100vw-1.5rem))]'
                : 'w-[min(920px,calc(100vw-1.5rem))]'
            }`}
            onClick={(event) => event.stopPropagation()}
          >
            <header class="flex shrink-0 items-center gap-2 border-b border-[var(--border-muted)] px-4 py-2.5">
              <div class="min-w-0 flex-1">
                <div class="truncate text-[14px] font-medium">{fileCitationName(path())}</div>
                <div class="mono truncate text-[11px] text-[var(--text-subtle)]">{path()}</div>
              </div>
              <a
                class="shrink-0 rounded-[7px] border border-[var(--border-muted)] px-3 py-1.5 text-[12px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
                href={workspaceFileUrl(path(), true)}
                download={fileCitationName(path())}
              >
                Download
              </a>
              <button
                type="button"
                class="grid h-8 w-8 shrink-0 place-items-center rounded-[7px] text-[var(--text-muted)] hover:bg-[var(--accent-hover)] hover:text-[var(--text)]"
                onClick={close}
                aria-label="Close file viewer"
              >
                <Icon name="close" class="h-4 w-4" />
              </button>
            </header>
            <div class="min-h-0 flex-1 overflow-y-auto bg-[var(--chat-black)] scrollbar-thin">
              <Show
                when={!preview.loading}
                fallback={
                  <p class="px-5 py-6 text-[13px] text-[var(--text-subtle)]">
                    {OFFICE_EXTS.has(extOf(path())) ? 'Converting document for preview…' : 'Loading…'}
                  </p>
                }
              >
                <Switch>
                  <Match when={preview()?.kind === 'image'}>
                    <div class="grid h-full place-items-center p-4">
                      <img
                        src={workspaceFileUrl(path())}
                        alt={fileCitationName(path())}
                        class="max-h-full max-w-full rounded-[8px] object-contain"
                      />
                    </div>
                  </Match>
                  <Match when={preview()?.kind === 'pdf'}>
                    {/* PDF open parameters: start fully zoomed out at whole-
                        page fit instead of the viewer's fit-width default,
                        which crops tall print proofs. Chromium reads
                        view=Fit, Firefox's pdf.js reads zoom=page-fit, and
                        each ignores the other's parameter. The viewer's own
                        toolbar still handles zooming from there. */}
                    <iframe
                      src={`${workspaceFileUrl(path())}#view=Fit&zoom=page-fit`}
                      title={fileCitationName(path())}
                      class="h-full w-full border-0"
                    />
                  </Match>
                  <Match when={preview()?.kind === 'office'}>
                    <iframe
                      src={`${officePreviewUrl(path())}#view=Fit&zoom=page-fit`}
                      title={fileCitationName(path())}
                      class="h-full w-full border-0"
                    />
                  </Match>
                  <Match when={preview()?.kind === 'markdown'}>
                    <div
                      class="markdown px-5 py-4"
                      innerHTML={marked.parse((preview() as { text: string }).text, { async: false }) as string}
                    />
                  </Match>
                  <Match when={preview()?.kind === 'text'}>
                    <pre class="mono max-w-full whitespace-pre-wrap break-words px-5 py-4 text-[12.5px] leading-[1.5] text-[var(--text-muted)]">
                      {(preview() as { text: string }).text}
                    </pre>
                  </Match>
                  <Match when={preview()?.kind === 'none'}>
                    <div class="grid h-full place-items-center p-6 text-center">
                      <div>
                        <p class="text-[14px] text-[var(--text-muted)]">
                          {(preview() as { reason: string }).reason}
                        </p>
                        <a
                          class="mt-3 inline-block rounded-[7px] bg-[var(--accent)] px-4 py-2 text-[13px] text-[#06210f]"
                          href={workspaceFileUrl(path(), true)}
                          download={fileCitationName(path())}
                        >
                          Download file
                        </a>
                      </div>
                    </div>
                  </Match>
                </Switch>
              </Show>
            </div>
          </div>
        </div>
      )}
    </Show>
  )
}
