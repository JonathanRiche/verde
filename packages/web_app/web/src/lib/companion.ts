/// Machine-wide Companion roster and crew helpers for the web client.
///
/// The daemon owns one roster per machine (`companion.roster.get` / `.put`,
/// packages/desktop/src/daemon/companions.zig) and appends the active
/// companion's persona to every turn on its thread, so the web client only
/// edits the roster and sends ordinary chat turns. Everything here is pure or
/// takes an injected `call`, so it is unit-testable without a daemon.

import { unwrapResult } from './live'
import type { RpcEnvelope } from './types'

export type CompanionCharacter = 'sprout' | 'moss' | 'vireo'
export type CompanionPose = 'idle' | 'working' | 'approval' | 'paused'

export const COMPANION_CHARACTERS: readonly CompanionCharacter[] = ['sprout', 'moss', 'vireo']
/// companion_roster.zig limits; the daemon clips beyond them.
export const MAX_COMPANIONS = 8
export const NAME_MAX_BYTES = 32
export const ORDERS_MAX_BYTES = 1024

export interface Companion {
  id: string
  name: string
  character: CompanionCharacter
  home_workspace_id: string
  thread_id: string
  provider: string
  model: string
  orders: string
}

export interface Roster {
  version: 1
  active_id: string
  companions: Companion[]
}

export interface RosterSnapshot {
  /// 0 means the daemon never stored a roster.
  revision: number
  roster: Roster
}

export const CHARACTER_INFO: Record<CompanionCharacter, { name: string; tagline: string }> = {
  sprout: { name: 'Sprout', tagline: 'Careful · checks in before big moves' },
  moss: { name: 'Moss', tagline: 'Steady · does the work, then summarizes' },
  vireo: { name: 'Vireo', tagline: 'Quick · runs ahead, pings only when it matters' },
}

export const COMPANION_SUGGESTIONS = [
  "What's running across my workspaces right now?",
  'Check every workspace for chats that need me.',
  'Start the dev servers for this workspace and watch them.',
] as const

type Call = (method: string, params: unknown) => Promise<RpcEnvelope>

const encoder = new TextEncoder()

/// Longest prefix of `value` within `max` UTF-8 bytes, never splitting a code point.
export function clipUtf8(value: string, max: number): string {
  if (encoder.encode(value).length <= max) return value
  let out = ''
  let used = 0
  for (const char of value) {
    const size = encoder.encode(char).length
    if (used + size > max) break
    out += char
    used += size
  }
  return out
}

/// companion_roster.cleanName: trim, drop control characters, clip to capacity.
export function cleanCompanionName(raw: string): string {
  // eslint-disable-next-line no-control-regex
  const stripped = raw.replace(/[\u0000-\u001f\u007f]/g, '').trim()
  return clipUtf8(stripped, NAME_MAX_BYTES).trim()
}

export function parseCharacter(value: unknown): CompanionCharacter {
  return COMPANION_CHARACTERS.includes(value as CompanionCharacter) ? (value as CompanionCharacter) : 'sprout'
}

const text = (value: unknown): string => (typeof value === 'string' ? value : '')

function parseCompanion(raw: unknown, index: number): Companion | null {
  if (!raw || typeof raw !== 'object') return null
  const row = raw as Record<string, unknown>
  const character = parseCharacter(row.character)
  const name = cleanCompanionName(text(row.name))
  return {
    id: text(row.id) || `cmp-restored-${index}`,
    name: name || CHARACTER_INFO[character].name,
    character,
    home_workspace_id: text(row.home_workspace_id),
    thread_id: text(row.thread_id),
    provider: text(row.provider),
    model: text(row.model),
    orders: text(row.orders),
  }
}

/// Normalizes a roster object the way the daemon parser does.
export function parseRoster(raw: unknown): Roster {
  const root = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {}
  const rows = Array.isArray(root.companions) ? root.companions : []
  const companions: Companion[] = []
  for (const row of rows) {
    if (companions.length >= MAX_COMPANIONS) break
    const parsed = parseCompanion(row, companions.length)
    if (parsed) companions.push(parsed)
  }
  const wanted = text(root.active_id)
  const active_id = companions.some((row) => row.id === wanted) ? wanted : (companions[0]?.id ?? '')
  return { version: 1, active_id, companions }
}

/// `companion.roster.get` envelope → snapshot; null when the call failed.
export function parseRosterSnapshot(response: RpcEnvelope): RosterSnapshot | null {
  if (response.error || response.ok === false) return null
  const result = unwrapResult<{ revision?: unknown; roster?: unknown }>(response)
  if (!result) return null
  const revision = typeof result.revision === 'number' && Number.isSafeInteger(result.revision) ? result.revision : 0
  return { revision, roster: parseRoster(result.roster) }
}

