import type { Attachment, RpcEnvelope } from './types'

/// chat.attachments.v1 client: repository-routed and remote turns cannot take
/// gateway file paths, so image bytes are streamed to the daemon that runs
/// the chat and the turn claims them by opaque id (see attachment_protocol.zig).

/** Raw bytes per append frame; the daemon's advertised limit still wins. */
export const WEB_ATTACHMENT_CHUNK_BYTES = 256 * 1024

type Call = (method: string, params: unknown) => Promise<RpcEnvelope>

function rpcResult<T>(response: RpcEnvelope, what: string): T {
  if (response.error || response.ok === false) throw new Error(`${what}: ${response.error?.message ?? 'failed'}`)
  const value = (response as { result?: unknown }).result
  if (!value || typeof value !== 'object') throw new Error(`${what}: empty response`)
  return value as T
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000))
  }
  return btoa(binary)
}

/** Upload one image to the target daemon and return its committed id. */
export async function stageAttachment(call: Call, mime: string, bytes: Uint8Array): Promise<string> {
  const created = rpcResult<{ attachment_id?: string; max_chunk_bytes?: number }>(
    await call('chat.attachment.create', { mime, byte_size: bytes.length }), 'Could not upload image')
  const id = created.attachment_id
  if (!id) throw new Error('Could not upload image: no attachment id')
  const limit = Math.min(WEB_ATTACHMENT_CHUNK_BYTES, created.max_chunk_bytes && created.max_chunk_bytes > 0 ? created.max_chunk_bytes : WEB_ATTACHMENT_CHUNK_BYTES)
  for (let offset = 0; offset < bytes.length; offset += limit) {
    rpcResult(await call('chat.attachment.append', {
      attachment_id: id, offset, data: bytesToBase64(bytes.subarray(offset, offset + limit)),
    }), 'Could not upload image')
  }
  rpcResult(await call('chat.attachment.commit', { attachment_id: id }), 'Could not upload image')
  return id
}

/**
 * Image params for chat.turn.start. Local primary-root turns keep the
 * gateway-path contract; routed turns stage bytes and reference ids.
 */
export async function turnImageParams(
  images: Attachment[],
  routed: boolean,
  call: Call,
  readBytes: (image: Attachment) => Promise<Uint8Array>,
): Promise<{ image_paths: string[]; images: Array<{ path: string; mime: string; byte_size: number }> } | { attachments: string[] }> {
  if (!routed) {
    return {
      image_paths: images.map((image) => image.path),
      images: images.map((image) => ({ path: image.path, mime: image.mime, byte_size: image.byte_size ?? 0 })),
    }
  }
  const attachments: string[] = []
  for (const image of images) attachments.push(await stageAttachment(call, image.mime, await readBytes(image)))
  return { attachments }
}
