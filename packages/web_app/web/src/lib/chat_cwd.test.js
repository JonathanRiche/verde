import { expect, test } from 'bun:test'
import { buildChatCwdChoices, chatCwdLocked, chatCwdTurnParams, createChatCwdApi, safeRelativeCwd } from './chat_cwd.ts'
const workspace = { workspace_id: 'ws', path: '/workspace', label: 'Workspace' }
const manifest = { workspace_id: 'ws', repositories: [
  { repository_id: 'primary', label: 'Main', bindings: [{ runtime_id: 'local', root_path: '/workspace' }, { runtime_id: 'remote', root_path: '/remote' }] },
  { repository_id: 'api', label: 'API', bindings: [{ runtime_id: 'local', root_path: '/api' }] },
  { repository_id: 'missing', label: 'Missing', bindings: [{ runtime_id: 'local', root_path: '/missing', availability: 'missing' }] },
] }
test('cwd choices use only matching available bindings and known safe subfolders', () => {
  const choices = buildChatCwdChoices(workspace, manifest, 'local', true, [
    { repository_id: 'primary', repository_cwd: 'src/app' },
    { repository_id: 'primary', repository_cwd: 'src/app' },
    { repository_id: 'primary', repository_cwd: '../private' },
    { repository_id: 'primary', repository_cwd: 'other', runtime_id: 'remote' },
  ])
  expect(choices.map((row) => row.path)).toEqual(['/workspace', '/workspace/src/app', '/api'])
  expect(buildChatCwdChoices(workspace, manifest, 'remote', false).map((row) => row.path)).toEqual(['/remote'])
})
test('missing or foreign manifest never offers a path to any chat', () => {
  expect(buildChatCwdChoices(workspace, null, null, false)).toEqual([])
  expect(buildChatCwdChoices(workspace, { ...manifest, workspace_id: 'other' }, 'remote', false)).toEqual([])
  expect(buildChatCwdChoices(workspace, null, null, true)).toEqual([])
  expect(buildChatCwdChoices(workspace, { ...manifest, workspace_id: 'other' }, 'local', true)).toEqual([])
  expect(buildChatCwdChoices(workspace, manifest, null, true)).toEqual([])
  const unavailable = { ...manifest, repositories: [{ repository_id: 'primary', bindings: [{ runtime_id: 'local', root_path: '/workspace', availability: 'missing' }] }] }
  expect(buildChatCwdChoices(workspace, unavailable, 'local', true)).toEqual([])
})
test('relative cwd rejects traversal, absolute paths and ambiguous separators', () => {
  for (const value of ['', '/tmp', '../x', 'x/../y', 'x\\y', 'x\0y', 'C:/tmp', './x', 'x//y', 'x/']) expect(safeRelativeCwd(value)).toBe(false)
  expect(safeRelativeCwd('src/my app')).toBe(true)
})
test('cwd locks on accepted work, provider session, runtime identity or active work', () => {
  expect(chatCwdLocked({ committed: false })).toBe(false)
  for (const thread of [{ committed: true }, { runtime_id: 'runtime' }, { provider_thread_id: 'session' }]) expect(chatCwdLocked(thread)).toBe(true)
  expect(chatCwdLocked({}, true)).toBe(true)
})
test('local and remote turn params preserve explicit cwd choices', () => {
  expect(chatCwdTurnParams({}, false, '/workspace')).toEqual({ project_path: '/workspace' })
  expect(chatCwdTurnParams({ repository_id: 'api' }, false, '/workspace')).toEqual({ repository_id: 'api', relative_cwd: null })
  expect(chatCwdTurnParams({ repository_cwd: 'src' }, false, '/workspace')).toEqual({ repository_id: 'primary', relative_cwd: 'src' })
  expect(chatCwdTurnParams({ repository_cwd: 'src' }, true, '/workspace')).toEqual({ repository_id: 'primary', relative_cwd: 'src', require_provider_ready: true })
})
test('cwd setter revalidates choices and lock after fetching, and never browses files', async () => {
  const calls = [], saves = [], notices = []
  let locked = false
  const api = createChatCwdApi({
    context: async () => ({ key: 'route', workspace, runtimeId: 'local', local: true, known: [] }),
    call: async (pane, method, params) => { calls.push([method, params]); return { result: manifest } },
    locked: () => locked,
    save: async (pane, choice) => { saves.push(choice); return true },
    notice: (message) => notices.push(message),
  })
  expect(await api.setChatCwd({}, JSON.stringify(['api', null]))).toBe(true)
  expect(saves[0].path).toBe('/api')
  expect(await api.setChatCwd({}, '/arbitrary')).toBe(false)
  locked = true
  expect(await api.setChatCwd({}, JSON.stringify(['api', null]))).toBe(false)
  expect(saves.length).toBe(1)
  expect(calls.every(([method]) => method === 'workspace.repository.manifest.get')).toBe(true)
  expect(notices.at(-1)).toContain('locked')
})
test('route becoming locked during inspection cannot be saved', async () => {
  let locked = false, saved = false
  const api = createChatCwdApi({
    context: async () => ({ key: 'route', workspace, runtimeId: 'local', local: true, known: [] }),
    call: async () => { locked = true; return { result: manifest } },
    locked: () => locked,
    save: async () => { saved = true; return true }, notice: () => {},
  })
  expect(await api.setChatCwd({}, JSON.stringify(['api', null]))).toBe(false)
  expect(saved).toBe(false)
})

test('fresh manifest failure prevents saving even a previously listed local root', async () => {
  for (const failed of [{ error: { message: 'Denied' } }, { ok: false }, { result: { ...manifest, workspace_id: 'foreign' } }, { result: { ...manifest, repositories: [] } }]) {
    let response = { result: manifest }, saved = false
    const api = createChatCwdApi({
      context: async () => ({ key: 'route', workspace, runtimeId: 'local', local: true, known: [] }),
      call: async () => response, locked: () => false,
      save: async () => { saved = true; return true }, notice: () => {},
    })
    const [root] = await api.listChatCwdChoices({})
    expect(root.path).toBe('/workspace')
    response = failed
    expect(await api.setChatCwd({}, root.id)).toBe(false)
    expect(saved).toBe(false)
    expect(api.chatCwdChoices('route')).toEqual([])
  }
})