export function isRosterConflict(response: RpcEnvelope): boolean {
  return response.error?.code === 'conflict'
}

export function activeCompanion(roster: Roster): Companion | null {
  return roster.companions.find((row) => row.id === roster.active_id) ?? roster.companions[0] ?? null
}

function uniqueName(roster: Roster, base: string, except?: string): string {
  const taken = new Set(roster.companions.filter((row) => row.id !== except).map((row) => row.name.toLowerCase()))
  if (!taken.has(base.toLowerCase())) return base
  for (let n = 2; n < 100; n += 1) {
    const suffix = ` ${n}`
    const candidate = `${clipUtf8(base, NAME_MAX_BYTES - suffix.length).trimEnd()}${suffix}`
    if (!taken.has(candidate.toLowerCase())) return candidate
  }
  return base
}

let idCounter = 0

/// Adds a companion and makes it active; null when the roster is full.
export function addCompanion(
  roster: Roster,
  character: CompanionCharacter,
  options: { name?: string; home_workspace_id?: string; now?: number } = {},
): Roster | null {
  if (roster.companions.length >= MAX_COMPANIONS) return null
  idCounter += 1
  const id = `cmp-${options.now ?? Date.now()}-${idCounter}`
  const base = cleanCompanionName(options.name ?? '') || CHARACTER_INFO[character].name
  const companion: Companion = {
    id,
    name: uniqueName(roster, base),
    character,
    home_workspace_id: options.home_workspace_id ?? '',
    thread_id: '',
    provider: '',
    model: '',
    orders: '',
  }
  return { ...roster, active_id: id, companions: [...roster.companions, companion] }
}

/// Removes a companion but always keeps at least one.
export function removeCompanion(roster: Roster, id: string): Roster | null {
  if (roster.companions.length <= 1) return null
  const index = roster.companions.findIndex((row) => row.id === id)
  if (index < 0) return null
  const companions = roster.companions.filter((row) => row.id !== id)
  const active_id = roster.active_id === id
    ? companions[Math.max(0, index - 1)]?.id ?? companions[0]?.id ?? ''
    : roster.active_id
  return { ...roster, active_id, companions }
}

export type CompanionPatch = Partial<Pick<Companion, 'name' | 'character' | 'orders' | 'provider' | 'model' | 'home_workspace_id' | 'thread_id'>>

/// Applies a field edit to one companion; null when it no longer exists or
/// the edit is invalid (an empty name).
export function patchCompanion(roster: Roster, id: string, patch: CompanionPatch): Roster | null {
  const current = roster.companions.find((row) => row.id === id)
  if (!current) return null
  const next: Companion = { ...current }
  if (patch.name !== undefined) {
    const name = cleanCompanionName(patch.name)
    if (!name) return null
    next.name = uniqueName(roster, name, id)
  }
  if (patch.character !== undefined) next.character = parseCharacter(patch.character)
  if (patch.orders !== undefined) next.orders = clipUtf8(patch.orders.trim(), ORDERS_MAX_BYTES)
  if (patch.provider !== undefined) next.provider = patch.provider
  if (patch.model !== undefined) next.model = patch.model
  if (patch.home_workspace_id !== undefined) next.home_workspace_id = patch.home_workspace_id
  if (patch.thread_id !== undefined) next.thread_id = patch.thread_id
  return { ...roster, companions: roster.companions.map((row) => (row.id === id ? next : row)) }
}

export function selectCompanion(roster: Roster, id: string): Roster | null {
  if (roster.active_id === id || !roster.companions.some((row) => row.id === id)) return null
  return { ...roster, active_id: id }
}

/// First use: an empty roster gets a default Sprout.
export function withDefaultCompanion(roster: Roster, home_workspace_id = ''): Roster | null {
  if (roster.companions.length > 0) return null
  return addCompanion(roster, 'sprout', { name: 'Sprout', home_workspace_id })
}

export async function fetchRoster(call: Call): Promise<RosterSnapshot> {
  const response = await call('companion.roster.get', {})
  const snapshot = parseRosterSnapshot(response)
  if (!snapshot) throw new Error(response.error?.message ?? 'Could not load companions')
  return snapshot
}

const MAX_SAVE_ATTEMPTS = 3

