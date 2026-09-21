import type { Message } from './types'

export interface UsageLimit { label: string; percent_left: number; reset: string }
export interface UsageStat { label: string; value: string }
export interface UsageSummary {
  provider: 'codex' | 'claude'
  limits: UsageLimit[]
  stats: UsageStat[]
  recent: UsageStat[]
}

/** Parse the provider's /usage transcript format, never ordinary assistant prose. */
export function parseUsageSummary(author: string | undefined, body: string): UsageSummary | null {
  if (author !== 'Usage') return null
  const lines = body.trim().split(/\r?\n/)
  const provider = lines[0] === 'Codex usage' ? 'codex' : lines[0] === 'Claude usage' ? 'claude' : null
  if (!provider) return null
  const result: UsageSummary = { provider, limits: [], stats: [], recent: [] }
  let section: 'limits' | 'stats' | 'recent' | null = null
  for (const raw of lines.slice(1)) {
    const line = raw.trim()
    if (line === 'Limits') { section = 'limits'; continue }
    if (line === 'Summary') { section = 'stats'; continue }
    if (line === 'Recent daily usage') { section = 'recent'; continue }
    if (!section || !line.startsWith('• ') || result[section].length >= 8) continue
    const item = line.slice(2)
    const colon = item.indexOf(':')
    if (colon < 1) continue
    const label = item.slice(0, colon).trim(), value = item.slice(colon + 1).trim()
    if (!label || !value) continue
    if (section === 'limits') {
      const match = /^([+-]?\d+)% left(?:\s+\((.*)\))?$/.exec(value)
      if (!match) continue
      const percent = Number(match[1])
      if (!Number.isSafeInteger(percent) || percent < 0 || percent > 100) continue
      result.limits.push({ label, percent_left: percent, reset: match[2] ?? '' })
    } else result[section].push({ label, value })
  }
  return result
}

export function latestPaneUsage(messages: readonly Message[], slash?: { transcript_title?: string | null; transcript_body?: string | null } | null): UsageSummary | null {
  if (slash?.transcript_body) {
    const usage = parseUsageSummary(slash.transcript_title ?? undefined, slash.transcript_body)
    if (usage) return usage
  }
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index]!
    if (message.role !== 'system') continue
    const usage = parseUsageSummary(message.author, message.body)
    if (usage) return usage
  }
  return null
}
