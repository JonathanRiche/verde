import { expect, test } from 'bun:test'

import { filePathFromHref } from './citations.ts'

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
