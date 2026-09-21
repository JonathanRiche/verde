import { Match, Show, Switch, createEffect, createResource, createSignal, onCleanup, onMount } from 'solid-js'

import { fileCitationName, filePathFromHref } from '../lib/citations'
import { isOfficePreviewPath, loadFilePreview, revokeFilePreview } from '../lib/file_preview'
import { workspaceFileUrl } from '../lib/live'
import { renderMarkdown } from '../lib/markdown'
import { Icon } from './Icons'
import { PdfPages } from './PdfPages'

// Module-level signal so transcript rows can open the viewer without
// threading state through the pane tree.
const [viewerPath, setViewerPath] = createSignal<string | null>(null)

export function openFileViewer(path: string): void {
  setViewerPath(path)
}

/// Delegated click handler for markdown bodies: file chips and absolute
/// workspace links open the in-app viewer instead of a JSON 404 page.
export function handleFileCitationClick(event: MouseEvent): void {
  const target = event.target as HTMLElement | null
  const anchor = target?.closest?.('a')
  if (!anchor || event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
    return
  }
  const path = filePathFromHref(anchor.getAttribute('href'))
  if (!path) return
  event.preventDefault()
  openFileViewer(path)
}

export function FileViewer() {
  const [preview] = createResource(viewerPath, loadFilePreview)
  const close = () => setViewerPath(null)

  createEffect(() => {
    const current = preview()
    onCleanup(() => revokeFilePreview(current))
  })

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
        <div class="anim-fade fixed inset-0 z-40 bg-black/55" onClick={close}>
          <div
            class={`anim-pop mx-auto mt-[6vh] flex h-[86vh] flex-col overflow-hidden rounded-[10px] border border-[var(--border-muted)] bg-[var(--panel)] shadow-[0_24px_80px_rgba(0,0,0,0.55)] ${
              extLooksWide(path())
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
            <div class="relative min-h-0 flex-1 overflow-hidden bg-[var(--chat-black)]">
              <Show
                when={!preview.loading}
                fallback={
                  <p class="px-5 py-6 text-[13px] text-[var(--text-subtle)]">
                    {isOfficePreviewPath(path()) ? 'Converting document for preview…' : 'Loading…'}
                  </p>
                }
              >
                <Switch>
                  <Match when={preview()?.kind === 'image'}>
                    <div class="grid h-full place-items-center p-4">
                      <img
                        src={(preview() as { url: string }).url}
                        alt={fileCitationName(path())}
                        class="max-h-full max-w-full rounded-[8px] object-contain"
                      />
                    </div>
                  </Match>
                  <Match when={preview()?.kind === 'pdf' || preview()?.kind === 'office'}>
                    <PdfPages data={(preview() as { data: ArrayBuffer }).data} />
                  </Match>
                  <Match when={preview()?.kind === 'markdown'}>
                    <div class="h-full overflow-y-auto scrollbar-thin">
                      <div
                        class="markdown px-5 py-4"
                        innerHTML={renderMarkdown((preview() as { text: string }).text)}
                      />
                    </div>
                  </Match>
                  <Match when={preview()?.kind === 'text'}>
                    <pre class="mono h-full max-w-full overflow-y-auto whitespace-pre-wrap break-words px-5 py-4 text-[12.5px] leading-[1.5] text-[var(--text-muted)] scrollbar-thin">
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

function extLooksWide(path: string): boolean {
  return path.toLowerCase().endsWith('.pdf') || isOfficePreviewPath(path)
}
