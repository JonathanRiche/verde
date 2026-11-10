import { expect, test } from 'bun:test'
import { dynamicModelOptions, effortOptionsFor, modelOptionsFor } from './models'

test('Muse Ember has exact efforts in static and live catalogs without changing Wonder', () => {
  const expected = [null, 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
  expect(effortOptionsFor('muse', 'muse-ember-1.0').map(row => row.value)).toEqual(expected)
  const live = dynamicModelOptions('muse', [{ model_id: 'muse-ember-1.0' }, { model_id: 'muse-wonder-1.0' }])
  expect(live[0].efforts.map(row => row.value)).toEqual(expected)
  expect(live[0].efforts.at(-1).label).toBe('Max')
  expect(live[1].efforts.at(-1).label).toBe('Ultra')
  expect(live[1].efforts.some(row => row.value === 'minimal')).toBe(false)
  expect(modelOptionsFor('muse')[0].value).toBe('muse-wonder-1.0')
  expect(modelOptionsFor('muse').filter(row => row.value.includes('ember')).map(row => row.value)).toEqual(['muse-ember-1.0'])
})
