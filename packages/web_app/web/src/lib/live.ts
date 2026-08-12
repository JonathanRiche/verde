import type { RpcEnvelope, Source } from './types'

export type EventHandler = (message: RpcEnvelope) => void

export class LiveClient {
  private ws: WebSocket | null = null
  private nextId = 1
  private pending = new Map<number, { resolve: (value: RpcEnvelope) => void; reject: (err: Error) => void }>()
  private listeners = new Set<EventHandler>()
  private reconnectTimer: number | null = null
  private closed = false

  source: Source = 'mock'
  connected = false

  connect(): void {
    this.closed = false
    this.open()
  }

  disconnect(): void {
    this.closed = true
    if (this.reconnectTimer !== null) window.clearTimeout(this.reconnectTimer)
    this.ws?.close()
    this.ws = null
  }

  onEvent(handler: EventHandler): () => void {
    this.listeners.add(handler)
    return () => this.listeners.delete(handler)
  }

  async call(method: string, params: unknown = {}): Promise<RpcEnvelope> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return fetchRpc(method, params)
    }
    const id = this.nextId++
    const payload = JSON.stringify({ id, method, params })
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.ws?.send(payload)
    })
  }

  private open(): void {
    const token = readToken()
    const proto = location.protocol === 'https:' ? 'wss' : 'ws'
    const query = token ? `?token=${encodeURIComponent(token)}` : ''
    const socket = new WebSocket(`${proto}://${location.host}/ws${query}`)
    this.ws = socket

    socket.addEventListener('open', () => {
      this.connected = true
    })
    socket.addEventListener('message', (event) => {
      const parsed = parseEnvelope(String(event.data))
      if (!parsed) return
      if (parsed.method === 'core.hello') {
        const params = parsed.params as { source?: Source } | undefined
        if (params?.source) this.source = params.source
      }
      if (typeof parsed.id === 'number' && this.pending.has(parsed.id)) {
        const waiter = this.pending.get(parsed.id)
        this.pending.delete(parsed.id)
        waiter?.resolve(parsed)
        return
      }
      for (const listener of this.listeners) listener(parsed)
    })
    socket.addEventListener('close', () => {
      this.connected = false
      for (const [id, waiter] of this.pending) {
        this.pending.delete(id)
        waiter.resolve({ id, error: { code: 'closed', message: 'socket closed' } })
      }
      if (!this.closed) {
        this.reconnectTimer = window.setTimeout(() => this.open(), 1500)
      }
    })
  }
}

export function readToken(): string {
  const fromQuery = new URLSearchParams(location.search).get('token')
  if (fromQuery) {
    localStorage.setItem('verde.web.token', fromQuery)
    return fromQuery
  }
  return localStorage.getItem('verde.web.token') ?? ''
}

export async function fetchRpc(method: string, params: unknown = {}): Promise<RpcEnvelope> {
  const token = readToken()
  const response = await fetch('/api/rpc', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(token ? { 'x-verde-token': token } : {}),
    },
    body: JSON.stringify({ id: Date.now(), method, params }),
  })
  return (await response.json()) as RpcEnvelope
}

function parseEnvelope(raw: string): RpcEnvelope | null {
  try {
    return JSON.parse(raw) as RpcEnvelope
  } catch {
    return null
  }
}

export function unwrapResult<T>(envelope: RpcEnvelope | unknown): T | null {
  if (!envelope || typeof envelope !== 'object') return null
  const root = envelope as Record<string, unknown>
  if (root.error) return null
  if (root.ok === false) return null
  if (root.result && typeof root.result === 'object') {
    const nested = root.result as Record<string, unknown>
    if (nested.result && typeof nested.result === 'object' && !Array.isArray(nested.result)) {
      return nested.result as T
    }
    return root.result as T
  }
  if (root.params && typeof root.params === 'object') {
    return unwrapResult<T>(root.params)
  }
  return root as T
}

export function unwrapList<T>(value: unknown, key: string): T[] {
  if (!value || typeof value !== 'object') return []
  const record = value as Record<string, unknown>
  const direct = record[key]
  if (Array.isArray(direct)) return direct as T[]
  if (record.result && typeof record.result === 'object') {
    const nested = (record.result as Record<string, unknown>)[key]
    if (Array.isArray(nested)) return nested as T[]
  }
  return []
}
