import { createFileRoute, getRouteApi } from '@tanstack/solid-router'
import { For, Show, createSignal, onCleanup, onMount } from 'solid-js'

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
    theme: 'M12 3a9 9 0 1 0 9 9c-2 0-3-1-3-3s1-3-1-4-5 1-5-2c0-1-.5-2-0-2z',
    shield: 'M12 3l7 3v5c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z M9 12l2 2 4-4',
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
// protocol; 'tui' = the agent's own TUI launched in an embedded Ghostty
// terminal pane. Source of truth: providers/types.zig and
// state/provider_models.zig (GUI), and workspace/stack.zig (TUI).
const providers = [
  {
    name: 'Codex',
    logo: openAiLogo,
    modes: ['gui', 'tui'],
    blurb: 'Runs the local codex CLI and boots codex app-server when a thread starts.',
  },
  {
    name: 'Claude Code',
    logo: claudeLogo,
    modes: ['gui', 'tui'],
    blurb: 'Talks to your installed Claude Code through the Claude Agent SDK.',
  },
  {
    name: 'OpenCode',
    logo: opencodeLogo,
    modes: ['gui', 'tui'],
    blurb: 'Drives the opencode CLI and starts opencode serve on demand.',
  },
  {
    name: 'Cursor',
    logo: cursorLogo,
    modes: ['gui', 'tui'],
    blurb: 'Speaks to the Cursor CLI ACP server (agent acp) on your machine.',
  },
  {
    name: 'Pi',
    logo: piLogo,
    modes: ['gui', 'tui'],
    blurb: 'Drives the pi CLI in RPC mode (pi --mode rpc) for native chat, and also launches its terminal TUI.',
  },
  {
    name: 'FX',
    logo: fxLogo,
    modes: ['gui', 'tui'],
    blurb: 'Speaks ACP to the fx CLI (fx acp) for native chat, and also launches its terminal TUI.',
  },
  {
    name: 'Grok Build',
    logo: grokLogo,
    modes: ['gui', 'tui'],
    blurb: 'Speaks ACP to the grok CLI (grok agent stdio), and also launches its terminal TUI.',
  },
  {
    name: 'Amp',
    logo: ampLogo,
    modes: ['tui'],
    blurb: 'Launches the amp CLI in an embedded terminal, with hooks that drive live status pips.',
  },
]

const MODE_LABELS: Record<string, string> = {
  gui: 'GUI chat',
  tui: 'Terminal TUI',
}

const featureCards = [
  {
    icon: 'sidebar',
    title: 'Niri-style scrolling panes',
    body: 'When a workspace grows past a couple of panes, switch to a horizontal or vertical strip — free-form panning, resizable columns, sidebar reorder, and per-workspace overrides.',
  },
  {
    icon: 'browser',
    title: 'Browser + Design Mode',
    body: 'Tile a native webview beside your agent, then point at an element or draw a region and send the visual context directly to a chat or terminal TUI.',
  },
  {
    icon: 'terminal',
    title: 'Project-scoped terminal dock',
    body: 'A Ghostty-powered terminal under every workspace. Spawn shell tabs or agent launch-profile tabs, with OSC titles and per-terminal zoom that persist.',
  },
  {
    icon: 'process',
    title: 'Managed workspace processes',
    body: 'Declare your dev server, build watcher, or queue worker once. Start, stop, restart, and inspect them from chat with /stack and /process.',
  },
  {
    icon: 'shield',
    title: 'Local-first, no relay',
    body: 'No hosted inference, no proxy, no telemetry sink. Verde talks to the CLIs already on your machine; tokens, transcripts, and files stay put.',
  },
  {
    icon: 'theme',
    title: 'Themes that match your rig',
    body: 'Import portable theme packages on Linux, macOS, or Windows, or let Verde follow your active Omarchy colors.toml automatically.',
  },
]

