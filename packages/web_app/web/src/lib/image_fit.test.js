import { describe, expect, test } from 'bun:test'

import { MAX_FIT_IMAGE_EDGE, fitImageForUpload } from './image_fit.ts'

function fakeFile(size, name = 'photo.png', type = 'image/png') {
  return new File([new Uint8Array(size)], name, { type })
}

/// Encoded size is proportional to pixel count, so tests can steer how many
/// shrink steps it takes to fit.
function fakeCodec({ width, height, bytes_per_pixel, fail_decode = false, png_bytes_per_pixel }) {
  const calls = []
  let closed = false
  return {
    calls,
    closed: () => closed,
    codec: {
      async decode() {
        if (fail_decode) throw new Error('decode failed')
        return { width, height, close: () => { closed = true } }
      },
      async encode(_image, w, h, mime) {
        calls.push({ w, h, mime })
        const per_pixel = mime === 'image/png' ? png_bytes_per_pixel ?? bytes_per_pixel : bytes_per_pixel
        return new Blob([new Uint8Array(Math.ceil(w * h * per_pixel))], { type: mime })
      },
    },
  }
}

describe('fitImageForUpload', () => {
  test('passes images under the cap through untouched', async () => {
    const file = fakeFile(1000)
    const fake = fakeCodec({ width: 10, height: 10, bytes_per_pixel: 1 })
    const fitted = await fitImageForUpload(file, 'image/png', 2000, fake.codec)
    expect(fitted.blob).toBe(file)
    expect(fitted.mime).toBe('image/png')
    expect(fitted.name).toBe('photo.png')
    expect(fake.calls).toHaveLength(0)
  })

  test('clamps the long edge and keeps PNG when it fits', async () => {
    const fake = fakeCodec({ width: 8000, height: 4000, bytes_per_pixel: 0.5 })
    const fitted = await fitImageForUpload(fakeFile(50_000_000), 'image/png', 10_000_000, fake.codec)
    expect(fake.calls[0]).toEqual({ w: MAX_FIT_IMAGE_EDGE, h: 2048, mime: 'image/png' })
    expect(fitted.mime).toBe('image/png')
    expect(fitted.name).toBe('photo.png')
    expect(fitted.blob.size).toBeLessThanOrEqual(10_000_000)
    expect(fake.closed()).toBe(true)
  })

  test('falls back to JPEG and shrinks until it fits', async () => {
    const fake = fakeCodec({ width: 4000, height: 3000, bytes_per_pixel: 0.5, png_bytes_per_pixel: 4 })
    const fitted = await fitImageForUpload(fakeFile(30_000_000, 'shot.PNG'), 'image/png', 2_000_000, fake.codec)
    expect(fitted.mime).toBe('image/jpeg')
    expect(fitted.name).toBe('shot.jpg')
    expect(fitted.blob.size).toBeLessThanOrEqual(2_000_000)
    expect(fake.calls.at(-1).w).toBeLessThan(4000)
  })

  test('non-PNG sources only try JPEG', async () => {
    const fake = fakeCodec({ width: 3000, height: 2000, bytes_per_pixel: 1 })
    await fitImageForUpload(fakeFile(20_000_000, 'a.webp', 'image/webp'), 'image/webp', 10_000_000, fake.codec)
    expect(fake.calls.every((call) => call.mime === 'image/jpeg')).toBe(true)
  })

  test('reports undecodable oversized images', async () => {
    const fake = fakeCodec({ width: 1, height: 1, bytes_per_pixel: 1, fail_decode: true })
    await expect(fitImageForUpload(fakeFile(20, 'x.bmp'), 'image/bmp', 10, fake.codec)).rejects.toThrow(
      'x.bmp is too large and could not be resized.',
    )
  })
})
