import { createFileRoute } from '@tanstack/solid-router'

import { renderConfigSchemaJson } from '../lib/config-schema'

/**
 * `/config.schema.json` — JSON Schema for `verde.json`.
 *
 * Editors fetch this URL from a `"$schema"` pointer in the config file
 * (or a workspace json.schemas mapping) for autocomplete and validation.
 */
export const Route = createFileRoute('/config.schema.json')({
  server: {
    handlers: {
      GET: async () =>
        new Response(renderConfigSchemaJson(), {
          headers: {
            // application/json so JSON language servers accept the body
            // without a schema-specific content-type allowlist.
            'Content-Type': 'application/json; charset=utf-8',
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'public, max-age=3600, s-maxage=86400',
            'X-Robots-Tag': 'noindex, follow',
          },
        }),
    },
  },
})
