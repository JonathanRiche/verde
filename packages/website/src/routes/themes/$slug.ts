import { createFileRoute } from '@tanstack/solid-router'

import { themeBySlug } from '../../lib/site-theme'
import { portableThemePackage } from '../../lib/theme-package'

export const Route = createFileRoute('/themes/$slug')({
  server: {
    handlers: {
      GET: async ({ params }) => {
        if (!params.slug.endsWith('.json')) {
          return new Response('Theme packages use a .json URL.\n', { status: 404 })
        }

        const slug = params.slug.slice(0, -'.json'.length)
        const theme = themeBySlug(slug)
        if (!theme) {
          return new Response(`Unknown Verde theme: ${slug}\n`, { status: 404 })
        }

        return Response.json(portableThemePackage(theme), {
          headers: {
            'Cache-Control': 'public, max-age=3600, s-maxage=86400',
            'Content-Disposition': `inline; filename="${theme.slug}.json"`,
          },
        })
      },
    },
  },
})