/// Optimistic-concurrency save. `edit` is re-applied to the freshest roster
/// after a `conflict`, so another client's save is never overwritten and the
/// user's edit still lands. Returning null from `edit` means "nothing to do"
/// (for example the companion was removed elsewhere).
export async function saveRoster(
  call: Call,
  current: RosterSnapshot,
  edit: (roster: Roster) => Roster | null,
): Promise<RosterSnapshot> {
  let snapshot = current
  for (let attempt = 0; attempt < MAX_SAVE_ATTEMPTS; attempt += 1) {
    const next = edit(snapshot.roster)
    if (!next) return snapshot
    const response = await call('companion.roster.put', { roster: next, expected_revision: snapshot.revision })
    if (isRosterConflict(response)) {
      snapshot = await fetchRoster(call)
      continue
    }
    const result = unwrapResult<{ revision?: unknown }>(response)
    if (response.error || response.ok === false || !result || typeof result.revision !== 'number') {
      throw new Error(response.error?.message ?? 'Could not save companions')
    }
    return { revision: result.revision, roster: parseRoster(next) }
  }
  throw new Error('Companions kept changing elsewhere; try again.')
}

// ---- Crew ---------------------------------------------------------------

export type CrewStatus =
  | 'running' | 'waiting_approval' | 'blocked' | 'completed' | 'failed' | 'aborted' | 'interrupted' | 'idle'

export interface CrewLink {
  link_id: string
  workspace_id: string
  local_thread_id: string
  title: string
  provider: string
  status: string
  summary: string
  updated_at_ms: number
}

export type PillTone = 'accent' | 'warning' | 'danger' | 'muted' | 'done'

export interface CrewPill {
  label: string
  tone: PillTone
  /// Lower sorts first: what needs the user, then live work, then history.
  rank: number
  live: boolean
}

const CREW_PILLS: Record<CrewStatus, CrewPill> = {
  waiting_approval: { label: 'Needs approval', tone: 'warning', rank: 0, live: true },
  blocked: { label: 'Blocked', tone: 'warning', rank: 1, live: true },
  running: { label: 'Running', tone: 'accent', rank: 2, live: true },
  failed: { label: 'Failed', tone: 'danger', rank: 3, live: false },
  interrupted: { label: 'Interrupted', tone: 'danger', rank: 4, live: false },
  completed: { label: 'Done', tone: 'done', rank: 5, live: false },
  aborted: { label: 'Stopped', tone: 'muted', rank: 6, live: false },
  idle: { label: 'Idle', tone: 'muted', rank: 7, live: false },
}

export function crewStatusPill(status: string | null | undefined): CrewPill {
  const known = CREW_PILLS[(status ?? '') as CrewStatus]
  if (known) return known
  const label = (status ?? '').replace(/_/g, ' ').trim()
  return { label: label ? label[0].toUpperCase() + label.slice(1) : 'Unknown', tone: 'muted', rank: 8, live: false }
}

/// `chat.links.list` envelope → visible child links, most urgent first.
export function parseCrewLinks(response: RpcEnvelope): CrewLink[] {
  if (response.error || response.ok === false) return []
  const result = unwrapResult<{ links?: unknown }>(response)
  const rows = Array.isArray(result?.links) ? result!.links as unknown[] : []
  const links: CrewLink[] = []
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue
    const row = raw as Record<string, unknown>
    if (row.hidden === true) continue
    const local_thread_id = text(row.local_thread_id)
    const workspace_id = text(row.workspace_id)
    if (!local_thread_id || !workspace_id) continue
    links.push({
      link_id: text(row.link_id) || `${workspace_id}:${local_thread_id}`,
      workspace_id,
      local_thread_id,
      title: text(row.title) || 'Chat',
      provider: text(row.provider),
      status: text(row.status) || 'idle',
      summary: text(row.summary),
      updated_at_ms: typeof row.updated_at_ms === 'number' ? row.updated_at_ms : 0,
    })
  }
  return links.sort((left, right) =>
    crewStatusPill(left.status).rank - crewStatusPill(right.status).rank || right.updated_at_ms - left.updated_at_ms)
}

// ---- Presence -------------------------------------------------------------

const plural = (count: number, one: string, many: string) => `${count} ${count === 1 ? one : many}`

/// One-line dock status from real machine state.
export function companionStatusLine(state: { needs: number; running: number }): string {
  if (state.needs > 0) return `${plural(state.needs, 'thing needs', 'things need')} you`
  if (state.running > 0) return `${plural(state.running, 'chat', 'chats')} running`
  return 'Ready when you are'
}

/// Pose from real state only: offline daemon pauses, approvals glance,
/// live turns work.
export function companionPose(state: { connected: boolean; needs: number; working: boolean }): CompanionPose {
  if (!state.connected) return 'paused'
  if (state.needs > 0) return 'approval'
  if (state.working) return 'working'
  return 'idle'
}
