import { createSignal } from 'solid-js'
import type { Message } from './types'

export interface TranscriptPage { messages: Message[]; cursor: string | null }
export interface TranscriptState {
  loaded: boolean
  loading: boolean
  loadingOlder: boolean
  hasOlder: boolean
  error: string | null
  olderError: string | null
}
interface History extends TranscriptState { identity: string; cursor: string | null }
export interface TranscriptContext {
  key: string
  identity: string
  current: () => boolean
  fetch: (cursor?: string) => Promise<TranscriptPage>
}
const EMPTY: TranscriptState = { loaded: false, loading: false, loadingOlder: false, hasOlder: false, error: null, olderError: null }

/// Inserts an older page ahead of a known newer boundary, keeping cached row
/// objects (and their mounted UI) when the page overlaps existing history.
export function mergeTranscriptPage(existing: Message[], page: Message[], before?: string): Message[] {
  if (!page.length) return existing
  const ids = new Set(page.map(row => row.message_id))
  const boundary = before ? existing.findIndex(row => row.message_id === before) : existing.length
  const index = boundary < 0 ? existing.length : boundary
  const old = new Map(existing.map(row => [row.message_id, row]))
  const rows = page.map(row => {
    const cached = old.get(row.message_id)
    return cached && cached.role === row.role && cached.author === row.author && cached.body === row.body &&
      cached.created_at_ms === row.created_at_ms && cached.tool_call_id === row.tool_call_id &&
      cached.tool_call_kind === row.tool_call_kind && cached.tool_call_status === row.tool_call_status &&
      JSON.stringify(cached.images ?? []) === JSON.stringify(row.images ?? []) ? cached : row
  })
  return [...existing.slice(0, index).filter(row => !ids.has(row.message_id)), ...rows, ...existing.slice(index).filter(row => !ids.has(row.message_id))]
}

export function reconcileOptimisticMessages(existing: Message[], received: Message[], started: Message[]): Message[] {
  const known = new Set(started.filter(row => !row.message_id.startsWith('local-user-')).map(row => row.message_id))
  const confirmed = received.filter(row => row.role === 'user' && !row.message_id.startsWith('local-user-'))
  const images = (row: Message) => JSON.stringify((row.images ?? []).map(image => [image.path, image.mime, image.byte_size]))
  const remove = new Set<string>()
  for (const row of started) {
    if (!row.message_id.startsWith('local-user-')) continue
    const match = confirmed.findIndex(candidate => candidate.body === row.body && images(candidate) === images(row) &&
      (!known.has(candidate.message_id) || started.findIndex(item => item.message_id === candidate.message_id) > started.indexOf(row)) &&
      (candidate.created_at_ms == null || row.created_at_ms == null || candidate.created_at_ms >= row.created_at_ms - 1000))
    if (match < 0) continue
    confirmed.splice(match, 1)
    remove.add(row.message_id)
  }
  return existing.filter(row => !remove.has(row.message_id))
}

export function createTranscriptHistory(options: {
  read: (key: string) => Message[]
  write: (key: string, messages: Message[]) => void
}) {
  const [histories, setHistories] = createSignal<Record<string, History>>({})
  const pending = new Map<string, Promise<void>>()
  const requestKey = (context: TranscriptContext) => JSON.stringify([context.key, context.identity])
  const state = (key: string, identity: string): TranscriptState => {
    const history = histories()[key]
    return history?.identity === identity ? history : EMPTY
  }
  const valid = (context: TranscriptContext) => context.current() && histories()[context.key]?.identity === context.identity
  const update = (context: TranscriptContext, patch: Partial<History>) => {
    if (!valid(context)) return
    setHistories(previous => ({ ...previous, [context.key]: { ...previous[context.key]!, ...patch } }))
  }
  const prepare = (context: TranscriptContext) => {
    const old = histories()[context.key]
    if (old?.identity === context.identity) return
    // Initial snapshots/optimistic rows may predate the first fetch. Only a
    // known route change invalidates them.
    if (old) options.write(context.key, [])
    setHistories(previous => ({ ...previous, [context.key]: { ...EMPTY, identity: context.identity, cursor: null } }))
  }
  async function load(context: TranscriptContext, force = false): Promise<void> {
    const key = requestKey(context)
    const active = pending.get(key)
    if (active) {
      await active
      if (force && context.current()) return load(context)
      return
    }
    if (!context.current()) return
    prepare(context)
    update(context, { loading: true, error: null })
    const job = (async () => {
      try {
        const previous = options.read(context.key)
        const previousIds = new Set(previous.filter(row => !row.message_id.startsWith('local-user-')).map(row => row.message_id))
        const hadHistory = histories()[context.key]!.loaded && previousIds.size > 0
        const olderCursor = histories()[context.key]!.cursor
        let page = await context.fetch()
        if (!valid(context)) return
        let received = page.messages
        let overlaps = page.messages.some(row => previousIds.has(row.message_id))
        // A refresh can contain more new rows than fit in one page. Bridge to
        // the cached tail before dropping a finished turn's live overlay.
        const seen = new Set<string>()
        while (hadHistory && previous.length && !overlaps && page.cursor) {
          if (seen.has(page.cursor)) throw new Error('Transcript pagination did not advance.')
          seen.add(page.cursor)
          page = await context.fetch(page.cursor)
          if (!valid(context)) return
          overlaps = page.messages.some(row => previousIds.has(row.message_id))
          received = mergeTranscriptPage(received, page.messages, received[0]?.message_id)
        }
        options.write(context.key, mergeTranscriptPage(reconcileOptimisticMessages(options.read(context.key), received, previous), received))
        update(context, { loaded: true, cursor: hadHistory ? olderCursor : page.cursor, hasOlder: hadHistory ? !!olderCursor : !!page.cursor })
        if (hadHistory && previous.length && !overlaps && !page.cursor) update(context, { cursor: null, hasOlder: false })
      } catch (error) {
        update(context, { error: error instanceof Error ? error.message : 'Could not load messages.' })
      } finally { update(context, { loading: false }) }
    })()
    pending.set(key, job)
    try { await job } finally { if (pending.get(key) === job) pending.delete(key) }
  }
  async function loadOlder(context: TranscriptContext): Promise<void> {
    const key = requestKey(context)
    if (!context.current() || pending.has(key)) return
    const history = histories()[context.key]
    if (history?.identity !== context.identity || !history.cursor) return
    const cursor = history.cursor
    update(context, { loadingOlder: true, olderError: null })
    const job = (async () => {
      try {
        const page = await context.fetch(cursor)
        if (!valid(context)) return
        if (page.cursor === cursor) throw new Error('Transcript pagination did not advance.')
        const existing = options.read(context.key)
        options.write(context.key, mergeTranscriptPage(existing, page.messages, existing[0]?.message_id))
        update(context, { cursor: page.cursor, hasOlder: !!page.cursor })
      } catch (error) {
        update(context, { olderError: error instanceof Error ? error.message : 'Could not load older messages.' })
      } finally { update(context, { loadingOlder: false }) }
    })()
    pending.set(key, job)
    try { await job } finally { if (pending.get(key) === job) pending.delete(key) }
  }
  const matches = (key: string, identity: string) => !histories()[key] || histories()[key]!.identity === identity
  return { state, load, loadOlder, matches }
}
