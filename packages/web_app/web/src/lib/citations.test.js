import { describe, expect, test } from 'bun:test'

import { decorateWorkspaceFileLinks, filePathFromHref } from './citations.ts'

describe('filePathFromHref', () => {
  const origin = 'http://127.0.0.1:6783'

  test('reads the path query from the file and preview endpoints', () => {
    expect(filePathFromHref(
      '/api/file?path=%2Fhome%2Frtg%2Fplan.docx',
      origin,
    )).toBe('/home/rtg/plan.docx')
    expect(filePathFromHref(
      '/api/preview?path=%2Fhome%2Frtg%2Fplan.docx',
      origin,
    )).toBe('/home/rtg/plan.docx')
  })

  test('accepts leftover absolute workspace hrefs from older renders', () => {
    expect(filePathFromHref(
      '/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf',
      origin,
    )).toBe('/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf')
  })

  test('ignores app and asset URLs', () => {
    expect(filePathFromHref('/login', origin)).toBeNull()
    expect(filePathFromHref('/assets/index.js', origin)).toBeNull()
    expect(filePathFromHref('https://example.com/report.pdf', origin)).toBeNull()
  })
})

describe('decorateWorkspaceFileLinks', () => {
  test('rewrites a Word and PDF markdown link onto /api/file', () => {
    const body = decorateWorkspaceFileLinks(
      '[Business Plan — Word](/home/rtg/development/sideb/sjevents/SJ-Co-Events-Business-Plan.docx)\n' +
        '[Pitch Deck — PDF](/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf)',
    )
    expect(body).toContain('/api/file?path=')
    expect(body).toContain(encodeURIComponent('/home/rtg/development/sideb/sjevents/SJ-Co-Events-Business-Plan.docx'))
    expect(body).toContain(encodeURIComponent('/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf'))
  })
})
