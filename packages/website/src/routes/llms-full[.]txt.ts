import { createFileRoute } from '@tanstack/solid-router'

import { renderLlmsFull } from '../content/docs'

/**
 * `/llms-full.txt` — every docs page concatenated into one markdown file,
 * with a source-URL attribution block per page. Lets an agent fetch the
 * whole documentation set in a single request.
 */
export const Route = createFileRoute('/llms-full.txt')({
  server: {
    handlers: {
      GET: async () =>
        new Response(renderLlmsFull(), {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=3600',
            'X-Robots-Tag': 'noindex, follow',
          },
        }),
    },
  },
})
