import { createFileRoute, getRouteApi } from '@tanstack/solid-router'
import { For, Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js'
import { Portal } from 'solid-js/web'

import { availableThemes, displayedTheme, setActiveThemeSlug } from '../lib/site-theme'
import {
  HOME_DESCRIPTION,
  HOME_TITLE,
  SITE_ORIGIN,
  SOCIAL_IMAGE_URL,
} from '../lib/seo'
import { themeImportCommand, themePackageUrl } from '../lib/theme-package'

const rootRoute = getRouteApi('__root__')

import openAiLogo from '../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import claudeLogo from '../../../desktop/src/assets/claude-logo.png'
import opencodeLogo from '../../../desktop/src/assets/opencode-logo-dark.png'
import cursorLogo from '../../../desktop/src/assets/editor_logos/cursor.png'
import piLogo from '../../../desktop/src/assets/pi-logo.png'
import fxLogo from '../../../desktop/src/assets/fx-logo.png'
import ampLogo from '../../../desktop/src/assets/amp-logo.png'
import grokLogo from '../../../desktop/src/assets/grok-logo.png'
import verdeLogoMask from '../../../desktop/src/assets/verde_logo_mask.png'
import CopyButton from '../components/CopyButton'

export const Route = createFileRoute('/')({
  head: () => ({
    meta: [
      { title: HOME_TITLE },
      { name: 'description', content: HOME_DESCRIPTION },
      { property: 'og:type', content: 'website' },
      { property: 'og:url', content: `${SITE_ORIGIN}/` },
      { property: 'og:title', content: HOME_TITLE },
      { property: 'og:description', content: HOME_DESCRIPTION },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: HOME_TITLE },
      { name: 'twitter:description', content: HOME_DESCRIPTION },
    ],
    links: [{ rel: 'canonical', href: `${SITE_ORIGIN}/` }],
  }),
  component: App,
})

const DEFAULT_INSTALL_COMMAND = 'curl -fsSL https://verdeai.dev/install.sh | sh'
const WINDOWS_INSTALL_COMMAND = 'irm https://verdeai.dev/install.ps1 | iex'

/* ───────────────────────── Feature icons ───────────────────────── */

function FeatureIcon(props: { name: string }) {
  // Single 24×24 stroke icon set so feature cards share one visual language.
  const paths: Record<string, string> = {
    browser:
      'M3 5h18v14H3zM3 9h18 M7 7h.01 M10 7h.01',
    terminal: 'M4 5h16v14H4z M7 9l3 3-3 3 M13 15h4',
    process: 'M12 3v4 M12 17v4 M5.6 5.6l2.8 2.8 M15.6 15.6l2.8 2.8 M3 12h4 M17 12h4 M5.6 18.4l2.8-2.8 M15.6 8.4l2.8-2.8',
    sidebar: 'M3 5h18v14H3z M9 5v14 M5.5 9h1.5 M5.5 12h1.5',
    shield: 'M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z M9 12l2 2 4-4',
    steer: 'M4 12h11 M11 8l4 4-4 4 M19 5v14',
    daemon: 'M5 4h14v6H5z M5 14h14v6H5z M8 7h.01 M8 17h.01 M12 10v4',
    bolt: 'M13 3L5 14h6l-1 7 8-11h-6z',
  }
  return (
    <svg class="feat-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path
        d={paths[props.name] ?? ''}
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
  )
}

/* ───────────────────────── Data ───────────────────────── */

// Two integration modes: 'gui' = native Verde chat pane over the provider's
// protocol; 'tui' = the agent's own TUI launched in an embedded terminal
// pane. Source of truth: providers/types.zig and
// state/provider_models.zig (GUI), and workspace/stack.zig (TUI).
const providers = [
  {
    name: 'Codex',
    logo: openAiLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'Claude Code',
    logo: claudeLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'OpenCode',
    logo: opencodeLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'Cursor',
    logo: cursorLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'Pi',
    logo: piLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'FX',
    logo: fxLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'Grok Build',
    logo: grokLogo,
    modes: ['gui', 'tui'],
  },
  {
    name: 'Amp',
    logo: ampLogo,
    modes: ['tui'],
  },
]

const MODE_LABELS: Record<string, string> = {
  gui: 'Chat window',
  tui: 'Terminal',
}

