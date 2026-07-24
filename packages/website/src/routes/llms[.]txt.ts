import { createFileRoute } from '@tanstack/solid-router'

import { renderLlmsIndex } from '../content/docs'

/**
 * `/llms.txt` — the llmstxt.org convention for agent-friendly sites.
 * Returns a compact markdown index of Verde's docs surface so an agent
 * can understand the project and find every doc page in one fetch.
 */
export const Route = createFileRoute('/llms.txt')({
  server: {
    handlers: {
      GET: async () =>
        new Response(renderLlmsIndex(), {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            // Agents re-fetch docs occasionally; let CDNs cache for an hour.
            'Cache-Control': 'public, max-age=3600',
            // Keep the machine-readable mirror crawlable without competing
            // with the canonical HTML docs in search results.
            'X-Robots-Tag': 'noindex, follow',
          },
        }),
    },
  },
})
