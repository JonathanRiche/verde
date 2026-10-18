import { expect, test } from 'bun:test'
import { buildHandoffPackage, shellQuote } from './web_actions'

test('shell quoting survives single quotes', () => {
  expect(shellQuote("it's")).toBe(`'it'\\''s'`)
})

test('handoff package redacts secrets and respects summary mode', () => {
  const messages = [
    { role: 'user', author: 'You', body: 'first ask' },
    { role: 'assistant', author: 'Codex', body: 'middle' },
    { role: 'user', author: 'You', body: 'Authorization: Bearer xyz\nlast ask' },
    { role: 'assistant', author: 'Codex', body: 'final answer' },
  ]
  const out = buildHandoffPackage({
    workspace_id: 'ws', workspace_label: 'WS', workspace_path: '/repo', pane_id: 3,
    source_provider: 'codex', verde_thread_id: 't', provider_thread_id: 'p', title: 'T',
    messages, context_mode: 'summary',
  })
  expect(out).toContain('first ask')
  expect(out).toContain('final answer')
  expect(out).not.toContain('middle')
  expect(out).not.toContain('Bearer xyz')
  expect(out).toContain('[redacted potentially sensitive line]')
})