const featureCards = [
  {
    icon: 'shield',
    title: 'Uses the plans you already have',
    body: 'Works with the logins you already have for Claude Code, Codex, Cursor and the rest. No new subscription and no API keys.',
  },
  {
    icon: 'steer',
    title: 'Approve and redirect as it works',
    body: 'Allow a command, change course mid-task, or queue the next request without stopping the agent.',
  },
  {
    icon: 'daemon',
    title: 'Close the window, keep working',
    body: 'Agents keep running when Verde is closed and pick up where they left off after a restart.',
  },
  {
    icon: 'browser',
    title: 'A browser built in',
    body: 'Preview your app next to the agent, click any element on the page, and ask for a change.',
  },
  {
    icon: 'terminal',
    title: 'Terminals and dev servers',
    body: 'Real terminals sit beside your chats, and your dev server starts, stops and restarts from one place.',
  },
  {
    icon: 'bolt',
    title: 'Native and fast, not Electron',
    body: 'Built in Zig, so it starts fast and stays light. Ctrl+Shift+P finds any chat or command, and every shortcut can be remapped.',
  },
]

// Short screen recordings of a demo workspace. The poster frame doubles as the
// grid thumbnail.
const gallery = [
  {
    src: '/media/clips/1-tiling.webp',
    video: '/media/clips/1-tiling.mp4',
    title: 'Claude and Codex, side by side',
    body: 'Each chat works on its own task in the same repo.',
  },
  {
    src: '/media/clips/2-browser-v3.webp',
    video: '/media/clips/2-browser-v3.mp4',
    title: 'Built-in browser',
    body: 'Switch tabs, watch an agent restyle the page and reload it, then click an element to ask for an edit.',
  },
  {
    src: '/media/clips/3-changes.webp',
    video: '/media/clips/3-changes.mp4',
    title: 'Changes, per chat',
    body: 'Filter changes by the chat that made them and open any diff.',
  },
  {
    src: '/media/clips/4-agents.webp',
    video: '/media/clips/4-agents.mp4',
    title: 'Agents that delegate',
    body: 'A chat hands subtasks to helper agents and tracks them live.',
  },
  {
    src: '/media/clips/5-terminal-agent.webp',
    video: '/media/clips/5-terminal-agent.mp4',
    title: 'CLI agents too',
    body: 'Run Claude Code, Codex and other CLIs in real terminal panes.',
  },
  {
    src: '/media/clips/6-files.webp',
    video: '/media/clips/6-files.mp4',
    title: 'Files at hand',
    body: 'Browse and filter the project tree, and open files beside the chat.',
  },
]

type GalleryItem = (typeof gallery)[number]

/* Full-screen viewer for the screenshot gallery. Arrow keys / buttons / dots
   step through, a horizontal swipe (touch or mouse drag) does the same, and
   Escape, the close button, or a click on the backdrop dismisses it. */
