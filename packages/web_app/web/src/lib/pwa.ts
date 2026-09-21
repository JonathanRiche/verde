/// iOS standalone PWAs (viewport-fit=cover + translucent status bar) report a
/// layout height shorter than the screen and scroll the document when an
/// input focuses, which left a dead strip under the composer and slid the
/// header beneath the status bar. The document and app root are therefore
/// sized from `--app-height`, published here (never `position: fixed`, which
/// iOS clips to the short layout viewport): the full screen at rest, the visual viewport while the
/// on-screen keyboard is up. `html.keyboard-open` lets CSS drop the
/// home-indicator padding that the keyboard covers.
const KEYBOARD_MIN_COVER_PX = 120

function isStandalone(): boolean {
  const legacy = (navigator as Navigator & { standalone?: boolean }).standalone === true
  return legacy || window.matchMedia('(display-mode: standalone)').matches
}

function restingHeight(): number {
  let height = window.innerHeight
  // iOS keeps screen.width/height in portrait terms regardless of rotation.
  if (isStandalone() && window.matchMedia('(pointer: coarse)').matches) {
    const portrait = window.matchMedia('(orientation: portrait)').matches
    const long_side = Math.max(window.screen.width, window.screen.height)
    const short_side = Math.min(window.screen.width, window.screen.height)
    height = Math.max(height, portrait ? long_side : short_side)
  }
  return height
}

export function trackAppViewport(): void {
  const root = document.documentElement
  const viewport = window.visualViewport
  const update = () => {
    const resting = restingHeight()
    const visible = viewport ? viewport.height : resting
    const keyboard_open = resting - visible > KEYBOARD_MIN_COVER_PX
    root.classList.toggle('keyboard-open', keyboard_open)
    root.style.setProperty('--app-height', `${Math.round(keyboard_open ? visible : resting)}px`)
    // The fixed root already fits the visible area; any document scroll iOS
    // applied to reveal a focused input only pushes the header off-screen.
    if (window.scrollX !== 0 || window.scrollY !== 0) window.scrollTo(0, 0)
  }
  viewport?.addEventListener('resize', update)
  viewport?.addEventListener('scroll', update)
  window.addEventListener('resize', update)
  window.addEventListener('orientationchange', update)
  window.addEventListener('scroll', update, { passive: true })
  update()
}

/// One-line viewport readout for Settings, so layout reports from phones come
/// with the numbers the sizing above is derived from.
export function viewportDiagnostics(): string {
  const viewport = window.visualViewport
  const applied = document.documentElement.style.getPropertyValue('--app-height') || 'unset'
  return [
    `app ${applied}`,
    `inner ${window.innerWidth}x${window.innerHeight}`,
    `visual ${viewport ? `${Math.round(viewport.height)}+${Math.round(viewport.offsetTop)}` : 'n/a'}`,
    `screen ${window.screen.width}x${window.screen.height}`,
    `client ${document.documentElement.clientHeight}`,
    isStandalone() ? 'standalone' : 'browser',
  ].join(' · ')
}

export function registerPwa(): void {
  if (!window.isSecureContext || !('serviceWorker' in navigator)) return
  // Vite HMR + a caching SW white-screens after dependency swaps.
  if (import.meta.env.DEV) {
    void navigator.serviceWorker.getRegistrations().then((regs) => {
      for (const reg of regs) void reg.unregister()
    })
    return
  }
  const register = () => {
    void navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' })
  }
  if (document.readyState === 'complete') register()
  else window.addEventListener('load', register, { once: true })
}
