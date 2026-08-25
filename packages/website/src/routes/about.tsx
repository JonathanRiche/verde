import { createFileRoute } from '@tanstack/solid-router'

import {
  HOME_DESCRIPTION,
  SITE_ORIGIN,
} from '../lib/seo'

const title = 'About Verde — Local-First AI Coding Agent Workspace'
const description =
  'Learn what Verde is, how its native tiling workspace connects to local coding-agent CLIs, and why it combines agent chat, terminals, and a browser.'

export const Route = createFileRoute('/about')({
  head: () => ({
    meta: [
      { title },
      { name: 'description', content: description },
      { property: 'og:type', content: 'website' },
      { property: 'og:url', content: `${SITE_ORIGIN}/about` },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: title },
      { name: 'twitter:description', content: description },
    ],
    links: [{ rel: 'canonical', href: `${SITE_ORIGIN}/about` }],
  }),
  component: About,
})

function About() {
  const structuredData = {
    '@context': 'https://schema.org',
    '@type': 'AboutPage',
    '@id': `${SITE_ORIGIN}/about#page`,
    url: `${SITE_ORIGIN}/about`,
    name: title,
    description,
    inLanguage: 'en',
    isPartOf: { '@id': `${SITE_ORIGIN}/#website` },
    about: { '@id': `${SITE_ORIGIN}/#software` },
  }

  return (
    <main class="wrap" style={{ padding: '5rem 0 2rem' }}>
      <script
        type="application/ld+json"
        innerHTML={JSON.stringify(structuredData)}
      />
      <section class="term-card" style={{ 'max-width': '48rem' }}>
        <p class="tag">About Verde</p>
        <h1 class="heading">A local-first workspace for coding agents.</h1>
        <p class="band-body">
          {HOME_DESCRIPTION}
        </p>
        <p class="band-body">
          Verde does not host models or relay prompts through a Verde service.
          It connects to supported provider CLIs already installed and
          authenticated on your computer, keeping the working environment
          project-scoped and local.
        </p>
        <h2 class="heading" style={{ 'font-size': '1.7rem', 'margin-top': '2.5rem' }}>
          Built for multi-agent development.
        </h2>
        <p class="band-body">
          Codex, Claude Code, OpenCode, Cursor, Pi, FX, and Grok Build can run
          in Verde's native chat interface. Codex, Claude Code, OpenCode,
          Cursor, Pi, FX, Grok Build, and Amp also run as terminal TUIs. Beside them,
          you can tile shell terminals and a native embedded browser, persist
          the layout, and control the running app through its local CLI.
        </p>
        <p style={{ 'margin-top': '2rem' }}>
          <a href="/docs/quickstart" class="btn btn-primary">
            Read the quickstart
          </a>{' '}
          <a
            href="https://github.com/JonathanRiche/verde"
            target="_blank"
            rel="noreferrer"
            class="btn btn-ghost"
          >
            View the source
          </a>
        </p>
      </section>
    </main>
  )
}