function Lightbox(props: {
  items: GalleryItem[]
  index: number | null
  onIndex: (i: number | null) => void
}) {
  const count = () => props.items.length
  const go = (delta: number) => {
    const i = props.index
    if (i === null) return
    props.onIndex((i + delta + count()) % count())
  }
  const close = () => props.onIndex(null)

  const [drag, setDrag] = createSignal(0)
  let startX: number | null = null
  let startY = 0
  let moved = false

  createEffect(() => {
    if (props.index === null) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close()
      else if (e.key === 'ArrowRight') go(1)
      else if (e.key === 'ArrowLeft') go(-1)
    }
    const prevOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    document.addEventListener('keydown', onKey)
    onCleanup(() => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prevOverflow
    })
  })

  const onPointerDown = (e: PointerEvent) => {
    if (e.button !== 0) return
    startX = e.clientX
    startY = e.clientY
    moved = false
  }
  const onPointerMove = (e: PointerEvent) => {
    if (startX === null) return
    const dx = e.clientX - startX
    if (!moved && Math.abs(dx) > 8 && Math.abs(dx) > Math.abs(e.clientY - startY)) {
      moved = true
      ;(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId)
    }
    if (moved) setDrag(dx)
  }
  const onPointerUp = () => {
    if (startX === null) return
    const dx = drag()
    startX = null
    setDrag(0)
    if (dx < -60) go(1)
    else if (dx > 60) go(-1)
  }
  // A drag that ended over the backdrop must not count as a click-to-close.
  const onBackdropClick = (e: MouseEvent) => {
    if (moved) {
      moved = false
      return
    }
    if (e.target === e.currentTarget) close()
  }

  return (
    <Show when={props.index !== null}>
      <Portal>
        <div
          class="lightbox"
          role="dialog"
          aria-modal="true"
          aria-label="Screenshot viewer"
          onClick={onBackdropClick}
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          onPointerCancel={onPointerUp}
        >
          <button type="button" class="lightbox-close" aria-label="Close" onClick={close}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
          <button
            type="button"
            class="lightbox-nav lightbox-prev"
            aria-label="Previous screenshot"
            onClick={() => go(-1)}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M15 5l-7 7 7 7" />
            </svg>
          </button>
          <button
            type="button"
            class="lightbox-nav lightbox-next"
            aria-label="Next screenshot"
            onClick={() => go(1)}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M9 5l7 7-7 7" />
            </svg>
          </button>

          {(() => {
            const item = () => props.items[props.index ?? 0]
            return (
              <figure class="lightbox-figure" onClick={(e) => e.target === e.currentTarget && !moved && close()}>
                <video
                  src={item().video}
                  poster={item().src}
                  aria-label={`${item().title}: ${item().body}`}
                  class="lightbox-img"
                  autoplay
                  muted
                  prop:muted={true}
                  loop
                  playsinline
                  controls
                  draggable={false}
                  style={{
                    transform: `translateX(${drag()}px)`,
                    transition: drag() === 0 ? 'transform 220ms ease' : 'none',
                  }}
                />
                <figcaption class="lightbox-caption">
                  <span class="lightbox-count">
                    {(props.index ?? 0) + 1} / {count()}
                  </span>
                  <strong>{item().title}</strong>
                  <span>{item().body}</span>
                </figcaption>
                <div class="lightbox-dots">
                  <For each={props.items}>
                    {(g, i) => (
                      <button
                        type="button"
                        class={`lightbox-dot${i() === props.index ? ' lightbox-dot--active' : ''}`}
                        aria-label={`Show ${g.title}`}
                        aria-current={i() === props.index}
                        onClick={() => props.onIndex(i())}
                      />
                    )}
                  </For>
                </div>
              </figure>
            )
          })()}
        </div>
      </Portal>
    </Show>
  )
}

const mobilePoints = [
  {
    title: 'Your agent needs you? Approve it in one tap.',
    body: 'Approval requests and finished turns reach your phone.',
  },
  {
    title: 'Steer it mid-turn.',
    body: 'The same chat with the same context, continued from your pocket.',
  },
  {
    title: 'A real terminal and a real diff.',
    body: 'Review changes and push from your phone.',
  },
  {
    title: 'Every machine in one app.',
    body: 'Pair your desktop, a home server, or a cloud box, and switch between them in one tap.',
  },
]

type Cell = boolean | 'partial'
const comparisonCols = ['Verde', 'Agents in a terminal', 'Hosted agent apps', 'IDE extensions']
const comparisonRows: { label: string; cells: Cell[] }[] = [
  { label: 'Run several agents at once', cells: [true, 'partial', false, 'partial'] },
  { label: 'Chat window or terminal, your choice', cells: [true, false, 'partial', false] },
  { label: 'Built-in browser', cells: [true, false, 'partial', false] },
  { label: 'Approve from your phone', cells: [true, false, 'partial', false] },
  { label: 'Runs on your machine, no relay', cells: [true, true, false, 'partial'] },
  { label: 'Native app, not Electron', cells: [true, true, false, false] },
]

