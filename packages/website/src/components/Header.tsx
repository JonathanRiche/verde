import { Link } from '@tanstack/solid-router'
import { For, Show, createEffect, createSignal, onCleanup, onMount } from 'solid-js'

import verdeLogo from '../../../desktop/src/assets/verde_logo.png'
import {
  activeTheme,
  activeThemeSlug,
  applySiteTheme,
  availableThemes,
  setActiveThemeSlug,
} from '../lib/site-theme'

/* Custom dropdown mirroring the homepage theme chips — same shared signal, so
   picking a theme here or there stays in sync. The Header is mounted on every
   route, so it owns the effect that applies the theme tokens site-wide. */
function ThemeDropdown() {
  const [open, setOpen] = createSignal(false)
  let rootEl: HTMLDivElement | undefined

  // Re-skin the page whenever the shared theme changes. Effects only run
  // client-side, so SSR always emits the stock Verde tokens.
  createEffect(() => {
    applySiteTheme(activeTheme())
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
      <div class="theme-dd" ref={rootEl}>
        <button
          type="button"
          class="theme-dd-trigger"
          aria-haspopup="listbox"
          aria-expanded={open()}
          aria-label="Preview an Omarchy theme"
          onClick={() => setOpen(!open())}
        >
          <span class="theme-swatch" style={{ background: activeTheme().bg }}>
            <span class="theme-swatch-dot" style={{ background: activeTheme().accent }} />
          </span>
          <span class="theme-dd-label">{activeTheme().name}</span>
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
