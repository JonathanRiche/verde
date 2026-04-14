import { createFileRoute } from '@tanstack/solid-router'

export const Route = createFileRoute('/about')({
  component: About,
})

function About() {
  return (
    <main class="wrap" style={{ padding: '5rem 0 2rem' }}>
      <section class="term-card" style={{ 'max-width': '48rem' }}>
        <p class="tag">About Verde</p>
        <h1 class="heading">Desktop shell for local coding agents.</h1>
        <p class="band-body">
          Verde is the native desktop app in this repo. It keeps coding-agent
          threads, an embedded browser pane, and a project-scoped terminal in
          the same workspace while talking to local provider CLIs such as Codex
          and OpenCode.
        </p>
      </section>
    </main>
  )
}
