/// Shrinks oversized chat images in the browser so any image can be dropped.
/// Every provider harness reads attachments into memory under its own cap
/// (Pi 16 MiB, ACP/Muse 20 MiB) and model APIs downsample far below 4K, so
/// re-encoding here keeps large photos sendable without losing usable detail.

/// Long-edge ceiling for re-encoded images. Model vision inputs top out well
/// below this; it only bounds decode/encode memory for huge sources.
export const MAX_FIT_IMAGE_EDGE = 4096

const JPEG_QUALITY = 0.9
const SCALE_STEP = 0.75
const MAX_ATTEMPTS = 8

export interface DecodedImage {
  width: number
  height: number
  close?: () => void
}

export interface ImageCodec {
  decode(file: Blob): Promise<DecodedImage>
  encode(image: DecodedImage, width: number, height: number, mime: string, quality: number): Promise<Blob | null>
}

export interface FittedImage {
  blob: Blob
  mime: string
  name: string
}

export async function fitImageForUpload(
  file: File,
  mime: string,
  max_bytes: number,
  codec: ImageCodec = canvasCodec,
): Promise<FittedImage> {
  if (file.size <= max_bytes) return { blob: file, mime, name: file.name }
  const label = file.name || 'That image'
  let image: DecodedImage
  try {
    image = await codec.decode(file)
  } catch {
    throw new Error(`${label} is too large and could not be resized.`)
  }
  try {
    const long_edge = Math.max(image.width, image.height)
    let scale = long_edge > MAX_FIT_IMAGE_EDGE ? MAX_FIT_IMAGE_EDGE / long_edge : 1
    // Screenshots stay lossless when a smaller PNG fits; photos go to JPEG.
    const targets = mime === 'image/png' ? ['image/png', 'image/jpeg'] : ['image/jpeg']
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
      const width = Math.max(1, Math.round(image.width * scale))
      const height = Math.max(1, Math.round(image.height * scale))
      for (const target of targets) {
        const blob = await codec.encode(image, width, height, target, JPEG_QUALITY)
        if (blob && blob.size <= max_bytes) {
          return { blob, mime: target, name: renameForMime(file.name, target) }
        }
      }
      scale *= SCALE_STEP
    }
  } finally {
    image.close?.()
  }
  throw new Error(`${label} is too large and could not be resized.`)
}

function renameForMime(name: string, mime: string): string {
  const extension = mime === 'image/png' ? 'png' : 'jpg'
  const base = name ? name.replace(/\.[^./]+$/, '') : 'image'
  return `${base}.${extension}`
}

const canvasCodec: ImageCodec = {
  decode: (file) => createImageBitmap(file),
  async encode(image, width, height, mime, quality) {
    const canvas = document.createElement('canvas')
    canvas.width = width
    canvas.height = height
    const context = canvas.getContext('2d')
    if (!context) return null
    // JPEG has no alpha; paint transparent regions white instead of black.
    if (mime === 'image/jpeg') {
      context.fillStyle = '#fff'
      context.fillRect(0, 0, width, height)
    }
    context.imageSmoothingQuality = 'high'
    context.drawImage(image as ImageBitmap, 0, 0, width, height)
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, mime, quality))
    canvas.width = 0
    canvas.height = 0
    return blob
  },
}
