import { expect, test } from 'bun:test'
import { latestPaneUsage, parseUsageSummary } from './usage.ts'
const body = 'Codex usage\n\nLimits\n• 5 hour: 74% left (resets 12:30)\n• Weekly: 0% left\nSummary\n• Lifetime tokens: 2.4M\nRecent daily usage\n• 2026-09-21: 50K tokens'
test('usage parses percent-left limits, stat tiles and daily rows', () => {
  expect(parseUsageSummary('Usage', body)).toEqual({ provider: 'codex', limits: [
    { label: '5 hour', percent_left: 74, reset: 'resets 12:30' }, { label: 'Weekly', percent_left: 0, reset: '' },
  ], stats: [{ label: 'Lifetime tokens', value: '2.4M' }], recent: [{ label: '2026-09-21', value: '50K tokens' }] })
  expect(parseUsageSummary('Usage', body.replace('Codex', 'Claude')).provider).toBe('claude')
})
test('usage requires exact provider heading and Usage author', () => {
  expect(parseUsageSummary('Assistant', body)).toBeNull()
  expect(parseUsageSummary('Usage', 'Codex usage example\nLimits')).toBeNull()
})
test('malformed limits are skipped and section rows are bounded', () => {
  const parsed = parseUsageSummary('Usage', 'Claude usage\nLimits\n• Bad: 101% left\n• Bad: -1% left\n• Bad: NaN% left\n• Bad: 2.5% left\nSummary\n' + '• Count: 1\n'.repeat(20))
  expect(parsed.limits).toEqual([])
  expect(parsed.stats.length).toBe(8)
})
test('per-pane selection ignores user and assistant content, supports slash output', () => {
  const messages = [{ role: 'system', author: 'Usage', body }, { role: 'user', author: 'Usage', body: body.replace('Codex', 'Claude') }]
  expect(latestPaneUsage(messages).provider).toBe('codex')
  expect(latestPaneUsage(messages, { transcript_title: 'Usage', transcript_body: body.replace('Codex', 'Claude') }).provider).toBe('claude')
  expect(latestPaneUsage([])).toBeNull()
})
