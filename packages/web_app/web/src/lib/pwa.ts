export function registerPwa(): void {
  installAndroidCutoutFullscreen()
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

function installAndroidCutoutFullscreen(): void {
  if (!/Android/i.test(navigator.userAgent)) return
  if (!window.matchMedia('(display-mode: fullscreen)').matches) return
  if (!document.fullscreenEnabled) return

  let pending = false
  const enter = () => {
    if (pending || document.fullscreenElement) return
    pending = true
    // Android Chromium's manifest-fullscreen path can leave the camera-cutout
    // band outside the web viewport. A user-activated Fullscreen API request
    // routes the same viewport-fit=cover page through its short-edges path.
    void document.documentElement
      .requestFullscreen({ navigationUI: 'hide' })
      .catch(() => undefined)
      .finally(() => {
        pending = false
      })
  }

  // Fullscreen API entry requires a user activation. Reuse the first normal
  // touch without swallowing it, and allow another touch to re-enter later.
  window.addEventListener('pointerdown', enter, { capture: true, passive: true })
}