const paletteRows = [
  { section: 'App', icon: '⌘', label: 'Scrolling Layout: Always', hint: 'workspace' },
  { section: 'Panes', icon: '▦', label: 'Next Pane', hint: 'Ctrl+Tab' },
  { section: 'Threads', icon: '◷', label: 'Fix split chat keyboard scrolling', hint: 'kit' },
  { section: 'Workspaces', icon: '⦿', label: 'kylos-apparel', hint: 'Alt+1' },
  { section: 'App', icon: '⌘', label: 'Toggle embedded browser', hint: 'Ctrl+Shift+B' },
]

const keybinds = [
  { combo: 'Ctrl+Shift+P', desc: 'Command palette — threads, panes, workspaces' },
  { combo: 'Ctrl+B, then T', desc: 'New chat thread (prefix mode)' },
  { combo: 'Ctrl+B, then Shift+T', desc: 'New standalone terminal pane (prefix mode)' },
  { combo: 'Ctrl+Shift+B', desc: 'Toggle the embedded browser pane' },
  { combo: 'Ctrl+H / J / K / L', desc: 'Move focus across panes (and the scrolling strip)' },
  { combo: 'Ctrl+Tab / Ctrl+Shift+Tab', desc: 'Next / previous pane in sidebar order' },
  { combo: 'Ctrl+Shift+H / J / K / L', desc: 'Swap panes — rearrange the tiling' },
  { combo: 'Alt+Z', desc: 'Zoom the focused pane to fill the workspace' },
  { combo: 'Alt+1 … Alt+9', desc: 'Jump between workspaces by sidebar order' },
  { combo: 'Alt+↑ / Alt+↓', desc: 'Cycle to the previous / next workspace' },
]

const scriptingExamples = [
  {
    label: 'Send a prompt to a specific pane',
    code: `verde live chat send --pane $PANE --prompt "run the tests and fix failures"`,
  },
  {
    label: 'Drive the embedded terminal from a script',
    code: `verde live terminal write --focused --text $'cargo test\\r'`,
  },
  {
    label: 'Split a terminal next to a chat pane',
    code: `verde live pane split --pane $PANE --kind terminal --axis vertical`,
  },
  {
    label: 'Inspect the running app',
    code: `verde live status --json | jq '.result.browser'`,
  },
]

type Cell = boolean | 'partial'
const comparisonCols = ['Verde', 'tmux + CLIs', 'Hosted agent apps', 'IDE extension']
const comparisonRows: { label: string; cells: Cell[] }[] = [
  { label: 'Run several agent CLIs side by side', cells: [true, 'partial', false, 'partial'] },
  { label: 'Native tiling chat / terminal / browser', cells: [true, 'partial', false, false] },
  { label: 'Embedded browser pane', cells: [true, false, 'partial', false] },
  { label: 'Local-only, no hosted relay', cells: [true, true, false, 'partial'] },
  { label: 'Scriptable over local IPC', cells: [true, true, false, false] },
  { label: 'No Electron / Chromium bundle', cells: [true, true, false, false] },
  { label: 'Layouts that persist across launches', cells: [true, 'partial', 'partial', false] },
]

const stack = [
  { label: 'Zig 0.16', detail: 'Native executable, no Electron UI' },
  { label: 'SDL3 + Palette', detail: 'Our Zig GUI framework, built in-tree' },
  { label: 'Ghostty VT', detail: 'Embedded terminal engine (libghostty-vt)' },
  { label: 'Native webview', detail: 'WPE WebKit · WKWebView · WebView2' },
  { label: 'SQLite', detail: 'Local state, projects, threads, transcripts' },
  { label: 'Omarchy themes', detail: 'colors.toml auto-detect on Linux' },
]

