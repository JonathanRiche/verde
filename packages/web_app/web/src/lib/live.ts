import type { Attachment, RpcEnvelope, Source } from './types'

export type EventHandler = (message: RpcEnvelope) => void

interface RuntimeRequestTarget {
  runtime_id: string
  instance_id: string
}

const RUNTIME_TARGET_CAPABILITY = 'rpc.target.v1'
const RUNTIME_ID_PATTERN = /^[0-9a-f]{32}$/

let runtimeTarget: Readonly<RuntimeRequestTarget> | null = null
let runtimeTargetBootstrap: Promise<Readonly<RuntimeRequestTarget>> | null = null
let runtimeIdentityRejected = false

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

  /// Replace a socket that may look open after a mobile page suspension but
  /// no longer has a usable network connection.
  reconnect(): void {
    this.closed = false
    this.clearReconnectTimer()
    const socket = this.ws
    this.ws = null
    this.connected = false
    this.resolvePendingAsClosed()
    socket?.close()
    this.open()
  }

  disconnect(): void {
    this.closed = true
    this.clearReconnectTimer()
    const socket = this.ws
    this.ws = null
    this.connected = false
    this.resolvePendingAsClosed()
    socket?.close()
  }

  onEvent(handler: EventHandler): () => void {
    this.listeners.add(handler)
    return () => this.listeners.delete(handler)
  }

  async call(method: string, params: unknown = {}): Promise<RpcEnvelope> {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || runtimeTarget === null) {
      return fetchRpc(method, params)
    }
    const id = this.nextId++
    const payload = JSON.stringify({ id, method, params, target: requireRuntimeTarget() })
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.ws?.send(payload)
    })
  }

  private open(): void {
    if (this.closed) return
    if (this.ws?.readyState === WebSocket.OPEN || this.ws?.readyState === WebSocket.CONNECTING) return
    this.clearReconnectTimer()
    stripLegacyTokenCredential()
    const socket = new WebSocket(webSocketEndpoint(location.href))
    this.ws = socket

    socket.addEventListener('open', () => {
      if (this.ws !== socket) return
      this.connected = true
    })
    socket.addEventListener('message', (event) => {
      if (this.ws !== socket) return
      const parsed = parseEnvelope(String(event.data))
      if (!parsed) return
      if (parsed.method === 'core.hello') {
        const params = parsed.params as { source?: Source; status_envelope?: RpcEnvelope } | undefined
        if (params?.source) this.source = params.source
        try {
          rememberRuntimeTarget(params?.status_envelope)
        } catch {
          // A changed daemon identity can otherwise redirect an already-open
          // page's later mutations to a replacement runtime.
          this.closed = true
          this.ws = null
          this.connected = false
          this.resolvePendingAsClosed()
          socket.close()
          return
        }
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
      if (this.ws !== socket) return
      this.ws = null
      this.connected = false
      this.resolvePendingAsClosed()
      this.scheduleReconnect()
    })
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer === null) return
    window.clearTimeout(this.reconnectTimer)
    this.reconnectTimer = null
  }

  private resolvePendingAsClosed(): void {
    for (const [id, waiter] of this.pending) {
      this.pending.delete(id)
      waiter.resolve({ id, error: { code: 'closed', message: 'socket closed' } })
    }
  }

  private scheduleReconnect(): void {
    if (this.closed || this.reconnectTimer !== null) return
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = null
      this.open()
    }, 1500)
  }
}

/// Removes credentials accepted by old gateway builds before any transport is
/// opened. Tokens are never read or migrated: authentication is an HttpOnly,
/// same-origin cookie owned by the gateway session endpoint.
export function stripLegacyTokenCredential(): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.removeItem('verde.web.token')
  } catch {
    // Storage can be unavailable in privacy modes; URL cleanup must continue.
  }

  const clean_url = new URL(window.location.href)
  if (!clean_url.searchParams.has('token')) return
  clean_url.searchParams.delete('token')
  window.history.replaceState(
    window.history.state,
    '',
    `${clean_url.pathname}${clean_url.search}${clean_url.hash}`,
  )
}

stripLegacyTokenCredential()

export function webSocketEndpoint(page_url: string): URL {
  const endpoint = new URL('/ws', page_url)
  endpoint.protocol = endpoint.protocol === 'https:' ? 'wss:' : 'ws:'
  return endpoint
}

export async function fetchRpc(method: string, params: unknown = {}): Promise<RpcEnvelope> {
  if (method === 'core.status') {
    const status = await fetchRpcRaw(method, params)
    tryRememberRuntimeTarget(status)
    return status
  }

  const target = await ensureRuntimeTarget()
  return fetchRpcRaw(method, params, target)
}

