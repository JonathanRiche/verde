import { createFileRoute } from '@tanstack/solid-router'
import { installScript } from '../lib/curl-install-script'

export { installScript } from '../lib/curl-install-script'

export const Route = createFileRoute('/install.sh')({
  server: {
    handlers: {
      GET: async () =>
        new Response(installScript, {
          headers: {
            'Content-Type': 'text/x-shellscript; charset=utf-8',
            'Cache-Control': 'public, max-age=600',
          },
        }),
    },
  },
})
