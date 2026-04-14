import { createFileRoute } from '@tanstack/solid-router'

export const Route = createFileRoute('/about')({
  component: About,
})

function About() {
  return (
    <main class="page-wrap" style={{ padding: '5rem 0 2rem' }}>
      <section class="install-panel" style={{ 'max-width': '48rem' }}>
        <p class="eyebrow">About Verde</p>
        <h1 class="section-title">Desktop shell for local coding agents.</h1>
        <p class="section-body">
          Verde is the native desktop app in this repo. It keeps coding-agent
          threads, an embedded browser pane, and a project-scoped terminal in
          the same workspace while talking to local provider CLIs such as Codex
          and OpenCode.
        </p>
      </section>
    </main>
  )
}
