import {
  HeadContent,
  Outlet,
  Scripts,
  createRootRouteWithContext,
} from '@tanstack/solid-router'
import { TanStackRouterDevtools } from '@tanstack/solid-router-devtools'

import { HydrationScript } from 'solid-js/web'
import { Suspense } from 'solid-js'

import Header from '../components/Header'

// Side-effect import (not `?url`): TanStack Start dev SSR skips `?url` CSS when
// building `/@tanstack-start/styles.css`, and `?url` hrefs point at prod asset
// names that 404 under `vite dev`.
import '../styles.css'

const siteUrl = 'https://openverde.ai'
const title = 'Verde | Desktop workspace for coding agents'
const description =
  'Verde is a native desktop workspace for coding agents with local provider CLIs, an embedded browser pane, and a project-scoped terminal dock.'

export const Route = createRootRouteWithContext()({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { title },
      { name: 'description', content: description },
      { name: 'theme-color', content: '#0d1213' },
      { name: 'robots', content: 'index, follow' },
      { property: 'og:type', content: 'website' },
      { property: 'og:url', content: siteUrl },
      { property: 'og:title', content: title },
      { property: 'og:description', content: description },
      { property: 'og:image', content: `${siteUrl}/og-image.png` },
      {
        property: 'og:image:alt',
        content:
          'Verde desktop app with an agent thread, browser pane, and terminal dock.',
      },
      { property: 'og:site_name', content: 'Verde' },
      { name: 'twitter:card', content: 'summary_large_image' },
      { name: 'twitter:title', content: title },
      { name: 'twitter:description', content: description },
      { name: 'twitter:image', content: `${siteUrl}/og-image.png` },
    ],
    links: [
      { rel: 'canonical', href: siteUrl },
      { rel: 'icon', type: 'image/png', href: '/verde-logo.png' },
      { rel: 'apple-touch-icon', href: '/verde-logo.png' },
      { rel: 'manifest', href: '/manifest.json' },
    ],
  }),
  shellComponent: RootComponent,
})

function RootComponent() {
  return (
    <html lang="en">
      <head>
        <HydrationScript />
      </head>
      <body>
        <HeadContent />
        <Suspense>
          <Header />
          <Outlet />
          <TanStackRouterDevtools />
        </Suspense>
        <Scripts />
      </body>
    </html>
  )
}
