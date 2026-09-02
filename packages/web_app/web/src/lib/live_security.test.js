import { afterEach, describe, expect, test } from 'bun:test'
import { JSDOM } from 'jsdom'

import {
  LiveClient,
  chatImageUrl,
  deleteChatImage,
  fetchRpc,
  resetRuntimeIdentityForTests,
  stripLegacyTokenCredential,
  uploadChatImage,
  webSocketEndpoint,
} from './live.ts'

const original_window = globalThis.window
const original_fetch = globalThis.fetch

afterEach(() => {
  if (original_window === undefined) delete globalThis.window
  else globalThis.window = original_window
  globalThis.fetch = original_fetch
  resetRuntimeIdentityForTests()
})

describe('cookie-backed browser session transport', () => {
  test('deletes legacy token state without using or persisting it', () => {
    const dom = new JSDOM('', {
      url: 'https://verde.example/workspace?keep=yes&token=do-not-keep#pane-2',
    })
    dom.window.localStorage.setItem('verde.web.token', 'old-token')
    globalThis.window = dom.window

    stripLegacyTokenCredential()

    expect(dom.window.location.href).toBe('https://verde.example/workspace?keep=yes#pane-2')
    expect(dom.window.localStorage.getItem('verde.web.token')).toBeNull()
    dom.window.close()
  })

  test('uses the exact same-origin WebSocket path without a query', () => {
    expect(webSocketEndpoint('https://verde.example/workspace?token=old#pane').href)
      .toBe('wss://verde.example/ws')
    expect(webSocketEndpoint('http://127.0.0.1:6783/').href)
      .toBe('ws://127.0.0.1:6783/ws')
  })

  test('builds only daemon-owned attachment URLs', () => {
    expect(chatImageUrl({
      attachment_id: 'web-image-1',
      path: '/tmp/web-chat-images/web-image-1',
      mime: 'image/png',
      byte_size: 10,
    })).toBe('/api/attachment?id=web-image-1')
  })

  test('sends RPC requests with same-origin cookie credentials and no token header', async () => {
    let request
    globalThis.fetch = async (input, init) => {
      request = { input, init }
      return new Response('{"id":1,"result":{}}', {
        headers: { 'content-type': 'application/json' },
      })
    }

    await fetchRpc('core.status')

    expect(request.input).toBe('/api/rpc')
    expect(request.init.credentials).toBe('same-origin')
    expect(request.init.headers).toEqual({ 'content-type': 'application/json' })
  })

  test('bootstraps runtime identity once and targets every non-status RPC', async () => {
    const requests = []
    globalThis.fetch = async (_input, init) => {
      const body = JSON.parse(init.body)
      requests.push(body)
      if (body.method === 'core.status') {
        return Response.json({
          id: body.id,
          result: {
            runtime_id: '0123456789abcdef0123456789abcdef',
            instance_id: '00112233445566778899aabbccddeeff',
            runtime_capabilities: ['rpc.target.v1'],
          },
        })
      }
      return Response.json({ id: body.id, result: {} })
    }

    await Promise.all([
      fetchRpc('core.snapshot'),
      fetchRpc('chat.thread.list'),
    ])

    expect(requests).toHaveLength(3)
    expect(requests.filter((request) => request.method === 'core.status')).toHaveLength(1)
    for (const request of requests.filter((request) => request.method !== 'core.status')) {
      expect(request.target).toEqual({
        runtime_id: '0123456789abcdef0123456789abcdef',
        instance_id: '00112233445566778899aabbccddeeff',
      })
    }
  })

  test('attaches the learned immutable target to WebSocket RPCs', async () => {
    globalThis.fetch = async (_input, init) => {
      const body = JSON.parse(init.body)
      return Response.json({
        id: body.id,
        result: {
          runtime_id: '0123456789abcdef0123456789abcdef',
          instance_id: '00112233445566778899aabbccddeeff',
          runtime_capabilities: ['rpc.target.v1'],
        },
      })
    }
    await fetchRpc('core.status')

    let sent
    const client = new LiveClient()
    client.ws = {
      readyState: WebSocket.OPEN,
      send(payload) {
        sent = JSON.parse(payload)
      },
    }
    const pending = client.call('chat.turn.cancel', { turn_id: 'turn-1' })

    expect(sent.target).toEqual({
      runtime_id: '0123456789abcdef0123456789abcdef',
      instance_id: '00112233445566778899aabbccddeeff',
    })
    expect(sent.method).toBe('chat.turn.cancel')
    client.pending.get(sent.id).resolve({ id: sent.id, result: {} })
    await pending
  })

  test('rejects a replacement runtime for the lifetime of the page', async () => {
    let status_count = 0
    globalThis.fetch = async (_input, init) => {
      const body = JSON.parse(init.body)
      if (body.method !== 'core.status') return Response.json({ id: body.id, result: {} })
      status_count += 1
      return Response.json({
        id: body.id,
        result: {
          runtime_id: '0123456789abcdef0123456789abcdef',
          instance_id: status_count === 1
            ? '00112233445566778899aabbccddeeff'
            : 'ffeeddccbbaa99887766554433221100',
          runtime_capabilities: ['rpc.target.v1'],
        },
      })
    }

    await fetchRpc('core.snapshot')
    await fetchRpc('core.status')

    await expect(fetchRpc('chat.thread.list')).rejects.toThrow('runtime identity changed')
  })

  test('fails closed when bootstrap status lacks targeted RPC support', async () => {
    globalThis.fetch = async (_input, init) => {
      const body = JSON.parse(init.body)
      return Response.json({
        id: body.id,
        result: {
          runtime_id: '0123456789abcdef0123456789abcdef',
          instance_id: '00112233445566778899aabbccddeeff',
          runtime_capabilities: [],
        },
      })
    }

    await expect(fetchRpc('chat.turn.start')).rejects.toThrow('targeted RPC')
  })

  test('uses cookie credentials for attachment writes without a token header', async () => {
    const requests = []
    globalThis.fetch = async (input, init) => {
      requests.push({ input, init })
      if (init.method === 'POST') {
        return Response.json({
          attachment: {
            attachment_id: 'web-image-2',
            path: '/tmp/web-chat-images/web-image-2',
            mime: 'image/png',
            byte_size: 3,
          },
        })
      }
      return new Response(null, { status: 204 })
    }

    const uploaded = await uploadChatImage(new File(['png'], 'proof.png', { type: 'image/png' }), 'image/png')
    await deleteChatImage(uploaded)

    expect(requests).toHaveLength(2)
    expect(requests[0].init.credentials).toBe('same-origin')
    expect(requests[0].init.headers).toEqual({ 'content-type': 'image/png' })
    expect(requests[1].init.credentials).toBe('same-origin')
    expect(requests[1].init.headers).toBeUndefined()
  })
})
