import { fileCitationName } from './citations'
import { officePreviewUrl, workspaceFileUrl } from './live'

const IMAGE_EXTS = new Set(['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'])
const MARKDOWN_EXTS = new Set(['md', 'markdown'])
const OFFICE_EXTS = new Set(['pptx', 'ppt', 'odp', 'docx', 'doc', 'odt', 'xlsx', 'xls', 'ods', 'rtf'])

export function extOf(path: string): string {
  const name = fileCitationName(path)
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

export function isOfficePreviewPath(path: string): boolean {
  return OFFICE_EXTS.has(extOf(path))
}

export type FilePreview =
  | { kind: 'image'; url: string }
  | { kind: 'pdf' | 'office'; data: ArrayBuffer }
  | { kind: 'markdown' | 'text'; text: string }
  | { kind: 'none'; reason: string }

/// Fetch with the session cookie. Safari's PDF plugin re-requests iframe
/// `/api/file` without cookies and renders JSON as the empty sad-document
/// page, so PDF/office bytes are handed to the in-app canvas renderer.
export async function loadFilePreview(path: string): Promise<FilePreview> {
  const ext = extOf(path)
  if (IMAGE_EXTS.has(ext)) {
    return await loadBinary(workspaceFileUrl(path), { kind: 'image', mime: imageMime(ext) })
  }
  if (ext === 'pdf') {
    return await loadBinary(workspaceFileUrl(path), { kind: 'pdf' })
  }
  if (OFFICE_EXTS.has(ext)) {
    return await loadBinary(officePreviewUrl(path), { kind: 'office' })
  }
  const response = await fetch(workspaceFileUrl(path), { credentials: 'same-origin' })
  if (!response.ok) return previewFailure(response)
  const text = await response.text()
  if (text.includes('\u0000')) return { kind: 'none', reason: 'No preview for binary files.' }
  return { kind: MARKDOWN_EXTS.has(ext) ? 'markdown' : 'text', text }
}

export function revokeFilePreview(preview: FilePreview | undefined): void {
  if (preview?.kind === 'image') URL.revokeObjectURL(preview.url)
}

async function loadBinary(
  url: string,
  target: { kind: 'image'; mime: string } | { kind: 'pdf' } | { kind: 'office' },
): Promise<FilePreview> {
  const response = await fetch(url, { credentials: 'same-origin' })
  if (!response.ok) return previewFailure(response)
  const data = await response.arrayBuffer()
  if (data.byteLength === 0) return { kind: 'none', reason: 'file is empty' }
  if (target.kind === 'image') {
    return { kind: 'image', url: URL.createObjectURL(new Blob([data], { type: target.mime })) }
  }
  return { kind: target.kind, data }
}

async function previewFailure(response: Response): Promise<FilePreview> {
  const payload = (await response.json().catch(() => null)) as { error?: string } | null
  return {
    kind: 'none',
    reason: payload?.error?.replaceAll('_', ' ') ?? `could not load file (${response.status})`,
  }
}

function imageMime(ext: string): string {
  if (ext === 'jpg') return 'image/jpeg'
  return `image/${ext}`
}
