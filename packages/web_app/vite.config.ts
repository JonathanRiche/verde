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
  // Keep Ghostty out of the prebundle so its wasm URL stays next to the package.
  // Drop leftover xterm entries after the terminal swap — they white-screen Vite.
  optimizeDeps: {
    include: ['marked', 'solid-js', 'solid-js/web', 'solid-js/store'],
    exclude: ['@slopus/ghostty-wasm', '@xterm/xterm', '@xterm/addon-fit'],
  },
  assetsInclude: ['**/*.wasm'],
  server: {
    host: '0.0.0.0',
    port: 6783,
    strictPort: true,
    allowedHosts: true,
    headers: {
      'Service-Worker-Allowed': '/',
    },
    fs: {
      allow: [packageRoot, resolve(packageRoot, '../desktop/src/assets')],
    },
    proxy: {
      '/api': 'http://127.0.0.1:7420',
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
