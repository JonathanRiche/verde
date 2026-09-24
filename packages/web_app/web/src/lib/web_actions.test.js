import { expect, test } from 'bun:test'
import { mkdtempSync, writeFileSync, chmodSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  agentResumeCommand, agentTerminalArgv, agentTuiCommand, buildHandoffPackage, buildHerdrHandoffScript,
  chainLayouts, openingExchange, parseHerdrLinkMarker, shellQuote,
} from './web_actions'

test('shell quoting survives single quotes', () => {
  expect(shellQuote("it's")).toBe(`'it'\\''s'`)
})

test('agent commands resume with provider-specific flags', () => {
  expect(agentTuiCommand('cursor')).toBe('cursor-agent')
  expect(agentTuiCommand('nope')).toBeNull()
  expect(agentResumeCommand('claude', 'abc')).toContain('--resume')
  expect(agentResumeCommand('codex', 'abc')).toContain('resume')
  expect(agentTerminalArgv('codex').slice(0, 2)).toEqual(['/bin/sh', '-lc'])
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

test('opening exchange pairs the first user message with the next assistant reply', () => {
  expect(openingExchange([
    { role: 'assistant', body: 'hi' }, { role: 'user', body: 'q' },
    { role: 'assistant', body: 'tool', tool_call_id: 'x' }, { role: 'assistant', body: 'a' },
  ])).toEqual({ user: 'q', assistant: 'a' })
})

test('herdr script mirrors the layout through herdr and prints the link marker', () => {
  const dir = mkdtempSync(join(tmpdir(), 'verde-herdr-'))
  const log = join(dir, 'log')
  const fake = join(dir, 'herdr')
  writeFileSync(fake, `#!/bin/sh
echo "$*" >> ${JSON.stringify(log)}
case "$*" in
  *"workspace create"*) printf '{\\n  "workspace_id": "w9",\\n  "pane_id": "p0"\\n}\\n' ;;
  *"pane split"*) n=$(grep -c "pane split" ${JSON.stringify(log)}); printf '{"pane_id":"p%s"}' "$n" ;;
esac
`)
  chmodSync(fake, 0o755)
  const layout = chainLayouts([{ leaf: 1 }, { leaf: 2 }])
  const script = buildHerdrHandoffScript({
    session: 'verde', label: "Bob's repo", cwd: dir, layout,
    panes: new Map([[1, { title: 'Chat', command: 'codex resume abc' }], [2, { title: 'Shell', command: null }]]),
  })
  const run = Bun.spawnSync(['/bin/sh', '-c', script], { env: { ...process.env, HERDR_BIN: fake } })
  expect(run.exitCode).toBe(0)
  const marker = parseHerdrLinkMarker(run.stdout.toString())
  expect(marker).toEqual({ workspace_id: 'w9', pane_id: 'p0' })
  const calls = readFileSync(log, 'utf8')
  expect(calls).toContain("workspace create --cwd")
  expect(calls).toContain("--label Bob's repo")
  expect(calls).toContain('pane split p0 --direction right')
  expect(calls).toContain('pane rename p1 Shell')
  expect(calls).toContain('pane run p0 codex resume abc')
})
