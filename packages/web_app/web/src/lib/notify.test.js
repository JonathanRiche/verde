import { describe, expect, test } from 'bun:test'
import { advanceAttention, notificationBody, notificationStatus } from './notify.ts'

const empty = () => ({ previous: new Map(), attention: new Set() })
const row = (status, key = 'ws:1') => ({ key, status })
const working = () => advanceAttention(empty(), [row('working')], null)

describe('notification attention transitions', () => {
  test('initial completed, approval and failed panes are silent', () => {
    const next = advanceAttention(empty(), [row('done'), row('waiting', 'ws:2'), row('error', 'ws:3')], null)
    expect(next.notifications).toEqual([])
    expect(next.attention.size).toBe(0)
  })
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
  for (const status of ['done', 'error']) {
    test(`acknowledged approval -> ${status} alerts and restores the badge once`, () => {
      const waiting = advanceAttention(working(), [row('waiting')], null)
      const acknowledged = advanceAttention(waiting, [row('waiting')], 'ws:1')
      expect(acknowledged.attention.size).toBe(0)
      const next = advanceAttention(acknowledged, [row(status)], null)
      expect(next.notifications).toEqual(['ws:1'])
      expect([...next.attention]).toEqual(['ws:1'])
      const repeat = advanceAttention(next, [row(status)], null)
      expect(repeat.notifications).toEqual([])
      expect(repeat.attention.size).toBe(1)
      const focused = advanceAttention(acknowledged, [row(status)], 'ws:1')
      expect(focused.notifications).toEqual([])
      expect(focused.attention.size).toBe(0)
    })
    test(`unacknowledged approval -> ${status} does not double-count the badge`, () => {
      const waiting = advanceAttention(working(), [row('waiting')], null)
      const next = advanceAttention(waiting, [row(status)], null)
      expect(next.notifications).toEqual(['ws:1'])
      expect(next.attention.size).toBe(1)
    })
  }
  test('visible focused pane is suppressed; hidden document uses null focus', () => {
    expect(advanceAttention(working(), [row('done')], 'ws:1').attention.size).toBe(0)
    expect(advanceAttention(working(), [row('done')], null).attention.size).toBe(1)
  })
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
  test('same pane number in different workspaces has separate attention', () => {
    const before = advanceAttention(empty(), [row('working', 'a:1'), row('working', 'b:1')], null)
    const after = advanceAttention(before, [row('done', 'a:1'), row('error', 'b:1')], 'a:1')
    expect([...after.attention]).toEqual(['b:1'])
  })
})

test('notification bodies use only workspace labels, never filesystem path fallbacks', () => {
  const path = '/home/private/project'
  expect(notificationBody('done', { label: 'Project', path })).toBe('Reply ready in Project')
  for (const workspace of [undefined, { path }, { label: '', path }]) {
    expect(notificationBody('done', workspace)).toBe('Reply ready in workspace')
    expect(notificationBody('waiting', workspace)).toBe('Needs approval')
    expect(notificationBody('error', workspace)).toBe('Turn failed')
  }
})

test('projection status uses approval/failure before pending work and ignores cancellation', () => {
  const pane = { send_pending: true }
  expect(notificationStatus(pane)).toBe('working')
  expect(notificationStatus(pane, { status: 'failed' })).toBe('error')
  expect(notificationStatus(pane, undefined, true)).toBe('waiting')
  expect(notificationStatus(pane, { status: 'aborted' })).toBe('idle')
  expect(notificationStatus({}, { status: 'completed' })).toBe('done')
  expect(notificationStatus({ completion_pending: true })).toBe('done')
})

// Exercise the actual worker click handler without a browser or live service.
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

for (const existing of [true, false]) {
  test(`service worker click ${existing ? 'focuses an existing app' : 'opens a pane deep link'}`, async () => {
    const listeners = {}
    const actions = []
    const key = 'workspace:42'
    runInNewContext(readFileSync(new URL('../../public/sw.js', import.meta.url), 'utf8'), {
      URL,
      self: {
        location: { origin: 'https://verde.example' },
        addEventListener: (name, callback) => { listeners[name] = callback },
        clients: {
          matchAll: async () => existing ? [{
            url: 'https://verde.example/',
            focus: async () => actions.push('focus'),
            postMessage: (message) => actions.push(message),
          }] : [],
          openWindow: async (url) => actions.push(url),
        },
      },
    })
    let finished
    listeners.notificationclick({
      notification: { data: { key }, close: () => actions.push('close') },
      waitUntil: (promise) => { finished = promise },
    })
    await finished
    expect(actions).toEqual(existing
      ? ['close', 'focus', { type: 'verde:notification-focus', key }]
      : ['close', '/?notification-pane=workspace%3A42'])
  })
}
