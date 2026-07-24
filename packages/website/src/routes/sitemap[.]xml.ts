import { createFileRoute } from '@tanstack/solid-router'

import { getAllDocs } from '../content/docs'
import { renderSitemap } from '../lib/seo'

export const Route = createFileRoute('/sitemap.xml')({
  server: {
    handlers: {
      GET: async () => {
        const paths = [
          '/',
          '/about',
          '/docs',
          ...getAllDocs().map((doc) => `/docs/${doc.slug}`),
        ]
        return new Response(renderSitemap(paths), {
          headers: {
            'Content-Type': 'application/xml; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
          },
        })
      },
    },
  },
})
