import { createFileRoute } from '@tanstack/solid-router'

import installScript from '../install.ps1?raw'

export const Route = createFileRoute('/install.ps1')({
  server: {
    handlers: {
      GET: async () =>
        new Response(installScript, {
          headers: {
            'Content-Type': 'text/plain; charset=utf-8',
            'Cache-Control': 'public, max-age=600',
          },
        }),
    },
  },
})
