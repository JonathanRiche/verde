import { expect, test } from 'bun:test'
import { bytesToBase64, stageAttachment, turnImageParams } from './staged_attachments'

const image = { path: '/gateway/web-chat-images/a.png', mime: 'image/png', byte_size: 5 }

test('local primary-root turns keep gateway paths and never upload', async () => {
  const calls = []
  const params = await turnImageParams([image], false, async (...args) => { calls.push(args); return {} }, async () => new Uint8Array())
  expect(params).toEqual({ image_paths: [image.path], images: [{ path: image.path, mime: 'image/png', byte_size: 5 }] })
  expect(calls).toEqual([])
})

test('routed turns stream bytes in offset chunks and reference committed ids', async () => {
  const calls = []
  const bytes = new Uint8Array(10).map((_, index) => index)
  const call = async (method, params) => {
    calls.push([method, params])
    if (method === 'chat.attachment.create') return { result: { attachment_id: 'a'.repeat(32), max_chunk_bytes: 4 } }
    if (method === 'chat.attachment.append') return { result: { received_bytes: params.offset } }
    return { result: { committed: true } }
  }
  expect(await turnImageParams([image], true, call, async () => bytes)).toEqual({ attachments: ['a'.repeat(32)] })
  expect(calls[0]).toEqual(['chat.attachment.create', { mime: 'image/png', byte_size: 10 }])
  expect(calls.filter(([method]) => method === 'chat.attachment.append').map(([, params]) => [params.offset, params.data]))
    .toEqual([[0, bytesToBase64(bytes.subarray(0, 4))], [4, bytesToBase64(bytes.subarray(4, 8))], [8, bytesToBase64(bytes.subarray(8))]])
  expect(calls.at(-1)).toEqual(['chat.attachment.commit', { attachment_id: 'a'.repeat(32) }])
})

test('daemon rejections surface as errors', async () => {
  await expect(stageAttachment(async () => ({ error: { message: 'unsupported attachment mime type' } }), 'image/png', new Uint8Array(8)))
    .rejects.toThrow('unsupported attachment mime type')
})