const faqs = [
  {
    question: 'Is Verde free?',
    answer:
      'Yes. Verde is free and open source (MIT). You only pay for the AI coding tools you already use.',
  },
  {
    question: 'What is Verde?',
    answer:
      'A desktop app for running AI coding agents like Claude Code and Codex side by side, with terminals and a browser built in.',
  },
  {
    question: 'What do I need first?',
    answer:
      'At least one AI coding tool installed and signed in, such as Claude Code, Codex, Cursor, OpenCode, Pi, FX, Grok Build or Amp.',
  },
  {
    question: 'Does Verde see my prompts or code?',
    answer:
      "No. Verde doesn't host any AI or relay your prompts. Your agents talk to their providers exactly as they do today.",
  },
  {
    question: 'Can several agents work on the same project?',
    answer:
      'Yes. Each chat works on its own task in the same repo, and Verde shows which chat changed which files.',
  },
  {
    question: 'Which operating systems does it run on?',
    answer: 'Linux, macOS and Windows (x64).',
  },
  {
    question: 'Do my agents stop when I close Verde?',
    answer:
      'No. They keep working in the background and pick up where they left off after restarts and upgrades.',
  },
  {
    question: 'Can I use it from my phone?',
    answer:
      'Yes. The iOS and Android apps are in private beta, and a web version works today. Approve requests, steer a task, review changes and push from anywhere.',
  },
]

/* ───────────────────────── Small render helpers ───────────────────────── */

function CompCell(props: { value: Cell }) {
  return (
    <Show
      when={props.value !== false}
      fallback={<span class="comp-cell comp-cell--no" aria-label="No">–</span>}
    >
      <Show
        when={props.value === true}
        fallback={<span class="comp-cell comp-cell--partial" aria-label="Partial">~</span>}
      >
        <span class="comp-cell comp-cell--yes" aria-label="Yes">✓</span>
      </Show>
    </Show>
  )
}

