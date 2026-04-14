import { createFileRoute } from '@tanstack/solid-router'
import { For } from 'solid-js'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import openAiLogo from '../../../desktop/src/assets/OpenAI-white-monoblossom.png'
import cursorLogo from '../../../desktop/src/assets/editor_logos/cursor.png'
import neovimLogo from '../../../desktop/src/assets/editor_logos/neovim.png'
import vscodeLogo from '../../../desktop/src/assets/editor_logos/vscode.png'
import zedLogo from '../../../desktop/src/assets/editor_logos/zed.png'

export const Route = createFileRoute('/')({ component: App })

const workspaceSignals = [
  {
    title: 'Local providers, no hosted middle layer',
    description:
      'Verde talks to the Codex and OpenCode CLIs already installed on your machine, then keeps each thread tied to the project you imported.',
  },
  {
    title: 'Browser and terminal beside the thread',
    description:
      'Keep the browser pane open for inspection, drop the embedded terminal with CommandOrControl+J, and stay inside the same desktop session.',
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
    detail: 'Project-scoped state, thread history, and file search stay attached to the repo.',
  },
  {
    index: '02',
    title: 'Switch providers without leaving the desktop shell',
    description:
      'Run Codex or OpenCode from the same app and keep the surrounding browser, chat, and terminal context intact.',
    detail: 'Codex threads can boot codex app-server automatically; OpenCode threads can boot opencode serve.',
  },
  {
    index: '03',
    title: 'Read, test, and iterate in one window',
    description:
      'Use the browser pane for inspection, the transcript for agent work, and the bottom terminal dock for commands that belong to the repo.',
    detail: 'The terminal opens in the selected project directory and leaves sidebar width untouched.',
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
    <main class="marketing-page">
      <section class="hero-shell">
        <div class="hero-field" aria-hidden="true" />

        <div class="page-wrap hero-layout">
          <div class="hero-copy rise-in">
            <p class="eyebrow">Desktop workspace for coding agents</p>
            <h1 class="hero-title">
              Verde keeps the thread, the browser, and the terminal in one
              place.
            </h1>
            <p class="hero-body">
              Import a repo, connect Codex or OpenCode through the local CLIs
              you already use, and work inside a native desktop shell built for
              longer sessions.
            </p>

            <div class="hero-actions">
              <a
                href="https://github.com/JonathanRiche/verde/releases"
                target="_blank"
                rel="noreferrer"
                class="action-primary"
              >
                Install Verde
              </a>
              <a href="#install" class="action-secondary">
                Build From Source
              </a>
            </div>

            <ul class="hero-points" aria-label="Verde highlights">
              <li>Codex and OpenCode</li>
              <li>Embedded browser pane</li>
              <li>Project-scoped terminal dock</li>
            </ul>
          </div>

          <div class="workspace-stage rise-in" style={{ 'animation-delay': '120ms' }}>
            <div class="workspace-topbar">
              <div class="workspace-brand">
                <img src={verdeLogo} alt="Verde" class="workspace-brand-logo" />
                <span>verde</span>
              </div>
              <div class="workspace-project">~/development/verde</div>
              <div class="workspace-window-controls" aria-hidden="true">
                <span />
                <span />
                <span />
              </div>
            </div>

            <div class="workspace-body">
              <aside class="workspace-sidebar">
                <p class="mini-label">Workspace</p>
                <div class="workspace-nav">
                  <div class="workspace-nav-item is-active">
                    <span>chat</span>
                    <strong>verde</strong>
                  </div>
                  <div class="workspace-nav-item">
                    <span>browser</span>
                    <strong>docs and app flow</strong>
                  </div>
                  <div class="workspace-nav-item">
                    <span>terminal</span>
                    <strong>project shell</strong>
                  </div>
                </div>

                <div class="provider-stack">
                  <div class="provider-pill">
                    <img src={openAiLogo} alt="" />
                    <span>Codex CLI</span>
                  </div>
                  <div class="provider-pill provider-pill-text">
                    <span>OC</span>
                    <span>OpenCode</span>
                  </div>
                </div>
              </aside>

              <div class="workspace-columns">
                <section class="surface-panel transcript-panel">
                  <div class="surface-header">
                    <span>Thread</span>
                    <strong>Provider runtime</strong>
                  </div>

                  <div class="transcript-stream">
                    <div class="transcript-bubble transcript-bubble-agent">
                      <p class="bubble-author">Codex</p>
                      <p>
                        App server ready. Imported project detected at{' '}
                        <code>/home/rtg/development/verde</code>.
                      </p>
                    </div>
                    <div class="transcript-bubble transcript-bubble-user">
                      <p class="bubble-author">You</p>
                      <p>
                        Keep the browser open on the docs and drop a terminal
                        below the thread.
                      </p>
                    </div>
                    <div class="transcript-bubble transcript-bubble-agent">
                      <p class="bubble-author">Verde</p>
                      <p>
                        Browser pane synced. Terminal dock toggled with{' '}
                        <code>CommandOrControl+J</code>.
                      </p>
                    </div>
                  </div>
                </section>

                <section class="surface-panel browser-panel">
                  <div class="surface-header">
                    <span>Browser pane</span>
                    <strong>Embedded alongside the thread</strong>
                  </div>

                  <div class="browser-shell">
                    <div class="browser-toolbar">
                      <span class="browser-dot" />
                      <span class="browser-dot" />
                      <span class="browser-dot" />
                      <div class="browser-address">
                        github.com/JonathanRiche/verde
                      </div>
                    </div>

                    <div class="browser-canvas">
                      <div class="browser-note">
                        <p>Inspect docs, review agent output, keep context live.</p>
                      </div>

                      <div class="browser-lines" aria-hidden="true">
                        <span />
                        <span />
                        <span />
                        <span />
                      </div>
                    </div>
                  </div>
                </section>
              </div>
            </div>

            <div class="terminal-dock">
              <div class="surface-header">
                <span>Terminal dock</span>
                <strong>Scoped to the selected project</strong>
              </div>

              <div class="terminal-lines">
                <p>
                  <span class="prompt">$</span> zig build run
                </p>
                <p>
                  <span class="prompt">$</span> codex login
                </p>
                <p>
                  <span class="prompt">$</span> opencode serve --hostname
                  127.0.0.1 --port 4096
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section id="product" class="section-band">
        <div class="page-wrap split-layout">
          <div class="section-copy">
            <p class="eyebrow">Native shell</p>
            <h2 class="section-title">
              Use local tools without stitching them together by hand.
            </h2>
            <p class="section-body">
              Verde is already structured around the way the desktop app works:
              local provider CLIs, imported project directories, and a UI that
              keeps the moving pieces visible instead of scattering them across
              terminal tabs and browser windows.
            </p>
          </div>

          <div class="signal-list">
            <For each={workspaceSignals}>
              {(item) => (
                <article class="signal-row">
                  <h3>{item.title}</h3>
                  <p>{item.description}</p>
                </article>
              )}
            </For>
          </div>
        </div>
      </section>

      <section id="flow" class="section-band section-band-contrast">
        <div class="page-wrap flow-layout">
          <div class="flow-copy">
            <p class="eyebrow">Workflow</p>
            <h2 class="section-title">
              One desktop workspace from first prompt to final command.
            </h2>
            <p class="section-body">
              The product story is simple: bring the repo in, start the provider
              you want, keep the browser pane next to the transcript, and pull
              the terminal up only when the work needs it.
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

          <div class="workflow-list">
            <For each={workflowSteps}>
              {(step) => (
                <article class="workflow-step">
                  <div class="workflow-index">{step.index}</div>
                  <div class="workflow-content">
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

      <section id="install" class="section-band">
        <div class="page-wrap install-layout">
          <div class="install-copy">
            <p class="eyebrow">Install</p>
            <h2 class="section-title">
              Ship it from releases or build it straight from the repo.
            </h2>
            <p class="section-body">
              Verde already has release artifacts for Linux and macOS, plus a
              direct source path when you want to run the app locally while you
              build on top of it.
            </p>
          </div>

          <div class="install-shelf">
            <article class="install-panel">
              <div class="surface-header">
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

            <article class="install-panel">
              <div class="surface-header">
                <span>Source path</span>
                <strong>Run locally</strong>
              </div>
              <pre>
                <code>{`git clone https://github.com/JonathanRiche/verde
cd verde
zig build run`}</code>
              </pre>
            </article>

            <article class="install-panel install-panel-wide">
              <div class="surface-header">
                <span>CLI prerequisites</span>
                <strong>Bring your provider runtime</strong>
              </div>
              <p>
                To actually use Verde, install and authenticate at least one
                local provider first.
              </p>
              <div class="install-commands">
                <div>
                  <strong>Codex</strong>
                  <pre>
                    <code>{`codex login`}</code>
                  </pre>
                </div>
                <div>
                  <strong>OpenCode</strong>
                  <pre>
                    <code>{`opencode`}</code>
                  </pre>
                </div>
              </div>
            </article>
          </div>
        </div>
      </section>
    </main>
  )
}
