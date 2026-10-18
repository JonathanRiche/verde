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
