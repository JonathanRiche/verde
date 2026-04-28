import { existsSync } from 'node:fs'

import { defineConfig } from 'vite'
import alchemy from 'alchemy/cloudflare/tanstack-start'
import { devtools } from '@tanstack/devtools-vite'
import viteTsConfigPaths from 'vite-tsconfig-paths'
import tailwindcss from '@tailwindcss/vite'

import { tanstackStart } from '@tanstack/solid-start/plugin/vite'

import solidPlugin from 'vite-plugin-solid'

const alchemyWranglerConfig = '.alchemy/local/wrangler.jsonc'
const alchemyPlugins = process.env.NODE_ENV !== 'production' &&
  existsSync(alchemyWranglerConfig)
  ? [alchemy({ configPath: alchemyWranglerConfig })]
  : []

export default defineConfig({
  build: {
    target: 'esnext',
    rollupOptions: {
      external: ['node:async_hooks', 'cloudflare:workers'],
    },
  },
  plugins: [
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
