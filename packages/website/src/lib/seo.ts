export const SITE_ORIGIN = 'https://verdeai.dev'
export const SITE_NAME = 'Verde'
export const HOME_TITLE =
  'Verde — Native Desktop Workspace for AI Coding Agents'
export const HOME_DESCRIPTION =
  'Run Codex, Claude Code, OpenCode, Cursor, and Amp side by side in a native, local-first tiling workspace with chat, terminal, and browser panes.'
export const SOCIAL_IMAGE_PATH = '/og-image-v2.png'
export const SOCIAL_IMAGE_URL = `${SITE_ORIGIN}${SOCIAL_IMAGE_PATH}`
export const SOCIAL_IMAGE_WIDTH = 1730
export const SOCIAL_IMAGE_HEIGHT = 909

function escapeXml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;')
}

/** Render only canonical, indexable URLs into the XML sitemap. */
export function renderSitemap(paths: readonly string[]): string {
  const urls = paths
    .map((path) => {
      const url = path === '/' ? `${SITE_ORIGIN}/` : `${SITE_ORIGIN}${path}`
      return `  <url>\n    <loc>${escapeXml(url)}</loc>\n  </url>`
    })
    .join('\n')

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
    urls,
    '</urlset>',
    '',
  ].join('\n')
}
