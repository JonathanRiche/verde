import { unwrapResult } from './live'
import type { RpcEnvelope } from './types'

export interface SlashCommand {
  id: string
  name: string
  summary: string
  usage: string
  requires_thread: boolean
  destructive_or_sensitive?: boolean
  availability?: 'available' | 'disabled' | 'unsupported'
  local?: boolean
}

export const LOCAL_COMMANDS: readonly SlashCommand[] = [
  { id: 'handoff', name: '/handoff', summary: 'Hand off this chat to another agent.', usage: '/handoff', requires_thread: true, local: true, availability: 'available' },
  { id: 'stack', name: '/stack', summary: 'Manage the workspace stack from verde.toml.', usage: '/stack start|stop|restart|status', requires_thread: false, local: true, availability: 'available' },
  { id: 'process', name: '/process', summary: 'Control one managed process.', usage: '/process start|stop|restart|focus|crashed <name>', requires_thread: false, local: true, availability: 'available' },
]

export type ParsedSlash =
  | { kind: 'prompt'; text: string }
  | { kind: 'literal'; text: string }
  | { kind: 'local' | 'provider' | 'unknown'; name: string; args: string; command?: SlashCommand }

/** Match desktop parsing: trim ASCII whitespace; local names take precedence. */
export function parseSlashCommand(draft: string, commands: readonly SlashCommand[] = []): ParsedSlash {
  const text = draft.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, '')
  if (!text.startsWith('/')) return { kind: 'prompt', text: draft }
  if (text.startsWith('//')) return { kind: 'literal', text: text.slice(1) }
  const end = text.search(/[ \t\r\n]/)
  const name = end < 0 ? text : text.slice(0, end)
  const args = end < 0 ? '' : text.slice(end).trim()
  const local = LOCAL_COMMANDS.find((row) => row.name === name)
  const command = local ?? commands.find((row) => row.name === name)
  return { kind: local ? 'local' : command ? 'provider' : 'unknown', name, args, command }
}

export interface ComposerToken { start: number; end: number; query: string }
export interface ComposerReplacement { draft: string; caret: number }

/** Token spans use textarea UTF-16 offsets, including the suffix after the caret. */
export function fileMentionAtCaret(draft: string, caret: number): ComposerToken | null {
  if (!Number.isInteger(caret) || caret < 0 || caret > draft.length) return null
  let start = caret, end = caret
  while (start > 0 && !/\s/.test(draft[start - 1])) start--
  while (end < draft.length && !/\s/.test(draft[end])) end++
  if (draft[start] !== '@' || caret <= start) return null
  return { start, end, query: draft.slice(start + 1, caret) }
}

export function slashTokenAtCaret(draft: string, caret: number): ComposerToken | null {
  const start = draft.search(/[^ \t\r\n]/)
  if (start < 0 || draft[start] !== '/' || draft[start + 1] === '/') return null
  let end = start + 1
  while (end < draft.length && !/\s/.test(draft[end])) end++
  if (!Number.isInteger(caret) || caret <= start || caret > end) return null
  return { start, end, query: draft.slice(start + 1, caret) }
}

function replaceToken(draft: string, token: ComposerToken, text: string): ComposerReplacement {
  const suffix = draft.slice(token.end)
  const replacement = text + (suffix.startsWith(' ') ? '' : ' ')
  return { draft: draft.slice(0, token.start) + replacement + suffix, caret: token.start + replacement.length + (suffix.startsWith(' ') ? 1 : 0) }
}

export function acceptSlashCommand(draft: string, caret: number, name: string): ComposerReplacement | null {
  const token = slashTokenAtCaret(draft, caret)
  return token && /^\/[^/\s]+$/.test(name) ? replaceToken(draft, token, name) : null
}

export function acceptFileMention(draft: string, caret: number, relativePath: string): ComposerReplacement | null {
  const token = fileMentionAtCaret(draft, caret)
  // Only accept repository-relative paths. This is insertion validation, not
  // authorization to read files; daemon search results are re-checked here.
  if (!token || !relativePath || /[\r\n\0\\]/.test(relativePath) || relativePath.startsWith('/') || /^[a-z]:/i.test(relativePath) || relativePath.split('/').some((part) => part === '..' || !part)) return null
  return replaceToken(draft, token, `@${relativePath}`)
}

