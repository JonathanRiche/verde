import { createFileRoute, notFound } from '@tanstack/solid-router'
import { onCleanup, onMount } from 'solid-js'

import DocsLayout from '../../components/DocsLayout'
import {
  SITE_ORIGIN,
  getDoc,
  getRawMarkdown,
  renderMarkdown,
} from '../../content/docs'

export const Route = createFileRoute('/docs/$slug')({
  head: ({ params }) => {
    // `/docs/<slug>.md` is the raw-markdown mirror of the same doc; serve
    // it from the GET handler below with `text/markdown` and skip the page.
    const pageSlug = params.slug.replace(/\.md$/, '')
    const isMarkdown = params.slug.endsWith('.md')
    if (isMarkdown) {
      // Raw mirror — no HTML head metadata, robots already point to the HTML page.
      return { meta: [{ name: 'robots', content: 'noindex' }] }
    }
    const doc = getDoc(pageSlug)
    if (!doc) {
      return {
        meta: [
          { title: 'Page not found | Verde Docs' },
          { name: 'robots', content: 'noindex' },
        ],
      }
    }
    const url = `${SITE_ORIGIN}/docs/${doc.slug}`
    return {
      meta: [
        { title: `${doc.title} | Verde Docs` },
        { name: 'description', content: doc.description },
        { property: 'og:type', content: 'article' },
        { property: 'og:url', content: url },
        { property: 'og:title', content: `${doc.title} | Verde Docs` },
        { property: 'og:description', content: doc.description },
        { name: 'twitter:card', content: 'summary' },
        { name: 'twitter:title', content: `${doc.title} | Verde Docs` },
        { name: 'twitter:description', content: doc.description },
      ],
      links: [
        { rel: 'canonical', href: url },
        { rel: 'alternate', type: 'text/markdown', href: `${url}.md` },
      ],
    }
  },
  server: {
    handlers: {
      // `/docs/<slug>.md` — raw markdown mirror for agents and scripts.
      // `/docs/<slug>`    — defers to the SSR HTML page below via `next()`.
      //
      // TanStack Start mounts this GET handler in the request middleware
      // chain. Because this route also declares a `component`, the framework
      // gives us `mayDefer=true`, which means we MUST either return a
      // Response (for the `.md` mirror) or call `next()` to fall through to
      // the SSR pipeline. Returning `undefined` short-circuits the chain
      // and yields an empty `text/plain` body — which is the bug this fix
      // replaces.
      GET: async ({ params, next }) => {
        if (!params.slug.endsWith('.md')) {
          return await next()
        }
        const slug = params.slug.slice(0, -3)
        const raw = getRawMarkdown(slug)
        if (!raw) {
          return new Response(`# 404 — no doc named "${slug}"\n`, {
            status: 404,
            headers: {
              'Content-Type': 'text/markdown; charset=utf-8',
              'Cache-Control': 'public, max-age=300',
            },
          })
        }
        return new Response(raw, {
          headers: {
            'Content-Type': 'text/markdown; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
          },
        })
      },
    },
  },
  loader: async ({ params }) => {
    // The markdown mirror is handled by the server GET handler above; the
    // loader only runs for the HTML page, where slug never ends in `.md`.
    const slug = params.slug.replace(/\.md$/, '')
    const doc = getDoc(slug)
    if (!doc) {
      throw notFound()
    }
    // Markdown rendering happens in the loader (rather than in the
    // component) so the Shiki-highlighted HTML is produced on the server
    // during SSR and reused during client-side SPA navigation. The
    // highlighter is async-once-load and cached across calls.
    const html = await renderMarkdown(doc.body)
    return { doc, html }
  },
  notFoundComponent: () => (
    <main class="docs-page">
      <DocsLayout>
        <section class="docs-notfound">
          <p class="tag tag-static">404</p>
          <h1 class="heading">That page isn't in the docs.</h1>
          <p class="band-body">
            The URL you opened doesn't match any doc. Try the docs index, or one
            of the entries in the sidebar.
          </p>
          <p>
            <a href="/docs" class="btn btn-ghost">← Back to docs</a>
          </p>
        </section>
      </DocsLayout>
    </main>
  ),
  component: DocPage,
})

function DocPage() {
  // `Route.useLoaderData()` returns a Solid Accessor (a getter function), not
  // the data itself — calling it returns the loader's `{ doc, html }` payload.
  const { doc, html } = Route.useLoaderData()()

  // Delegated click handler for the copy buttons injected by the markdown
  // renderer (one per `.code-block`). Delegation survives both SSR hydration
  // and SPA navigation between docs pages without re-attaching listeners.
  let markdownRef: HTMLDivElement | undefined
  let copyResetTimer: ReturnType<typeof setTimeout> | undefined

  function handleCopyClick(event: MouseEvent) {
    const target = event.target as HTMLElement | null
    const btn = target?.closest<HTMLButtonElement>('.code-block-copy')
    if (!btn) return
    const block = btn.closest<HTMLElement>('.code-block')
    const pre = block?.querySelector<HTMLPreElement>('pre')
    if (!pre) return
    const code = pre.textContent ?? ''
    event.preventDefault()

    // Try the modern Async Clipboard API first. If it rejects (e.g. the
    // document lost focus, or the browser withheld the permission), fall
    // back to the legacy `execCommand('copy')` path via a transient
    // `<textarea>`. Either path success → `showCopied(btn)`. This matches
    // the resilience of `CopyButton.tsx` (used by the homepage install
    // command) so the two affordances behave identically.
    function legacyCopy(): boolean {
      const ta = document.createElement('textarea')
      ta.value = code
      ta.setAttribute('readonly', '')
      ta.style.position = 'fixed'
      ta.style.top = '0'
      ta.style.left = '0'
      ta.style.opacity = '0'
      document.body.appendChild(ta)
      ta.select()
      ta.setSelectionRange(0, code.length)
      let ok = false
      try {
        if (document.execCommand('copy')) ok = true
      } catch {
        /* ignore */
      } finally {
        ta.remove()
      }
      return ok
    }

    if (navigator.clipboard?.writeText) {
      void navigator.clipboard.writeText(code).then(
        () => showCopied(btn),
        () => {
          if (legacyCopy()) showCopied(btn)
        },
      )
    } else if (legacyCopy()) {
      showCopied(btn)
    }
  }

  function showCopied(btn: HTMLButtonElement) {
    btn.classList.add('is-copied')
    btn.setAttribute('aria-label', 'Copied to clipboard')
    if (copyResetTimer) clearTimeout(copyResetTimer)
    copyResetTimer = setTimeout(() => {
      btn.classList.remove('is-copied')
      btn.setAttribute('aria-label', 'Copy code')
    }, 2000)
  }

  onMount(() => {
    markdownRef?.addEventListener('click', handleCopyClick)
  })
  onCleanup(() => {
    if (markdownRef) markdownRef.removeEventListener('click', handleCopyClick)
    if (copyResetTimer) clearTimeout(copyResetTimer)
  })

  return (
    <main class="docs-page">
      <DocsLayout slug={doc.slug}>
        <header class="docs-doc-head">
          <p class="docs-doc-eyebrow">{doc.section}</p>
          <h1 class="docs-doc-title">{doc.title}</h1>
          <p class="docs-doc-lead">{doc.description}</p>
        </header>
        <div ref={markdownRef} class="docs-markdown" innerHTML={html} />
      </DocsLayout>
    </main>
  )
}

