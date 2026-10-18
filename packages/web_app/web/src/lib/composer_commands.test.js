import { expect, test } from 'bun:test'
import { acceptFileMention, repositoryCommandPath, createComposerCommands, sanitizeFileMatches } from './composer_commands'

const commands = [{ id: 'compact', name: '/compact', summary: 'Compact', usage: '/compact', requires_thread: true }]

test('file acceptance cannot insert absolute or traversal paths', () => {
  for (const path of ['/etc/passwd', '../secret', 'src/../../secret', 'C:\\secret', 'a\nb', 'a//b']) {
    expect(acceptFileMention('@x', 2, path)).toBeNull()
  }
  expect(acceptFileMention('@x', 2, 'dir/my file.ts')?.draft).toBe('@dir/my file.ts ')
})

test('slash paths resolve the runtime checkout for repositories and subfolders and reject escapes', () => {
  const manifest = { repositories: [{ repository_id: 'primary', bindings: [
    { runtime_id: 'host', root_path: '/host' }, { runtime_id: 'remote', root_path: '/remote', availability: 'available' },
  ] }] }
  expect(repositoryCommandPath(manifest, 'primary', 'remote')).toBe('/remote')
  expect(repositoryCommandPath(manifest, 'primary', 'remote', 'services/api')).toBe('/remote/services/api')
  expect(repositoryCommandPath({ repositories: [{ repository_id: 'api', bindings: [{ runtime_id: 'local', root_path: '/api' }] }] }, 'api', 'local')).toBe('/api')
  expect(() => repositoryCommandPath(manifest, 'primary', 'remote', 'a//b')).toThrow()
  expect(() => repositoryCommandPath(manifest, 'primary', 'remote', 'a/./b')).toThrow()
  expect(() => repositoryCommandPath(manifest, 'primary', 'missing')).toThrow()
  expect(() => repositoryCommandPath(manifest, 'primary', 'remote', '../outside')).toThrow()
  expect(() => repositoryCommandPath(manifest, 'primary', 'remote', '/absolute')).toThrow()
})

function fixture(responses = [], context = { provider: 'codex', project_path: '/repo', thread_id: 'provider-thread' }) {
  const calls = [], notices = []
  const api = createComposerCommands({
    key: (pane) => pane,
    context: async () => context,
    call: async (pane, method, params) => { calls.push({ pane, method, params }); const value = responses.shift(); if (value instanceof Error) throw value; return value },
    notice: (value) => notices.push(value),
  }, 1)
  return { api, calls, notices }
}
const catalog = (rows = commands) => ({ result: { provider: 'codex', commands: rows } })

test('disabled, unknown and thread-required commands never execute', async () => {
  for (const [rows, input, threadId] of [
    [[{ ...commands[0], availability: 'disabled' }], '/compact', 'id'],
    [commands, '/unknown', 'id'], [commands, '/compact', null],
  ]) {
    const f = fixture([catalog(rows)], { provider: 'codex', project_path: '/repo', thread_id: threadId })
    expect(await f.api.submitSlashCommand('pane', input)).toBeNull()
    expect(f.calls).toHaveLength(1)
  }
})

test('sanitized file matches are always insertable mentions', () => {
  expect(sanitizeFileMatches(null)).toEqual([])
  expect(sanitizeFileMatches([{ path: 'a//b' }, { path: 'C:\\x' }, { path: 'dir/my file.ts' }])).toEqual([{ path: 'dir/my file.ts', file_name: 'my file.ts' }])
})

test('a provider directory or thread change during catalog loading prevents command execution', async () => {
  for (const patch of [{ provider: 'claude' }, { project_path: '/other' }, { thread_id: 'other-thread' }]) {
    let context = { provider: 'codex', project_path: '/workspace', thread_id: 'thread' }
    const methods = [], notices = []
    const api = createComposerCommands({
      key: () => 'pane', context: async () => ({ ...context }), notice: (text) => notices.push(text),
      call: async (_pane, method) => {
        methods.push(method)
        context = { ...context, ...patch }
        return { result: { provider: 'codex', commands } }
      },
    })
    expect(await api.submitSlashCommand('pane', '/compact')).toBeNull()
    expect(methods).toEqual(['provider.slash.list'])
    expect(notices.at(-1)).toContain('changed')
  }
})
