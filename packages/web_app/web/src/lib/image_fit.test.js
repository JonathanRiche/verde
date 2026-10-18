import { describe, expect, test } from 'bun:test'

import { fitImageForUpload } from './image_fit.ts'

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

  test('falls back to JPEG and shrinks until it fits', async () => {
    const fake = fakeCodec({ width: 4000, height: 3000, bytes_per_pixel: 0.5, png_bytes_per_pixel: 4 })
    const fitted = await fitImageForUpload(fakeFile(30_000_000, 'shot.PNG'), 'image/png', 2_000_000, fake.codec)
    expect(fitted.mime).toBe('image/jpeg')
    expect(fitted.name).toBe('shot.jpg')
    expect(fitted.blob.size).toBeLessThanOrEqual(2_000_000)
    expect(fake.calls.at(-1).w).toBeLessThan(4000)
  })

})
