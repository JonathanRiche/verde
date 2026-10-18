import { afterEach, describe, expect, test } from 'bun:test'

import { loadFilePreview } from './file_preview.ts'

const original_fetch = globalThis.fetch
const { createObjectURL, revokeObjectURL } = URL

afterEach(() => {
  globalThis.fetch = original_fetch
  URL.createObjectURL = createObjectURL
  URL.revokeObjectURL = revokeObjectURL
})

describe('loadFilePreview', () => {

  test('shows HTML source from the download attachment', async () => {
    globalThis.fetch = async (input) => {
      expect(String(input)).toContain('download=1')
      return new Response('<h1>hi</h1>', { status: 200 })
    }

    expect(await loadFilePreview('/home/rtg/page.html')).toEqual({ kind: 'text', text: '<h1>hi</h1>' })
  })
})
