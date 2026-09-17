import { Show, createEffect, createSignal, onCleanup } from 'solid-js'

/// Renders PDF bytes to canvases. iPhone Safari cannot display cookie-auth
/// PDFs in an iframe (its plugin refetches without the session and shows
/// the empty document icon), so the viewer paints pages itself.
export function PdfPages(props: { data: ArrayBuffer }) {
  const [error, setError] = createSignal<string | null>(null)
  let host: HTMLDivElement | undefined

  createEffect(() => {
    const data = props.data
    let cancelled = false
    setError(null)
    host?.replaceChildren()
    const run = async () => {
      try {
        const pdfjs = await import('pdfjs-dist')
        const worker = (await import('pdfjs-dist/build/pdf.worker.min.mjs?url')).default
        pdfjs.GlobalWorkerOptions.workerSrc = worker
        const task = pdfjs.getDocument({ data: new Uint8Array(data.slice(0)) })
        const pdf = await task.promise
        if (!host || cancelled) return
        const css_width = Math.max(host.clientWidth, 280)
        const pixel_width = Math.min(css_width * (window.devicePixelRatio || 1), 1600)
        for (let number = 1; number <= pdf.numPages; number += 1) {
          if (cancelled || !host) return
          const page = await pdf.getPage(number)
          const unscaled = page.getViewport({ scale: 1 })
          const viewport = page.getViewport({ scale: pixel_width / unscaled.width })
          const canvas = document.createElement('canvas')
          canvas.width = viewport.width
          canvas.height = viewport.height
          canvas.className = 'block w-full bg-white'
          host.appendChild(canvas)
          await page.render({ canvas, viewport }).promise
        }
      } catch (caught) {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : 'could not render pdf')
        }
      }
    }
    void run()
    onCleanup(() => {
      cancelled = true
      host?.replaceChildren()
    })
  })

  return (
    <div class="h-full overflow-y-auto scrollbar-thin">
      <Show when={error()}>
        {(message) => <p class="px-5 py-6 text-[13px] text-[var(--text-muted)]">{message()}</p>}
      </Show>
      <div ref={host} class="flex flex-col gap-2 p-2" />
    </div>
  )
}
