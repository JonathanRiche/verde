import { createFileRoute } from '@tanstack/solid-router'
import { For, Show, createSignal, onCleanup } from 'solid-js'

import openAiLogo from '../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import claudeLogo from '../../../desktop/src/assets/claude-logo.png'
import opencodeLogo from '../../../desktop/src/assets/opencode-logo-dark.png'
import cursorLogo from '../../../desktop/src/assets/editor_logos/cursor.png'
import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import appScreenshot from '../../../../assets/green_verde.png'

export const Route = createFileRoute('/')({ component: App })

const DEFAULT_INSTALL_COMMAND = 'curl -fsSL https://verdeai.dev/install.sh | sh'

/* ───────────────────────── Copy button ───────────────────────── */

function ClipboardGlyph() {
  return (
    <svg class="copy-svg" viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m4 0v10a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7h16Z"
      />
    </svg>
  )
}

function CheckGlyph() {
  return (
    <svg class="copy-svg" viewBox="0 0 24 24" aria-hidden="true">
      <path
        fill="none"
        stroke="currentColor"
        stroke-width="2.5"
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M5 13l4 4L19 7"
      />
    </svg>
  )
}

function CopyButton(props: { command: string; size?: 'sm' | 'md' }) {
  const [copied, setCopied] = createSignal(false)
  let copyTimer: ReturnType<typeof setTimeout> | undefined
  let sourceInput: HTMLInputElement | undefined

  onCleanup(() => {
    if (copyTimer !== undefined) clearTimeout(copyTimer)
  })

  function showCopied() {
    setCopied(true)
    if (copyTimer !== undefined) clearTimeout(copyTimer)
    copyTimer = setTimeout(() => setCopied(false), 2000)
  }

  function handleCopy(ev: MouseEvent) {
    ev.preventDefault()
    ev.stopPropagation()
    const el = sourceInput
    if (el) {
      el.focus()
      el.select()
      el.setSelectionRange(0, el.value.length)
      try {
        if (document.execCommand('copy')) {
          showCopied()
          return
        }
      } catch {
        /* fall through */
      }
    }
    if (navigator.clipboard?.writeText) {
      void navigator.clipboard
        .writeText(props.command)
        .then(() => showCopied(), () => {})
    }
  }

  return (
    <span class="copy-wrap">
      <input
        ref={(el) => {
          sourceInput = el
        }}
        type="text"
        class="copy-source"
        readOnly
        tabIndex={-1}
        aria-hidden="true"
        value={props.command}
      />
      <button
        type="button"
        class={`copy-btn copy-btn--${props.size ?? 'md'}${copied() ? ' copy-btn--done' : ''}`}
        onClick={handleCopy}
        aria-label={copied() ? 'Copied to clipboard' : 'Copy to clipboard'}
      >
        {copied() ? <CheckGlyph /> : <ClipboardGlyph />}
      </button>
    </span>
  )
}

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

const providers = [
  {
    name: 'Codex',
    logo: openAiLogo,
    blurb: 'Runs the local codex CLI and boots codex app-server when a thread starts.',
  },
  {
    name: 'Claude Code',
    logo: claudeLogo,
    blurb: 'Talks to your installed Claude Code through the Claude Agent SDK.',
  },
  {
    name: 'OpenCode',
    logo: opencodeLogo,
    blurb: 'Drives the opencode CLI and starts opencode serve on demand.',
  },
  {
    name: 'Cursor',
    logo: cursorLogo,
    blurb: 'Speaks to the Cursor CLI ACP server (agent acp) on your machine.',
  },
]

const featureCards = [
  {
    icon: 'browser',
    title: 'Embedded browser pane',
    body: 'A real native webview tiled next to your agent — WPE WebKit on Linux, WKWebView on macOS, WebView2 on Windows. Toggle it with Ctrl+B.',
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
    icon: 'sidebar',
    title: 'Live-state sidebar',
    body: 'Projects, threads, and running agents in one rail — each pane shows its provider glyph and a live title, so you always know what is working.',
  },
  {
    icon: 'shield',
    title: 'Local-first, no relay',
    body: 'No hosted inference, no proxy, no telemetry sink. Verde talks to the CLIs already on your machine; tokens, transcripts, and files stay put.',
  },
  {
    icon: 'theme',
    title: 'Themes that match your rig',
    body: 'A warm-green native theme out of the box, with Omarchy colors.toml auto-detection on Linux so the app blends into your desktop.',
  },
]

const paletteRows = [
  { section: 'Threads', icon: '◷', label: 'Fix split chat keyboard scrolling', hint: 'kit' },
  { section: 'Threads', icon: '◷', label: 'Restore GUI thread sync controls', hint: 'verde' },
  { section: 'Panes', icon: '▦', label: 'Jump to browser pane', hint: 'Ctrl+L' },
  { section: 'Workspaces', icon: '⦿', label: 'kylos-apparel', hint: 'Alt+1' },
  { section: 'App', icon: '⌘', label: 'Toggle embedded browser', hint: 'Ctrl+B' },
]

