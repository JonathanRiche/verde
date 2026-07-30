import { createFileRoute, Link } from '@tanstack/solid-router'
import { For } from 'solid-js'

import DocsLayout from '../../components/DocsLayout'
import {
  SITE_ORIGIN,
  getAllDocs,
  getDocsNav,
  type DocEntry,
} from '../../content/docs'

const docsTitle = 'Verde Docs — Install, Providers, CLI & Tiling'
const docsDescription =
  'Install Verde, connect coding-agent providers, tile chat, terminal, and browser panes, configure keybinds, and automate the app with the verde CLI.'

export const Route = createFileRoute('/docs/')({
  head: () => ({
    meta: [
      { title: docsTitle },
      {
        name: 'description',
        content: docsDescription,
      },
      { property: 'og:type', content: 'website' },
      { property: 'og:url', content: `${SITE_ORIGIN}/docs` },
      { property: 'og:title', content: docsTitle },
      {
        property: 'og:description',
        content: docsDescription,
      },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: docsTitle },
      { name: 'twitter:description', content: docsDescription },
    ],
    links: [{ rel: 'canonical', href: `${SITE_ORIGIN}/docs` }],
  }),
  component: DocsIndex,
})

const SECTION_BLURB: Record<string, string> = {
  'Get started': 'Install Verde, authenticate a provider, and run your first chat thread.',
  Workspace: 'The tiled workspace — panes, splits, focus, resize, the terminal dock, and keybinds.',
  Reference: 'The full verde CLI surface, configuration files, themes, logs, and troubleshooting.',
}

function DocCard(props: { entry: DocEntry }) {
  return (
    <Link to={`/docs/${props.entry.slug}`} class="docs-card">
      <div class="docs-card-head">
        <span class="docs-card-tag">{props.entry.section}</span>
      </div>
      <h3 class="docs-card-title">{props.entry.title}</h3>
      <p class="docs-card-body">{props.entry.description}</p>
      <span class="docs-card-arrow" aria-hidden="true">→</span>
    </Link>
  )
}

function DocsIndex() {
  const structuredData = {
    '@context': 'https://schema.org',
    '@type': 'CollectionPage',
    '@id': `${SITE_ORIGIN}/docs#page`,
    url: `${SITE_ORIGIN}/docs`,
    name: docsTitle,
    description: docsDescription,
    inLanguage: 'en',
    isPartOf: { '@id': `${SITE_ORIGIN}/#website` },
    mainEntity: {
      '@type': 'ItemList',
      itemListElement: getAllDocs().map((doc, index) => ({
        '@type': 'ListItem',
        position: index + 1,
        name: doc.title,
        url: `${SITE_ORIGIN}/docs/${doc.slug}`,
      })),
    },
  }

  return (
    <main class="docs-page">
      <script
        type="application/ld+json"
        innerHTML={JSON.stringify(structuredData)}
      />
      <DocsLayout>
        <section class="docs-hero">
          <p class="tag tag-static">Documentation</p>
          <h1 class="heading">Everything you need to run Verde.</h1>
          <p class="band-body docs-hero-lead">
            Verde is a native desktop workspace for coding agents — Codex,
            Claude Code, OpenCode, and Cursor as native chat or terminal panes,
            with Grok Build and Amp available as terminal TUIs in the same
            tiling window. These docs cover installation, provider setup, the
            tiled workspace, keybinds, the scriptable CLI, configuration, and
            troubleshooting.
          </p>
        </section>

        <div class="docs-agent-strip">
          <div class="docs-agent-copy">
            <span class="docs-agent-eyebrow">Agent-friendly</span>
            <p class="docs-agent-body">
              These docs are crawlable as plain markdown. Pull{' '}
              <a href="/llms.txt" class="text-link">llms.txt</a> for a compact
              index, <a href="/llms-full.txt" class="text-link">llms-full.txt</a>
              {' '}for everything in one file, or grab any page as raw markdown
              at <code>/docs/&lt;slug&gt;.md</code> (e.g.{' '}
              <a href="/docs/quickstart.md" class="text-link">
                /docs/quickstart.md
              </a>
              ).
            </p>
          </div>
          <a href="/llms.txt" class="docs-agent-pill">
            <code>GET /llms.txt</code>
          </a>
        </div>

        <For each={getDocsNav()}>
          {(group) => (
            <section class="docs-section">
              <div class="docs-section-head">
                <h2 class="docs-section-title">{group.section}</h2>
                <p class="docs-section-blurb">{SECTION_BLURB[group.section]}</p>
              </div>
              <div class="docs-card-grid">
                <For each={group.entries}>
                  {(entry) => <DocCard entry={entry} />}
                </For>
              </div>
            </section>
          )}
        </For>

        <section class="docs-index-foot">
          <p>
            Verde is built with{' '}
            <a href="https://ziglang.org" target="_blank" rel="noreferrer" class="text-link">Zig</a>
            ,{' '}
            <a href="https://libsdl.org" target="_blank" rel="noreferrer" class="text-link">SDL3</a>
            , and{' '}
            <a href="https://ghostty.org" target="_blank" rel="noreferrer" class="text-link">Ghostty</a>
            . Source on{' '}
            <a
              href="https://github.com/JonathanRiche/verde"
              target="_blank"
              rel="noreferrer"
              class="text-link"
            >
              GitHub
            </a>
            .
          </p>
        </section>
      </DocsLayout>
    </main>
  )
}
