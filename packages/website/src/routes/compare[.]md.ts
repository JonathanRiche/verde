import { createFileRoute } from '@tanstack/solid-router'

import { renderCompareMarkdown } from '../content/compare'

/** `/compare.md` — raw markdown mirror of `/compare` for agents and scripts. */
export const Route = createFileRoute('/compare.md')({
  server: {
    handlers: {
      GET: async () =>
        new Response(renderCompareMarkdown(), {
          headers: {
            'Content-Type': 'text/markdown; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
            'X-Robots-Tag': 'noindex, follow',
          },
        }),
    },
  },
})
