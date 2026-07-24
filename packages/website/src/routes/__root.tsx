import {
  HeadContent,
  Outlet,
  Scripts,
  createRootRouteWithContext,
} from '@tanstack/solid-router'
import { TanStackRouterDevtools } from '@tanstack/solid-router-devtools'
import { createServerFn } from '@tanstack/solid-start'
import { getCookie } from '@tanstack/solid-start/server'

import { HydrationScript } from 'solid-js/web'
import { Suspense } from 'solid-js'

import Header from '../components/Header'
import {
  SITE_NAME,
  SITE_ORIGIN,
  SOCIAL_IMAGE_HEIGHT,
  SOCIAL_IMAGE_URL,
  SOCIAL_IMAGE_WIDTH,
} from '../lib/seo'
import { THEME_COOKIE } from '../lib/site-theme'

/* Read the visitor's saved Omarchy theme pick during SSR so the page paints
   already themed (see lib/site-theme.ts). Runs on the server only; the
   client re-derives the same value from document.cookie. */
const getSavedThemeSlug = createServerFn({ method: 'GET' }).handler(() => {
  return getCookie(THEME_COOKIE) ?? null
})

// Side-effect import (not `?url`): TanStack Start dev SSR skips `?url` CSS when
// building `/@tanstack-start/styles.css`, and `?url` hrefs point at prod asset
// names that 404 under `vite dev`.
import '../styles.css'

export const Route = createRootRouteWithContext()({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { name: 'theme-color', content: '#0d1213' },
      { name: 'color-scheme', content: 'dark' },
      { name: 'robots', content: 'index, follow' },
      { property: 'og:image', content: SOCIAL_IMAGE_URL },
      { property: 'og:image:secure_url', content: SOCIAL_IMAGE_URL },
      { property: 'og:image:type', content: 'image/png' },
      { property: 'og:image:width', content: String(SOCIAL_IMAGE_WIDTH) },
      { property: 'og:image:height', content: String(SOCIAL_IMAGE_HEIGHT) },
      {
        property: 'og:image:alt',
        content:
          'Verde, a native tiling workspace showing coding-agent, chat, and terminal panes.',
      },
      { property: 'og:site_name', content: SITE_NAME },
      { property: 'og:locale', content: 'en_CA' },
      { name: 'twitter:image', content: SOCIAL_IMAGE_URL },
      {
        name: 'twitter:image:alt',
        content:
          'Verde, a native tiling workspace showing coding-agent, chat, and terminal panes.',
      },
    ],
    links: [
      { rel: 'icon', type: 'image/x-icon', href: '/favicon.ico' },
      { rel: 'icon', type: 'image/png', sizes: '192x192', href: '/logo192.png' },
      { rel: 'apple-touch-icon', sizes: '192x192', href: '/logo192.png' },
      { rel: 'manifest', href: '/manifest.json' },
      {
        rel: 'alternate',
        type: 'text/plain',
        title: 'Verde documentation for language models',
        href: '/llms.txt',
      },
    ],
  }),
  loader: () => getSavedThemeSlug(),
  shellComponent: RootComponent,
})

function RootComponent() {
  const entityGraph = {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'WebSite',
        '@id': `${SITE_ORIGIN}/#website`,
        url: `${SITE_ORIGIN}/`,
        name: SITE_NAME,
        inLanguage: 'en',
        publisher: { '@id': `${SITE_ORIGIN}/#organization` },
      },
      {
        '@type': 'Organization',
        '@id': `${SITE_ORIGIN}/#organization`,
        name: SITE_NAME,
        url: `${SITE_ORIGIN}/`,
        logo: `${SITE_ORIGIN}/logo512.png`,
        sameAs: ['https://github.com/JonathanRiche/verde'],
      },
    ],
  }

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
        <script
          type="application/ld+json"
          innerHTML={JSON.stringify(entityGraph)}
        />
        <Scripts />
      </body>
    </html>
  )
}
