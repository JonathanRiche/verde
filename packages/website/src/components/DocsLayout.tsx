import { Link, useNavigate } from '@tanstack/solid-router'
import { For, Show, createMemo, type JSX } from 'solid-js'

import {
  REPO_ROOT,
  SITE_ORIGIN,
  extractToc,
  getDoc,
  getDocsNav,
  getPager,
  type DocSection,
} from '../content/docs'

export interface DocsLayoutProps {
  /** Current page slug. Undefined for the docs index page. */
  slug?: string
  children: JSX.Element
}

interface Crumb {
  label: string
  to?: string
}

const SECTION_LABEL: Record<DocSection, string> = {
  'Get started': 'Get started',
  Workspace: 'Workspace',
  Reference: 'Reference',
}

/**
 * Docs page shell — sticky sidebar on the left, prose content in the middle,
 * "On this page" TOC on the right (sticky on desktop, hidden on mobile).
 * Includes breadcrumbs, prev/next pager, and an "Edit on GitHub" link.
 *
 * Internal clicks on `<a href="/...">` inside the prose container are
 * intercepted and routed through TanStack Router so docs navigation is
 * SPA-fast instead of a full reload.
 */
export default function DocsLayout(props: DocsLayoutProps): JSX.Element {
  const navigate = useNavigate()

  const currentDoc = createMemo(() => (props.slug ? getDoc(props.slug) : undefined))
  const toc = createMemo(() => (currentDoc() ? extractToc(currentDoc()!.body) : []))
  const pager = createMemo(() => (props.slug ? getPager(props.slug) : {}))

  const crumbs = createMemo<Crumb[]>(() => {
    const doc = currentDoc()
    if (!doc) return [{ label: 'Docs', to: '/docs' }]
    return [
      { label: 'Docs', to: '/docs' },
      { label: SECTION_LABEL[doc.section] },
      { label: doc.title },
    ]
  })

  /** Intercept clicks on internal `<a href="/...">` in the prose container. */
  function handleProseClick(event: MouseEvent) {
    if (event.defaultPrevented || event.button !== 0) return
    const target = event.target as HTMLElement | null
    const anchor = target?.closest('a')
    if (!anchor) return
    const href = anchor.getAttribute('href')
    if (!href || href.startsWith('#') || href.startsWith('http') || href.startsWith('mailto:')) {
      return
    }
    // Internal SPA link — let the router handle it.
    event.preventDefault()
    void navigate(href)
  }

  return (
    <div class={`docs-shell${currentDoc() ? ' docs-shell--with-toc' : ''}`}>
      <aside class="docs-sidebar" aria-label="Docs navigation">
        <Link to="/docs" class="docs-sidebar-title" activeProps={{ class: 'docs-sidebar-title docs-sidebar-title--active' }}>
          Verde docs
        </Link>
        <nav class="docs-nav">
          <For each={getDocsNav()}>
            {(group) => (
              <div class="docs-nav-group">
                <p class="docs-nav-section">{SECTION_LABEL[group.section]}</p>
                <ul class="docs-nav-list">
                  <For each={group.entries}>
                    {(entry) => (
                      <li>
                        <Link
                          to={`/docs/${entry.slug}`}
                          class="docs-nav-link"
                          activeProps={{ class: 'docs-nav-link docs-nav-link--active' }}
                        >
                          {entry.title}
                        </Link>
                      </li>
                    )}
                  </For>
                </ul>
              </div>
            )}
          </For>
        </nav>
      </aside>

      <div class="docs-content">
        <nav class="docs-breadcrumbs" aria-label="Breadcrumb">
          <For each={crumbs()}>
            {(crumb, i) => (
              <span class="docs-crumb">
                <Show when={crumb.to && i() < crumbs().length - 1} fallback={<span>{crumb.label}</span>}>
                  <Link to={crumb.to!} class="docs-crumb-link">
                    {crumb.label}
                  </Link>
                </Show>
                <Show when={i() < crumbs().length - 1}>
                  <span class="docs-crumb-sep" aria-hidden="true">/</span>
                </Show>
              </span>
            )}
          </For>
        </nav>

        <article class="docs-prose" onClick={handleProseClick}>
          {props.children}
        </article>

        <Show when={currentDoc()}>
          {(doc) => (
            <p class="docs-edit">
              <a
                href={`${REPO_ROOT}${doc().githubPath}`}
                target="_blank"
                rel="noreferrer"
                class="docs-edit-link"
              >
                Edit this page on GitHub →
              </a>
            </p>
          )}
        </Show>

        <Show when={pager().prev || pager().next}>
          <nav class="docs-pager" aria-label="Pager">
            <Show when={pager().prev}>
              {(prev) => (
                <Link to={`/docs/${prev().slug}`} class="docs-pager-card docs-pager-card--prev">
                  <span class="docs-pager-label">← Previous</span>
                  <span class="docs-pager-title">{prev().title}</span>
                </Link>
              )}
            </Show>
            <Show when={pager().next}>
              {(next) => (
                <Link to={`/docs/${next().slug}`} class="docs-pager-card docs-pager-card--next">
                  <span class="docs-pager-label">Next →</span>
                  <span class="docs-pager-title">{next().title}</span>
                </Link>
              )}
            </Show>
          </nav>
        </Show>
      </div>

      <Show when={currentDoc()}>
        <aside class="docs-toc" aria-label="On this page">
          <Show when={toc().length >= 2}>
            <p class="docs-toc-title">On this page</p>
            <ul class="docs-toc-list">
              <For each={toc()}>
                {(item) => (
                  <li>
                    <a
                      href={`#${item.slug}`}
                      class={`docs-toc-link${item.depth === 3 ? ' docs-toc-link--sub' : ''}`}
                    >
                      {item.text}
                    </a>
                  </li>
                )}
              </For>
            </ul>
          </Show>
          <div class="docs-toc-machine">
            <p class="docs-toc-machine-title">For agents</p>
            <a href="/llms.txt" class="docs-toc-llm">llms.txt</a>
            <a href="/llms-full.txt" class="docs-toc-llm">llms-full.txt</a>
            <a href={`/docs/${props.slug}.md`} class="docs-toc-llm">this page (.md)</a>
          </div>
        </aside>
      </Show>

      <Show when={currentDoc()}>
        {(doc) => (
          <script
            type="application/ld+json"
            innerHTML={JSON.stringify({
              '@context': 'https://schema.org',
              '@graph': [
                {
                  '@type': 'TechArticle',
                  '@id': `${SITE_ORIGIN}/docs/${doc().slug}#article`,
                  url: `${SITE_ORIGIN}/docs/${doc().slug}`,
                  headline: doc().title,
                  description: doc().description,
                  articleSection: SECTION_LABEL[doc().section],
                  inLanguage: 'en',
                  mainEntityOfPage: `${SITE_ORIGIN}/docs/${doc().slug}`,
                  isPartOf: { '@id': `${SITE_ORIGIN}/docs#page` },
                  about: { '@id': `${SITE_ORIGIN}/#software` },
                  author: { '@id': `${SITE_ORIGIN}/#organization` },
                  publisher: { '@id': `${SITE_ORIGIN}/#organization` },
                },
                {
                  '@type': 'BreadcrumbList',
                  itemListElement: [
                    {
                      '@type': 'ListItem',
                      position: 1,
                      name: 'Docs',
                      item: `${SITE_ORIGIN}/docs`,
                    },
                    {
                      '@type': 'ListItem',
                      position: 2,
                      name: SECTION_LABEL[doc().section],
                    },
                    {
                      '@type': 'ListItem',
                      position: 3,
                      name: doc().title,
                      item: `${SITE_ORIGIN}/docs/${doc().slug}`,
                    },
                  ],
                },
              ],
            })}
          />
        )}
      </Show>
    </div>
  )
}
