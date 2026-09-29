import { afterEach, describe, expect, test } from 'bun:test'

import { loadFilePreview, revokeFilePreview } from './file_preview.ts'

const original_fetch = globalThis.fetch
const { createObjectURL, revokeObjectURL } = URL

afterEach(() => {
  globalThis.fetch = original_fetch
  URL.createObjectURL = createObjectURL
  URL.revokeObjectURL = revokeObjectURL
})

describe('loadFilePreview', () => {
  test('fetches a PDF with cookies and returns the bytes', async () => {
    globalThis.fetch = async (input, init) => {
      expect(String(input)).toContain('/api/file?')
      expect(init?.credentials).toBe('same-origin')
      return new Response(new Uint8Array([0x25, 0x50, 0x44, 0x46]), {
        status: 200,
        headers: { 'content-type': 'application/pdf' },
      })
    }

    const preview = await loadFilePreview('/home/rtg/deck.pdf')
    expect(preview.kind).toBe('pdf')
    expect(preview.kind === 'pdf' && preview.data.byteLength).toBe(4)
    revokeFilePreview(preview)
  })

  test('surfaces a JSON file error instead of stuffing it into a PDF iframe', async () => {
    globalThis.fetch = async () =>
      new Response(JSON.stringify({ ok: false, error: 'unauthorized' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      })

    const preview = await loadFilePreview('/home/rtg/deck.pdf')
    expect(preview).toEqual({ kind: 'none', reason: 'unauthorized' })
  })

  test('converts Word documents through the preview endpoint', async () => {
    globalThis.fetch = async (input) => {
      expect(String(input)).toContain('/api/preview?')
      return new Response(new Uint8Array([0x25, 0x50, 0x44, 0x46]), { status: 200 })
    }

    const preview = await loadFilePreview('/home/rtg/plan.docx')
    expect(preview.kind).toBe('office')
    expect(preview.kind === 'office' && preview.data.byteLength).toBe(4)
    revokeFilePreview(preview)
  })

  test('renders SVG as an image from the download attachment', async () => {
    globalThis.URL.createObjectURL = () => 'blob:svg'
    globalThis.URL.revokeObjectURL = () => {}
    globalThis.fetch = async (input) => {
      expect(String(input)).toContain('download=1')
      return new Response('<svg xmlns="http://www.w3.org/2000/svg"/>', { status: 200 })
    }

    const preview = await loadFilePreview('/home/rtg/find-your-chapter.svg')
    expect(preview).toEqual({ kind: 'image', url: 'blob:svg' })
    revokeFilePreview(preview)
  })

  test('shows HTML source from the download attachment', async () => {
    globalThis.fetch = async (input) => {
      expect(String(input)).toContain('download=1')
      return new Response('<h1>hi</h1>', { status: 200 })
    }

    expect(await loadFilePreview('/home/rtg/page.html')).toEqual({ kind: 'text', text: '<h1>hi</h1>' })
  })
})