const keybinds = [
  { combo: 'Ctrl+P', desc: 'Command palette — threads, panes, workspaces' },
  { combo: 'Ctrl+T', desc: 'New chat thread' },
  { combo: 'Ctrl+Shift+T', desc: 'Split a terminal pane next to the focus' },
  { combo: 'Ctrl+B', desc: 'Toggle the embedded browser pane' },
  { combo: 'Ctrl+H / J / K / L', desc: 'Move focus across panes, vim-style' },
  { combo: 'Ctrl+Shift+H / J / K / L', desc: 'Swap panes — rearrange the tiling' },
  { combo: 'Alt+Shift+←↑↓→', desc: 'Resize the focused pane' },
  { combo: 'Alt+Z', desc: 'Zoom the focused pane to fill the workspace' },
  { combo: 'Alt+1 … Alt+9', desc: 'Jump between workspaces by sidebar order' },
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
  { label: 'Scriptable over a local IPC socket', cells: [true, true, false, false] },
  { label: 'No Electron / Chromium bundle', cells: [true, true, false, false] },
  { label: 'Layouts that persist across launches', cells: [true, 'partial', 'partial', false] },
]

const stack = [
  { label: 'Zig 0.16', detail: 'Single static binary, no Electron' },
  { label: 'SDL3 + Palette', detail: 'Our Zig GUI framework, built in-tree' },
  { label: 'Ghostty VT', detail: 'Embedded terminal engine (libghostty-vt)' },
  { label: 'Native webview', detail: 'WPE WebKit · WKWebView · WebView2' },
  { label: 'SQLite', detail: 'Local state, projects, threads, transcripts' },
  { label: 'Omarchy themes', detail: 'colors.toml auto-detect on Linux' },
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

  return (
    <main>
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
              Verde runs Codex, Claude Code, OpenCode, and Cursor side by side in
              one native desktop app. Tile chat, terminal, and browser panes with
              vim keybinds. No hosted relay — Verde just talks to the CLIs already
              on your machine.
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
                Linux and macOS · pulls the latest GitHub release
              </p>
            </div>
          </div>
        </div>

        <div class="stage-wrap">
          <div class="app-frame rise" style={{ 'animation-delay': '180ms' }}>
            <img
              src={appScreenshot}
              alt="Verde desktop app with a sidebar of projects and threads, a chat pane, a browser pane, and an embedded terminal dock."
              class="app-screenshot"
            />
          </div>
        </div>
      </section>

      {/* ── Provider strip ── */}
      <section id="providers" class="providers-band">
        <div class="wrap">
          <p class="strip-eyebrow">Four agent runtimes, one workspace</p>
          <div class="provider-grid stagger">
            <For each={providers}>
              {(p) => (
                <article class="provider-card">
                  <div class="provider-card-head">
                    <img src={p.logo} alt="" class="provider-card-logo" />
                    <h3>{p.name}</h3>
                  </div>
                  <p>{p.blurb}</p>
                </article>
              )}
            </For>
          </div>
          <p class="providers-note">
            Verde doesn't host a model or run inference. It drives the provider
            CLIs already installed on your machine, so your tokens, transcripts,
            and project files never leave it.
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
              Every pane is a first-class window. Split a chat thread beside its
              browser pane, drop a terminal underneath, and rearrange the tiling
              with the same muscle memory you use in your window manager.
            </p>
            <p class="band-body band-body-muted">
              Layouts and per-terminal zoom persist across launches. Right-click
              any terminal to spawn shell tabs, agent launch-profile tabs, or new
              splits around it.
            </p>
          </div>

          <div class="feature-visual">
            {/* Pure-CSS diagram of a tiled workspace: chat + browser over a terminal dock */}
            <div class="tiling-mock" aria-hidden="true">
              <div class="tm-sidebar">
                <span class="tm-dot" />
                <span class="tm-row" />
                <span class="tm-row tm-row--active" />
                <span class="tm-row" />
                <span class="tm-row tm-row--short" />
              </div>
              <div class="tm-main">
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
                <div class="tm-pane tm-pane--term">
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
              Hit <span class="heading-warm">Ctrl+P</span>, type, jump.
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
            {/* Pure-CSS mock of the Ctrl+P launcher overlay */}
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
              Every running instance exposes a Unix-socket IPC. The{' '}
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
              href="https://github.com/JonathanRiche/verde#cli-and-live-control"
              target="_blank"
              rel="noreferrer"
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
              Built as a single native binary on top of Verde's own Palette UI
              framework. No Chromium bundle, no JavaScript runtime, no telemetry
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

      {/* ── Install ── */}
      <section id="install" class="band band-alt">
        <div class="wrap">
          <div class="band-header band-header--center">
            <p class="tag tag-static">Install</p>
            <h2 class="heading">One command on Linux or macOS.</h2>
            <p class="band-body">
              The installer detects your platform, downloads the matching release
              artifact from GitHub, and drops Verde into <code>~/.local</code> or{' '}
              <code>/Applications</code>.
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
              Then install and authenticate at least one provider CLI —{' '}
              <code>codex login</code>, Claude Code, <code>opencode</code>, or{' '}
              <code>agent login</code> for Cursor.
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
            <img src={verdeLogo} alt="" />
            <div>
              <strong>verde</strong>
              <span>A tiling desktop for AI coding agents.</span>
            </div>
          </div>

          <div class="footer-cols">
            <div class="footer-col">
              <p class="footer-col-title">Project</p>
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
              <a href="https://github.com/JonathanRiche/verde#getting-started" target="_blank" rel="noreferrer" class="footer-link">
                Getting started
              </a>
              <a href="https://github.com/JonathanRiche/verde#cli-and-live-control" target="_blank" rel="noreferrer" class="footer-link">
                CLI reference
              </a>
              <a href="https://github.com/JonathanRiche/verde#config-and-state" target="_blank" rel="noreferrer" class="footer-link">
                Config &amp; themes
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
