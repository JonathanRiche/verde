import { createFileRoute } from '@tanstack/solid-router'
import { For } from 'solid-js'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import openAiLogo from '../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import cursorLogo from '../../../desktop/src/assets/editor_logos/cursor.png'
import neovimLogo from '../../../desktop/src/assets/editor_logos/neovim.png'
import vscodeLogo from '../../../desktop/src/assets/editor_logos/vscode.png'
import zedLogo from '../../../desktop/src/assets/editor_logos/zed.png'
import appScreenshot from '../../../../assets/app_screenshot.png'

export const Route = createFileRoute('/')({ component: App })

const features = [
  {
    title: 'Local providers, no hosted middle layer',
    description:
      'Verde talks to the Codex and OpenCode CLIs already installed on your machine, then keeps each thread tied to the project you imported.',
  },
  {
    title: 'Browser and terminal beside the thread',
    description:
      'Keep the browser pane open for inspection, drop the embedded terminal with Ctrl+J, and stay inside the same desktop session.',
  },
  {
    title: 'Built for long coding sessions',
    description:
      'Native Zig, SDL3, OpenGL, and a dark UI tuned for project-scoped work instead of bouncing between tabs and floating terminals.',
  },
]

const workflowSteps = [
  {
    index: '01',
    title: 'Import the repo you already work in',
    description:
      'Point Verde at a project directory and keep the provider runtime scoped to that workspace from the first prompt onward.',
    detail:
      'Project-scoped state, thread history, and file search stay attached to the repo.',
  },
  {
    index: '02',
    title: 'Switch providers without leaving the desktop shell',
    description:
      'Run Codex or OpenCode from the same app and keep the surrounding browser, chat, and terminal context intact.',
    detail:
      'Codex threads can boot codex app-server automatically; OpenCode threads can boot opencode serve.',
  },
  {
    index: '03',
    title: 'Read, test, and iterate in one window',
    description:
      'Use the browser pane for inspection, the transcript for agent work, and the bottom terminal dock for commands that belong to the repo.',
    detail:
      'The terminal opens in the selected project directory and leaves sidebar width untouched.',
  },
]

const editors = [
  { name: 'VS Code', logo: vscodeLogo },
  { name: 'Cursor', logo: cursorLogo },
  { name: 'Zed', logo: zedLogo },
  { name: 'Neovim', logo: neovimLogo },
]