export function classifyBangCommand(draft: string): { kind: 'prompt' | 'shell'; text: string } {
  if (draft.startsWith('!!')) return { kind: 'prompt', text: draft.slice(1) }
  if (draft.startsWith('!') && draft.slice(1).trim()) return { kind: 'shell', text: draft.slice(1).trim() }
  return { kind: 'prompt', text: draft }
}

export interface SlashCommandResult {
  handled: boolean
  thread_id?: string | null
  notice?: string | null
  transcript_title?: string | null
  transcript_body?: string | null
}

export interface ComposerCommandContext {
  provider: string
  project_path: string
  thread_id: string | null
}

/**
 * The checkout a chat's provider runs in on `runtimeId`: the repository
 * binding root plus the chat's validated relative working directory.
 */
export function repositoryCommandPath(manifest: { repositories?: Array<{
  repository_id: string; bindings?: Array<{ runtime_id: string; root_path: string; availability?: string }>
}> }, repositoryId: string, runtimeId: string, relativeCwd?: string | null): string {
  const binding = manifest.repositories?.find((row) => row.repository_id === repositoryId)
    ?.bindings?.find((row) => row.runtime_id === runtimeId && (!row.availability || row.availability === 'available'))
  if (!binding?.root_path) throw new Error('The selected repository is unavailable on this runtime.')
  const unsafe = (path: string) => /[\\\x00-\x1f]/.test(path) || path.split('/').some((part) => part === '..' || part === '.')
  if (!binding.root_path.startsWith('/') || unsafe(binding.root_path)) throw new Error('Invalid repository root.')
  if (!relativeCwd) return binding.root_path
  if (relativeCwd.startsWith('/') || unsafe(relativeCwd) || relativeCwd.split('/').some((part) => part === '')) throw new Error('Invalid chat working directory.')
  return `${binding.root_path.replace(/\/+$/, '')}/${relativeCwd}`
}

export interface FileMatch { path: string; file_name: string }
export type FileSearchResult =
  | { status: 'ok'; files: FileMatch[] }
  | { status: 'cancelled' | 'error'; files: FileMatch[]; message?: string }

/** Daemon-resolved repository route for `workspace.files.search`; never a client path. */
export interface ComposerFileRoute { workspace_id: string; repository_id: string; relative_cwd: string | null }

/** Keep only mention-safe, root-relative daemon results (see acceptFileMention). */
export function sanitizeFileMatches(value: unknown): FileMatch[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((row) => {
    const path = row && typeof row === 'object' ? (row as { path?: unknown }).path : null
    if (typeof path !== 'string' || !acceptFileMention('@', 1, path)) return []
    const name = (row as { file_name?: unknown }).file_name
    return [{ path, file_name: typeof name === 'string' && name ? name : path.slice(path.lastIndexOf('/') + 1) }]
  })
}

