import { describe, expect, test } from 'bun:test'
import { advanceAttention } from './notify.ts'

const empty = () => ({ previous: new Map(), attention: new Set() })
const row = (status, key = 'ws:1') => ({ key, status })
const working = () => advanceAttention(empty(), [row('working')], null)

describe('notification attention transitions', () => {
  for (const status of ['done', 'waiting', 'error']) {
    test(`working -> ${status} alerts once and remains unacknowledged`, () => {
      const next = advanceAttention(working(), [row(status)], null)
      expect(next.notifications).toEqual(['ws:1'])
      expect(next.attention.size).toBe(1)
      const repeat = advanceAttention(next, [row(status)], null)
      expect(repeat.notifications).toEqual([])
      expect(repeat.attention.size).toBe(1)
    })
  }
  test('focus acknowledges without notifying again on blur', () => {
    const done = advanceAttention(working(), [row('done')], null)
    const acknowledged = advanceAttention(done, [row('done')], 'ws:1')
    expect(acknowledged.attention.size).toBe(0)
    expect(advanceAttention(acknowledged, [row('done')], null).notifications).toEqual([])
  })
  test('resume, abort and removal clear attention', () => {
    const done = advanceAttention(working(), [row('waiting')], null)
    for (const rows of [[], [row('working')], [row('idle')]]) {
      expect(advanceAttention(done, rows, null).attention.size).toBe(0)
    }
    const resumed = advanceAttention(done, [row('working')], null)
    expect(advanceAttention(resumed, [row('done')], null).notifications).toEqual(['ws:1'])
  })
})
