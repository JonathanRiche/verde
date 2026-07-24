import { describe, expect, test } from 'bun:test'

import { SITE_ORIGIN, renderSitemap } from './seo'

describe('website SEO helpers', () => {
  test('renders canonical absolute URLs without duplicate variants', () => {
    const sitemap = renderSitemap(['/', '/about', '/docs/design-mode'])

    expect(sitemap).toContain(`<loc>${SITE_ORIGIN}/</loc>`)
    expect(sitemap).toContain(`<loc>${SITE_ORIGIN}/about</loc>`)
    expect(sitemap).toContain(`<loc>${SITE_ORIGIN}/docs/design-mode</loc>`)
    expect(sitemap).not.toContain('.md</loc>')
    expect(sitemap).not.toContain('<priority>')
  })
})
