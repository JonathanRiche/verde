// Auto-generated Cloudflare binding types.
// @see https://alchemy.run/concepts/bindings/#type-safe-bindings

/// <reference types="vite/client" />

import type { worker } from '../alchemy.run'

export type CloudflareEnv = typeof worker.Env

declare global {
  type Env = CloudflareEnv
}

declare module 'cloudflare:workers' {
  namespace Cloudflare {
    export interface Env extends CloudflareEnv {}
  }
}
