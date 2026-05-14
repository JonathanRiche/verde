import alchemy from 'alchemy'
import { TanStackStart } from 'alchemy/cloudflare'
import { CloudflareStateStore } from 'alchemy/state'

const useCloudflareState = process.env.ALCHEMY_STATE_TOKEN != null

const app = await alchemy('verde-website', {
  phase: process.argv.includes('--destroy') ? 'destroy' : 'up',
  stateStore: useCloudflareState
    ? (scope) =>
        new CloudflareStateStore(scope, {
          scriptName: 'verde-website-state',
        })
    : undefined,
})

export const worker = await TanStackStart('website', {
  entrypoint: 'dist/server/server.js',
  assets: 'dist/client',
  noBundle: false,
  adopt: true,
  dev: 'rm -rf node_modules/.vite && bun vite dev --port 3000',
  domains: [
    { domainName: 'openverde.ai', adopt: true },
    { domainName: 'open-verde.com', adopt: true },
  ],
  wrangler: {
    main: 'dist/server/server.js',
    transform: (spec) => ({
      ...spec,
      compatibility_date: '2026-04-28',
      compatibility_flags: Array.from(
        new Set([...(spec.compatibility_flags ?? []), 'nodejs_compat']),
      ),
      observability: {
        enabled: true,
      },
    }),
  },
})

console.log({ url: worker.url })

await app.finalize()