function App() {
  const [showMoreInstall, setShowMoreInstall] = createSignal(false)
  const [lightbox, setLightbox] = createSignal<number | null>(null)

  // Theme state lives in lib/site-theme.ts, shared with the nav dropdown; the
  // Header owns the site-wide <style> overrides. During SSR the theme comes
  // from the visitor's cookie via the root loader.
  const savedSlug = rootRoute.useLoaderData() as () => string | null
  const theme = () => displayedTheme(savedSlug())

  // Warm the alternate theme captures after the critical hero has had time
  // to load, so instant theme switching does not compete with the page LCP.
  onMount(() => {
    const timer = window.setTimeout(() => {
      for (const t of availableThemes) {
        if (t.slug === theme().slug) continue
        const img = new Image()
        img.src = t.shot
      }
    }, 1500)
    onCleanup(() => window.clearTimeout(timer))
  })

  const homeStructuredData = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication',
        '@id': `${SITE_ORIGIN}/#software`,
        name: 'Verde',
        url: `${SITE_ORIGIN}/`,
        description: HOME_DESCRIPTION,
        image: SOCIAL_IMAGE_URL,
        applicationCategory: 'DeveloperApplication',
        applicationSubCategory: 'AI coding agent workspace',
        operatingSystem: ['Linux', 'macOS', 'Windows'],
        isAccessibleForFree: true,
        license:
          'https://github.com/JonathanRiche/verde/blob/master/LICENSE',
        downloadUrl: 'https://github.com/JonathanRiche/verde/releases',
        softwareRequirements:
          'At least one supported provider CLI installed and authenticated',
        featureList: [
          'Native and terminal coding-agent panes',
          'Tiled chat, terminal, and browser workspace',
          'Local provider CLI integrations',
          'Embedded browser with Design Mode',
          'In-place approvals and mid-turn steering',
          'Session daemon that keeps agents running after the window closes',
          'iOS, Android, and web companion apps (beta)',
          'Scriptable local IPC',
          'Portable themes',
        ],
        offers: {
          '@type': 'Offer',
          price: '0',
          priceCurrency: 'USD',
          availability: 'https://schema.org/InStock',
          url: `${SITE_ORIGIN}/#install`,
        },
        publisher: { '@id': `${SITE_ORIGIN}/#organization` },
      },
      {
        '@type': 'FAQPage',
        '@id': `${SITE_ORIGIN}/#faq`,
        mainEntity: faqs.map((faq) => ({
          '@type': 'Question',
          name: faq.question,
          acceptedAnswer: {
            '@type': 'Answer',
            text: faq.answer,
          },
        })),
      },
    ],
  }

  return (
    <main>
      <script
        type="application/ld+json"
        innerHTML={JSON.stringify(homeStructuredData)}
      />
      {/* ── Hero ── */}
      <section class="hero">
        <div class="hero-grid-bg" aria-hidden="true" />
        <div class="hero-backdrop" aria-hidden="true" />

        <div class="wrap hero-wrap">
          <div class="hero-content rise">
            <p class="tag">
              <span class="tag-pulse" />
              Free · Open source · Linux, macOS, Windows
            </p>
            <h1 class="display">
              All your coding agents.<br />
              <span class="display-accent">Anywhere you work.</span>
            </h1>
            <p class="lead">
              Verde is a desktop app that runs Claude Code, Codex, Cursor and
              more side by side, with a terminal and browser built in. It uses
              the subscriptions you already have, and you can check in from
              your phone when you step away.
            </p>

            <div class="hero-actions">
              <a href="#install" class="btn btn-primary">
                Install Verde
              </a>
              <a
                href="https://github.com/JonathanRiche/verde"
                target="_blank"
                rel="noreferrer"
                class="btn btn-ghost"
              >
                <span class="btn-glyph" aria-hidden="true">★</span>
                Source on GitHub
              </a>
            </div>

            <div class="hero-install" aria-label="Quick install command">
              <div class="hero-install-row">
                <span class="hero-install-prompt">$</span>
                <code class="hero-install-cmd">{DEFAULT_INSTALL_COMMAND}</code>
                <CopyButton command={DEFAULT_INSTALL_COMMAND} />
              </div>
              <p class="hero-install-note">
                Linux and macOS · Windows installer below · latest GitHub release
              </p>
            </div>
          </div>
        </div>

        <div class="stage-wrap">
          <div class="app-frame rise" style={{ 'animation-delay': '180ms' }}>
            {/* Follows the Omarchy theme picker (nav dropdown / #themes chips) */}
            <img
              src={theme().shot}
              alt="Verde desktop app with a sidebar of chats and terminals, a Codex chat and a Claude chat side by side, themed to match the selected Omarchy theme."
              class="app-screenshot"
              width="2000"
              height="1282"
              loading="eager"
              fetchpriority="high"
              decoding="async"
            />
          </div>
        </div>
      </section>

      {/* ── Provider strip ── */}
      <section id="providers" class="providers-band">
        <div class="wrap">
          <p class="strip-eyebrow">Works with the coding agents you already use</p>
          <div class="provider-grid stagger">
            <For each={providers}>
              {(p) => (
                <article class="provider-card">
                  <div class="provider-card-head">
                    <img src={p.logo} alt="" class="provider-card-logo" />
                    <h3>{p.name}</h3>
                  </div>
                  <div class="provider-modes">
                    <For each={p.modes}>
                      {(m) => (
                        <span class={`provider-mode provider-mode--${m}`}>
                          {MODE_LABELS[m]}
                        </span>
                      )}
                    </For>
                  </div>
                </article>
              )}
            </For>
          </div>
          <p class="providers-note">
            Use each one in Verde's chat window or in its own terminal app.
            Verde doesn't host any AI: it runs the tools and logins already on
            your computer.
          </p>
        </div>
      </section>

      {/* ── Tour: promo video + themed screenshot gallery ── */}
      <section id="tour" class="band">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">See it work</p>
            <h2 class="heading">Thirty seconds, one window.</h2>
            <p class="band-body">
              A 30-second tour, then six short clips of the features you'll use
              every day.
            </p>
          </div>

          <div class="tour-video app-frame">
            <video
              class="tour-video-el"
              src="/media/verde-desktop.mp4"
              poster="/media/verde-desktop-poster.webp"
              controls
              playsinline
              preload="none"
              width="1600"
              height="900"
              aria-label="Verde desktop tour, 30 seconds, with sound"
            />
          </div>

          <div class="shot-grid stagger">
            <For each={gallery}>
              {(g, i) => (
                <figure class="shot-card">
                  <button
                    type="button"
                    class="shot-link"
                    aria-label={`Play video: ${g.title}`}
                    onClick={() => setLightbox(i())}
                  >
                    <img
                      src={g.src}
                      alt={`${g.title}: ${g.body}`}
                      width="1600"
                      height="1026"
                      loading="lazy"
                      decoding="async"
                    />
                    <span class="shot-play" aria-hidden="true">
                      <svg viewBox="0 0 24 24">
                        <path d="M8 5.5v13l11-6.5z" />
                      </svg>
                    </span>
                  </button>
                  <figcaption>
                    <strong>{g.title}</strong>
                    <span>{g.body}</span>
                  </figcaption>
                </figure>
              )}
            </For>
          </div>
        </div>
      </section>

      <Lightbox items={gallery} index={lightbox()} onIndex={setLightbox} />

      {/* ── Mobile companion ── */}
      <section id="mobile" class="band band-alt">
        <div class="wrap feature-row">
          <div class="feature-copy">
            <p class="tag tag-static">Companion apps · beta</p>
            <h2 class="heading">
              Start at your desk.<br />
              <span class="display-accent">Finish anywhere.</span>
            </h2>
            <p class="band-body">
              Your agents run on your machines, and the companion apps keep you
              in the loop when you’re away from the desk.
            </p>
            <ul class="mobile-points">
              <For each={mobilePoints}>
                {(m) => (
                  <li>
                    <span class="mobile-point-dot" aria-hidden="true" />
                    <div>
                      <strong>{m.title}</strong>
                      <span>{m.body}</span>
                    </div>
                  </li>
                )}
              </For>
            </ul>
            <div class="store-badges" aria-label="App store availability">
              <span class="store-badge" aria-disabled="true">
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path
                    fill="currentColor"
                    d="M16.37 12.6c-.02-2.3 1.88-3.4 1.96-3.46-1.07-1.56-2.73-1.78-3.32-1.8-1.41-.14-2.76.83-3.48.83-.72 0-1.82-.81-3-.79-1.54.02-2.96.9-3.76 2.28-1.6 2.78-.41 6.9 1.15 9.16.76 1.1 1.67 2.34 2.86 2.3 1.15-.05 1.58-.74 2.97-.74 1.38 0 1.77.74 2.98.72 1.23-.02 2.01-1.12 2.76-2.23.87-1.28 1.23-2.52 1.25-2.58-.03-.01-2.39-.92-2.41-3.65zM14.1 5.86c.63-.77 1.06-1.83.94-2.89-.91.04-2.01.61-2.66 1.37-.58.67-1.1 1.76-.96 2.8 1.01.08 2.05-.52 2.68-1.28z"
                  />
                </svg>
                <span class="store-badge-text">
                  <small>Coming soon to the</small>
                  App Store
                </span>
              </span>
              <span class="store-badge" aria-disabled="true">
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path fill="currentColor" d="M4.2 2.6c-.25.27-.4.68-.4 1.2v16.4c0 .52.15.93.4 1.2l9.2-9.4z" opacity=".85" />
                  <path fill="currentColor" d="M16.5 15.1 13.4 12l3.1-3.1 3.7 2.1c1.06.6 1.06 1.6 0 2.2z" />
                  <path fill="currentColor" d="M16.5 8.9 5.6 2.7c-.53-.3-1.03-.33-1.4-.1l9.2 9.4z" opacity=".7" />
                  <path fill="currentColor" d="m13.4 12-9.2 9.4c.37.23.87.2 1.4-.1l10.9-6.2z" opacity=".55" />
                </svg>
                <span class="store-badge-text">
                  <small>Coming soon to</small>
                  Google Play
                </span>
              </span>
            </div>
            <p class="band-body band-body-muted">
              In private beta. A web version works today.{' '}
              <a
                href="https://github.com/JonathanRiche/verde/blob/master/docs/serve-pair-connect.md"
                target="_blank"
                rel="noreferrer"
                class="text-link"
              >
                How to pair
              </a>
            </p>
          </div>

          <div class="feature-visual">
            <div class="app-frame mobile-video">
              <video
                class="tour-video-el"
                src="/media/verde-mobile.mp4"
                poster="/media/verde-mobile-poster.webp"
                controls
                playsinline
                preload="none"
                width="1600"
                height="900"
                aria-label="Verde mobile tour, 30 seconds, with sound: approve an edit, steer the turn, review the diff and push"
              />
            </div>
          </div>
        </div>
      </section>

      {/* ── Feature grid ── */}
      <section id="features" class="band">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">Everything in one window</p>
            <h2 class="heading">Everything a coding session needs.</h2>
          </div>

          <div class="feature-grid stagger">
            <For each={featureCards}>
              {(f) => (
                <article class="feature-card">
                  <span class="feat-icon-wrap">
                    <FeatureIcon name={f.icon} />
                  </span>
                  <h3>{f.title}</h3>
                  <p>{f.body}</p>
                </article>
              )}
            </For>
          </div>
        </div>
      </section>

      {/* ── Comparison ── */}
      <section id="compare" class="band band-alt">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">How it compares</p>
            <h2 class="heading">One app instead of three.</h2>
            <p class="band-body">
              What you get with Verde, compared with running agents in a
              terminal, in a hosted app, or inside your IDE.
            </p>
          </div>

          <div class="comp-scroll">
            <table class="comp-table">
              <thead>
                <tr>
                  <th class="comp-rowhead" />
                  <For each={comparisonCols}>
                    {(c, i) => (
                      <th class={i() === 0 ? 'comp-col comp-col--verde' : 'comp-col'}>
                        {c}
                      </th>
                    )}
                  </For>
                </tr>
              </thead>
              <tbody>
                <For each={comparisonRows}>
                  {(row) => (
                    <tr>
                      <th class="comp-rowhead" scope="row">{row.label}</th>
                      <For each={row.cells}>
                        {(cell, i) => (
                          <td class={i() === 0 ? 'comp-td comp-td--verde' : 'comp-td'}>
                            <CompCell value={cell} />
                          </td>
                        )}
                      </For>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
          </div>
          <p class="comp-legend">
            <span><span class="comp-cell comp-cell--yes">✓</span> full</span>
            <span><span class="comp-cell comp-cell--partial">~</span> partial / with effort</span>
            <span><span class="comp-cell comp-cell--no">–</span> not really</span>
          </p>
        </div>
      </section>

      {/* ── Portable theme showcase ── */}
      <Show when={availableThemes.length > 0}>
        <section id="themes" class="themes-band">
          <div class="wrap">
            <div class="band-header band-header--center">
              <p class="tag tag-static">Themes</p>
              <h2 class="heading">It dresses like your desktop.</h2>
              <p class="band-body">
                {availableThemes.length} themes, or let Verde match your desktop
                automatically.
              </p>
            </div>

            <div class="theme-picker" role="tablist" aria-label="Preview Verde under an Omarchy theme">
              <For each={availableThemes}>
                {(t) => (
                  <button
                    type="button"
                    role="tab"
                    aria-selected={theme().slug === t.slug}
                    class={`theme-chip${theme().slug === t.slug ? ' theme-chip--active' : ''}`}
                    onClick={() => setActiveThemeSlug(t.slug)}
                  >
                    <span class="theme-swatch" style={{ background: t.bg }}>
                      <span class="theme-swatch-dot" style={{ background: t.accent }} />
                    </span>
                    {t.name}
                  </button>
                )}
              </For>
            </div>

            <div class="app-frame theme-frame">
              <img
                src={theme().shot}
                alt={`Verde desktop app themed by the Omarchy ${theme().name} theme.`}
                class="theme-screenshot"
                width="2536"
                height="1030"
                loading="lazy"
                decoding="async"
              />
            </div>

            <div class="theme-import-card" aria-live="polite">
              <div class="theme-import-copy">
                <span class="theme-import-kicker">Install {theme().name}</span>
                <code>{themeImportCommand(theme().slug)}</code>
                <span class="theme-import-result">
                  Imports, activates, and adds it to the Settings theme dropdown.
                </span>
              </div>
              <div class="theme-import-actions">
                <CopyButton
                  command={themeImportCommand(theme().slug)}
                  label={`Copy ${theme().name} import command`}
                />
                <a
                  class="theme-json-link"
                  href={themePackageUrl(theme().slug)}
                  download={`${theme().slug}.json`}
                >
                  JSON file
                </a>
              </div>
            </div>

          </div>
        </section>
      </Show>

      {/* ── Frequently asked questions ── */}
      <section id="faq" class="band band-alt">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Common questions</p>
            <h2 class="heading">Before you install.</h2>
          </div>

          <dl class="faq-grid">
            <For each={faqs}>
              {(faq) => (
                <div class="faq-item">
                  <dt>{faq.question}</dt>
                  <dd>{faq.answer}</dd>
                </div>
              )}
            </For>
          </dl>
        </div>
      </section>

      {/* ── Install ── */}
      <section id="install" class="band">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">Install</p>
            <h2 class="heading">One command to install.</h2>
            <p class="band-body">
              You'll need at least one AI coding tool installed and signed in,
              such as Claude Code, Codex, Cursor or OpenCode.
            </p>
          </div>

          <article class="install-primary">
            <div class="install-primary-head">
              <span class="install-tag">Easiest</span>
              <strong>Latest release</strong>
            </div>
            <div class="install-primary-cmd">
              <span class="hero-install-prompt">$</span>
              <code>{DEFAULT_INSTALL_COMMAND}</code>
              <CopyButton command={DEFAULT_INSTALL_COMMAND} />
            </div>
            <p class="install-primary-note">
              <strong>Windows x64 · PowerShell</strong>
            </p>
            <div class="install-primary-cmd">
              <span class="hero-install-prompt">PS&gt;</span>
              <code>{WINDOWS_INSTALL_COMMAND}</code>
              <CopyButton command={WINDOWS_INSTALL_COMMAND} />
            </div>
            <p class="install-primary-note">
              No admin rights needed. Adds a Start Menu shortcut.
            </p>
          </article>

          <button
            type="button"
            class="install-toggle"
            onClick={() => setShowMoreInstall(!showMoreInstall())}
            aria-expanded={showMoreInstall()}
          >
            <span>{showMoreInstall() ? 'Hide other paths' : 'Other install paths'}</span>
            <span class="install-toggle-glyph" aria-hidden="true">
              {showMoreInstall() ? '−' : '+'}
            </span>
          </button>

          <Show when={showMoreInstall()}>
            <div class="install-more rise">
              <article class="install-more-card">
                <strong>Arch Linux (AUR)</strong>
                <pre><code>yay -S verde-bin</code></pre>
              </article>

              <article class="install-more-card">
                <strong>npm launcher</strong>
                <pre><code>npx verde-app</code></pre>
              </article>

              <article class="install-more-card">
                <strong>Custom prefix</strong>
                <pre><code>{`curl -fsSL https://verdeai.dev/install.sh \\
  | VERDE_INSTALL_PREFIX=~/.local sh`}</code></pre>
              </article>

              <article class="install-more-card">
                <strong>From source</strong>
                <pre><code>{`# Linux
bash ./scripts/release/install-linux-local.sh

# macOS
./scripts/release/install-macos-local.sh`}</code></pre>
              </article>
            </div>
          </Show>
        </div>
      </section>

      {/* ── Footer ── */}
      <footer class="site-footer">
        <div class="wrap footer-grid">
          <div class="footer-brand">
            <span
              class="footer-logo logo-mask"
              aria-hidden="true"
              style={{
                'mask-image': `url(${verdeLogoMask})`,
                '-webkit-mask-image': `url(${verdeLogoMask})`,
              }}
            />
            <div>
              <strong>verde</strong>
              <span>All your coding agents in one desktop app.</span>
            </div>
          </div>

          <div class="footer-cols">
            <div class="footer-col">
              <p class="footer-col-title">Project</p>
              <a href="/about" class="footer-link">
                About
              </a>
              <a href="https://github.com/JonathanRiche/verde" target="_blank" rel="noreferrer" class="footer-link">
                GitHub
              </a>
              <a href="https://github.com/JonathanRiche/verde/releases" target="_blank" rel="noreferrer" class="footer-link">
                Releases
              </a>
              <a href="https://github.com/JonathanRiche/verde/blob/master/LICENSE" target="_blank" rel="noreferrer" class="footer-link">
                MIT License
              </a>
            </div>

            <div class="footer-col">
              <p class="footer-col-title">Docs</p>
              <a href="/docs/quickstart" class="footer-link">
                Quickstart
              </a>
              <a href="/docs/providers" class="footer-link">
                Providers
              </a>
              <a href="/docs/cli" class="footer-link">
                CLI reference
              </a>
              <a href="/docs/config" class="footer-link">
                Config &amp; state
              </a>
              <a href="/docs" class="footer-link">
                All docs
              </a>
            </div>

            <div class="footer-col">
              <p class="footer-col-title">Built on</p>
              <a href="https://ziglang.org" target="_blank" rel="noreferrer" class="footer-link">
                Zig
              </a>
              <a href="https://libsdl.org" target="_blank" rel="noreferrer" class="footer-link">
                SDL3
              </a>
              <a href="https://ghostty.org" target="_blank" rel="noreferrer" class="footer-link">
                Ghostty
              </a>
            </div>
          </div>
        </div>
      </footer>
    </main>
  )
}
