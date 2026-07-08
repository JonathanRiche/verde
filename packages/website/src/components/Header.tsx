import { Link, getRouteApi } from '@tanstack/solid-router'
import { For, Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import {
  activeThemeSlug,
  availableThemes,
  displayedTheme,
  persistThemeCookie,
  setActiveThemeSlug,
  themeCssText,
} from '../lib/site-theme'

const rootRoute = getRouteApi('__root__')

/* Custom dropdown mirroring the homepage theme chips — same shared signal, so
   picking a theme here or there stays in sync. The Header is mounted on every
   route, so it owns the site-wide theming: a reactive <style> tag whose token
   overrides follow the current theme. During SSR the current theme comes from
   the visitor's cookie (read by the root loader), so returning visitors get
   already-themed HTML with no flash. */
function ThemeDropdown() {
  const [open, setOpen] = createSignal(false)
  let rootEl: HTMLDivElement | undefined

  const savedSlug = rootRoute.useLoaderData() as () => string | null
  const theme = () => displayedTheme(savedSlug())

  // Persist picks for the next visit's SSR. Effects never run server-side.
  createEffect(() => {
    persistThemeCookie(activeThemeSlug())
  })

  onMount(() => {
    const onPointerDown = (e: MouseEvent) => {
      if (rootEl && !rootEl.contains(e.target as Node)) setOpen(false)
    }
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    onCleanup(() => {
      document.removeEventListener('mousedown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
    })
  })

  return (
    <Show when={availableThemes.length > 1}>
      {/* Site-wide token overrides; sits after the main stylesheet so its
          equal-specificity :root block wins by source order. */}
      <style innerHTML={themeCssText(theme())} />

      <div class="theme-dd" ref={rootEl}>
        <button
          type="button"
          class="theme-dd-trigger"
          aria-haspopup="listbox"
          aria-expanded={open()}
          aria-label="Preview an Omarchy theme"
          onClick={() => setOpen(!open())}
        >
          <span class="theme-swatch" style={{ background: theme().bg }}>
            <span class="theme-swatch-dot" style={{ background: theme().accent }} />
          </span>
          <span class="theme-dd-label">{theme().name}</span>
          <svg class="theme-dd-chevron" viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M6 9l6 6 6-6"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </button>

        <Show when={open()}>
          <div class="theme-dd-menu" role="listbox" aria-label="Omarchy themes">
            <For each={availableThemes}>
              {(t) => (
                <button
                  type="button"
                  role="option"
                  aria-selected={activeThemeSlug() === t.slug}
                  class={`theme-dd-item${activeThemeSlug() === t.slug ? ' theme-dd-item--active' : ''}`}
                  onClick={() => {
                    setActiveThemeSlug(t.slug)
                    setOpen(false)
                  }}
                >
                  <span class="theme-swatch" style={{ background: t.bg }}>
                    <span class="theme-swatch-dot" style={{ background: t.accent }} />
                  </span>
                  {t.name}
                </button>
              )}
            </For>
          </div>
        </Show>
      </div>
    </Show>
  )
}

export default function Header() {
  return (
    <header class="site-header">
      <nav class="wrap header-inner" aria-label="Primary">
        <Link to="/" class="brand">
          <img src={verdeLogo} alt="Verde" class="brand-logo" />
          <span>verde</span>
        </Link>

        <div class="nav-links">
          <a href="/#providers" class="nav-link">
            Providers
          </a>
          <a href="/#themes" class="nav-link">
            Themes
          </a>
          <a href="/#features" class="nav-link">
            Features
          </a>
          <a href="/#cli" class="nav-link">
            CLI
          </a>
          <a href="/#compare" class="nav-link">
            Compare
          </a>
          <a href="/#install" class="nav-link">
            Install
          </a>
          <Link to="/docs" class="nav-link" activeProps={{ class: 'nav-link nav-link--active' }}>
            Docs
          </Link>
        </div>

        <ThemeDropdown />

        <a
          href="https://github.com/JonathanRiche/verde/releases"
          target="_blank"
          rel="noreferrer"
          class="nav-cta"
        >
          Get Verde
        </a>
      </nav>
    </header>
  )
}
