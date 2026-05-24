import { createFileRoute } from '@tanstack/solid-router'
import { For, Show, createSignal, onCleanup } from 'solid-js'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import openAiLogo from '../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import claudeLogo from '../../../desktop/src/assets/claude-logo.png'
import opencodeLogo from '../../../desktop/src/assets/opencode-logo-dark.png'
import cursorLogo from '../../../desktop/src/assets/editor_logos/cursor.png'
import appScreenshot from '../../../../assets/app_screenshot.png'

export const Route = createFileRoute('/')({ component: App })

const DEFAULT_INSTALL_COMMAND =
  'curl -fsSL https://verdeai.dev/install.sh | sh'

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
        aria-label={
          copied() ? 'Copied to clipboard' : 'Copy to clipboard'
        }
      >
        {copied() ? <CheckGlyph /> : <ClipboardGlyph />}
      </button>
    </span>
  )
}

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

const stack = [
  { label: 'Zig 0.16', detail: 'Single static binary, no Electron' },
  { label: 'SDL3 + Palette', detail: "Our Zig GUI framework, built in-tree" },
  { label: 'Ghostty VT', detail: 'Embedded terminal engine (libghostty-vt)' },
  { label: 'Native webview', detail: 'WPE WebKit · WKWebView · WebView2' },
  { label: 'SQLite', detail: 'Local state, projects, threads, transcripts' },
  { label: 'Omarchy themes', detail: 'colors.toml auto-detect on Linux' },
]

const keybinds = [
  { combo: 'Ctrl+T', desc: 'New chat thread' },
  { combo: 'Ctrl+Shift+T', desc: 'Split a terminal pane below the focus' },
  { combo: 'Alt+1 … Alt+9', desc: 'Jump between workspaces by sidebar order' },
  { combo: 'Ctrl+H/J/K/L', desc: 'Move focus across panes, vim-style' },
  { combo: 'Ctrl+Shift+H/J/K/L', desc: 'Swap panes — rearrange the tiling' },
  { combo: 'Ctrl+B', desc: 'Toggle the embedded browser pane' },
  { combo: 'Ctrl+= / Ctrl+−', desc: 'Per-terminal font scale, restored with layout' },
  { combo: 'Tab', desc: 'Return focus to the chat composer' },
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

function App() {
  const [showMoreInstall, setShowMoreInstall] = createSignal(false)

  return (
    <main>
      {/* ── Hero ── */}
      <section class="hero">
        <div class="hero-grid-bg" aria-hidden="true" />
        <div class="hero-backdrop" aria-hidden="true" />

        <div class="wrap">
          <div class="hero-content rise">
            <p class="tag">
              <span class="tag-pulse" />
              Local · native · keyboard-first
            </p>
            <h1 class="display">
              A tiling workspace<br />for AI coding agents.
            </h1>
            <p class="lead">
              Verde runs Codex, Claude Code, OpenCode, and Cursor side by side
              in one native desktop window. Split chat, terminal, and browser
              panes with vim-style keybinds. No hosted relay — Verde just talks
              to the CLIs already on your machine.
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
          <p class="stage-caption">
            One window. Sidebar of projects and threads, tiled chat and browser
            panes, embedded terminal below — all native, all keyboard-driven.
          </p>
        </div>
      </section>

      {/* ── Providers ── */}
      <section id="providers" class="band band-providers">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Providers</p>
            <h2 class="heading">
              Four agent runtimes. <span class="heading-warm">One window.</span>
            </h2>
            <p class="band-body">
              Verde doesn't host a model or run an inference service. It talks
              to the provider CLIs already on your machine, so your tokens,
              transcripts, and project files stay where you put them.
            </p>
          </div>

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
        </div>
      </section>

      {/* ── Stack / under the hood ── */}
      <section id="stack" class="band band-alt">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Under the hood</p>
            <h2 class="heading">
              Zig and SDL3, <span class="heading-strike">not Electron.</span>
            </h2>
            <p class="band-body">
              Built as a single native binary on top of Verde's own Palette UI
              framework. The ingredients are picked for a workstation tool — no
              Chromium bundle, no JavaScript runtime, no telemetry sink.
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

      {/* ── Tiling / keybinds ── */}
      <section id="tiling" class="band">
        <div class="wrap tiling-grid">
          <div class="tiling-copy">
            <p class="tag tag-static">Tiling workspace</p>
            <h2 class="heading">
              A workspace, not a chat box.
            </h2>
            <p class="band-body">
              Every pane is a first-class window. Split chat threads next to
              their browser pane, drop a terminal underneath, and arrange the
              tiling with the same muscle memory you use everywhere else.
            </p>
            <p class="band-body band-body-muted">
              Workspace layouts and per-terminal zoom persist across launches.
              Right-click any terminal pane to spawn shell tabs, agent
              launch-profile tabs, or new workspace splits around it.
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
      <section id="scripting" class="band band-alt">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Scripting</p>
            <h2 class="heading">
              Drive Verde from your shell.
            </h2>
            <p class="band-body">
              Every running Verde instance exposes a Unix-socket IPC. The
              <code>verde live</code> and <code>verde state</code> subcommands
              let you inspect panes, send prompts, write to terminals, and
              script the app from your dotfiles, hooks, or CI.
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

      {/* ── Install ── */}
      <section id="install" class="band">
        <div class="wrap">
          <div class="band-header">
            <p class="tag tag-static">Install</p>
            <h2 class="heading">
              One command on Linux or macOS.
            </h2>
            <p class="band-body">
              The installer detects your platform, downloads the matching
              release artifact from GitHub, and drops Verde into{' '}
              <code>~/.local</code> or <code>/Applications</code>.
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
              <code>codex login</code>, Claude Code,{' '}
              <code>opencode</code>, or <code>agent login</code> for Cursor.
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
              <a
                href="https://github.com/JonathanRiche/verde"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                GitHub
              </a>
              <a
                href="https://github.com/JonathanRiche/verde/releases"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                Releases
              </a>
              <a
                href="https://github.com/JonathanRiche/verde/blob/master/LICENSE"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                MIT License
              </a>
            </div>

            <div class="footer-col">
              <p class="footer-col-title">Docs</p>
              <a
                href="https://github.com/JonathanRiche/verde#getting-started"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                Getting started
              </a>
              <a
                href="https://github.com/JonathanRiche/verde#cli-and-live-control"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                CLI reference
              </a>
              <a
                href="https://github.com/JonathanRiche/verde#config-and-state"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                Config &amp; themes
              </a>
            </div>

            <div class="footer-col">
              <p class="footer-col-title">Built on</p>
              <a
                href="https://ziglang.org"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                Zig
              </a>
              <a
                href="https://libsdl.org"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                SDL3
              </a>
              <a
                href="https://ghostty.org"
                target="_blank"
                rel="noreferrer"
                class="footer-link"
              >
                Ghostty
              </a>
            </div>
          </div>
        </div>
      </footer>
    </main>
  )
}
