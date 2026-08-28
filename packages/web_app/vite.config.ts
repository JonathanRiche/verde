import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'
import solid from 'vite-plugin-solid'

const packageRoot = dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  root: resolve(packageRoot, 'web'),
  resolve: {
    tsconfigPaths: true,
  },
  plugins: [
    tailwindcss(),
    solid(),
  ],
  optimizeDeps: {
    include: ['marked', 'solid-js', 'solid-js/web', 'solid-js/store'],
  },
  assetsInclude: ['**/*.wasm'],
  server: {
    host: '127.0.0.1',
    port: 6783,
    strictPort: true,
    allowedHosts: ['127.0.0.1', 'localhost'],
    headers: {
      'Service-Worker-Allowed': '/',
    },
    fs: {
      allow: [packageRoot, resolve(packageRoot, '../desktop/src/assets')],
    },
    proxy: {
      '/api': 'http://127.0.0.1:7420',
      '/auth': 'http://127.0.0.1:7420',
      '/login': 'http://127.0.0.1:7420',
      '/ws': { target: 'ws://127.0.0.1:7420', ws: true },
    },
  },
  preview: {
    port: 4173,
  },
  build: {
    target: 'es2023',
    outDir: resolve(packageRoot, 'dist'),
    emptyOutDir: true,
    sourcemap: true,
  },
})