const faqs = [
  {
    question: 'What is Verde?',
    answer:
      'Verde is a native desktop workspace for AI coding agents. It tiles agent chats, terminal TUIs, shell terminals, and an embedded browser in one project-scoped window.',
  },
  {
    question: 'Which coding agents does Verde support?',
    answer:
      'Verde supports Codex, Claude Code, OpenCode, Cursor, Pi, FX, and Grok Build in native GUI chat panes. Codex, Claude Code, OpenCode, Cursor, Pi, FX, Grok Build, and Amp also run as terminal TUIs.',
  },
  {
    question: 'Does Verde host models or relay prompts?',
    answer:
      'No. Verde runs and talks to provider CLIs installed on your computer. It does not provide hosted inference or route prompts through a Verde relay.',
  },
  {
    question: 'Which operating systems can run Verde?',
    answer:
      'Verde provides install paths for Linux, macOS, and Windows x64. Its embedded browser uses WPE WebKit on Linux, WKWebView on macOS, and WebView2 on Windows.',
  },
  {
    question: 'Is Verde free and open source?',
    answer:
      'Yes. Verde is MIT-licensed open-source software, and its source code and releases are available on GitHub.',
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
              Local · native · keyboard-first
            </p>
            <h1 class="display">
              Every coding agent.<br />
              <span class="display-accent">One tiling window.</span>
            </h1>
            <p class="lead">
              Verde runs Codex, Claude Code, OpenCode, Cursor, Pi, FX, and
              Grok Build as native chat or terminal TUI panes, with Amp as a
              terminal TUI in the same native desktop app.
              Tile or Niri-style scroll chat, terminal, and browser panes with
              vim keybinds. No hosted relay — Verde just talks to the CLIs
              already on your machine.
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
              alt="Verde desktop app with a sidebar of projects and threads, a chat pane, a terminal pane, and an Amp TUI, themed to match the selected Omarchy theme."
              class="app-screenshot"
              width="2536"
              height="1030"
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
          <p class="strip-eyebrow">Coding agents, one workspace — GUI chat or native TUI</p>
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
                  <p>{p.blurb}</p>
                </article>
              )}
            </For>
          </div>
          <p class="providers-note">
            Codex, Claude Code, OpenCode, Cursor, Pi, FX, and Grok Build can
            run inside an embedded Ghostty terminal pane or drive Verde's native
            chat panes. Amp is a terminal TUI.
            Either way, Verde doesn't host a model or run inference — it drives
            the provider CLIs already installed on your machine, so your tokens,
            transcripts, and project files never leave it.
          </p>
        </div>
      </section>

      {/* ── Feature: tiling ── */}
      <section id="tiling" class="band">
        <div class="wrap feature-row">
          <div class="feature-copy">
            <p class="tag tag-static">Tiling workspace</p>
            <h2 class="heading">A workspace, not a chat box.</h2>
            <p class="band-body">
              Every pane is a first-class window. Split chat, browser, and
              terminal side by side — or let Verde scroll them as a Niri-style
              strip when the workspace fills up. Same vim keybinds either way.
            </p>
            <p class="band-body band-body-muted">
              Automatic, always-on, or disabled per workspace. Free-form wheel
              panning, resizable columns, sidebar reorder, and layouts that
              persist across launches.
            </p>
          </div>

          <div class="feature-visual">
            {/* Pure-CSS diagram: Niri-style horizontal scrolling strip of panes */}
            <div class="tiling-mock" aria-hidden="true">
              <div class="tm-sidebar">
                <span class="tm-dot" />
                <span class="tm-row" />
                <span class="tm-row tm-row--active" />
                <span class="tm-row" />
                <span class="tm-row tm-row--short" />
              </div>
              <div class="tm-main tm-main--scroll">
                <div class="tm-pane tm-pane--chat">
                  <span class="tm-label">chat · claude</span>
                  <span class="tm-line" />
                  <span class="tm-line tm-line--short" />
                  <span class="tm-bubble" />
                </div>
                <div class="tm-pane tm-pane--browser">
                  <span class="tm-label">browser</span>
                  <span class="tm-url" />
                  <span class="tm-block" />
                </div>
                <div class="tm-pane tm-pane--term tm-pane--peek">
                  <span class="tm-label">terminal · zsh</span>
                  <span class="tm-cmd">$ cargo test</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── Feature: command palette ── */}
      <section id="palette" class="band band-alt">
        <div class="wrap feature-row feature-row--reverse">
          <div class="feature-copy">
            <p class="tag tag-static">Command palette</p>
            <h2 class="heading">
              Hit <span class="heading-warm">Ctrl+Shift+P</span>, type, jump.
            </h2>
            <p class="band-body">
              One Raycast-style launcher ranks your threads, open panes,
              workspaces, and app commands in a single list. Search past chats by
              title, hop to any pane, or fire an action without leaving the
              keyboard.
            </p>
            <p class="band-body band-body-muted">
              Ctrl+Enter opens a thread in a fresh pane. Slash commands like{' '}
              <code>/stack</code> and <code>/process</code> run straight from the
              composer alongside each provider's own commands.
            </p>
          </div>

          <div class="feature-visual">
            {/* Pure-CSS mock of the Ctrl+Shift+P launcher overlay */}
            <div class="palette-mock" aria-hidden="true">
              <div class="pm-input">
                <span class="pm-caret-prefix">›</span>
                <span class="pm-query">scroll</span>
                <span class="pm-caret" />
              </div>
              <div class="pm-list">
                <For each={paletteRows}>
                  {(r, i) => (
                    <div class={`pm-row${i() === 0 ? ' pm-row--active' : ''}`}>
                      <span class="pm-row-icon">{r.icon}</span>
                      <span class="pm-row-label">{r.label}</span>
                      <span class="pm-row-section">{r.section}</span>
                      <span class="pm-row-hint">{r.hint}</span>
                    </div>
                  )}
                </For>
              </div>
              <div class="pm-foot">
                <span><kbd>↵</kbd> Open</span>
                <span><kbd>Ctrl+↵</kbd> New pane</span>
                <span><kbd>Esc</kbd> Close</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── Portable theme showcase ── */}
      <Show when={availableThemes.length > 0}>
        <section id="themes" class="themes-band">
          <div class="wrap">
            <div class="band-header band-header--center">
              <p class="tag tag-static">Portable themes</p>
              <h2 class="heading">It dresses like your desktop.</h2>
              <p class="band-body">
                On Omarchy, Verde auto-detects the active theme's{' '}
                <code>colors.toml</code> with no config needed. On any platform,
                pick a palette below and import it from this site. Every shot is
                the real app recaptured under that theme, and this page re-skins
                itself from the same colors.
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

            <p class="themes-note">
              These URLs are ordinary, versioned JSON files, so they also work
              with <code>verde theme validate</code> and automation. Verde still
              follows <code>~/.local/state/omarchy/current/theme/colors.toml</code>{' '}
              automatically. See{' '}
              <a href="/docs/config" class="text-link">Configuration &amp; state</a>{' '}
              for the detection order and manual overrides.
            </p>
          </div>
        </section>
      </Show>

      {/* ── Feature grid ── */}
      <section id="features" class="band">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">Everything in one window</p>
            <h2 class="heading">Built like a workstation tool.</h2>
            <p class="band-body">
              The pieces a coding session actually needs — a browser, a terminal,
              your long-running processes, and every agent — without a browser tab
              or a second app in sight.
            </p>
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

      {/* ── Keybinds ── */}
      <section id="keybinds" class="band band-alt">
        <div class="wrap feature-row">
          <div class="feature-copy">
            <p class="tag tag-static">Keyboard-first</p>
            <h2 class="heading">Your hands stay on home row.</h2>
            <p class="band-body">
              Verde is driven the way you drive your editor and window manager —
              splits, focus, resize, and zoom all have vim-style defaults, and
              every binding is remappable in one config file.
            </p>
            <p class="band-body band-body-muted">
              These are the defaults; override any of them under{' '}
              <code>keybinds</code> in your Verde config.
            </p>
          </div>

          <div class="keybind-card">
            <div class="keybind-head">
              <span class="keybind-head-dot" />
              <span class="keybind-head-dot" />
              <span class="keybind-head-dot" />
              <span class="keybind-head-title">verde.keybinds</span>
            </div>
            <dl class="keybind-list">
              <For each={keybinds}>
                {(k) => (
                  <>
                    <dt>
                      <kbd>{k.combo}</kbd>
                    </dt>
                    <dd>{k.desc}</dd>
                  </>
                )}
              </For>
            </dl>
          </div>
        </div>
      </section>

      {/* ── Scripting / CLI ── */}
      <section id="cli" class="band">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Scripting</p>
            <h2 class="heading">Drive Verde from your shell.</h2>
            <p class="band-body">
              Every running instance exposes current-user local IPC: a Unix
              socket on Linux and macOS, or a named pipe on Windows. The{' '}
              <code>verde live</code> and <code>verde state</code> subcommands let
              you inspect panes, send prompts, write to terminals, and script the
              app from your dotfiles, hooks, or CI.
            </p>
          </div>

          <div class="script-grid stagger">
            <For each={scriptingExamples}>
              {(ex) => (
                <article class="script-card">
                  <div class="script-card-head">
                    <span>{ex.label}</span>
                    <CopyButton command={ex.code} size="sm" />
                  </div>
                  <pre><code>{ex.code}</code></pre>
                </article>
              )}
            </For>
          </div>

          <p class="script-foot">
            Full command surface in{' '}
            <a
              href="/docs/cli"
              class="text-link"
            >
              the CLI reference
            </a>
          </p>
        </div>
      </section>

      {/* ── Comparison ── */}
      <section id="compare" class="band band-alt">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">Where it fits</p>
            <h2 class="heading">Not a multiplexer. Not a chat app.</h2>
            <p class="band-body">
              Verde sits where a terminal multiplexer, a hosted agent app, and an
              IDE plugin each stop short — a native home for every agent you
              already run locally.
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

      {/* ── Under the hood ── */}
      <section id="stack" class="band">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Under the hood</p>
            <h2 class="heading">
              Zig and SDL3, <span class="heading-strike">not Electron.</span>
            </h2>
            <p class="band-body">
              Built as a native desktop package on top of Verde's own Palette UI
              framework. No Electron UI, no bundled Chromium, and no telemetry
              sink — just the ingredients a workstation tool should be made of.
            </p>
          </div>

          <ul class="stack-strip stagger" aria-label="Build ingredients">
            <For each={stack}>
              {(s) => (
                <li class="stack-item">
                  <span class="stack-bullet" aria-hidden="true" />
                  <div>
                    <strong>{s.label}</strong>
                    <span>{s.detail}</span>
                  </div>
                </li>
              )}
            </For>
          </ul>
        </div>
      </section>

      {/* ── Frequently asked questions ── */}
      <section id="faq" class="band band-alt">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Common questions</p>
            <h2 class="heading">Verde, in plain language.</h2>
            <p class="band-body">
              The short version of how Verde fits into a local AI coding
              workflow.
            </p>
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
            <h2 class="heading">One command on Linux, macOS, or Windows.</h2>
            <p class="band-body">
              The installer detects your platform, downloads the matching release
              artifact from GitHub, and installs Verde into <code>~/.local</code>,{' '}
              <code>/Applications</code>, or your Windows user profile.
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
              Windows installs without administrator access and creates a Start
              Menu shortcut. Then install and authenticate at least one provider CLI —{' '}
              <code>codex login</code>, Claude Code, <code>opencode</code>,{' '}
              <code>agent login</code> for Cursor, <code>pi</code>,{' '}
              <code>fx login</code>, <code>grok login</code>, or{' '}
              <code>amp</code>.
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
              <span>A tiling desktop for AI coding agents.</span>
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