export function createComposerCommands<Pane>(deps: {
  key: (pane: Pane) => string
  context: (pane: Pane) => Promise<ComposerCommandContext>
  /** Route used for `@` file search; resolved server-side from the stored binding. */
  fileRoute?: (pane: Pane) => ComposerFileRoute | Promise<ComposerFileRoute>
  call: (pane: Pane, method: string, params: unknown) => Promise<RpcEnvelope>
  notice: (message: string | null) => void
  /** Runs /handoff, /stack, /process; resolves whether the command ran. */
  local?: (pane: Pane, name: string, args: string) => Promise<boolean>
}, debounceMs = 150) {
  const searches = new Map<string, () => void>()
  async function request<T>(pane: Pane, method: string, params: unknown): Promise<T> {
    const response = await deps.call(pane, method, params)
    // SlashRunResult has a nested result; unwrapResult intentionally unwraps
    // that layer, whereas SlashListResult keeps provider + commands.
    const result = unwrapResult<T>(response)
    if (response.error || response.ok === false || !result) throw new Error(response.error?.message ?? `${method} failed`)
    return result
  }
  async function catalog(pane: Pane, context: ComposerCommandContext): Promise<SlashCommand[]> {
    const result = await request<{ provider: string; commands: SlashCommand[] }>(pane, 'provider.slash.list', { provider: context.provider, project_path: context.project_path })
    if (result.provider !== context.provider || !Array.isArray(result.commands)) throw new Error('Invalid slash-command catalog')
    return [...LOCAL_COMMANDS, ...result.commands.filter((row) => !LOCAL_COMMANDS.some((local) => local.name === row.name))]
  }
  const fail = (error: unknown) => deps.notice(error instanceof Error ? error.message : 'Composer command failed')
  async function listSlashCommands(pane: Pane): Promise<SlashCommand[] | null> {
    try { return await catalog(pane, await deps.context(pane)) } catch (error) { fail(error); return null }
  }
  async function submitSlashCommand(pane: Pane, draft: string): Promise<SlashCommandResult | null> {
    deps.notice(null)
    try {
      const preliminary = parseSlashCommand(draft)
      if (preliminary.kind === 'local') {
        if (!deps.local) throw new Error(`${preliminary.name} is unavailable here.`)
        return { handled: await deps.local(pane, preliminary.name, preliminary.args) }
      }
      if (preliminary.kind === 'prompt' || preliminary.kind === 'literal') throw new Error('This is a chat prompt, not a slash command.')
      const context = await deps.context(pane)
      const parsed = parseSlashCommand(draft, await catalog(pane, context))
      if (parsed.kind !== 'provider' || !parsed.command) throw new Error(`Unknown slash command: ${preliminary.name}`)
      if (parsed.command.availability && parsed.command.availability !== 'available') throw new Error(`${parsed.name} is ${parsed.command.availability} for this provider.`)
      if (parsed.command.requires_thread && !context.thread_id) throw new Error(`${parsed.name} requires an existing provider thread. Send a message first.`)
      // Catalog loading may yield across a provider or route change. A command
      // selected for the old context must never execute against the new one.
      const current = await deps.context(pane)
      if (current.provider !== context.provider || current.project_path !== context.project_path || current.thread_id !== context.thread_id) {
        throw new Error('The chat provider or working directory changed. Select the command again.')
      }
      const result = await request<SlashCommandResult>(pane, 'provider.slash.run', {
        ...context, command: parsed.command.id, raw_text: draft.trim(), args: parsed.args,
      })
      if (typeof result.handled !== 'boolean') throw new Error('Invalid slash-command result')
      if (result.notice) deps.notice(result.notice)
      else if (!result.handled) deps.notice(`${parsed.name} was not handled by the provider.`)
      return result
    } catch (error) { fail(error); return null }
  }
  function cancelFileSearch(pane: Pane): void { searches.get(deps.key(pane))?.() }
  function cancelAllFileSearches(): void { for (const cancel of searches.values()) cancel() }
  function searchFiles(pane: Pane, query: string, signal?: AbortSignal): Promise<FileSearchResult> {
    const key = deps.key(pane)
    cancelFileSearch(pane)
    return new Promise((resolve) => {
      let settled = false
      const finish = (result: FileSearchResult) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        signal?.removeEventListener('abort', cancel)
        if (searches.get(key) === cancel) searches.delete(key)
        resolve(result)
      }
      const cancel = () => finish({ status: 'cancelled', files: [] })
      const timer = setTimeout(async () => {
        try {
          if (!deps.fileRoute) throw new Error('File search is unavailable for this chat.')
          const route = await deps.fileRoute(pane)
          if (settled) return
          const result = await request<{ files?: unknown }>(pane, 'workspace.files.search', { ...route, query, limit: 20 })
          finish({ status: 'ok', files: sanitizeFileMatches(result.files) })
        } catch (error) {
          finish({ status: 'error', files: [], message: error instanceof Error ? error.message : 'File search failed.' })
        }
      }, debounceMs)
      searches.set(key, cancel)
      signal?.addEventListener('abort', cancel, { once: true })
      if (signal?.aborted) cancel()
    })
  }
  return { listSlashCommands, submitSlashCommand, searchFiles, cancelFileSearch, cancelAllFileSearches }
}