async function fetchRpcRaw(
  method: string,
  params: unknown,
  target?: Readonly<RuntimeRequestTarget>,
): Promise<RpcEnvelope> {
  const response = await fetch('/api/rpc', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(target
      ? { id: Date.now(), method, params, target }
      : { id: Date.now(), method, params }),
  })
  return (await response.json()) as RpcEnvelope
}

async function ensureRuntimeTarget(): Promise<Readonly<RuntimeRequestTarget>> {
  if (runtimeIdentityRejected) throw new Error('runtime identity changed; reload the page')
  if (runtimeTarget) return runtimeTarget
  if (!runtimeTargetBootstrap) {
    runtimeTargetBootstrap = fetchRpcRaw('core.status', {})
      .then((status) => rememberRuntimeTarget(status))
      .finally(() => {
        runtimeTargetBootstrap = null
      })
  }
  return runtimeTargetBootstrap
}

function requireRuntimeTarget(): Readonly<RuntimeRequestTarget> {
  if (runtimeIdentityRejected || !runtimeTarget) {
    throw new Error('runtime identity is unavailable; reload the page')
  }
  return runtimeTarget
}

function tryRememberRuntimeTarget(status: unknown): void {
  try {
    rememberRuntimeTarget(status)
  } catch {
    // Bootstrap status remains readable for diagnostics and compatibility.
    // Every non-status RPC still calls ensureRuntimeTarget and fails closed.
  }
}

function rememberRuntimeTarget(status: unknown): Readonly<RuntimeRequestTarget> {
  const result = statusResult(status)
  const runtime_id = result?.runtime_id
  const instance_id = result?.instance_id
  const capabilities = result?.runtime_capabilities
  if (
    typeof runtime_id !== 'string' ||
    typeof instance_id !== 'string' ||
    !RUNTIME_ID_PATTERN.test(runtime_id) ||
    !RUNTIME_ID_PATTERN.test(instance_id) ||
    !Array.isArray(capabilities) ||
    !capabilities.includes(RUNTIME_TARGET_CAPABILITY)
  ) {
    throw new Error('daemon does not advertise targeted RPC')
  }

  if (
    runtimeTarget &&
    (runtimeTarget.runtime_id !== runtime_id || runtimeTarget.instance_id !== instance_id)
  ) {
    runtimeIdentityRejected = true
    throw new Error('runtime identity changed; reload the page')
  }

  if (!runtimeTarget) runtimeTarget = Object.freeze({ runtime_id, instance_id })
  return runtimeTarget
}

function statusResult(status: unknown): Record<string, unknown> | null {
  if (!status || typeof status !== 'object') return null
  const root = status as Record<string, unknown>
  if (root.error || root.ok === false) return null
  if (root.result && typeof root.result === 'object' && !Array.isArray(root.result)) {
    const outer = root.result as Record<string, unknown>
    if (outer.result && typeof outer.result === 'object' && !Array.isArray(outer.result)) {
      return outer.result as Record<string, unknown>
    }
    return outer
  }
  return null
}

/// Clears page-lifetime identity state between transport security tests.
export function resetRuntimeIdentityForTests(): void {
  runtimeTarget = null
  runtimeTargetBootstrap = null
  runtimeIdentityRejected = false
}

export async function uploadChatImage(file: File, mime: string): Promise<Attachment> {
  const response = await fetch('/api/attachment', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'content-type': mime },
    body: file,
  })
  const payload = (await response.json().catch(() => null)) as
    | { attachment?: Attachment; error?: string }
    | null
  if (!response.ok || !payload?.attachment) {
    const reason = payload?.error?.replaceAll('_', ' ') ?? `upload failed (${response.status})`
    throw new Error(reason)
  }
  return { ...payload.attachment, name: file.name }
}

export async function deleteChatImage(attachment: Attachment): Promise<void> {
  const id = webChatAttachmentId(attachment)
  if (!id) return
  await fetch(`/api/attachment?id=${encodeURIComponent(id)}`, {
    method: 'DELETE',
    credentials: 'same-origin',
  })
}

export function chatImageUrl(attachment: Attachment): string | null {
  const id = webChatAttachmentId(attachment)
  if (!id) return null
  const query = new URLSearchParams({ id })
  return `/api/attachment?${query.toString()}`
}

function webChatAttachmentId(attachment: Attachment): string | null {
  if (attachment.attachment_id?.startsWith('web-')) return attachment.attachment_id
  const marker = '/web-chat-images/'
  const offset = attachment.path.lastIndexOf(marker)
  if (offset < 0) return null
  const id = attachment.path.slice(offset + marker.length)
  return id.startsWith('web-') && !id.includes('/') ? id : null
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
