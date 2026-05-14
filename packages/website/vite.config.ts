import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { defineConfig } from 'vite'
import type { Plugin } from 'vite'
import alchemy from 'alchemy/cloudflare/tanstack-start'
import { devtools } from '@tanstack/devtools-vite'
import viteTsConfigPaths from 'vite-tsconfig-paths'
import tailwindcss from '@tailwindcss/vite'

import { tanstackStart } from '@tanstack/solid-start/plugin/vite'

import solidPlugin from 'vite-plugin-solid'

const packageRoot = dirname(fileURLToPath(import.meta.url))

const alchemyWranglerConfig = '.alchemy/local/wrangler.jsonc'
const alchemyPlugins = process.env.NODE_ENV !== 'production' &&
  existsSync(alchemyWranglerConfig)
  ? [alchemy({ configPath: alchemyWranglerConfig })]
  : []

const ASSET_EXT_MIME: Record<string, string> = {
  '.css': 'text/css',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.ttf': 'font/ttf',
  '.eot': 'application/vnd.ms-fontobject',
}

function mimeForAssetPath(pathname: string): string | undefined {
  const lower = pathname.toLowerCase()
  for (const [ext, mime] of Object.entries(ASSET_EXT_MIME)) {
    if (lower.endsWith(ext)) {
      return mime
    }
  }
  return undefined
}

/**
 * TanStack Start's SSR manifest references `/assets/*` from the last client
 * build. Vite dev does not emit those files, so they 404 unless `dist/client`
 * already exists. Serve matching files from `dist/client` when present.
 * (JS is excluded so we never serve a stale client bundle from disk.)
 */
function serveStaleClientAssetsFromDist(): Plugin {
  return {
    name: 'verde-serve-stale-dist-client-assets',
    apply: 'serve',
    enforce: 'pre',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const pathname = req.url?.split('?')[0] ?? ''
        if (!pathname.startsWith('/assets/')) {
          return next()
        }

        const mime = mimeForAssetPath(pathname)
        if (!mime) {
          return next()
        }

        const diskPath = join(packageRoot, 'dist/client', pathname)
        let filePath = diskPath
        if (!existsSync(filePath)) {
          if (mime === 'text/css') {
            const assetsDir = join(packageRoot, 'dist/client/assets')
            if (!existsSync(assetsDir)) {
              return next()
            }
            const cssFiles = readdirSync(assetsDir).filter((f) => f.endsWith('.css'))
            if (cssFiles.length === 1) {
              filePath = join(assetsDir, cssFiles[0]!)
            } else {
              return next()
            }
          } else {
            return next()
          }
        }

        try {
          const body = readFileSync(filePath)
          res.setHeader('Content-Type', mime)
          res.setHeader('Cache-Control', 'no-store')
          res.end(body)
        } catch {
          next()
        }
      })
    },
  }
}

export default defineConfig({
  build: {
    target: 'esnext',
    rollupOptions: {
      external: ['node:async_hooks', 'cloudflare:workers'],
    },
  },
  plugins: [
    serveStaleClientAssetsFromDist(),
    ...alchemyPlugins,
    devtools(),
    // this is the plugin that enables path aliases
    viteTsConfigPaths({
      projects: ['./tsconfig.json'],
    }),
    tailwindcss(),
    tanstackStart(),
    solidPlugin({ ssr: true }),
  ],
})
