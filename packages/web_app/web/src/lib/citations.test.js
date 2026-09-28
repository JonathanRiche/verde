import { expect, test } from 'bun:test'

import { decorateTranscriptFiles, filePathFromHref } from './citations.ts'

test('markdown file URLs round-trip encoded Mac paths without double encoding', () => {
  const path = '/Users/jhonellebriche/Library/Application Support/Verde/workspaces/event-rentals-venture/finance/reports/report.pdf'
  for (const prefix of ['', 'file://']) {
    const decorated = decorateTranscriptFiles(`[Investor report](${prefix}${encodeURI(path)})`)
    const href = /\]\(([^)]+)\)/.exec(decorated)[1]
    expect(filePathFromHref(href, 'http://localhost:6783')).toBe(path)
  }
})

test('markdown paths decode once and tolerate literal percent signs', () => {
  for (const [url, path] of [['/work/100%25%20done.pdf', '/work/100% done.pdf'],
    ['/work/literal%2520.pdf', '/work/literal%20.pdf'], ['/work/100%.pdf', '/work/100%.pdf']]) {
    const href = /\]\(([^)]+)\)/.exec(decorateTranscriptFiles(`[Report](${url})`))[1]
    expect(filePathFromHref(href, 'http://localhost:6783')).toBe(path)
  }
  const citation = decorateTranscriptFiles(':codex-file-citation{path="/work/literal%20.pdf" purpose="output"}')
  expect(filePathFromHref(/href="([^"]+)"/.exec(citation)[1], 'http://localhost:6783')).toBe('/work/literal%20.pdf')
})

test('filePathFromHref reads file/preview endpoints and legacy absolute hrefs, ignoring app URLs', () => {
  const origin = 'http://127.0.0.1:6783'
  expect(filePathFromHref('/api/file?path=%2Fhome%2Frtg%2Fplan.docx', origin)).toBe('/home/rtg/plan.docx')
  expect(filePathFromHref('/api/preview?path=%2Fhome%2Frtg%2Fplan.docx', origin)).toBe('/home/rtg/plan.docx')
  expect(filePathFromHref('/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf', origin))
    .toBe('/home/rtg/development/sideb/sjevents/SJ-Co-Events-Pitch-Deck.pdf')
  expect(filePathFromHref('/login', origin)).toBeNull()
  expect(filePathFromHref('/assets/index.js', origin)).toBeNull()
  expect(filePathFromHref('https://example.com/report.pdf', origin)).toBeNull()
})
