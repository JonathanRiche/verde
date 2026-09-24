import { expect, test } from 'bun:test'
import { parseSlashCommand, slashTokenAtCaret, fileMentionAtCaret, acceptSlashCommand, acceptFileMention, classifyBangCommand, repositoryCommandPath, createComposerCommands, sanitizeFileMatches } from './composer_commands'

const commands = [{ id: 'compact', name: '/compact', summary: 'Compact', usage: '/compact', requires_thread: true }]

test('slash parsing matches desktop precedence, arguments, escaping and case sensitivity', () => {
  expect(parseSlashCommand(' /compact  extra \n', commands)).toMatchObject({ kind: 'provider', name: '/compact', args: 'extra' })
  expect(parseSlashCommand('/stack status', [{ ...commands[0], name: '/stack' }])).toMatchObject({ kind: 'local', args: 'status' })
  expect(parseSlashCommand(' //compact ')).toEqual({ kind: 'literal', text: '/compact' })
  expect(parseSlashCommand('/Compact', commands).kind).toBe('unknown')
  expect(parseSlashCommand('please /compact', commands).kind).toBe('prompt')
  expect(parseSlashCommand('/')).toMatchObject({ kind: 'unknown', name: '/', args: '' })
})

test('slash autocomplete replaces only the first token including its suffix', () => {
  expect(slashTokenAtCaret('  /comZZ args', 6)).toEqual({ start: 2, end: 8, query: 'com' })
  expect(acceptSlashCommand('  /comZZ args', 6, '/compact')).toEqual({ draft: '  /compact args', caret: 11 })
  expect(slashTokenAtCaret('//literal', 4)).toBeNull()
  expect(slashTokenAtCaret('/compact args', 12)).toBeNull()
  expect(slashTokenAtCaret('text /co', 8)).toBeNull()
})

test('file token uses the caret, rejects email addresses and supports empty queries', () => {
  expect(fileMentionAtCaret('see @src/main.ts next', 8)).toEqual({ start: 4, end: 16, query: 'src' })
  expect(fileMentionAtCaret('mail a@b.test', 12)).toBeNull()
  expect(fileMentionAtCaret('@', 1)).toEqual({ start: 0, end: 1, query: '' })
  expect(fileMentionAtCaret('@x ', 3)).toBeNull()
  expect(fileMentionAtCaret('@x', -1)).toBeNull()
  expect(acceptFileMention('😀 @old rest', 6, 'src/new.ts')).toEqual({ draft: '😀 @src/new.ts rest', caret: 15 })
})

test('file acceptance cannot insert absolute or traversal paths', () => {
  for (const path of ['/etc/passwd', '../secret', 'src/../../secret', 'C:\\secret', 'a\nb', 'a//b']) {
    expect(acceptFileMention('@x', 2, path)).toBeNull()
  }
  expect(acceptFileMention('@x', 2, 'dir/my file.ts')?.draft).toBe('@dir/my file.ts ')
})

test('bang commands retain desktop escape and bare-bang semantics', () => {
  expect(classifyBangCommand('! ls ')).toEqual({ kind: 'shell', text: 'ls' })
  expect(classifyBangCommand('!!literal')).toEqual({ kind: 'prompt', text: '!literal' })
  expect(classifyBangCommand('!')).toEqual({ kind: 'prompt', text: '!' })
  expect(classifyBangCommand(' !ls').kind).toBe('prompt')
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

test('provider commands execute on the supplied pane with provider thread identity', async () => {
  const f = fixture([catalog(), { result: { provider: 'codex', result: { handled: true, transcript_title: 'Compacted', transcript_body: 'Done' } } }])
  expect(await f.api.submitSlashCommand('remote-pane', '/compact please')).toMatchObject({ handled: true, transcript_body: 'Done' })
  expect(f.calls[1]).toEqual({ pane: 'remote-pane', method: 'provider.slash.run', params: { provider: 'codex', project_path: '/repo', thread_id: 'provider-thread', command: 'compact', raw_text: '/compact please', args: 'please' } })
})

test('local commands run through the local handler and never call a provider', async () => {
  const calls = [], local = []
  const api = createComposerCommands({
    key: (pane) => pane,
    context: async () => ({ provider: 'codex', project_path: '/repo', thread_id: 'id' }),
    call: async (pane, method) => { calls.push(method); return catalog() },
    notice: () => {},
    local: async (pane, name, args) => { local.push([pane, name, args]); return true },
  }, 1)
  expect(await api.submitSlashCommand('pane', '/stack restart web')).toEqual({ handled: true })
  expect(local).toEqual([['pane', '/stack', 'restart web']])
  expect(calls.every((method) => method !== 'provider.slash.run')).toBe(true)
})

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

test('catalog errors surface without trying another route', async () => {
  const f = fixture([{ error: { message: 'insufficient_scope' } }])
  expect(await f.api.listSlashCommands('remote')).toBeNull()
  expect(f.notices.at(-1)).toBe('insufficient_scope')
  expect(f.calls).toHaveLength(1)
})

test('file search debounces per pane, cancels stale queries and returns daemon matches', async () => {
  const calls = []
  const route = { workspace_id: 'ws', repository_id: 'api', relative_cwd: 'services' }
  const api = createComposerCommands({
    key: (pane) => pane,
    context: async () => { throw new Error('file search must not need slash context') },
    fileRoute: () => route,
    call: async (pane, method, params) => { calls.push({ pane, method, params }); return { result: { files: [
      { path: 'src/main.ts', file_name: 'main.ts' }, { path: '/etc/passwd' }, { path: '../secret' }, { path: 'lib/util.ts' }, 7,
    ] } } },
    notice: () => {},
  }, 1)
  const first = api.searchFiles('a', 'old')
  const latest = api.searchFiles('a', 'new')
  expect(await first).toEqual({ status: 'cancelled', files: [] })
  expect(await latest).toEqual({ status: 'ok', files: [{ path: 'src/main.ts', file_name: 'main.ts' }, { path: 'lib/util.ts', file_name: 'util.ts' }] })
  expect(calls).toEqual([{ pane: 'a', method: 'workspace.files.search', params: { ...route, query: 'new', limit: 20 } }])
  const abort = new AbortController()
  const pending = api.searchFiles('b', 'x', abort.signal)
  abort.abort()
  expect((await pending).status).toBe('cancelled')
  const other = api.searchFiles('c', 'x')
  api.cancelAllFileSearches()
  expect((await other).status).toBe('cancelled')
  expect(calls).toHaveLength(1)
})

test('file search errors settle with the daemon message and never widen the route', async () => {
  const f = fixture([{ error: { message: 'repository binding not found on this runtime' } }])
  expect(await f.api.searchFiles('a', 'x')).toEqual({ status: 'error', files: [], message: 'File search is unavailable for this chat.' })
  expect(f.calls).toEqual([])
  const api = createComposerCommands({
    key: (pane) => pane, context: async () => ({}), notice: () => {},
    fileRoute: async () => ({ workspace_id: 'ws', repository_id: 'primary', relative_cwd: null }),
    call: async () => ({ error: { message: 'repository binding not found on this runtime' } }),
  }, 1)
  expect(await api.searchFiles('a', 'x')).toEqual({ status: 'error', files: [], message: 'repository binding not found on this runtime' })
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
