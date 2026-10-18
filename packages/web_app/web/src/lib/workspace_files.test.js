import { expect, test } from 'bun:test'
import { absolutePath, locateInRoots } from './workspace_files'

const ROOTS = [{ id: 'home', name: 'verde', path: '/w/verde' }, { id: 'verde-cloud', name: 'verde-cloud', path: '/w/verde-cloud/' }]

test('absolute paths map to (root, relative path) and back', () => {
  expect(absolutePath(ROOTS[1], 'a/b.ts')).toBe('/w/verde-cloud/a/b.ts')
  expect(absolutePath(ROOTS[0], '')).toBe('/w/verde')
  expect(locateInRoots('/w/verde/src/main.zig', ROOTS)).toEqual({ root: 'home', path: 'src/main.zig' })
  expect(locateInRoots('/w/verde-cloud/README', ROOTS)).toEqual({ root: 'verde-cloud', path: 'README' })
  expect(locateInRoots('/w/verde-clouds/x', ROOTS)).toBeNull()
  expect(locateInRoots('/w/verde', ROOTS)).toBeNull()
  expect(locateInRoots('/w/verde/../etc/passwd', ROOTS)).toBeNull()
  const nested = [{ id: 'home', name: 'home', path: '/w' }, { id: 'lib', name: 'lib', path: '/w/lib' }]
  expect(locateInRoots('/w/lib/x.c', nested)).toEqual({ root: 'lib', path: 'x.c' })
})