function App() {
  return (
    <main>
      {/* ── Hero ── */}
      <section class="hero">
        <div class="hero-backdrop" aria-hidden="true" />

        <div class="wrap">
          <div class="hero-content rise">
            <p class="tag">Desktop workspace for coding agents</p>
            <h1 class="display">
              One native shell for the thread, browser, and terminal.
            </h1>
            <p class="lead">
              Import a repo, connect Codex or OpenCode through the local CLIs
              you already use, and work inside a native desktop shell built for
              longer sessions.
            </p>
            <div class="hero-actions">
              <a
                href="https://github.com/JonathanRiche/verde/releases"
                target="_blank"
                rel="noreferrer"
                class="btn btn-primary"
              >
                Install Verde
              </a>
              <a href="#install" class="btn btn-ghost">
                Build from source
              </a>
            </div>
            <div class="hero-install-preview" aria-label="Quick install commands">
              <div class="hero-install-tabs">
                <span>Arch Linux</span>
                <span>macOS / npm</span>
              </div>
              <div class="hero-install-lines">
                <p>
                  <span class="prompt">$</span> yay -S verde-bin
                </p>
                <p>
                  <span class="prompt">$</span> npm install -g verde-app
                </p>
              </div>
            </div>
            <ul class="hero-highlights stagger" aria-label="Verde highlights">
              <li>Codex and OpenCode</li>
              <li>Embedded browser pane</li>
              <li>Project-scoped terminal dock</li>
            </ul>
          </div>
        </div>

        {/* Full-width workspace mockup */}
        <div class="stage-wrap">
          <div class="app-frame rise" style={{ 'animation-delay': '180ms' }}>
            <img
              src={appScreenshot}
              alt="Verde desktop app with a project sidebar, agent thread, browser pane, and terminal dock."
              class="app-screenshot"
            />
          </div>
        </div>
      </section>

      {/* ── Features (bento grid) ── */}
      <section id="product" class="band">
        <div class="wrap">
          <div class="band-header">
            <p class="tag">What's inside</p>
            <h2 class="heading">
              Local tools, native performance, one workspace.
            </h2>
            <p class="band-body">
              Verde is structured around how the desktop app works: local
              provider CLIs, imported project directories, and a UI that keeps
              the moving pieces visible.
            </p>
          </div>

          <div class="bento stagger">
            {/* Wide card – providers */}
            <article class="bento-card bento-wide">
              <div class="card-visual">
                <div class="card-providers">
                  <div class="card-pill">
                    <img src={openAiLogo} alt="" />
                    <span>Codex CLI</span>
                  </div>
                  <div class="card-pill">
                    <span
                      class="provider-pill-badge"
                      style={{
                        width: '1.1rem',
                        height: '1.1rem',
                        'font-size': '0.55rem',
                      }}
                    >
                      OC
                    </span>
                    <span>OpenCode</span>
                  </div>
                </div>
              </div>
              <div class="card-body">
                <h3>{features[0].title}</h3>
                <p>{features[0].description}</p>
              </div>
            </article>

            {/* Browser card */}
            <article class="bento-card">
              <div class="card-visual">
                <div class="card-browser">
                  <div class="card-browser-bar">
                    <div class="dots">
                      <span />
                      <span />
                      <span />
                    </div>
                    <div class="url">localhost:3000</div>
                  </div>
                  <div class="card-browser-content">
                    <div class="skeleton">
                      <span style={{ width: '72%' }} />
                      <span style={{ width: '88%' }} />
                      <span style={{ width: '55%' }} />
                      <span style={{ width: '40%' }} />
                    </div>
                  </div>
                </div>
              </div>
              <div class="card-body">
                <h3>{features[1].title}</h3>
                <p>{features[1].description}</p>
              </div>
            </article>

            {/* Terminal card */}
            <article class="bento-card">
              <div class="card-visual">
                <div class="card-terminal">
                  <div class="card-terminal-bar">
                    <span class="tab-active">shell</span>
                    <span>build</span>
                  </div>
                  <div class="card-terminal-content">
                    <p>
                      <span class="prompt">$</span> zig build run
                    </p>
                    <p>
                      <span class="prompt">$</span> zig build test
                    </p>
                    <p style={{ color: 'var(--diff-add)' }}>
                      47 passed, 0 failed
                    </p>
                  </div>
                </div>
              </div>
              <div class="card-body">
                <h3>{features[2].title}</h3>
                <p>{features[2].description}</p>
              </div>
            </article>
          </div>
        </div>
      </section>

      {/* ── Workflow ── */}
      <section id="flow" class="band band-alt">
        <div class="wrap flow-grid">
          <div class="flow-aside">
            <div class="flow-aside-sticky">
              <p class="tag">Workflow</p>
              <h2 class="heading">
                One desktop workspace from first prompt to final command.
              </h2>
              <p class="band-body">
                The product story is simple: bring the repo in, start the
                provider you want, keep the browser pane next to the transcript,
                and pull the terminal up only when the work needs it.
              </p>
              <div class="editor-strip" aria-label="Editor compatibility">
                <For each={editors}>
                  {(editor) => (
                    <div class="editor-chip">
                      <img src={editor.logo} alt="" />
                      <span>{editor.name}</span>
                    </div>
                  )}
                </For>
              </div>
            </div>
          </div>

          <div class="flow-steps stagger">
            <For each={workflowSteps}>
              {(step) => (
                <article class="step">
                  <div class="step-num">{step.index}</div>
                  <div class="step-body">
                    <h3>{step.title}</h3>
                    <p>{step.description}</p>
                    <small>{step.detail}</small>
                  </div>
                </article>
              )}
            </For>
          </div>
        </div>
      </section>

      {/* ── Install ── */}
      <section id="install" class="band">
        <div class="wrap">
          <div class="band-header">
            <p class="tag">Install</p>
            <h2 class="heading">
              Ship it from releases or build it straight from the repo.
            </h2>
            <p class="band-body">
              Verde has release artifacts for Linux and macOS, an AUR package
              for Arch, an npm launcher, and source installers for local builds
              with the embedded browser pane.
            </p>
          </div>

          <div class="install-grid stagger">
            <article class="term-card">
              <div class="term-card-header">
                <span>Release path</span>
                <strong>Download and install</strong>
              </div>
              <p>Grab the latest packaged build from GitHub Releases.</p>
              <a
                href="https://github.com/JonathanRiche/verde/releases"
                target="_blank"
                rel="noreferrer"
                class="text-link"
              >
                Open release downloads
              </a>
            </article>

            <article class="term-card">
              <div class="term-card-header">
                <span>Source path</span>
                <strong>Install from source</strong>
              </div>
              <pre>
                <code>{`# Linux with embedded browser pane
bash ./scripts/release/install-linux-local-cef.sh

# macOS app bundle with CEF
./scripts/release/install-macos-local.sh`}</code>
              </pre>
            </article>

            <article class="term-card term-card-span">
              <div class="term-card-header">
                <span>Other install paths</span>
                <strong>Arch, npm, or plain Zig</strong>
              </div>
              <p>
                Use the AUR package on Arch, the npm launcher on supported
                developer machines, or install from the repo root with Zig.
              </p>
              <div class="install-prereqs">
                <div>
                  <strong>Package managers</strong>
                  <pre>
                    <code>{`yay -S verde-bin
npx verde-app`}</code>
                  </pre>
                </div>
                <div>
                  <strong>Repo root</strong>
                  <pre>
                    <code>zig build --release=safe -p ~/.local</code>
                  </pre>
                </div>
              </div>
            </article>

            <article class="term-card term-card-span">
              <div class="term-card-header">
                <span>CLI prerequisites</span>
                <strong>Bring your provider runtime</strong>
              </div>
              <p>
                Install and authenticate at least one local provider to use
                Verde.
              </p>
              <div class="install-prereqs">
                <div>
                  <strong>Codex</strong>
                  <pre>
                    <code>codex login</code>
                  </pre>
                </div>
                <div>
                  <strong>OpenCode</strong>
                  <pre>
                    <code>opencode</code>
                  </pre>
                </div>
              </div>
            </article>
          </div>
        </div>
      </section>

      {/* ── Footer ── */}
      <footer class="site-footer">
        <div class="wrap footer-inner">
          <div class="footer-brand">
            <img src={verdeLogo} alt="" />
            <span>verde</span>
          </div>
          <div class="footer-links">
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
          </div>
        </div>
      </footer>
    </main>
  )
}
