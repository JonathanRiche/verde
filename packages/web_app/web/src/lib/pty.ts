import type { LiveClient } from './live'
import { unwrapResult } from './live'

export interface DaemonSession {
  id?: string
  session_id?: string
  workspace_id?: string
  cwd?: string
  label?: string
  command?: string
  pane_id?: number
  running?: boolean
  cols?: number
  rows?: number
}

export interface TailResult {
  text?: string
  next_offset?: number
  offset?: number
  running?: boolean
  id?: string
  truncated?: boolean
}

function resultOf<T>(envelope: { result?: unknown; error?: { message: string } }): T | null {
  if (envelope.error) return null
  return unwrapResult<T>(envelope)
}

export async function listSessions(client: LiveClient): Promise<DaemonSession[]> {
  const response = await client.call('session.list', {})
  const body = resultOf<{ sessions?: DaemonSession[] }>(response)
  return body?.sessions ?? []
}

export async function tailSession(
  client: LiveClient,
  sessionId: string,
  offset: number | null,
): Promise<TailResult | null> {
  const params: Record<string, unknown> = { id: sessionId, max_bytes: 256 * 1024 }
  if (offset != null) params.offset = offset
  const response = await client.call('session.tail', params)
  return resultOf<TailResult>(response)
}

export async function screenSession(client: LiveClient, sessionId: string): Promise<ScreenResult> {
  const response = await client.call('session.screen', { id: sessionId, max_bytes: 256 * 1024 })
  const body = resultOf<{ text?: string; cols?: number; rows?: number }>(response)
  const text = body?.text ?? ''
  const lines = text.split('\n')
  const max_line = Math.max(1, ...lines.map((line) => [...line].length))
  return {
    text,
    cols: positive(body?.cols) ?? Math.max(80, max_line),
    rows: positive(body?.rows) ?? Math.max(8, lines.length),
    exact: false,
  }
}

export async function writeSession(client: LiveClient, sessionId: string, text: string): Promise<boolean> {
  const response = await client.call('session.write', { id: sessionId, text })
  return !response.error && response.ok !== false
}

export async function resizeSession(
  client: LiveClient,
  sessionId: string,
  cols: number,
  rows: number,
): Promise<void> {
  await client.call('session.resize', { id: sessionId, cols, rows })
}

export async function tailPane(
  client: LiveClient,
  workspaceId: string,
  paneId: number,
  lines = 400,
): Promise<string> {
  const response = await client.call('terminal.tail', {
    workspace_id: workspaceId,
    pane: paneId,
    lines,
  })
  return resultOf<{ text?: string }>(response)?.text ?? ''
}

export interface ScreenCell {
  x: number
  y: number
  fg?: string
  bg?: string
  f?: number
}

export interface ScreenCursor {
  x?: number
  y?: number
  visible?: boolean
}

export interface ScreenResult {
  text: string
  cols: number
  rows: number
  exact: boolean
  fg?: string
  bg?: string
  cursor?: ScreenCursor
  palette?: string[]
  cells?: ScreenCell[]
}

export async function screenPane(
  client: LiveClient,
  workspaceId: string,
  paneId: number,
): Promise<ScreenResult> {
  const response = await client.call('terminal.screen', {
    workspace_id: workspaceId,
    pane: paneId,
  })
  const body = resultOf<{
    text?: string
    cols?: number
    rows?: number
    fg?: string
    bg?: string
    cursor?: ScreenCursor
    palette?: string[]
    cells?: ScreenCell[]
  }>(response)
  const text = body?.text ?? ''
  const lines = text.split('\n')
  const max_line = Math.max(1, ...lines.map((line) => [...line].length))
  const cols = positive(body?.cols)
  const rows = positive(body?.rows)
  return {
    text,
    cols: cols ?? Math.max(80, max_line),
    rows: rows ?? Math.max(8, lines.length),
    exact: cols != null && rows != null,
    fg: body?.fg,
    bg: body?.bg,
    cursor: body?.cursor,
    palette: body?.palette,
    cells: body?.cells,
  }
}

function positive(value: number | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.round(value) : null
}

export async function writePane(
  client: LiveClient,
  workspaceId: string,
  paneId: number,
  text: string,
  sessionId?: string | null,
): Promise<boolean> {
  if (sessionId) return writeSession(client, sessionId, text)
  const response = await client.call('terminal.write', {
    workspace_id: workspaceId,
    pane: paneId,
    text,
  })
  return !response.error && response.ok !== false
}

export function sessionIdOf(session: DaemonSession): string {
  return session.session_id ?? session.id ?? ''
}

export function writeTerminalDelta(previous: string, next: string): { reset: boolean; chunk: string } {
  if (next === previous) return { reset: false, chunk: '' }
  if (previous && next.startsWith(previous)) return { reset: false, chunk: next.slice(previous.length) }
  if (previous.length > 64) {
    const tail = previous.slice(-64)
    const index = next.lastIndexOf(tail)
    if (index >= 0) return { reset: false, chunk: next.slice(index + tail.length) }
  }
  return { reset: true, chunk: next }
}

export function toXtermText(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\n/g, '\r\n')
}

/// Skip a ring-buffer slice that starts mid-CSI or mid-UTF-8 so leftover
/// fragments like `:20;20;20m]` are not painted as text.
export function alignPtyStream(bytes: string): string {
  if (!bytes) return bytes
  const markers = ['\u001b[?1049h', '\u001b[2J', '\u001b[H', '\u001bc', '\u001b[?1049l']
  let start = 0
  for (const marker of markers) {
    const index = bytes.lastIndexOf(marker)
    if (index > start) start = index
  }
  if (start === 0) {
    const esc = bytes.indexOf('\u001b')
    if (esc > 0 && esc < 256) start = esc
    else {
      const newline = bytes.indexOf('\n')
      if (newline >= 0 && newline < 256) start = newline + 1
    }
  }
  let aligned = start > 0 ? bytes.slice(start) : bytes
  // Cap the first replay so Ghostty WASM cannot trap on a huge ring dump.
  const MAX = 48 * 1024
  if (aligned.length > MAX) {
    const cut = aligned.length - MAX
    const esc = aligned.indexOf('\u001b', cut)
    aligned = aligned.slice(esc >= cut ? esc : cut)
  }
  return aligned
}
